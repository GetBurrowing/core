defmodule PlatformWeb.ChatLive.MeetingHooksCompanionTest do
  @moduledoc """
  Task 01a13ca2 stage 3: an iOS app build whose `capabilities().camera` is
  true gets a video-only COMPANION connection (`video:user:<uuid>`) from the
  page, and the camera button shows only what the companion's publication
  CONFIRMED (`companion_media_state`).

  Connected mounts of the real `ChatLive`, driven with the events
  `meeting_client.js` pushes, mirroring `meeting_hooks_native_call_test.exs`.
  The JS half is pinned in
  `assets/test/hooks/meeting_client_native_handoff.test.js`.

  `async: false`: `put_livekit_env/1` mutates application env, and the
  per-user `Platform.Meetings.State` ETS table is process-global.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings.Participant
  alias Platform.Meetings.State, as: MeetingState
  alias Platform.Repo
  alias PlatformWeb.ChatLive.MeetingHooks

  @audio_only %{"mic" => true, "camera" => false, "activeSpeakers" => true}
  @with_camera %{"mic" => true, "camera" => true, "activeSpeakers" => true}

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
        email: "companion-hooks-#{n}@example.com",
        name: "Companion Hooks #{n}",
        oidc_sub: "oidc-companion-hooks-#{n}",
        avatar_url: nil
      })

    {:ok, channel} =
      Chat.create_space(%{
        name: "Companion Hooks #{n}",
        slug: "companion-hooks-#{n}",
        kind: "channel"
      })

    on_exit(fn -> MeetingState.broadcast_left(user.id) end)

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")
    render_click(view, "meeting_join", %{})
    assert_push_event(view, "join-meeting", %{room_name: room_name})

    %{conn: conn, view: view, user: user, channel: channel, room_name: room_name}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp attach(view, caps) do
    render_hook(view, "native_call_attached", %{
      "capabilities" => caps,
      "mic" => true,
      "camera" => false
    })
  end

  defp jwt_claims(token) do
    [_header, payload, _sig] = String.split(token, ".")
    payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  describe "native_call_attached" do
    test "camera:true pushes join-companion with a video:user:<id> token for this room",
         %{view: view, user: user, room_name: room_name} do
      rows_before = Repo.aggregate(Participant, :count)

      attach(view, @with_camera)

      assert_push_event(view, "join-companion", %{token: token, url: url, room_name: ^room_name})
      assert url == "wss://livekit.test"

      claims = jwt_claims(token)
      assert claims["sub"] == "video:user:#{user.id}"
      assert claims["video"]["room"] == room_name
      refute "microphone" in claims["video"]["canPublishSources"]

      assert assigns(view).native_call.camera == true
      # The companion starts OFF: only its publication turns it on.
      assert assigns(view).camera_enabled == false
      assert assigns(view).camera_pending == false

      # Minting the companion writes no roster row.
      assert Repo.aggregate(Participant, :count) == rows_before
    end

    test "camera:false pushes nothing and keeps today's audio-only call", %{view: view} do
      attach(view, @audio_only)

      refute_push_event(view, "join-companion", %{})
      assert assigns(view).native_call.camera == false
      assert render(view) =~ "Audio only in the app"
    end

    test "a build with no camera key (legacy) pushes nothing", %{view: view} do
      attach(view, %{"mic" => true})

      refute_push_event(view, "join-companion", %{})
      assert assigns(view).native_call.camera == false
    end

    test "no user on the socket (a guest): no companion, the UI stays audio only" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          mic_enabled: true,
          camera_enabled: true,
          active_space: %{id: Ecto.UUID.generate()}
        }
      }

      socket = MeetingHooks.apply_native_call_attached(socket, %{"capabilities" => @with_camera})

      assert socket.assigns.native_call.camera == false
      assert (socket.private[:live_temp] || %{})[:push_events] in [nil, []]
    end
  end

  describe "the call bar" do
    test "the note is hidden with the companion camera and shown without it", %{view: view} do
      attach(view, @audio_only)
      html = render(view)
      assert html =~ "Audio only in the app"
      refute html =~ ~s(data-role="meeting-camera")

      attach(view, @with_camera)
      html = render(view)
      refute html =~ "Audio only in the app"
      assert html =~ ~s(data-role="meeting-camera")
      refute html =~ ~s(data-role="meeting-share-button")
    end
  end

  describe "the companion camera" do
    test "a tap sets camera_pending and asks; only the confirmation flips it", %{view: view} do
      attach(view, @with_camera)

      render_click(view, "meeting_toggle_camera", %{})

      assert_push_event(view, "toggle-camera", %{want: true})
      assert assigns(view).camera_enabled == false
      assert assigns(view).camera_pending == true
      assert render(view) =~ ~s(aria-busy="true")

      # A second tap while pending is a no-op.
      render_click(view, "meeting_toggle_camera", %{})
      assert assigns(view).camera_pending == true

      render_hook(view, "companion_media_state", %{"camera" => true})

      assert assigns(view).camera_enabled == true
      assert assigns(view).camera_pending == false
      refute render(view) =~ ~s(aria-busy="true")

      render_click(view, "meeting_toggle_camera", %{})
      assert_push_event(view, "toggle-camera", %{want: false})
    end

    test "native_media_state camera:false does not override a companion-confirmed camera",
         %{view: view} do
      attach(view, @with_camera)
      render_hook(view, "companion_media_state", %{"camera" => true})
      assert assigns(view).camera_enabled == true

      render_hook(view, "native_media_state", %{"mic" => false, "camera" => false})

      assert assigns(view).camera_enabled == true
      assert assigns(view).mic_enabled == false
    end

    test "control: without the companion, native_media_state still moves the camera",
         %{view: view} do
      attach(view, @audio_only)
      render_hook(view, "native_media_state", %{"mic" => true, "camera" => true})
      assert assigns(view).camera_enabled == true
    end

    test "companion_media_state without the companion changes nothing", %{view: view} do
      attach(view, @audio_only)
      before = assigns(view).camera_enabled

      render_hook(view, "companion_media_state", %{"camera" => !before})

      assert assigns(view).camera_enabled == before
    end

    test "failed: camera shows the one line at the confirmed state; a confirmation clears it",
         %{view: view} do
      attach(view, @with_camera)
      render_click(view, "meeting_toggle_camera", %{})

      render_hook(view, "companion_media_state", %{"camera" => false, "failed" => "camera"})

      assert render(view) =~ "Couldn&#39;t change the camera."
      assert assigns(view).camera_enabled == false
      assert assigns(view).camera_pending == false

      render_hook(view, "companion_media_state", %{"camera" => true})
      refute render(view) =~ "Couldn&#39;t change the camera."
    end

    test "a remount re-seeds camera_pending false, so pending always has an exit",
         %{conn: conn, view: view, channel: channel} do
      attach(view, @with_camera)
      render_click(view, "meeting_toggle_camera", %{})
      assert assigns(view).camera_pending == true

      {:ok, remounted, _html} = live(conn, ~p"/chat/#{channel.slug}")

      assert assigns(remounted).camera_pending == false
      assert assigns(remounted).native_call == nil
    end

    test "leaving the call drops camera_pending", %{view: view} do
      attach(view, @with_camera)
      render_click(view, "meeting_toggle_camera", %{})

      render_click(view, "meeting_leave", %{})

      assert assigns(view).camera_pending == false
      assert assigns(view).native_call == nil
    end
  end
end
