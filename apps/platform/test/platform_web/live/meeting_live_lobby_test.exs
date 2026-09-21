defmodule PlatformWeb.MeetingLiveLobbyTest do
  @moduledoc """
  FE-17 stage 4 (task 01a07410) — the pre-join lobby, and the one claim
  it exists to make true: a mic or camera switched OFF in the lobby is
  OFF in the call.

  ## The trap these tests are written against

  Two per-screen assertions — "the lobby toggle renders off" and "the
  in-call control renders off" — can BOTH pass while the value is dropped
  between them, because each screen can be set up directly in the state
  it asserts. The load-bearing tests here drive the toggle in the lobby,
  submit Join on the SAME LiveView, and then read the in-call state and
  the `join-meeting` payload that `meeting_client.js` enters the room
  with. Before this stage the transition reset both assigns to `true`
  (`MeetingHooks.attach_guest/1` re-seeded them) and the JS connect path
  hardcoded `setMicrophoneEnabled(true)`; either alone made joining muted
  impossible, and only a test across the transition can see it.

  Kept `async: false` for the same reason as `meeting_live_guest_mount_test`:
  `put_livekit_env/0` mutates application env.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Repo
  alias Platform.Tasks

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp put_livekit_env do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
    :ok
  end

  defp create_meeting do
    org_id = Platform.TenancyFixtures.fabrikam_org_id()

    {:ok, project} =
      Tasks.create_project(%{
        name: "Lobby Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Lobby Kickoff #{System.unique_integer([:positive])}"
      })

    Repo.preload(meeting, :chat_space)
  end

  # A guest whose invite carries no display_name lands in `:name_entry`,
  # which is the lobby.
  defp open_lobby(conn) do
    put_livekit_env()
    open_lobby_for_meeting(conn, create_meeting())
  end

  # Same lobby entry, for a meeting the test already built (and, for the
  # agent-capability tests below, already populated a space roster for).
  defp open_lobby_for_meeting(conn, meeting) do
    expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
    token = GuestInvite.sign(meeting.slug, expires_at, nil)

    {:ok, view, html} =
      %{conn | host: "meet.localhost"}
      |> live("/#{meeting.slug}/#{token}")

    {view, html, meeting}
  end

  # An agent on the meeting's OWN space roster, with no runtime linked at
  # all -- `join_capability/1` answers `:unknown` for this shape, matching
  # `meeting_live_agent_invite_test.exs`'s own `bare_roster_agent!`.
  defp bare_roster_agent!(space_id, name) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "lobby-agent-#{n}",
        name: name,
        status: "active"
      })

    {:ok, _entry} = Chat.add_space_agent(space_id, agent.id, role: "member")

    agent
  end

  # The same roster agent, with a linked runtime that has DECLARED a
  # capability set -- mirrors `meeting_live_agent_invite_test.exs`'s own
  # `roster_agent!` + `declaring_roster_agent!`, written straight onto the
  # runtime's metadata rather than driven through a real channel join, for
  # the same reason that file gives: the declaration is the input under
  # test, not the handshake that would produce one.
  defp declaring_roster_agent!(space_id, name, features) do
    agent = bare_roster_agent!(space_id, name)
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "lobby-agent-owner-#{n}@example.com",
        name: "Lobby Agent Owner #{n}",
        oidc_sub: "oidc-lobby-agent-owner-#{n}"
      })

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{runtime_id: "lobby-agent-rt-#{n}"})

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    # `link_agent/2` auto-rosters federated agents into every channel
    # space, so re-affirm membership idempotently rather than asserting on
    # a row that may already exist -- matching the sibling fixture's own
    # comment on why this call is here.
    {:ok, _entry} = Chat.ensure_space_agent(space_id, agent.id, role: "member")

    client_info =
      %{"product" => "openclaw", "version" => "0.1.0"}
      |> then(fn ci -> if is_nil(features), do: ci, else: Map.put(ci, "features", features) end)

    {:ok, _runtime} =
      Federation.update_metadata(Federation.get_runtime(activated.id), %{
        "client_info" => client_info
      })

    agent
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp toggle(view, role) do
    view
    |> element(~s([data-role="#{role}"]))
    |> render_click()
  end

  defp join(view, name \\ "Jane Doe") do
    view
    |> form(~s([data-role="meeting-lobby-join-form"]), %{"guest" => %{"name" => name}})
    |> render_submit()
  end

  # ── The lobby renders ──────────────────────────────────────────────────

  describe "a guest reaches the lobby" do
    test "the name-entry state renders the lobby with preview, both toggles ON, and one Join action",
         %{conn: conn} do
      {view, html, meeting} = open_lobby(conn)

      assert assigns(view).state == :name_entry
      assert html =~ ~s(data-role="meeting-lobby")
      assert html =~ meeting.name
      assert html =~ ~s(data-role="meeting-lobby-preview")
      assert html =~ ~s(phx-hook="MeetingLobbyPreview")
      assert html =~ ~s(data-role="meeting-lobby-mic")
      assert html =~ ~s(data-role="meeting-lobby-camera")
      assert html =~ ~s(data-role="meeting-lobby-join")
      assert html =~ ~s(data-role="meeting-lobby-roster")
      assert html =~ "Nobody is in the call yet."

      # Both toggles start ON: the pre-lobby default, stated in words.
      assert has_element?(view, ~s([data-role="meeting-lobby-mic"][data-on="true"]))
      assert has_element?(view, ~s([data-role="meeting-lobby-camera"][data-on="true"]))
      assert html =~ "Mic on"
      assert html =~ "Camera on"

      # No LiveKit client yet — the room does not exist until Join.
      refute html =~ ~s(id="meeting-client")
    end

    test "it is a mobile-first single column whose Join action clears the safe-area inset and carries no shell-chrome term",
         %{conn: conn} do
      {view, html, _meeting} = open_lobby(conn)

      # Mobile-first: the column is capped at max-w-md and fills the
      # viewport; nothing is gated behind a desktop breakpoint.
      assert has_element?(view, ~s([data-role="meeting-lobby"].max-w-md))

      # The Join bar sits at the bottom and pads for the safe-area inset.
      assert html =~ "pb-[calc(1rem+env(safe-area-inset-bottom))]"

      # Guest surface has no shell chrome, so no bottom-nav term here —
      # meeting_live_test's chrome-escape test refutes the literal in guest
      # documents; this pins the SAME rule on the lobby.
      refute html =~ "bottom-nav"

      # The toggles keep a 44px short axis.
      assert has_element?(view, ~s([data-role="meeting-lobby-mic"].min-h-11))
      assert has_element?(view, ~s([data-role="meeting-lobby-camera"].min-h-11))
    end

    test "the lobby names who is already in the call", %{conn: conn} do
      put_livekit_env()
      meeting = create_meeting()

      # `active_participants_for_space/1` reads the space's ACTIVE room, and
      # `ensure_room/1` alone leaves it pending — the SFU webhook normally
      # activates it.
      {:ok, room} = Meetings.ensure_room(meeting.chat_space_id)
      {:ok, room} = Meetings.activate_room(room)

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{
          identity: "guest:already-here",
          name: "Ada Lovelace (guest)"
        })

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil)

      {:ok, _view, html} =
        %{conn | host: "meet.localhost"}
        |> live("/#{meeting.slug}/#{token}")

      assert html =~ "Ada Lovelace (guest) is already in the call."
      refute html =~ "Nobody is in the call yet."
    end

    test "the roster line counts, names, and never renders a blank name" do
      alias PlatformWeb.MeetingLive

      assert MeetingLive.lobby_roster_line([]) == "Nobody is in the call yet."

      assert MeetingLive.lobby_roster_line([%{display_name: "Ada"}]) ==
               "Ada is already in the call."

      assert MeetingLive.lobby_roster_line([%{display_name: "Ada"}, %{display_name: "Grace"}]) ==
               "Ada and Grace are already in the call."

      assert MeetingLive.lobby_roster_line([
               %{display_name: "Ada"},
               %{display_name: "Grace"},
               %{display_name: "Linus"}
             ]) == "Ada and 2 others are already in the call."

      # An unresolved name (nil / blank) is still a person, never a blank.
      assert MeetingLive.lobby_roster_line([%{display_name: nil}]) ==
               "Someone is already in the call."

      assert MeetingLive.lobby_roster_line([%{display_name: ""}]) ==
               "Someone is already in the call."
    end

    test "lobby_agent_rows/1 keeps only rows this meeting's space actually has as a member" do
      alias PlatformWeb.MeetingLive

      member = %{agent: %{id: "a"}, state: :invitable, capability: :capable, in_space?: true}
      outsider = %{agent: %{id: "b"}, state: :invitable, capability: :capable, in_space?: false}

      assert MeetingLive.lobby_agent_rows([member, outsider]) == [member]
      assert MeetingLive.lobby_agent_rows([outsider]) == []
      assert MeetingLive.lobby_agent_rows([]) == []
    end

    test "lobby_agent_capability_line/1 answers the two known capabilities and stays silent on unknown" do
      alias PlatformWeb.MeetingLive

      assert MeetingLive.lobby_agent_capability_line(:capable) == "Voice runtime online"
      assert MeetingLive.lobby_agent_capability_line(:incapable) == "No voice runtime online"
      assert MeetingLive.lobby_agent_capability_line(:unknown) == nil
    end
  end

  # ── The lobby's own agent list (the meeting-vs-mockups audit's gap) ────
  #
  # The mock built the pre-join screen specifically so a member sees, before
  # anyone joins, whether an agent in the meeting can actually hear them --
  # "the exact failure that bit you mid-call that night" (an agent silently
  # unable to hear the room, discovered only once it mattered). These are the
  # cases that prove the fix reads the real capability rather than a
  # hardcoded line.
  describe "the lobby's agent list" do
    test "a capable agent's name and \"Voice runtime online\" both render", %{conn: conn} do
      put_livekit_env()
      meeting = create_meeting()
      agent = declaring_roster_agent!(meeting.chat_space_id, "Saru", [Meetings.voice_feature()])

      {_view, html, _meeting} = open_lobby_for_meeting(conn, meeting)

      assert html =~ ~s(data-role="meeting-lobby-agents")
      assert html =~ ~s(data-agent-id="#{agent.id}")
      assert html =~ ~s(data-capability="capable")
      assert html =~ "Saru"
      assert html =~ "Voice runtime online"
    end

    test "an incapable agent's name and \"No voice runtime online\" both render", %{conn: conn} do
      put_livekit_env()
      meeting = create_meeting()
      _agent = declaring_roster_agent!(meeting.chat_space_id, "Higgins", ["some_other_feature"])

      {_view, html, _meeting} = open_lobby_for_meeting(conn, meeting)

      assert html =~ ~s(data-capability="incapable")
      assert html =~ "Higgins"
      assert html =~ "No voice runtime online"
    end

    test "an agent with no runtime at all shows its name and NO capability line", %{conn: conn} do
      put_livekit_env()
      meeting = create_meeting()
      _agent = bare_roster_agent!(meeting.chat_space_id, "Geordi")

      {_view, html, _meeting} = open_lobby_for_meeting(conn, meeting)

      assert html =~ ~s(data-capability="unknown")
      assert html =~ "Geordi"
      refute html =~ "Voice runtime online"
      refute html =~ "No voice runtime online"
    end

    test "a human-only meeting renders no agent list at all", %{conn: conn} do
      {_view, html, _meeting} = open_lobby(conn)

      refute html =~ ~s(data-role="meeting-lobby-agents")
    end

    test "TWO agents, one of each capability, both render on their own line", %{conn: conn} do
      put_livekit_env()
      meeting = create_meeting()

      capable = declaring_roster_agent!(meeting.chat_space_id, "Saru", [Meetings.voice_feature()])

      incapable =
        declaring_roster_agent!(meeting.chat_space_id, "Higgins", ["some_other_feature"])

      {_view, html, _meeting} = open_lobby_for_meeting(conn, meeting)

      assert html =~ ~s(data-agent-id="#{capable.id}")
      assert html =~ ~s(data-agent-id="#{incapable.id}")
      assert html =~ "Voice runtime online"
      assert html =~ "No voice runtime online"
    end
  end

  # ── Per-screen: the toggles write the ONE pair MeetingHooks owns ───────

  describe "the lobby toggles" do
    test "mic toggle flips :mic_enabled and the lobby says so", %{conn: conn} do
      {view, _html, _meeting} = open_lobby(conn)

      html = toggle(view, "meeting-lobby-mic")

      assert assigns(view).mic_enabled == false
      assert has_element?(view, ~s([data-role="meeting-lobby-mic"][data-on="false"]))
      assert html =~ "Mic off"
      assert html =~ "microphone off"
      # Still in the lobby: toggling is not joining.
      assert assigns(view).state == :name_entry
    end

    test "a toggle click does not wipe a half-typed name", %{conn: conn} do
      {view, _html, _meeting} = open_lobby(conn)

      view
      |> form(~s([data-role="meeting-lobby-join-form"]), %{"guest" => %{"name" => "Grace Ho"}})
      |> render_change()

      html = toggle(view, "meeting-lobby-mic")

      assert assigns(view).name_value == "Grace Ho"
      assert html =~ ~s(value="Grace Ho")
    end

    test "camera toggle flips :camera_enabled, the preview reads it, and the lobby says so",
         %{conn: conn} do
      {view, _html, _meeting} = open_lobby(conn)

      html = toggle(view, "meeting-lobby-camera")

      assert assigns(view).camera_enabled == false
      assert has_element?(view, ~s([data-role="meeting-lobby-camera"][data-on="false"]))

      assert has_element?(
               view,
               ~s([data-role="meeting-lobby-preview"][data-camera-enabled="false"])
             )

      assert html =~ "Camera off"
      assert html =~ "camera off"
      assert assigns(view).state == :name_entry
    end
  end

  # ── END TO END across the transition ──────────────────────────────────
  #
  # These are the tests the stage exists for. Each drives the lobby toggle,
  # submits Join on the same LiveView, and asserts the IN-CALL state plus
  # the payload the JS connect path enters the room with. A mutation that
  # restores the reset-to-true on the transition (or drops the pair from
  # the payload) must turn these red while the per-screen tests above stay
  # green — that difference is the point.

  describe "the lobby's choice survives Join" do
    test "mic OFF in the lobby is mic OFF in the call, on the assigns, the client dataset and the join payload",
         %{conn: conn} do
      {view, _html, _meeting} = open_lobby(conn)

      toggle(view, "meeting-lobby-mic")
      html = join(view)

      a = assigns(view)
      assert a.state == :in_meeting
      assert a.in_meeting == true
      assert a.mic_enabled == false
      assert a.camera_enabled == true

      # The in-call client mirrors the same pair.
      assert html =~ ~s(id="meeting-client")
      assert has_element?(view, ~s(#meeting-client[data-mic-enabled="false"]))
      assert has_element?(view, ~s(#meeting-client[data-camera-enabled="true"]))

      # And the join payload — what `_join` hands to LiveKit — says muted.
      assert_push_event(view, "join-meeting", %{
        token: token,
        mic_enabled: false,
        camera_enabled: true
      })

      assert is_binary(token)
    end

    test "camera OFF in the lobby is camera OFF in the call", %{conn: conn} do
      {view, _html, _meeting} = open_lobby(conn)

      toggle(view, "meeting-lobby-camera")
      join(view)

      a = assigns(view)
      assert a.state == :in_meeting
      assert a.camera_enabled == false
      assert a.mic_enabled == true
      assert has_element?(view, ~s(#meeting-client[data-camera-enabled="false"]))
      assert has_element?(view, ~s(#meeting-client[data-mic-enabled="true"]))

      assert_push_event(view, "join-meeting", %{mic_enabled: true, camera_enabled: false})
    end

    test "both OFF in the lobby is both OFF in the call", %{conn: conn} do
      {view, _html, _meeting} = open_lobby(conn)

      toggle(view, "meeting-lobby-mic")
      toggle(view, "meeting-lobby-camera")
      join(view)

      a = assigns(view)
      assert a.state == :in_meeting
      assert a.mic_enabled == false
      assert a.camera_enabled == false

      assert_push_event(view, "join-meeting", %{mic_enabled: false, camera_enabled: false})
    end

    test "joining with both on leaves both on", %{conn: conn} do
      {view, _html, _meeting} = open_lobby(conn)

      join(view)

      a = assigns(view)
      assert a.state == :in_meeting
      assert a.mic_enabled == true
      assert a.camera_enabled == true
      assert has_element?(view, ~s(#meeting-client[data-mic-enabled="true"]))
      assert has_element?(view, ~s(#meeting-client[data-camera-enabled="true"]))

      assert_push_event(view, "join-meeting", %{mic_enabled: true, camera_enabled: true})
    end

    test "a rejected name keeps the lobby AND keeps the choice", %{conn: conn} do
      {view, _html, _meeting} = open_lobby(conn)

      toggle(view, "meeting-lobby-mic")
      html = join(view, "   ")

      a = assigns(view)
      assert a.state == :name_entry
      assert a.name_error == "Please enter your name."
      # The toggle is not reset by a failed submit.
      assert a.mic_enabled == false
      assert html =~ "Mic off"
    end
  end
end
