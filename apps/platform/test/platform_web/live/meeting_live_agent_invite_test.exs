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

  ## Where this file encoded the NEXT defect (task 01a04e0f)

  Two assertions here read a `meeting_participants` row as "the agent is in
  the call", because that is what `invitable_agents/2` read. It is not:
  `invite_agent/3` writes the row before it broadcasts, and a broadcast into
  a topic with no subscribers returns `:ok`. So a founder invited an agent
  whose voice worker had not connected, got a row and a success flash, and
  the row removed the agent from the invite list — the only control that
  could have retried. The meeting had to be abandoned.

  Those assertions now stand on ARRIVAL — `metadata["identity"]`, which only
  `Meetings.upsert_live_participant/2` (the LiveKit webhook path) ever
  writes. The load-bearing test is "an invite whose broadcast reached
  nobody": it clicks with no client on the runtime topic (asserted empty
  against the pubsub registry, not assumed), proves the control survives,
  connects the worker, clicks again, and asserts the retry is PUSHED to that
  client and that no second roster row was written.

  Its positive control lives in `the invite-an-agent control` and is written
  so it cannot pass vacuously: `refute arrived.id in offered` would be green
  on an empty list, and an empty list is the bug. The assertion pins the
  exact list instead, so it fails if the arrived agent is offered AND if the
  other roster agent is not.

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

  # A roster agent whose runtime has DECLARED a capability set.
  #
  # Written straight onto the runtime's metadata in the shape
  # `PlatformWeb.RuntimeChannel.persist_client_info/2` writes, rather than by
  # driving a real join with a `client_info` payload: the declaration is the
  # input under test here, and a channel round-trip would make these tests
  # depend on the handshake as well as on the filter.
  #
  # `features: nil` writes a `client_info` with NO `features` key — the third
  # case, a client that connected before the field existed. It is NOT the same
  # as `features: []`, and the tests below turn on that difference.
  defp declaring_roster_agent!(space, features) do
    %{agent: agent, runtime: runtime} = ctx = roster_agent!(space)

    client_info =
      %{"product" => "openclaw", "version" => "0.1.0"}
      |> then(fn ci -> if is_nil(features), do: ci, else: Map.put(ci, "features", features) end)

    {:ok, _runtime} = Federation.update_metadata(runtime, %{"client_info" => client_info})

    %{ctx | agent: agent, runtime: Federation.get_runtime(runtime.id)}
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

    # THE POSITIVE CONTROL for everything task 01a04e0f loosened. Written so
    # it cannot pass by accident: a bare `refute arrived.id in ids` is green
    # whenever the list is empty, and the list being empty is precisely the
    # bug being fixed. So the same assertion pins the list non-empty and pins
    # the OTHER roster agent present in it.
    test "does not offer an agent that has actually arrived, while still offering the others",
         %{conn: conn, space: space, meeting: meeting, agent: arrived} do
      other = bare_roster_agent!(space)

      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)

      # The real production sequence, not a shortcut: the invite writes the
      # roster row, and the LiveKit webhook then finds that same row and
      # backfills the joiner's identity onto it. `upsert_live_participant/2`
      # is the only writer of `metadata["identity"]`, which is what the
      # exclusion now reads.
      {:ok, invited_row} =
        Meetings.participant_joined(room, %{display_name: arrived.name, agent_id: arrived.id})

      {:ok, live_row} =
        Meetings.upsert_live_participant(room, %{
          identity: "agent:#{arrived.slug}",
          name: arrived.name
        })

      # Same row, backfilled — not a second one. If this ever stops holding,
      # the test below is asserting about a different row than it thinks.
      assert live_row.id == invited_row.id
      assert live_row.metadata["identity"] == "agent:#{arrived.slug}"

      {:ok, _view, html} =
        conn |> login(user!("already-in")) |> live(~p"/meetings/#{meeting.slug}")

      offered =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-agent-invite-button"]))
        |> LazyHTML.attribute("data-agent-id")

      assert offered == [other.id]
    end
  end

  # ── Retrying an invite nobody received (task 01a04e0f) ───────────────────
  #
  # `invite_agent/3` writes the participant row BEFORE it broadcasts, and
  # `Phoenix.Endpoint.broadcast/3` returns `:ok` into a topic with no
  # subscribers. So an agent whose runtime is registered but whose voice
  # worker has not connected got a roster row, a success flash, and no
  # invite — and the row then removed it from the invite list, which was the
  # only control that could have tried again.
  #
  # The zero-subscriber condition here is real and not simulated: the first
  # click happens while no client has joined `runtime:<runtime_id>`, and the
  # test asserts that emptiness against the pubsub registry rather than
  # trusting the setup.
  describe "an invite whose broadcast reached nobody" do
    test "leaves the agent invitable, marked unanswered, and the retry is received",
         %{
           conn: conn,
           space: space,
           meeting: meeting,
           agent: agent,
           runtime: runtime,
           runtime_agent: runtime_agent
         } do
      topic = "runtime:#{runtime.runtime_id}"
      assert Registry.lookup(Platform.PubSub, topic) == []

      {:ok, view, _html} =
        conn |> login(user!("retry-inviter")) |> live(~p"/meetings/#{meeting.slug}")

      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      selector = ~s([data-role="meeting-agent-invite-button"][data-agent-id="#{agent.id}"])

      after_first = view |> element(selector) |> render_click()

      # The invite "succeeded" exactly as it did for the founder: a flash, a
      # roster row, and nothing on the wire.
      #
      # The copy is now "Invited … — waiting for it to join" and the second
      # assertion is the load-bearing one (task 01a0554f): a dispatch that
      # reached nobody must not be reported as arrival. `assert` alone would
      # stay green over a flash that claimed the agent had joined.
      assert after_first =~ "waiting for it to join"
      refute after_first =~ "is joining the meeting"
      assert [_row] = agent_participant_rows(space.id, agent.id)

      # …and the control survives it. This is the whole fix. Before 01a04e0f
      # the row above deleted this button and the meeting was unrecoverable.
      first_button =
        after_first |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

      assert LazyHTML.attribute(first_button, "data-agent-id") == [agent.id]

      # And it says so, rather than looking identical to a delivered invite.
      assert LazyHTML.attribute(first_button, "data-invite-pending") == ["true"]

      # Now the worker connects — the thing that had not happened yet.
      channel = join_runtime_client!(runtime_agent)
      assert Registry.lookup(Platform.PubSub, topic) != []

      after_second = view |> element(selector) |> render_click()
      assert after_second =~ "waiting for it to join"
      refute after_second =~ "is joining the meeting"

      # The load-bearing assertion: the retry is actually DELIVERED to a
      # client that went through `RuntimeSocket.connect/3` and
      # `RuntimeChannel.join/3`, not merely broadcast.
      assert_push("meeting_join", payload, 1_000)
      assert payload.agent_identity == "agent:#{agent.slug}"
      assert is_binary(payload.token) and payload.token != ""

      # The LiveKit room the invite names is the SPACE's active room, not
      # `meeting.livekit_room_name` — `invite_agent/3` is handed
      # `get_active_room(space_id)`.
      assert payload.room_name == Meetings.get_active_room(space.id).livekit_room_name

      # Retrying must not accumulate roster rows. `participant_joined/2` is a
      # plain insert; `invite_agent/3` now reuses the row it already wrote.
      assert [_still_one] = agent_participant_rows(space.id, agent.id)

      # Silence the "channel unused" warning while keeping the binding
      # meaningful — the pushes above were asserted against this process,
      # which `subscribe_and_join/3` made the channel's owner.
      assert is_pid(channel.channel_pid)
    end
  end

  # ── The exclusion itself, against hand-built participant lists ───────────
  #
  # `invitable_agents/2` is the function the defect lived in, and driving it
  # directly is the only way to pin the cases the rendered page cannot reach
  # — notably an arrival row that carries a LiveKit identity but NO agent FK,
  # which is what a worker publishing under an unexpected display name
  # produces.
  # ── The ack that nobody read (task 01a0554f) ────────────────────────────

  describe "a runtime that answers the join with an error" do
    # End to end, through the real subscription: the click dispatches, the
    # agent's runtime answers "error", and the SCREEN changes. Before this
    # task the ack reached core's log and the invite flash stood unchallenged
    # for the rest of the call, which is how five test meetings were spent
    # waiting on an agent that had already refused.
    #
    # Driven through `Meetings.record_agent_join_ack/3` on the room name — not
    # by `send/2` into the view — so it also pins that MeetingLive is actually
    # SUBSCRIBED to the topic the ack lands on. A `send/2` would pass against a
    # view subscribed to nothing at all.
    test "turns the optimistic invite flash into a visible failure",
         %{conn: conn, space: space, meeting: meeting, agent: agent} do
      {:ok, view, _html} =
        conn |> login(user!("ack-inviter")) |> live(~p"/meetings/#{meeting.slug}")

      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      after_click =
        view
        |> element(~s([data-role="meeting-agent-invite-button"][data-agent-id="#{agent.id}"]))
        |> render_click()

      assert after_click =~ "waiting for it to join"

      room = Meetings.get_active_room(space.id)
      :ok = Meetings.record_agent_join_ack(agent.id, room.livekit_room_name, "error")

      html = render(view)

      assert html =~ "could not join the meeting"
      assert html =~ agent.name

      # The optimistic copy is GONE, not merely joined by an error beneath it.
      # A banner that says both things at once is the state the founder was
      # already in.
      refute html =~ "waiting for it to join"
    end

    # The control. If the clause fired on every ack, a working join would show
    # the user an error, which is a worse screen than the one being fixed.
    test "a successful ack leaves the screen alone",
         %{conn: conn, space: space, meeting: meeting, agent: agent} do
      {:ok, view, _html} =
        conn |> login(user!("ack-ok-inviter")) |> live(~p"/meetings/#{meeting.slug}")

      _ = render(view)

      view
      |> element(~s([data-role="meeting-agent-invite-button"][data-agent-id="#{agent.id}"]))
      |> render_click()

      room = Meetings.get_active_room(space.id)
      :ok = Meetings.record_agent_join_ack(agent.id, room.livekit_room_name, "joined")

      html = render(view)

      refute html =~ "could not join the meeting"
      assert html =~ "waiting for it to join"
    end

    # The retry documented by `invite_agent/3` has to survive the failure —
    # a red banner that also removes the only button is not a fix.
    test "the invite control survives the failure",
         %{conn: conn, space: space, meeting: meeting, agent: agent} do
      {:ok, view, _html} =
        conn |> login(user!("ack-retry-inviter")) |> live(~p"/meetings/#{meeting.slug}")

      _ = render(view)

      selector = ~s([data-role="meeting-agent-invite-button"][data-agent-id="#{agent.id}"])
      view |> element(selector) |> render_click()

      room = Meetings.get_active_room(space.id)
      :ok = Meetings.record_agent_join_ack(agent.id, room.livekit_room_name, "error")

      html = render(view)

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(selector)
             |> Enum.any?()

      assert agent_participant_rows(space.id, agent.id) != []
    end
  end

  # ── The list stops offering seats that cannot be taken (task 01a0554f) ──

  describe "the invite list and declared voice capability" do
    # The load-bearing test, and it pins the whole three-valued predicate in
    # one assertion. Asserting only "the incapable agent is gone" would be
    # green against a filter that returned `[]`, and an empty list is the
    # failure mode that would put us back where we started — with the one
    # agent that CAN join missing from the rail.
    test "offers the voice-capable and the undeclared, and drops the declared-without-voice",
         %{conn: conn, space: space, meeting: meeting, agent: setup_agent} do
      %{agent: voice} = declaring_roster_agent!(space, ["meeting_voice"])
      %{agent: text_only} = declaring_roster_agent!(space, ["system_event_prompt"])
      %{agent: declared_empty} = declaring_roster_agent!(space, [])
      %{agent: never_declared} = declaring_roster_agent!(space, nil)

      {:ok, _view, html} =
        conn |> login(user!("capability")) |> live(~p"/meetings/#{meeting.slug}")

      offered =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-agent-invite-button"]))
        |> LazyHTML.attribute("data-agent-id")
        |> MapSet.new()

      # Kept: declared voice, and never declared at all.
      assert voice.id in offered
      assert never_declared.id in offered

      # Dropped: declared its features, and voice was not among them.
      refute text_only.id in offered
      refute declared_empty.id in offered

      # And the setup agent — a runtime with no client_info written — is still
      # offered. This is the assertion that stops the filter being "hide
      # everything we are unsure about".
      assert setup_agent.id in offered
    end

    # `:incapable` is about the DECLARATION, not about reachability. An agent
    # with no runtime keeps its control and its own, actionable error, which
    # task 01a04f31 added deliberately.
    test "an agent with no linked runtime is still offered, and still explains itself",
         %{conn: conn, space: space, meeting: meeting} do
      orphan = bare_roster_agent!(space)

      {:ok, view, _html} =
        conn |> login(user!("orphan-capability")) |> live(~p"/meetings/#{meeting.slug}")

      _ = render(view)

      html =
        view
        |> element(~s([data-role="meeting-agent-invite-button"][data-agent-id="#{orphan.id}"]))
        |> render_click()

      assert html =~ "no connected runtime"
    end
  end

  describe "join_capability/1" do
    test "reads the three cases apart", %{space: space} do
      %{agent: voice} = declaring_roster_agent!(space, ["meeting_voice"])
      %{agent: text_only} = declaring_roster_agent!(space, ["system_event_prompt"])
      %{agent: declared_empty} = declaring_roster_agent!(space, [])
      %{agent: never_declared} = declaring_roster_agent!(space, nil)

      assert Meetings.join_capability(voice) == :capable
      assert Meetings.join_capability(text_only) == :incapable
      assert Meetings.join_capability(declared_empty) == :incapable
      assert Meetings.join_capability(never_declared) == :unknown
      assert Meetings.join_capability(bare_roster_agent!(space)) == :unknown
    end

    # The feature is matched exactly. A client declaring something that merely
    # contains the word must not be admitted on a substring.
    test "does not admit a near-miss feature name", %{space: space} do
      %{agent: near} = declaring_roster_agent!(space, ["meeting_voice_beta", "voice"])

      assert Meetings.join_capability(near) == :incapable
    end
  end

  describe "invitable_agents/2" do
    test "an agent with a roster row but no LiveKit identity is still invitable",
         %{space: space, agent: agent} do
      participants = [
        %{
          participant_type: "agent",
          participant_id: agent.id,
          identity: nil,
          display_name: agent.name
        }
      ]

      assert [%Agent{id: offered}] =
               PlatformWeb.MeetingLive.invitable_agents(space.id, participants)

      assert offered == agent.id

      assert PlatformWeb.MeetingLive.pending_invite_agent_ids(participants) ==
               MapSet.new([agent.id])
    end

    test "the same row, once a LiveKit identity is on it, is not invitable and not pending",
         %{space: space, agent: agent} do
      participants = [
        %{
          participant_type: "agent",
          participant_id: agent.id,
          identity: "agent:#{agent.slug}",
          display_name: agent.name
        }
      ]

      assert PlatformWeb.MeetingLive.invitable_agents(space.id, participants) == []
      assert PlatformWeb.MeetingLive.pending_invite_agent_ids(participants) == MapSet.new()
    end

    test "an identity-bearing row with no agent FK still counts as arrival",
         %{space: space, agent: agent} do
      # What `upsert_live_participant/2` inserts when nothing matches: the
      # dispatched identity is `"agent:<slug>"`, `parse_identity/1` casts the
      # suffix as a UUID and answers `:unknown`, so the row carries the
      # identity and no FK at all. An FK-only exclusion misses it entirely
      # and would offer an agent that is in the room.
      participants = [
        %{
          participant_type: "user",
          participant_id: nil,
          identity: "agent:#{agent.slug}",
          display_name: agent.name
        }
      ]

      assert PlatformWeb.MeetingLive.invitable_agents(space.id, participants) == []
    end

    test "a non-agent identity on someone else's row does not exclude the agent",
         %{space: space, agent: agent} do
      participants = [
        %{
          participant_type: "user",
          participant_id: Platform.Types.UUIDv7.generate(),
          identity: "user:#{Platform.Types.UUIDv7.generate()}",
          display_name: "A human"
        }
      ]

      assert [%Agent{id: offered}] =
               PlatformWeb.MeetingLive.invitable_agents(space.id, participants)

      assert offered == agent.id
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

      # The control is NOT consumed by its own click (task 01a04e0f). It used
      # to be, and that is what made an undelivered invite unrecoverable.
      # Delivery to the runtime channel — which this test has just proved —
      # is still not ARRIVAL: nothing has published into the LiveKit room, no
      # webhook has stamped an identity on the roster row, and this process
      # cannot tell a worker that connects from one that silently does not.
      # So the option stays, marked as unanswered.
      offered =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-agent-invite-button"]))

      assert LazyHTML.attribute(offered, "data-agent-id") == [agent.id]
      assert LazyHTML.attribute(offered, "data-invite-pending") == ["true"]
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

  # Task 01a06686 stage 2: the voice worker is its own runtime row. When
  # that row has declared `meeting_voice` but is not connected, the invite is
  # refused with a sentence that names the WORKER — not the "no connected
  # runtime" copy, which would send the operator to check a brain that is
  # perfectly fine.
  describe "an invitable agent whose voice worker is offline" do
    test "is refused with a voice-worker flash and leaves no roster row",
         %{conn: conn, space: space, meeting: meeting} do
      %{agent: agent} = roster_agent!(space)
      owner = user!("voice-owner")
      {:ok, voice, _token} = Federation.register_voice_runtime(owner.id, agent)

      # Declared voice, never connected: `RuntimePresence.online?/1` is
      # false for a runtime id no channel has ever tracked.
      {:ok, _} =
        Federation.update_metadata(voice, %{
          "client_info" => %{
            "product" => "openclaw",
            "version" => "0.1.0",
            "features" => ["meeting_voice"]
          }
        })

      {:ok, view, _html} =
        conn |> login(user!("voice-offline-inviter")) |> live(~p"/meetings/#{meeting.slug}")

      _ = render(view)

      html =
        view
        |> element(~s([data-role="meeting-agent-invite-button"][data-agent-id="#{agent.id}"]))
        |> render_click()

      assert html =~ "voice worker is offline"
      assert html =~ "#{agent.name}&#39;s voice worker is offline"
      refute html =~ "no connected runtime"
      refute html =~ "waiting for it to join"

      assert agent_participant_rows(space.id, agent.id) == []
    end
  end

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
      refute html =~ "waiting for it to join"
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
