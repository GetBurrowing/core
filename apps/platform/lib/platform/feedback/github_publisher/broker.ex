defmodule Platform.Feedback.GithubPublisher.Broker do
  @moduledoc """
  The installation-side publisher (task 01a11ec3 stage 2): hands the
  sanitized submission to the Burrow-hosted feedback broker, which holds the
  GitHub credentials. This adapter carries NO credential — not a GitHub
  token, not an App key, not a broker secret — so there is nothing on a
  Burrow installation for a submission, a log or an error to leak.

  ## Wire contract

    * The base URL is `FEEDBACK_BROKER_URL`, or `default_broker_url/0`
      (the hosted Burrow broker) when it is unset or blank (task 01a1a6a5
      stage 3).
    * `POST <base>/issues` with JSON
      `%{repository, fingerprint, installation, submission}` and the
      fingerprint as the `idempotency-key` header. `installation` is the
      configured installation label or `null`. `submission` is
      `Platform.Feedback.Submission.wire_fields/1` of the sanitized
      structure: the allowlisted fields in the raw-argument shape.
    * NO `title`, `body` or `labels` are sent (task 01a1a6a5 stage 1). The
      feedback repository is public, so anyone can call a broker; a broker
      that forwarded a client-built markdown body would let any caller post
      arbitrary markdown, links and mentions. The broker therefore re-runs
      `Submission.normalize/1` (redaction, bounds) and
      `GithubPublisher.build_issue/2` (fencing) itself. The `issue` argument
      this adapter receives is deliberately ignored.
    * The broker must answer a repeated key with the issue it already
      created.
    * `GET <base>/issues/<fingerprint>` answers the issue a
      fingerprint produced (200) or 404.
    * `POST <base>/usage` carries an anonymous usage-count batch
      (`post_usage/1`, task 01a1b678 stage 2).
    * A 200/201 body must carry `repository` and `issue_number`; everything
      else in it is ignored. `GithubPublisher.publish/2` rebuilds the
      identity from those two validated values.

  `config :platform, :feedback_broker_req_options` is merged into every
  request; `config/test.exs` routes it to the `Req.Test` stub named after
  this module.
  """

  @behaviour Platform.Feedback.GithubPublisher

  @default_broker_url "https://burrow.kobo-ai.com/api/feedback-broker/v1"

  alias Platform.Feedback.GithubPublisher

  @impl true
  def create_issue(_issue, opts) do
    fingerprint = Keyword.fetch!(opts, :fingerprint)

    body = %{
      repository: Keyword.fetch!(opts, :repository),
      fingerprint: fingerprint,
      installation: installation_label(),
      submission: Keyword.fetch!(opts, :submission)
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

  @doc """
  `POST <base>/usage` with an anonymous usage-count batch (task 01a1b678
  stage 2), to the same base as every feedback request. `body` is built and
  scrubbed by `Platform.Sharing.UsageEvents`; this adapter only carries it.
  `:ok` on 200/201/202.
  """
  @spec post_usage(map()) :: :ok | {:error, atom()}
  def post_usage(body) when is_map(body) do
    with :ok <- usage_consent(body),
         {:ok, base} <- base_url(),
         {:ok, status, _response} <- request(:post, base <> "/usage", "post_usage", json: body) do
      case status do
        status when status in [200, 201, 202] -> :ok
        status -> GithubPublisher.http_error(status)
      end
    end
  end

  defp usage_consent(body) do
    cond do
      not Platform.Sharing.enabled?(:usage_counts) -> {:error, :sharing_disabled}
      Map.has_key?(body, "instruction_outcomes") and
          Platform.Sharing.enabled?(:instruction_updates_stopped) -> {:error, :sharing_disabled}
      Platform.Sharing.UsageEvents.refusal(body) != nil -> {:error, :invalid_usage}
      true -> :ok
    end
  rescue
    _ -> {:error, :sharing_disabled}
  end

  defp installation_label do
    case GithubPublisher.config(:installation_label) do
      label when is_binary(label) ->
        case String.trim(label) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  The broker every install uses unless `FEEDBACK_BROKER_URL` overrides it:
  the hosted Burrow broker (task 01a1a6a5 stage 3). This is the ONE place
  in the tree it is written.
  Moving the broker means changing this value in a release, or setting
  `FEEDBACK_BROKER_URL` on each install.
  """
  @spec default_broker_url() :: String.t()
  def default_broker_url, do: @default_broker_url

  @doc """
  The resolved broker base URL. Unset or blank uses `default_broker_url/0`;
  an explicit value wins; an explicit value that is not an http(s) URL with
  a host is `:publisher_not_configured` and does NOT fall back to the
  default.
  """
  @spec base_url() :: {:ok, String.t()} | {:error, :publisher_not_configured}
  def base_url do
    configured =
      case GithubPublisher.config(:broker_url) do
        url when is_binary(url) ->
          case String.trim(url) do
            "" -> @default_broker_url
            trimmed -> trimmed
          end

        nil ->
          @default_broker_url

        other ->
          other
      end

    case configured do
      url when is_binary(url) ->
        case URI.parse(url) do
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
