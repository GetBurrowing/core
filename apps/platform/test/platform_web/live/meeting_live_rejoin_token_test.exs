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

    test "a guest whose invite was revoked mid-call is refused", ctx do
      invite = guest_invite!(ctx.meeting, "Jane Doe")
      token = guest_token(ctx.meeting, invite)

      {:ok, view, _} = live(guest_conn(build_conn()), "/#{ctx.meeting.slug}/#{token}")
      {:ok, _} = Meetings.revoke_invite(invite)

      render_hook(view, "meeting_rejoin_token", %{})
      assert_reply(view, %{error: "denied"} = reply)
      refute Map.has_key?(reply, :token)
    end
  end
end
