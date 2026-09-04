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
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
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
  # the name, the same contract `/meetings` is held to.
  defp rail_activity_word(html, presence_id) do
    html
    |> frag()
    |> LazyHTML.query(~s(#{rail_row(html, presence_id)} [data-role="agent-activity-word"]))
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
      assert Process.alive?(view.pid)
      assert rail_activity_word(typing_html, presence.id) == "Writing"
      assert rail_activity_state(typing_html, presence.id) == ["typing"]
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
end
