defmodule Platform.Orchestration.ExecutionSpaceTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Orchestration.ExecutionSpace

  @task_id "01234567-89ab-cdef-0123-456789abcdef"

  describe "find_or_create/1" do
    test "creates an execution space for a task" do
      assert {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert space.kind == "execution"
      assert space.name == "task-exec-01234567"
      assert space.metadata["task_id"] == @task_id
    end

    test "is idempotent — returns existing space" do
      {:ok, space1} = ExecutionSpace.find_or_create(@task_id)
      {:ok, space2} = ExecutionSpace.find_or_create(@task_id)
      assert space1.id == space2.id
    end

    test "execution spaces are excluded from list_spaces by default" do
      {:ok, _space} = ExecutionSpace.find_or_create(@task_id)
      spaces = Chat.list_spaces()
      refute Enum.any?(spaces, &(&1.kind == "execution"))
    end

    test "execution spaces are included with include_execution: true" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      spaces = Chat.list_spaces(include_execution: true)
      assert Enum.any?(spaces, &(&1.id == space.id))
    end
  end

  describe "archive/1" do
    test "archives the execution space" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert {:ok, archived} = ExecutionSpace.archive(@task_id)
      assert archived.id == space.id
      assert archived.archived_at != nil
    end

    test "returns error when no space exists" do
      assert {:error, :not_found} = ExecutionSpace.archive("nonexistent-task-id")
    end
  end

  describe "post_log/2" do
    test "posts a log-only message to the execution space" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert {:ok, message} = ExecutionSpace.post_log(space.id, "Task started")
      assert message.content == "Task started"
      assert message.log_only == true
      assert message.content_type == "system"
      assert message.space_id == space.id
    end
  end

  describe "post_engagement/2" do
    test "posts an engagement message to the execution space" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert {:ok, message} = ExecutionSpace.post_engagement(space.id, "Heartbeat prompt")
      assert message.content == "Heartbeat prompt"
      assert message.log_only == false
      assert message.content_type == "text"
      assert message.space_id == space.id
    end

    test "accepts metadata option" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)

      assert {:ok, message} =
               ExecutionSpace.post_engagement(space.id, "Prompt",
                 metadata: %{"reason" => "task_heartbeat"}
               )

      assert message.metadata["reason"] == "task_heartbeat"
      assert message.metadata["source"] == "task_router"
    end
  end

  describe "ensure_system_participant/1" do
    test "creates a system participant" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert {:ok, participant} = ExecutionSpace.ensure_system_participant(space.id)
      assert participant.display_name == "TaskRouter"
      assert participant.participant_type == "agent"
    end

    test "is idempotent" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      {:ok, p1} = ExecutionSpace.ensure_system_participant(space.id)
      {:ok, p2} = ExecutionSpace.ensure_system_participant(space.id)
      assert p1.id == p2.id
    end
  end

  describe "add_participant/2" do
    test "adds an agent participant to the space" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)

      # Create a real agent to add as participant
      {:ok, agent} =
        Platform.Repo.insert(%Platform.Agents.Agent{
          name: "Test Agent",
          slug: "test-agent-#{System.unique_integer([:positive])}",
          runtime_type: "external"
        })

      assert {:ok, participant} = ExecutionSpace.add_participant(space.id, agent.id)
      assert participant.participant_type == "agent"
    end
  end
end
