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

  ## The INDEX half (task 019f9cb7 stage 6)

  Sections 8-13 extend the same file to the `/meetings` LISTING — the index,
  its calendar week, its archive view and its live refresh. The detail route
  above was only ever half the leak: a scoped `/meetings/:slug` that redirects
  a stranger away is worth nothing while the index it redirects them TO
  renders every meeting name in every org.

  Two rules, held to at every assertion:

    * BOTH LAYERS. Every claim is made twice — once against the context
      (`Meetings.list_meetings_for_user/1`, `Archive.search/2`) and once
      against the RENDERED LiveView. A context-only test does not prove the
      page stopped leaking; the page is what leaked.
    * A POSITIVE CONTROL IN EVERY NEGATIVE TEST. A listing that returns `[]`
      for everybody satisfies every "must not see" assertion in this file
      vacuously, so each one also asserts, on the same fixture and through
      the same call, that a viewer who SHOULD see that exact row does.

  And one distinction the external branch turns on: INVITATION, not
  participation. Section 10 pins it in both directions — a meeting attended
  with no invite is hidden, and an invite never used is shown.

  ## Why this module is `async: false`

  Reaching `/meetings` as an EXTERNAL user requires `:meet_host` to be set and
  `:host_surface_enforcement` relaxed (see section 10's setup, which documents
  the routing gap that makes the relaxation necessary). Both are process-global
  application env, which no `async: true` module may touch — a concurrent test
  would observe another module's host config. The alternative was to assert the
  external branch somewhere else, which would have split one boundary across
  two files.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings
  alias Platform.Meetings.Archive
  alias Platform.Meetings.Invite
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
  defp meeting_in_org(org_id, name, attrs \\ %{}) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Scope Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    attrs = Map.merge(%{project_id: project.id, name: name}, attrs)

    # `Meeting.changeset/2` requires the intended-time PAIR: a start without
    # an end is rejected, so a caller who names only the start gets the end.
    attrs =
      case attrs do
        %{scheduled_start_at: %DateTime{} = start} ->
          Map.put_new(attrs, :scheduled_end_at, DateTime.add(start, 1800, :second))

        _ ->
          attrs
      end

    {:ok, meeting} = Meetings.create_meeting(attrs)
    meeting
  end

  # ── Index fixtures (019f9cb7 stage 6) ─────────────────────────────────────

  # The calendar week is the index's only NAME-bearing surface — the grouped
  # list this route used to render is gone — so a meeting that is to be seen
  # (or proven unseen) on the index has to be placed inside the week on
  # screen. `Etc/UTC` keeps the fixture instant and the rendered column the
  # same date without depending on a tz database.
  @index_zone "Etc/UTC"

  defp today_at(hour) do
    @index_zone
    |> MeetingLive.calendar_today_date()
    |> DateTime.new!(Time.new!(hour, 0, 0), @index_zone)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp scheduled_meeting_in_org(org_id, name, hour \\ 9),
    do: meeting_in_org(org_id, name, %{scheduled_start_at: today_at(hour)})

  # An archived row: `Archive` reads `status in ~w(ended cancelled)` and dates
  # rows off the actuals, so both are stamped. Written through
  # `Ecto.Changeset.change/2` rather than a context call because the lifecycle
  # transition is not what is under test here.
  defp ended!(meeting) do
    # Microsecond precision, not truncated: the actuals are
    # `:utc_datetime_usec` and a second-precision value is rejected at dump.
    now = DateTime.utc_now()

    meeting
    |> Ecto.Changeset.change(%{
      status: "ended",
      started_at: DateTime.add(now, -3600, :second),
      ended_at: DateTime.add(now, -1800, :second)
    })
    |> Repo.update!()
  end

  defp invite!(meeting, attrs) do
    %Invite{}
    |> Invite.changeset(
      Map.merge(%{meeting_id: meeting.id, display_name: "Scope Invitee"}, attrs)
    )
    |> Repo.insert!()
  end

  # A `chat_participants` row for the meeting's bound space and NO invite —
  # the shape that makes "participation is not invitation" constructible.
  defp seat!(meeting, user) do
    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  # ── Layer helpers: context ids and RENDERED ids ───────────────────────────

  defp listed_ids(user), do: user |> Meetings.list_meetings_for_user() |> Enum.map(& &1.id)

  defp archived_ids(user) do
    result = Archive.search(user, [])
    Enum.map(result.matches ++ result.others, & &1.id)
  end

  # `put_connect_params/2` supplies the zone the calendar needs; without it
  # `:calendar_time_zone` is nil, the week list is `[]` BY CONTRACT, and every
  # "must not see" assertion below would pass for the wrong reason.
  defp index_conn(conn, user, opts) do
    conn = if host = opts[:host], do: %{conn | host: host}, else: conn

    conn
    |> sign_in(user)
    |> put_connect_params(%{"timezone" => @index_zone})
  end

  defp index_html(conn, user, opts \\ []) do
    {:ok, view, _html} = live(index_conn(conn, user, opts), ~p"/meetings")
    {view, render(view)}
  end

  defp rendered_ids(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("data-meeting-id")
    |> Enum.uniq()
  end

  # The week grid and the mobile day view render the same contract, so the
  # ids arrive twice; `Enum.uniq/1` in `rendered_ids/2` makes that a set.
  defp index_ids(conn, user, opts \\ []) do
    {_view, html} = index_html(conn, user, opts)
    {rendered_ids(html, ~s([data-role="calendar-event"])), html}
  end

  defp archive_ids(conn, user, opts \\ []) do
    conn = index_conn(conn, user, opts)
    {:ok, _view, html} = live(conn, ~p"/meetings?view=archive")
    {rendered_ids(html, ~s([data-role="archive-row"])), html}
  end

  # ── External-viewer setup, shared by sections 10 and 11b ──────────────────
  #
  # See section 10's comment for WHY the host fence is relaxed and why that is
  # a finding rather than a fixture detail. The env writes are the reason this
  # module is `async: false`; both keys are restored on exit, including the
  # "was unset" case, so a later module sees the config it configured.
  @meet_host "meet.example.com"

  defp relax_host_fence_and_seed_external(_ctx) do
    previous_host = Application.get_env(:platform, :meet_host)
    previous_fence = Application.get_env(:platform, :host_surface_enforcement, :off)

    Application.put_env(:platform, :meet_host, @meet_host)
    Application.put_env(:platform, :host_surface_enforcement, :off)

    on_exit(fn ->
      Application.put_env(:platform, :host_surface_enforcement, previous_fence)

      if previous_host do
        Application.put_env(:platform, :meet_host, previous_host)
      else
        Application.delete_env(:platform, :meet_host)
      end
    end)

    org_id = tenant_org_id("soylent")

    %{
      org_id: org_id,
      external: user_in_org(org_id, external: true),
      insider: user_in_org(org_id)
    }
  end

  defp external_index(conn, user), do: index_ids(conn, user, host: @meet_host)

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

    # ── The INDEX half of the same pin (019f9cb7 stage 6) ─────────────────
    #
    # A string scan rather than `function_exported?/3`, because the two
    # unscoped LISTING functions still EXIST on `Platform.Meetings` — they
    # are legitimate for callers that are not viewer-facing (jobs, counts,
    # the anti-vacuity control in `MeetingListingScopeTest`). What must not
    # come back is `MeetingLive` reaching them, and only a scan over the
    # module's source can say that.
    #
    # `meeting_live.ex` describes its own scoping in prose WITHOUT naming
    # the unscoped functions, deliberately — the same convention
    # `Platform.Tasks.ProjectScopeTest` relies on. Keep it that way or this
    # test trips on a comment.
    test "MeetingLive does not reach either unscoped listing function" do
      source = File.read!("lib/platform_web/live/meeting_live.ex")

      # Anti-vacuity: the scan is proven to be able to find a name, on this
      # exact file, before its silence about the other two means anything.
      assert source =~ "list_meetings_for_user",
             "the scan is reading the wrong file — it cannot find the scoped call it should"

      refute source =~ "list_all_meetings_unscoped",
             "the meetings index is back on an unscoped listing read — see task 019f9cb7"

      refute source =~ "list_meetings_in_range(",
             "the calendar week is back on the unscoped range read — see task 019f9cb7"

      # And the scoped pair really is what the index resolves through, so the
      # refutations above cannot be satisfied by deleting the call entirely.
      Code.ensure_loaded!(Meetings)
      assert function_exported?(Meetings, :list_meetings_for_user, 1)
      assert function_exported?(Meetings, :list_meetings_in_range_for_user, 4)
    end
  end

  # ── 8. The INDEX is scoped for INTERNAL viewers ───────────────────────────

  describe "cross-org denial on the /meetings index" do
    test "a foreign-org meeting is absent from the list AND from the rendered week",
         %{conn: conn} do
      foreign = scheduled_meeting_in_org(tenant_org_id("wayne_tech"), "Wayne-Tech Index Only")
      own = scheduled_meeting_in_org(tenant_org_id("soylent"), "Soylent Index Standup", 11)

      viewer = user_in_org(tenant_org_id("soylent"))
      insider = user_in_org(tenant_org_id("wayne_tech"))

      # CONTEXT layer.
      ids = listed_ids(viewer)
      assert own.id in ids, "positive control: the viewer's own-org meeting is listed"
      refute foreign.id in ids

      assert foreign.id in listed_ids(insider),
             "positive control: the foreign row exists and IS visible to its own org"

      # RENDER layer — the half that actually leaked. The name is the payload;
      # the slug is asserted too because it is the link a name would carry.
      {rendered, html} = index_ids(conn, viewer)

      assert own.id in rendered, "positive control: the own-org meeting draws on the week"
      refute foreign.id in rendered
      assert html =~ own.name
      refute html =~ foreign.name
      refute html =~ foreign.slug

      {insider_rendered, insider_html} = index_ids(conn, insider)

      assert foreign.id in insider_rendered,
             "positive control: the same page DOES draw that meeting for its own org"

      assert insider_html =~ foreign.name
    end

    test "a viewer with no memberships gets an empty index, not everyone's", %{conn: conn} do
      meeting = scheduled_meeting_in_org(tenant_org_id("soylent"), "Membership Gated Sync")
      insider = user_in_org(tenant_org_id("soylent"))

      orphan =
        Repo.insert!(%User{
          email: "mtg-scope-orphan-#{System.unique_integer([:positive])}@example.com",
          name: "Orphan Viewer",
          oidc_sub: "oidc-mtg-scope-orphan-#{System.unique_integer([:positive])}"
        })

      assert meeting.id in listed_ids(insider), "positive control"
      refute meeting.id in listed_ids(orphan)

      {rendered, html} = index_ids(conn, orphan)
      refute meeting.id in rendered
      refute html =~ meeting.name

      # An empty scoped answer says so, rather than rendering a week that
      # reads as "your meetings" while holding somebody else's.
      assert html =~ ~s(data-empty-state="meetings-index")
    end
  end

  # ── 9. Root admin and anonymous, on the index ─────────────────────────────

  describe "the index bypass and the index floor" do
    test "a Fabrikam root admin still sees every org's meetings, at both layers", %{conn: conn} do
      a = scheduled_meeting_in_org(tenant_org_id("soylent"), "Root Index Reach A", 9)
      b = scheduled_meeting_in_org(tenant_org_id("wayne_tech"), "Root Index Reach B", 13)
      admin = user_in_org(fabrikam_org_id(), role: "admin")

      assert Tenancy.fabrikam_admin?(admin)

      ids = listed_ids(admin)
      assert a.id in ids and b.id in ids

      {rendered, html} = index_ids(conn, admin)
      assert a.id in rendered and b.id in rendered
      assert html =~ a.name and html =~ b.name
    end

    test "a nil / anonymous viewer sees nothing an authenticated viewer does see",
         %{conn: conn} do
      meeting = scheduled_meeting_in_org(tenant_org_id("soylent"), "Anonymous Floor Sync")
      insider = user_in_org(tenant_org_id("soylent"))

      assert meeting.id in listed_ids(insider), "positive control"
      assert Meetings.list_meetings_for_user(nil) == []
      assert Archive.search(nil, []).total == 0

      # Through the route: no session means no mount at all, so the page
      # cannot leak — but the context floor above is what holds if a future
      # surface mounts without one.
      assert {:error, {:redirect, _}} = live(conn, ~p"/meetings")

      {rendered, html} = index_ids(conn, insider)
      assert meeting.id in rendered, "positive control: the row is real and renderable"
      assert html =~ meeting.name
    end
  end

  # ── 10. External viewers on the index: INVITATION, not participation ──────

  describe "external viewers see exactly their live invites" do
    # ── The host fence, relaxed DELIBERATELY and under protest ────────────
    #
    # An external user cannot reach `/meetings` over HTTP today at all:
    # `ExternalUserScope` admits the index on the `:meet` surface only, but
    # `/meetings` is declared ONLY in the app-host router scope, and
    # `HostSurface` (`:host_surface_enforcement` is `:on` in config.exs)
    # 404s an app-scope route reached on a `meet.`-prefixed host. So it is
    # 403 on the app host and 404 on the meet host, and the admission clause
    # is unreachable.
    #
    # That is a ROUTING gap, tracked separately (019ffbb3) and explicitly not
    # this stage's to fix. Relaxing the fence here exercises the query
    # scoping as it will behave once `/meetings` is declared on the meet
    # scope. It is stated rather than quietly done, because a test that
    # switches off a production fence to reach its subject is evidence about
    # the subject, not a detail of the fixture.
    setup :relax_host_fence_and_seed_external

    test "an invited meeting is shown and an UNINVITED one in the SAME org is not",
         %{conn: conn} = ctx do
      invited = scheduled_meeting_in_org(ctx.org_id, "Invited Working Session", 9)
      uninvited = scheduled_meeting_in_org(ctx.org_id, "Internal Only Session", 14)
      invite!(invited, %{user_id: ctx.external.id})

      assert Tenancy.external_user?(ctx.external)
      assert Tenancy.member_of?(ctx.external, ctx.org_id)

      # Both halves in one test on purpose: an implementation that scoped
      # external users to their ORG would pass the first half alone, and org
      # scoping is exactly the too-broad rule this task rules out. The
      # negative row is same-org, so only externality can be denying it.
      insider_ids = listed_ids(ctx.insider)
      assert invited.id in insider_ids and uninvited.id in insider_ids

      ids = listed_ids(ctx.external)
      assert invited.id in ids, "positive control: the invited meeting is listed"
      refute uninvited.id in ids

      {rendered, html} = external_index(conn, ctx.external)
      assert invited.id in rendered
      assert html =~ invited.name
      refute uninvited.id in rendered
      refute html =~ uninvited.name
      refute html =~ uninvited.slug
    end

    test "a meeting they ATTENDED but hold no invite for is not shown",
         %{conn: conn} = ctx do
      attended = scheduled_meeting_in_org(ctx.org_id, "Attended Without Invite", 9)
      invited = scheduled_meeting_in_org(ctx.org_id, "Invited Elsewhere", 15)

      seat!(attended, ctx.external)
      invite!(invited, %{user_id: ctx.external.id})

      assert Chat.participant?(attended.chat_space_id, ctx.external.id),
             "fixture precondition: the participation really is there"

      # Participation is REAL access on the detail route — which is precisely
      # why the listing keying on it would look correct and be wrong.
      assert {:ok, _} = Meetings.fetch_meeting_for_user(ctx.external, attended.slug)

      ids = listed_ids(ctx.external)
      assert invited.id in ids, "positive control: the invited meeting is listed"
      refute attended.id in ids, "participation is not invitation"

      {rendered, html} = external_index(conn, ctx.external)
      assert invited.id in rendered
      refute attended.id in rendered
      refute html =~ attended.name
    end

    test "an invited meeting they never attended IS shown — the converse",
         %{conn: conn} = ctx do
      never_attended = scheduled_meeting_in_org(ctx.org_id, "Invited Never Attended", 10)
      invite!(never_attended, %{user_id: ctx.external.id})

      refute Chat.participant?(never_attended.chat_space_id, ctx.external.id),
             "fixture precondition: no participant row exists"

      assert never_attended.id in listed_ids(ctx.external)

      {rendered, html} = external_index(conn, ctx.external)
      assert never_attended.id in rendered
      assert html =~ never_attended.name
    end

    test "a REVOKED invite and an EXPIRED invite both disappear", %{conn: conn} = ctx do
      revoked_meeting = scheduled_meeting_in_org(ctx.org_id, "Revoked Invite Session", 9)
      expired_meeting = scheduled_meeting_in_org(ctx.org_id, "Expired Invite Session", 11)
      live_meeting = scheduled_meeting_in_org(ctx.org_id, "Live Invite Session", 13)

      revoked = invite!(revoked_meeting, %{user_id: ctx.external.id})

      invite!(expired_meeting, %{
        user_id: ctx.external.id,
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

      invite!(live_meeting, %{
        user_id: ctx.external.id,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

      # Revocation leaves the chat participant row behind — the reason the
      # rule cannot key on participation.
      seat!(revoked_meeting, ctx.external)

      assert revoked_meeting.id in listed_ids(ctx.external),
             "positive control: it is listed BEFORE revocation"

      {:ok, _} = Meetings.revoke_invite(revoked)

      ids = listed_ids(ctx.external)
      assert live_meeting.id in ids, "positive control: the live invite survives"
      refute revoked_meeting.id in ids
      refute expired_meeting.id in ids

      {rendered, html} = external_index(conn, ctx.external)
      assert live_meeting.id in rendered
      assert html =~ live_meeting.name
      refute revoked_meeting.id in rendered
      refute html =~ revoked_meeting.name
      refute expired_meeting.id in rendered
      refute html =~ expired_meeting.name
    end

    test "an invite with user_id: nil resolves on EMAIL, case-insensitively",
         %{conn: conn} = ctx do
      # `ExternalAdmission` never backfills `meeting_invites.user_id`, so a
      # listing keyed on `user_id` alone passes every other test here and
      # shows a real invitee nothing.
      invitee = user_in_org(ctx.org_id, external: true)
      matched = scheduled_meeting_in_org(ctx.org_id, "Address Matched Session", 9)
      other_address = scheduled_meeting_in_org(ctx.org_id, "Other Address Session", 14)

      invite!(matched, %{user_id: nil, email: String.upcase(invitee.email)})
      invite!(other_address, %{user_id: nil, email: "someone.else@example.com"})

      ids = listed_ids(invitee)
      assert matched.id in ids, "the email disjunct must admit the account-less invite row"
      refute other_address.id in ids

      {rendered, html} = external_index(conn, invitee)
      assert matched.id in rendered
      assert html =~ matched.name
      refute other_address.id in rendered
      refute html =~ other_address.name
    end
  end

  # ── 11. The ARCHIVE obeys the same four rules ─────────────────────────────

  describe "the archive is scoped the way the index is" do
    test "an internal viewer's archive excludes another org's ended meetings",
         %{conn: conn} do
      own = tenant_org_id("soylent") |> meeting_in_org("Soylent Archived Retro") |> ended!()
      foreign = tenant_org_id("wayne_tech") |> meeting_in_org("Wayne-Tech Archived Retro") |> ended!()

      viewer = user_in_org(tenant_org_id("soylent"))
      insider = user_in_org(tenant_org_id("wayne_tech"))

      ids = archived_ids(viewer)
      assert own.id in ids, "positive control"
      refute foreign.id in ids

      assert foreign.id in archived_ids(insider),
             "positive control: the foreign row is archived and visible to its own org"

      {rendered, html} = archive_ids(conn, viewer)
      assert own.id in rendered, "positive control: the archive page draws the own-org row"
      refute foreign.id in rendered
      assert html =~ own.name
      refute html =~ foreign.name
      refute html =~ foreign.slug
    end

    test "a Fabrikam root admin's archive spans orgs; a nil viewer's is empty", %{conn: conn} do
      a = tenant_org_id("soylent") |> meeting_in_org("Archive Root Reach A") |> ended!()
      b = tenant_org_id("wayne_tech") |> meeting_in_org("Archive Root Reach B") |> ended!()
      admin = user_in_org(fabrikam_org_id(), role: "admin")

      ids = archived_ids(admin)
      assert a.id in ids and b.id in ids

      {rendered, html} = archive_ids(conn, admin)
      assert a.id in rendered and b.id in rendered
      assert html =~ a.name and html =~ b.name

      assert archived_ids(nil) == []
    end
  end

  # ── 11b. The archive, for an EXTERNAL viewer ──────────────────────────────
  #
  # Its own describe rather than a nested one (ExUnit does not nest), sharing
  # section 10's host-fence relaxation and the objection recorded there.

  describe "the archive for an external viewer" do
    setup :relax_host_fence_and_seed_external

    test "invited is shown, uninvited in the SAME org is not", %{conn: conn} = ctx do
      invited = ctx.org_id |> meeting_in_org("Archived Invited Review") |> ended!()
      uninvited = ctx.org_id |> meeting_in_org("Archived Internal Review") |> ended!()
      invite!(invited, %{user_id: ctx.external.id})

      insider_ids = archived_ids(ctx.insider)
      assert invited.id in insider_ids and uninvited.id in insider_ids

      ids = archived_ids(ctx.external)
      assert invited.id in ids, "positive control"
      refute uninvited.id in ids

      {rendered, html} = archive_ids(conn, ctx.external, host: @meet_host)
      assert invited.id in rendered
      assert html =~ invited.name
      refute uninvited.id in rendered
      refute html =~ uninvited.name
    end

    test "attended-without-invite is hidden; invited-never-attended is shown",
         %{conn: conn} = ctx do
      attended = ctx.org_id |> meeting_in_org("Archived Attended Session") |> ended!()
      invited = ctx.org_id |> meeting_in_org("Archived Invited Absent") |> ended!()

      seat!(attended, ctx.external)
      invite!(invited, %{user_id: ctx.external.id})

      refute Chat.participant?(invited.chat_space_id, ctx.external.id),
             "fixture precondition: invited-but-absent"

      ids = archived_ids(ctx.external)
      assert invited.id in ids, "the converse: an invite never used still archives"
      refute attended.id in ids, "participation is not invitation"

      {rendered, html} = archive_ids(conn, ctx.external, host: @meet_host)
      assert invited.id in rendered
      refute attended.id in rendered
      refute html =~ attended.name
    end

    test "a revoked invite and an expired invite drop out of the archive",
         %{conn: conn} = ctx do
      revoked_meeting = ctx.org_id |> meeting_in_org("Archived Revoked") |> ended!()
      expired_meeting = ctx.org_id |> meeting_in_org("Archived Expired") |> ended!()
      live_meeting = ctx.org_id |> meeting_in_org("Archived Live Invite") |> ended!()

      revoked = invite!(revoked_meeting, %{user_id: ctx.external.id})

      invite!(expired_meeting, %{
        user_id: ctx.external.id,
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

      invite!(live_meeting, %{user_id: ctx.external.id})
      seat!(revoked_meeting, ctx.external)

      assert revoked_meeting.id in archived_ids(ctx.external),
             "positive control: archived BEFORE revocation"

      {:ok, _} = Meetings.revoke_invite(revoked)

      ids = archived_ids(ctx.external)
      assert live_meeting.id in ids, "positive control"
      refute revoked_meeting.id in ids
      refute expired_meeting.id in ids

      {rendered, html} = archive_ids(conn, ctx.external, host: @meet_host)
      assert live_meeting.id in rendered
      refute revoked_meeting.id in rendered
      refute expired_meeting.id in rendered
      refute html =~ revoked_meeting.name
    end

    test "an invite with user_id: nil matches on email in the archive too",
         %{conn: conn} = ctx do
      invitee = user_in_org(ctx.org_id, external: true)
      matched = ctx.org_id |> meeting_in_org("Archived Address Match") |> ended!()
      other = ctx.org_id |> meeting_in_org("Archived Other Address") |> ended!()

      invite!(matched, %{user_id: nil, email: String.upcase(invitee.email)})
      invite!(other, %{user_id: nil, email: "someone.else@example.com"})

      ids = archived_ids(invitee)
      assert matched.id in ids
      refute other.id in ids

      {rendered, html} = archive_ids(conn, invitee, host: @meet_host)
      assert matched.id in rendered
      refute other.id in rendered
      refute html =~ other.name
    end
  end

  # ── 12. The LIVE refresh is scoped too ────────────────────────────────────

  describe "a broadcast does not re-leak into a correctly mounted index" do
    test "a meeting-created event for a foreign meeting leaves the index unchanged",
         %{conn: conn} do
      org_id = tenant_org_id("soylent")
      viewer = user_in_org(org_id)

      {view, html} = index_html(conn, viewer)
      refute html =~ "Broadcast Foreign Meeting"

      foreign =
        scheduled_meeting_in_org(tenant_org_id("wayne_tech"), "Broadcast Foreign Meeting", 9)

      # The handler re-queries the whole list, so delivering the message is
      # enough to exercise the refresh regardless of which topics this mount
      # subscribed to.
      send(view.pid, {:meeting_created, foreign})
      after_foreign = render(view)

      refute after_foreign =~ foreign.name
      refute foreign.id in rendered_ids(after_foreign, ~s([data-role="calendar-event"]))

      # POSITIVE CONTROL, and it is the important half: the same message for
      # a meeting the viewer MAY see must appear, or the refutation above
      # only proves the refresh is dead.
      own = scheduled_meeting_in_org(org_id, "Broadcast Own Meeting", 15)
      send(view.pid, {:meeting_created, own})
      after_own = render(view)

      assert after_own =~ own.name
      assert own.id in rendered_ids(after_own, ~s([data-role="calendar-event"]))
      refute after_own =~ foreign.name

      # ── Why this test also reads the ASSIGN ───────────────────────────
      #
      # MUTATION FINDING (019f9cb7 stage 6). Restoring the unscoped read at
      # THIS call site alone changes nothing on screen: the grouped list that
      # used to render `@meetings` is gone, and the refresh re-draws the week
      # from the range query — which is scoped by a different call. So the
      # refreshed list is currently a LATENT leak: it holds foreign rows that
      # no element draws today, and the first template that renders
      # `@meetings` again ships them.
      #
      # Rendered assertions therefore cannot pin this call site, and a guard
      # that cannot fire is not a guard. The assign is read directly instead,
      # and named as the reason.
      assigns = :sys.get_state(view.pid).socket.assigns
      listed = Enum.map(assigns.meetings, & &1.id)

      assert own.id in listed, "positive control: the refreshed assign holds the own-org row"
      refute foreign.id in listed, "the refreshed list re-leaked a foreign meeting"
    end
  end
end
