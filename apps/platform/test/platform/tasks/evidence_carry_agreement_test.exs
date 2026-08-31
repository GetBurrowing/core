defmodule Platform.Tasks.EvidenceCarryAgreementTest do
  @moduledoc """
  Task `01a0167c` stage 3 — the two evidence writers must agree.

  `Platform.Tasks.evaluate_validation/3` (tasks.ex, the bare row write) and
  `Platform.Tasks.PlanEngine.evaluate_validation/2` (plan_engine.ex, the
  lifecycle writer) must persist the SAME `evidence` map for the same
  (stored evidence, incoming evidence, kind) triple, because both route the
  incoming map through `Platform.Tasks.EvidenceCarry.carry_prior_rulings/2`.
  Nothing structural stops a future change from re-inlining a divergent copy
  into either writer, so this file exercises BOTH against the database and
  asserts the persisted maps are equal — a behavioural guard, not a source
  scan. Only `evidence` is compared: the engine additionally sets
  `evaluated_by`, runs telemetry, and advances the stage, so whole-struct
  equality would fail for reasons unrelated to the carry.
  """
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Task, Validation}

  @archive [%{"verdict" => "rejected", "note" => "invented sample ruling"}]
  @other_archive [%{"verdict" => "approved", "note" => "caller-supplied ruling"}]

  # Each case seeds two rows of the same kind with the same stored evidence on
  # one started stage of an `in_review` task — the shape
  # `plan_engine_direct_evidence_write_test.exs` uses so the engine's
  # transaction (telemetry, stage advance) succeeds rather than erroring on a
  # `backlog` task or a never-started stage. The bare writer runs first (it
  # never touches the stage); the engine writer then resolves the last pending
  # validation and advances, which is fine — the stage's fate is not compared.
  @cases [
    %{
      name: "manual_approval + stored archive + incoming WITHOUT the key",
      kind: "manual_approval",
      stored: %{"prior_rulings" => @archive},
      incoming: %{"summary" => "second look"},
      expect: %{"summary" => "second look", "prior_rulings" => @archive}
    },
    %{
      name: "manual_approval + stored archive + incoming WITH a differing key",
      kind: "manual_approval",
      stored: %{"prior_rulings" => @archive},
      incoming: %{"summary" => "second look", "prior_rulings" => @other_archive},
      expect: %{"summary" => "second look", "prior_rulings" => @other_archive}
    },
    %{
      name: "manual_approval + stored evidence with NO archive",
      kind: "manual_approval",
      stored: %{"earlier" => "note"},
      incoming: %{"summary" => "second look"},
      expect: %{"summary" => "second look"}
    },
    %{
      name: "test_pass + stored archive",
      kind: "test_pass",
      stored: %{"prior_rulings" => @archive},
      incoming: %{"summary" => "second look"},
      expect: %{"summary" => "second look"}
    }
  ]

  for {c, index} <- Enum.with_index(@cases, 1) do
    @c c
    test "case #{index}: #{c.name} — both writers persist the same evidence" do
      %{kind: kind, stored: stored, incoming: incoming, expect: expect} = @c

      stage = seed_stage()
      {:ok, bare} = seed_validation(stage, kind, stored)
      {:ok, engine} = seed_validation(stage, kind, stored)

      # Precondition on the seeded rows, so a carry that "agrees" cannot be
      # agreeing on an empty archive that never made it into the database.
      assert Repo.get!(Validation, bare.id).evidence == stored
      assert Repo.get!(Validation, engine.id).evidence == stored

      assert {:ok, _} = Tasks.evaluate_validation(bare.id, "passed", incoming)

      assert {:ok, _} =
               PlanEngine.evaluate_validation(engine.id, %{
                 status: "passed",
                 evidence: incoming,
                 evaluated_by: "some_agent"
               })

      bare_evidence = Repo.get!(Validation, bare.id).evidence
      engine_evidence = Repo.get!(Validation, engine.id).evidence

      # Evidence only — see @moduledoc for why not the whole struct.
      assert bare_evidence == engine_evidence,
             "the two writers diverged for #{kind}: " <>
               "Tasks.evaluate_validation/3 wrote #{inspect(bare_evidence)}, " <>
               "PlanEngine.evaluate_validation/2 wrote #{inspect(engine_evidence)}"

      # Agreement alone would also pass if both writers dropped the carry, so
      # pin what the agreed map must be.
      assert bare_evidence == expect
      assert engine_evidence == expect
    end
  end

  test "case 3 (no archive): neither writer invents a prior_rulings key" do
    stage = seed_stage()
    {:ok, bare} = seed_validation(stage, "manual_approval", %{"earlier" => "note"})
    {:ok, engine} = seed_validation(stage, "manual_approval", %{"earlier" => "note"})

    assert {:ok, _} = Tasks.evaluate_validation(bare.id, "passed", %{"summary" => "x"})

    assert {:ok, _} =
             PlanEngine.evaluate_validation(engine.id, %{
               status: "passed",
               evidence: %{"summary" => "x"},
               evaluated_by: "some_agent"
             })

    # One refute per writer — a single refute over the merged pair would be
    # vacuous for whichever writer it did not read.
    refute Map.has_key?(Repo.get!(Validation, bare.id).evidence, "prior_rulings")
    refute Map.has_key?(Repo.get!(Validation, engine.id).evidence, "prior_rulings")
  end

  test "case 4 (test_pass): neither writer carries the stored archive" do
    stage = seed_stage()
    {:ok, bare} = seed_validation(stage, "test_pass", %{"prior_rulings" => @archive})
    {:ok, engine} = seed_validation(stage, "test_pass", %{"prior_rulings" => @archive})

    assert {:ok, _} = Tasks.evaluate_validation(bare.id, "passed", %{"summary" => "x"})

    assert {:ok, _} =
             PlanEngine.evaluate_validation(engine.id, %{
               status: "passed",
               evidence: %{"summary" => "x"},
               evaluated_by: "some_agent"
             })

    refute Map.has_key?(Repo.get!(Validation, bare.id).evidence, "prior_rulings")
    refute Map.has_key?(Repo.get!(Validation, engine.id).evidence, "prior_rulings")
  end

  defp seed_stage do
    {:ok, project} = Tasks.create_project(%{name: "Agreement Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Agreement Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Gate"})
    {:ok, _} = PlanEngine.start_stage(stage.id)
    _task = task |> Task.changeset(%{status: "in_review"}) |> Repo.update!()
    stage
  end

  defp seed_validation(stage, kind, stored) do
    Tasks.create_validation(%{stage_id: stage.id, kind: kind, evidence: stored})
  end
end
