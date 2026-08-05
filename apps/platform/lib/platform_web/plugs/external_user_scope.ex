defmodule PlatformWeb.Plugs.ExternalUserScope do
  @moduledoc """
  Fast-fail authorization gate for external users at HTTP entry.

  Runs AFTER `PlatformWeb.Plugs.RequireAuth` in the authenticated pipeline,
  so `conn.assigns.current_user` (a `%User{}` with `:org_memberships`
  preloaded) and `conn.assigns.current_user_org_membership` are already set.

  Enforcement is fail-closed and ALLOWLIST-based, and the allowlist is a
  function of `(host, route, grant)` — not of `(route, grant)` alone. Three
  surfaces share one endpoint and `PlatformWeb.ExternalSurface.for_conn/1` is
  the single answer to which one a request is on:

    * `:meet` — the guest MEET host. An external user reaches ONLY
      `/meetings/:slug`, and only a meeting they hold a live invite to
      (`Platform.Meetings.invited_to_slug?/2`). `/chat` on this host is off
      surface.
    * `:chat` — the external CHAT host (task 019f9257). UNCHANGED: `/`,
      `/chat`, and a `/chat/:slug` they are scoped to.
    * `:app` — the primary Suite host. UNCHANGED, byte for byte: same
      clauses, same order, same reason strings as before the meet surface
      existed.

  Each surface's clause set is an allowlist TERMINATED BY A DENY, so a new
  app route added later is `403` for external users on every host with no
  per-route wiring. Do not convert this into a denylist.

  Anything denied halts with a uniform `403` BEFORE the controller or
  LiveView mounts. Internal users are a complete no-op — `call/2` returns the
  conn unchanged without ever consulting the surface (this is the
  load-bearing "internal user unaffected" invariant, and host branching is
  the easiest way to break it).

  FAIL-CLOSED ON AN UNCONFIGURED HOST: with `:meet_host` unset, `for_conn/1`
  never answers `:meet`, so `/meetings/:slug` is `403` for external users
  everywhere. The meet surface ships DARK until `MEET_HOST` is provisioned.
  That is deliberate and is not to be papered over with a fallback.

  See canvas §4 (`/chat/<other space>` via direct URL -> 403 always) and §9
  (no existence oracle for off-limits resources).
  """

  import Plug.Conn

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Tenancy
  alias PlatformWeb.ExternalRedirect
  alias PlatformWeb.ExternalSurface

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %{} = user ->
        # `Tenancy.external_user?/1` (shipped by M1) is the shared predicate —
        # do NOT add a second one here. Internal users fall through unchanged.
        if Tenancy.external_user?(user) do
          gate_external(conn, user)
        else
          conn
        end

      _ ->
        # RequireAuth runs first and would already have halted an
        # unauthenticated request; defensive no-op if the assign is absent.
        conn
    end
  end

  # Allowlist per SURFACE; every surface's clause set ends in a deny, so a NEW
  # app route added later is automatically 403 for external users on ALL THREE
  # hosts without per-route wiring (canvas §8 "zero everything else"). This is
  # an allowlist — do not invert it into a denylist.
  defp gate_external(conn, user) do
    case {ExternalSurface.for_conn(conn), conn.path_info} do
      # MEET surface: the guest host exists to serve exactly one route. Note
      # `fence_to_chat_host/1` is NOT reachable from here — that is the point.
      # Bouncing an invited member off the meet host to /chat would defeat the
      # invite. Everything else on this host is off surface.
      {:meet, ["meetings", slug]} ->
        gate_meeting(conn, user, slug)

      {:meet, _} ->
        deny(conn, user, "external_off_surface")

      # CHAT and APP surfaces: byte-identical to the pre-meet behaviour —
      # same clauses, same order, same reason strings.
      #
      # Root redirects into /chat; the index list is filtered by M5/M7. But an
      # external user reaching the internal /chat index on the SUITE host must
      # be PINNED to the chat host (task 019f9257) — otherwise they mount the
      # internal :authenticated live_session. That fence still does exactly
      # that job here. Fall through when already on the chat host (no loop) or
      # when CHAT_HOST is unset (dev/test).
      {_, []} ->
        fence_to_chat_host(conn) || conn

      {_, ["chat"]} ->
        fence_to_chat_host(conn) || conn

      {_, ["chat", slug]} ->
        gate_space(conn, user, slug)

      {_, _} ->
        deny(conn, user, "external_non_chat_route")
    end
  end

  # task 019f9257: redirect an external user off the internal /chat index to the
  # absolute chat-host external surface. Returns a halted conn (302) when the
  # redirect applies, or `nil` to fall through. Guards:
  #   * only when CHAT_HOST is configured (`ExternalRedirect.chat_host_configured?/0`)
  #     — dev/test leave it unset and keep today's pass-through;
  #   * never when the request is ALREADY on the chat host (avoid a redirect loop).
  # Internal users never reach here (the caller gates on `Tenancy.external_user?/1`).
  #
  # UNCHANGED by the meet surface, and deliberately NOT reachable from the
  # `:meet` clauses of `gate_external/2`: the fence still pins an external user
  # off the internal /chat index on the app host, but firing it on the meet host
  # would bounce an INVITED member away from their meeting.
  defp fence_to_chat_host(conn) do
    if ExternalRedirect.chat_host_configured?() and not ExternalSurface.on_chat_host?(conn) do
      conn
      |> Phoenix.Controller.redirect(external: ExternalRedirect.chat_url("/chat"))
      |> halt()
    end
  end

  # NO EXISTENCE ORACLE, by the same mechanism the chat branch uses rather than
  # a new one: ONE deny call site with ONE reason string covers both "this slug
  # names no meeting" and "you are not invited". `invited_to_slug?/2` answers a
  # single `Repo.exists?` over invite-joined-meeting, so it cannot separate the
  # two either, and `deny/3` renders the fixed :"403" template independent of
  # the resource — so even the `[:platform, :auth, :access_blocked]` telemetry
  # is identical. Never redirect and never 500 on the no-such-meeting path.
  defp gate_meeting(conn, user, slug) do
    if Meetings.invited_to_slug?(slug, user) do
      conn
    else
      deny(conn, user, "external_meeting_not_invited")
    end
  end

  defp gate_space(conn, user, slug) do
    if authorized_space?(user, resolve_space(conn, slug)) do
      conn
    else
      deny(conn, user, "external_out_of_scope")
    end
  end

  # Same resolution ChatLive `handle_params/3` uses: org-scoped slug lookup
  # against the external user's SXI org, falling back to a bare-UUID get.
  defp resolve_space(conn, slug) do
    org_id =
      case conn.assigns[:current_user_org_membership] do
        %{org: %{id: id}} -> id
        _ -> nil
      end

    Chat.get_space_by_slug(slug, org_id: org_id) ||
      (valid_uuid?(slug) && Chat.get_space(slug)) || nil
  end

  # A uniform 403 for BOTH a nonexistent space (`nil`) and an out-of-scope
  # existing space is deliberate: it gives the external user no existence
  # oracle — an off-limits slug is indistinguishable from a missing one
  # (canvas §9, cl-9-10). Never redirect and never 500 on the nil path.
  defp authorized_space?(_user, nil), do: false

  defp authorized_space?(user, %{id: space_id} = space) do
    # Primary gate: an actual `chat_participants` row (channels, groups, and
    # DMs the user already belongs to — apply_grant/DM-creation materializes
    # the row). Thinner DM branch below only for the may-DM access case.
    Chat.participant?(space_id, user.id) or dm_allowlisted?(user, space)
  end

  # DM ACCESS branch: let an external user open a DM surface with a counterpart
  # whose org is on their per-org DM allowlist. This gates ACCESS to an
  # existing `/chat/:slug` only — M8 (task 019f8837-4663) owns server-side
  # enforcement of DM *initiation* (rejecting a create to a non-allowlisted
  # org). Keep this branch to access, not creation.
  defp dm_allowlisted?(user, %{kind: "dm", id: space_id}) do
    space_id
    |> Chat.list_participants(participant_type: "user")
    |> Enum.reject(fn p -> p.participant_id == user.id end)
    |> Enum.any?(fn p -> counterpart_org_allowed?(user, p.participant_id) end)
  end

  defp dm_allowlisted?(_user, _space), do: false

  defp counterpart_org_allowed?(user, counterpart_user_id) do
    %{id: counterpart_user_id}
    |> Tenancy.list_user_memberships()
    |> Enum.any?(fn m -> Tenancy.may_dm_org?(user, m.org_id) end)
  end

  # On any deny: emit the access-blocked telemetry (mirrors
  # `RequireAuth.emit_access_blocked/3` — feeds the M15 security suite +
  # audit), then halt with a uniform 403 rendered via the error views. The
  # catch-all `render/2` in ErrorHTML/ErrorJSON already yields "Forbidden"
  # for the `:"403"` template, so no new template clause is needed.
  defp deny(conn, user, reason) do
    emit_access_blocked(conn, user, reason)

    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.put_view(html: PlatformWeb.ErrorHTML, json: PlatformWeb.ErrorJSON)
    |> Phoenix.Controller.render(:"403")
    |> halt()
  end

  defp emit_access_blocked(conn, user, reason) do
    :telemetry.execute(
      [:platform, :auth, :access_blocked],
      %{system_time: System.system_time()},
      %{
        action: "blocked",
        actor_id: user.id,
        actor_type: "user",
        resource_type: "route",
        resource_id: conn.request_path,
        ip_address: format_ip(conn.remote_ip),
        reason: reason
      }
    )
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: to_string(ip)

  # Platform.UUID.valid?/1, NOT a bare Ecto.UUID.cast/1. resolve_space/2 above
  # passes the ORIGINAL `slug` — a URL PATH SEGMENT — to `Chat.get_space/1`
  # when this returns true. A bare cast hex-encodes any 16-byte binary and
  # returns {:ok, _}, so a 16-character channel slug cleared this guard and
  # then raised `Ecto.Query.CastError` inside `Repo` on a LIVE REQUEST PATH.
  # That is the PR #613 failure. Do not "simplify" this back to a bare cast.
  defp valid_uuid?(string), do: Platform.UUID.valid?(string)
end
