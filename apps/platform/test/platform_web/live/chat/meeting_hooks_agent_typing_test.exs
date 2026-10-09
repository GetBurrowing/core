defmodule PlatformWeb.ChatLive.MeetingHooksAgentTypingTest do
  @moduledoc """
  Task 01a05b14 stage 5, round 2 — `{:agent_typing, …}` reaches the
  quickmeet rail.

  The e2e reviewer, on a build where the crash-remount loop from round 1
  was already fixed, still saw the in-chat quickmeet read the Writer row
  as "Idle" where `/meetings` read "Writing" — while the chat composer on
  the SAME page showed "Writer is thinking…" from the SAME broadcast. The
  only fold of `{:agent_typing, …}` into `AgentActivity` was
  `MeetingLive.handle_info/2`; `MeetingHooks` folded `{:agent_activity, …}`
  only, and nothing ever broadcasts `:typing` on the meeting topic. The
  quickmeet rail could not show "Writing" by any path.

  These tests drive a REAL mounted `ChatLive` and broadcast through
  `Platform.Chat.PubSub.broadcast_agent_typing/3` — the function
  `AgentResponder` and `RuntimeChannel` now call — rather than a
  hand-built tuple, so the payload asserted on here is the payload
  production sends. They assert the rendered rail row, not an assign,
  because the defect was a missing consumer and only the row can show
  that the consumer is wired.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings
  alias Platform.Meetings.AgentActivity
  alias Platform.Meetings.Meeting
  alias Platform.Repo

  setup %{conn: conn} do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "agent-typing-#{n}@example.com",
        name: "Ada Typing",
        oidc_sub: "oidc-agent-typing-#{n}"
      })

    {:ok, space} =
      Chat.create_space(%{
        name: "Agent Typing #{n}",
        slug: "agent-typing-#{n}",
        kind: "channel"
      })

    # A LIVE `meetings` row bound to the space. Without it `join_call_shell/2`
    # has no meeting to hydrate and `:quickmeet_meeting_id` stays nil — the
    # guard the fold sits behind — so the rail would be data-less for a
    # reason unrelated to this round.
    meeting = seed_live_meeting(space)

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, conn: conn, user: user, space: space, meeting: meeting}
  end

  defp seed_live_meeting(space) do
    {:ok, project} =
      %Platform.Tasks.Project{}
      |> Platform.Tasks.Project.changeset(%{
        name: "Typing Project #{System.unique_integer([:positive])}",
        slug: "typing-project-#{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "typing-meeting-#{System.unique_integer([:positive])}",
        name: "Typing Meeting",
        livekit_room_name: "meeting-#{meeting_id}",
        status: "live"
      })
      |> Repo.insert()

    meeting
  end

  # An agent IN THE CALL: a live `meeting_participants` row (what the rail
  # iterates) keyed by `agents.id`. Returns the rail row id and the agent.
  defp seat_agent_in_call(space, display_name) do
    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "agent-#{System.unique_integer([:positive])}",
        name: display_name,
        status: "active"
      })

    {:ok, presence} =
      Meetings.participant_joined(room, %{agent_id: agent.id, display_name: display_name})

    {presence, agent}
  end

  # The broadcast carries a `chat_participants` row id, NOT an `agents.id`
  # — two different UUIDs, both called a participant id. This is the
  # bridge's input; `seat_agent_in_call/2` seeds the rail's.
  defp seat_agent_in_chat(space, agent, display_name) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Join the quickmeet from the chat surface and prove the rail is up —
  # the DIRECTION CONTROL for every "the row reads X" claim below.
  defp join(conn, space, meeting) do
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
    render_click(view, "meeting_join", %{})

    assert assigns(view).in_meeting
    assert assigns(view).quickmeet_meeting_id == meeting.id
    assert has_element?(view, "#quickmeet-call-rail")

    view
  end

  defp frag(html), do: LazyHTML.from_fragment(html)

  defp rail_row(html, presence_id),
    do: ~s(#quickmeet-call-rail [data-participant-id="#{presence_id}"])

  # Mirrors `MeetingLiveTest.rail_activity_word/2`: the badge WORD under
  # the name, the same contract `/meetings` is held to — the state half
  # (`.i`) of the line, not the held-row "Listening…" crossfade (`.l`).
  defp rail_activity_word(html, presence_id) do
    html
    |> frag()
    |> LazyHTML.query(~s(#{rail_row(html, presence_id)} [data-role="agent-activity-word"] .i))
    |> LazyHTML.text()
    |> String.trim()
  end

  # The `:delayed` reason (task 01a07400 stage 3) — a node of its own,
  # following the word on the Ask mockup's one `.st` line.
  defp rail_delay_reason(html, presence_id) do
    html
    |> frag()
    |> LazyHTML.query(
      ~s(#{rail_row(html, presence_id)} [data-role="agent-activity-delay-reason"])
    )
    |> LazyHTML.text()
    |> String.trim()
  end

  # And the ring around the face — `data-activity-state` on the avatar.
  defp rail_activity_state(html, presence_id) do
    html
    |> frag()
    |> LazyHTML.query(~s(#{rail_row(html, presence_id)} [data-role="agent-activity-avatar"]))
    |> LazyHTML.attribute("data-activity-state")
  end

  defp count(html, selector), do: html |> frag() |> LazyHTML.query(selector) |> Enum.count()

  describe "agent typing on the quickmeet rail" do
    test "a typing broadcast for an agent in the call reads Writing, and clears to Idle", %{
      conn: conn,
      space: space,
      meeting: meeting
    } do
      {presence, agent} = seat_agent_in_call(space, "Writer")
      chat_participant = seat_agent_in_chat(space, agent, "Writer")

      view = join(conn, space, meeting)
      html = render(view)

      # The row is there and quiet before any signal — so a later
      # "Writing" is a change, not a default.
      assert count(html, rail_row(html, presence.id)) == 1
      assert rail_activity_word(html, presence.id) == "Idle"
      assert rail_activity_state(html, presence.id) == ["idle"]

      :ok = ChatPubSub.broadcast_agent_typing(space.id, chat_participant.id, true)
      typing_html = render(view)

      # The process that took the broadcast is the process that answers.
      #
      # `=~`, not `==`: task 01a06e07 stage 3 appends an age counter (and,
      # for this agent, a delay clause — it has no linked voice worker in
      # this test's fixture) to the SAME word node, in the SAME slot the
      # bare word used to occupy alone. The word itself is still the
      # thing this test is about.
      assert Process.alive?(view.pid)

      # CHANGED in task 01a07400 stage 3, and CORRECTED later in the same
      # stage. This fixture's agent has NO runtime row at all, which makes
      # two specific causes true at once; the `cond` order decided which
      # was shown. It used to read "no voice worker in this room"; that
      # clause is no longer promotable to a state — it does not hold up
      # typing, and `:speaking` is not delayable, so it had no true
      # configuration as one (see `AgentDelayReason.specific_for_agent/1`).
      # The row is still `:delayed`, now carrying the cause that IS true
      # here: nothing is reachable for this agent.
      #
      # What this test is about — that the process which took the broadcast
      # is the process that answers — is proved by the row CHANGING from
      # the "Idle"/["idle"] pair asserted above, and by the signal read
      # directly off the live socket's own struct below, which still says
      # `:typing`. The delay qualifies that signal; it does not replace
      # what produced it.
      assert rail_activity_word(typing_html, presence.id) =~ "Delayed"
      refute rail_activity_word(typing_html, presence.id) =~ "Idle"
      assert rail_activity_state(typing_html, presence.id) == ["delayed"]
      assert rail_delay_reason(typing_html, presence.id) =~ "agent went offline"
      assert AgentActivity.for_agent(assigns(view).agent_activity, agent.id) == :typing

      # The SAME broadcast still drives the composer on the same page —
      # the pre-existing consumer this fold was added alongside, not
      # instead of. (Round 2's whole finding was these two disagreeing.)
      assert typing_html =~ "is thinking"

      # typing=false clears it — the row returns to Idle, not to a stale
      # Writing that a remount would be needed to shift.
      :ok = ChatPubSub.broadcast_agent_typing(space.id, chat_participant.id, false)
      idle_html = render(view)

      assert rail_activity_word(idle_html, presence.id) == "Idle"
      assert rail_activity_state(idle_html, presence.id) == ["idle"]
      assert AgentActivity.for_agent(assigns(view).agent_activity, agent.id) == :idle
      refute idle_html =~ "is thinking"
    end

    test "a typing broadcast for an agent NOT in the call changes nothing on the rail", %{
      conn: conn,
      space: space,
      meeting: meeting
    } do
      {presence, in_call_agent} = seat_agent_in_call(space, "In Call")
      _in_call_chat = seat_agent_in_chat(space, in_call_agent, "In Call")

      # Seated in the CHAT only — a member of the space with no
      # `meeting_participants` row, so the rail has no row for it.
      outsider =
        Repo.insert!(%Platform.Agents.Agent{
          slug: "agent-#{System.unique_integer([:positive])}",
          name: "Outsider",
          status: "active"
        })

      outsider_chat = seat_agent_in_chat(space, outsider, "Outsider")

      view = join(conn, space, meeting)
      before = render(view)
      rows_before = count(before, ~s(#quickmeet-call-rail [data-participant-type="agent"]))
      assert rows_before == 1

      :ok = ChatPubSub.broadcast_agent_typing(space.id, outsider_chat.id, true)
      after_html = render(view)

      assert Process.alive?(view.pid)
      # No row appeared for the outsider, and the in-call agent's row did
      # not pick up the outsider's signal.
      assert count(after_html, ~s(#quickmeet-call-rail [data-participant-type="agent"])) ==
               rows_before

      assert count(after_html, ~s(#quickmeet-call-rail [data-agent="agent:#{outsider.id}"])) == 0
      assert rail_activity_word(after_html, presence.id) == "Idle"
      assert rail_activity_state(after_html, presence.id) == ["idle"]
      assert AgentActivity.for_agent(assigns(view).agent_activity, in_call_agent.id) == :idle
    end

    test "a typing broadcast before the viewer has joined does not touch the activity value",
         %{conn: conn, space: space} do
      {_presence, agent} = seat_agent_in_call(space, "Early")
      chat_participant = seat_agent_in_chat(space, agent, "Early")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      refute assigns(view).in_meeting
      assert assigns(view).quickmeet_meeting_id == nil

      :ok = ChatPubSub.broadcast_agent_typing(space.id, chat_participant.id, true)
      html = render(view)

      # The composer still consumes it (the pre-existing path) …
      assert Process.alive?(view.pid)
      assert html =~ "is thinking"
      # … but nothing is folded into a call this socket is not in. The
      # guard is on the quickmeet binding, not on `:in_meeting` alone.
      assert assigns(view).agent_activity == AgentActivity.new()
    end

    test "a human's typing and a malformed participant id light no agent row", %{
      conn: conn,
      space: space,
      meeting: meeting,
      user: user
    } do
      {presence, agent} = seat_agent_in_call(space, "Writer")
      _chat = seat_agent_in_chat(space, agent, "Writer")

      view = join(conn, space, meeting)

      # The joiner's own chat participant row (`do_join/1` seats it and
      # assigns it) — a HUMAN typing in the meeting's chat. The bridge
      # returns nil for it.
      human = assigns(view).current_participant
      assert %{participant_type: "user", participant_id: user_id} = human
      assert user_id == user.id

      :ok = ChatPubSub.broadcast_agent_typing(space.id, human.id, true)
      assert rail_activity_word(render(view), presence.id) == "Idle"

      # Not a UUID at all: `agent_id_for_chat_participant/1` must answer
      # nil rather than let `Repo.get/2` raise inside the LiveView.
      :ok = ChatPubSub.broadcast_agent_typing(space.id, "not-a-uuid", true)
      assert Process.alive?(view.pid)
      assert rail_activity_word(render(view), presence.id) == "Idle"

      # An unknown but well-formed id: no participant behind it.
      :ok = ChatPubSub.broadcast_agent_typing(space.id, Ecto.UUID.generate(), true)
      assert Process.alive?(view.pid)
      assert rail_activity_word(render(view), presence.id) == "Idle"
      assert has_element?(view, "#quickmeet-call-rail")
    end
  end

  # Task 01a06e07 stage 3, correction 1: "A tick that lives only in
  # MeetingLive leaves the quickmeet frozen." `join_call_shell/2` arms
  # `MeetingHooks`' own `:agent_activity_tick` loop the moment a REAL
  # quickmeet is joined (this file's `join/2`); these tests drive that
  # real message through the real mounted `ChatLive` process rather than
  # asserting on `participant_rail.ex` in isolation, because the trap this
  # closes is specifically "the markup is right but nothing re-renders
  # it".
  describe "the quickmeet's agent-activity tick" do
    test "a real :agent_activity_tick message advances @agent_activity_now on the LIVE process",
         %{conn: conn, space: space, meeting: meeting} do
      view = join(conn, space, meeting)

      before = assigns(view).agent_activity_now
      assert %DateTime{} = before

      send(view.pid, :agent_activity_tick)
      # `render/1` is a synchronous round trip through the SAME process
      # mailbox `send/2` just enqueued onto — the process handles both in
      # arrival order, so by the time this call returns, the tick's
      # `handle_info/2` clause has already run.
      _html = render(view)

      after_tick = assigns(view).agent_activity_now

      assert DateTime.compare(after_tick, before) == :gt,
             "the tick fired but @agent_activity_now did not move — the clock " <>
               "`<.participant_rail>` ages against would be frozen"
    end

    test "the tick is what turns a stuck agent's rail row into Couldn't on the quickmeet",
         %{conn: conn, space: space, meeting: meeting} do
      {presence, agent} = seat_agent_in_call(space, "Ticker")
      view = join(conn, space, meeting)

      :ok = AgentActivity.broadcast(meeting.id, :computing, agent.id, true)
      html = render(view)
      # "Delayed", not "Thinking" — this fixture seats no voice worker, and
      # task 01a07400 stage 2 makes that a state rather than a note. The
      # CLOCK is what this test is about, and `:delayed` keeps the age of
      # the state it qualifies, so the ceiling below still fires unchanged.
      assert rail_activity_word(html, presence.id) =~ "Delayed"
      refute html =~ "Couldn&#39;t"

      # Backdate the stamp past `AgentActivity.ceiling_seconds/0` (120s)
      # DIRECTLY on the live process's own struct — no clock is mocked, no
      # process is restarted, this is the exact same `%AgentActivity{}`
      # the running quickmeet already holds, just as if 121 real seconds
      # had passed since the broadcast above.
      #
      # THROUGH `Phoenix.Component.assign/3`, not a bare `put_in` on the
      # raw state: LiveView's diff engine decides whether to re-invoke a
      # nested function component by consulting `socket.assigns.__changed__`
      # — bookkeeping `assign/3` maintains and a raw mutation of
      # `state.socket.assigns` bypasses. A `put_in` that skips it changes
      # the VALUE but leaves `:agent_activity` looking untouched to the
      # diff, and the next render silently reuses the pre-backdate content
      # for that attribute — a real trap this test tripped over verifying
      # itself, not something a production caller can hit (every real
      # mutation of `:agent_activity` already goes through `assign/3` or
      # `update/3`, in `MeetingHooks.apply_agent_activity/2`).
      stale_at = DateTime.add(DateTime.utc_now(), -(AgentActivity.ceiling_seconds() + 1), :second)

      :sys.replace_state(view.pid, fn state ->
        activity = state.socket.assigns.agent_activity
        backdated = %{activity | computing: Map.put(activity.computing, agent.id, stale_at)}
        %{state | socket: Phoenix.Component.assign(state.socket, :agent_activity, backdated)}
      end)

      assert :sys.get_state(view.pid).socket.assigns.agent_activity.computing[agent.id] ==
               stale_at

      # CORRECTED, task 01a077e7 stage 1. This comment used to claim the
      # tick is load-bearing here. On the quickmeet it is NOT: the
      # `assign/3` above already changed `:agent_activity`, which IS
      # passed at the `<.meeting_panel>` call site, so the panel is
      # re-diffed on that change alone, and `<.participant_rail>` falls
      # back to `DateTime.utc_now/0` when `:now` is nil. This test passed
      # on the build that never threaded `:agent_activity_now` through at
      # all, so it is not a guard for that defect — the
      # "an ETS-only :speaking becomes visible on a bare tick" test below
      # is. Kept as written because what it DOES cover, the 120-second
      # ceiling turning a stuck row into "Couldn't", is real.
      send(view.pid, :agent_activity_tick)
      capped_html = render(view)

      # The reason is "agent went offline", not the generic duration —
      # this fixture's agent has no linked `AgentRuntime` at all, and
      # `failed_reason/2` checks `Meetings.runtime_offline?/1` (a real,
      # honest check) before falling back to "no response for <duration>".
      assert rail_activity_word(capped_html, presence.id) =~ "Couldn't"
      assert rail_activity_word(capped_html, presence.id) =~ "agent went offline"
      assert rail_activity_state(capped_html, presence.id) == ["failed"]
    end
  end

  # ── Task 01a077e7 stage 1 ────────────────────────────────────────────
  #
  # The clock existed; the WIRE did not. `MeetingHooks` has armed and
  # re-armed `:agent_activity_tick` since task 01a06e07, and
  # `Partials.meeting_panel/1` has always read `:agent_activity_now` for
  # the rail's `now=` — but it read it as `assigns[:agent_activity_now]`,
  # declared no such attr, and `chat_live.html.heex` passed no such value.
  # A function component is re-invoked only when something passed AT ITS
  # CALL SITE changes, so a tick changed nothing the diff could see and
  # the whole `<.meeting_panel>` subtree was skipped. The rail therefore
  # repainted only when some OTHER passed assign happened to change.
  #
  # The state that makes this visible is `:speaking`: `mark_speaking/4`
  # writes ETS and `agent_activity.ex` broadcasts only `:computing` and
  # `:failed`, so nothing about a `:speaking` touches an assign. On the
  # broken build it could never reach this screen by itself.
  describe "the quickmeet rail repaints on the tick alone (the meeting_panel wire)" do
    test "an ETS-only :speaking becomes visible with the tick as the ONLY change",
         %{conn: conn, space: space, meeting: meeting} do
      {presence, agent} = seat_agent_in_call(space, "Speaker")
      view = join(conn, space, meeting)

      before = render(view)
      assert count(before, rail_row(before, presence.id)) == 1
      assert rail_activity_word(before, presence.id) == "Idle"
      refute rail_activity_word(before, presence.id) =~ "Speaking"

      # Straight into ETS. This touches NO assign and sends NO broadcast —
      # `mark_speaking/4` is an `:ets.insert/2` and nothing else — so the
      # only thing that can carry it to the client is a re-diff of the
      # panel, and the only thing that can cause one is the tick.
      assert {:ok, %{state: :speaking}} =
               AgentActivity.mark_speaking(meeting.id, agent.id, Ecto.UUID.generate())

      # And it is genuinely not on screen yet: `render/1` reads the test
      # client's accumulated DOM, so with no diff pushed the row is still
      # the "Idle" one rendered above. This is the defect, stated as an
      # assertion.
      assert rail_activity_word(render(view), presence.id) == "Idle"

      # The tick, and NOTHING else. No broadcast, no `:sys.replace_state`,
      # no click — every one of those changes an assign that IS passed at
      # the call site, which is precisely what made the panel paint on the
      # broken build, so a test using any of them would pass there and
      # prove nothing.
      send(view.pid, :agent_activity_tick)
      html = render(view)

      assert Process.alive?(view.pid)

      assert rail_activity_word(html, presence.id) =~ "Speaking",
             "the tick advanced :agent_activity_now but the rail did not repaint — " <>
               "`<.meeting_panel>` is not being handed the clock, so LiveView " <>
               "skips its whole subtree on a tick"

      assert rail_activity_state(html, presence.id) == ["speaking"]
    end

    # A value passed to an attr the component does not declare is the
    # SHAPE of this bug, and phoenix_live_view only warns about it (see
    # `deps/phoenix_live_view/lib/phoenix_component/declarative.ex`) — a
    # warning `mix precommit` turns into an error, but only while the call
    # site is there. Pin the declaration itself so the pair cannot rot
    # back apart.
    test "meeting_panel/1 declares :agent_activity_now" do
      attrs =
        PlatformWeb.ChatLive.Partials.__components__()
        |> Map.fetch!(:meeting_panel)
        |> Map.fetch!(:attrs)
        |> Enum.map(& &1.name)

      assert :agent_activity_now in attrs
      # Anti-vacuity: the attr list is the real one, so a mistyped fetch
      # cannot make the assertion above pass against an empty list.
      assert :agent_activity in attrs
    end
  end
end
