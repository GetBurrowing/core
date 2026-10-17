defmodule Platform.Feedback.Disposition.Broker do
  @moduledoc """
  Applies an intake disposition through the Suite-hosted feedback broker
  (task 01a11ec3 stage 3), the same broker `feedback_submit` publishes
  through. The installation carries no GitHub credential.

  ## Wire contract

    * `POST <FEEDBACK_BROKER_URL>/issues/dispositions` with JSON
      `%{repository, issue_number, verdict, comment, close, labels}` and the
      disposition key as the `idempotency-key` header. The broker must answer
      a repeated key without commenting twice.
    * 200/201/202/204 is `:ok`; anything else is a bounded error. The response
      body is never read, returned or logged.

  Requests merge `config :platform, :feedback_broker_req_options`, so tests
  reach the `Req.Test` stub named after `Platform.Feedback.GithubPublisher.Broker`.
  """

  @behaviour Platform.Feedback.Disposition

  alias Platform.Feedback.GithubPublisher

  @impl true
  def apply_disposition(disposition, opts) do
    key = Keyword.fetch!(opts, :idempotency_key)

    with {:ok, base} <- base_url() do
      request_opts =
        [
          method: :post,
          url: base <> "/issues/dispositions",
          json:
            Map.take(disposition, [
              :repository,
              :issue_number,
              :verdict,
              :comment,
              :close,
              :labels
            ]),
          headers: [{"idempotency-key", key}],
          retry: false,
          redirect: false,
          receive_timeout: 15_000
        ]
        |> Keyword.merge(Application.get_env(:platform, :feedback_broker_req_options, []))

      result =
        try do
          Req.request(request_opts)
        rescue
          _ -> {:error, :exception}
        catch
          _, _ -> {:error, :exception}
        end

      case result do
        {:ok, %Req.Response{status: status}} when status in [200, 201, 202, 204] ->
          GithubPublisher.log("broker", "apply_disposition", status)
          :ok

        {:ok, %Req.Response{status: status}} ->
          GithubPublisher.log("broker", "apply_disposition", status)
          {:error, :disposition_rejected}

        {:error, _} ->
          GithubPublisher.log("broker", "apply_disposition", "transport_error")
          {:error, :disposition_unavailable}
      end
    end
  end

  defp base_url do
    case GithubPublisher.config(:broker_url) do
      url when is_binary(url) ->
        case URI.parse(String.trim(url)) do
          %URI{scheme: scheme, host: host} = uri
          when scheme in ["https", "http"] and is_binary(host) and host != "" ->
            {:ok, uri |> URI.to_string() |> String.trim_trailing("/")}

          _ ->
            {:error, :disposition_not_configured}
        end

      _ ->
        {:error, :disposition_not_configured}
    end
  end
end
