defmodule Platform.Meetings.MeetingCancellationTest do
  @moduledoc """
  Tests for the durable meeting-cancellation model (task `019fb954-c848`):
  `Platform.Meetings.cancel_meeting/2`,
  `Platform.Meetings.mark_cancellation_notified/1`, and the
  `{:meeting_cancelled, _}` clause on
  `Platform.Meetings.MeetingNotifier`.

  Cancelled meetings are constructed by calling `cancel_meeting/2` — never by
  writing `status: "cancelled"` through a bare changeset — so the transition
  rule is exercised on every path, not just the one test that names it.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingNotifier
  alias Platform.Repo
  alias Platform.Tasks

  defmodule Recorder do
    @moduledoc """
    Test double for `Platform.Notifications`, mirroring the one in
    `Platform.Meetings.MeetingNotifierTest`. The cancellation tests here
    assert on the persisted stamp rather than on the push, but the notifier's
    `fan_out/1` calls the notifications module unconditionally, so a double
    has to exist or the real Push pipeline runs.
    """
    def install(pid \\ self()) do
      :persistent_term.put({__MODULE__, :owner}, pid)
    end

    def fan_out_to_humans(participant_ids, payload, opts \\ []) do
      notify({:notif, participant_ids, payload, opts})
    end

    def fan_out_to_user(user_id, payload, _opts \\ []) do
      notify({:notif_user, user_id, payload})
    end

    defp notify(msg) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, msg)
      end

      :ok
    end
  end

  setup do
    Application.put_env(:platform, :notifications_module, Recorder)
    Recorder.install(self())

    on_exit(fn ->
      Application.delete_env(:platform, :notifications_module)
    end)

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp create_project(name) do
    {:ok, project} = Tasks.create_project(%{name: name})
    project
  end

  defp create_meeting(project, name) do
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    meeting
  end

  defp add_user_participant(meeting, display_name) do
    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    participant
  end

  defp start_meeting!(meeting) do
    {:ok, live} = Meetings.start_meeting(meeting)
    live
  end

  defp end_meeting!(meeting) do
    {:ok, ended} = Meetings.end_meeting(meeting)
    ended
  end

  defp start_notifier! do
    {:ok, pid} = start_supervised({MeetingNotifier, []})
    pid
  end

  defp wait_until(timeout_ms \\ 2_000, step_ms \\ 25, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(deadline, step_ms, fun)
  end

  defp do_wait(deadline, step_ms, fun) do
    case fun.() do
      nil -> retry_or_fail(deadline, step_ms, fun)
      false -> retry_or_fail(deadline, step_ms, fun)
      value -> value
    end
  end

  defp retry_or_fail(deadline, step_ms, fun) do
    if System.monotonic_time(:millisecond) >= deadline do
      ExUnit.Assertions.flunk("wait_until predicate did not become truthy within deadline")
    else
      Process.sleep(step_ms)
      do_wait(deadline, step_ms, fun)
    end
  end

  # ── cancel_meeting/2 ───────────────────────────────────────────────────────

  describe "cancel_meeting/2" do
    test "cancels a scheduled meeting, stamping the time and the actor" do
      project = create_project("Cancel Scheduled Project")
      meeting = create_meeting(project, "Scheduled Standup")
      actor = add_user_participant(meeting, "Alice")

      assert meeting.status == "scheduled"

      assert {:ok, cancelled} = Meetings.cancel_meeting(meeting, actor.id)

      assert cancelled.status == "cancelled"
      assert cancelled.cancelled_by_participant_id == actor.id
      assert %DateTime{} = cancelled.cancelled_at

      # The returned struct is not evidence on its own — read it back.
      persisted = Repo.get!(Meeting, meeting.id)
      assert persisted.status == "cancelled"
      assert persisted.cancelled_by_participant_id == actor.id
      assert DateTime.compare(persisted.cancelled_at, cancelled.cancelled_at) == :eq
    end

    test "cancels a live meeting, stamping the time and the actor" do
      project = create_project("Cancel Live Project")
      meeting = project |> create_meeting("Live Standup") |> start_meeting!()
      actor = add_user_participant(meeting, "Bob")

      assert meeting.status == "live"

      assert {:ok, cancelled} = Meetings.cancel_meeting(meeting, actor.id)

      assert cancelled.status == "cancelled"
      assert cancelled.cancelled_by_participant_id == actor.id
      assert %DateTime{} = cancelled.cancelled_at

      persisted = Repo.get!(Meeting, meeting.id)
      assert persisted.status == "cancelled"
      assert persisted.cancelled_by_participant_id == actor.id

      # Starting stamped `started_at`; cancelling must not erase the actual.
      assert %DateTime{} = persisted.started_at
    end

    test "refuses to cancel an ended meeting, with the error on :status" do
      project = create_project("Cancel Ended Project")

      meeting =
        project
        |> create_meeting("Finished Standup")
        |> start_meeting!()
        |> end_meeting!()

      actor = add_user_participant(meeting, "Carol")

      assert meeting.status == "ended"

      assert {:error, changeset} = Meetings.cancel_meeting(meeting, actor.id)

      # Attributable: the rejection is the transition rule on :status, not a
      # constraint or a required-field miss somewhere else on the row.
      assert [status: {message, _}] = changeset.errors
      assert message == "illegal transition from ended to cancelled"

      # And nothing was written.
      persisted = Repo.get!(Meeting, meeting.id)
      assert persisted.status == "ended"
      assert is_nil(persisted.cancelled_at)
      assert is_nil(persisted.cancelled_by_participant_id)
    end
  end

  # ── mark_cancellation_notified/1 ───────────────────────────────────────────

  describe "mark_cancellation_notified/1" do
    test "the first call claims the stamp" do
      project = create_project("CAS First Project")
      meeting = create_meeting(project, "CAS Standup")
      actor = add_user_participant(meeting, "Dave")

      {:ok, cancelled} = Meetings.cancel_meeting(meeting, actor.id)
      assert is_nil(cancelled.cancellation_notified_at)

      assert {:ok, claimed} = Meetings.mark_cancellation_notified(cancelled)
      assert %DateTime{} = claimed.cancellation_notified_at

      persisted = Repo.get!(Meeting, meeting.id)

      assert DateTime.compare(
               persisted.cancellation_notified_at,
               claimed.cancellation_notified_at
             ) ==
               :eq
    end

    test "a second call loses the race AND leaves the stored stamp untouched" do
      project = create_project("CAS Second Project")
      meeting = create_meeting(project, "CAS Twice Standup")
      actor = add_user_participant(meeting, "Erin")

      {:ok, cancelled} = Meetings.cancel_meeting(meeting, actor.id)

      {:ok, claimed} = Meetings.mark_cancellation_notified(cancelled)
      first_stamp = Repo.get!(Meeting, meeting.id).cancellation_notified_at

      # Re-read from the DB so the second caller carries the winner's stamp,
      # which is what a second GenServer message would actually look like.
      reloaded = Repo.get!(Meeting, meeting.id)

      assert {:already_notified, ^reloaded} = Meetings.mark_cancellation_notified(reloaded)

      # THE killing assertion. The return tuple alone does not distinguish a
      # correct implementation from one that re-stamps and then reports
      # `:already_notified` anyway — only the persisted value does. Equality,
      # not a bare `assert`: a re-stamped value is still a %DateTime{}.
      second_stamp = Repo.get!(Meeting, meeting.id).cancellation_notified_at
      assert second_stamp == first_stamp
      assert second_stamp == claimed.cancellation_notified_at
    end

    test "a stale struct still loses the race against a stamped row" do
      project = create_project("CAS Stale Project")
      meeting = create_meeting(project, "CAS Stale Standup")
      actor = add_user_participant(meeting, "Frank")

      {:ok, cancelled} = Meetings.cancel_meeting(meeting, actor.id)

      # `cancelled` has `cancellation_notified_at: nil` in memory, so it takes
      # the nil-guarded head — the SQL `WHERE ... IS NULL` is what has to
      # reject it, not the function-head pattern match.
      {:ok, _claimed} = Meetings.mark_cancellation_notified(cancelled)
      first_stamp = Repo.get!(Meeting, meeting.id).cancellation_notified_at

      assert {:already_notified, _} = Meetings.mark_cancellation_notified(cancelled)

      assert Repo.get!(Meeting, meeting.id).cancellation_notified_at == first_stamp
    end
  end

  # ── MeetingNotifier wire-in ────────────────────────────────────────────────

  describe "meeting_cancelled dispatch" do
    test "the notifier stamps cancellation_notified_at on the broadcast" do
      project = create_project("Notifier Cancel Project")
      _pid = start_notifier!()

      meeting = create_meeting(project, "Notifier Standup")
      actor = add_user_participant(meeting, "Grace")
      _attendee = add_user_participant(meeting, "Heidi")

      {:ok, cancelled} = Meetings.cancel_meeting(meeting, actor.id)

      # Nothing but the notifier stamps this column: `cancel_meeting/2`
      # returned a row with it still nil, so a non-nil value later can only
      # have come from the `{:meeting_cancelled, _}` clause.
      assert is_nil(cancelled.cancellation_notified_at)

      wait_until(fn ->
        Repo.get!(Meeting, meeting.id).cancellation_notified_at
      end)

      assert %DateTime{} = Repo.get!(Meeting, meeting.id).cancellation_notified_at
    end

    test "starting a meeting does not stamp the cancellation column" do
      project = create_project("Notifier Start Only Project")
      _pid = start_notifier!()

      meeting = create_meeting(project, "Start Only Standup")
      _attendee = add_user_participant(meeting, "Ivan")

      {:ok, started} = Meetings.start_meeting(meeting)

      # The `:meeting_started` path claims `notified_at`. Wait on THAT, so the
      # assertion below runs after the notifier has demonstrably handled the
      # message rather than before it got there.
      wait_until(fn -> Repo.get!(Meeting, started.id).notified_at end)

      assert is_nil(Repo.get!(Meeting, started.id).cancellation_notified_at)
    end
  end
end
