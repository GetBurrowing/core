defmodule PlatformWeb.MeetingLiveGuestHostFlashTest do
  @moduledoc """
  A misconfigured guest host must be DISTINGUISHABLE in the UI from an
  ordinary invite failure.

  `Meetings.invite_guest/2` fails closed with `{:error,
  :guest_host_not_configured}` when `:meeting_guest_host` is absent, but
  until this stage `MeetingLive`'s live-invite handler discarded the reason
  and flashed the same "That invite could not be sent." it flashes for a
  changeset error. A behavioural review caught exactly that: no guest link
  was minted (correct) but the operator was given no signal about WHICH
  configuration was missing, which is the entire point of failing closed.

  NOT async, and that is load-bearing: `:meeting_guest_host` is global
  application env and `config/test.exs` sets a value for the whole suite,
  so a module that mutates it concurrently corrupts any other test minting
  a guest link. Same constraint `guest_host_gate_test.exs` and
  `guest_invite_test.exs` carry.

  These drive the real event path — mount the index, select the meeting,
  open the invite control, type an address, click the guest option — and
  assert on RENDERED output. A test that greps the source for the message
  would pass against a handler that never runs.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.{Chat, Meetings, Repo}
  alias Platform.Accounts.User
  alias Platform.Meetings.Meeting
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  @grid_zone "America/Chicago"
  @generic_message "That invite could not be sent."
  @configured_host "meet.example.com"

  setup %{conn: conn} do
    original = Application.get_env(:platform, :meeting_guest_host)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:platform, :meeting_guest_host)
        value -> Application.put_env(:platform, :meeting_guest_host, value)
      end
    end)

    user =
      Repo.insert!(%User{
        email: "guest_host_flash_#{System.unique_integer([:positive])}@example.com",
        name: "Meeting Host",
        oidc_sub: "oidc-guest-host-flash-#{System.unique_integer([:positive])}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    Repo.delete_all(Meeting)

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Guest Host Flash Project #{System.unique_integer([:positive])}",
        slug: "guest-host-flash-#{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    conn =
      conn
      |> init_test_session(current_user_id: user.id)
      |> put_connect_params(%{"timezone" => @grid_zone})

    {:ok, conn: conn, user: user, meeting: seed_meeting(project)}
  end

  # 2:00–3:00 PM local today: inside the rendered week AND inside the
  # default {8, 18} hour window whatever time the suite runs at.
  defp seed_meeting(project) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Guest Host Flash Space #{System.unique_integer([:positive])}",
        slug: "guest-host-flash-space-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    today = PlatformWeb.MeetingLive.calendar_today_date(@grid_zone)
    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "guest-host-flash-meeting-#{System.unique_integer([:positive])}",
        name: "Guest Host Flash Meeting",
        livekit_room_name: "meeting-#{meeting_id}",
        status: "scheduled",
        scheduled_start_at: zoned_utc(today, 14),
        scheduled_end_at: zoned_utc(today, 15)
      })
      |> Repo.insert()

    meeting
  end

  defp zoned_utc(%Date{} = date, hour) do
    date
    |> DateTime.new!(Time.new!(hour, 0, 0), @grid_zone)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp in_grid(selector), do: ~s([data-role="calendar-week-grid"] #{selector})
  defp in_panel(selector), do: ~s([data-role="meeting-detail-panel"] #{selector})

  # The whole flow a host performs, ending in the click that calls
  # `invite_guest/2`. Returns the HTML rendered by that final click.
  defp submit_guest_invite(conn, meeting, address) do
    {:ok, view, _html} = live(conn, ~p"/meetings?view=calendar")

    view
    |> element(in_grid(~s([data-role="calendar-event"][data-meeting-id="#{meeting.id}"])))
    |> render_click()

    view
    |> element(in_panel(~s([data-role="meeting-invite-add-people"])))
    |> render_click()

    view
    |> element(in_panel(~s([data-role="meeting-invite-search"])))
    |> render_keyup(%{"value" => address})

    view
    |> element(in_panel(~s([data-role="meeting-invite-option"][data-option="guest"])))
    |> render_click()
  end

  describe "live guest invite with :meeting_guest_host unset" do
    test "the flash names the missing configuration", %{conn: conn, meeting: meeting} do
      Application.delete_env(:platform, :meeting_guest_host)

      html = submit_guest_invite(conn, meeting, "outsider@example.test")

      # The point of the whole change: the operator can tell WHICH thing is
      # misconfigured, rather than reading a message that also covers a bad
      # email address.
      assert html =~ "MEETING_GUEST_HOST"
      assert html =~ "Guest links are not available"
      refute html =~ @generic_message
    end

    test "the refusal is logged as well as flashed", %{conn: conn, meeting: meeting} do
      Application.delete_env(:platform, :meeting_guest_host)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert submit_guest_invite(conn, meeting, "outsider@example.test") =~
                   "MEETING_GUEST_HOST"
        end)

      assert log =~ "meeting_guest_host"
    end

    test "nothing is written and no link — malformed or otherwise — is rendered", %{
      conn: conn,
      meeting: meeting
    } do
      Application.delete_env(:platform, :meeting_guest_host)

      html = submit_guest_invite(conn, meeting, "outsider@example.test")

      assert Meetings.list_invites(meeting.id) == []
      # `https:///slug/token` is the shape a host-less URL would take.
      refute html =~ "https:///"
      refute html =~ ~s(data-clipboard-text)
    end
  end

  describe "live guest invite with :meeting_guest_host configured" do
    # POSITIVE CONTROL. Without it, a handler that flashed the new message
    # unconditionally would pass every test above.
    test "succeeds and flashes neither error message", %{conn: conn, meeting: meeting} do
      Application.put_env(:platform, :meeting_guest_host, @configured_host)

      html = submit_guest_invite(conn, meeting, "outsider@example.test")

      assert [invite] = Meetings.list_invites(meeting.id)
      assert invite.display_name == "outsider@example.test"
      refute html =~ "MEETING_GUEST_HOST"
      refute html =~ @generic_message
      assert html =~ "https://#{@configured_host}/"
    end
  end
end
