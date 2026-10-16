defmodule PlatformWeb.ChatLive.MeetingHooksNativeCallTest do
  @moduledoc """
  Task 01a13c62 stage 3: inside the Burrow iOS app the native call owns the
  mic, and the page's mic button may only show what the call CONFIRMED.

  Connected mounts of the real `ChatLive`, driven with the same events
  `meeting_client.js` pushes (`native_call_attached`, `native_media_state`)
  and asserting the `toggle-mic` push it receives. The JS half is pinned in
  `assets/test/hooks/meeting_client_native_handoff.test.js`.

  `async: false`: `put_livekit_env/1` mutates application env, and the
  per-user `Platform.Meetings.State` ETS table is process-global.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings.State, as: MeetingState
  alias Platform.Repo

  @caps %{"mic" => true, "camera" => false, "activeSpeakers" => true}

  defp put_livekit_env(_ctx) do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
    :ok
  end

  setup [:put_livekit_env]

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "native-call-#{n}@example.com",
        name: "Native Call #{n}",
        oidc_sub: "oidc-native-call-#{n}",
        avatar_url: nil
      })

    {:ok, channel} =
      Chat.create_space(%{name: "Native Call #{n}", slug: "native-call-#{n}", kind: "channel"})

    on_exit(fn -> MeetingState.broadcast_left(user.id) end)

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")
    render_click(view, "meeting_join", %{})

    %{conn: conn, view: view, user: user, channel: channel}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp attach_native(view, mic \\ true) do
    render_hook(view, "native_call_attached", %{
      "capabilities" => @caps,
      "mic" => mic,
      "camera" => false
    })
  end

  test "a page mic tap asks the native call and waits; the confirmation flips it", %{view: view} do
    attach_native(view)
    assert assigns(view).mic_enabled == true

    render_click(view, "meeting_toggle_mic", %{})

    assert_push_event(view, "toggle-mic", %{want: false})
    assert assigns(view).mic_enabled == true
    assert assigns(view).mic_pending == true

    html = render(view)
    assert html =~ ~s(aria-busy="true")
    assert html =~ "ring-warning"

    render_hook(view, "native_media_state", %{"mic" => false, "camera" => false})

    assert assigns(view).mic_enabled == false
    assert assigns(view).mic_pending == false
    refute render(view) =~ ~s(aria-busy="true")
  end

  test "failed shows the one line at the last confirmed state; a late confirmation clears it",
       %{view: view} do
    attach_native(view)
    render_click(view, "meeting_toggle_mic", %{})

    render_hook(view, "native_media_state", %{"mic" => true, "camera" => false, "failed" => "mic"})

    html = render(view)
    assert html =~ "Couldn&#39;t change the mic. Use the call controls."
    assert assigns(view).mic_enabled == true

    render_hook(view, "native_media_state", %{"mic" => false, "camera" => false})

    refute render(view) =~ "Couldn&#39;t change the mic"
    assert assigns(view).mic_enabled == false
  end

  test "native mode hides camera and share and shows the audio-only note", %{view: view} do
    before = render(view)
    assert before =~ ~s(data-role="meeting-camera")
    refute before =~ "Audio only in the app"

    attach_native(view)
    html = render(view)

    refute html =~ ~s(data-role="meeting-camera")
    refute html =~ ~s(data-role="meeting-share-button")
    assert html =~ ~s(data-role="meeting-mic")
    assert html =~ "Audio only in the app"
  end

  test "a remount drops pending, so the state always has an exit",
       %{conn: conn, view: view, channel: channel} do
    attach_native(view)
    render_click(view, "meeting_toggle_mic", %{})
    assert assigns(view).mic_pending == true

    {:ok, remounted, _html} = live(conn, ~p"/chat/#{channel.slug}")

    assert assigns(remounted).mic_pending == false
    assert assigns(remounted).native_call == nil
  end

  test "leaving the call drops native mode", %{view: view} do
    attach_native(view)
    render_click(view, "meeting_leave", %{})

    assert assigns(view).native_call == nil
    assert assigns(view).mic_pending == false
  end
end
