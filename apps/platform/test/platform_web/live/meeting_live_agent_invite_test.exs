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
  import Phoenix.ChannelTest, only: [subscribe_and_join: 3, assert_push: 3, refute_push: 3]

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

      # Task 01a0691d stage 2: "dropped" means dropped from the BUTTONS, not
      # from the list. Both declared-without-voice agents are still rows,
      # blocked and explained, so the reader can find the agent that used to
      # vanish. The old assertion ("gone") is the defect this task fixes.
      rows =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(
          ~s([data-role="meeting-agent-invite-row"][data-invite-state="incapable"])
        )

      assert MapSet.new(LazyHTML.attribute(rows, "data-agent-id")) ==
               MapSet.new([text_only.id, declared_empty.id])
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

  # ── The People tab's invite section (task 01a0691d stage 2) ────────────

  defp invite_row(html, agent_id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="meeting-agent-invite-row"][data-agent-id="#{agent_id}"]))
  end

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  describe "the People tab's invite section" do
    # The defect that filed the task: an empty INVITABLE list used to remove
    # the whole block, and the founder read that as "no such feature". The
    # only roster agent here declares no voice, so the clickable list is
    # exactly empty — and the section is still there, listing it.
    test "renders with zero invitable agents",
         %{conn: conn, meeting: meeting, agent: agent, runtime: runtime} do
      {:ok, _runtime} =
        Federation.update_metadata(runtime, %{
          "client_info" => %{"product" => "openclaw", "version" => "0.1.0", "features" => []}
        })

      {:ok, view, html} =
        conn |> login(user!("zero-invitable")) |> live(~p"/meetings/#{meeting.slug}")

      # Positive control on the premise: nothing is clickable.
      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="meeting-agent-invite-button"]))
             |> Enum.empty?()

      assert has_element?(view, ~s([data-role="meeting-agent-invite"]))

      assert has_element?(
               view,
               ~s([data-role="meeting-agent-invite-row"][data-invite-state="incapable"][data-agent-id="#{agent.id}"])
             )

      refute has_element?(view, ~s([data-role="meeting-agent-invite-empty"]))
    end

    test "a text-only agent is rendered disabled with its reason and is not clickable",
         %{conn: conn, meeting: meeting, space: space} do
      %{agent: text_only} = declaring_roster_agent!(space, [])

      {:ok, view, html} =
        conn |> login(user!("text-only-row")) |> live(~p"/meetings/#{meeting.slug}")

      row = invite_row(html, text_only.id)
      assert Enum.count(row) == 1
      assert LazyHTML.attribute(row, "data-invite-state") == ["incapable"]

      assert row
             |> LazyHTML.query(~s([data-role="meeting-agent-invite-reason"]))
             |> LazyHTML.text()
             |> squish() == "No voice runtime online"

      row_html = LazyHTML.to_html(row)
      refute row_html =~ "<button"
      refute row_html =~ "phx-click"

      refute has_element?(
               view,
               ~s([data-role="meeting-agent-invite-button"][data-agent-id="#{text_only.id}"])
             )
    end

    # Since task 01a05553 the empty state means something narrower and much
    # rarer: not "this space has no agents" but "there is no ACTIVE agent
    # anywhere". Both halves have to be arranged, and both are asserted rather
    # than assumed — the point of the case is that the section survives an
    # empty list, and it would be worthless if the list were not actually
    # empty.
    test "an org with no active agents shows the empty line under the heading", %{conn: conn} do
      space = space!()
      meeting = meeting!(space)
      viewer = user!("empty-roster")

      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: viewer.id,
          joined_at: DateTime.utc_now()
        })

      for entry <- Chat.list_space_agents(space.id) do
        {:ok, _} = Chat.remove_space_agent({:user, viewer.id}, space.id, entry.agent_id)
      end

      # The setup agent lives on ANOTHER space and is still `"active"`, so it
      # would be offered here on its roster row alone. Park every agent.
      Repo.update_all(Agent, set: [status: "paused"])

      assert Chat.list_space_agents(space.id) == []
      assert Chat.list_agents_for_picker() == []

      {:ok, view, html} = conn |> login(viewer) |> live(~p"/meetings/#{meeting.slug}")

      assert has_element?(view, ~s([data-role="meeting-agent-invite"]))

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="meeting-agent-invite-empty"]))
             |> LazyHTML.text()
             |> squish() ==
               "No active agents yet. Every active agent appears here, whether or not it is already in this space."

      refute html =~ ~s(data-role="meeting-agent-invite-row")
    end

    # The gate is `user_id`, not `@shell?`. On the `meet.` host the
    # `:meet_member` session mounts a signed-in member with `chrome_mode:
    # "none"` — no shell — and that member may invite. A `@shell?` gate
    # would take the control away from exactly this viewer.
    test "a signed-in member on the meet host has no shell and still gets the section",
         %{conn: conn, meeting: meeting, agent: agent} do
      {:ok, view, _html} =
        conn
        |> login(user!("meet-member"))
        |> Map.put(:host, "meet.localhost")
        |> live("/meetings/#{meeting.slug}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.shell? == false
      assert is_binary(assigns.user_id)

      assert has_element?(view, ~s([data-role="meeting-agent-invite"]))

      assert has_element?(
               view,
               ~s([data-role="meeting-agent-invite-button"][data-agent-id="#{agent.id}"])
             )
    end
  end

  # ── The People tab follows the space roster (task 01a0691d stage 3) ─────
  #
  # `Chat.add_space_agent/3` and `remove_space_agent/3` broadcast
  # `{:roster_changed, space_id}` on `space_agents:<id>`; the page must fold it
  # without a reload. `ShellLive`'s on_mount hook used to HALT that message for
  # every view, so the discriminating mutant here is the one that stops
  # `MeetingLive` declaring `:roster_changed_downstream?` — with it, both
  # surfaces go dark at once.
  #
  # `render/1` is a synchronous call into the LiveView process and local PubSub
  # delivery is a plain `send`, so a broadcast issued BEFORE the render is
  # folded before the render answers; no sleeps.

  defp seat!(space, user) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    user
  end

  # Steer the shell's OWN roster hold away from the meeting's space.
  #
  # `ShellLive` holds `space_agents:<id>` for the viewer's newest agent-bearing
  # seated space and, since this stage, forwards `{:roster_changed, _}` to the
  # view. If that space were the meeting's, ONE registration would serve both
  # holders (`SpaceTopics` refcounts them) and the message would arrive whether
  # or not `MeetingLive` took a hold of its own — which it must, because the
  # guest surface mounts with no shell at all. A decoy created LAST is the
  # newest, so the shell picks it and this file's cases turn on MeetingLive's
  # own hold.
  defp decoy_shell_space!(viewer) do
    decoy = space!()
    seat!(decoy, viewer)

    stranger =
      Repo.insert!(%Agent{
        slug: "decoy-#{System.unique_integer([:positive])}",
        name: "Decoy",
        status: "active"
      })

    {:ok, _} = Chat.add_space_agent(decoy.id, stranger.id, role: "member")
    decoy
  end

  defp row_selector(agent_id, state),
    do:
      ~s([data-role="meeting-agent-invite-row"][data-invite-state="#{state}"][data-agent-id="#{agent_id}"])

  defp any_row_selector(agent_id),
    do: ~s([data-role="meeting-agent-invite-row"][data-agent-id="#{agent_id}"])

  # The "not in space" marker INSIDE a given agent's row. A descendant
  # selector, because the marker is nested two elements deep — the same reason
  # every LazyHTML read in this file uses `query/2` and not `filter/2`.
  defp membership_selector(agent_id),
    do: any_row_selector(agent_id) <> ~s( [data-role="meeting-agent-invite-membership"])

  # An ACTIVE agent that is deliberately NOT on this meeting's space roster —
  # the state task 01a05553 exists for. Built by rostering and then removing,
  # rather than by simply not adding: `Federation.link_agent/2` auto-rosters a
  # federated agent into every non-archived CHANNEL space, `space!/0` makes a
  # channel, and `declaring_roster_agent!/2` needs a linked runtime to have a
  # declared capability at all. "Just don't add it" would therefore be undone
  # by the link, and the test would pass for the wrong reason.
  #
  # Production reaches this state without any removal: a real meeting's
  # backing space is `kind: "meeting"` (`Meetings.create_meeting/1`) and
  # `auto_roster_federated_agent/1` only rosters into channels, so NO agent is
  # ever auto-added to a meeting's space. That is why the pre-01a05553 rail
  # was empty on every meeting ever created.
  defp off_space_agent!(space, features) do
    remover = seat!(space, user!("off-space-remover"))
    ctx = declaring_roster_agent!(space, features)

    :ok = Chat.remove_space_agent({:user, remover.id}, space.id, ctx.agent.id)

    refute ctx.agent.id in Enum.map(Chat.list_space_agents(space.id), & &1.agent_id),
           "the fixture did not actually take the agent off the space roster"

    ctx
  end

  defp row_state_and_membership(rows, agent_id) do
    case Enum.find(rows, &(&1.agent.id == agent_id)) do
      nil -> :no_row
      row -> {row.state, row.in_space?}
    end
  end

  # ── The list is the roster, not the space (task 01a05553) ────────────────
  #
  # The defect the sponsor hit live: inviting an agent to a meeting took six
  # screens. `invite_rows/2` read `Chat.list_space_agents/1` on the meeting's
  # OWN chat space, every meeting mints a fresh one, and nothing ever rosters
  # an agent into a `kind: "meeting"` space — so the list was empty on the
  # first render of every meeting, and the only way to get a clickable row was
  # to leave the call and add the agent to the space by hand.
  describe "an agent that is not in the meeting's space" do
    # THE DISCRIMINATING CASE. "The list is non-empty" would be vacuous here:
    # it is green against a build that returns every agent unconditionally,
    # which is the obvious wrong way to fix this. So this pins BOTH edges of
    # the widening in one test — the outsider is listed AND marked as a
    # non-member, and the agent that has actually arrived keeps `:in_call`
    # and stays out of the clickable list.
    #
    # `refute arrived.id in offered` cannot pass on an empty list, because
    # `assert outsider.id in offered` above it fails first.
    test "is listed and marked, while an arrived agent stays :in_call and unoffered",
         %{space: space} do
      %{agent: outsider} = off_space_agent!(space, ["meeting_voice"])
      %{agent: arrived} = declaring_roster_agent!(space, ["meeting_voice"])

      participants = [
        %{
          participant_type: "agent",
          participant_id: arrived.id,
          identity: "agent:#{arrived.slug}",
          display_name: arrived.name
        }
      ]

      rows = PlatformWeb.MeetingLive.invite_rows(space.id, participants)

      assert row_state_and_membership(rows, outsider.id) == {:invitable, false}
      assert row_state_and_membership(rows, arrived.id) == {:in_call, true}

      offered =
        space.id
        |> PlatformWeb.MeetingLive.invitable_agents(participants)
        |> Enum.map(& &1.id)

      assert outsider.id in offered
      refute arrived.id in offered
    end

    # `MeetingHooks.invite_agent_into_call/3` resolves the clicked id with
    # `Enum.find(socket.assigns[:invitable_agents], ...)`. If the outsider is
    # not in THAT list the click falls to the catch-all error branch and the
    # feature does nothing while looking finished — the single most likely way
    # to get this stage wrong. Asserted on the assign the running LiveView
    # actually holds, not on the function in isolation.
    test "is in the :invitable_agents assign, and its click is not the catch-all miss",
         %{conn: conn, space: space, meeting: meeting} do
      ctx = off_space_agent!(space, ["meeting_voice"])
      outsider = ctx.agent
      _channel = join_runtime_client!(ctx)

      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, _room} = Meetings.activate_room(room)

      viewer = seat!(space, user!("outsider-assign"))
      {:ok, view, _html} = conn |> login(viewer) |> live(~p"/meetings/#{meeting.slug}")
      _ = render(view)

      offered =
        view.pid
        |> :sys.get_state()
        |> get_in([Access.key!(:socket), Access.key!(:assigns), :invitable_agents])
        |> Enum.map(& &1.id)

      assert outsider.id in offered

      # The assign is only half the claim. `invite_agent_into_call/3` resolves
      # the clicked id against exactly that list, and a miss is SILENT — it
      # falls to the catch-all flash and the feature does nothing while
      # looking finished. So the click is driven for real and the catch-all is
      # refuted by its exact copy.
      html =
        view
        |> element(~s([data-role="meeting-agent-invite-button"][data-agent-id="#{outsider.id}"]))
        |> render_click()

      refute html =~ "That agent could not be invited."
    end

    test "renders with the marker and a clickable invite button",
         %{conn: conn, space: space, meeting: meeting, agent: member} do
      %{agent: outsider} = off_space_agent!(space, ["meeting_voice"])

      {:ok, view, html} =
        conn |> login(user!("outsider-row")) |> live(~p"/meetings/#{meeting.slug}")

      row = invite_row(html, outsider.id)
      assert Enum.count(row) == 1
      assert LazyHTML.attribute(row, "data-invite-state") == ["invitable"]

      assert row
             |> LazyHTML.query(~s([data-role="meeting-agent-invite-membership"]))
             |> LazyHTML.text()
             |> squish() == "not in space"

      # Marked, not blocked: the button is there and carries the id.
      assert row
             |> LazyHTML.query(~s([data-role="meeting-agent-invite-button"]))
             |> LazyHTML.attribute("phx-value-agent-id") == [outsider.id]

      # The negative half of the marker: an agent that IS in the space has no
      # marker at all. Without this the assertion above would pass against a
      # build that stamps every row.
      assert has_element?(view, any_row_selector(member.id))
      refute has_element?(view, membership_selector(member.id))
    end

    # An agent that is neither in the space nor `active` is not a candidate:
    # widening the list to the roster must not widen it to every row in the
    # `agents` table.
    test "a paused agent outside the space is not listed at all", %{space: space} do
      %{agent: outsider} = off_space_agent!(space, ["meeting_voice"])

      {:ok, _} =
        outsider
        |> Agent.changeset(%{status: "paused"})
        |> Repo.update()

      rows = PlatformWeb.MeetingLive.invite_rows(space.id, [])

      assert row_state_and_membership(rows, outsider.id) == :no_row
    end

    # The union half of `invitable_roster/1`. A space member whose status has
    # left `"active"` keeps its row: sourcing from the roster must never
    # DELETE a row that the space source produced, least of all one for an
    # agent standing in the call.
    test "a paused agent that is still in the space keeps its row",
         %{space: space, agent: member} do
      {:ok, _} = member |> Agent.changeset(%{status: "paused"}) |> Repo.update()

      rows = PlatformWeb.MeetingLive.invite_rows(space.id, [])

      assert row_state_and_membership(rows, member.id) == {:invitable, true}
    end
  end

  # Every `chat_participants` row for this agent on this space. A COUNT, not
  # a presence check: the duplicate-membership case below turns on there
  # being exactly one, and `Chat.get_agent_participant/2` would answer the
  # same for one row as for two.
  defp space_agent_rows(space_id, agent_id) do
    Repo.all(
      from(p in Chat.Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id
      )
    )
  end

  # ── Task 01a05553 stage 2: the click does the whole job ──────────────────

  describe "clicking an agent that is not in the meeting's space" do
    # Stage 1 made the outsider VISIBLE and clickable. This is the claim that
    # the click FINISHES: the space row and the meeting row, both, from one
    # click. Neither half alone is the feature — a space row with no invite is
    # the old manual detour done for you, and an invite with no space row is
    # what `invite_agent/3` refuses to resolve.
    #
    # The dispatch is asserted on a REAL joined runtime client, so
    # "was invited" means a frame this worker could actually receive.
    test "adds it to the space AND invites it into the room",
         %{conn: conn, space: space, meeting: meeting} do
      ctx = off_space_agent!(space, ["meeting_voice"])
      outsider = ctx.agent
      _channel = join_runtime_client!(ctx)

      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, _room} = Meetings.activate_room(room)

      # The premise, asserted rather than assumed: no space row, no meeting
      # row. Without this the assertions below would be green against a
      # fixture that never removed the agent.
      assert space_agent_rows(space.id, outsider.id) == []
      assert agent_participant_rows(space.id, outsider.id) == []

      viewer = seat!(space, user!("stage2-adder"))
      {:ok, view, _html} = conn |> login(viewer) |> live(~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-role="meeting-agent-invite-button"][data-agent-id="#{outsider.id}"]))
        |> render_click()

      # 1. The space roster, read back from the context rather than from the
      #    return value of the thing under test.
      assert [%Chat.Participant{}] = space_agent_rows(space.id, outsider.id)

      assert outsider.id in Enum.map(Chat.list_space_agents(space.id), & &1.agent_id)

      # 2. The meeting. A row AND a frame the worker could receive — the row
      #    alone is exactly the 01a04e0f lying-success shape.
      assert [%MeetingParticipant{}] = agent_participant_rows(space.id, outsider.id)
      assert_push "meeting_join", _payload, 500

      assert html =~ "waiting for it to join"
      refute html =~ "could not be invited"
      refute html =~ "do not have permission"
    end

    # ORDER. `Meetings.invite_agent/3` resolves the agent through the space
    # roster, so a build that invited first and added second would fail here
    # even though both writes eventually happen.
    test "the space row is what makes the invite resolvable at all",
         %{space: space} do
      ctx = off_space_agent!(space, ["meeting_voice"])
      outsider = ctx.agent
      _channel = join_runtime_client!(ctx)

      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)

      inviter = seat!(space, user!("stage2-order"))

      # Invite BEFORE the add — the reversed order — and the roster row is
      # still not written by it. This is the fact the ordering rests on, and
      # it is asserted against the context, not inferred from the handler.
      {:ok, %MeetingParticipant{}} = Meetings.invite_agent(room, outsider, inviter)
      assert space_agent_rows(space.id, outsider.id) == []
    end
  end

  describe "clicking an agent that is already in the meeting's space" do
    # The unchanged path. `Chat.add_space_agent/3` is idempotent, but the
    # handler must not reach it at all here — so the assertion is on the row
    # COUNT staying at one, which a second insert (or a changed uniqueness
    # story) would break.
    test "still invites, and writes no second membership row",
         %{conn: conn, space: space, meeting: meeting, runtime_agent: runtime_agent} do
      member = runtime_agent.agent
      _channel = join_runtime_client!(runtime_agent)

      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, _room} = Meetings.activate_room(room)

      assert [%Chat.Participant{} = before] = space_agent_rows(space.id, member.id)

      viewer = seat!(space, user!("stage2-member"))
      {:ok, view, _html} = conn |> login(viewer) |> live(~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-role="meeting-agent-invite-button"][data-agent-id="#{member.id}"]))
        |> render_click()

      assert [%Chat.Participant{} = unchanged] = space_agent_rows(space.id, member.id)
      assert unchanged.id == before.id
      assert unchanged.joined_at == before.joined_at

      assert [%MeetingParticipant{}] = agent_participant_rows(space.id, member.id)
      assert_push "meeting_join", _payload, 500
      assert html =~ "waiting for it to join"
    end
  end

  describe "a viewer who may not invite, clicking an agent that is not in the space" do
    # THE SECURITY CASE, and the reason it is written on the ABSENCE of the
    # membership row rather than on the flash: adding an agent to a space is
    # a real mutation, and `Chat.add_space_agent/3` authorizes nothing of its
    # own. A build that added first and authorized second returns
    # `{:error, :forbidden}` and flashes exactly the same sentence — every
    # return-value assertion stays green while the space has silently gained
    # an agent. Only `space_agent_rows(...) == []` can tell the two apart.
    #
    # The positive control is the first test in
    # "clicking an agent that is not in the meeting's space": the identical
    # click, by a seated viewer, on an identical fixture, DOES write the row.
    # So a green result here is about the actor and not about the room, the
    # agent, or the fact that nothing was ever going to be added.
    test "gets the permission error and the agent is NOT added to the space",
         %{conn: conn, space: space, meeting: meeting} do
      ctx = off_space_agent!(space, ["meeting_voice"])
      outsider = ctx.agent
      _channel = join_runtime_client!(ctx)

      # The room is live, so the `with` reaches the membership step rather
      # than dying earlier at `get_active_room/1` — otherwise this passes
      # without ever exercising the guard.
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, _room} = Meetings.activate_room(room)

      assert space_agent_rows(space.id, outsider.id) == []

      # `no_autojoin=true`: auto-join calls `ensure_chat_space_participant/3`
      # and would hand this viewer the very membership the check looks for.
      denied = user!("stage2-denied")

      {:ok, view, _html} =
        conn |> login(denied) |> live(~p"/meetings/#{meeting.slug}?no_autojoin=true")

      refute Repo.get_by(Chat.Participant,
               space_id: space.id,
               participant_type: "user",
               participant_id: denied.id
             )

      html =
        view
        |> element(~s([data-role="meeting-agent-invite-button"][data-agent-id="#{outsider.id}"]))
        |> render_click()

      assert html =~ "do not have permission"

      # The discriminating assertion.
      assert space_agent_rows(space.id, outsider.id) == []
      refute outsider.id in Enum.map(Chat.list_space_agents(space.id), & &1.agent_id)

      # And nothing reached the meeting either.
      assert agent_participant_rows(space.id, outsider.id) == []
      refute_push "meeting_join", _payload, 200
    end
  end

  describe "the People tab follows the space roster" do
    # T3.1 — an agent ADDED while the page is open appears, with the state its
    # runtime earns (declared voice -> invitable + capable).
    #
    # THIS CASE DOES NOT ISOLATE THIS STAGE'S MECHANISM, and saying so is the
    # point. `Chat.add_space_agent/3` reaches `add_participant/2`, which also
    # broadcasts `{:participant_joined, p}` on `chat:space:<id>`
    # (`chat.ex:1407`) — a topic `MeetingLive` already held and already
    # refreshed its participants on (`:3425`). So the add half was live before
    # this stage, and every mutant that removes the roster subscription leaves
    # this case GREEN. Verified, not assumed: M11 survives here.
    #
    # T3.2 below is the case that carries the surface. `remove_space_agent/3`
    # deletes the row with a bare `Repo.delete` and broadcasts ONLY
    # `{:roster_changed, _}`, so the removal genuinely rides this stage's
    # topic. Kept as a user-facing claim rather than deleted, and labelled so
    # the next reader does not mistake it for evidence.
    test "an agent added to the space appears without a reload",
         %{conn: conn, space: space, meeting: meeting} do
      viewer = seat!(space, user!("roster-add"))
      _decoy = decoy_shell_space!(viewer)
      %{agent: capable} = declaring_roster_agent!(space, ["meeting_voice"])

      # Off the roster BEFORE the mount, so its later appearance is the
      # broadcast's doing and not the mount's.
      :ok = Chat.remove_space_agent({:user, viewer.id}, space.id, capable.id)
      refute capable.id in Enum.map(Chat.list_space_agents(space.id), & &1.agent_id)

      {:ok, view, _html} = conn |> login(viewer) |> live(~p"/meetings/#{meeting.slug}")
      _ = render(view)

      # Since task 01a05553 the row is there BEFORE the add — the list is the
      # active roster, not the space — so what the add changes is the marker,
      # not the row's existence. The claim this case still carries is that the
      # rail follows the roster live; the membership marker is what it now
      # follows with.
      assert has_element?(view, row_selector(capable.id, "invitable"))
      assert has_element?(view, membership_selector(capable.id))

      {:ok, _} = Chat.add_space_agent(space.id, capable.id, role: "member")

      assert has_element?(view, row_selector(capable.id, "invitable"))
      refute has_element?(view, membership_selector(capable.id))

      assert has_element?(
               view,
               ~s([data-role="meeting-agent-invite-button"][data-agent-id="#{capable.id}"])
             )

      assert Process.alive?(view.pid)
    end

    # T3.2 — and one REMOVED is MARKED, not removed (task 01a05553).
    #
    # This is the case that carries the surface: `remove_space_agent/3`
    # deletes the row with a bare `Repo.delete` and broadcasts ONLY
    # `{:roster_changed, _}`, so it genuinely rides the roster subscription
    # rather than the `{:participant_joined, _}` the add also emits.
    #
    # Its assertion inverted with this task. An agent that leaves the space is
    # still an active agent and still invitable, so taking its row away would
    # reintroduce exactly the vanishing-row mystery 01a0554f was filed for.
    # What must change is the marker.
    test "an agent removed from the space is marked, not dropped, without a reload",
         %{conn: conn, space: space, meeting: meeting, agent: agent} do
      viewer = seat!(space, user!("roster-remove"))
      _decoy = decoy_shell_space!(viewer)

      {:ok, view, _html} = conn |> login(viewer) |> live(~p"/meetings/#{meeting.slug}")
      _ = render(view)
      assert has_element?(view, any_row_selector(agent.id))
      refute has_element?(view, membership_selector(agent.id))

      :ok = Chat.remove_space_agent({:user, viewer.id}, space.id, agent.id)

      assert has_element?(view, any_row_selector(agent.id))
      assert has_element?(view, membership_selector(agent.id))
      assert Process.alive?(view.pid)
    end

    # T3.3 — negative control: membership is THIS space's, not any space's.
    #
    # Restated for task 01a05553. The stranger is now listed here from the
    # first render, because it is an active agent — that is the point of the
    # task. What must NOT happen is its marker flipping to "member" because
    # somebody added it to a DIFFERENT space. That is the assertion a build
    # which answered `:in_space?` from "is in any space" would fail, and it is
    # reachable in a way the old refutation no longer is.
    test "membership follows this space only, not a roster change elsewhere",
         %{conn: conn, space: space, meeting: meeting, agent: agent} do
      viewer = seat!(space, user!("roster-other"))
      other_space = space!()

      stranger =
        Repo.insert!(%Agent{
          slug: "stranger-#{System.unique_integer([:positive])}",
          name: "Stranger",
          status: "active"
        })

      {:ok, view, _html} = conn |> login(viewer) |> live(~p"/meetings/#{meeting.slug}")
      _ = render(view)

      assert has_element?(view, any_row_selector(stranger.id))
      assert has_element?(view, membership_selector(stranger.id))

      {:ok, _} = Chat.add_space_agent(other_space.id, stranger.id, role: "member")

      assert has_element?(view, membership_selector(stranger.id)),
             "another space's roster row was read as membership of this meeting's space"

      # The page is still alive, and its own member is still unmarked.
      assert has_element?(view, any_row_selector(agent.id))
      refute has_element?(view, membership_selector(agent.id))
    end

    # T3.7 — an invited agent's ARRIVAL reaches the rail. The worker's own
    # `upsert_live_participant/2` matches the roster row `invite_agent/3` wrote
    # and takes the identity-backfill branch, which never broadcast before this
    # stage: the row sat on "Invite sent, no answer yet" while the agent was in
    # the call.
    test "an invited agent's arrival flips its row to in_call",
         %{conn: conn, space: space, meeting: meeting} do
      %{agent: voice} = ctx = declaring_roster_agent!(space, ["meeting_voice"])
      _channel = join_runtime_client!(ctx)

      {:ok, view, _html} = conn |> login(user!("arrival")) |> live(~p"/meetings/#{meeting.slug}")
      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      view
      |> element(~s([data-role="meeting-agent-invite-button"][data-agent-id="#{voice.id}"]))
      |> render_click()

      assert has_element?(view, row_selector(voice.id, "pending"))
      assert [_row] = agent_participant_rows(space.id, voice.id)

      room = Meetings.get_active_room(space.id)
      assert %Meetings.Room{} = room

      {:ok, arrived} =
        Meetings.upsert_live_participant(room, %{
          identity: "agent:#{voice.slug}",
          name: voice.name
        })

      # The SAME row, backfilled — not a second one.
      assert arrived.metadata["identity"] == "agent:#{voice.slug}"
      assert [_still_one] = agent_participant_rows(space.id, voice.id)

      assert has_element?(view, row_selector(voice.id, "in_call"))

      refute has_element?(
               view,
               ~s([data-role="meeting-agent-invite-button"][data-agent-id="#{voice.id}"])
             )
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

  # ── The row model (task 01a0691d stage 1) ────────────────────────────────

  # Four roster agents, one per state, inserted in the REVERSE of the order
  # `invite_rows/2` must return them in, so the roster's own `joined_at`
  # ordering cannot produce the expected order by accident: only the sort
  # can. Returns the agents by state and the participant list that puts two
  # of them in it.
  defp four_state_roster!(space) do
    %{agent: arrived} = declaring_roster_agent!(space, ["meeting_voice"])
    %{agent: incapable} = declaring_roster_agent!(space, [])
    %{agent: pending} = declaring_roster_agent!(space, ["meeting_voice"])
    %{agent: free} = declaring_roster_agent!(space, ["meeting_voice"])

    participants = [
      # Invited, never answered: a roster row and no LiveKit identity.
      %{
        participant_type: "agent",
        participant_id: pending.id,
        identity: nil,
        display_name: pending.name
      },
      # Arrived: the identity only `upsert_live_participant/2` writes.
      %{
        participant_type: "agent",
        participant_id: arrived.id,
        identity: "agent:#{arrived.slug}",
        display_name: arrived.name
      }
    ]

    %{
      free: free,
      pending: pending,
      incapable: incapable,
      arrived: arrived,
      participants: participants
    }
  end

  defp rows_for(rows, agents) do
    ids = MapSet.new(agents, & &1.id)

    rows
    |> Enum.filter(&MapSet.member?(ids, &1.agent.id))
    |> Enum.map(&{&1.agent.id, &1.state, &1.capability})
  end

  describe "invite_rows/2" do
    # T1.1 — the four states and the one order, pinned in a single equality so
    # a wrong state AND a wrong position both fail here.
    test "yields the four states, invitable first, whatever order the roster holds them in",
         %{space: space} do
      %{free: free, pending: pending, incapable: incapable, arrived: arrived} =
        fixture = four_state_roster!(space)

      rows = PlatformWeb.MeetingLive.invite_rows(space.id, fixture.participants)

      assert rows_for(rows, [free, pending, incapable, arrived]) == [
               {free.id, :invitable, :capable},
               {pending.id, :pending, :capable},
               {incapable.id, :incapable, :incapable},
               {arrived.id, :in_call, :capable}
             ]

      # Every row carries a real `%Agent{}`, not an id the template would
      # have to look up again.
      assert Enum.all?(rows, &match?(%{agent: %Agent{}}, &1))
    end

    # T1.2 — 01a0554f's ruling, kept: never declared is offered, and the row
    # says so rather than hiding the hedge inside `:invitable`.
    test "an undeclared runtime is invitable with capability :unknown",
         %{space: space, agent: undeclared} do
      rows = PlatformWeb.MeetingLive.invite_rows(space.id, [])

      assert rows_for(rows, [undeclared]) == [{undeclared.id, :invitable, :unknown}]
    end

    # T1.3 — the button list is a projection of the row model, not a second
    # predicate. Pinned as an equality on the FULL list (setup agent included)
    # so a projection that dropped or reordered anything fails.
    test "invitable_agents/2 is exactly the agents of the invitable and pending rows",
         %{space: space, agent: setup_agent} do
      %{free: free, pending: pending, participants: participants} = four_state_roster!(space)

      rows = PlatformWeb.MeetingLive.invite_rows(space.id, participants)

      expected =
        rows
        |> Enum.filter(&(&1.state in [:invitable, :pending]))
        |> Enum.map(& &1.agent)

      offered = PlatformWeb.MeetingLive.invitable_agents(space.id, participants)

      assert offered == expected

      assert Enum.map(offered, & &1.id) |> Enum.sort() ==
               Enum.sort([setup_agent.id, free.id, pending.id])
    end
  end

  describe "an agent whose runtime declared no voice" do
    # T1.4 — the refusal is the SERVER's, not the markup's. The click is
    # forged straight at the handler with an id the rail never offered, and
    # the agent's runtime has a real client on its channel, so the refutation
    # below is on a topic a wrongly-let-through invite WOULD reach
    # (`resolve_voice_target/1` routes a declared-without-voice agent to its
    # brain runtime, so a push here is exactly what a broken filter produces).
    test "is refused even when the click is forged, and nothing is dispatched",
         %{conn: conn, space: space, meeting: meeting} do
      %{agent: incapable} = incapable_ctx = declaring_roster_agent!(space, [])
      _channel = join_runtime_client!(incapable_ctx)

      {:ok, view, _html} =
        conn |> login(user!("forger")) |> live(~p"/meetings/#{meeting.slug}")

      # Auto-join has landed: the room is active, so the only thing between
      # this click and a dispatch is the invite list.
      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      # Positive control on the fixture: the agent is on the roster and the
      # rail renders it no button.
      assert incapable.id in Enum.map(Chat.list_space_agents(space.id), & &1.agent_id)

      refute has_element?(
               view,
               ~s([data-role="meeting-agent-invite-button"][data-agent-id="#{incapable.id}"])
             )

      html = render_click(view, "meeting_invite_agent", %{"agent-id" => incapable.id})

      refute_push "meeting_join", _payload, 200
      assert agent_participant_rows(space.id, incapable.id) == []
      assert html =~ "That agent could not be invited."
      refute html =~ "waiting for it to join"
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

  # ── What LiveKit sees, in the flash (task 01a06925 stage 3) ──────────────
  #
  # The roster row that lists the inviter as present is written server-side
  # before the browser connects; the flash after Invite now says whether the
  # SFU sees them. Three variants, and in every one the invite is still
  # DELIVERED — `assert_push "meeting_join"` — because the diagnostic runs
  # after `invite_agent/3` and can only lengthen the copy.

  describe "the invite flash and the media room" do
    # `ListParticipants` is made from the LiveView process, so the stub is
    # shared rather than owned by the test process.
    defp stub_livekit_participants(identities) do
      {:ok, _} = Application.ensure_all_started(:req)

      Application.put_env(
        :platform,
        :livekit_req_client,
        Req.new(plug: {Req.Test, :livekit_invite_test})
      )

      Req.Test.set_req_test_to_shared(%{})

      Req.Test.stub(:livekit_invite_test, fn conn ->
        Req.Test.json(conn, %{
          "participants" => Enum.map(identities, &%{"identity" => &1, "name" => &1})
        })
      end)

      on_exit(fn ->
        Req.Test.set_req_test_to_private(%{})
        Application.delete_env(:platform, :livekit_req_client)
      end)
    end

    defp invite_and_read_flash(conn, inviter, meeting, runtime_agent) do
      _channel = join_runtime_client!(runtime_agent)
      {:ok, view, _html} = conn |> login(inviter) |> live(~p"/meetings/#{meeting.slug}")
      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      html =
        view
        |> element(~s([data-role="meeting-agent-invite-button"]))
        |> render_click()

      # Delivered, whatever the diagnostic said.
      assert_push "meeting_join", _payload, 1_000
      html
    end

    test "LiveKit sees the inviter and two others: the flash says so, with the count",
         %{conn: conn, meeting: meeting, runtime_agent: runtime_agent} do
      inviter = user!("inviter")
      # The viewer plus TWO others — the viewer's own identity is excluded
      # from the count, so a wrong fold reads 3 (or 1), never 2.
      stub_livekit_participants(["user:#{inviter.id}", "agent:other", "user:someone-else"])

      html = invite_and_read_flash(conn, inviter, meeting, runtime_agent)

      assert html =~ "Invited"
      assert html =~ "waiting for it to join."
      assert html =~ "LiveKit sees you and 2 other(s) in the media room."
      refute html =~ "does not see you"
    end

    test "LiveKit sees only agents: the flash says the inviter is not in the media room",
         %{conn: conn, meeting: meeting, runtime_agent: runtime_agent} do
      inviter = user!("inviter")
      stub_livekit_participants(["agent:other"])

      html = invite_and_read_flash(conn, inviter, meeting, runtime_agent)

      assert html =~ "Invited"

      assert html =~
               "LiveKit does not see you in the media room yet; the agent will be speaking to nobody. Check your call connection."

      refute html =~ "LiveKit sees you"
    end

    test "LiveKit cannot be asked: the flash is the existing copy, unchanged",
         %{conn: conn, meeting: meeting, runtime_agent: runtime_agent} do
      # No stub: the configured `wss://livekit.test` does not resolve, so
      # `ListParticipants` fails in transport and presence is :unavailable.
      # The diagnostic must degrade to the old flash, not to an error.
      inviter = user!("inviter")

      html = invite_and_read_flash(conn, inviter, meeting, runtime_agent)

      assert html =~ "Invited"
      assert html =~ "waiting for it to join."
      refute html =~ "LiveKit sees you"
      refute html =~ "does not see you"
      refute html =~ "could not be invited"
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
