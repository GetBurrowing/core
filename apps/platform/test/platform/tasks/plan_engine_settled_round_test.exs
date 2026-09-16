defmodule Platform.Tasks.PlanEngineSettledRoundTest do
  @moduledoc """
  Task `01a08e86` stage 3 — a behavioural gate is judged once per SETTLED
  round, not on every verdict write.

  ## The measured incident, and the bound on it

  On 2026-09-11 gate stage `01a08fa3-b3ef-7006-876b-08a7a0ef1a85` bounced its
  task to `in_progress` at **09:38:09.960Z** while its reviewer was still
  running: the gate held one `failed` row (`…700a`) and one
  never-dispositioned sibling (`…700b`). A remediation stage was synthesized
  quoting a partial finding set. That bounce is what these tests pin.

  A SECOND bounce at **09:50:17.903Z** is deliberately NOT claimed here. That
  write was `passed`, so it cannot reach the fast-fail branch;
  `reset_gate_stage/1` had already driven the gate to `pending`, and
  `maybe_advance_resolved_stage/1` takes `_other -> :ok` there. No write path
  was identified that produces that transition, so this change neither covers
  it nor should be read as regressing if it recurs.

  ## Why the bounce notices are not evidence either way

  Both bounce notices rendered `pending_validations=e2e_behavior:pending`,
  which reads as proof that no sibling was `failed`. It is not.
  `validation_diagnostic/1` does print `failed`, but
  `bounce_to_in_progress/4` → `maybe_open_remediation_stage/2` re-pends the
  failed rows BEFORE the `post_log` — so the notice renders identically
  whichever way the question goes. It discriminates nothing. The statuses
  above come from a contemporaneous `validation_list` read, not from it.

  ## Paired-assertion discipline

  Every hold here is asserted against a case that must STILL fire. A guard
  that cannot go red is the defect class this task exists to close, so
  "the gate holds" is never asserted without "and the gate still fails once
  the round settles" beside it.
  """
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, ReviewDisposition, Stage, Validation}

  @payload %{
    "setup" => "A seeded task whose gate carries several behavioural cases",
    "actions" => "Disposition the cases one at a time",
    "expected" => "The gate is judged once, on the settled round"
  }

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Settled Round Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Settled Round Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    {:ok, impl} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Land the change"})
    {:ok, gate} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Task-level review"})

    %{plan: plan, task: task, impl: impl, gate: gate}
  end

  # A gate carrying `count` e2e_behavior rows, driven to `running` the way the
  # router drives it.
  defp running_gate!(gate, count) do
    rows =
      for _ <- 1..count do
        {:ok, v} =
          Tasks.create_validation(%{
            stage_id: gate.id,
            kind: "e2e_behavior",
            evaluation_payload: @payload
          })

        v
      end

    gate = gate |> Stage.changeset(%{status: "running"}) |> Repo.update!()
    {gate, rows}
  end

  defp genuine_failure, do: %{"observed" => "the roster rendered an unsubstituted mustache"}

  defp unevaluated_failure do
    %{
      "disposition" => ReviewDisposition.marker(),
      ReviewDisposition.reason_key() => "the dev server would not boot"
    }
  end

  defp fail!(validation, evidence),
    do: PlanEngine.evaluate_validation(validation.id, %{status: "failed", evidence: evidence})

  defp pass!(validation),
    do: PlanEngine.evaluate_validation(validation.id, %{status: "passed", evidence: %{}})

  defp status(%Stage{id: id}), do: Repo.get!(Stage, id).status

  describe "the settled-round hold" do
    test "a genuine failure does not fail the gate while a sibling is still owed", ctx do
      {gate, [first, second]} = running_gate!(ctx.gate, 2)

      {:ok, _} = fail!(first, genuine_failure())

      # The incident, pinned: mid-run, the gate must not bounce.
      assert status(gate) == "running"

      # PAIRED ASSERTION — the failure is DELAYED, never swallowed. The same
      # fixture must fail the instant the round settles, or the hold above is
      # indistinguishable from the engine having stopped judging gates.
      {:ok, _} = pass!(second)

      assert status(gate) == "failed"
    end

    test "the ordinary path still re-evaluates: a settled round is judged on the last write",
         ctx do
      {gate, [only]} = running_gate!(ctx.gate, 1)

      # Nothing is owed, so there is nothing to wait for and the verdict lands
      # on this write. This is the positive control for the test above: it is
      # what proves the hold is keyed on owed siblings and not on a gate the
      # engine has simply stopped failing.
      {:ok, _} = fail!(only, genuine_failure())

      assert status(gate) == "failed"
    end

    test "a settled round of passes still passes the gate", ctx do
      {gate, [first, second]} = running_gate!(ctx.gate, 2)

      {:ok, _} = pass!(first)
      assert status(gate) == "running"

      {:ok, _} = pass!(second)
      assert status(gate) == "passed"
    end

    test "five cases: two written in immediate succession, the second passing, never bounce the gate",
         ctx do
      {gate, [c1, c2, c3, c4, c5]} = running_gate!(ctx.gate, 5)

      for row <- [c1, c2, c3], do: {:ok, _} = pass!(row)
      assert status(gate) == "running"

      # The coordinator's two-write ruling, entered one tool call at a time.
      {:ok, _} = pass!(c4)
      assert status(gate) == "running"

      {:ok, _} = pass!(c5)
      assert status(gate) == "passed"

      # The gate never entered `failed`, so no remediation stage is even
      # openable off it — the incident's synthesized stage cannot recur here.
      assert {:error, :no_failed_gate_validations} = PlanEngine.open_remediation_stage(gate.id)
    end

    test "case 1 of 5 failing mid-run holds, and the gate still fails once case 5 lands", ctx do
      {gate, [c1, c2, c3, c4, c5]} = running_gate!(ctx.gate, 5)

      {:ok, _} = fail!(c1, genuine_failure())
      assert status(gate) == "running"

      for row <- [c2, c3, c4] do
        {:ok, _} = pass!(row)
        assert status(gate) == "running"
      end

      {:ok, _} = pass!(c5)
      assert status(gate) == "failed"

      # And the real failure is still actionable: the remediation stage opens
      # on a COMPLETE finding set rather than a partial one.
      assert {:ok, _stage} = PlanEngine.open_remediation_stage(gate.id)
    end
  end

  describe "scope — what the hold must not touch" do
    test "a non-e2e stage still fails on the first failed write, sibling pending", ctx do
      {:ok, test_pass} = Tasks.create_validation(%{stage_id: ctx.impl.id, kind: "test_pass"})
      {:ok, _lint} = Tasks.create_validation(%{stage_id: ctx.impl.id, kind: "lint_pass"})

      impl = ctx.impl |> Stage.changeset(%{status: "running"}) |> Repo.update!()

      {:ok, _} = fail!(test_pass, %{"result" => "3 failures"})

      # Unchanged from before this task: implementation stages are not slowed
      # down by a hold written for behavioural gates.
      assert status(impl) == "failed"
    end

    test "a could_not_evaluate gate whose every case is unevaluated still fails", ctx do
      {gate, [first, second]} = running_gate!(ctx.gate, 2)

      {:ok, _} = fail!(first, unevaluated_failure())
      assert status(gate) == "running"

      {:ok, _} = fail!(second, unevaluated_failure())

      # Nothing passed, so this is still the router's "fix the environment"
      # bounce and the 3-strikes bookkeeping is untouched.
      assert status(gate) == "failed"
    end

    test "a settled round with a passed case and an unevaluated one still passes with skips",
         ctx do
      {gate, [first, second]} = running_gate!(ctx.gate, 2)

      {:ok, _} = fail!(first, unevaluated_failure())
      assert status(gate) == "running"

      {:ok, _} = pass!(second)

      assert status(gate) == "passed"
      assert Repo.get!(Validation, first.id).status == "skipped"
    end
  end
end
