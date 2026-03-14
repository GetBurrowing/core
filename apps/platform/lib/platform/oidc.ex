defmodule Platform.OIDC do
  @default_scope "openid email profile"

  # Returns {:ok, %{url: url, session_params: %{state:, nonce:, code_verifier:, ...}}}
  # Callers must store the full session_params and pass them back to callback/2.
  # The session_params do NOT include openid_configuration — it is fetched fresh
  # in callback/2 when needed (avoiding oversized cookies).
  def authorize_url do
    strategy().authorize_url(base_config())
  end

  # session_params must be the full map returned by authorize_url/0 (state, nonce, code_verifier).
  def callback(params, session_params) do
    config =
      base_config()
      |> Keyword.put(:session_params, session_params)

    strategy().callback(config, params)
  end

  # Builds a logout/end-session URL. Prefers the end_session_endpoint from the
  # provider's discovery document (passed in as openid_configuration) so the
  # module works with any compliant OIDC provider. Falls back to a heuristic
  # path derived from the issuer URL when no config is available.
  def logout_url(id_token_hint, openid_configuration \\ nil) do
    endpoint =
      get_in(openid_configuration, ["end_session_endpoint"]) ||
        get_in(openid_configuration, [:end_session_endpoint]) ||
        issuer() <> "/end-session"

    URI.parse(endpoint)
    |> Map.put(:query, URI.encode_query(logout_query(id_token_hint)))
    |> URI.to_string()
  end

  def app_url, do: config!(:app_url)

  def callback_url do
    URI.merge(app_url(), "/auth/oidc/callback")
    |> to_string()
  end

  # Assent strategies require a Keyword list, not a Map.
  defp base_config do
    issuer = issuer()

    [
      client_id: config!(:client_id),
      client_secret: config!(:client_secret),
      issuer: issuer,
      site: issuer,
      base_url: issuer,
      authorization_params: [scope: @default_scope],
      redirect_uri: callback_url(),
      discovery_document_uri: issuer <> "/.well-known/openid-configuration",
      user_url: issuer <> "/userinfo",
      token_url: issuer <> "/token",
      authorize_url: issuer <> "/authorize",
      http_adapter: config(:http_adapter)
    ] ++ pkce_config()
  end

  # PKCE (RFC 7636) is opt-in via OIDC_PKCE_ENABLED=true.
  # Enable it when your OIDC provider enforces PKCE for the client (e.g. Pocket ID,
  # Keycloak with "PKCE Required"). Leave it off for providers that don't support it.
  # When enabled, Assent generates code_verifier/code_challenge and handles the
  # full exchange automatically — no extra code needed in the controller.
  defp pkce_config do
    if config(:pkce_enabled), do: [code_verifier: true], else: []
  end

  defp logout_query(nil), do: %{"post_logout_redirect_uri" => app_url()}

  defp logout_query(id_token_hint) do
    %{
      "id_token_hint" => id_token_hint,
      "post_logout_redirect_uri" => app_url()
    }
  end

  defp strategy do
    config(:strategy) || Assent.Strategy.OIDC
  end

  defp issuer do
    config!(:issuer)
    |> String.trim_trailing("/")
  end

  defp config(key) do
    Application.get_env(:platform, :oidc, [])
    |> Keyword.get(key)
  end

  defp config!(key) do
    config(key) || raise "missing OIDC configuration for #{inspect(key)}"
  end
end
