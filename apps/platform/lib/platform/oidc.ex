defmodule Platform.OIDC do
  @default_scope "openid email profile"

  # Returns {:ok, %{url: url, session_params: %{state:, nonce:, code_verifier:, ...}}}
  # Callers must store the full session_params and pass them back to callback/2.
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

  def logout_url(id_token_hint) do
    issuer = issuer()

    URI.parse(issuer <> "/end-session")
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
    ]
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
