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
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Tasks.Project
  alias PlatformWeb.MeetingLive.LiveInvites

  @guest_host_message "Guest links are not available: MEETING_GUEST_HOST is not configured."
  @generic_message "That invite could not be sent."
  @expiry_message "That link could not be updated."
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

  # A guest row whose link lapsed an hour ago; no API mints one.
  defp expire!(invite) do
    invite
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))
    |> Repo.update!()
  end

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

  describe "commit_params/3" do
    test "one candidate is the highlighted row" do
      assert LiveInvites.commit_params([%{id: "u-1"}], "ignored@example.test", "anything") ==
               %{"kind" => "user", "id" => "u-1"}
    end

    test "zero candidates plus an address is the default guest row" do
      assert LiveInvites.commit_params([], "guest@example.test", "guest@example.test") ==
               %{"kind" => "guest", "email" => "guest@example.test"}
    end

    test "several candidates highlight nothing" do
      assert LiveInvites.commit_params([%{id: "u-1"}, %{id: "u-2"}], nil, "Guest") == nil

      assert LiveInvites.commit_params([%{id: "u-1"}, %{id: "u-2"}], "a@example.test", "a@") ==
               nil
    end

    # Task 01a19ea6: Enter commits a typed name just as it does an address.
    test "zero candidates, no address and a typed name is the guest-by-name row" do
      assert LiveInvites.commit_params([], nil, "  Guest Alpha ") ==
               %{"kind" => "guest", "name" => "Guest Alpha"}
    end

    test "a blank query highlights nothing" do
      assert LiveInvites.commit_params([], nil, "   ") == nil
      assert LiveInvites.commit_params([], nil, "") == nil
    end

    # An address that produced no email option (already invited) is not a
    # name.
    test "an address-shaped query with no email option highlights nothing" do
      assert LiveInvites.commit_params([], nil, "taken@example.test") == nil
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

  describe "set_expiry/3 and renew/4" do
    setup %{meeting: meeting} do
      Application.put_env(:platform, :meeting_guest_host, @configured_host)

      {:ok, %{invite: invite}} =
        Meetings.invite_guest(meeting, %{display_name: "Guest Alpha", email: nil})

      {:ok, invite: invite}
    end

    test "each allowlisted choice moves the row", %{meeting: meeting, invite: invite} do
      updated =
        LiveInvites.set_expiry(socket(), meeting, %{"id" => invite.id, "choice" => "days_7"})

      assert error_flash(updated) == nil
      week = Repo.get!(Invite, invite.id).expires_at
      assert DateTime.diff(week, DateTime.utc_now(), :second) > 6 * 86_400

      LiveInvites.set_expiry(socket(), meeting, %{"id" => invite.id, "choice" => "meeting_end"})

      assert DateTime.compare(
               Repo.get!(Invite, invite.id).expires_at,
               meeting.scheduled_end_at
             ) == :eq

      LiveInvites.set_expiry(socket(), meeting, %{"id" => invite.id, "choice" => "hours_24"})
      day = Repo.get!(Invite, invite.id).expires_at
      assert_in_delta DateTime.diff(day, DateTime.utc_now(), :second), 86_400, 10
    end

    test "an unknown choice raises and writes nothing", %{meeting: meeting, invite: invite} do
      for choice <- ["forever", "2099-01-01T00:00:00Z", nil] do
        assert_raise ArgumentError, fn ->
          LiveInvites.set_expiry(socket(), meeting, %{"id" => invite.id, "choice" => choice})
        end

        assert_raise ArgumentError, fn ->
          LiveInvites.renew(socket(), meeting, %{"id" => invite.id, "choice" => choice}, nil)
        end
      end

      assert Repo.get!(Invite, invite.id).expires_at == invite.expires_at
      assert length(Meetings.list_invites(meeting.id, include_revoked: true)) == 1
    end

    test "a forged invite id raises and writes nothing", %{
      inviter: inviter,
      meeting: meeting,
      invite: invite
    } do
      {:ok, member_invite} =
        LiveInvites.deliver(meeting, "user", %{"id" => inviter.id}, [inviter], inviter.id)

      for id <- [member_invite.id, Ecto.UUID.generate(), "nope"] do
        assert_raise ArgumentError, fn ->
          LiveInvites.set_expiry(socket(), meeting, %{"id" => id, "choice" => "days_7"})
        end

        assert_raise ArgumentError, fn ->
          LiveInvites.renew(socket(), meeting, %{"id" => id, "choice" => "days_7"}, inviter.id)
        end
      end

      assert Repo.get!(Invite, invite.id).expires_at == invite.expires_at
      assert length(Meetings.list_invites(meeting.id, include_revoked: true)) == 2
    end

    test "an expired row flashes on set and renews on New link", %{
      inviter: inviter,
      meeting: meeting,
      invite: invite
    } do
      expired = expire!(invite)

      refused =
        LiveInvites.set_expiry(socket(), meeting, %{"id" => invite.id, "choice" => "days_7"})

      assert error_flash(refused) == @expiry_message
      assert Repo.get!(Invite, invite.id).expires_at == expired.expires_at

      renewed =
        LiveInvites.renew(
          socket(),
          meeting,
          %{"id" => invite.id, "choice" => "meeting_end"},
          inviter.id
        )

      assert error_flash(renewed) == nil
      assert [fresh] = Meetings.list_invites(meeting.id)
      refute fresh.id == invite.id
      assert fresh.display_name == "Guest Alpha"
    end

    test "renewing a live row flashes and writes nothing", %{
      inviter: inviter,
      meeting: meeting,
      invite: invite
    } do
      refused =
        LiveInvites.renew(
          socket(),
          meeting,
          %{"id" => invite.id, "choice" => "days_7"},
          inviter.id
        )

      assert error_flash(refused) == @expiry_message
      assert [only] = Meetings.list_invites(meeting.id, include_revoked: true)
      assert only.id == invite.id
    end

    test "renew with the guest host unset flashes the operator message", %{
      inviter: inviter,
      meeting: meeting,
      invite: invite
    } do
      expire!(invite)
      Application.delete_env(:platform, :meeting_guest_host)

      refused =
        LiveInvites.renew(
          socket(),
          meeting,
          %{"id" => invite.id, "choice" => "days_7"},
          inviter.id
        )

      assert error_flash(refused) == @guest_host_message
      assert [only] = Meetings.list_invites(meeting.id, include_revoked: true)
      assert only.id == invite.id
      assert only.revoked_at == nil
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
