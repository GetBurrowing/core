defmodule Platform.Tasks.BlockedCauseTest do
  @moduledoc """
  Task 01a0e7ac stage 1: a router escalation records WHY the task is blocked
  as a machine-readable, episode-scoped `metadata["blocked_cause"]`, beside
  the prose `blocked_reason` sentence.

  - `Tasks.stamp_blocked_reason/3` with a `:cause` writes the five keys and
    the status the task held BEFORE the block.
  - `Tasks.stamp_blocked_reason/2` (no cause) deletes any existing cause, so
    a later escalation of a different kind never inherits it.
  - Every transition OUT of `blocked` clears the cause on the same changeset
    as the status flip; `blocked_reason` persists by design.
  """

  use Platform.DataCase, async: true

  alias Platform.Tasks

  @cause %{
    kind: "execution.no_ack_timeout",
    stage_id: "stage-cause-1",
    runtime_id: "runtime-cause-1"
  }

  setup do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Blocked Cause #{n}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Blocked cause #{n}",
        description: "Pin the blocked_cause stamp"
      })

    {:ok, task} = Tasks.transition_task_status(task, "in_progress")
    %{task: task}
  end

  describe "stamp_blocked_reason/3 with a cause" do
    test "blocks the task and writes all five cause keys, recording the prior status",
         %{task: task} do
      assert {:ok, blocked} = Tasks.stamp_blocked_reason(task, "no ack", cause: @cause)

      assert blocked.status == "blocked"
      cause = Tasks.get_task_record(task.id).metadata["blocked_cause"]

      assert %{
               "kind" => "execution.no_ack_timeout",
               "stage_id" => "stage-cause-1",
               "runtime_id" => "runtime-cause-1",
               "prior_status" => "in_progress",
               "at" => at
             } = cause

      assert Map.keys(cause) |> Enum.sort() ==
               ~w(at kind prior_status runtime_id stage_id)

      assert {:ok, _, _} = DateTime.from_iso8601(at)
      assert Tasks.get_task_record(task.id).metadata["blocked_reason"] == "no ack"
    end

    test "re-stamping an already-blocked task keeps the original prior_status", %{task: task} do
      {:ok, _} = Tasks.stamp_blocked_reason(task, "first", cause: @cause)

      {:ok, _} =
        Tasks.stamp_blocked_reason(task.id, "second",
          cause: %{@cause | kind: "execution.safety_net_fired"}
        )

      cause = Tasks.get_task_record(task.id).metadata["blocked_cause"]
      assert cause["kind"] == "execution.safety_net_fired"
      assert cause["prior_status"] == "in_progress"
    end

    test "a caused stamp on a task blocked WITHOUT a cause records a nil prior_status",
         %{task: task} do
      {:ok, _} = Tasks.stamp_blocked_reason(task, "uncaused")
      {:ok, _} = Tasks.stamp_blocked_reason(task.id, "caused", cause: @cause)

      cause = Tasks.get_task_record(task.id).metadata["blocked_cause"]
      assert cause["kind"] == "execution.no_ack_timeout"
      assert Map.has_key?(cause, "prior_status")
      assert cause["prior_status"] == nil
    end

    test "keeps unmet_dependencies on the loaded metadata map", %{task: task} do
      {:ok, task} = Tasks.update_task(task, %{metadata: %{"unmet_dependencies" => ["dep-1"]}})
      {:ok, _} = Tasks.stamp_blocked_reason(task, "no ack", cause: @cause)

      metadata = Tasks.get_task_record(task.id).metadata
      assert metadata["unmet_dependencies"] == ["dep-1"]
      assert metadata["blocked_cause"]["kind"] == "execution.no_ack_timeout"
    end
  end

  describe "stamp_blocked_reason/2 over a caused block" do
    test "deletes blocked_cause but keeps the new blocked_reason", %{task: task} do
      {:ok, _} = Tasks.stamp_blocked_reason(task, "no ack", cause: @cause)
      assert Tasks.get_task_record(task.id).metadata["blocked_cause"]

      {:ok, _} = Tasks.stamp_blocked_reason(task.id, "a different escalation")

      metadata = Tasks.get_task_record(task.id).metadata
      refute Map.has_key?(metadata, "blocked_cause")
      assert metadata["blocked_reason"] == "a different escalation"
      assert metadata["blocked_reason_at"]
    end
  end

  describe "transitions and the cause" do
    test "blocked -> in_progress clears blocked_cause and keeps the other stamps",
         %{task: task} do
      {:ok, task} = Tasks.update_task(task, %{metadata: %{"unmet_dependencies" => ["dep-1"]}})
      {:ok, blocked} = Tasks.stamp_blocked_reason(task, "no ack", cause: @cause)
      before = Tasks.get_task_record(task.id).metadata
      assert before["blocked_cause"]

      assert {:ok, resumed} = Tasks.transition_task_status(blocked, "in_progress")
      assert resumed.status == "in_progress"

      metadata = Tasks.get_task_record(task.id).metadata
      refute Map.has_key?(metadata, "blocked_cause")
      assert metadata["blocked_reason"] == "no ack"
      assert metadata["blocked_reason_at"] == before["blocked_reason_at"]
      assert metadata["unmet_dependencies"] == ["dep-1"]
    end

    test "every exit from blocked clears the cause", %{task: task} do
      exited =
        for target <- ~w(backlog planning in_review deploying cancelled),
            reduce: [] do
          acc ->
            {:ok, fresh} =
              Tasks.create_task(%{
                project_id: task.project_id,
                title: "exit to #{target}",
                description: "exit"
              })

            {:ok, fresh} = Tasks.transition_task_status(fresh, "in_progress")
            {:ok, blocked} = Tasks.stamp_blocked_reason(fresh, "no ack", cause: @cause)

            case Tasks.transition_task_status(blocked, target) do
              {:ok, _} ->
                refute Map.has_key?(
                         Tasks.get_task_record(fresh.id).metadata,
                         "blocked_cause"
                       ),
                       "exit blocked -> #{target} kept blocked_cause"

                [target | acc]

              {:error, _} ->
                # A guard unrelated to the cause refused this edge.
                acc
            end
        end

      # Without this, a run in which every edge was refused would pass.
      assert "backlog" in exited
      assert "cancelled" in exited
    end

    test "a board drop out of blocked clears the cause", %{task: task} do
      {:ok, blocked} = Tasks.stamp_blocked_reason(task, "no ack", cause: @cause)
      assert Tasks.get_task_record(task.id).metadata["blocked_cause"]

      assert {:ok, dropped} = Tasks.drop_task_to_column(blocked, "backlog")
      assert dropped.status == "backlog"

      metadata = Tasks.get_task_record(task.id).metadata
      refute Map.has_key?(metadata, "blocked_cause")
      assert metadata["blocked_reason"] == "no ack"
    end

    test "a transition that does not leave blocked leaves blocked_cause alone", %{task: task} do
      planted = %{"kind" => "execution.no_ack_timeout", "prior_status" => "in_progress"}
      {:ok, task} = Tasks.update_task(task, %{metadata: %{"blocked_cause" => planted}})

      assert {:ok, moved} = Tasks.transition_task_status(task, "in_review")
      assert moved.status == "in_review"
      assert Tasks.get_task_record(task.id).metadata["blocked_cause"] == planted
    end
  end
end
