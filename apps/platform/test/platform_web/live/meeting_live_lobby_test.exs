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
    meeting = create_meeting()
    expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
    token = GuestInvite.sign(meeting.slug, expires_at, nil)

    {:ok, view, html} =
      %{conn | host: "meet.localhost"}
      |> live("/#{meeting.slug}/#{token}")

    {view, html, meeting}
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
