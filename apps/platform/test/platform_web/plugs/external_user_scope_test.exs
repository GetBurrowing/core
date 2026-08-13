defmodule PlatformWeb.Plugs.ExternalUserScopeTest do
  @moduledoc """
  Tests for the `ExternalUserScope` authorization plug (rbac-external-users
  M6). The plug is driven directly on a `Plug.Test`-built conn with the
  assigns `RequireAuth` would have set already pre-populated — the router
  wiring is exercised by `router_external_scope_test.exs`.

  Invariants under test:

    * internal users are a complete no-op (pass through unhalted, any path,
      ON EVERY HOST)
    * the reachable surface is a function of `(host, route, grant)`: on the
      chat and app hosts an external user reaches `/`, `/chat` and a
      `/chat/:slug` they are scoped to; on the MEET host they reach only a
      `/meetings/:slug` they hold a live invite to, and nothing else
    * every other route, an out-of-scope space, a nonexistent space, a
      meeting they are not invited to and a slug naming no meeting all halt
      with a uniform `403` — no existence oracle on either surface
    * the DM allowlist branch grants access to a DM with an allowlisted org
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Plugs.ExternalUserScope

  # ── Helpers ────────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "ext-scope-#{n}@example.com",
          name: "ExtScope #{n}",
          oidc_sub: "oidc-ext-scope-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_scope_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  defp membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp channel!(org, kind \\ "channel") do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{
        name: "Space #{n}",
        slug: "scope-space-#{n}",
        kind: kind,
        org_id: org.id
      })

    space
  end

  defp join!(space, user_id) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })

    :ok
  end

  # A real meeting, through the real constructor (which also mints the backing
  # chat space), so the slug under test is one the app would actually serve.
  defp meeting! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Ext Scope Project #{n}"})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Ext Scope Meeting #{n}",
        slug: "ext-scope-meeting-#{n}"
      })

    meeting
  end

  # A live invite row (no expiry, not revoked) keyed on `user_id` — the shape
  # `Meetings.invited_to_slug?/2` admits.
  defp invite!(meeting, user) do
    %Invite{}
    |> Invite.changeset(%{
      meeting_id: meeting.id,
      user_id: user.id,
      display_name: "Ext Scope Invitee"
    })
    |> Repo.insert!()
  end

  # Build a conn for `path` with the assigns RequireAuth would have set,
  # then run the plug. `format: "html"` so the deny path can render :"403".
  defp run(path, current_user, membership) do
    Phoenix.ConnTest.build_conn(:get, path)
    |> Plug.Conn.put_private(:phoenix_format, "html")
    |> Plug.Conn.assign(:current_user, current_user)
    |> Plug.Conn.assign(:current_user_org_membership, membership)
    |> ExternalUserScope.call(ExternalUserScope.init([]))
  end

  # Full authenticated user + membership assign shape, mirroring
  # `Tenancy.load_membership/1` (a map, NOT an %OrgMembership{}).
  defp authed(user, org, role) do
    user = Accounts.get_user(user.id)
    {user, %{org: org, role: role}}
  end

  setup do
    org = tenant_org!()

    ext = create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext.id, org_id: org.id})

    internal = create_user!()
    membership!(internal, org, "member")

    space_a = channel!(org)
    space_b = channel!(org)
    join!(space_a, ext.id)

    {ext_user, ext_membership} = authed(ext, org, :member)
    {int_user, int_membership} = authed(internal, org, :member)

    %{
      org: org,
      ext_user: ext_user,
      ext_membership: ext_membership,
      int_user: int_user,
      int_membership: int_membership,
      space_a: space_a,
      space_b: space_b
    }
  end

  describe "internal users (no-op)" do
    test "pass through unhalted on every path", ctx do
      for path <- ["/", "/chat", "/tasks", "/admin", "/org_memory", "/chat/" <> ctx.space_b.slug] do
        conn = run(path, ctx.int_user, ctx.int_membership)
        refute conn.halted, "expected internal user unhalted on #{path}"
      end
    end

    test "no telemetry emitted for internal user", ctx do
      ref = attach_telemetry()
      run("/tasks", ctx.int_user, ctx.int_membership)
      refute_receive {:access_blocked, _}, 50
      detach_telemetry(ref)
    end
  end

  describe "external users — chat surface allowlist" do
    test "unhalted on root and chat index", ctx do
      refute run("/", ctx.ext_user, ctx.ext_membership).halted
      refute run("/chat", ctx.ext_user, ctx.ext_membership).halted
    end

    test "unhalted on a scoped space (participant of A)", ctx do
      conn = run("/chat/" <> ctx.space_a.slug, ctx.ext_user, ctx.ext_membership)
      refute conn.halted
    end
  end

  describe "external users — denials" do
    test "403 on an out-of-scope existing space (B)", ctx do
      conn = run("/chat/" <> ctx.space_b.slug, ctx.ext_user, ctx.ext_membership)
      assert conn.halted
      assert conn.status == 403
    end

    test "403 on a nonexistent space — indistinguishable from out-of-scope", ctx do
      missing = run("/chat/does-not-exist-zzz", ctx.ext_user, ctx.ext_membership)
      out_of_scope = run("/chat/" <> ctx.space_b.slug, ctx.ext_user, ctx.ext_membership)

      assert missing.halted and missing.status == 403
      assert out_of_scope.halted and out_of_scope.status == 403
    end

    # ── UUID boundary (task 019fa129 stage 4) ──────────────────────────
    #
    # THE LIVE REQUEST-PATH BUG. `resolve_space/2` passes the ORIGINAL slug —
    # a URL PATH SEGMENT — to `Chat.get_space/1` when `valid_uuid?/1` returns
    # true. `valid_uuid?/1` was a BARE `Ecto.UUID.cast/1`, which hex-encodes
    # any 16-byte binary and returns {:ok, _}. So a 16-character channel slug
    # cleared the guard and then raised `Ecto.Query.CastError` inside `Repo`
    # — a 500 on a public request path. That is the PR #613 failure, and it
    # was still live on main until this stage.
    #
    # `"/chat/does-not-exist-zzz"` above does NOT cover this: 20 characters is
    # not 16, and a bare cast rejects it. The length is the whole test.
    test "403 (not a 500) on a 16-character channel slug", ctx do
      slug = "higginshigginsxx"
      assert byte_size(slug) == 16
      # The precondition that makes this test non-vacuous:
      assert {:ok, _} = Ecto.UUID.cast(slug)

      conn = run("/chat/" <> slug, ctx.ext_user, ctx.ext_membership)

      assert conn.halted
      assert conn.status == 403
    end

    test "403 on other malformed slug lengths too", ctx do
      for slug <- ["higgins", String.duplicate("a", 32), String.duplicate("a", 36)] do
        conn = run("/chat/" <> slug, ctx.ext_user, ctx.ext_membership)
        assert conn.halted and conn.status == 403, "expected 403 on slug #{inspect(slug)}"
      end
    end

    test "403 on non-chat routes", ctx do
      for path <- ["/tasks", "/admin", "/org_memory", "/files", "/meetings"] do
        conn = run(path, ctx.ext_user, ctx.ext_membership)
        assert conn.halted and conn.status == 403, "expected 403 on #{path}"
      end
    end

    test "emits access_blocked telemetry with reason external_out_of_scope (space)", ctx do
      ref = attach_telemetry()
      run("/chat/" <> ctx.space_b.slug, ctx.ext_user, ctx.ext_membership)
      assert_receive {:access_blocked, meta}
      assert meta.reason == "external_out_of_scope"
      assert meta.actor_id == ctx.ext_user.id
      assert meta.resource_type == "route"
      detach_telemetry(ref)
    end

    test "emits access_blocked telemetry with reason external_non_chat_route (route)", ctx do
      ref = attach_telemetry()
      run("/tasks", ctx.ext_user, ctx.ext_membership)
      assert_receive {:access_blocked, meta}
      assert meta.reason == "external_non_chat_route"
      detach_telemetry(ref)
    end
  end

  describe "external users — DM allowlist branch" do
    test "allowed to open a DM with a counterpart whose org is allowlisted", ctx do
      counterpart_org = tenant_org!()
      counterpart = create_user!()
      membership!(counterpart, counterpart_org, "member")

      dm = channel!(ctx.org, "dm")
      join!(dm, counterpart.id)
      # external user is NOT a participant of the DM, but may DM the org.
      {:ok, _} = Tenancy.allow_dm(ctx.ext_user, counterpart_org)

      conn = run("/chat/" <> dm.slug, ctx.ext_user, ctx.ext_membership)
      refute conn.halted
    end

    test "403 on a DM with a non-allowlisted counterpart org", ctx do
      counterpart_org = tenant_org!()
      counterpart = create_user!()
      membership!(counterpart, counterpart_org, "member")

      dm = channel!(ctx.org, "dm")
      join!(dm, counterpart.id)

      conn = run("/chat/" <> dm.slug, ctx.ext_user, ctx.ext_membership)
      assert conn.halted and conn.status == 403
    end
  end

  # ── task 019f9257: pin external users to the chat host ──────────────────
  #
  # When CHAT_HOST is configured, an external user hitting the internal /chat
  # index on the SUITE host is redirected (302) to the absolute chat-host
  # surface instead of mounting the internal :authenticated live_session. No
  # loop when already on the chat host; internal users untouched; unset
  # CHAT_HOST preserves today's pass-through.
  describe "external users — chat-host pin fence (task 019f9257)" do
    setup do
      prev = Application.get_env(:platform, :chat_host)
      Application.put_env(:platform, :chat_host, "chat.localhost")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:platform, :chat_host, prev),
          else: Application.delete_env(:platform, :chat_host)
      end)

      :ok
    end

    # Same as `run/3` but with an explicit request host.
    defp run_on_host(path, host, user, membership) do
      Phoenix.ConnTest.build_conn(:get, path)
      |> Map.put(:host, host)
      |> Plug.Conn.put_private(:phoenix_format, "html")
      |> Plug.Conn.assign(:current_user, user)
      |> Plug.Conn.assign(:current_user_org_membership, membership)
      |> ExternalUserScope.call(ExternalUserScope.init([]))
    end

    test "external user on the suite host → 302 to the absolute chat-host /chat", ctx do
      for path <- ["/", "/chat"] do
        conn = run_on_host(path, "suite.localhost", ctx.ext_user, ctx.ext_membership)
        assert conn.halted, "expected fence to halt on #{path}"
        assert conn.status == 302
        assert Plug.Conn.get_resp_header(conn, "location") == ["https://chat.localhost/chat"]
      end
    end

    test "external user ALREADY on the chat host → falls through (no redirect loop)", ctx do
      conn = run_on_host("/chat", "chat.localhost", ctx.ext_user, ctx.ext_membership)
      refute conn.halted
    end

    test "external user on the chat host can still reach a scoped space", ctx do
      conn =
        run_on_host(
          "/chat/" <> ctx.space_a.slug,
          "chat.localhost",
          ctx.ext_user,
          ctx.ext_membership
        )

      refute conn.halted
    end

    test "internal user on the suite host is unaffected by the fence", ctx do
      conn = run_on_host("/chat", "suite.localhost", ctx.int_user, ctx.int_membership)
      refute conn.halted
    end

    test "CHAT_HOST unset → external user on suite host passes through (dev/test)", ctx do
      Application.delete_env(:platform, :chat_host)
      conn = run_on_host("/chat", "suite.localhost", ctx.ext_user, ctx.ext_membership)
      refute conn.halted
    end
  end

  # ── task 019fb955-f8b1 stage 3: the meet host surface ───────────────────
  #
  # The reachable surface is now a function of (host, route, grant). On the
  # MEET host an external user reaches ONLY `/meetings/:slug`, and only a
  # meeting they hold a live invite to; `/chat` there is off surface. The chat
  # and app surfaces above are unchanged.
  #
  # THE CONFIG IS NOT OPTIONAL SETUP. `ExternalSurface.for_conn/1` answers
  # `:meet` only when `:meet_host` is configured AND matches, which is how dev
  # and test pass through today. A test in this block that forgets to set it
  # takes the `:app` path and asserts nothing about the meet surface — so the
  # first test below DELETES the config and pins the resulting denial, proving
  # the resolver consults it. Without that control the whole block would pass
  # on a build whose resolver always answers `:meet`.
  describe "external users — meet host surface" do
    @meet_host "meet.example.com"

    setup ctx do
      prev = Application.get_env(:platform, :meet_host)
      Application.put_env(:platform, :meet_host, @meet_host)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:platform, :meet_host, prev),
          else: Application.delete_env(:platform, :meet_host)
      end)

      # One principal throughout: `ctx.ext_user` holds a live invite to
      # `invited_meeting`, holds none to `other_meeting`, and participates in
      # `ctx.space_a`. That last fact is the positive control — a 403 alone is
      # equally consistent with a broken fixture or an unauthenticated conn.
      invited_meeting = meeting!()
      other_meeting = meeting!()
      invite!(invited_meeting, ctx.ext_user)

      %{invited_meeting: invited_meeting, other_meeting: other_meeting}
    end

    # ── Vacuity control ──────────────────────────────────────────────────
    test "MEET_HOST unset → even an INVITED user is 403 on the meet host", ctx do
      Application.delete_env(:platform, :meet_host)

      conn =
        run_on_host(
          "/meetings/" <> ctx.invited_meeting.slug,
          @meet_host,
          ctx.ext_user,
          ctx.ext_membership
        )

      assert conn.halted
      assert conn.status == 403
    end

    test "invited external user reaches their meeting on the meet host", ctx do
      conn =
        run_on_host(
          "/meetings/" <> ctx.invited_meeting.slug,
          @meet_host,
          ctx.ext_user,
          ctx.ext_membership
        )

      refute conn.halted
    end

    test "403 on a REAL meeting the external user is not invited to", ctx do
      conn =
        run_on_host(
          "/meetings/" <> ctx.other_meeting.slug,
          @meet_host,
          ctx.ext_user,
          ctx.ext_membership
        )

      assert conn.halted
      assert conn.status == 403
    end

    test "403 on a slug naming no meeting at all", ctx do
      conn =
        run_on_host("/meetings/no-such-meeting-zzz", @meet_host, ctx.ext_user, ctx.ext_membership)

      assert conn.halted
      assert conn.status == 403
    end

    # ── The oracle assertion ─────────────────────────────────────────────
    #
    # Status alone is not the property. "This meeting exists but you are not
    # invited" and "no meeting has this slug" must be INDISTINGUISHABLE, or the
    # meet surface leaks a meeting directory.
    #
    # THE TELEMETRY ASSERTION IS NOT DECORATION. Mutation-tested at stage 3:
    # splitting the no-such-meeting path onto its own reason string leaves
    # status, body and headers BYTE-IDENTICAL — `deny/3` renders the same fixed
    # :"403" template either way — so the response half of this test cannot see
    # it and the mutant survived the whole file. The divergence is observable
    # only on `[:platform, :auth, :access_blocked]`, which feeds the audit log,
    # and there it is a working existence oracle for anyone reading that stream.
    # One reason string is the property; assert it exactly, since a second one
    # is exactly what gets added later "for debuggability".
    test "not-invited and no-such-meeting are indistinguishable, telemetry included", ctx do
      ref = attach_telemetry()

      not_invited =
        run_on_host(
          "/meetings/" <> ctx.other_meeting.slug,
          @meet_host,
          ctx.ext_user,
          ctx.ext_membership
        )

      assert_receive {:access_blocked, not_invited_meta}

      missing =
        run_on_host("/meetings/no-such-meeting-zzz", @meet_host, ctx.ext_user, ctx.ext_membership)

      assert_receive {:access_blocked, missing_meta}
      detach_telemetry(ref)

      assert not_invited.status == missing.status
      assert not_invited.resp_body == missing.resp_body
      assert Enum.sort(not_invited.resp_headers) == Enum.sort(missing.resp_headers)

      assert not_invited_meta.reason == missing_meta.reason
      assert not_invited_meta.reason == "external_meeting_not_invited"
    end

    # ── Positive control on the same principal ───────────────────────────
    test "the same uninvited user IS admitted to their space on the chat host", ctx do
      conn =
        run_on_host(
          "/chat/" <> ctx.space_a.slug,
          "chat.example.com",
          ctx.ext_user,
          ctx.ext_membership
        )

      refute conn.halted
    end

    # ── Cross-host denial: one assertion per direction ───────────────────
    test "chat route on the MEET host → 403 external_off_surface", ctx do
      ref = attach_telemetry()

      conn =
        run_on_host("/chat/" <> ctx.space_a.slug, @meet_host, ctx.ext_user, ctx.ext_membership)

      assert conn.halted
      assert conn.status == 403
      assert_receive {:access_blocked, meta}
      assert meta.reason == "external_off_surface"
      detach_telemetry(ref)
    end

    test "meeting route on the CHAT host → 403 external_non_chat_route", ctx do
      ref = attach_telemetry()

      conn =
        run_on_host(
          "/meetings/" <> ctx.invited_meeting.slug,
          "chat.example.com",
          ctx.ext_user,
          ctx.ext_membership
        )

      assert conn.halted
      assert conn.status == 403
      assert_receive {:access_blocked, meta}
      assert meta.reason == "external_non_chat_route"
      detach_telemetry(ref)
    end

    # The chat-host fence must NOT fire on the meet surface — a 302 here would
    # bounce an invited member off their meeting host and back to /chat.
    test "root and /chat on the meet host are 403, NOT a 302 fence redirect", ctx do
      prev = Application.get_env(:platform, :chat_host)
      Application.put_env(:platform, :chat_host, "chat.example.com")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:platform, :chat_host, prev),
          else: Application.delete_env(:platform, :chat_host)
      end)

      for path <- ["/", "/chat"] do
        conn = run_on_host(path, @meet_host, ctx.ext_user, ctx.ext_membership)
        assert conn.halted, "expected halt on #{path}"
        assert conn.status == 403, "expected 403 (not #{conn.status}) on #{path}"
      end
    end

    # ── stage 4: the meetings INDEX is on surface ────────────────────────
    #
    # Stages 1–3 made the index, the calendar week and the archive
    # viewer-scoped; until this clause landed external users could not reach
    # `/meetings` at all, so that scoping was inert. Admission here is
    # unconditional BECAUSE the page behind it filters per row — the tests
    # below pin that this widened exactly one path and nothing adjacent.
    test "external user on the meet host reaches the meetings index", ctx do
      conn = run_on_host("/meetings", @meet_host, ctx.ext_user, ctx.ext_membership)

      refute conn.halted
    end

    test "the archive view is the same path and is admitted too", ctx do
      conn = run_on_host("/meetings?view=archive", @meet_host, ctx.ext_user, ctx.ext_membership)

      refute conn.halted
    end

    # The index being open must not soften the per-meeting gate beside it.
    test "index open, but a meeting they hold no invite to is still 403", ctx do
      index = run_on_host("/meetings", @meet_host, ctx.ext_user, ctx.ext_membership)
      refute index.halted

      show =
        run_on_host(
          "/meetings/" <> ctx.other_meeting.slug,
          @meet_host,
          ctx.ext_user,
          ctx.ext_membership
        )

      assert show.halted
      assert show.status == 403
    end

    test "other app routes on the meet host are still 403 external_off_surface", ctx do
      ref = attach_telemetry()

      for path <- ["/tasks", "/files", "/admin", "/meetings/archive/extra"] do
        conn = run_on_host(path, @meet_host, ctx.ext_user, ctx.ext_membership)
        assert conn.halted, "expected halt on #{path}"
        assert conn.status == 403, "expected 403 (not #{conn.status}) on #{path}"
      end

      assert_receive {:access_blocked, meta}
      assert meta.reason == "external_off_surface"
      detach_telemetry(ref)
    end

    # The widening is SURFACE-scoped: `/meetings` stays off surface on the chat
    # and app hosts, where nothing scoped the page for those viewers.
    test "the index stays 403 on the chat and app hosts", ctx do
      for host <- ["chat.example.com", "suite.example.com"] do
        conn = run_on_host("/meetings", host, ctx.ext_user, ctx.ext_membership)
        assert conn.halted, "expected halt on #{host}"
        assert conn.status == 403, "expected 403 (not #{conn.status}) on #{host}"
      end
    end

    # ── The invariant host branching breaks first ────────────────────────
    test "internal users remain a complete no-op on the meet host", ctx do
      ref = attach_telemetry()

      paths = [
        "/meetings/" <> ctx.other_meeting.slug,
        "/chat/" <> ctx.space_b.slug,
        "/tasks"
      ]

      for path <- paths do
        conn = run_on_host(path, @meet_host, ctx.int_user, ctx.int_membership)
        refute conn.halted, "expected internal user unhalted on #{path}"
      end

      refute_receive {:access_blocked, _}, 50
      detach_telemetry(ref)
    end
  end

  # ── task 019fb955-f8b1 rework: the meeting's own chat space ─────────────
  #
  # THE RULE THIS BLOCK EXISTS FOR: if you are invited to the meeting, you have
  # access to the chat for that meeting.
  #
  # It did not hold. `Meetings.create_meeting/1` mints the bound chat space
  # with no `:org_id`, so `org_id IS NULL`; `resolve_space/2` looked the slug up
  # ORG-SCOPED, and `where s.org_id == ^org_id` cannot match NULL; and the slug
  # is `meeting-<uuid>`, not a bare UUID, so the UUID fallback missed too. The
  # plug answered nil and denied — while `Chat.participant?/2` was true the
  # whole time and was NEVER CONSULTED, because resolution had already
  # answered. That is resolution doing authorization, and doing it wrong.
  #
  # The fix does not widen the gate: `authorized_space?/2` still decides, and
  # it still requires a real `chat_participants` row or the DM allowlist. What
  # changed is that resolution now FINDS the row so the authorizer gets to run.
  describe "external users — the chat space bound to a meeting" do
    setup do
      meeting = meeting!()
      space = Chat.get_space(meeting.chat_space_id)

      # ANTI-VACUITY, both halves. If either of these stops holding, this block
      # is exercising some other resolution path and proves nothing about the
      # bug: the org-scoped lookup has to MISS (org_id is NULL) and the
      # bare-UUID fallback has to MISS (the slug is not a UUID).
      assert is_nil(space.org_id),
             "meeting spaces are minted org-less; a non-nil org_id here means " <>
               "the root fix landed and this test now proves nothing"

      refute Platform.UUID.valid?(space.slug)
      assert String.starts_with?(space.slug, "meeting-")

      %{meeting: meeting, meeting_space: space}
    end

    test "an INVITED member reaches their own meeting's chat space", ctx do
      invite!(ctx.meeting, ctx.ext_user)
      join!(ctx.meeting_space, ctx.ext_user.id)

      # The three predicates the reviewer measured true on this exact row while
      # the plug denied it. Assert them, so a failure downstream of resolution
      # cannot be mistaken for the resolution bug.
      assert Chat.participant?(ctx.meeting_space.id, ctx.ext_user.id)

      conn =
        run_on_host(
          "/chat/" <> ctx.meeting_space.slug,
          "chat.example.com",
          ctx.ext_user,
          ctx.ext_membership
        )

      refute conn.halted, "an invited member was denied their own meeting's chat"
    end

    # THE GATE IS NOT WIDENED. Resolution finding the row is not admission:
    # without a participant row the same request is still 403, so what the
    # fallback restored is the authorizer's turn, not access.
    test "a NON-participant is still 403 on a meeting space that now resolves", ctx do
      refute Chat.participant?(ctx.meeting_space.id, ctx.ext_user.id)

      conn =
        run_on_host(
          "/chat/" <> ctx.meeting_space.slug,
          "chat.example.com",
          ctx.ext_user,
          ctx.ext_membership
        )

      assert conn.halted
      assert conn.status == 403
    end

    # ADR-0042 per-org channel-slug scoping is untouched. The unscoped retry is
    # guarded by the reserved-prefix list, and a USER-CREATED channel slug can
    # never carry one — so an org-less CHANNEL stays unresolvable even for a
    # participant. This is the assertion that reds if someone "simplifies" the
    # fallback by dropping the prefix guard.
    test "the unscoped retry does NOT extend to non-reserved slugs", ctx do
      n = System.unique_integer([:positive])

      {:ok, orgless_channel} =
        Chat.create_space(%{name: "Orgless #{n}", slug: "orgless-chan-#{n}", kind: "channel"})

      join!(orgless_channel, ctx.ext_user.id)

      refute Chat.reserved_slug_prefix?(orgless_channel.slug)
      assert Chat.participant?(orgless_channel.id, ctx.ext_user.id)

      conn =
        run_on_host(
          "/chat/" <> orgless_channel.slug,
          "chat.example.com",
          ctx.ext_user,
          ctx.ext_membership
        )

      assert conn.halted,
             "the reserved-prefix guard is gone — every org-less slug now resolves unscoped"

      assert conn.status == 403
    end

    # NO EXISTENCE ORACLE ON THE NEW PATH. Validation 019fcefa-d885-7b59 pins
    # the two 403s as byte-identical; the fallback adds a third way to reach a
    # 403 (a meeting slug that resolves but is not yours) and a fourth (a
    # meeting slug naming nothing), and both have to be indistinguishable from
    # the existing pair in status, body, headers AND telemetry reason.
    test "resolvable-but-unauthorized and no-such-meeting-slug are indistinguishable", ctx do
      ref = attach_telemetry()

      unauthorized =
        run_on_host(
          "/chat/" <> ctx.meeting_space.slug,
          "chat.example.com",
          ctx.ext_user,
          ctx.ext_membership
        )

      assert_receive {:access_blocked, unauthorized_meta}

      # A well-formed meeting slug that names no row at all — same prefix, so
      # it takes the SAME fallback branch and misses there.
      missing_slug = "meeting-" <> Ecto.UUID.generate()
      refute Chat.get_space_by_slug(missing_slug, [])

      missing =
        run_on_host(
          "/chat/" <> missing_slug,
          "chat.example.com",
          ctx.ext_user,
          ctx.ext_membership
        )

      assert_receive {:access_blocked, missing_meta}

      # And against the PRE-EXISTING pair the byte-identity validation pinned:
      # an out-of-scope ordinary space.
      out_of_scope =
        run_on_host(
          "/chat/" <> ctx.space_b.slug,
          "chat.example.com",
          ctx.ext_user,
          ctx.ext_membership
        )

      assert_receive {:access_blocked, out_of_scope_meta}
      detach_telemetry(ref)

      for other <- [missing, out_of_scope] do
        assert unauthorized.status == other.status
        assert unauthorized.resp_body == other.resp_body
        assert Enum.sort(unauthorized.resp_headers) == Enum.sort(other.resp_headers)
      end

      assert unauthorized_meta.reason == "external_out_of_scope"
      assert missing_meta.reason == "external_out_of_scope"
      assert out_of_scope_meta.reason == "external_out_of_scope"
    end
  end

  describe "defensive no-op" do
    test "no current_user assign → conn unchanged", _ctx do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/tasks")
        |> ExternalUserScope.call(ExternalUserScope.init([]))

      refute conn.halted
    end
  end

  # ── Telemetry test plumbing ────────────────────────────────────────────

  defp attach_telemetry do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "ext-scope-test-#{inspect(ref)}",
      [:platform, :auth, :access_blocked],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:access_blocked, metadata})
      end,
      nil
    )

    ref
  end

  defp detach_telemetry(ref), do: :telemetry.detach("ext-scope-test-#{inspect(ref)}")
end
