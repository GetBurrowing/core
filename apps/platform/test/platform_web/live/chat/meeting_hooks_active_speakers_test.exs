defmodule PlatformWeb.ChatLive.MeetingHooksActiveSpeakersTest do
  @moduledoc """
  Task 01a05b14 stage 5 — the `active_speakers` push on the CHAT surface.

  The `MeetingRoom` JS hook is mounted on `#meeting-room` in
  `chat_live.html.heex` as well as in `meeting_live.html.heex`, and a
  hook's `pushEvent` ignores `phx-target`: the push lands on whichever
  root LiveView owns the page. `/meetings` had a handler; `ChatLive` had
  none, so every LiveKit active-speaker change in a quickmeet was a
  `FunctionClauseError` in `ChatLive.handle_event/3`, the process
  crash-remounted, and the remount lost the transient `:typing` rail
  state that only ever arrives over PubSub (the e2e reviewer counted 859
  crashes in one session and saw the quickmeet's Writer row read `Idle`
  where `/meetings` read `Writing`).

  These tests drive the push through a REAL mounted `ChatLive`
  (`render_hook/3` is root-targeted, the honest simulation of a hook
  push) rather than through `MeetingHooks` functions directly, because
  the defect was the absence of a clause on the LiveView, which no unit
  test of the hook module can see.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
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
        email: "active-speakers-#{n}@example.com",
        name: "Ada Speaker",
        oidc_sub: "oidc-active-speakers-#{n}"
      })

    {:ok, space} =
      Chat.create_space(%{
        name: "Active Speakers #{n}",
        slug: "active-speakers-#{n}",
        kind: "channel"
      })

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, conn: conn, user: user, space: space}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp speaking(view), do: assigns(view).speaking_identities

  # Join the quickmeet from the chat surface. The rail and the panel exist
  # only once `:in_meeting` is true, so both are asserted here as the
  # DIRECTION CONTROL for the "still mounted after the push" claims below:
  # a test that never saw the panel cannot claim the push kept it.
  defp join(conn, space) do
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
    render_click(view, "meeting_join", %{})

    assert assigns(view).in_meeting
    assert has_element?(view, "#meeting-panel")
    assert has_element?(view, "#quickmeet-call-rail")

    view
  end

  describe "active_speakers on the quickmeet" do
    test "a speaker push is folded into the assign and the panel stays mounted", %{
      conn: conn,
      space: space,
      user: user
    } do
      view = join(conn, space)
      identity = "user:#{user.id}"

      # Nobody is speaking on join.
      refute MapSet.member?(speaking(view), identity)

      render_hook(view, "active_speakers", %{"identities" => [identity]})

      # The process that took the push is the process that answers.
      assert Process.alive?(view.pid)
      assert MapSet.member?(speaking(view), identity)

      # The reviewer saw the panel vanish outright (railCount 0) after the
      # crash-remount cycle; a push must leave the call surface where it
      # was, still joined.
      assert assigns(view).in_meeting
      assert has_element?(view, "#meeting-panel")
      assert has_element?(view, "#quickmeet-call-rail")

      # And the joiner's durable participant row is still live — nothing
      # on this path stamps `left_at`.
      assert Enum.any?(Meetings.active_participants_for_space(space.id), &(&1.user_id == user.id))

      # Silence clears it again.
      render_hook(view, "active_speakers", %{"identities" => []})
      assert MapSet.size(speaking(view)) == 0
      assert has_element?(view, "#quickmeet-call-rail")
    end

    test "a push before the viewer has joined is harmless too", %{conn: conn, space: space} do
      # The hook is mounted on every non-embedded ChatLive page, not only
      # inside a call, so the handler must exist regardless of `:in_meeting`.
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      refute assigns(view).in_meeting

      render_hook(view, "active_speakers", %{"identities" => ["user:someone"]})

      assert Process.alive?(view.pid)
      assert MapSet.member?(speaking(view), "user:someone")
    end

    test "a malformed payload is ignored rather than crashing the LiveView", %{
      conn: conn,
      space: space
    } do
      view = join(conn, space)

      for bad <- [%{"nonsense" => true}, %{"identities" => "user:not-a-list"}, %{}] do
        render_hook(view, "active_speakers", bad)
        assert Process.alive?(view.pid), "crashed on #{inspect(bad)}"
        assert MapSet.size(speaking(view)) == 0, "assigned from #{inspect(bad)}"
      end

      # Non-binary members are dropped, the binaries are kept.
      render_hook(view, "active_speakers", %{"identities" => [1, nil, "user:ok", %{}]})
      assert speaking(view) == MapSet.new(["user:ok"])
      assert has_element?(view, "#quickmeet-call-rail")
    end

    test "leaving the call clears the speaking set", %{conn: conn, space: space, user: user} do
      view = join(conn, space)
      render_hook(view, "active_speakers", %{"identities" => ["user:#{user.id}"]})
      assert MapSet.size(speaking(view)) == 1

      render_click(view, "meeting_leave", %{})

      refute assigns(view).in_meeting
      assert MapSet.size(speaking(view)) == 0
    end
  end
end
