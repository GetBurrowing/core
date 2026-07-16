defmodule Platform.Orchestration.ExecutionLeaseTest do
  @moduledoc """
  Schema-level coverage for the stage-scoped lease keying introduced by
  the router arch fix (task 019f6791 stage 1).

  Two concerns:

    * `changeset/2` must cast `:stage_id` and preserve it on the struct.
    * The partial unique index `execution_leases_active_stage_unique_idx`
      must permit two active leases for the same `(task_id, phase,
      runtime_id)` when their `stage_id`s differ, and must still reject
      duplicates when all four columns match.

  These tests are the guardrail for stages 2 and 3 — if this file
  starts failing, the storage layer contract has drifted and the
  router-side stage-scoped helpers will silently misroute.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.ExecutionLease
  alias Platform.Repo
  alias Platform.Tasks

  defp create_task! do
    {:ok, project} =
      Tasks.create_project(%{name: "Lease Schema Project #{System.unique_integer([:positive])}"})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Lease Schema Task"})
    task
  end

  defp now_usec, do: DateTime.utc_now()

  defp base_attrs(task, opts \\ []) do
    %{
      task_id: task.id,
      phase: Keyword.get(opts, :phase, "execution"),
      runtime_id: Keyword.get(opts, :runtime_id, "runtime:test"),
      status: Keyword.get(opts, :status, "active"),
      started_at: now_usec(),
      expires_at: DateTime.add(now_usec(), 900, :second),
      stage_id: Keyword.get(opts, :stage_id, nil)
    }
  end

  describe "changeset/2 with :stage_id" do
    test "casts :stage_id when provided" do
      task = create_task!()
      stage_id = Ecto.UUID.generate()

      changeset =
        ExecutionLease.changeset(%ExecutionLease{}, base_attrs(task, stage_id: stage_id))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :stage_id) == stage_id
    end

    test "accepts nil :stage_id (legacy / pre-plan callers)" do
      task = create_task!()

      changeset = ExecutionLease.changeset(%ExecutionLease{}, base_attrs(task))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :stage_id) == nil
    end
  end

  describe "execution_leases_active_stage_unique_idx" do
    test "two active leases for the same task/phase/runtime with distinct stage_id both persist" do
      task = create_task!()
      stage_a = Ecto.UUID.generate()
      stage_b = Ecto.UUID.generate()

      assert {:ok, lease_a} =
               %ExecutionLease{}
               |> ExecutionLease.changeset(base_attrs(task, stage_id: stage_a))
               |> Repo.insert()

      assert {:ok, lease_b} =
               %ExecutionLease{}
               |> ExecutionLease.changeset(base_attrs(task, stage_id: stage_b))
               |> Repo.insert()

      assert lease_a.id != lease_b.id
      assert lease_a.stage_id == stage_a
      assert lease_b.stage_id == stage_b
    end

    test "two active leases sharing (task_id, phase, runtime_id, stage_id) conflict on the new index" do
      task = create_task!()
      stage_id = Ecto.UUID.generate()

      assert {:ok, _first} =
               %ExecutionLease{}
               |> ExecutionLease.changeset(base_attrs(task, stage_id: stage_id))
               |> Repo.insert()

      assert {:error, changeset} =
               %ExecutionLease{}
               |> ExecutionLease.changeset(base_attrs(task, stage_id: stage_id))
               |> Repo.insert()

      refute changeset.valid?

      assert Enum.any?(changeset.errors, fn
               {:task_id, {"active lease already exists for task/runtime/phase/stage", _}} -> true
               _ -> false
             end)
    end

    test "two active leases with NULL stage_id both persist (partial index treats NULLs as distinct)" do
      task = create_task!()

      assert {:ok, first} =
               %ExecutionLease{}
               |> ExecutionLease.changeset(base_attrs(task))
               |> Repo.insert()

      assert {:ok, second} =
               %ExecutionLease{}
               |> ExecutionLease.changeset(base_attrs(task))
               |> Repo.insert()

      assert first.id != second.id
      assert first.stage_id == nil
      assert second.stage_id == nil
    end

    test "abandoned leases are outside the partial index and don't block new active leases" do
      task = create_task!()
      stage_id = Ecto.UUID.generate()

      assert {:ok, _abandoned} =
               %ExecutionLease{}
               |> ExecutionLease.changeset(
                 base_attrs(task, stage_id: stage_id, status: "abandoned")
               )
               |> Repo.insert()

      assert {:ok, _active} =
               %ExecutionLease{}
               |> ExecutionLease.changeset(base_attrs(task, stage_id: stage_id))
               |> Repo.insert()
    end
  end
end
