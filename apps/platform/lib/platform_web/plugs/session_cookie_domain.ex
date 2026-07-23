defmodule PlatformWeb.Plugs.SessionCookieDomain do
  @moduledoc """
  Thin wrapper around `Plug.Session` that injects a runtime-configured `Domain`
  attribute onto the `_platform_session` cookie's write path.

  ## Why this plug exists

  `PlatformWeb.Endpoint`'s `@session_options` is a compile-time module attribute
  used in three places: `plug Plug.Session` (the HTTP Set-Cookie *write* path)
  and `connect_info: [session: ...]` on both the `/live` websocket and longpoll
  transports (the *read* path). A compiled release captures that term at build
  time, so a prod-only `domain:` cannot be baked into the attribute.

  The `Domain` cookie attribute is only meaningful on the Set-Cookie *write*
  path — the LiveView socket merely reads and verifies the already-signed cookie
  and does not depend on `domain`. So we resolve the domain at runtime here, on
  the `Plug.Session` write path only, and leave both socket `connect_info` uses
  untouched.

  ## Behaviour

  `call/2` reads `Application.get_env(:platform, :session_cookie_domain)`:

    * a non-empty binary (e.g. `".example.com"`, set in prod via
      `SESSION_COOKIE_DOMAIN`) → `domain:` is merged into the base session opts,
      so the cookie is shared across every `*.example.com` subdomain.
      This is the cross-subdomain OIDC fix: a login started on `chat.*` keeps
      its `state` cookie when Pocket-ID redirects the callback to `suite.*`.
    * `nil`/empty (dev, test, CI, localhost — none set the env var) → the base
      opts are used unchanged, i.e. byte-for-byte the current host-only cookie.

  The two possible `Plug.Session.init/1` results are memoized in
  `:persistent_term` (keyed by the resolved domain) so per-request cost is
  negligible.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, base_opts) do
    Plug.Session.call(conn, session_opts(base_opts))
  end

  defp session_opts(base_opts) do
    domain = configured_domain()
    key = {__MODULE__, domain}

    case :persistent_term.get(key, :undefined) do
      :undefined ->
        opts =
          base_opts
          |> maybe_put_domain(domain)
          |> Plug.Session.init()

        :persistent_term.put(key, opts)
        opts

      opts ->
        opts
    end
  end

  defp configured_domain do
    case Application.get_env(:platform, :session_cookie_domain) do
      domain when is_binary(domain) and domain != "" -> domain
      _ -> nil
    end
  end

  defp maybe_put_domain(opts, nil), do: opts
  defp maybe_put_domain(opts, domain), do: Keyword.put(opts, :domain, domain)
end
