defmodule PlatformWeb.Plugs.VerifyGithubSignature do
  @moduledoc """
  Verify the HMAC-SHA256 signature GitHub attaches to webhook deliveries.

  GitHub signs the *raw request bytes* with the secret configured on the repo
  hook and sends `X-Hub-Signature-256: sha256=<lowercase hex>`. The verdict
  itself lives in `Platform.Webhooks.GithubSignature`; this plug is the thin
  transport layer, mirroring `PlatformWeb.Plugs.VerifyLivekitSignature`.

  The raw body must already be cached on `conn.assigns[:raw_body]` — this is
  done by `PlatformWeb.Plugs.CacheBodyReader` at the endpoint's `Plug.Parsers`
  layer, which runs before router pipelines. The plug deliberately never calls
  `Plug.Conn.read_body/1`: post-parsers the body stream is drained, so the
  controller's old `read_raw_body/1` fallback always returned `""` and the
  HMAC path was never actually exercised end to end.

  `repo_url` is read from `conn.body_params`, not `conn.params`, so a
  query-string `?repository[html_url]=` cannot steer per-project secret
  selection.

  ## Feature flag

  When `Application.get_env(:platform, :github_webhook_signature_required, true)`
  is `false`, verification failures are logged as warnings but the request
  passes through. This is a rollback safety valve — flip it in the prod runtime
  (`Application.put_env/3` over `bin/platform rpc`) to reopen the endpoint
  without a redeploy, at the cost of restoring the audited bypass. Nothing in
  test config turns it off: enforcement is the ambient test behaviour so the
  fail-closed path stays exercised by the whole suite.

  See `docs/runbooks/github_webhook_secret.md` for the secret cutover.

  Task 019f9b11 stage 2 — GitHub webhook auth-bypass fix.
  """

  import Plug.Conn

  alias Platform.Webhooks.GithubSignature

  require Logger

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    raw_body = conn.assigns[:raw_body] || ""
    signature = get_req_header(conn, "x-hub-signature-256") |> List.first()
    repo_url = get_in(conn.body_params, ["repository", "html_url"])

    case GithubSignature.verify(raw_body, signature, repo_url) do
      :ok ->
        # Task 01a11ec3 stage 3: record that THIS delivery verified, so a
        # handler that must act only on signed events (external-feedback
        # intake) can tell a verified delivery from one let through by the
        # `:github_webhook_signature_required` rollback valve below.
        assign(conn, :github_signature_verified, true)

      {:error, reason} ->
        if signature_required?() do
          Logger.warning(
            "[Webhook] Rejecting GitHub webhook: signature verification failed " <>
              "(reason=#{reason} #{delivery_context(conn, repo_url)})"
          )

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{status: "error", reason: to_string(reason)}))
          |> halt()
        else
          Logger.warning(
            "[Webhook] GitHub signature verification failed (reason=#{reason} " <>
              "#{delivery_context(conn, repo_url)}) — passing through because " <>
              ":github_webhook_signature_required is false"
          )

          conn
        end
    end
  end

  defp signature_required? do
    Application.get_env(:platform, :github_webhook_signature_required, true)
  end

  # Forensics for a real attack, and the breadcrumb an operator needs while
  # cutting the secret over.
  defp delivery_context(conn, repo_url) do
    event = get_req_header(conn, "x-github-event") |> List.first()
    delivery = get_req_header(conn, "x-github-delivery") |> List.first()

    "x-github-event=#{inspect(event)} x-github-delivery=#{inspect(delivery)} " <>
      "repo_url=#{inspect(repo_url)}"
  end
end
