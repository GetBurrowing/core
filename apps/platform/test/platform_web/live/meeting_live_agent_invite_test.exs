defmodule PlatformWeb.MeetingLiveAgentInviteTest do
  @moduledoc """
  Task 01a04c2f — the missing edge between the meeting UI and
  `Platform.Meetings.invite_agent/3`.

  ## What was actually broken

  `invite_agent/3` worked and had ZERO callers in `lib/` or `test/`. Nothing
  in the product could put an agent into a meeting, so agent voice had no way
  in. Its third parameter, `inviting_user`, was matched as `_inviting_user`
  and ignored outright.

  ## What these tests refuse to be satisfied by

  A test that asserts the rail button renders proves nothing: the whole defect
  was a control that did not exist reaching a function that was never called.
  So the load-bearing assertion here is the DISPATCH — a runtime receives
  `meeting_join` carrying a non-empty token and `agent_identity` of
  `"agent:" <> agent.slug` — and its negative, that an unauthorized viewer
  pushing the same event produces no such message at all. `refute_receive` is
  what makes the authorization assertion mean something; a flash assertion
  alone would still pass if the broadcast fired and the flash were merely
  cosmetic.

  ## Where this file was itself vacuous (task 01a04f31)

  As merged, the dispatch assertion above read

      PlatformWeb.Endpoint.subscribe("runtime:agent:\#{agent.id}")

  and that is why it stayed green over a dispatch that could reach nobody.
  An in-VM `Phoenix.PubSub` subscribe bypasses
  `PlatformWeb.RuntimeChannel.join/3` entirely, so the test process became a
  subscriber on a topic that no websocket client could ever have joined — it
  could see that a broadcast happened and could never see that the broadcast
  was unreachable. A test that subscribes directly can never discover that
  nothing could have subscribed.

  The dispatch test now stands up a REAL runtime — registered, activated,
  linked to the roster agent — connects it through
  `PlatformWeb.RuntimeSocket.connect/3`, joins the channel, and asserts the
  frame is PUSHED to that client. The dead `runtime:agent:<uuid>` topic is
  kept, subscribed, and `refute_receive`d, so a regression to it fails here
  twice. `Platform.Meetings.MeetingJoinDispatchTopicTest` carries the rest.

  ## Why the negative viewer is shaped the way it is

  `handle_params/3` admits any viewer in the meeting's org
  (`fetch_meeting_for_user/2` is an ORG visibility query, not space
  membership), so "can load the page" and "may write to the space" are
  genuinely different questions. The denied viewer here is an org member — the
  page renders for them — who holds no `chat_participants` row for the
  meeting's space, mounted with `?no_autojoin=true` so the auto-join's
  `ensure_chat_space_participant/3` never mints one. That is a real
  separation, not a contrived one: auto-join is exactly what grants the
  membership `SpaceAccess.authorize_writer/2` then finds.

  `async: false` — LiveKit config is app-env, mirroring
  `meeting_live_member_mount_test.exs`.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  # `Phoenix.ChannelTest` in a `ConnCase`: `@endpoint` is all it needs, and
  # the whole point of this file's dispatch test is that the LiveView click
  # and the websocket client have to be in the same test. Imported narrowly
  # so nothing here collides with `Phoenix.ConnTest` / `Phoenix.LiveViewTest`.
  # `connect/2` is deliberately NOT imported — `Phoenix.ConnTest` exports one
  # too and the call would be ambiguous. It is called fully qualified below;
  # the macro reads `@endpoint` from the calling module either way.
  import Phoenix.ChannelTest, only: [subscribe_and_join: 3, assert_push: 3]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Participant, as: MeetingParticipant
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "agent-invite-#{label}-#{n}@example.com",
        name: "Agent Invite #{label} #{n}",
        oidc_sub: "oidc-agent-invite-#{label}-#{n}"
      })

    # `/meetings/:slug` resolves through `fetch_meeting_for_user/2`, which
    # requires an `org_memberships` row in the meeting's org. `@example.com`
    # keeps `derive_role_from_email/1` at `:member`; a `@example.com` address
    # would derive admin and blanket-bypass every scope check below.
    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{
        user_id: user.id,
        org_id: Platform.TenancyFixtures.fabrikam_org_id(),
        role: "member"
      })
    )

    user
  end

  defp space! do
    {:ok, space} =
      Chat.create_space(%{
        name: "Agent Invite Space #{System.unique_integer([:positive])}",
        slug: "agent-invite-space-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp meeting!(space) do
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(
        Project.changeset(%Project{}, %{
          name: "Agent Invite Project #{n}",
          slug: "agent-invite-project-#{n}",
          org_id: Platform.TenancyFixtures.fabrikam_org_id()
        })
      )

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "agent-invite-meeting-#{n}",
        name: "Agent Invite Kickoff #{n}",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    meeting
  end

  # An agent ON THE SPACE ROSTER — which is where `@invitable_agents` reads
  # from. A bare `%Agent{}` row with no `chat_participants` entry would not be
  # offered by the control at all, and every assertion below would pass or
  # fail for the wrong reason.
  defp bare_roster_agent!(space) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "invitable-agent-#{n}",
        name: "Invitable Agent #{n}",
        status: "active"
      })

    {:ok, _entry} = Chat.add_space_agent(space.id, agent.id, role: "member")

    agent
  end

  # The same roster agent, plus the AgentRuntime that makes it reachable.
  #
  # This is not decoration. Since task 01a04f31 `invite_agent/3` refuses an
  # agent with no linked runtime (`{:error, :no_runtime}`) rather than writing
  # a roster row and broadcasting into the void, so the happy path here
  # REQUIRES a real runtime — and having one is what lets the dispatch test
  # below connect an actual websocket client instead of subscribing in-VM.
  #
  # `raw_token` is captured because activation is the only moment the
  # plaintext token exists; the row keeps a hash.
  defp roster_agent!(space) do
    agent = bare_roster_agent!(space)
    owner = user!("runtime-owner")

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "invite-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    # `link_agent/2` auto-rosters federated agents into every channel space,
    # so re-affirm membership idempotently rather than asserting on a row
    # that may already exist.
    {:ok, _entry} = Chat.ensure_space_agent(space.id, agent.id, role: "member")

    %{agent: agent, runtime: Federation.get_runtime(activated.id), raw_token: raw_token}
  end

  # A connected, authenticated websocket client for that runtime, joined on
  # the ONE topic `RuntimeChannel.join/3` accepts for it.
  defp join_runtime_client!(%{runtime: runtime, raw_token: raw_token}) do
    {:ok, socket} =
      Phoenix.ChannelTest.connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, channel} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
    channel
  end

  defp login(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp agent_participant_rows(space_id, agent_id) do
    Repo.all(
      from(p in MeetingParticipant,
        join: r in Platform.Meetings.Room,
        on: r.id == p.room_id,
        where: r.space_id == ^space_id and p.agent_id == ^agent_id
      )
    )
  end

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    space = space!()
    %{agent: agent} = runtime_agent = roster_agent!(space)

    %{
      space: space,
      meeting: meeting!(space),
      agent: agent,
      runtime_agent: runtime_agent,
      runtime: runtime_agent.runtime
    }
  end

  # ── The control ──────────────────────────────────────────────────────────

  describe "the invite-an-agent control" do
    test "offers each space agent and is wired to the invite event",
         %{conn: conn, meeting: meeting, agent: agent} do
      {:ok, _view, html} =
        conn |> login(user!("render")) |> live(~p"/meetings/#{meeting.slug}")

      # `LazyHTML.query/2`, NOT `filter/2` — the button is nested inside the
      # rail aside, and `filter/2` matches only a fragment's ROOT nodes, so it
      # would silently return `[]` and make every assertion here vacuous.
      buttons =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-agent-invite-button"]))

      assert LazyHTML.attribute(buttons, "data-agent-id") == [agent.id]
      assert LazyHTML.attribute(buttons, "phx-click") == ["meeting_invite_agent"]
      assert LazyHTML.attribute(buttons, "phx-value-agent-id") == [agent.id]
    end

    test "does not offer an agent that is already in the call",
         %{conn: conn, space: space, meeting: meeting, agent: agent} do
      # Same roster agent, already a live participant. The section must lose
      # its only row — otherwise a second click writes a duplicate
      # `meeting_participants` row and re-dispatches a join.
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)

      {:ok, _p} =
        Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

      {:ok, _view, html} =
        conn |> login(user!("already-in")) |> live(~p"/meetings/#{meeting.slug}")

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="meeting-agent-invite-button"]))
             |> Enum.empty?()
    end
  end

  # ── The dispatch ─────────────────────────────────────────────────────────

  describe "inviting an agent from the meeting rail" do
    test "pushes meeting_join to a runtime client that actually joined the channel",
         %{
           conn: conn,
           space: space,
           meeting: meeting,
           agent: agent,
           runtime_agent: runtime_agent
         } do
      inviter = user!("inviter")

      # The real client, through `RuntimeSocket.connect/3` and
      # `RuntimeChannel.join/3`. Everything this test asserts about delivery
      # is asserted against THIS process's pushes.
      _channel = join_runtime_client!(runtime_agent)

      # The dead topic, kept and subscribed. Nothing may arrive here.
      #
      # `subscribe_and_join/3` also subscribes THIS process to the live
      # topic, so the refutation below has to name the dead topic explicitly
      # — a bare `refute_receive %Broadcast{event: "meeting_join"}` matches
      # the legitimate broadcast and fails on a correct implementation.
      dead_topic = "runtime:agent:#{agent.id}"
      PlatformWeb.Endpoint.subscribe(dead_topic)

      {:ok, view, _html} = conn |> login(inviter) |> live(~p"/meetings/#{meeting.slug}")

      # Auto-join has to have landed before the click: it is what activates
      # the room the handler reads AND what mints the inviter's space
      # membership. `render/1` is a synchronous round trip, so the `:auto_join`
      # message ahead of it in the mailbox is fully processed by the time it
      # returns.
      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      html =
        view
        |> element(~s([data-role="meeting-agent-invite-button"]))
        |> render_click()

      room = Meetings.get_active_room(space.id)
      assert room

      # `assert_push`, not `assert_receive` on a bare subscription: this only
      # passes if the frame travelled broadcast -> joined channel process ->
      # client, which is the leg the merged version of this test skipped.
      assert_push "meeting_join", payload, 1_000

      # And the topic the code used to publish on is confirmed dead.
      refute_receive %Phoenix.Socket.Broadcast{topic: ^dead_topic}, 200

      # The three fields a voice runtime cannot connect without.
      assert payload.agent_identity == "agent:" <> agent.slug
      assert payload.room_name == room.livekit_room_name
      assert is_binary(payload.token) and payload.token != ""

      # A JWT, not just a non-empty string — the redundant pre-flight token in
      # `invite_agent/3` is discarded, so this asserts the token that is
      # actually SENT is the well-formed one.
      assert [_header, _claims, _sig] = String.split(payload.token, ".")

      # And the durable half: the agent is on the meeting roster.
      assert [%MeetingParticipant{}] = agent_participant_rows(space.id, agent.id)

      # The control has consumed its own option.
      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="meeting-agent-invite-button"]))
             |> Enum.empty?()
    end
  end

  # ── The refusal ──────────────────────────────────────────────────────────

  describe "a viewer who may see the meeting but may not write to its space" do
    test "causes no meeting_join broadcast and no roster row",
         %{conn: conn, space: space, meeting: meeting, agent: agent} do
      # The room is live and the agent is invitable — everything except this
      # viewer's authorization is in place, so a green result here cannot come
      # from the invite being impossible.
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, _room} = Meetings.activate_room(room)

      outsider = user!("outsider")

      # For a REFUTE, an in-VM subscribe on the live topic is strictly the
      # more sensitive instrument: it would catch a stray broadcast even with
      # no client connected. Subscribing to the dead `runtime:agent:<uuid>`
      # topic instead — what this test used to do — is a refutation that
      # cannot fail, and proves nothing about authorization.
      {:ok, live_topic} = Meetings.meeting_join_topic(agent)
      PlatformWeb.Endpoint.subscribe(live_topic)

      # `no_autojoin=true`: auto-join would call
      # `ensure_chat_space_participant/3` and hand this viewer the very
      # membership the check looks for.
      {:ok, view, _html} =
        conn
        |> login(outsider)
        |> live(~p"/meetings/#{meeting.slug}?no_autojoin=true")

      refute Repo.get_by(Chat.Participant,
               space_id: space.id,
               participant_type: "user",
               participant_id: outsider.id
             )

      html =
        view
        |> element(~s([data-role="meeting-agent-invite-button"]))
        |> render_click()

      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_join"}, 300

      assert agent_participant_rows(space.id, agent.id) == []
      assert html =~ "do not have permission"
    end

    test "the context refuses the same invite directly, whatever the caller",
         %{space: space, agent: agent} do
      # The LiveView test above can only exercise the handler's own arguments.
      # This one pins the guard where it actually lives, so a future caller
      # that never goes through `MeetingLive` inherits it.
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)

      stranger = user!("stranger")

      assert {:error, :forbidden} = Meetings.invite_agent(room, agent, stranger)
      assert {:error, :forbidden} = Meetings.invite_agent(room, agent, {:user, stranger.id})

      # `nil` is no principal, not a bypass — `SpaceAccess.normalize_actor/1`
      # has no clause promoting an unknown shape, and this is the shape the
      # parameter carried for its whole life as `_inviting_user`.
      assert {:error, :forbidden} = Meetings.invite_agent(room, agent, nil)

      assert agent_participant_rows(space.id, agent.id) == []

      # Positive control on the identical call: with a space membership the
      # very same invite succeeds, so the three refusals above are about the
      # ACTOR and not about the room, the agent, or LiveKit config.
      {:ok, _member_row} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: stranger.id,
          display_name: stranger.name,
          joined_at: DateTime.utc_now()
        })

      assert {:ok, %MeetingParticipant{}} = Meetings.invite_agent(room, agent, stranger)
    end
  end

  # ── An agent nothing is listening for (task 01a04f31) ────────────────────

  describe "an invitable agent with no linked runtime" do
    test "is refused with a specific flash and leaves no roster row",
         %{conn: conn, space: space, meeting: meeting} do
      # On the space roster, so the control offers it — but with no
      # AgentRuntime, so no topic exists that any client could be listening
      # on. Before this task the invite "succeeded": a participant row, a
      # green flash, and a broadcast nobody received.
      orphan = bare_roster_agent!(space)

      {:ok, view, _html} =
        conn |> login(user!("orphan-inviter")) |> live(~p"/meetings/#{meeting.slug}")

      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      html =
        view
        |> element(~s([data-role="meeting-agent-invite-button"][data-agent-id="#{orphan.id}"]))
        |> render_click()

      assert html =~ "no connected runtime"
      refute html =~ "is joining the meeting"

      assert agent_participant_rows(space.id, orphan.id) == []

      # The control is still there to try again once a runtime connects —
      # which it would NOT be if a participant row had been written, since
      # `invitable_agents/2` excludes agents already in the call.
      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(
               ~s([data-role="meeting-agent-invite-button"][data-agent-id="#{orphan.id}"])
             )
             |> Enum.any?()
    end

    test "the context refuses it directly, for an authorized caller",
         %{space: space} do
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)

      orphan = bare_roster_agent!(space)
      inviter = user!("orphan-context")

      {:ok, _member} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: inviter.id,
          display_name: inviter.name,
          joined_at: DateTime.utc_now()
        })

      # Not `:forbidden` — the caller is authorized. The refusal is about the
      # agent being unreachable, and the two must stay distinguishable
      # because only one of them is the user's fault.
      assert {:error, :no_runtime} = Meetings.invite_agent(room, orphan, inviter)
      assert agent_participant_rows(space.id, orphan.id) == []
    end
  end
end
