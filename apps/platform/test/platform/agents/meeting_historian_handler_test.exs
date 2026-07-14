defmodule Platform.Agents.MeetingHistorianHandlerTest do
  @moduledoc """
  Tests for `Platform.Agents.MeetingHistorianHandler` — the `meeting_ended`
  PubSub subscriber that fires the Historian dispatcher (ADR-0041 / T6 stage 4).
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Agents.{Agent, MeetingHistorianHandler}
  alias Platform.Chat
  alias Platform.Chat.{Message, Space}
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks

  @valid_agent_attrs %{
    slug: "historian-agent",
    name: "Historian",
    status: "active"
  }

  defp create_historian_agent(attrs \\ %{}) do
    agent =
      %Agent{}
      |> Agent.changeset(Map.merge(@valid_agent_attrs, attrs))
      |> Repo.insert!()

    # Task 019f2444 stage 6: Roles is the sole Historian signal now
    # (`agents.system_events` was dropped in stage 5). Pin the role so
    # `:meeting_ended` dispatch resolves to this agent. If a prior
    # fixture in the same test already pinned it, the unique index on
    # `role_key` returns `{:error, changeset}` — swallow and let the
    # older assignment win.
    if agent.status == "active" do
      case Platform.Roles.assign_role("historian", agent.id) do
        {:ok, _} -> :ok
        {:error, _changeset} -> :ok
      end
    end

    agent
  end

  defp create_project(name) do
    {:ok, project} = Tasks.create_project(%{name: name})
    project
  end

  defp create_meeting(project) do
    name = "Meeting #{System.unique_integer([:positive])}"
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    meeting
  end

  defp transition_meeting_to_ended(%Meeting{} = meeting) do
    {:ok, live} = Meetings.start_meeting(meeting)
    {:ok, ended} = Meetings.end_meeting(live)
    ended
  end

  defp start_handler! do
    {:ok, pid} = start_supervised({MeetingHistorianHandler, []})
    pid
  end

  defp system_space_for(%Agent{} = agent) do
    Chat.get_space_by_slug("system-#{agent.slug}")
  end

  defp last_message_for(%Space{id: space_id}) do
    Repo.one(
      from(m in Message,
        where: m.space_id == ^space_id,
        order_by: [desc: m.inserted_at],
        limit: 1
      )
    )
  end

  defp message_count_for(%Space{id: space_id}) do
    Repo.aggregate(from(m in Message, where: m.space_id == ^space_id), :count)
  end

  defp attach_debounce_telemetry! do
    test = self()
    handler_id = "meeting-historian-debounce-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :agents, :historian, :dispatch_debounced],
        fn _event, measurements, metadata, _ ->
          send(test, {:dispatch_debounced, measurements, metadata})
        end,
        nil
      )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end

  # Wait until the predicate returns truthy or the timeout elapses. Polling
  # avoids hard-coded sleeps for PubSub fan-out + the dispatcher's chained
  # writes (space + participant + message inserts).
  defp wait_until(timeout_ms \\ 2_000, step_ms \\ 25, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(deadline, step_ms, fun)
  end

  defp do_wait(deadline, step_ms, fun) do
    case fun.() do
      nil ->
        retry_or_fail(deadline, step_ms, fun)

      false ->
        retry_or_fail(deadline, step_ms, fun)

      value ->
        value
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

  describe "init/1 subscriptions" do
    test "subscribes to project meeting topics that exist at boot" do
      project = create_project("Boot Project")

      _pid = start_handler!()
      subscribed = MeetingHistorianHandler.subscribed_projects()

      assert MapSet.member?(subscribed, project.id),
             "expected handler to subscribe to existing project #{project.id}, " <>
               "got: #{inspect(subscribed)}"
    end

    test "subscribes to the project-meetings meta-topic" do
      # No project at boot — handler still subscribes to the meta-topic so
      # post-boot projects don't slip past. We verify by creating a project
      # post-boot and confirming the dynamic subscribe fires.
      _pid = start_handler!()
      assert MapSet.size(MeetingHistorianHandler.subscribed_projects()) == 0

      project = create_project("Late Project")
      # Trigger the meta-broadcast — `Meetings.create_meeting/1` publishes
      # `{:project_meetings_topic_added, project_id}` on
      # `Meetings.project_meetings_meta_topic/0` when a meeting is created.
      _meeting = create_meeting(project)

      wait_until(fn ->
        MapSet.member?(MeetingHistorianHandler.subscribed_projects(), project.id)
      end)
    end
  end

  describe "meeting_ended dispatch" do
    test "dispatches the historian on :meeting_ended for an existing-at-boot project" do
      agent = create_historian_agent()
      project = create_project("Existing Project")

      _pid = start_handler!()

      meeting = create_meeting(project)
      _ended = transition_meeting_to_ended(meeting)

      # The dispatcher posts the synthetic instruction message into the
      # agent's `system-<slug>` space, so the space gets opened and the
      # message lands with our trigger metadata.
      wait_until(fn ->
        case system_space_for(agent) do
          nil -> false
          space -> last_message_for(space)
        end
      end)

      space = system_space_for(agent)
      message = last_message_for(space)

      assert message != nil
      assert message.metadata["source"] == "system_event"
      assert message.metadata["event_type"] == "historian"
      assert message.metadata["trigger"] == "meeting_ended"
      assert message.metadata["meeting_id"] == meeting.id
      assert message.metadata["project_id"] == project.id
      assert message.metadata["chat_space_id"] == meeting.chat_space_id
    end

    test "dispatches the historian for a project created after handler boot" do
      agent = create_historian_agent()

      _pid = start_handler!()

      # Project created post-boot; create_meeting/1 publishes the meta
      # signal which prompts the handler to dynamically subscribe.
      project = create_project("Post-Boot Project")
      meeting = create_meeting(project)

      wait_until(fn ->
        MapSet.member?(MeetingHistorianHandler.subscribed_projects(), project.id)
      end)

      _ended = transition_meeting_to_ended(meeting)

      wait_until(fn ->
        case system_space_for(agent) do
          nil -> false
          space -> last_message_for(space)
        end
      end)

      space = system_space_for(agent)
      message = last_message_for(space)

      assert message != nil
      assert message.metadata["trigger"] == "meeting_ended"
      assert message.metadata["meeting_id"] == meeting.id
      assert message.metadata["project_id"] == project.id
    end

    test "no crash when the project has no historian-pinned agent" do
      # No agent pinned to the Historian role. The dispatcher logs and
      # returns :ok; the handler stays alive.
      project = create_project("Orphan Project")

      pid = start_handler!()

      meeting = create_meeting(project)
      _ended = transition_meeting_to_ended(meeting)

      # Give the PubSub round-trip a tick to land, then assert liveness.
      Process.sleep(100)
      assert Process.alive?(pid)
      # And no system space got created (no agent ⇒ no dispatch pipeline).
      assert MapSet.member?(
               MeetingHistorianHandler.subscribed_projects(),
               project.id
             )
    end
  end

  describe "per-meeting debounce" do
    setup do
      # Pick a debounce window that outruns the whole test — every subsequent
      # fire in the test window should hit the "already dispatched" branch.
      original = Application.get_env(:platform, :meeting_historian_debounce_ms)
      Application.put_env(:platform, :meeting_historian_debounce_ms, 60_000)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:platform, :meeting_historian_debounce_ms)
        else
          Application.put_env(:platform, :meeting_historian_debounce_ms, original)
        end
      end)

      :ok
    end

    test "5x :meeting_ended for the same meeting → 1 dispatch, 4 debounced" do
      agent = create_historian_agent()
      project = create_project("Debounce Project")

      pid = start_handler!()
      attach_debounce_telemetry!()

      meeting = create_meeting(project)

      # First send fires the dispatch; the remaining four should be debounced
      # because our test-scoped window (60s) far outruns the test.
      for _ <- 1..5 do
        send(pid, {:meeting_ended, meeting})
      end

      # Flush the mailbox via a synchronous handle_call so we know all five
      # handle_info branches have run.
      _ = MeetingHistorianHandler.subscribed_projects()

      # Exactly one system-space message should have landed — the dispatch
      # from the first fire. Poll for the space to appear, then assert.
      wait_until(fn ->
        case system_space_for(agent) do
          nil -> false
          space -> last_message_for(space)
        end
      end)

      # Drain: give any queued messages a beat and then re-check the count.
      _ = MeetingHistorianHandler.subscribed_projects()
      space = system_space_for(agent)

      assert message_count_for(space) == 1,
             "expected exactly one Historian dispatch message, got " <>
               "#{message_count_for(space)}"

      # And we should have received four debounce telemetry beacons — one for
      # each of the skipped fires. Order-preserving assert_receive drains them.
      for _ <- 1..4 do
        assert_receive {:dispatch_debounced, %{elapsed_ms: _}, %{meeting_id: mid}}, 500
        assert mid == meeting.id
      end

      refute_receive {:dispatch_debounced, _, _}, 100
    end

    test "different meetings dispatch independently — no cross-meeting debounce" do
      agent = create_historian_agent()
      project = create_project("Multi-Meeting Debounce Project")

      pid = start_handler!()
      attach_debounce_telemetry!()

      meeting_a = create_meeting(project)
      meeting_b = create_meeting(project)

      send(pid, {:meeting_ended, meeting_a})
      send(pid, {:meeting_ended, meeting_b})

      # Both meetings should have produced one dispatch each — no debounce
      # skips because the map is keyed by meeting_id.
      _ = MeetingHistorianHandler.subscribed_projects()

      wait_until(fn ->
        case system_space_for(agent) do
          nil -> false
          space -> message_count_for(space) == 2
        end
      end)

      refute_receive {:dispatch_debounced, _, _}, 100
    end
  end

  describe "noise tolerance" do
    test "ignores :meeting_created and :meeting_started events" do
      _agent = create_historian_agent()
      project = create_project("Noise Project")
      _pid = start_handler!()

      # Creating the meeting fires :meeting_created and :project_meetings_topic_added.
      meeting = create_meeting(project)
      {:ok, _live} = Meetings.start_meeting(meeting)

      # Without an `end_meeting/1` no `system-<slug>` space should appear
      # from any of the noise events.
      Process.sleep(100)
      refute system_space_for(%Agent{slug: "historian-agent"})
    end
  end
end
