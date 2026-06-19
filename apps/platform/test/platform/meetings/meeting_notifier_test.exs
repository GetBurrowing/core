defmodule Platform.Meetings.MeetingNotifierTest do
  @moduledoc """
  Tests for `Platform.Meetings.MeetingNotifier` — the GenServer that fans
  out push notifications on `:meeting_started`.

  Uses a test-double recorder (`Platform.Meetings.MeetingNotifierTest.Recorder`)
  injected via `:notifications_module` to assert recipient lists and payloads
  without exercising the real `Platform.Notifications.fan_out_to_humans/3`
  Push pipeline.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.MeetingNotifier
  alias Platform.Tasks

  defmodule Recorder do
    @moduledoc """
    Test double for `Platform.Notifications`. Records each
    `fan_out_to_humans/3` call as `{:notif, participant_ids, payload, opts}`
    so tests can `assert_receive` against the captured args.
    """
    def install(pid \\ self()) do
      :persistent_term.put({__MODULE__, :owner}, pid)
    end

    def fan_out_to_humans(participant_ids, payload, opts \\ []) do
      owner = :persistent_term.get({__MODULE__, :owner}, nil)

      if owner do
        send(owner, {:notif, participant_ids, payload, opts})
      end

      :ok
    end
  end

  setup do
    # Swap the runtime `:notifications_module` lookup to our recorder, and
    # install `self()` as the message destination so `assert_receive` can
    # observe each fan-out call.
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

  defp create_meeting(project, opts) do
    name = Keyword.get(opts, :name, "Meeting #{System.unique_integer([:positive])}")
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    meeting
  end

  defp add_user_participant(meeting, opts) do
    user_id = Keyword.get(opts, :user_id, Ecto.UUID.generate())
    display_name = Keyword.get(opts, :display_name)

    {:ok, p} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
  end

  defp add_agent_participant(meeting) do
    agent_id = Ecto.UUID.generate()

    {:ok, p} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "agent",
        participant_id: agent_id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp assign_host(meeting, %{id: participant_id}) do
    meeting
    |> Ecto.Changeset.change(host_participant_id: participant_id)
    |> Platform.Repo.update!()
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

  # ── Subscription tests ─────────────────────────────────────────────────────

  describe "init/1 subscriptions" do
    test "subscribes to project meeting topics that exist at boot" do
      project = create_project("Boot Project")

      _pid = start_notifier!()
      subscribed = MeetingNotifier.subscribed_projects()

      assert MapSet.member?(subscribed, project.id),
             "expected notifier to subscribe to existing project #{project.id}, " <>
               "got: #{inspect(subscribed)}"
    end

    test "subscribes to the projects:lifecycle topic" do
      # No project at boot — notifier still subscribes to the lifecycle topic
      # so post-boot projects don't slip past. Verify by creating a project
      # post-boot and confirming the dynamic subscribe fires.
      _pid = start_notifier!()
      refute MapSet.member?(MeetingNotifier.subscribed_projects(), "bogus")

      project = create_project("Late Project")

      wait_until(fn ->
        MapSet.member?(MeetingNotifier.subscribed_projects(), project.id)
      end)
    end
  end

  # ── meeting_started dispatch ───────────────────────────────────────────────

  describe "meeting_started dispatch" do
    test "fans out to human participants with the expected payload" do
      project = create_project("Standup Project")
      _pid = start_notifier!()

      meeting = create_meeting(project, name: "Standup")
      host = add_user_participant(meeting, display_name: "Alice")
      _alice = add_user_participant(meeting, display_name: "Bob")
      _bob = add_user_participant(meeting, display_name: "Carol")
      meeting = assign_host(meeting, host)

      {:ok, _live} = Meetings.start_meeting(meeting)

      assert_receive {:notif, recipients, payload, opts}, 2_000

      # All three human participants are in the unfiltered recipient list;
      # the host is excluded via opts so fan_out_to_humans drops them.
      assert length(recipients) == 3
      assert host.id in recipients
      assert Keyword.get(opts, :exclude_participant_id) == host.id
      assert payload.title == "Alice started a meeting"
      assert payload.body == "Standup"
      assert payload.url == "/meetings/#{meeting.slug}"
    end

    test "falls back to 'Someone' when host has no display_name" do
      project = create_project("Anon Project")
      _pid = start_notifier!()

      meeting = create_meeting(project, name: "Mystery")
      host = add_user_participant(meeting, display_name: nil)
      meeting = assign_host(meeting, host)

      {:ok, _live} = Meetings.start_meeting(meeting)

      assert_receive {:notif, _recipients, payload, _opts}, 2_000
      assert payload.title == "Someone started a meeting"
    end

    test "falls back to 'Someone' when meeting has no host_participant" do
      project = create_project("Hostless Project")
      _pid = start_notifier!()

      meeting = create_meeting(project, name: "Anon")
      # No host assigned; no participants.

      {:ok, _live} = Meetings.start_meeting(meeting)

      assert_receive {:notif, _recipients, payload, _opts}, 2_000
      assert payload.title == "Someone started a meeting"
    end

    test "agent participants are excluded from the recipient list" do
      project = create_project("Mixed Project")
      _pid = start_notifier!()

      meeting = create_meeting(project, name: "Mixed")
      user_p = add_user_participant(meeting, display_name: "Dave")
      agent_p = add_agent_participant(meeting)

      {:ok, _live} = Meetings.start_meeting(meeting)

      assert_receive {:notif, recipients, _payload, _opts}, 2_000
      assert user_p.id in recipients
      refute agent_p.id in recipients
    end

    test "sender exclusion: host's participant_id passed in opts" do
      project = create_project("Sender Project")
      _pid = start_notifier!()

      meeting = create_meeting(project, name: "Sender")
      host = add_user_participant(meeting, display_name: "Eve")
      _other = add_user_participant(meeting, display_name: "Frank")
      meeting = assign_host(meeting, host)

      {:ok, _live} = Meetings.start_meeting(meeting)

      assert_receive {:notif, _recipients, _payload, opts}, 2_000
      assert Keyword.get(opts, :exclude_participant_id) == host.id
    end

    test ":project_created subscription fires for post-boot projects" do
      # Notifier starts with no projects. Create one AFTER startup, then
      # create+start a meeting in it; assert the notification fires (proves
      # dynamic subscription via projects:lifecycle works).
      _pid = start_notifier!()

      project = create_project("Post-Boot Project")

      wait_until(fn ->
        MapSet.member?(MeetingNotifier.subscribed_projects(), project.id)
      end)

      meeting = create_meeting(project, name: "Late Meeting")
      _host = add_user_participant(meeting, display_name: "Gail")

      {:ok, _live} = Meetings.start_meeting(meeting)

      assert_receive {:notif, _recipients, payload, _opts}, 2_000
      assert payload.body == "Late Meeting"
    end
  end

  # ── Idempotency (notified_at CAS) ─────────────────────────────────────────
  #
  # Stage 3 of task 019edbc1 added `meetings.notified_at` + an atomic CAS
  # via `Meetings.mark_notified/1`, wired into the
  # `{:meeting_started, _}` handler. Two broadcasts for the same meeting
  # must result in exactly ONE call to the fan-out recorder.

  describe "idempotent fan-out (notified_at)" do
    test "two :meeting_started broadcasts for the same meeting fan out exactly once" do
      project = create_project("Idempotent Project")
      _pid = start_notifier!()

      meeting = create_meeting(project, name: "OnlyOnce")
      _host = add_user_participant(meeting, display_name: "Iris")

      # First start: real transition scheduled→live, then a real broadcast.
      {:ok, live} = Meetings.start_meeting(meeting)
      assert_receive {:notif, _, payload, _}, 2_000
      assert payload.body == "OnlyOnce"

      # Simulate a second-fan-out attempt by re-broadcasting on the project
      # topic. `start_meeting/1` won't double-broadcast (changeset rejects
      # live→live) but the underlying race the CAS column defends against
      # IS another caller landing a second `{:meeting_started, _}` payload
      # before the column is stamped. Reuse the exact PubSub topic the
      # notifier listens on and confirm the handler swallows the duplicate.
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Meetings.project_meetings_topic(project.id),
        {:meeting_started, live}
      )

      refute_receive {:notif, _, _, _}, 250
    end
  end

  # ── Noise tolerance ───────────────────────────────────────────────────────

  describe "noise tolerance" do
    test "ignores :meeting_created and :meeting_ended events" do
      project = create_project("Noise Project")
      _pid = start_notifier!()

      meeting = create_meeting(project, name: "Noisy")
      _host = add_user_participant(meeting, display_name: "Hank")

      # No fan-out on :meeting_created.
      refute_receive {:notif, _, _, _}, 200

      {:ok, live} = Meetings.start_meeting(meeting)
      # Drain the :meeting_started fan-out (the one we DO care about).
      assert_receive {:notif, _, _, _}, 2_000

      {:ok, _ended} = Meetings.end_meeting(live)
      # No second fan-out from :meeting_ended.
      refute_receive {:notif, _, _, _}, 200
    end
  end
end
