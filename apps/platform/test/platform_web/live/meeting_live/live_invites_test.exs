defmodule PlatformWeb.MeetingLive.LiveInvitesTest do
  @moduledoc """
  Unit tests for `PlatformWeb.MeetingLive.LiveInvites` (task 01a19e7b
  stage 1), driven on a bare socket so they pin the module's own contract
  independently of either LiveView that calls it.

  The end-to-end proof that the move changed nothing is the UNMODIFIED
  MeetingLive suites (`meeting_live_test.exs`,
  `meeting_live_guest_host_flash_test.exs`,
  `meeting_live_create_sheet_invite_test.exs`) and `invite_control_test.exs`.

  NOT async: `:meeting_guest_host` is global application env, the same
  constraint `meeting_live_guest_host_flash_test.exs` carries.
  """
  use Platform.DataCase, async: false

  alias Platform.{Chat, Meetings, Repo}
  alias Platform.Accounts.User
  alias Platform.Meetings.Meeting
  alias Platform.Tasks.Project
  alias PlatformWeb.MeetingLive.LiveInvites

  @guest_host_message "Guest links are not available: MEETING_GUEST_HOST is not configured."
  @generic_message "That invite could not be sent."
  @configured_host "meet.example.com"

  setup do
    original = Application.get_env(:platform, :meeting_guest_host)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:platform, :meeting_guest_host)
        value -> Application.put_env(:platform, :meeting_guest_host, value)
      end
    end)

    inviter = insert_user!("Live Invites Host")

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Live Invites Project #{System.unique_integer([:positive])}",
        slug: "live-invites-#{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    {:ok, inviter: inviter, meeting: seed_meeting(project)}
  end

  defp insert_user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "live_invites_#{n}@example.com",
      name: "#{name} #{n}",
      oidc_sub: "oidc-live-invites-#{n}"
    })
  end

  defp seed_meeting(project) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Live Invites Space #{System.unique_integer([:positive])}",
        slug: "live-invites-space-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    meeting_id = Platform.Types.UUIDv7.generate()
    start = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "live-invites-meeting-#{System.unique_integer([:positive])}",
        name: "Live Invites Meeting",
        livekit_room_name: "meeting-#{meeting_id}",
        status: "scheduled",
        scheduled_start_at: start,
        scheduled_end_at: DateTime.add(start, 3600, :second)
      })
      |> Repo.insert()

    meeting
  end

  defp socket do
    LiveInvites.seed(%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}})
  end

  defp error_flash(socket), do: Map.get(socket.assigns.flash, "error")

  describe "seed/1 and open/1" do
    test "seed is closed and empty; open is the same but open" do
      seeded = socket()

      assert seeded.assigns.meeting_invite_open == false
      assert seeded.assigns.meeting_invite_query == ""
      assert seeded.assigns.meeting_invite_candidates == []
      assert seeded.assigns.meeting_invite_email == nil

      dirty =
        seeded
        |> Phoenix.Component.assign(:meeting_invite_query, "left over")
        |> Phoenix.Component.assign(:meeting_invite_email, "x@example.test")

      opened = LiveInvites.open(dirty)

      assert opened.assigns.meeting_invite_open == true
      assert opened.assigns.meeting_invite_query == ""
      assert opened.assigns.meeting_invite_email == nil
    end
  end

  describe "commit_params/2" do
    test "one candidate is the highlighted row" do
      assert LiveInvites.commit_params([%{id: "u-1"}], "ignored@example.test") ==
               %{"kind" => "user", "id" => "u-1"}
    end

    test "zero candidates plus an address is the default guest row" do
      assert LiveInvites.commit_params([], "guest@example.test") ==
               %{"kind" => "guest", "email" => "guest@example.test"}
    end

    test "several candidates highlight nothing" do
      assert LiveInvites.commit_params([%{id: "u-1"}, %{id: "u-2"}], nil) == nil
      assert LiveInvites.commit_params([%{id: "u-1"}, %{id: "u-2"}], "a@example.test") == nil
    end

    test "zero candidates and no address highlight nothing" do
      assert LiveInvites.commit_params([], nil) == nil
    end
  end

  describe "deliver/5" do
    test "a user id absent from the rendered candidates raises and writes nothing", %{
      inviter: inviter,
      meeting: meeting
    } do
      offered = insert_user!("Offered")
      not_offered = insert_user!("Not Offered")

      assert_raise ArgumentError, ~r/no candidate is currently offered/, fn ->
        LiveInvites.deliver(meeting, "user", %{"id" => not_offered.id}, [offered], inviter.id)
      end

      assert Meetings.list_invites(meeting.id) == []
    end

    # POSITIVE CONTROL for the test above: an implementation that raised for
    # every user id would pass it.
    test "a user id in the rendered candidates is invited", %{inviter: inviter, meeting: meeting} do
      offered = insert_user!("Offered")

      assert {:ok, _} =
               LiveInvites.deliver(meeting, "user", %{"id" => offered.id}, [offered], inviter.id)

      assert [invite] = Meetings.list_invites(meeting.id)
      assert invite.user_id == offered.id
    end

    test "an unknown kind raises", %{inviter: inviter, meeting: meeting} do
      assert_raise ArgumentError, ~r/no live invite kind "carrier-pigeon"/, fn ->
        LiveInvites.deliver(meeting, "carrier-pigeon", %{}, [], inviter.id)
      end

      assert Meetings.list_invites(meeting.id) == []
    end
  end

  describe "stage/4" do
    test "a guest with the guest host unset flashes the operator message and writes nothing",
         %{inviter: inviter, meeting: meeting} do
      Application.delete_env(:platform, :meeting_guest_host)

      staged =
        socket()
        |> LiveInvites.search(meeting, "outsider@example.test")
        |> LiveInvites.stage(
          meeting,
          %{"kind" => "guest", "email" => "outsider@example.test"},
          inviter.id
        )

      assert error_flash(staged) == @guest_host_message
      refute error_flash(staged) == @generic_message
      assert Meetings.list_invites(meeting.id) == []
      # The search is cleared whatever the outcome.
      assert staged.assigns.meeting_invite_query == ""
      assert staged.assigns.meeting_invite_email == nil
    end

    # POSITIVE CONTROL: a stage/4 that flashed unconditionally would pass the
    # test above.
    test "a guest with the guest host configured is written and flashes nothing", %{
      inviter: inviter,
      meeting: meeting
    } do
      Application.put_env(:platform, :meeting_guest_host, @configured_host)

      staged =
        LiveInvites.stage(
          socket(),
          meeting,
          %{"kind" => "guest", "email" => " outsider@example.test "},
          inviter.id
        )

      assert error_flash(staged) == nil
      assert [invite] = Meetings.list_invites(meeting.id)
      assert invite.email == "outsider@example.test"
      assert invite.user_id == nil
      assert %DateTime{} = invite.expires_at
    end
  end

  describe "commit/4" do
    test "a blank value is a no-op", %{inviter: inviter, meeting: meeting} do
      assert {:noop, _socket} = LiveInvites.commit(socket(), meeting, "   ", inviter.id)
      assert Meetings.list_invites(meeting.id) == []
    end

    test "an unmatched address stages the default guest row", %{
      inviter: inviter,
      meeting: meeting
    } do
      Application.put_env(:platform, :meeting_guest_host, @configured_host)

      assert {:staged, staged} =
               LiveInvites.commit(socket(), meeting, "newcomer@example.test", inviter.id)

      assert [invite] = Meetings.list_invites(meeting.id)
      assert invite.email == "newcomer@example.test"
      assert staged.assigns.meeting_invite_query == ""
    end

    test "search excludes someone already invited", %{inviter: inviter, meeting: meeting} do
      member = insert_user!("Already Invited")
      {:ok, _} = LiveInvites.deliver(meeting, "user", %{"id" => member.id}, [member], inviter.id)

      searched = LiveInvites.search(socket(), meeting, member.email)

      refute Enum.any?(searched.assigns.meeting_invite_candidates, &(&1.id == member.id))
      assert {:noop, _} = LiveInvites.commit(socket(), meeting, member.email, inviter.id)
    end
  end
end
