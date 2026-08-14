defmodule PlatformWeb.LoginOrigin do
  @moduledoc """
  Remembers WHICH EXTERNAL SURFACE a login started on, so the OIDC callback can
  return the user to it.

  Three surfaces share one endpoint and are distinguished only by hostname
  (`PlatformWeb.ExternalSurface`). A member handed a bare meet link who is not
  yet signed in bounces through the IdP and lands back on the APP host — a
  different front door from the one they knocked on. This module carries the
  one fact needed to fix that, and carries it in the narrowest possible form.

  ## The decision: an allowlist, in its strongest form

  The origin **never enters the OIDC `state`, and no client-supplied string is
  ever stored or echoed.** At `login/2` we resolve the request's surface
  server-side with `ExternalSurface.for_conn/1` and put the resulting ATOM
  (`:meet` | `:chat` | `:app`) in the signed session beside
  `:oidc_session_params`. At callback we read that atom and map it to a URL
  built entirely from server config (`:meet_host` / `:chat_host`). There is no
  host string, no path, and no URL in the round trip.

  This is not a new trust assumption. The OIDC flow ALREADY depends on the
  session cookie surviving the meet-host -> IdP -> app-host round trip:
  `AuthController.callback/2` refuses unless
  `get_session(conn, :oidc_session_params)[:state] == state`, and
  `PlatformWeb.Plugs.SessionCookieDomain` is the plug that makes that work
  across subdomains (its moduledoc names this exact case). The origin rides the
  same signed, server-written cookie the `state` check already trusts. Where
  the cookie is host-only (dev/test/CI, `SESSION_COOKIE_DOMAIN` unset) the key
  is simply absent and we fall back to today's destination — the same way login
  already fails closed there.

  ### Why the stored value is safe

  The surface atom is a CLOSED SET OF THREE, resolved server-side from
  `conn.host` by `ExternalSurface.for_conn/1`, which is an EXACT match against
  the configured `:meet_host` (see its `on_meet_host?/1` — `meet.evil.example.com`
  is NOT the meet surface). Even a forged `Host:` header can only select a host
  we ourselves configured.

  ## Rejected alternatives

    * **Carry the origin host in the OIDC `state`.** `state` is
      attacker-influencable; a callback that redirects to a host named in it is
      an open redirect. Allowlisting the value would close that, but it buys
      nothing over the session — which is signed and written by us — while
      adding a second place a host string can appear.

    * **A signed/encrypted round-trip token (`Phoenix.Token`).**
      Tamper-DETECTABLE rather than merely constrained sounds stronger, but is
      redundant: `Plug.Session` with a signed cookie IS that token — already
      built, already keyed, already exercised by the `state` check. A second
      signing path means two expiry stories for one fact.

    * **Do nothing; carry the user onward from the chat landing.** Cheapest,
      adds no surface, and legitimate — but it leaves the meet domain
      permanently an incomplete front door.

  ## Capture uses `for_conn/1`, deliberately

  NOT `router_surface/1`. `router_surface/1` matches the `meet.` PREFIX and
  exists to mirror the router's host scopes; the question here is "is this a
  host we have CONFIGURED and can therefore redirect back to". With
  `:meet_host` unset, `for_conn/1` answers `:app` and the feature is simply
  dark — the fail-closed posture `PlatformWeb.Plugs.ExternalUserScope`
  documents.
  """

  alias Plug.Conn
  alias PlatformWeb.ExternalSurface

  @typedoc "The closed set of surfaces a login can originate from."
  @type surface :: :chat | :meet | :app

  # The key name is part of the CONTRACT with the OIDC callback: `capture/1`
  # writes it at `login/2` and `read/1` consumes it a full redirect round trip
  # later, in a different controller action. Renaming it here without renaming
  # it there does not fail to compile — it silently degrades every login to
  # `:app`. Change it in one place only, through these functions.
  @session_key :login_origin_surface

  @doc """
  The session key this module owns. Exposed for tests and for callers that need
  to assert on session contents; write and read it through `capture/1`,
  `read/1` and `clear/1` rather than by hand.
  """
  @spec session_key() :: atom()
  def session_key, do: @session_key

  @doc """
  Record the surface this request is on, server-resolved, in the session.
  """
  @spec capture(Conn.t()) :: Conn.t()
  def capture(%Conn{} = conn),
    do: Conn.put_session(conn, @session_key, ExternalSurface.for_conn(conn))

  @doc """
  Read back the captured surface.

  Written as an explicit three-clause match over the closed set with a
  catch-all that answers `:app` — NOT `||` (which cannot distinguish `false`
  from absent and admits any truthy value) and NOT `String.to_existing_atom/1`
  (which would accept whatever atom the VM happens to have loaded). A missing
  key, `nil`, the binary `"meet"`, an unknown atom, a map: all `:app`.
  """
  @spec read(Conn.t()) :: surface()
  def read(%Conn{} = conn) do
    case Conn.get_session(conn, @session_key) do
      :meet -> :meet
      :chat -> :chat
      :app -> :app
      _other -> :app
    end
  end

  @doc """
  Drop the key, so a completed login cannot leave it to influence a later one.
  """
  @spec clear(Conn.t()) :: Conn.t()
  def clear(%Conn{} = conn), do: Conn.delete_session(conn, @session_key)
end
