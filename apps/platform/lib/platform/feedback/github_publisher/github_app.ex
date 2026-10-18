defmodule Platform.Feedback.GithubPublisher.GithubApp do
  @moduledoc """
  The Burrow-hosted publisher (task 01a11ec3 stage 2): a least-privilege
  GitHub App. Never run this on a Burrow installation — those use
  `Platform.Feedback.GithubPublisher.Broker` and hold no GitHub credential.

  ## Least privilege, per call

  Each publication mints a fresh installation access token narrowed in the
  token request itself to `permissions: %{issues: "write"}` and
  `repositories: [<the one configured repository>]`, uses it for the one
  issue call, and drops it. Even if the App is installed more broadly, the
  token this module holds can write issues on one repository and nothing
  else.

  ## Where the credential lives

  `FEEDBACK_GITHUB_APP_ID`, `FEEDBACK_GITHUB_APP_INSTALLATION_ID` and
  `FEEDBACK_GITHUB_APP_PRIVATE_KEY` (PEM) are read from the PROCESS
  ENVIRONMENT at call time. They are deliberately never written into
  application config, so `Application.get_all_env(:platform)`, a config dump
  or a crash report of the config server never carries them. The minted JWT
  and installation token exist only as local values inside one call; no
  function returns, logs or inspects them, and every error is a bounded atom.

  `config :platform, :feedback_github_req_options` is merged into every
  request; `config/test.exs` routes it to the `Req.Test` stub named after
  this module.
  """

  @behaviour Platform.Feedback.GithubPublisher

  alias Platform.Feedback.GithubPublisher

  @default_api "https://api.github.com"

  @impl true
  def create_issue(issue, opts) do
    repo = Keyword.fetch!(opts, :repository)

    with {:ok, token} <- installation_token(repo),
         {:ok, status, body} <-
           request(:post, "/repos/#{repo}/issues", "create_issue", token,
             json: %{title: issue.title, body: issue.body, labels: issue.labels}
           ) do
      case {status, body} do
        {201, %{"number" => number}} when is_integer(number) ->
          {:ok, %{repository: repo, issue_number: number}}

        {201, _} ->
          {:error, :publisher_bad_response}

        {status, _} ->
          GithubPublisher.http_error(status)
      end
    end
  end

  @impl true
  def find_existing(opts) do
    repo = Keyword.fetch!(opts, :repository)
    fingerprint = Keyword.fetch!(opts, :fingerprint)
    query = "repo:#{repo} is:issue in:body \"#{fingerprint}\""

    with {:ok, token} <- installation_token(repo),
         {:ok, status, body} <-
           request(:get, "/search/issues", "find_existing", token,
             params: [q: query, per_page: 1]
           ) do
      case {status, body} do
        {200, %{"items" => [%{"number" => number} | _]}} when is_integer(number) ->
          {:ok, %{repository: repo, issue_number: number}}

        {200, %{"items" => []}} ->
          {:ok, nil}

        {200, _} ->
          {:error, :publisher_bad_response}

        {status, _} ->
          GithubPublisher.http_error(status)
      end
    end
  end

  # ── token minting ──────────────────────────────────────────────────────

  defp installation_token(repo) do
    with {:ok, app_id, installation_id, pem} <- credentials(),
         {:ok, jwt} <- app_jwt(app_id, pem),
         {:ok, status, body} <-
           request(
             :post,
             "/app/installations/#{installation_id}/access_tokens",
             "mint_token",
             jwt,
             json: %{
               repositories: [repo |> String.split("/", parts: 2) |> List.last()],
               permissions: %{issues: "write"}
             }
           ) do
      case {status, body} do
        {201, %{"token" => token}} when is_binary(token) and token != "" -> {:ok, token}
        {201, _} -> {:error, :publisher_bad_response}
        {status, _} -> GithubPublisher.http_error(status)
      end
    end
  end

  defp credentials do
    app_id = env("FEEDBACK_GITHUB_APP_ID")
    installation_id = env("FEEDBACK_GITHUB_APP_INSTALLATION_ID")
    pem = env("FEEDBACK_GITHUB_APP_PRIVATE_KEY")

    if numeric?(app_id) and numeric?(installation_id) and is_binary(pem),
      do: {:ok, app_id, installation_id, pem},
      else: {:error, :publisher_not_configured}
  end

  defp app_jwt(app_id, pem) do
    now = System.os_time(:second)

    try do
      jwk = JOSE.JWK.from_pem(pem)

      {_meta, jwt} =
        jwk
        |> JOSE.JWT.sign(%{"alg" => "RS256"}, %{
          "iat" => now - 60,
          "exp" => now + 540,
          "iss" => app_id
        })
        |> JOSE.JWS.compact()

      {:ok, jwt}
    rescue
      _ -> {:error, :publisher_not_configured}
    catch
      _, _ -> {:error, :publisher_not_configured}
    end
  end

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp numeric?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9]{1,20}\z/, value)
  defp numeric?(_value), do: false

  # ── transport ──────────────────────────────────────────────────────────

  defp request(method, path, operation, bearer, extra) do
    opts =
      [
        method: method,
        url: api_base() <> path,
        headers: [
          {"authorization", "Bearer " <> bearer},
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", "2022-11-28"}
        ],
        retry: false,
        redirect: false,
        receive_timeout: 15_000
      ]
      |> Keyword.merge(extra)
      |> Keyword.merge(Application.get_env(:platform, :feedback_github_req_options, []))

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
        GithubPublisher.log("github_app", operation, status)
        {:ok, status, body}

      {:error, _reason} ->
        # The reason is dropped: a transport exception can carry the request
        # it failed on, and the request holds the bearer.
        GithubPublisher.log("github_app", operation, "transport_error")
        {:error, :publisher_unavailable}
    end
  end

  defp api_base do
    case GithubPublisher.config(:github_api_url) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> @default_api
    end
  end
end
