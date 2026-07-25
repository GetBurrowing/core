defmodule Platform.Security.MeetingSlugScopeTest do
  @moduledoc """
  Security suite — the `/meetings/:slug` read boundary (task 019f9b14).

  This file adds no production behaviour. It exists because the three stages
  that closed the leak are only as durable as the assertions that pin them,
  and this bug's shape — a correctly-scoped function sitting 229 lines from an
  unscoped one — recurs precisely when nothing asserts the boundary.

  What is pinned, end to end through a real LiveView mount rather than a
  context call (`Platform.Meetings.MeetingAuthzTest` already covers the
  context in isolation; the point here is the *route*):

    * DENIAL — a viewer with no `org_memberships` row in the meeting's org is
      redirected to `/meetings`, with a flash byte-identical to a genuinely
      absent slug so the route is not a slug-existence oracle.
    * NO SUBSCRIPTION ON DENIAL — the severity was never the returned row, it
      was what `handle_params/3`'s success body does with it: subscribe the
      viewer to the meeting's chat / presence / room / meeting topics, build
      the participant list, attach `MeetingHooks`, and `send(self(),
      :auto_join)`, which starts the meeting and mints a LiveKit token. The
      denial assertions here read `Registry.lookup(Platform.PubSub, topic)`
      directly — `Phoenix.PubSub.subscribe/3` is `Registry.register/3` under
      the hood (phoenix_pubsub 2.x, pubsub.ex:205), so the subscriber list for
      a topic is observable — and each one is paired with an *allowed* mount
      of the same meeting on the same topic, so the probe is proven to have
      teeth rather than being vacuously empty.
    * ALLOW — an entitled member still mounts, so the fix did not over-deny.
    * COLLISION — `meetings` carries `unique_index(:meetings, [:project_id,
      :slug])`, so one slug string can name two rows in two orgs. Each viewer
      resolves *their* org's meeting and never sees the other's name. Before
      this task both viewers got an `Ecto.MultipleResultsError` 500.
    * ROOT ADMIN — the deliberate Fabrikam-admin bypass, pinned so a later reader
      does not mistake it for a hole.
    * EXTERNAL NARROWING — org membership *alone* does not admit an external
      user; a `chat_participants` row for the meeting's bound space is also
      required. This is the `ExternalScope.visible_space_id?/2` composition
      that makes org scoping sufficient rather than crude.
    * SURFACE — the unscoped `Meetings.get_meeting_by_slug/1` cannot come back.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.MeetingLive

  # ── Fixtures ──────────────────────────────────────────────────────────────

  # `@example.com` so `Tenancy.derive_role_from_email/1` yields `member`. A
  # `@example.com` address would derive admin and blanket-bypass the very
  # check under test — the one fixture mistake that would make this whole
  # file green for the wrong reason.
  defp user_in_org(org_id, opts \\ []) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "mtg-scope-#{n}@example.com",
        name: "Meeting Scope #{n}",
        oidc_sub: "oidc-mtg-scope-#{n}"
      })

    role = Keyword.get(opts, :role, "member")

    if Keyword.get(opts, :external, false) do
      {:ok, _} =
        Tenancy.mark_membership_external(%{user_id: user.id, org_id: org_id, role: role})
    else
      member!(user, org_id, role)
    end

    user
  end

  defp member!(user, org_id, role \\ "member") do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  # `Meetings.create_meeting/1` mints the bound chat space itself, so the
  # meeting arrives with a real `chat_space_id` — which is what every topic
  # in the success body is keyed off.
  defp meeting_in_org(org_id, name) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Scope Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    meeting
  end

  defp sign_in(conn, user), do: init_test_session(conn, current_user_id: user.id)

  # `Phoenix.PubSub.subscribe/3` is `Registry.register(pubsub, topic, meta)`
  # and `Phoenix.PubSub` starts a duplicate `Registry` under the pubsub's own
  # name, so the live subscriber set for a topic is directly readable. That
  # makes "did the denied mount subscribe?" an observation rather than an
  # inference.
  defp subscribers(topic) do
    Platform.PubSub
    |> Registry.lookup(topic)
    |> Enum.map(&elem(&1, 0))
  end

  # Every topic `handle_params/3`'s `{:ok, meeting}` branch joins.
  defp meeting_topics(meeting) do
    %{
      chat: ChatPubSub.space_topic(meeting.chat_space_id),
      presence: MeetingsPubSub.presence_topic(meeting.chat_space_id),
      meeting: MeetingLive.meeting_topic(meeting.id)
    }
  end

  # ── 1. Non-member denial ──────────────────────────────────────────────────

  describe "cross-org denial" do
    test "a Soylent member cannot open a Wayne-Tech meeting by slug", %{conn: conn} do
      meeting = meeting_in_org(tenant_org_id("wayne_tech"), "Wayne-Tech Only")
      viewer = user_in_org(tenant_org_id("soylent"))

      assert {:error, {:live_redirect, %{to: "/meetings"}}} =
               live(sign_in(conn, viewer), ~p"/meetings/#{meeting.slug}")
    end

    test "the denial is indistinguishable from a slug that does not exist", %{conn: conn} do
      meeting = meeting_in_org(tenant_org_id("wayne_tech"), "Existence Oracle")
      viewer = user_in_org(tenant_org_id("soylent"))
      conn = sign_in(conn, viewer)

      assert {:error, {:live_redirect, %{to: "/meetings", flash: denied}}} =
               live(conn, ~p"/meetings/#{meeting.slug}")

      assert {:error, {:live_redirect, %{to: "/meetings", flash: absent}}} =
               live(conn, ~p"/meetings/no-such-meeting-anywhere")

      assert denied["error"] == "Meeting not found."
      assert denied == absent
    end

    test "denial is a clean redirect — no crash, no Ecto exception", %{conn: conn} do
      meeting = meeting_in_org(tenant_org_id("wayne_tech"), "Clean Denial")
      viewer = user_in_org(tenant_org_id("soylent"))

      result =
        try do
          live(sign_in(conn, viewer), ~p"/meetings/#{meeting.slug}")
        rescue
          e -> flunk("denied mount raised #{inspect(e.__struct__)}: #{Exception.message(e)}")
        end

      assert {:error, {:live_redirect, %{to: "/meetings"}}} = result
    end
  end

  # ── 2. A denied mount subscribes to nothing and starts nothing ────────────

  describe "denied mount reaches none of the success body" do
    setup %{conn: conn} do
      org_id = tenant_org_id("wayne_tech")
      meeting = meeting_in_org(org_id, "Side Effect Probe")

      %{
        meeting: meeting,
        topics: meeting_topics(meeting),
        outsider: sign_in(conn, user_in_org(tenant_org_id("soylent"))),
        insider: sign_in(conn, user_in_org(org_id))
      }
    end

    test "no process is subscribed to the chat, presence or meeting topic afterwards",
         ctx do
      # Baseline: nobody is on these topics. The ids are freshly minted for
      # this test, so this holds even under `async: true`.
      for {_name, topic} <- ctx.topics, do: assert(subscribers(topic) == [])

      assert {:error, {:live_redirect, %{to: "/meetings"}}} =
               live(ctx.outsider, ~p"/meetings/#{ctx.meeting.slug}")

      for {name, topic} <- ctx.topics do
        assert subscribers(topic) == [],
               "denied mount subscribed to the #{name} topic (#{topic})"
      end
    end

    test "the same probe DOES see an entitled viewer's LiveView on every topic", ctx do
      # The control for the assertion above: an empty subscriber list only
      # means something if a real subscription would have shown up in it.
      # `meetings:presence:` and `meeting:` are subscribed from nowhere but
      # MeetingLive's authorized paths (grep: two call sites, both in the
      # `{:ok, meeting}` branch and the join handler), so those two are exact.
      {:ok, view, _html} = live(ctx.insider, ~p"/meetings/#{ctx.meeting.slug}")
      _ = render(view)

      for {name, topic} <- ctx.topics do
        assert view.pid in subscribers(topic),
               "allowed mount did NOT subscribe to the #{name} topic (#{topic}) — " <>
                 "the denial assertions above are vacuous"
      end
    end

    test "a broadcast on the meeting's chat topic still reaches a legitimate subscriber",
         ctx do
      # Proves the topic itself is live and deliverable, so "no subscribers"
      # above is a statement about the denied mount and not about a dead topic.
      ChatPubSub.subscribe(ctx.meeting.chat_space_id)
      MeetingsPubSub.subscribe_presence(ctx.meeting.chat_space_id)

      assert self() in subscribers(ctx.topics.chat)

      assert {:error, {:live_redirect, %{to: "/meetings"}}} =
               live(ctx.outsider, ~p"/meetings/#{ctx.meeting.slug}")

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        ctx.topics.chat,
        {:new_message, :probe}
      )

      assert_receive {:new_message, :probe}, 500

      # And the denied mount is not sitting on the topic alongside us.
      assert subscribers(ctx.topics.chat) == [self()]
    end

    test "no LiveKit / lifecycle side effects: the meeting stays scheduled and roomless",
         ctx do
      assert {:error, {:live_redirect, %{to: "/meetings"}}} =
               live(ctx.outsider, ~p"/meetings/#{ctx.meeting.slug}")

      # `:auto_join` flips a scheduled meeting to `live` (stamping
      # `started_at` and broadcasting `{:meeting_started, _}`) and then mints
      # a LiveKit token via `MeetingHooks.join/1`. None of it ran.
      reloaded = Repo.get!(Meeting, ctx.meeting.id)
      assert reloaded.status == "scheduled"
      assert is_nil(reloaded.started_at)

      assert is_nil(Meetings.get_active_room(ctx.meeting.chat_space_id))
      assert Meetings.active_participants_for_space(ctx.meeting.chat_space_id) == []
    end
  end

  # ── 3. Allow — the fix did not over-deny ──────────────────────────────────

  describe "entitled viewers still mount" do
    test "a Wayne-Tech member opens the Wayne-Tech meeting and sees its name", %{conn: conn} do
      org_id = tenant_org_id("wayne_tech")
      meeting = meeting_in_org(org_id, "Wayne-Tech Weekly")
      viewer = user_in_org(org_id)

      assert {:ok, _view, html} = live(sign_in(conn, viewer), ~p"/meetings/#{meeting.slug}")
      assert html =~ meeting.name
    end
  end

  # ── 4. Slug collisions across orgs ────────────────────────────────────────

  describe "one slug, two orgs" do
    setup do
      soylent_id = tenant_org_id("soylent")
      wayne_tech_id = tenant_org_id("wayne_tech")

      # Identical names in two projects yield an identical slug — legal,
      # because the unique index is on (project_id, slug), not slug alone.
      soylent_meeting = meeting_in_org(soylent_id, "Shared Slug Standup")
      wayne_tech_meeting = meeting_in_org(wayne_tech_id, "Shared Slug Standup")

      assert soylent_meeting.slug == wayne_tech_meeting.slug
      refute soylent_meeting.id == wayne_tech_meeting.id

      %{
        soylent_id: soylent_id,
        wayne_tech_id: wayne_tech_id,
        soylent_meeting: soylent_meeting,
        wayne_tech_meeting: wayne_tech_meeting,
        slug: soylent_meeting.slug
      }
    end

    test "the same URL resolves per viewer, and neither sees the other's meeting",
         %{conn: conn} = ctx do
      soylent_viewer = user_in_org(ctx.soylent_id)
      wayne_tech_viewer = user_in_org(ctx.wayne_tech_id)

      # Before this task BOTH of these mounts raised Ecto.MultipleResultsError.
      assert {:ok, view_a, html_a} =
               live(sign_in(conn, soylent_viewer), ~p"/meetings/#{ctx.slug}")

      assert {:ok, view_b, html_b} =
               live(sign_in(conn, wayne_tech_viewer), ~p"/meetings/#{ctx.slug}")

      # The rendered name is identical by construction (same name, two orgs),
      # so assert on identity instead: each viewer's LiveView joined its OWN
      # meeting's topics and not the other's.
      #
      # Only the `meeting:` and `meetings:presence:` topics are used as the
      # discriminator. The chat-space topic is NOT a clean signal here:
      # `ShellLive`'s roster hook subscribes every authenticated LiveView to
      # `ChatPubSub` for whatever `first_space/0` returns — a global,
      # viewer-independent pick, unrelated to this route's gate (and a sibling
      # of the unscoped `:index` listing already TODO'd in `meeting_live.ex`).
      # Asserting on it would be asserting on the shell sidebar.
      a_topics = meeting_topics(ctx.soylent_meeting)
      b_topics = meeting_topics(ctx.wayne_tech_meeting)

      _ = render(view_a)
      _ = render(view_b)

      assert view_a.pid in subscribers(a_topics.meeting)
      assert view_a.pid in subscribers(a_topics.presence)
      refute view_a.pid in subscribers(b_topics.meeting)
      refute view_a.pid in subscribers(b_topics.presence)

      assert view_b.pid in subscribers(b_topics.meeting)
      assert view_b.pid in subscribers(b_topics.presence)
      refute view_b.pid in subscribers(a_topics.meeting)
      refute view_b.pid in subscribers(a_topics.presence)

      assert html_a =~ ctx.soylent_meeting.name
      assert html_b =~ ctx.wayne_tech_meeting.name
    end

    test "a viewer entitled to both is told the link is ambiguous, not handed one",
         %{conn: conn} = ctx do
      viewer = ctx.soylent_id |> user_in_org() |> member!(ctx.wayne_tech_id)

      assert {:error, {:live_redirect, %{to: "/meetings", flash: flash}}} =
               live(sign_in(conn, viewer), ~p"/meetings/#{ctx.slug}")

      assert flash["error"] ==
               "That link matches more than one meeting. Open it from the Meetings list."

      # An ambiguous mount is a refusal too — it must not have subscribed to
      # either candidate on the way to deciding.
      for meeting <- [ctx.soylent_meeting, ctx.wayne_tech_meeting],
          {_name, topic} <- meeting_topics(meeting) do
        assert subscribers(topic) == []
      end
    end
  end

  # ── 5. Root-admin bypass (deliberate) ─────────────────────────────────────

  describe "Fabrikam root admin" do
    test "an admin of the root org opens a tenant-org meeting they are not a member of",
         %{conn: conn} do
      org_id = tenant_org_id("soylent")
      meeting = meeting_in_org(org_id, "Root Reach")
      admin = user_in_org(fabrikam_org_id(), role: "admin")

      refute Tenancy.member_of?(admin, org_id)
      assert Tenancy.fabrikam_admin?(admin)

      assert {:ok, _view, html} = live(sign_in(conn, admin), ~p"/meetings/#{meeting.slug}")
      assert html =~ meeting.name
    end
  end

  # ── 6. External-user narrowing ────────────────────────────────────────────

  describe "external users are narrowed past org membership" do
    # Two independent layers deny an external user here, and this file pins
    # both rather than pretending there is only one:
    #
    #   1. HTTP — `PlatformWeb.Plugs.ExternalUserScope` allowlists an external
    #      user to `/chat` and `/chat/:slug` ONLY, so `/meetings/:slug` is a
    #      uniform 403 before any LiveView mounts. The external user therefore
    #      cannot reach `handle_params/3` on this route at all today.
    #   2. CONTEXT — `fetch_meeting_for_user/2` composes
    #      `ExternalScope.visible_space_id?/2` on top of the org filter, so
    #      even a caller that bypasses the router (an MCP tool, an agent path,
    #      a future non-chat external surface) gets the narrowing.
    #
    # Layer 2 is the one this task added, and it is the one asserted in
    # detail: org membership ALONE must not admit an external user.

    test "the HTTP layer 403s an external user off /meetings/:slug entirely", %{conn: conn} do
      org_id = tenant_org_id("soylent")
      meeting = meeting_in_org(org_id, "Fenced Off")
      external = user_in_org(org_id, external: true)

      assert Tenancy.external_user?(%{id: external.id})
      assert Tenancy.member_of?(external, org_id)

      conn = get(sign_in(conn, external), ~p"/meetings/#{meeting.slug}")

      assert conn.status == 403
      assert conn.halted

      # Nothing mounted, so nothing subscribed.
      for {_name, topic} <- meeting_topics(meeting), do: assert(subscribers(topic) == [])
    end

    test "org membership alone does not admit an external user; a participant row does" do
      org_id = tenant_org_id("soylent")
      meeting = meeting_in_org(org_id, "Internal Working Session")
      external = user_in_org(org_id, external: true)

      # A full org member of the SAME org resolves it — so the denial below is
      # about externality, not about the fixture being wrong.
      insider = user_in_org(org_id)
      assert {:ok, _} = Meetings.fetch_meeting_for_user(insider, meeting.slug)

      # The external user holds the same org membership and is still denied,
      # because they hold no `chat_participants` row for the meeting's bound
      # space. `:not_found` rather than a distinct error — an external user
      # must not learn the meeting exists.
      assert {:error, :not_found} = Meetings.fetch_meeting_for_user(external, meeting.slug)

      {:ok, _participant} =
        Chat.add_participant(meeting.chat_space_id, %{
          participant_type: "user",
          participant_id: external.id,
          joined_at: DateTime.utc_now()
        })

      assert {:ok, fetched} = Meetings.fetch_meeting_for_user(external, meeting.slug)
      assert fetched.id == meeting.id
    end
  end

  # ── 7. Surface pin ────────────────────────────────────────────────────────

  describe "the unscoped read is gone for good" do
    test "Platform.Meetings exports no arity-1 get_meeting_by_slug" do
      Code.ensure_loaded!(Meetings)

      refute function_exported?(Meetings, :get_meeting_by_slug, 1),
             "an unscoped slug read is back on Platform.Meetings — see task 019f9b14"

      # The arity-2 form stays: it takes an explicit project_id, so it is not
      # an authorization surface.
      assert function_exported?(Meetings, :get_meeting_by_slug, 2)
    end

    test "an anonymous mount is never authorized", %{conn: conn} do
      meeting = meeting_in_org(tenant_org_id("soylent"), "No Session")

      assert {:error, :not_found} = Meetings.fetch_meeting_for_user(nil, meeting.slug)

      # And through the route: no `current_user_id` in the session means
      # `mount/3` fabricates a UUID for `:user_id`, which must never be the
      # authorization subject.
      assert {:error, {:redirect, _}} = live(conn, ~p"/meetings/#{meeting.slug}")
    end
  end
end
