defmodule Platform.Tasks.PlanEngineRemediationTest do
  @moduledoc """
  Task `01a006e7` stage 3 — a failed behavioural gate must leave the plan with
  an open stage to dispatch.

  `PlanEngine.open_remediation_stage/2` synthesizes that stage in front of the
  gate. These tests cover the four properties the synthesized stage has to
  have: it lands before the gate with contiguous positions, it carries the
  gate agent's finding, its name does not make the engine adopt it as the e2e
  host, and the ruling it clears from the gate survives as history.
  """
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Stage, Validation}

  @payload %{
    "setup" => "A task with a merged PR",
    "actions" => "Read the task's transition history with no DB access",
    "expected" => "The history is readable through the MCP surface"
  }

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Remediation Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Remediation Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    {:ok, impl1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Land the tool"})
    {:ok, impl2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Wire the router"})
    {:ok, gate} = Tasks.create_stage(%{plan_id: plan.id, position: 3, name: "Task-level review"})

    {:ok, e2e} =
      Tasks.create_validation(%{
        stage_id: gate.id,
        kind: "e2e_behavior",
        evaluation_payload: @payload
      })

    %{plan: plan, task: task, impl1: impl1, impl2: impl2, gate: gate, e2e: e2e}
  end

  defp fail_gate!(ctx, evidence) do
    current = Repo.get!(Validation, ctx.e2e.id)

    # A re-ruling carries the accumulated history forward — the same shape
    # `ReviewDisposition` writes back onto a gate that has been reopened before.
    evidence =
      case current.evidence do
        %{"prior_rulings" => prior} -> Map.put(evidence, "prior_rulings", prior)
        _ -> evidence
      end

    current
    |> Validation.changeset(%{
      status: "failed",
      evidence: evidence,
      evaluated_by: "review_gate",
      evaluated_at: DateTime.utc_now()
    })
    |> Repo.update!()

    ctx.gate |> Stage.changeset(%{status: "failed"}) |> Repo.update!()
  end

  defp stages(plan_id) do
    Stage
    |> Ecto.Query.where([s], s.plan_id == ^plan_id)
    |> Ecto.Query.order_by([s], asc: s.position)
    |> Repo.all()
  end

  test "the remediation stage lands in front of the gate with contiguous positions", ctx do
    fail_gate!(ctx, %{"observed" => "The MCP surface returned :not_found"})

    assert {:ok, stage} = PlanEngine.open_remediation_stage(ctx.gate.id)

    ordered = stages(ctx.plan.id)

    assert Enum.map(ordered, & &1.position) == [1, 2, 3, 4]

    assert Enum.map(ordered, & &1.name) == [
             "Land the tool",
             "Wire the router",
             PlanEngine.remediation_stage_name(),
             "Task-level review"
           ]

    # The gate still sits LAST: a remediation stage placed after it would
    # never let the failure be re-judged — the plan would complete instead.
    assert List.last(ordered).id == ctx.gate.id
    assert Enum.at(ordered, 2).id == stage.id

    # The synthesized stage is a real unit of work the router can dispatch.
    assert stage.status == "pending"

    kinds =
      Validation
      |> Ecto.Query.where([v], v.stage_id == ^stage.id)
      |> Repo.all()
      |> Enum.map(& &1.kind)
      |> Enum.sort()

    assert kinds == ["lint_pass", "test_pass"]

    # And the gate is closed again, so the router cannot dispatch both at once.
    assert Repo.get!(Stage, ctx.gate.id).status == "pending"
  end

  test "the gate agent's ruling is archived and reads back verbatim", ctx do
    fail_gate!(ctx, %{
      "expected" => "history readable without DB access",
      "observed" => "tool answered :unauthorized for an agent with no DB grant"
    })

    assert {:ok, stage} = PlanEngine.open_remediation_stage(ctx.gate.id)

    reloaded = Repo.get!(Validation, ctx.e2e.id)

    # The gate reads as un-evaluated again...
    assert reloaded.status == "pending"
    assert reloaded.evaluated_by == nil
    assert reloaded.evaluated_at == nil

    # ...but the observation SURVIVES. Asserting on the key alone would pass
    # against an empty list, which is the erasure this test exists to catch.
    assert [entry] = reloaded.evidence["prior_rulings"]
    assert entry["status"] == "failed"
    assert entry["evaluated_by"] == "review_gate"

    assert entry["evidence"]["observed"] ==
             "tool answered :unauthorized for an agent with no DB grant"

    assert entry["evidence"]["expected"] == "history readable without DB access"

    # And the executor dispatched to the new stage receives the finding itself,
    # not a summary of it.
    assert stage.description =~ "tool answered :unauthorized for an agent with no DB grant"
    assert stage.description =~ "history readable without DB access"
    assert stage.description =~ "Task-level review"
  end

  test "supplied feedback is carried alongside the evidence", ctx do
    fail_gate!(ctx, %{"observed" => "nothing happened"})

    assert {:ok, stage} =
             PlanEngine.open_remediation_stage(
               ctx.gate.id,
               "Reviewer: the grant check is inverted"
             )

    assert stage.description =~ "Reviewer: the grant check is inverted"
    assert stage.description =~ "nothing happened"
  end

  test "the synthesized name does not make the engine adopt it as the e2e host" do
    # Asserted against the ENGINE'S OWN matcher, not a copied substring list,
    # so the name and the predicate cannot drift apart.
    refute PlanEngine.e2e_host_stage_name?(PlanEngine.remediation_stage_name())

    # The predicate is really the one that fires — shown by a name that does match.
    assert PlanEngine.e2e_host_stage_name?("Task-level review")
    assert PlanEngine.e2e_host_stage_name?("Final validation")
  end

  test "a gate with no failed e2e validation is refused", ctx do
    assert {:error, :no_failed_gate_validations} =
             PlanEngine.open_remediation_stage(ctx.gate.id)

    assert Enum.map(stages(ctx.plan.id), & &1.position) == [1, 2, 3]
  end

  test "an unknown stage id is refused" do
    assert {:error, :stage_not_found} =
             PlanEngine.open_remediation_stage(Ecto.UUID.generate())

    assert {:error, :stage_not_found} = PlanEngine.open_remediation_stage("not-a-uuid")
  end

  test "repeated reopens accumulate history rather than overwriting it", ctx do
    fail_gate!(ctx, %{"observed" => "first round"})
    assert {:ok, _} = PlanEngine.open_remediation_stage(ctx.gate.id)

    fail_gate!(ctx, %{"observed" => "second round"})
    assert {:ok, _} = PlanEngine.open_remediation_stage(ctx.gate.id)

    reloaded = Repo.get!(Validation, ctx.e2e.id)

    assert Enum.map(reloaded.evidence["prior_rulings"], & &1["evidence"]["observed"]) ==
             ["first round", "second round"]
  end

  test "two consecutive gate failures leave exactly ONE remediation stage", ctx do
    fail_gate!(ctx, %{"observed" => "round one: the tool answered :not_found"})
    assert {:ok, first} = PlanEngine.open_remediation_stage(ctx.gate.id)

    fail_gate!(ctx, %{"observed" => "round two: the tool answered :unauthorized"})
    assert {:ok, second} = PlanEngine.open_remediation_stage(ctx.gate.id)

    remediation =
      Enum.filter(stages(ctx.plan.id), &(&1.name == PlanEngine.remediation_stage_name()))

    # The invariant first, so that removing the reuse lookup reports the
    # COUNT (2) rather than tripping an id comparison on the way past it.
    assert length(remediation) == 1

    # The SAME row, not a near-identical sibling.
    assert second.id == first.id

    # Positions stay contiguous — a second shift would have opened a gap.
    assert Enum.map(stages(ctx.plan.id), & &1.position) == [1, 2, 3, 4]
    assert List.last(stages(ctx.plan.id)).id == ctx.gate.id

    # BOTH findings are carried. Reuse that silently discarded the second
    # would dispatch the executor against feedback the gate has moved past.
    assert second.description =~ "round one: the tool answered :not_found"
    assert second.description =~ "round two: the tool answered :unauthorized"
    assert second.description =~ "## Round 2"

    # And it is open again, with its own validations re-earned rather than
    # left `passed` from the previous round.
    assert second.status == "pending"

    statuses =
      Validation
      |> Ecto.Query.where([v], v.stage_id == ^second.id)
      |> Repo.all()
      |> Enum.map(& &1.status)
      |> Enum.uniq()

    assert statuses == ["pending"]
  end

  test "a third failure still reuses the one stage and marks the round", ctx do
    for round <- ~w(alpha beta gamma) do
      fail_gate!(ctx, %{"observed" => "finding #{round}"})
      assert {:ok, _} = PlanEngine.open_remediation_stage(ctx.gate.id)
    end

    assert [stage] =
             Enum.filter(stages(ctx.plan.id), &(&1.name == PlanEngine.remediation_stage_name()))

    for round <- ~w(alpha beta gamma), do: assert(stage.description =~ "finding #{round}")
    assert stage.description =~ "## Round 2"
    assert stage.description =~ "## Round 3"

    # The stage bound holds at the round bound the engine already enforces —
    # this is not a second constant, it is the same one read back.
    assert Tasks.max_review_rounds() == 3
  end

  # ── The full round trip ────────────────────────────────────────────────
  #
  # Task 01a006e7 remediation. The reuse bound shipped with a passing test that
  # constructed a `failed` remediation stage by hand — a state the LIFECYCLE
  # NEVER PRODUCES. To get from a remediation stage back to the gate, the
  # remediation stage must be driven to `passed`; so at the moment of the
  # second gate failure the existing remediation stage is always `passed`, the
  # one status the old predicate excluded. The bound was dead code and the test
  # proved nothing.
  #
  # This test therefore hand-sets NO intermediate status. It drives the engine
  # the way the router and the executor do — `start_stage/1` then
  # `evaluate_validation/2` — and asserts the invariant on the far side.

  # Drive the gate to `failed` through the engine rather than writing the
  # status: `evaluate_validation/2`'s `running + failed -> advance_stage`
  # branch is what the reviewer's run exercised.
  defp fail_gate_via_engine!(ctx, observed) do
    gate = Repo.get!(Stage, ctx.gate.id)
    if gate.status == "pending", do: {:ok, _} = PlanEngine.start_stage(gate.id)

    {:ok, _} =
      PlanEngine.evaluate_validation(ctx.e2e.id, %{
        status: "failed",
        evaluated_by: "review_gate",
        evidence: %{"observed" => observed}
      })

    assert Repo.get!(Stage, ctx.gate.id).status == "failed"
    :ok
  end

  # Drive the remediation stage to `passed` the way its executor does: start it,
  # then pass every validation it carries.
  defp pass_remediation_via_engine!(stage_id) do
    {:ok, _} = PlanEngine.start_stage(stage_id)

    Validation
    |> Ecto.Query.where([v], v.stage_id == ^stage_id)
    |> Repo.all()
    |> Enum.each(fn v ->
      {:ok, _} =
        PlanEngine.evaluate_validation(v.id, %{
          status: "passed",
          evaluated_by: "executor",
          evidence: %{"result" => "ok"}
        })
    end)

    assert Repo.get!(Stage, stage_id).status == "passed"
    :ok
  end

  test "a SECOND gate failure after the remediation stage passed reuses the one stage", ctx do
    # Round 1 — the gate fails, a remediation stage opens.
    fail_gate_via_engine!(ctx, "round one: the tool answered :not_found")
    assert {:ok, first} = PlanEngine.open_remediation_stage(ctx.gate.id)
    assert first.status == "pending"

    # The executor does the work. This is the step that makes the old
    # predicate unreachable: the only route back to the gate runs through
    # `passed`.
    pass_remediation_via_engine!(first.id)
    assert Repo.get!(Stage, first.id).status == "passed"

    # Round 2 — the gate re-runs and fails AGAIN.
    fail_gate_via_engine!(ctx, "round two: the tool answered :unauthorized")
    assert {:ok, second} = PlanEngine.open_remediation_stage(ctx.gate.id)

    remediation =
      Enum.filter(stages(ctx.plan.id), &(&1.name == PlanEngine.remediation_stage_name()))

    # THE INVARIANT. The reviewer observed two remediation stages here
    # (`[1..3 impl, 4 remediation PASSED, 5 remediation RUNNING, 6 gate]`).
    assert length(remediation) == 1
    assert second.id == first.id

    # Reopened, not left as history.
    assert second.status == "pending"
    assert is_nil(second.started_at)
    assert is_nil(second.completed_at)

    # BOTH findings survive, under a round marker.
    assert second.description =~ "round one: the tool answered :not_found"
    assert second.description =~ "round two: the tool answered :unauthorized"
    assert second.description =~ "## Round 2"

    # Its own validations are re-earned rather than left `passed` from round 1
    # — otherwise the stage advances the instant the router opens it.
    statuses =
      Validation
      |> Ecto.Query.where([v], v.stage_id == ^second.id)
      |> Repo.all()
      |> Enum.map(& &1.status)
      |> Enum.uniq()

    assert statuses == ["pending"]

    # Positions stay contiguous with the gate still last: a second insert
    # would have shifted the gate to position 5.
    ordered = stages(ctx.plan.id)
    assert Enum.map(ordered, & &1.position) == [1, 2, 3, 4]
    assert List.last(ordered).id == ctx.gate.id

    # And the gate is closed again, so the reopened remediation stage is the
    # lowest-position pending stage — the one the router will dispatch.
    assert Repo.get!(Stage, ctx.gate.id).status == "pending"
  end

  test "re-dispositioning a failed validation to passed still self-heals the stage", ctx do
    # `maybe_advance_resolved_stage/1` is the path that let a bounced task heal
    # itself when a validation was flipped to `passed`. This stage must not
    # change it; the assertion below is what says so.
    {:ok, running} = PlanEngine.start_stage(ctx.impl1.id)
    {:ok, v} = Tasks.create_validation(%{stage_id: running.id, kind: "test_pass"})

    {:ok, _} = PlanEngine.evaluate_validation(v.id, %{status: "failed", evidence: %{}})
    assert Repo.get!(Stage, ctx.impl1.id).status == "failed"

    {:ok, _} = PlanEngine.evaluate_validation(v.id, %{status: "passed", evidence: %{}})

    assert Repo.get!(Stage, ctx.impl1.id).status == "passed"
    assert Repo.get!(Stage, ctx.impl2.id).status == "running"
  end
end
