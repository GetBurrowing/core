defmodule Platform.Tasks.ArchitectureRejectionLoopTest do
  @moduledoc """
  ADR-0046 member 6 stage 3 — the loop, and the bound on it.

  Stage 1 built the arithmetic and stage 2 built the messenger; neither
  could detonate, because neither was wired to anything. This file is where
  the fix detectors live. Two of them are mandatory and both were detonated;
  the measured output is in the stage note and reproduced below.

  Not `async: true`: `resolve_architecture_gate/3` broadcasts
  `{:plan_updated, _}` on `tasks:board`, which wakes the singleton
  `TaskRouterWatcher`, and `reject_plan/3` broadcasts again.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ArchitectureRejection
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Task

  defp u, do: System.unique_integer([:positive])

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Arch Rejection Loop Project #{u()}"})
    %{project: project}
  end

  # A task that WOULD auto-approve: the flag on and both
  # `auto_approve_precondition/2` legs satisfied. Without that, "the plan
  # did not get approved" would pass for the wrong reason.
  defp task_fixture(project, opts \\ []) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Arch rejection loop task #{u()}",
        status: Keyword.get(opts, :status, "planning"),
        auto_approve_plan: true,
        phase_assignees: %{
          "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"},
          "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
        }
      })

    task
  end

  defp plan_fixture(task, stage_names) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    stages =
      stage_names
      |> Enum.with_index(1)
      |> Enum.map(fn {name, position} ->
        {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: position, name: name})
        stage
      end)

    {Repo.get!(Plan, plan.id), stages}
  end

  # The state a gated submit leaves behind, reached directly so these tests
  # exercise the REJECTION rather than re-testing member 5's submit branch.
  defp open_gate!(task, plan, architect_id \\ nil) do
    {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()
    {:ok, gated} = Tasks.open_architecture_gate(submitted, architect_id)
    {:ok, _task} = Tasks.set_planning_step(task.id, :architecting)
    gated
  end

  # Write a terminal verdict straight onto a plan, bypassing the gate. Used
  # only to set up HISTORY (older versions the walk has to read); the
  # version under test always goes through the real gate.
  defp seed_verdict!(%Plan{} = plan, state, opts) do
    verdict =
      %{
        "state" => state,
        "summary" => Keyword.get(opts, :summary),
        "findings" => Keyword.get(opts, :findings, []),
        "resolved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "resolved_by" => Keyword.get(opts, :resolved_by),
        "source" => "mcp"
      }

    plan
    |> Plan.architecture_verdict_changeset(%{architecture_verdict: verdict})
    |> Repo.update!()
  end

  defp finding(stage, constraint, detail) do
    %{"stage_id" => stage.id, "constraint" => constraint, "detail" => detail}
  end

  defp space_for!(task) do
    {:ok, space} = ExecutionSpace.find_or_create(task.id)
    space
  end

  defp messages_in(space_id) do
    Repo.all(from(m in Chat.Message, where: m.space_id == ^space_id, order_by: m.inserted_at))
  end

  defp rejection_messages(space_id) do
    space_id
    |> messages_in()
    |> Enum.filter(&(Map.get(&1.metadata || %{}, "reason") == "plan_rejected"))
  end

  defp reload(%Plan{id: id}), do: Repo.get!(Plan, id)

  # Written through the schema rather than through `transition_stage/2`:
  # this fixture only needs the STATUS the in-flight guard reads, and the
  # context function carries dispatch side effects that would muddy the
  # absence assertions below.
  defp start_stage!(%Stage{id: id}) do
    Repo.get!(Stage, id) |> Stage.changeset(%{status: "running"}) |> Repo.update!()
  end

  # ── DETECTOR (MANDATORY): the rejection is ACTIONABLE, not just recorded

  describe "the rejection reaches the planner" do
    # Against member 5's merged state — and against this branch with the
    # four-line seam in `settle_resolved_architecture_gate/2` reverted to
    # the bare stop — the plan comes back `pending_review` with a nil
    # `rejection_reason` and the execution space is empty. That is member
    # 5's documented interim stall. The detonation output is in the stage
    # note.
    #
    # The two halves are deliberately both here: the persisted reason is
    # the durable channel (`ContextAssembler` lifts it into every dispatch
    # context) and the non-log-only message is the wake-up channel (it is
    # the ONLY thing that causes a v2 to be authored). Either alone would
    # pass against a half-wired seam.
    test "a :reject persists the findings AND posts them to the execution space", %{
      project: project
    } do
      task = task_fixture(project)
      {plan, [stage_one, _stage_two]} = plan_fixture(task, ["Wire the dispatch", "Render it"])
      space = space_for!(task)
      gated = open_gate!(task, plan)

      assert {:ok, %Plan{status: "rejected"}} =
               Tasks.resolve_architecture_gate(gated, :reject,
                 source: "mcp",
                 summary: "Stage 1 puts task orchestration inside the chat context.",
                 findings: [
                   finding(
                     stage_one,
                     "cross_context_coupling",
                     "Move the dispatch call out of Platform.Chat."
                   )
                 ]
               )

      reloaded = reload(gated)
      assert reloaded.status == "rejected"

      # The findings, not a paraphrase of them: the stage NAME (which the
      # verdict did not carry — it carried only a stage_id, so this proves
      # the composer resolved it against `plan.stages`), the constraint
      # literal, and the architect's detail.
      assert reloaded.rejection_reason =~ "Wire the dispatch"
      assert reloaded.rejection_reason =~ "cross_context_coupling"
      assert reloaded.rejection_reason =~ "Move the dispatch call out of Platform.Chat."

      assert reloaded.rejection_reason =~
               "Stage 1 puts task orchestration inside the chat context."

      # ONE body, two channels. `PlanRejection.compose_message/3` wraps the
      # same string in its "Plan vN rejected by X:" envelope, so the posted
      # message CONTAINS the persisted reason verbatim — the architect's
      # findings are not composed twice and cannot drift.
      assert [msg] = rejection_messages(space.id)
      assert msg.content =~ "Plan v1 rejected by "
      assert String.ends_with?(msg.content, reloaded.rejection_reason)
      assert msg.log_only == false
      assert msg.metadata["plan_id"] == plan.id

      # This path does not author a v2 — the PLANNER does, in response to
      # the message above. Same invariant member 5's approval test names.
      assert length(Tasks.list_plans(task.id)) == 1
    end

    # GUARD (ordering, and it is subtle): `streak/1` inside `handle/1` sees
    # THIS version as already-rejected, because `record_architecture_verdict/3`
    # wrote the verdict before `handle/1` ran. The first rejection is
    # therefore iteration 1, not iteration 0. An off-by-one here escalates
    # a version late, which is the unbounded loop in miniature.
    test "the first rejection reads as iteration 1 of the limit", %{project: project} do
      task = task_fixture(project)
      {plan, [stage_one]} = plan_fixture(task, ["Only stage"])
      _space = space_for!(task)
      gated = open_gate!(task, plan)

      assert {:ok, _} =
               Tasks.resolve_architecture_gate(gated, :reject,
                 source: "mcp",
                 summary: "s",
                 findings: [finding(stage_one, "data_model", "Normalise the column.")]
               )

      reason = reload(gated).rejection_reason

      assert reason =~ "iteration 1 of #{ArchitectureRejection.reject_limit()}"
      refute reason =~ "iteration 0 of"

      # …and the counter agrees with what the body claims.
      assert ArchitectureRejection.streak(task.id) == 1
      refute ArchitectureRejection.escalation_due?(task.id)
    end
  end

  # ── DETECTOR (MANDATORY): THE BOUND ───────────────────────────────────

  describe "the bound" do
    # Two consecutive rejections across v1 and v2. The first asks for
    # another version; the second must NOT. Reverting `escalation_due?/1`
    # to always-false makes the second round take the feedback path and
    # this test fails on three separate assertions — see the stage note for
    # the verbatim output.
    #
    # The absence assertions (v2 untouched, no second message) run against
    # the SAME fixture and the SAME mechanism as the positive assertions in
    # round one, so neither half can pass against a module that always
    # rejects or one that never does.
    test "the second consecutive rejection escalates instead of asking for a v3", %{
      project: project
    } do
      task = task_fixture(project)
      {v1, [v1_stage]} = plan_fixture(task, ["Round one stage"])
      space = space_for!(task)
      gated_v1 = open_gate!(task, v1)

      assert {:ok, %Plan{status: "rejected"}} =
               Tasks.resolve_architecture_gate(gated_v1, :reject,
                 source: "mcp",
                 summary: "Round one",
                 findings: [finding(v1_stage, "cross_context_coupling", "Split the context.")]
               )

      assert length(rejection_messages(space.id)) == 1
      assert ArchitectureRejection.streak(task.id) == 1

      # The planner authors v2 in response. Same shape, still wrong.
      {v2, [v2_stage]} = plan_fixture(task, ["Round two stage"])
      gated_v2 = open_gate!(task, v2)

      assert {:ok, %Plan{status: "pending_review"}} =
               Tasks.resolve_architecture_gate(gated_v2, :reject,
                 source: "mcp",
                 summary: "Round two",
                 findings: [finding(v2_stage, "duplicated_logic", "Still duplicated.")]
               )

      # THE BOUND. v2 is parked for a human, not bounced back at the
      # planner: no rejection, no reason, and — the half that actually
      # stops the loop — no second wake-up message.
      reloaded_v2 = reload(gated_v2)
      assert reloaded_v2.status == "pending_review"
      assert reloaded_v2.rejection_reason == nil
      assert reloaded_v2.architecture_verdict["state"] == "rejected"
      assert length(rejection_messages(space.id)) == 1

      # `auto_approve_plan: true` on this task, and it did NOT float the
      # plan through: `maybe_auto_approve/1` runs only from
      # `settle_plan_submission/1`, which the `:reject` branch never calls.
      assert reloaded_v2.approved_by == nil
      assert reloaded_v2.auto_approved_at == nil
      assert Repo.get!(Task, task.id).auto_approve_plan == true

      assert ArchitectureRejection.streak(task.id) == 2
      assert ArchitectureRejection.escalation_due?(task.id)
    end

    # The same bound, asserted on `handle/1`'s RETURN VALUE rather than on
    # its effects. Paired with the test above on purpose: that one proves
    # the effects stop, this one proves the module says which branch it
    # took. `{:ok, :escalated, _}` is what stage 4 hangs the digest and the
    # inbox row off, so it is a contract, not an implementation detail.
    test "handle/1 reports :feedback_sent below the limit and :escalated at it", %{
      project: project
    } do
      task = task_fixture(project)
      {v1, [v1_stage]} = plan_fixture(task, ["Round one stage"])
      _space = space_for!(task)

      # v1: verdict written, nothing downstream yet — exactly the state
      # `resolve_architecture_gate/3` hands `handle/1`.
      seeded_v1 =
        v1
        |> Plan.changeset(%{status: "pending_review"})
        |> Repo.update!()
        |> seed_verdict!("rejected",
          summary: "Round one",
          findings: [finding(v1_stage, "module_boundary", "Two contexts.")]
        )

      assert {:ok, :feedback_sent, %Plan{status: "rejected"}} =
               ArchitectureRejection.handle(seeded_v1)

      {v2, [v2_stage]} = plan_fixture(task, ["Round two stage"])

      seeded_v2 =
        v2
        |> Plan.changeset(%{status: "pending_review"})
        |> Repo.update!()
        |> seed_verdict!("rejected",
          summary: "Round two",
          findings: [finding(v2_stage, "module_boundary", "Still two contexts.")]
        )

      assert {:ok, :escalated, %Plan{status: "pending_review"}} =
               ArchitectureRejection.handle(seeded_v2)

      assert reload(seeded_v2).rejection_reason == nil
    end
  end

  # ── GUARD (PAIRED): the in-flight refusal, from both sides ────────────

  describe "in-flight plans" do
    # Half one: the guard FIRES. Rejecting a plan whose executor already
    # has commits on a branch strands that branch and this codebase has no
    # recovery path, so `handle/1` refuses rather than rejecting.
    test "handle/1 refuses a plan with a started stage and touches nothing", %{project: project} do
      task = task_fixture(project)
      {plan, [stage_one, _stage_two]} = plan_fixture(task, ["Running stage", "Later stage"])
      space = space_for!(task)

      seeded =
        plan
        |> Plan.changeset(%{status: "pending_review"})
        |> Repo.update!()
        |> seed_verdict!("rejected",
          summary: "Too late",
          findings: [finding(stage_one, "data_model", "Wrong shape.")]
        )

      start_stage!(stage_one)

      assert {:error, :plan_in_flight} = ArchitectureRejection.handle(seeded)

      untouched = reload(seeded)
      assert untouched.status == "pending_review"
      assert untouched.rejection_reason == nil
      assert rejection_messages(space.id) == []
    end

    # The task-status half of the same guard, on the same mechanism.
    test "handle/1 refuses when the task itself has moved past planning", %{project: project} do
      task = task_fixture(project)
      {plan, [stage_one]} = plan_fixture(task, ["Only stage"])
      space = space_for!(task)

      seeded =
        plan
        |> Plan.changeset(%{status: "pending_review"})
        |> Repo.update!()
        |> seed_verdict!("rejected",
          summary: "Too late",
          findings: [finding(stage_one, "data_model", "Wrong shape.")]
        )

      Repo.get!(Task, task.id)
      |> Task.changeset(%{status: "in_progress"})
      |> Repo.update!()

      assert {:error, :plan_in_flight} = ArchitectureRejection.handle(seeded)
      assert reload(seeded).status == "pending_review"
      assert rejection_messages(space.id) == []
    end

    # Half two, and this is the half that answers "prove it rather than
    # assuming it": the SANCTIONED path cannot reach the state above.
    # Approving through member 5's human-override path resolves the gate,
    # and a resolved gate refuses a second verdict, so `handle/1` is never
    # called at all. One test proves the guard works; this one proves the
    # guard is unreachable from the outside. Neither alone is the assertion
    # the task asks for.
    test "resolve_architecture_gate/3 cannot reach handle/1 once a stage has started", %{
      project: project
    } do
      user =
        Repo.insert!(%Platform.Accounts.User{
          name: "Approver #{u()}",
          email: "arch-loop-#{u()}@example.com",
          oidc_sub: "arch-loop-sub-#{u()}"
        })

      task = task_fixture(project)
      {plan, [stage_one]} = plan_fixture(task, ["Only stage"])
      space = space_for!(task)
      gated = open_gate!(task, plan)

      # The human approves past the open gate, then execution starts.
      assert {:ok, %Plan{status: "approved"}} = Tasks.approve_plan(gated, user.id)
      start_stage!(stage_one)

      assert {:error, :gate_already_resolved} =
               Tasks.resolve_architecture_gate(gated, :reject,
                 source: "mcp",
                 summary: "Too late",
                 findings: [finding(stage_one, "data_model", "Wrong shape.")]
               )

      # handle/1 was never reached: no rejection, no message.
      still_approved = reload(gated)
      assert still_approved.status == "approved"
      assert still_approved.rejection_reason == nil
      assert still_approved.architecture_verdict["state"] == "human_override"
      assert rejection_messages(space.id) == []
    end
  end

  # ── GUARD: the rest of the composed body ──────────────────────────────

  describe "the feedback body" do
    # Member 5's finding shape allows a nil `stage_id` — a plan-wide
    # objection. It must still render and still post.
    test "a finding with no stage renders (plan-wide) and still posts", %{project: project} do
      task = task_fixture(project)
      {plan, _stages} = plan_fixture(task, ["Only stage"])
      space = space_for!(task)
      gated = open_gate!(task, plan)

      assert {:ok, %Plan{status: "rejected"}} =
               Tasks.resolve_architecture_gate(gated, :reject,
                 source: "mcp",
                 summary: "The whole plan is shaped wrong.",
                 findings: [
                   %{
                     "stage_id" => nil,
                     "constraint" => "duplicated_logic",
                     "detail" => "Three stages reimplement the same walk."
                   }
                 ]
               )

      reason = reload(gated).rejection_reason
      assert reason =~ "(plan-wide)"
      assert reason =~ "duplicated_logic"
      assert [msg] = rejection_messages(space.id)
      assert String.ends_with?(msg.content, reason)
    end

    # The verdict's own `"stage_name"` wins over a lookup, because member
    # 5's shape carries it and a stage renamed since the verdict was
    # written should still read as what the architect actually objected to.
    test "an explicit stage_name in the finding is used verbatim", %{project: project} do
      task = task_fixture(project)
      {plan, [stage_one]} = plan_fixture(task, ["Current name"])
      _space = space_for!(task)
      gated = open_gate!(task, plan)

      assert {:ok, _} =
               Tasks.resolve_architecture_gate(gated, :reject,
                 source: "mcp",
                 summary: "s",
                 findings: [
                   %{
                     "stage_id" => stage_one.id,
                     "stage_name" => "Name the architect saw",
                     "constraint" => "module_boundary",
                     "detail" => "d"
                   }
                 ]
               )

      assert reload(gated).rejection_reason =~ "Name the architect saw"
    end

    # GUARD (no-raise contract): the persisted reason is the durable truth
    # and the chat post is best-effort. With the space gone, the rejection
    # must still land and `handle/1` must still report success — mirroring
    # the comment `PlanRejection` inherited from `tasks_live.ex`.
    test "a failed execution-space post still leaves the plan rejected", %{project: project} do
      task = task_fixture(project)
      {plan, [stage_one]} = plan_fixture(task, ["Only stage"])

      assert ExecutionSpace.find_by_task_id(task.id) == nil

      seeded =
        plan
        |> Plan.changeset(%{status: "pending_review"})
        |> Repo.update!()
        |> seed_verdict!("rejected",
          summary: "s",
          findings: [finding(stage_one, "module_boundary", "d")]
        )

      assert {:ok, :feedback_sent, %Plan{status: "rejected"}} =
               ArchitectureRejection.handle(seeded)

      reloaded = reload(seeded)
      assert reloaded.status == "rejected"
      assert reloaded.rejection_reason =~ "module_boundary"
    end
  end

  # ── GUARD: second-mechanism binding ───────────────────────────────────

  # Same family as member 5's source-vocabulary guard. The four constraint
  # literals are closed by `Plan.architecture_constraints/0` at the schema
  # layer and again at the tool boundary; this module only FORMATS what
  # already passed both. A local copy of a literal is the defect that a
  # refactor would otherwise introduce silently — the body would keep
  # rendering correctly while the vocabulary quietly forked.
  test "the module contains no copy of the constraint vocabulary" do
    source = File.read!("lib/platform/tasks/architecture_rejection.ex")

    for constraint <- Plan.architecture_constraints() do
      refute source =~ constraint,
             "architecture_rejection.ex hardcodes the constraint literal #{inspect(constraint)}; " <>
               "read it from Plan.architecture_constraints/0 instead"
    end
  end
end
