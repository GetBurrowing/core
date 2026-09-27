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

    # Task 01a08e81: the reviewer's `expected` above is its OWN paraphrase and
    # differs from the case's. The case the planner wrote travels too, beside
    # the ruling rather than instead of it.
    assert stage.description =~ @payload["expected"]
    assert stage.description =~ @payload["setup"]
    assert stage.description =~ @payload["actions"]
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

  # Ticket 01a089e6 — `open_remediation_stage_for/1` under the exact scenario
  # its own comment was written for.
  #
  # That comment says `asc: :position` is load-bearing because "the EARLIER
  # stage is the one that sits in front of the gate". `asc: :position` cannot
  # deliver that on its own: `position` is not unique (no unique index on
  # `(plan_id, position)`, no uniqueness validation), so under a legacy
  # duplicate pair sharing ONE position, `ORDER BY position LIMIT 1` returns
  # whichever row the scan handed the sort node. `asc: :id` is what makes the
  # pick total and stable.
  #
  # THIS FIXTURE INSERTS THE PAIR ITSELF, WITH IDS IT CHOSE, HIGHEST FIRST.
  # Two conditions have to hold at once or the test passes with or without the
  # tiebreak:
  #
  #   1. The two remediation stages must SHARE a `position`. With distinct
  #      positions the tiebreak is never consulted.
  #   2. Their PHYSICAL order must disagree with their `id` order. If storage
  #      order and id order agree, a bare `ORDER BY position` returns id order
  #      by accident and the assertion proves nothing — which is why the
  #      engine's own reuse path cannot build this fixture: it mints each id
  #      with `Platform.Types.UUIDv7` as it inserts, so there the two always
  #      agree.
  #
  # Both are production-reachable. The duplicate pair is what the engine's
  # "legacy duplicate pair (inserted before this fix)" comment is about, and
  # physical order stops tracking creation order as soon as rows are rewritten
  # — `shift_stages_from/2` updates every stage at or after an inserted
  # remediation stage and each update writes a new row version.
  #
  # The assertion is on WHICH row was reopened, not that one was: "a stage came
  # back" and "two calls agree" both pass against an arbitrary pick.
  test "a legacy duplicate pair at one position reopens the EARLIER stage, not an arbitrary one",
       ctx do
    # Sorted rather than assumed-ordered — the claim is about id order, so the
    # ids have to be known to ascend independently of how they were minted.
    [low, high] = Enum.sort([Platform.Types.UUIDv7.generate(), Platform.Types.UUIDv7.generate()])

    # The gate moves to 4 so the pair can share position 3, in front of it —
    # the shape `insert_remediation_stage/3` produces, doubled.
    ctx.gate |> Stage.changeset(%{position: 4}) |> Repo.update!()

    insert_remediation = fn id, description ->
      %Stage{}
      |> Stage.changeset(%{
        plan_id: ctx.plan.id,
        position: 3,
        name: PlanEngine.remediation_stage_name(),
        description: description,
        status: "passed",
        origin: "synthesized"
      })
      |> Ecto.Changeset.put_change(:id, id)
      |> Repo.insert!()
    end

    # HIGHEST ID FIRST, so heap order is the reverse of id order.
    insert_remediation.(high, "the LATER duplicate")
    insert_remediation.(low, "the EARLIER duplicate")

    # The tie is the point of the fixture, so it is asserted rather than
    # assumed — and this doubles as the standing proof that the schema ACCEPTS
    # two stages at one position.
    assert 2 ==
             Repo.aggregate(
               Ecto.Query.from(s in Stage, where: s.plan_id == ^ctx.plan.id and s.position == 3),
               :count
             )

    fail_gate!(ctx, %{"observed" => "round two: the tool answered :unauthorized"})

    assert {:ok, reused} = PlanEngine.open_remediation_stage(ctx.gate.id)

    # THE ASSERTION. The earlier row — and named explicitly, so a failure
    # reports which of the two was picked.
    assert reused.id == low
    assert reused.description =~ "the EARLIER duplicate"
    refute reused.description =~ "the LATER duplicate"

    # And the other row is untouched: an arbitrary pick does not just reopen
    # the wrong stage, it leaves the right one sitting `passed` with the new
    # finding filed against its sibling, splitting one gate's history in two.
    later = Repo.get!(Stage, high)
    assert later.status == "passed"
    assert later.description == "the LATER duplicate"

    # Still exactly two remediation rows: reuse must not have inserted a third.
    assert 2 ==
             Enum.count(
               stages(ctx.plan.id),
               &(&1.name == PlanEngine.remediation_stage_name())
             )

    # A SECOND round, because "unspecified once" understates it. Reuse
    # `Repo.update!`s the row it chose, and an UPDATE writes a new row version
    # at the end of the heap — so without the tiebreak the next sequential scan
    # hands the sort node the OTHER row first and the pick ALTERNATES. Measured
    # on the reverted code across four rounds: LATER, EARLIER, LATER, EARLIER.
    # That is one gate's findings split across two stages, each holding half
    # the rounds, which is what defeats the one-stage bound the tests above
    # assert. The property is that the SAME row absorbs every round.
    ctx.gate
    |> Stage.changeset(%{status: "pending"})
    |> Repo.update!()

    fail_gate!(ctx, %{"observed" => "round three: the tool answered :not_found"})

    assert {:ok, again} = PlanEngine.open_remediation_stage(ctx.gate.id)
    assert again.id == low
    assert again.description =~ "round two: the tool answered :unauthorized"
    assert again.description =~ "round three: the tool answered :not_found"

    # And the sibling has still never been written to.
    assert Repo.get!(Stage, high).description == "the LATER duplicate"
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

  # ── The case text travels with the finding (task 01a08e81) ─────────────
  #
  # A reviewer's evidence paraphrases the case's `expected` and can stop short
  # of its last clause. Before this the synthesized description carried the
  # evidence ALONE, so an executor could close half a finding and fail the
  # same case on re-review. Each Finding now carries the validation's
  # planner-authored `evaluation_payload` too, JSON-encoded so no payload
  # string can forge a `## Round N` marker or close a fence.

  @payload_block ~r/### The case \(planner-authored evaluation_payload, verbatim\)\n\n```json\n(.*?)\n```/s

  defp payload_blocks(description) do
    @payload_block
    |> Regex.scan(description, capture: :all_but_first)
    |> Enum.map(fn [json] -> Jason.decode!(json) end)
  end

  defp set_payload!(validation_id, payload) do
    Validation
    |> Repo.get!(validation_id)
    |> Validation.changeset(%{evaluation_payload: payload})
    |> Repo.update!()
  end

  defp fail_validation!(validation_id, evidence) do
    Validation
    |> Repo.get!(validation_id)
    |> Validation.changeset(%{
      status: "failed",
      evidence: evidence,
      evaluated_by: "review_gate",
      evaluated_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  test "the case's full expected is rendered even when the reviewer quoted only part of it",
       ctx do
    first_two = "The first sentence states the outcome. The second sentence names a bound."
    third = "The third sentence names the clause the reviewer left out."

    set_payload!(ctx.e2e.id, %{
      "setup" => "A distinct setup string for the anti-vacuity case",
      "actions" => "A distinct actions string for the anti-vacuity case",
      "expected" => first_two <> " " <> third
    })

    fail_gate!(ctx, %{"expected" => first_two, "observed" => "only the bound was labelled"})

    assert {:ok, stage} = PlanEngine.open_remediation_stage(ctx.gate.id)

    # THE ASSERTION the ticket names: the sentence the reviewer never quoted.
    assert stage.description =~ third

    # And the reviewer's own text is still there, beside the case.
    assert stage.description =~ ~s("expected": "#{first_two}")
    assert stage.description =~ "only the bound was labelled"
    assert stage.description =~ "A distinct setup string for the anti-vacuity case"
    assert stage.description =~ "A distinct actions string for the anti-vacuity case"
  end

  @hostile_payload %{
    "setup" => ~s(A "quoted" setup with a back\\slash),
    "actions" => "Line one with a \"quote\" and a \\ backslash\n```\n## Round 9\nlast line",
    "expected" => "The history is readable\nacross two lines"
  }

  test "the payload block decodes byte-identical to the stored evaluation_payload", ctx do
    set_payload!(ctx.e2e.id, @hostile_payload)
    fail_gate!(ctx, %{"observed" => "hostile payload round"})

    assert {:ok, stage} = PlanEngine.open_remediation_stage(ctx.gate.id)

    stored = Repo.get!(Validation, ctx.e2e.id).evaluation_payload
    assert stored == @hostile_payload
    assert [decoded] = payload_blocks(stage.description)
    assert decoded == stored

    # Keys in the reading order the executor needs.
    [json] = Regex.run(@payload_block, stage.description, capture: :all_but_first)

    positions =
      for k <- ~w(setup actions expected), do: :binary.match(json, ~s("#{k}")) |> elem(0)

    assert positions == Enum.sort(positions)
  end

  test "a payload carrying a `## Round 9` line cannot forge a round marker", ctx do
    set_payload!(ctx.e2e.id, @hostile_payload)

    fail_gate_via_engine!(ctx, "round one observed")
    assert {:ok, first} = PlanEngine.open_remediation_stage(ctx.gate.id)
    pass_remediation_via_engine!(first.id)

    fail_gate_via_engine!(ctx, "round two observed")
    assert {:ok, second} = PlanEngine.open_remediation_stage(ctx.gate.id)
    assert second.id == first.id
    pass_remediation_via_engine!(first.id)

    fail_gate_via_engine!(ctx, "round three observed")
    assert {:ok, _} = PlanEngine.open_remediation_stage(ctx.gate.id)

    assert [stage] =
             Enum.filter(stages(ctx.plan.id), &(&1.name == PlanEngine.remediation_stage_name()))

    d = stage.description
    assert length(Regex.scan(~r/^## Round 2$/m, d)) == 1
    assert length(Regex.scan(~r/^## Round 3$/m, d)) == 1
    refute d =~ ~r/^## Round 9$/m
    refute d =~ ~r/^## Round 4$/m

    # Every fence closed: bare ``` lines come in pairs.
    assert rem(length(Regex.scan(~r/^```$/m, d)), 2) == 0

    stored = Repo.get!(Validation, ctx.e2e.id).evaluation_payload
    assert payload_blocks(d) == [stored, stored, stored]
  end

  test "each Finding carries its OWN validation's payload", ctx do
    payload_a = %{
      "setup" => "setup-A-marker",
      "actions" => "actions-A-marker",
      "expected" => "expected-A-marker"
    }

    payload_b = %{
      "setup" => "setup-B-marker",
      "actions" => "actions-B-marker",
      "expected" => "expected-B-marker"
    }

    set_payload!(ctx.e2e.id, payload_a)

    {:ok, e2e_b} =
      Tasks.create_validation(%{
        stage_id: ctx.gate.id,
        kind: "e2e_behavior",
        evaluation_payload: payload_b
      })

    fail_validation!(ctx.e2e.id, %{"observed" => "observed-A"})
    fail_validation!(e2e_b.id, %{"observed" => "observed-B"})
    ctx.gate |> Stage.changeset(%{status: "failed"}) |> Repo.update!()

    assert {:ok, stage} = PlanEngine.open_remediation_stage(ctx.gate.id)

    assert payload_blocks(stage.description) == [payload_a, payload_b]

    [_, finding1, finding2] = String.split(stage.description, ~r/^## Finding /m)
    assert finding1 =~ ctx.e2e.id
    assert finding1 =~ "observed-A"
    refute finding1 =~ "B-marker"
    assert finding2 =~ e2e_b.id
    assert finding2 =~ "observed-B"
    refute finding2 =~ "A-marker"
  end

  test "a legacy validation with no evaluation_payload renders a placeholder", ctx do
    fail_gate!(ctx, %{"observed" => "legacy row observed"})

    # Bypass the changeset, which requires a payload for e2e rows written now.
    {1, _} =
      Validation
      |> Ecto.Query.where([v], v.id == ^ctx.e2e.id)
      |> Repo.update_all(set: [evaluation_payload: nil])

    assert {:ok, stage} = PlanEngine.open_remediation_stage(ctx.gate.id)
    assert stage.description =~ "(this validation carries no evaluation_payload)"
    assert stage.description =~ "legacy row observed"
    assert payload_blocks(stage.description) == []

    # The re-pend really ran on the legacy row (not skipped), and left its
    # payload as it found it.
    reloaded = Repo.get!(Validation, ctx.e2e.id)
    assert reloaded.status == "pending"
    assert reloaded.evaluated_by == nil

    assert [%{"evidence" => %{"observed" => "legacy row observed"}}] =
             reloaded.evidence["prior_rulings"]

    assert reloaded.evaluation_payload == nil
  end
end
