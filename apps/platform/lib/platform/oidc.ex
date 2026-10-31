defmodule Platform.OIDC do
  @default_scope "openid email profile groups"
  @default_external_claim "groups"

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

  # -- External-user marker claim (rbac-external-users M2 stage 1) --
  #
  # These READ a static id-token claim — no outbound IdP call (ADR-0004).

  @doc """
  The claim VALUE that marks a login as external (e.g. `"globex-external"`).

  Install config with NO default: `OIDC_EXTERNAL_GROUP` (task 01a14dd9).
  `nil` when unset, and a nil group flags nobody as external.
  """
  def external_group, do: config(:external_group)

  @doc "The claim NAME to inspect for the external marker (default `\"groups\"`)."
  def external_claim, do: config(:external_claim) || @default_external_claim

  @doc """
  Pure predicate: does `claims` (a string-keyed claims map) carry the
  configured external marker?

  Nil-safe and tolerant of the claim being a list, a bare string, or
  absent/malformed — anything that is not the configured group (or a list
  containing it) yields `false`. Returns `false` when no `external_group`
  is configured, so an unset marker never accidentally flags users.
  """
  @spec external_claim?(map()) :: boolean()
  def external_claim?(claims) when is_map(claims) do
    group = external_group()

    if is_binary(group) and group != "" do
      claims
      |> Map.get(external_claim())
      |> claim_contains?(group)
    else
      false
    end
  end

  def external_claim?(_claims), do: false

  @doc """
  The configured claim's value as a **list of strings**.

  Reads the SAME claim name as `external_claim?/1` (`external_claim/0`) but
  keeps the values instead of reducing them to a boolean — this is the seam
  `Tenancy.resolve_org_from_groups/1` consumes to name the org an external
  login belongs to.

  Shapes:

    * a list — non-binary members are dropped, order preserved
    * a bare string — wrapped to a one-element list
    * `nil` / absent / any other shape (number, map, …) — `[]`

  Never raises, never returns `nil`. Unlike `external_claim?/1` this does NOT
  depend on `external_group/0` being configured: the group values are data,
  not a marker test.
  """
  @spec claim_groups(map()) :: [String.t()]
  def claim_groups(claims) when is_map(claims) do
    claims
    |> Map.get(external_claim())
    |> normalize_groups()
  end

  def claim_groups(_claims), do: []

  defp normalize_groups(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp normalize_groups(value) when is_binary(value), do: [value]
  defp normalize_groups(_value), do: []

  defp claim_contains?(value, group) when is_list(value), do: Enum.any?(value, &(&1 == group))
  defp claim_contains?(value, group) when is_binary(value), do: value == group
  defp claim_contains?(_value, _group), do: false

  @doc """
  Open pocket-id's sign-in interaction for `authorize_url` server-side and
  return its RELATIVE path (`/interaction?interaction=<id>`), for the install
  hand-over (task 01a10315 stage 6 round 2, `PlatformWeb.AuthController.handover/2`).

  Why: pocket-id's one-time login page (`/lc/<code>?redirect=`) only follows
  a `redirect` that is one of its own front-end pages (measured on v2.18.0:
  `/authorize?...` and any absolute URL fail with "Invalid redirect URL").
  Its `/interaction` page is one, and the interaction it shows is created by
  an ordinary `GET /authorize` that carries no cookie, so core makes that
  request itself. The interaction holds this login's state, nonce and PKCE
  challenge; the browser completes it once signed in with the code, and
  pocket-id returns it to `/auth/oidc/callback` with the same `state`.

  Only a same-origin `/interaction?interaction=<id>` location is accepted;
  anything else (an error redirect to the callback, a 200) is an error.
  """
  @spec begin_interaction(String.t()) :: {:ok, String.t()} | {:error, term()}
  def begin_interaction(authorize_url) do
    options =
      [redirect: false, retry: false, receive_timeout: 10_000] ++
        Application.get_env(:platform, :oidc_interaction_req_options, [])

    case Req.get(authorize_url, options) do
      {:ok, %Req.Response{status: status} = response} when status in [302, 303] ->
        response |> Req.Response.get_header("location") |> List.first() |> interaction_path(authorize_url)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  @interaction_query ~r/\Ainteraction=[A-Za-z0-9-]{8,64}\z/

  defp interaction_path(nil, _authorize_url), do: {:error, :no_location}

  defp interaction_path(location, authorize_url) do
    authorize = URI.parse(authorize_url)
    uri = URI.merge(authorize, location)

    if {uri.scheme, uri.host, uri.port} == {authorize.scheme, authorize.host, authorize.port} and
         uri.path == "/interaction" and is_binary(uri.query) and
         Regex.match?(@interaction_query, uri.query),
       do: {:ok, "/interaction?" <> uri.query},
       else: {:error, :not_an_interaction}
  end

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
      authorization_params: [scope: config(:scope) || @default_scope],
      redirect_uri: callback_url(),
      discovery_document_uri: issuer <> "/.well-known/openid-configuration",
      user_url: issuer <> "/userinfo",
      token_url: issuer <> "/token",
      authorize_url: issuer <> "/authorize",
      http_adapter: http_adapter()
    ] ++ pkce_config()
  end

  # PKCE (RFC 7636) is opt-in via OIDC_PKCE_ENABLED=true.
  # Enable it when your OIDC provider enforces PKCE for the client (e.g. Keycloak with
  # "PKCE Required", or providers with strict PKCE enforcement). Leave it off for providers that don't support it.
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

  @doc """
  The configured OIDC issuer with any trailing slash removed. On bundled
  pocket-id installs this is pocket-id's browser-facing `APP_URL`, which
  `Platform.SignInAdmin.Config.public_base/0` uses to build sign-in links.
  Raises when no issuer is configured.
  """
  @spec issuer() :: String.t()
  def issuer do
    config!(:issuer)
    |> String.trim_trailing("/")
  end

  @doc """
  The HTTP adapter Assent uses for discovery, token and userinfo calls.

  Assent's `Assent.HTTPAdapter.Httpc`, when given no trust store, verifies
  against `:certifi.cacerts()`, a list compiled into certifi.beam that no file
  can extend. So the bare module (the config.exs value) is resolved to the same
  CAStore bundle `config/runtime.exs` installs as core's global trust store,
  and one file decides what core trusts (ADR 0053). Only `:cacertfile` is
  supplied: Assent still adds `verify: :verify_peer` and hostname checking.
  Any other configured adapter (e.g. `{Assent.HTTPAdapter.Mint, []}` in test)
  is passed through unchanged.
  """
  def http_adapter(configured \\ config(:http_adapter))

  def http_adapter(Assent.HTTPAdapter.Httpc),
    do: {Assent.HTTPAdapter.Httpc, ssl: [cacertfile: CAStore.file_path()]}

  def http_adapter(configured), do: configured

  @required_settings [
    {:issuer, "OIDC_ISSUER"},
    {:client_id, "OIDC_CLIENT_ID"},
    {:client_secret, "OIDC_CLIENT_SECRET"}
  ]

  @doc """
  The environment variables naming OIDC settings this install lacks, in a
  fixed order (`OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`), or `[]`
  when login is configured. `PlatformWeb.AuthController` answers `/auth/login`
  with a readable 503 naming them, instead of letting `authorize_url/0` raise
  (task 01a10322 stage 6).
  """
  @spec missing_settings() :: [String.t()]
  def missing_settings do
    for {key, env} <- @required_settings, blank?(config(key)), do: env
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false

  defp config(key) do
    Application.get_env(:platform, :oidc, [])
    |> Keyword.get(key)
  end

  defp config!(key) do
    config(key) || raise "missing OIDC configuration for #{inspect(key)}"
  end
end
