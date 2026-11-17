defmodule PlatformWeb.MeetingLiveRejoinTokenTest do
  @moduledoc """
  `meeting_rejoin_token`: the client asks for a fresh LiveKit token before it
  rejoins after a network drop (a guest token lasts 30 minutes, so the one
  from the first join is stale on a long outage).

  The handler is NOT a new way in. Every case below pins both sides of its
  claim: the allowed caller gets a token for the SAME room and identity the
  original join used, and the caller the original join would have refused (or
  who is no longer part of the call) gets an error reply and no token.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.Invite
  alias Platform.Meetings.State, as: MeetingState
  alias Platform.Repo
  alias Platform.Tasks
  alias PlatformWeb.ChatLive.MeetingHooks
  alias Platform.Tenancy.OrgMembership

  @livekit_url "wss://livekit.test"

  setup %{conn: conn} do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: @livekit_url
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    n = System.unique_integer([:positive])
    org_id = Platform.TenancyFixtures.acme_org_id()
    user = user!("member-#{n}")
    on_exit(fn -> MeetingState.broadcast_left(user.id) end)

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
    |> Repo.insert!()

    {:ok, project} = Tasks.create_project(%{name: "Rejoin token #{n}", org_id: org_id})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Rejoin call #{n}"})

    %{
      conn: init_test_session(conn, current_user_id: user.id),
      user: user,
      meeting: meeting
    }
  end

  defp user!(suffix) do
    Repo.insert!(%User{
      email: "rejoin-token-#{suffix}@example.com",
      name: "Rejoin Viewer",
      oidc_sub: "rejoin-token-#{suffix}"
    })
  end

  defp claims(jwt) do
    [_h, payload, _sig] = String.split(jwt, ".", parts: 3)
    payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  describe "authenticated member" do
    test "a joined member gets a fresh token for the same room and identity", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
      view |> render_click("meeting_join", %{})
      assert_push_event(view, "join-meeting", %{token: first, room_name: room_name})

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{token: fresh, url: @livekit_url, room_name: ^room_name})

      assert fresh != first
      assert claims(fresh)["video"]["room"] == room_name
      assert claims(fresh)["video"]["room"] == claims(first)["video"]["room"]
      assert claims(fresh)["sub"] == "user:#{ctx.user.id}"
      assert claims(fresh)["sub"] == claims(first)["sub"]
    end

    test "a member who never joined is refused: error reply, no token", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{error: "unavailable"} = reply)
      refute Map.has_key?(reply, :token)
    end

    test "a member removed from the space after joining gets an error, not a re-add", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
      view |> render_click("meeting_join", %{})
      assert_push_event(view, "join-meeting", %{token: _})

      row =
        ctx.meeting.chat_space_id
        |> Chat.list_participants(participant_type: "user")
        |> Enum.find(&(&1.participant_id == ctx.user.id))

      {:ok, _} = Chat.remove_participant(row)

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{error: "denied"} = reply)
      refute Map.has_key?(reply, :token)

      still_there =
        ctx.meeting.chat_space_id
        |> Chat.list_participants(participant_type: "user")
        |> Enum.any?(&(&1.participant_id == ctx.user.id))

      refute still_there
    end
  end

  describe "member: call room is the one joined, not the current space" do
    test "after :active_space moves, the token is still for the room joined in", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
      view |> render_click("meeting_join", %{})
      assert_push_event(view, "join-meeting", %{token: first, room_name: room_name})

      {:ok, other} =
        Chat.create_space(%{
          name: "Other",
          slug: "other-#{System.unique_integer([:positive])}",
          kind: "channel",
          org_id: Platform.TenancyFixtures.acme_org_id()
        })

      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns, &Map.put(&1, :active_space, other))
      end)

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{token: fresh, room_name: ^room_name})

      assert claims(fresh)["video"]["room"] == claims(first)["video"]["room"]
      assert claims(fresh)["video"]["room"] == room_name

      other_seated =
        other.id
        |> Chat.list_participants(participant_type: "user")
        |> Enum.any?(&(&1.participant_id == ctx.user.id))

      refute other_seated
    end
  end

  describe "error replies" do
    test "every denial reason yields the same reply; non-denials are \"unavailable\"" do
      # reply shape is a pure function of the class, never of the reason
      assert MeetingHooks.rejoin_reply({:error, :join_not_permitted}) ==
               MeetingHooks.rejoin_reply({:error, :not_a_participant})

      assert MeetingHooks.rejoin_reply({:error, :join_not_permitted}) == %{error: "denied"}
      assert MeetingHooks.rejoin_reply({:error, :revoked}) == %{error: "denied"}
      assert MeetingHooks.rejoin_reply({:error, :expired}) == %{error: "denied"}
      assert MeetingHooks.rejoin_reply({:error, :invalid}) == %{error: "denied"}

      assert MeetingHooks.rejoin_reply({:error, :livekit_not_configured}) == %{
               error: "unavailable"
             }

      assert MeetingHooks.rejoin_reply({:error, :not_in_meeting}) == %{error: "unavailable"}
      assert MeetingHooks.rejoin_reply({:error, %Ecto.Changeset{}}) == %{error: "unavailable"}
    end

    test "a non-denial failure (livekit unconfigured) is unavailable, not denied", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
      view |> render_click("meeting_join", %{})
      assert_push_event(view, "join-meeting", %{token: _})

      Application.put_env(:platform, :livekit, api_key: nil, api_secret: nil, url: nil)

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{error: "unavailable"})
    end

    test "after a remount (not in the meeting) the reply is unavailable", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{error: "unavailable"})
    end
  end

  describe "write throttle (rejoin and join share one per-socket window)" do
    # Writes made by ANY process during `fun`, counted from the repo's query
    # telemetry. No pid filter: a write made from a spawned task would be
    # missed by a `self() == view_pid` filter. (`join_for_user/3` writes in the
    # LiveView process today; the unfiltered count keeps this honest if that
    # changes.) The tests are non-async on the sandbox, so the only writers are
    # the view under test and its own children.
    defp count_writes(fun) do
      test = self()
      id = "rejoin-writes-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:platform, :repo, :query],
        fn _e, _m, meta, _c ->
          if meta.query =~ ~r/(INSERT INTO|UPDATE )/, do: send(test, {:write, meta.query})
        end,
        nil
      )

      try do
        fun.()
        drain_writes([])
      after
        :telemetry.detach(id)
      end
    end

    defp drain_writes(acc) do
      receive do
        {:write, q} -> drain_writes([q | acc])
      after
        50 -> acc
      end
    end

    # Fill the socket's window as if `limit` gated requests had just been made.
    defp fill_window(view) do
      now = System.monotonic_time(:millisecond)

      :sys.replace_state(view.pid, fn state ->
        update_in(
          state.socket.assigns,
          &Map.put(&1, :write_requests, List.duplicate(now, MeetingHooks.write_throttle_limit()))
        )
      end)
    end

    defp window_size(view),
      do: length(:sys.get_state(view.pid).socket.assigns[:write_requests] || [])

    defp joined_view(ctx) do
      {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
      view |> render_click("meeting_join", %{})
      assert_push_event(view, "join-meeting", %{token: _})
      view
    end

    test "a permitted member with a full window gets unavailable and nothing is written", ctx do
      view = joined_view(ctx)

      # The write counter must see a granted request, or "no writes" proves nothing.
      granted =
        count_writes(fn ->
          render_hook(view, "meeting_rejoin_token", %{})
          assert_reply(view, %{token: _})
        end)

      assert granted != []

      fill_window(view)

      writes =
        count_writes(fn ->
          render_hook(view, "meeting_rejoin_token", %{})
          assert_reply(view, %{error: "unavailable"} = reply)
          refute Map.has_key?(reply, :token)
        end)

      assert writes == []
    end

    test "a member revoked after the window filled gets denied, not unavailable", ctx do
      view = joined_view(ctx)
      fill_window(view)

      row =
        ctx.meeting.chat_space_id
        |> Chat.list_participants(participant_type: "user")
        |> Enum.find(&(&1.participant_id == ctx.user.id))

      {:ok, _} = Chat.remove_participant(row)

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{error: "denied"} = reply)
      refute Map.has_key?(reply, :token)
    end

    test "refusals do not consume slots", ctx do
      view = joined_view(ctx)

      row =
        ctx.meeting.chat_space_id
        |> Chat.list_participants(participant_type: "user")
        |> Enum.find(&(&1.participant_id == ctx.user.id))

      {:ok, _} = Chat.remove_participant(row)
      before = window_size(view)

      for _ <- 1..(MeetingHooks.write_throttle_limit() + 5) do
        render_hook(view, "meeting_rejoin_token", %{})
        assert_reply(view, %{error: "denied"})
      end

      assert window_size(view) == before
    end

    test "a granted request consumes exactly one slot", ctx do
      view = joined_view(ctx)
      before = window_size(view)
      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{token: _})
      assert window_size(view) == before + 1
    end

    test "meeting_join: normal use is never throttled, repeated join/leave all push", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")

      for _ <- 1..10 do
        view |> render_click("meeting_join", %{})
        assert_push_event(view, "join-meeting", %{token: _})
        view |> render_click("meeting_leave", %{})
      end
    end

    # `maybe_start_meeting` flips a scheduled meeting live BEFORE the join
    # hook runs, once; start it with a first join so the burst below measures
    # only the repeatable writes.
    defp started_then_left_view(ctx) do
      view = joined_view(ctx)
      view |> render_click("meeting_leave", %{})
      view
    end

    test "meeting_join: a burst beyond the limit makes no writes and pushes nothing", ctx do
      view = started_then_left_view(ctx)
      fill_window(view)

      writes = count_writes(fn -> view |> render_click("meeting_join", %{}) end)

      assert writes == []
      refute_push_event(view, "join-meeting", %{}, 100)
      refute :sys.get_state(view.pid).socket.assigns.in_meeting
    end

    # The member lobby: a signed-in member on the `meet.` host lands in
    # `state: :lobby` and presses Join. A throttled press must leave them in
    # the lobby with a message, not strand them out of both lobby and call.
    defp lobby_view(ctx) do
      {:ok, view, _} =
        %{ctx.conn | host: "meet.localhost"} |> live("/meetings/#{ctx.meeting.slug}")

      assert :sys.get_state(view.pid).socket.assigns.state == :lobby
      view
    end

    defp view_assigns(view), do: :sys.get_state(view.pid).socket.assigns

    test "the lobby's join_meeting with a full window keeps the lobby, flashes, writes nothing, starts nothing",
         ctx do
      view = lobby_view(ctx)
      fill_window(view)
      assert view_assigns(view).meeting.status == "scheduled"

      writes = count_writes(fn -> view |> render_click("join_meeting", %{}) end)

      assert writes == []
      assigns = view_assigns(view)
      assert assigns.state == :lobby
      refute assigns.in_meeting
      assert assigns.meeting.status == "scheduled"
      assert Meetings.get_meeting(ctx.meeting.id).status == "scheduled"
      assert Phoenix.Flash.get(assigns.flash, :error) =~ "Too many join attempts"
      refute_push_event(view, "join-meeting", %{}, 100)
    end

    test "the lobby's join_meeting below the limit still joins and takes one slot", ctx do
      view = lobby_view(ctx)
      before = window_size(view)
      view |> render_click("join_meeting", %{})
      assert_push_event(view, "join-meeting", %{token: _})
      assert view_assigns(view).state == nil
      assert window_size(view) == before + 1
    end

    test ":auto_join with a full window changes nothing and flashes", ctx do
      view = joined_view(ctx)

      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns, &Map.put(&1, :in_meeting, false))
      end)

      fill_window(view)

      writes =
        count_writes(fn ->
          send(view.pid, :auto_join)
          render(view)
        end)

      assert writes == []
      assigns = view_assigns(view)
      refute assigns.in_meeting
      assert Phoenix.Flash.get(assigns.flash, :error) =~ "Too many join attempts"
    end

    test "meeting_join with a full window flashes", ctx do
      view = started_then_left_view(ctx)
      fill_window(view)
      view |> render_click("meeting_join", %{})

      assert Phoenix.Flash.get(view_assigns(view).flash, :error) =~ "Too many join attempts"
    end

    test "a join that writes then fails to mint still takes a slot, so repeats are throttled",
         ctx do
      limit = MeetingHooks.write_throttle_limit()
      {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
      Application.put_env(:platform, :livekit, [])

      first = count_writes(fn -> view |> render_click("meeting_join", %{}) end)
      assert first != []
      refute view_assigns(view).in_meeting
      assert window_size(view) == 1

      for _ <- 2..limit, do: view |> render_click("meeting_join", %{})
      assert window_size(view) == limit

      writes = count_writes(fn -> view |> render_click("meeting_join", %{}) end)
      assert writes == []
    end

    test "throttled requests do not flood the log at warning", ctx do
      view = joined_view(ctx)
      fill_window(view)

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          for _ <- 1..5 do
            render_hook(view, "meeting_rejoin_token", %{})
            assert_reply(view, %{error: "unavailable"})
            view |> render_click("meeting_join", %{})
          end
        end)

      refute log =~ "throttled"
      refute log =~ "unavailable"
    end

    test "meeting_join: a refused join with a full window is not hidden by the throttle", ctx do
      # Gate first: a caller the join would refuse never reaches the window.
      {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")

      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns, &Map.put(&1, :active_space, nil))
      end)

      before = window_size(view)
      view |> render_click("meeting_join", %{})
      assert window_size(view) == before
    end

    test "the window slides: requests are accepted again once old ones age out" do
      limit = MeetingHooks.write_throttle_limit()
      window = MeetingHooks.write_throttle_window_ms()
      socket = %Phoenix.LiveView.Socket{}

      socket =
        Enum.reduce(1..limit, socket, fn i, sock ->
          assert {:ok, sock} = MeetingHooks.write_throttle(sock, 1_000 + i)
          sock
        end)

      assert {:error, :throttled} = MeetingHooks.write_throttle(socket, 1_000 + limit + 1)
      # Still inside the window of the newest request.
      assert {:error, :throttled} = MeetingHooks.write_throttle(socket, 1_001 + window - 1)
      # The oldest has aged out: exactly one slot opens.
      assert {:ok, socket} = MeetingHooks.write_throttle(socket, 1_001 + window)
      assert {:error, :throttled} = MeetingHooks.write_throttle(socket, 1_001 + window)
    end

    test "a throttled request does not consume a slot" do
      limit = MeetingHooks.write_throttle_limit()
      socket = %Phoenix.LiveView.Socket{}

      socket =
        Enum.reduce(1..limit, socket, fn _, sock ->
          {:ok, sock} = MeetingHooks.write_throttle(sock, 0)
          sock
        end)

      for t <- 1..5, do: assert({:error, :throttled} = MeetingHooks.write_throttle(socket, t))
      window = MeetingHooks.write_throttle_window_ms()
      assert {:ok, _} = MeetingHooks.write_throttle(socket, window)
    end
  end

  describe "guest" do
    defp guest_invite!(meeting, name) do
      %Invite{}
      |> Invite.changeset(%{meeting_id: meeting.id, display_name: name})
      |> Repo.insert!()
    end

    defp guest_conn(conn) do
      %{conn | host: "meet.localhost"}
    end

    defp guest_token(meeting, invite) do
      GuestInvite.sign(
        meeting.slug,
        System.os_time(:second) + 3600,
        invite.display_name,
        invite_id: invite.id,
        meeting_id: meeting.id
      )
    end

    test "a guest keeps the guest identity and the same room; identity stays guest:", ctx do
      invite = guest_invite!(ctx.meeting, "Jane Doe")
      token = guest_token(ctx.meeting, invite)

      {:ok, view, _} = live(guest_conn(build_conn()), "/#{ctx.meeting.slug}/#{token}")
      assigns = :sys.get_state(view.pid).socket.assigns
      assert String.starts_with?(assigns.identity, "guest:")

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{token: fresh, url: @livekit_url, room_name: room_name})
      assert room_name == assigns.room_name

      assert claims(fresh)["sub"] == assigns.identity
      assert claims(fresh)["name"] == "Jane Doe (guest)"
      assert claims(fresh)["video"]["room"] == assigns.room_name
      assert fresh != assigns.token
    end

    test "a guest with a full window gets unavailable, no token", ctx do
      invite = guest_invite!(ctx.meeting, "Jane Doe")
      token = guest_token(ctx.meeting, invite)
      {:ok, view, _} = live(guest_conn(build_conn()), "/#{ctx.meeting.slug}/#{token}")
      fill_window(view)

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{error: "unavailable"} = reply)
      refute Map.has_key?(reply, :token)
    end

    test "a guest revoked after the window filled gets denied, not unavailable", ctx do
      invite = guest_invite!(ctx.meeting, "Jane Doe")
      token = guest_token(ctx.meeting, invite)
      {:ok, view, _} = live(guest_conn(build_conn()), "/#{ctx.meeting.slug}/#{token}")
      fill_window(view)
      {:ok, _} = Meetings.revoke_invite(invite)

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{error: "denied"} = reply)
      refute Map.has_key?(reply, :token)
      assert window_size(view) == MeetingHooks.write_throttle_limit()
    end

    test "a guest whose invite was revoked mid-call is refused", ctx do
      invite = guest_invite!(ctx.meeting, "Jane Doe")
      token = guest_token(ctx.meeting, invite)

      {:ok, view, _} = live(guest_conn(build_conn()), "/#{ctx.meeting.slug}/#{token}")
      {:ok, _} = Meetings.revoke_invite(invite)

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{error: "denied"} = reply)
      refute Map.has_key?(reply, :token)
    end

    defp drop_to_name_entry(view) do
      # A network drop remounts the guest into name entry: no longer in the
      # call, the invite link still on the socket.
      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns, &Map.put(&1, :in_meeting, false))
      end)
    end

    test "a guest whose invite was revoked during the outage (remounted, not in call) is denied",
         ctx do
      invite = guest_invite!(ctx.meeting, "Jane Doe")
      token = guest_token(ctx.meeting, invite)

      {:ok, view, _} = live(guest_conn(build_conn()), "/#{ctx.meeting.slug}/#{token}")
      drop_to_name_entry(view)
      {:ok, _} = Meetings.revoke_invite(invite)

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{error: "denied"} = reply)
      refute Map.has_key?(reply, :token)
    end

    test "a guest remounted with a still-valid invite gets unavailable, not denied", ctx do
      invite = guest_invite!(ctx.meeting, "Jane Doe")
      token = guest_token(ctx.meeting, invite)

      {:ok, view, _} = live(guest_conn(build_conn()), "/#{ctx.meeting.slug}/#{token}")
      drop_to_name_entry(view)

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{error: "unavailable"})
    end
  end
end
