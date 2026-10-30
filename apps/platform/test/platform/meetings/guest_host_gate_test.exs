defmodule Platform.Meetings.GuestHostGateTest do
  @moduledoc """
  Guest-link generation fails CLOSED when `:meeting_guest_host` is absent
  (task 019fcefd stage 2).

  The failure this covers is not hypothetical: on 2026-08-04 the `exp` lane
  came up with `MEETING_GUEST_HOST` unset, and the old `||` fallback in
  `config/runtime.exs` meant exp silently minted guest links pointing at
  PRODUCTION. Nothing errored and nothing logged.

  NOT async. `Application.put_env(:platform, :meeting_guest_host, …)` is
  global process state, and `config/test.exs` sets `meet.test.local` for
  the whole suite — an async module mutating it would corrupt any
  concurrently-running test that mints a guest link. Same call
  `guest_invite_test.exs` made in stage 1.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Meetings
  alias Platform.Meetings.Invite

  setup do
    original = Application.get_env(:platform, :meeting_guest_host)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:platform, :meeting_guest_host)
        value -> Application.put_env(:platform, :meeting_guest_host, value)
      end
    end)

    :ok
  end

  defp create_meeting! do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Guest Host Gate Project #{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Guest Kickoff #{System.unique_integer([:positive])}"
      })

    meeting
  end

  describe "invite_guest/2 with a configured host" do
    # POSITIVE CONTROL. Without this, an implementation that breaks guest
    # links outright would pass both negative tests below.
    test "mints a link against the configured hostname" do
      Application.put_env(:platform, :meeting_guest_host, "meet.example.com")
      meeting = create_meeting!()

      assert {:ok, %{invite: %Invite{} = invite, token: token, url: url}} =
               Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      # Short link (task 01a18d0a-ec37): host + /g/ + the row's code, and
      # no token in the URL.
      assert url == "https://meet.example.com/g/#{invite.short_code}"
      assert is_binary(token)
      refute url =~ token

      # And the re-derived link for the persisted row agrees.
      assert Meetings.guest_invite_link(meeting, invite) == url
    end
  end

  describe "invite_guest/2 with no usable host" do
    test "unset: no invite, no link, and the refusal is logged" do
      Application.delete_env(:platform, :meeting_guest_host)
      meeting = create_meeting!()

      log =
        capture_log(fn ->
          assert {:error, :guest_host_not_configured} =
                   Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})
        end)

      assert log =~ "meeting_guest_host"
      # Fail closed all the way: nothing was written, so there is no
      # orphaned invite row (nor the guest chat space it would have owned).
      assert Meetings.list_invites(meeting.id) == []

      # Asserted directly rather than through `list_invites/1`, which could
      # filter: no row, no short code and no guest space for this meeting.
      assert Repo.aggregate(from(i in Invite, where: i.meeting_id == ^meeting.id), :count) == 0

      assert Repo.aggregate(
               from(s in Platform.Chat.Space,
                 where:
                   s.kind == "guest_meeting" and
                     fragment("?->>'meeting_id'", s.metadata) == ^meeting.id
               ),
               :count
             ) == 0
    end

    test "blank string behaves exactly like unset" do
      # The case a nil-only check silently misses.
      Application.put_env(:platform, :meeting_guest_host, "")
      meeting = create_meeting!()

      assert {:error, :guest_host_not_configured} =
               Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      assert Meetings.list_invites(meeting.id) == []
    end

    test "guest_invite_link/2 returns nil rather than a host-less URL" do
      # An existing row minted while the host WAS configured must not turn
      # into "https:///slug/token" (or, now that the row carries a short
      # code, "https:///g/<code>") once the host goes away.
      Application.put_env(:platform, :meeting_guest_host, "meet.example.com")
      meeting = create_meeting!()

      assert {:ok, %{invite: invite}} =
               Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      Application.put_env(:platform, :meeting_guest_host, "")

      assert is_nil(Meetings.guest_invite_link(meeting, invite))
    end
  end
end
