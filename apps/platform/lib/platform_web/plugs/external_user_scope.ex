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
  alias Platform.Chat.ExternalScope
  alias Platform.Access
  alias Platform.Access.Registry
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

      # The meetings INDEX (and the archive, which is `?view=archive` — a query
      # param on this same path, so `conn.path_info` is still `["meetings"]`).
      #
      # UNCONDITIONAL ON PURPOSE, unlike its `/meetings/:slug` sibling above.
      # A route gate sees a path, not a result set, so it cannot express "only
      # the rows you are invited to" — the sibling can carry an
      # `invited_to_slug?/2` check precisely because a slug names ONE meeting.
      # Per-row authorization for the index belongs in the QUERY, and that is
      # where it now lives: the index and calendar week resolve through
      # `Meetings.list_meetings_for_user/1` and
      # `Meetings.list_meetings_in_range_for_user/4`, and the archive through
      # the invitation branch of `Platform.Meetings.Archive.search/2`.
      #
      # So this clause is surface ADMISSION only. Do not "harden" it with a
      # grant check that cannot be written correctly here, and do not copy the
      # unconditional form onto a route whose page is not viewer-scoped.
      {:meet, ["meetings"]} ->
        conn

      # The meet-host ROOT. Surface ADMISSION only, mirroring
      # `{:meet, ["meetings"]}` above: it grants no data, because the root
      # serves a redirect to a page whose per-row authorization lives in the
      # QUERY (`Meetings.list_meetings_for_user/1`).
      #
      # This clause MUST sit above the terminal `{:meet, _}` deny — clause
      # order IS the allowlist mechanism, and below the deny it is dead code.
      #
      # Why the CHAT host needed no equivalent, and why this must not be
      # "simplified" away by pattern-matching on that sibling: the chat host's
      # root already falls through to `{_, []} -> fence_to_chat_host(conn) ||
      # conn`, which admits it (and no-ops when already on the chat host). The
      # meet surface is fenced EARLIER by its own terminal deny, so its root
      # never reaches that clause. The two hosts differ here for a real reason.
      #
      # Deliberately NOT a fall-through to `fence_to_chat_host/1`: bouncing a
      # meet-host member to the chat host is exactly the defeat the meet
      # comment above warns about.
      {:meet, []} ->
        conn

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

      # The app host admits only a registry rail path whose module explicitly
      # permits guests. The LiveView mount gate then re-checks every view.
      {:app, [segment | _]} ->
        entry =
          Enum.find(Registry.rail_entries(), fn entry ->
            entry.key != :chat and rail_segment(entry.key) == segment
          end)

        if entry && Access.module_access?(conn.assigns[:access_scope], entry.key) do
          conn
        else
          deny(conn, user, "external_non_chat_route")
        end

      {_, _} ->
        deny(conn, user, "external_non_chat_route")
    end
  end

  defp rail_segment(:context), do: "org_memory"
  defp rail_segment(:experiments), do: "control"
  defp rail_segment(:prompts), do: "admin"
  defp rail_segment(key), do: Atom.to_string(key)

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

  # A uniform 403 for BOTH a nonexistent space (`nil`) and an out-of-scope
  # existing space is deliberate: it gives the external user no existence
  # oracle — an off-limits slug is indistinguishable from a missing one
  # (canvas §9, cl-9-10). Never redirect and never 500 on the nil path;
  # `ExternalScope.authorized_space?/2` answers `false` for nil so both land
  # on this one deny call with this one reason string.
  #
  # The PREDICATE lives in `Platform.Chat.ExternalScope`, not here (task
  # 01a011ed). It was private to this plug, ChatLive had no equivalent, and
  # the two gates drifted — which is the whole defect. Do not re-inline it:
  # the LiveView mount calls the same function.
  defp gate_space(conn, user, slug) do
    if ExternalScope.authorized_space?(user, resolve_space(conn, slug)) do
      conn
    else
      deny(conn, user, "external_out_of_scope")
    end
  end

  # RESOLUTION, NOT AUTHORIZATION. This function's only job is to turn a URL
  # segment into the row the request names; `ExternalScope.authorized_space?/2`
  # decides whether this user may have it. Keeping the two apart is
  # load-bearing — org-scoping inside resolution silently fails CLOSED on rows
  # the authorizer would have admitted, and gives a denial that no grant can
  # lift.
  #
  # Same resolution ChatLive `handle_params/3` uses, all three steps of it:
  #
  #   1. org-scoped slug lookup against the external user's SXI org — this is
  #      the ADR-0042 disambiguator ("#general" in one tenant vs another) and
  #      stays FIRST so an ambiguous user-created slug still resolves to the
  #      caller's own tenant;
  #   2. a bare-UUID `get_space/1` — already unscoped, and already the
  #      precedent that unscoped resolution followed by authorization is this
  #      module's shape;
  #   3. `system_prefix_fallback/1` — added here by task 019fb955-f8b1 rework.
  #
  # Step 3 is what was missing, and the bug it caused: `Meetings.create_meeting/1`
  # mints the meeting's chat space with NO `:org_id`, so `org_id IS NULL`;
  # `get_space_by_slug/2`'s `where s.org_id == ^org_id` cannot match NULL; and
  # the slug is `meeting-<uuid>`, not a bare UUID, so step 2 misses too. The
  # plug therefore 403'd an external user on the chat space of a meeting they
  # HELD A LIVE INVITE TO — `Chat.participant?/2` was true the whole time and
  # was never consulted, because resolution had already answered nil. That
  # contradicts the rule this stack exists to implement: if you are invited to
  # the meeting, you have access to the chat for that meeting.
  #
  # ChatLive grew step 3 for exactly this class of row and this plug did not,
  # so the gate denied requests for spaces the LiveView behind it would have
  # rendered. The fix is to re-converge them, NOT to give meeting spaces an
  # org_id — that is the root fix (migration + backfill + nullability), filed
  # separately, and a migration does not belong in this member.
  defp resolve_space(conn, slug) do
    org_id =
      case conn.assigns[:current_user_org_membership] do
        %{org: %{id: id}} -> id
        _ -> nil
      end

    Chat.get_space_by_slug(slug, org_id: org_id) ||
      (valid_uuid?(slug) && Chat.get_space(slug)) ||
      system_prefix_fallback(slug) || nil
  end

  # Unscoped slug lookup, admitted ONLY for system-minted slug prefixes
  # (`Chat.reserved_slug_prefix?/1`: meeting-, task-exec-, dm-, group-). Those
  # spaces are minted by orchestration paths and carry `org_id = NULL` by
  # design or by history, so the org-scoped lookup structurally cannot find
  # them. A USER-CREATED channel slug can never carry one of these prefixes, so
  # ADR-0042 per-org channel-slug scoping is untouched.
  #
  # Mirrors `ChatLive.system_prefix_fallback/1` and shares its prefix list.
  # This RESOLVES; it does not admit. Everything it returns still has to clear
  # `ExternalScope.authorized_space?/2`, which requires a real
  # `chat_participants` row or the DM allowlist.
  defp system_prefix_fallback(slug) do
    if Chat.reserved_slug_prefix?(slug), do: Chat.get_space_by_slug(slug, [])
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
