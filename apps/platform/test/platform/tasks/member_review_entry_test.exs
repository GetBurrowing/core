defmodule Platform.Tasks.MemberReviewEntryTest do
  use Platform.DataCase, async: true

  alias Platform.Tasks
  alias Platform.Tasks.MemberReviewEntry
  alias Platform.Tasks.Stacks

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Member Review Entry Project"})
    {:ok, stack} = create_stack(project, "member-review-entry")
    %{project: project, stack: stack}
  end

  defp create_stack(project, slug) do
    slug = "#{slug}-#{System.unique_integer([:positive])}"

    Stacks.create_stack(%{
      project_id: project.id,
      slug: slug,
      name: "Stack #{slug}",
      rollup_branch: Stacks.rollup_branch_name(slug)
    })
  end

  # `Tasks.create_task/1` defaults `status` to `backlog`, which sits OUTSIDE
  # clause (b)'s `in_progress` precondition. Every fixture here sets the status
  # explicitly — a fixture left on the default would satisfy the "does not
  # advance" assertions for the wrong reason.
  defp member(project, stack, status, title, extra \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: title,
            status: status,
            stack_id: stack && stack.id
          },
          extra
        )
      )

    task
  end

  # `transition_task/2` refuses a `deploying` transition without a resolved
  # deploy target (task 019f42db), so the ADR-0046 fixtures carry one.
  defp deployable_member(project, stack, title) do
    member(project, stack, "in_progress", title, %{
      deploy_target: "production",
      deploy_strategy: %{"type" => "manual"}
    })
  end

  defp plan_with_stages(task, stage_specs) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    stages =
      stage_specs
      |> Enum.with_index(1)
      |> Enum.map(fn {{name, status, kinds}, position} ->
        {:ok, stage} =
          Tasks.create_stage(%{plan_id: plan.id, position: position, name: name})

        Enum.each(kinds, fn kind ->
          {:ok, _} = Tasks.create_validation(validation_attrs(stage, kind))
        end)

        {:ok, stage} = force_stage_status(stage, status)
        stage
      end)

    {plan, stages}
  end

  # `e2e_behavior` validations are rejected without an `evaluation_payload`
  # carrying setup/actions/expected.
  defp validation_attrs(stage, "e2e_behavior") do
    %{
      stage_id: stage.id,
      kind: "e2e_behavior",
      evaluation_payload: %{
        "setup" => "a stack member fixture",
        "actions" => "settle the non-gate stages",
        "expected" => "the member reaches in_review"
      }
    }
  end

  defp validation_attrs(stage, kind), do: %{stage_id: stage.id, kind: kind}

  # `pending -> passed` is not a legal single hop (`pending -> running -> passed`).
  # Walk it rather than writing the column directly, so the fixture only ever
  # produces states the engine itself can produce.
  defp force_stage_status(stage, "pending"), do: {:ok, stage}

  defp force_stage_status(stage, "running"), do: Tasks.transition_stage(stage, "running")

  defp force_stage_status(stage, "skipped"), do: Tasks.transition_stage(stage, "skipped")

  defp force_stage_status(stage, status) when status in ~w(passed failed) do
    {:ok, running} = Tasks.transition_stage(stage, "running")
    Tasks.transition_stage(running, status)
  end

  defp reload_stages(plan), do: Tasks.list_stages(plan.id)

  # ── gate_validation?/1 ────────────────────────────────────────────────

  describe "gate_validation?/1" do
    test "is true for exactly the two kinds that automatically produce in_review" do
      assert MemberReviewEntry.gate_validation?(%{kind: "e2e_behavior"})
      assert MemberReviewEntry.gate_validation?(%{kind: "manual_approval"})
    end

    test "is false for command validations and for a kindless map" do
      refute MemberReviewEntry.gate_validation?(%{kind: "test_pass"})
      refute MemberReviewEntry.gate_validation?(%{kind: "lint_pass"})
      refute MemberReviewEntry.gate_validation?(%{})
    end
  end

  # ── gate_stage?/1 ─────────────────────────────────────────────────────

  describe "gate_stage?/1" do
    test "reads validations from the database when the association is not loaded", %{
      project: project,
      stack: stack
    } do
      task = member(project, stack, "in_progress", "Gate stage loading")

      {plan, _} =
        plan_with_stages(task, [
          {"Build", "pending", ["test_pass"]},
          {"Review", "pending", ["e2e_behavior"]}
        ])

      # `Tasks.list_stages/1` does NOT preload validations, so this exercises
      # the `%Ecto.Association.NotLoaded{}` branch, not the preloaded one.
      [build, review] = reload_stages(plan)
      assert %Ecto.Association.NotLoaded{} = build.validations

      refute MemberReviewEntry.gate_stage?(build)
      assert MemberReviewEntry.gate_stage?(review)
    end

    test "uses a preloaded list without querying, and is false for a stage with none" do
      assert MemberReviewEntry.gate_stage?(%{validations: [%{kind: "manual_approval"}]})
      refute MemberReviewEntry.gate_stage?(%{validations: [%{kind: "test_pass"}]})
      refute MemberReviewEntry.gate_stage?(%{validations: []})
      refute MemberReviewEntry.gate_stage?(nil)
    end
  end

  # ── member_work_settled?/2 — the four clauses ─────────────────────────

  describe "member_work_settled?/2" do
    # MUTANT 1 target: deleting clause (c)'s `gate_stage?` filter (so ALL
    # stages must be settled) leaves this test green but kills the hole-B test
    # below. MUTANT 2 target: inverting (c) to require gate stages settled TOO
    # likewise leaves this green. This is the HOLE A case.
    test "hole A: a gate-free member with every stage settled is settled" do
      %{task: task, stages: stages} =
        gate_free_member_fixture()

      # ANTI-VACUITY: if the fixture accidentally carried an e2e or
      # manual_approval validation, "member reaches in_review" would prove
      # nothing about the gate-free path. Assert the fixture discriminates
      # BEFORE asserting the outcome.
      refute Enum.any?(stages, &MemberReviewEntry.gate_stage?/1)

      assert MemberReviewEntry.member_work_settled?(task, stages)
    end

    # MUTANT 1 and MUTANT 2 killer. If clause (c) required EVERY stage to be
    # settled (rather than every NON-gate stage), the still-pending gate stage
    # would make this false and the member would stall exactly as it does in
    # production today.
    test "hole B: the final stage is the gate and is still pending — non-gate work settled is enough",
         %{project: project, stack: stack} do
      task = member(project, stack, "in_progress", "Hole B member")

      {plan, _} =
        plan_with_stages(task, [
          {"Build", "passed", ["test_pass"]},
          {"Lint", "passed", ["lint_pass"]},
          {"Task-level review", "pending", ["e2e_behavior"]}
        ])

      stages = reload_stages(plan)

      # The discriminator: exactly one gate stage, and it is UNSETTLED.
      gate = Enum.filter(stages, &MemberReviewEntry.gate_stage?/1)
      assert [gate_stage] = gate
      assert gate_stage.status == "pending"

      assert MemberReviewEntry.member_work_settled?(task, stages)
    end

    # Where the rule LOSES: a member that still has real non-gate work running
    # must wait. A fix that makes everything enter in_review immediately would
    # pass the two tests above and destroy the gate.
    test "false when a NON-gate stage is still running alongside a pending gate", %{
      project: project,
      stack: stack
    } do
      task = member(project, stack, "in_progress", "Still working member")

      {plan, _} =
        plan_with_stages(task, [
          {"Build", "passed", ["test_pass"]},
          {"Deploy prep", "running", ["lint_pass"]},
          {"Task-level review", "pending", ["e2e_behavior"]}
        ])

      stages = reload_stages(plan)

      refute MemberReviewEntry.member_work_settled?(task, stages)
    end

    # Clause (a). Solo tasks keep their existing terminal path.
    test "false for a non-member task with everything settled", %{project: project} do
      task = member(project, nil, "in_progress", "Solo task")
      assert task.stack_id == nil

      {plan, _} =
        plan_with_stages(task, [
          {"Build", "passed", ["test_pass"]},
          {"Lint", "passed", ["lint_pass"]}
        ])

      stages = reload_stages(plan)

      # The fixture is settled and gate-free — everything EXCEPT clause (a)
      # holds, so a false answer here can only be clause (a).
      refute Enum.any?(stages, &MemberReviewEntry.gate_stage?/1)
      assert Enum.all?(stages, &(&1.status == "passed"))

      refute MemberReviewEntry.member_work_settled?(task, stages)
    end

    # MUTANT 3 killer, and the ADR-0046 regression guard. Dropping clause (b)'s
    # status guard makes this true and puts the 2026-07-27 eight-member
    # `deploying` regression back on the table.
    test "adr-0046: false for a member already at deploying", %{project: project, stack: stack} do
      task = deployable_member(project, stack, "Deploying member")

      {plan, _} =
        plan_with_stages(task, [
          {"Build", "passed", ["test_pass"]},
          {"Lint", "passed", ["lint_pass"]}
        ])

      task = deploying!(task)
      assert task.status == "deploying"

      stages = reload_stages(plan)

      # Everything EXCEPT clause (b) holds.
      refute Enum.any?(stages, &MemberReviewEntry.gate_stage?/1)
      assert Enum.all?(stages, &(&1.status == "passed"))

      refute MemberReviewEntry.member_work_settled?(task, stages)
    end

    # MUTANT 4 killer. Clause (d). Every stage here is a gate stage, so
    # clause (c) filters the list to EMPTY and `Enum.all?/2` over an empty list
    # is `true` — (c) is satisfied vacuously. Only (d) stops it.
    test "false for an all-pending plan whose every stage is a gate stage", %{
      project: project,
      stack: stack
    } do
      task = member(project, stack, "in_progress", "All pending member")

      {plan, _} =
        plan_with_stages(task, [
          {"Review one", "pending", ["e2e_behavior"]},
          {"Review two", "pending", ["manual_approval"]}
        ])

      stages = reload_stages(plan)

      assert Enum.all?(stages, &MemberReviewEntry.gate_stage?/1)
      assert Enum.all?(stages, &(&1.status == "pending"))
      assert stages |> Enum.reject(&MemberReviewEntry.gate_stage?/1) |> Enum.empty?()

      refute MemberReviewEntry.member_work_settled?(task, stages)
    end

    test "false for a nil task and for a non-list stages argument", %{
      project: project,
      stack: stack
    } do
      task = member(project, stack, "in_progress", "Nil guards")
      refute MemberReviewEntry.member_work_settled?(nil, [])
      refute MemberReviewEntry.member_work_settled?(task, :not_a_list)
    end
  end

  # ── maybe_enter_in_review/2 ───────────────────────────────────────────

  describe "maybe_enter_in_review/2" do
    test "hole A: transitions the gate-free member in_progress -> in_review, given a plan" do
      %{task: task, plan: plan, stages: stages} = gate_free_member_fixture()

      refute Enum.any?(stages, &MemberReviewEntry.gate_stage?/1)

      # BEAT 1 — pre-state.
      assert Tasks.get_task_record(task.id).status == "in_progress"

      # BEAT 2 — act. Passed a PLAN, so this also covers plan -> task resolution.
      assert {:ok, updated} = MemberReviewEntry.maybe_enter_in_review(plan, stages)

      # BEAT 3 — post-state.
      assert updated.status == "in_review"
      assert Tasks.get_task_record(task.id).status == "in_review"
    end

    test "accepts a task struct directly", %{project: project, stack: stack} do
      task = member(project, stack, "in_progress", "Direct task arg")

      {plan, _} =
        plan_with_stages(task, [{"Build", "passed", ["test_pass"]}])

      stages = reload_stages(plan)

      assert Tasks.get_task_record(task.id).status == "in_progress"
      assert {:ok, updated} = MemberReviewEntry.maybe_enter_in_review(task, stages)
      assert updated.status == "in_review"
    end

    test "is a :noop and leaves the deploying member untouched", %{
      project: project,
      stack: stack
    } do
      task = deployable_member(project, stack, "Deploying noop member")

      {plan, _} =
        plan_with_stages(task, [
          {"Build", "passed", ["test_pass"]},
          {"Lint", "passed", ["lint_pass"]}
        ])

      _ = deploying!(task)

      # BEAT 1 — pre-state.
      assert Tasks.get_task_record(task.id).status == "deploying"

      # BEAT 2 — act.
      assert MemberReviewEntry.maybe_enter_in_review(plan, reload_stages(plan)) == :noop

      # BEAT 3 — post-state UNCHANGED. Without this the 2026-07-27 fix regresses.
      assert Tasks.get_task_record(task.id).status == "deploying"
    end

    test "is a :noop for a member with unsettled non-gate work", %{
      project: project,
      stack: stack
    } do
      task = member(project, stack, "in_progress", "Unsettled noop member")

      {plan, _} =
        plan_with_stages(task, [
          {"Build", "passed", ["test_pass"]},
          {"Deploy prep", "running", ["lint_pass"]}
        ])

      assert Tasks.get_task_record(task.id).status == "in_progress"
      assert MemberReviewEntry.maybe_enter_in_review(plan, reload_stages(plan)) == :noop
      assert Tasks.get_task_record(task.id).status == "in_progress"
    end

    test "is a :noop for a solo task", %{project: project} do
      task = member(project, nil, "in_progress", "Solo noop task")

      {plan, _} =
        plan_with_stages(task, [{"Build", "passed", ["test_pass"]}])

      assert MemberReviewEntry.maybe_enter_in_review(plan, reload_stages(plan)) == :noop
      assert Tasks.get_task_record(task.id).status == "in_progress"
    end

    test "is a :noop for a nil input" do
      assert MemberReviewEntry.maybe_enter_in_review(nil, []) == :noop
    end
  end

  # ── shared fixtures ───────────────────────────────────────────────────

  # The DISCRIMINATING fixture: a stack member whose stages carry NO
  # `e2e_behavior` and NO `manual_approval`. Every caller asserts that
  # explicitly before asserting an outcome.
  defp gate_free_member_fixture do
    {:ok, project} = Tasks.create_project(%{name: "Gate-free Project"})
    {:ok, stack} = create_stack(project, "gate-free")
    task = member(project, stack, "in_progress", "Gate-free member")

    {plan, _} =
      plan_with_stages(task, [
        {"Build", "passed", ["test_pass"]},
        {"Lint", "passed", ["lint_pass"]}
      ])

    %{project: project, stack: stack, task: task, plan: plan, stages: reload_stages(plan)}
  end

  defp deploying!(task) do
    {:ok, task} = Tasks.transition_task(task, "in_review")
    {:ok, task} = Tasks.transition_task(task, "deploying")
    task
  end
end
