defmodule Platform.Feedback.GithubPublisher.Broker do
  @moduledoc """
  The installation-side publisher (task 01a11ec3 stage 2): hands the built
  issue to the Suite-hosted feedback broker, which holds the GitHub
  credentials. This adapter carries NO credential — not a GitHub token, not
  an App key, not a broker secret — so there is nothing on a Burrow
  installation for a submission, a log or an error to leak.

  ## Wire contract

    * `POST <FEEDBACK_BROKER_URL>/issues` with JSON
      `%{repository, title, body, labels, fingerprint}` and the fingerprint
      as the `idempotency-key` header. The broker must answer a repeated key
      with the issue it already created.
    * `GET <FEEDBACK_BROKER_URL>/issues/<fingerprint>` answers the issue a
      fingerprint produced (200) or 404.
    * A 200/201 body must carry `repository` and `issue_number`; everything
      else in it is ignored. `GithubPublisher.publish/2` rebuilds the
      identity from those two validated values.

  `config :platform, :feedback_broker_req_options` is merged into every
  request; `config/test.exs` routes it to the `Req.Test` stub named after
  this module.
  """

  @behaviour Platform.Feedback.GithubPublisher

  alias Platform.Feedback.GithubPublisher

  @impl true
  def create_issue(issue, opts) do
    fingerprint = Keyword.fetch!(opts, :fingerprint)

    body = %{
      repository: Keyword.fetch!(opts, :repository),
      title: issue.title,
      body: issue.body,
      labels: issue.labels,
      fingerprint: fingerprint
    }

    with {:ok, base} <- base_url(),
         {:ok, status, response} <-
           request(:post, base <> "/issues", "create_issue",
             json: body,
             headers: [{"idempotency-key", fingerprint}]
           ) do
      case status do
        status when status in [200, 201] -> parse_identity(response)
        status -> GithubPublisher.http_error(status)
      end
    end
  end

  @impl true
  def find_existing(opts) do
    fingerprint = Keyword.fetch!(opts, :fingerprint)

    with {:ok, base} <- base_url(),
         {:ok, status, response} <-
           request(:get, base <> "/issues/" <> URI.encode_www_form(fingerprint), "find_existing") do
      case status do
        200 -> parse_identity(response)
        404 -> {:ok, nil}
        status -> GithubPublisher.http_error(status)
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
            {:error, :publisher_not_configured}
        end

      _ ->
        {:error, :publisher_not_configured}
    end
  end

  defp request(method, url, operation, extra \\ []) do
    opts =
      [
        method: method,
        url: url,
        retry: false,
        redirect: false,
        receive_timeout: 15_000
      ]
      |> Keyword.merge(extra)
      |> Keyword.merge(Application.get_env(:platform, :feedback_broker_req_options, []))

    result =
      try do
        Req.request(opts)
      rescue
        _ -> {:error, :exception}
      catch
        _, _ -> {:error, :exception}
      end

    case result do
      {:ok, %Req.Response{status: status, body: body}} ->
        GithubPublisher.log("broker", operation, status)
        {:ok, status, body}

      {:error, _reason} ->
        GithubPublisher.log("broker", operation, "transport_error")
        {:error, :publisher_unavailable}
    end
  end

  defp parse_identity(%{"repository" => repo, "issue_number" => number})
       when is_binary(repo) and is_integer(number),
       do: {:ok, %{repository: repo, issue_number: number}}

  defp parse_identity(_body), do: {:error, :publisher_bad_response}
end
