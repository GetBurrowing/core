defmodule PlatformWeb.ChatLive.MeetingHooksReconnectIntentTest do
  @moduledoc """
  Task 01a08d5a stage 3: committed mic/camera intent must survive an LV
  reconnect mount and the restore-on-reconnect join.

  The e2e reviewer's finding (validation 01a08ea1-ccae-7003): after a
  `liveSocket.disconnect(); connect()` the reconnect mount re-ran
  `MeetingHooks.attach/1`, which re-seeded `:mic_enabled` to the literal
  `true`, so `#meeting-client` rendered `data-mic-enabled="true"` and the
  JS hook — which honours the dataset — re-published a mic the user had
  muted. Same for the restore-on-reconnect `do_join`, which re-pushes
  `join-meeting` against a dataset that was already re-seeded.

  These are CONNECTED LiveView mounts of the real `ChatLive` / guest
  `MeetingLive` surfaces. The second `live/2` IS a new LV process with no
  surviving assigns — exactly what a socket drop produces. What it cannot
  be is a reconnect as `MeetingHooks.reconnect_mount?/1` detects one:
  `Phoenix.LiveViewTest.ClientProxy` hard-sets `"_mounts" => 0` on every
  mount (`Map.put(view.connect_params, "_mounts", 0)`), so the
  `put_connect_params/2` value is overwritten and the restore branch of
  `maybe_restore_on_reconnect/2` never runs under this harness. That
  branch is pinned at unit level in `meeting_hooks_test.exs` ("committed
  media intent survives attach + restore"), where `:meeting_reconnect?`
  is set directly. Here the assertion is on the rendered dataset of the
  fresh mount, because the dataset is what the JS reads — on
  `reconnected()` / `_adoptRoom` for the surviving Room, and in `_join`
  BEFORE the restore join's tracks are published — and the fix is
  deliberately not gated on the reconnect flag (a `live_navigate`
  remount adopts the surviving Room through the same dataset).

  `async: false`: `put_livekit_env/0` mutates application env, and the
  per-user `Platform.Meetings.State` ETS table is process-global.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.State, as: MeetingState
  alias Platform.Repo

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

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "reconnect-intent-#{n}@example.com",
      name: "Reconnect Intent #{n}",
      oidc_sub: "oidc-reconnect-intent-#{n}",
      avatar_url: nil
    })
  end

  defp create_channel do
    n = System.unique_integer([:positive])

    {:ok, ch} =
      Chat.create_space(%{
        name: "Reconnect Intent #{n}",
        slug: "reconnect-intent-#{n}",
        kind: "channel"
      })

    ch
  end

  # The `#meeting-client` dataset as the JS hook would read it.
  defp dataset(html) do
    node =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#meeting-client")

    assert LazyHTML.to_html(node) != "", "expected #meeting-client in the rendered page"

    %{
      mic: node |> LazyHTML.attribute("data-mic-enabled") |> List.first(),
      camera: node |> LazyHTML.attribute("data-camera-enabled") |> List.first()
    }
  end

  # A second connected mount of the same conn: a NEW LiveView process, as
  # after a socket drop. (`_mounts` is pinned to 0 by the test harness —
  # see the moduledoc — so this is a remount, not a detected reconnect.)
  defp remount(conn, path), do: live(conn, path)

  setup [:put_livekit_env]

  setup do
    user = insert_user()
    channel = create_channel()
    on_exit(fn -> MeetingState.broadcast_left(user.id) end)
    %{user: user, channel: channel}
  end

  describe "member reconnect mount (ChatLive) keeps committed media intent" do
    test "mic toggled off before the drop renders data-mic-enabled=\"false\" on the reconnect mount",
         %{conn: conn, user: user, channel: channel} do
      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      # Join, then commit mic OFF server-side (the in-chat control's event).
      render_click(view, "meeting_join", %{})
      assert :sys.get_state(view.pid).socket.assigns.in_meeting
      render_click(view, "meeting_toggle_mic", %{})
      assert :sys.get_state(view.pid).socket.assigns.mic_enabled == false

      # The socket drops: a NEW LV process mounts. The dataset it renders
      # is what the JS reads before any join or re-engage runs.
      {:ok, _remounted, html} = remount(conn, ~p"/chat/#{channel.slug}")

      assert %{mic: "false", camera: "true"} = dataset(html)
    end

    test "camera toggled off before the drop renders data-camera-enabled=\"false\" on the reconnect mount",
         %{conn: conn, user: user, channel: channel} do
      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(view, "meeting_join", %{})
      render_click(view, "meeting_toggle_camera", %{})
      assert :sys.get_state(view.pid).socket.assigns.camera_enabled == false

      {:ok, _remounted, html} = remount(conn, ~p"/chat/#{channel.slug}")

      assert %{mic: "true", camera: "false"} = dataset(html)
    end

    # POSITIVE CONTROL: the same reconnect with nothing toggled still seeds
    # both on. Without this the "false" assertions above could pass on a
    # seed that is simply always false.
    test "with mic and camera left on, the reconnect mount renders both \"true\"",
         %{conn: conn, user: user, channel: channel} do
      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(view, "meeting_join", %{})
      assert :sys.get_state(view.pid).socket.assigns.in_meeting

      {:ok, _remounted, html} = remount(conn, ~p"/chat/#{channel.slug}")

      assert %{mic: "true", camera: "true"} = dataset(html)
    end

    # FIRST-JOIN DEFAULTS UNCHANGED: a user who is NOT in a meeting (no
    # participant row, no ETS row) gets the literal seeds on every mount,
    # even after toggling a control outside a meeting.
    test "a mount with no meeting in progress keeps the first-join defaults",
         %{conn: conn, user: user, channel: channel} do
      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, html} = live(conn, ~p"/chat/#{channel.slug}")
      assert %{mic: "true", camera: "true"} = dataset(html)
      render_click(view, "meeting_toggle_mic", %{})
      assert :sys.get_state(view.pid).socket.assigns.mic_enabled == false

      {:ok, view, html} = remount(conn, ~p"/chat/#{channel.slug}")
      assert %{mic: "true", camera: "true"} = dataset(html)
      refute :sys.get_state(view.pid).socket.assigns.in_meeting
    end

    # A genuine leave resets: the next join starts from the defaults again.
    test "after an explicit leave the next fresh mount renders both \"true\" again",
         %{conn: conn, user: user, channel: channel} do
      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/chat/#{channel.slug}")

      render_click(view, "meeting_join", %{})
      render_click(view, "meeting_toggle_mic", %{})
      render_click(view, "meeting_leave", %{})
      refute :sys.get_state(view.pid).socket.assigns.in_meeting

      {:ok, _view, html} = remount(conn, ~p"/chat/#{channel.slug}")
      assert %{mic: "true", camera: "true"} = dataset(html)
    end
  end

  describe "guest reconnect mount (MeetingLive guest ingress) keeps committed media intent" do
    setup do
      org_id = Platform.TenancyFixtures.fabrikam_org_id()

      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "Reconnect Intent Guest #{System.unique_integer([:positive])}",
          org_id: org_id
        })

      {:ok, meeting} =
        Platform.Meetings.create_meeting(%{project_id: project.id, name: "Guest Reconnect"})

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      %{meeting: meeting, token: token}
    end

    test "mic toggled off before the drop renders data-mic-enabled=\"false\" on the guest reconnect mount",
         %{conn: conn, meeting: meeting, token: token} do
      conn = %{conn | host: "meet.localhost"}
      path = "/#{meeting.slug}/#{token}"

      {:ok, view, html} = live(conn, path)
      assert :sys.get_state(view.pid).socket.assigns.state == :in_meeting
      assert %{mic: "true", camera: "true"} = dataset(html)

      render_click(view, "meeting_toggle_mic", %{})
      assert :sys.get_state(view.pid).socket.assigns.mic_enabled == false

      # Same invite URL, new LV process: the token carries the display
      # name, so the guest lands straight back in `:in_meeting` and a
      # fresh `join-meeting` is pushed against the freshly rendered dataset.
      {:ok, remounted, html} = remount(conn, path)
      assert :sys.get_state(remounted.pid).socket.assigns.state == :in_meeting
      # The payload is what the JS reads first (`_desiredInitialMedia`,
      # FE-17 stage 4 / c1b076bc); the dataset is its fallback.
      assert_push_event(remounted, "join-meeting", %{mic_enabled: false, camera_enabled: true})

      assert %{mic: "false", camera: "true"} = dataset(html)
    end

    test "an explicit guest leave clears the cached pair: the next mount renders \"true\"",
         %{conn: conn, meeting: meeting, token: token} do
      conn = %{conn | host: "meet.localhost"}
      path = "/#{meeting.slug}/#{token}"

      {:ok, view, _html} = live(conn, path)
      render_click(view, "meeting_toggle_mic", %{})
      render_click(view, "meeting_leave", %{})

      {:ok, _remounted, html} = remount(conn, path)
      assert %{mic: "true", camera: "true"} = dataset(html)
    end

    test "with mic left on, the guest reconnect mount renders \"true\" (positive control)",
         %{conn: conn, meeting: meeting, token: token} do
      conn = %{conn | host: "meet.localhost"}
      path = "/#{meeting.slug}/#{token}"

      {:ok, _view, _html} = live(conn, path)
      {:ok, _remounted, html} = remount(conn, path)

      assert %{mic: "true", camera: "true"} = dataset(html)
    end
  end
end
