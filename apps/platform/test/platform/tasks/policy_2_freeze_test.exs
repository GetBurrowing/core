defmodule Platform.Tasks.Policy2FreezeTest do
  @moduledoc """
  Tests the Policy 2 task-scoped freeze trigger wired into
  `Platform.Tasks.transition_task/2` (task
  `019e1e80-4230-7a79-ac73-c157975b3999` Stage 3).

  See `apps/platform/audit/2026-05-13-policy-2-freeze-trigger/design.md`
  for the atomicity contract and the execution-space-binding rationale.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskRecord

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp unique_int, do: System.unique_integer([:positive, :monotonic])

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Policy2 Test #{unique_int()}",
        slug: "policy2-#{unique_int()}"
      })

    project
  end

  defp create_task_with_approved_plan(project, agent_id) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Policy 2 freeze target",
        status: "planning",
        assignee_type: "agent",
        assignee_id: agent_id
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    plan
    |> Ecto.Changeset.change(%{status: "pending_review"})
    |> Repo.update!()

    {:ok, _approved} =
      Tasks.approve_plan(
        Repo.get!(Platform.Tasks.Plan, plan.id),
        Ecto.UUID.generate()
      )

    # After approve_plan, the task auto-transitions to in_progress via
    # apply_dispatch_gate. For these tests we want to drive the transition
    # ourselves, so reset to planning.
    task = Repo.get!(TaskRecord, task.id)

    task
    |> Ecto.Changeset.change(%{status: "planning"})
    |> Repo.update!()
  end

  defp create_exec_space_with_messages(task, agent_id, message_count) do
    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    {:ok, agent_participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent_id,
        joined_at: DateTime.utc_now(),
        display_name: "Saru"
      })

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: "Author"
      })

    messages =
      for i <- 1..message_count do
        {:ok, msg} =
          Chat.post_message(%{
            space_id: space.id,
            participant_id: author.id,
            content_type: "text",
            content: "message #{i}"
          })

        msg
      end

    {space, agent_participant, author, messages}
  end

  # ── Happy path: task → in_progress freezes exec-space messages ─────────────

  describe "transition_task/2 → :in_progress with Policy 2 freeze" do
    test "freezes all non-frozen messages in the task's execution space" do
      project = create_project()
      agent_id = Ecto.UUID.generate()
      task = create_task_with_approved_plan(project, agent_id)

      {_space, agent_participant, _author, [msg1, msg2]} =
        create_exec_space_with_messages(task, agent_id, 2)

      # Both messages start unfrozen.
      assert is_nil(Repo.get!(Platform.Chat.Message, msg1.id).frozen_at)
      assert is_nil(Repo.get!(Platform.Chat.Message, msg2.id).frozen_at)

      # Transition task -> :in_progress.
      assert {:ok, updated_task} = Tasks.transition_task(task, "in_progress")
      assert updated_task.status == "in_progress"

      # Both messages now have frozen_at set, frozen_by the agent's
      # participant id in the exec space.
      refreshed1 = Repo.get!(Platform.Chat.Message, msg1.id)
      refreshed2 = Repo.get!(Platform.Chat.Message, msg2.id)
      assert %DateTime{} = refreshed1.frozen_at
      assert %DateTime{} = refreshed2.frozen_at
      assert refreshed1.frozen_by_participant_id == agent_participant.id
      assert refreshed2.frozen_by_participant_id == agent_participant.id
    end

    test "broadcasts {:messages_frozen, ids, %{reason, task_id}} on the space topic" do
      project = create_project()
      agent_id = Ecto.UUID.generate()
      task = create_task_with_approved_plan(project, agent_id)

      {space, _agent_p, _author, [msg]} =
        create_exec_space_with_messages(task, agent_id, 1)

      # Subscribe to the chat topic the production code broadcasts on.
      Platform.Chat.PubSub.subscribe(space.id)

      assert {:ok, _updated} = Tasks.transition_task(task, "in_progress")

      assert_receive {:messages_frozen, ids, %{reason: :task_in_progress, task_id: tid}}, 1_000
      assert ids == [msg.id]
      assert tid == task.id
    end

    test "does NOT re-freeze already-frozen messages or change frozen_by audit" do
      project = create_project()
      agent_id = Ecto.UUID.generate()
      task = create_task_with_approved_plan(project, agent_id)

      {space, agent_participant, _author, [msg]} =
        create_exec_space_with_messages(task, agent_id, 1)

      # Pre-freeze with a different real participant.
      {:ok, other_participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          joined_at: DateTime.utc_now(),
          display_name: "PriorFreezer"
        })

      other_participant_id = other_participant.id
      original_frozen_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      msg
      |> Platform.Chat.Message.changeset(%{
        frozen_at: original_frozen_at,
        frozen_by_participant_id: other_participant_id
      })
      |> Repo.update!()

      # Transition the task — the already-frozen message must NOT have its
      # frozen_by audit overwritten (MessageVersions.freeze/2 is idempotent
      # on already-frozen messages).
      assert {:ok, _} = Tasks.transition_task(task, "in_progress")

      refreshed = Repo.get!(Platform.Chat.Message, msg.id)
      assert refreshed.frozen_by_participant_id == other_participant_id
      assert DateTime.compare(refreshed.frozen_at, original_frozen_at) == :eq
      refute refreshed.frozen_by_participant_id == agent_participant.id
    end
  end

  # ── Non-:in_progress transitions: freeze path skipped ──────────────────────

  describe "transition_task/2 → other statuses leave messages alone" do
    test "transitioning to :blocked does NOT freeze exec-space messages" do
      project = create_project()
      agent_id = Ecto.UUID.generate()
      task = create_task_with_approved_plan(project, agent_id)

      {_space, _agent_p, _author, [msg]} =
        create_exec_space_with_messages(task, agent_id, 1)

      assert {:ok, _updated} = Tasks.transition_task(task, "blocked")

      refreshed = Repo.get!(Platform.Chat.Message, msg.id)
      assert is_nil(refreshed.frozen_at)
    end
  end

  # ── Policy 2 also fires on the approve_plan auto-dispatch path ─────────────

  describe "approve_plan/2 → auto-dispatch :in_progress fires Policy 2 freeze" do
    test "messages in the task's exec space are frozen when approve_plan auto-dispatches" do
      # Reproduces the code-reviewer HIGH finding: previously
      # `apply_dispatch_gate` called `transition_task_status` directly,
      # bypassing the Policy 2 freeze. The fix wires the freeze into the
      # same approve_plan transaction; this test guards against regression.
      project = create_project()
      agent_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Auto-dispatch freeze target",
          status: "planning",
          assignee_type: "agent",
          assignee_id: agent_id
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      plan
      |> Ecto.Changeset.change(%{status: "pending_review"})
      |> Repo.update!()

      # Seed the exec space + agent participant + a message — same shape
      # as the happy-path test, but the freeze will be triggered by
      # approve_plan (not by transition_task).
      {_space, agent_participant, _author, [msg]} =
        create_exec_space_with_messages(task, agent_id, 1)

      assert is_nil(Repo.get!(Platform.Chat.Message, msg.id).frozen_at)

      pending = Repo.get!(Platform.Tasks.Plan, plan.id)
      assert {:ok, _approved} = Tasks.approve_plan(pending, Ecto.UUID.generate())

      # Task auto-dispatched to :in_progress AND the message is frozen
      # by the agent's participant.
      refreshed_task = Repo.get!(TaskRecord, task.id)
      assert refreshed_task.status == "in_progress"

      refreshed_msg = Repo.get!(Platform.Chat.Message, msg.id)
      assert %DateTime{} = refreshed_msg.frozen_at
      assert refreshed_msg.frozen_by_participant_id == agent_participant.id
    end
  end

  # ── No-exec-space + no-actor: graceful skip rather than block ──────────────

  describe "transition_task/2 graceful-skip paths" do
    test "task with no execution space still transitions to :in_progress" do
      project = create_project()
      agent_id = Ecto.UUID.generate()
      task = create_task_with_approved_plan(project, agent_id)

      # No execution space created — find_by_task_id returns nil.
      assert {:ok, updated} = Tasks.transition_task(task, "in_progress")
      assert updated.status == "in_progress"
    end

    test "task with exec space but no resolvable assignee participant transitions, skips freeze" do
      project = create_project()
      agent_id = Ecto.UUID.generate()
      task = create_task_with_approved_plan(project, agent_id)

      # Create the exec space, but DON'T add a participant whose
      # participant_id matches agent_id. resolve_freeze_actor returns nil,
      # warning logged, messages stay unfrozen.
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      {:ok, author} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          joined_at: DateTime.utc_now(),
          display_name: "OnlyUser"
        })

      {:ok, msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "unrelated"
        })

      assert {:ok, updated} = Tasks.transition_task(task, "in_progress")
      assert updated.status == "in_progress"

      refreshed = Repo.get!(Platform.Chat.Message, msg.id)
      assert is_nil(refreshed.frozen_at)
    end
  end
end
