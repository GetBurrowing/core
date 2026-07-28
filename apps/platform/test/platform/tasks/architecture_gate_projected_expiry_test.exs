defmodule Platform.Tasks.ArchitectureGateProjectedExpiryTest do
  @moduledoc """
  ADR-0046 member 5 stage 5 aftermath — the gate that expires and is never
  written down.

  `Tasks.architecture_gate/1` PROJECTS an overdue `"pending"` verdict as
  `{:resolved, %{"state" => "expired"}}` without persisting anything. That
  projection is the correctness guarantee (nothing blocks forever), but it
  is only a read. Something still has to WRITE the row, and on one real
  path nothing ever does:

    * `TaskRouterWatcher.should_run?/1` requires `assignee_type == "agent"`,
      so a task whose PLANNING assignee is a USER never has a router, never
      arms `{:architecture_gate_deadline, _}`, and never gets the `:overdue`
      occupancy re-fire on rehydrate.
    * `architecture_gate_admission/2` then reads only the boolean, gets
      `false` from the projection, returns `:inert`, and `do_approve_plan/3`
      approves while writing nothing about the gate.

  The consequence, and the reason this file exists: the verdict row stays
  `"pending"` and the task keeps the `architecture: "complete"` outcome
  written at submit from `{:ok, :dispatched}`. An unanswered gate is then
  BYTE-IDENTICAL to an architect pass, and `AutoMerger.execute_merge/4`
  auto-merges it.

  There is a narrower second window on the same mechanism: an
  agent-assigned task whose human clicks Approve after the deadline but
  before any router observes the task.

  ## What this file does NOT claim

  It does not claim a new gate STATE was needed. `"expired"` /
  `"deadline"` already exist in `Plan.architecture_gate_states/0` and
  `Plan.architecture_verdict_sources/0` and are already what a router
  writes when one exists. The defect is a missing writer, not a missing
  word — see `distinguishes_test` below, which pins that an
  expired-by-projection gate is observably different from an architect
  pass on three fields while `plan.status` is identical on both.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.TaskRouterWatcher
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{AutoMerger, Plan, Task}

  defp u, do: System.unique_integer([:positive])

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Projected Expiry Project #{u()}"})
    %{project: project}
  end

  defp user_fixture do
    n = u()

    Repo.insert!(%Platform.Accounts.User{
      name: "Approver #{n}",
      email: "approver-#{n}@example.com",
      oidc_sub: "projected-expiry-sub-#{n}"
    })
  end

  # THE LOAD-BEARING FIXTURE DETAIL: `assignee_type: "user"`.
  #
  # Every other gate fixture in this suite assigns an agent, and against an
  # agent-assigned task the watcher guard is invisible — a router would
  # exist, arm the deadline and settle the row, and this whole file would
  # be testing a path the production defect does not live on. `opts` allows
  # `assignee_type: "agent"` so the *contrast* can be asserted rather than
  # assumed.
  defp task_fixture(project, opts \\ []) do
    assignee_type = Keyword.get(opts, :assignee_type, "user")
    assignee_id = Keyword.get(opts, :assignee_id, Ecto.UUID.generate())

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Projected expiry fixture #{u()}",
        status: "planning",
        auto_approve_plan: Keyword.get(opts, :auto_approve_plan, false),
        assignee_type: assignee_type,
        assignee_id: assignee_id,
        phase_assignees: %{
          "planning" => %{"assignee_id" => assignee_id, "assignee_type" => assignee_type},
          "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"},
          "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
        }
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})

    {task, plan}
  end

  # The state a GATED submit leaves behind: plan `pending_review`, gate
  # open, cursor at `:architecting`, and — the part that makes the defect
  # bite — `planning_step_outcomes["architecture"] == "complete"`, written
  # from `{:ok, :dispatched}` at submit time. Without that entry the "an
  # unanswered gate is byte-identical to a pass" claim would be untestable,
  # because the pass case would have an entry and the expired case would
  # have nothing.
  defp open_gate!(task, plan) do
    {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()
    {:ok, gated} = Tasks.open_architecture_gate(submitted, nil)
    {:ok, _task} = Tasks.set_planning_step(task.id, :architecting)
    {:ok, _task} = Tasks.record_planning_step(task.id, :architecture, {:ok, :dispatched})
    gated
  end

  # Push `deadline_at` into the past leaving `state` as `"pending"` — the
  # exact row shape a real gate reaches when its timeout elapses and no
  # router exists to notice. Written through `update_all` so no changeset
  # can normalise it.
  defp expire_deadline!(%Plan{} = plan, seconds_ago \\ 3600) do
    verdict =
      Map.put(
        Repo.get!(Plan, plan.id).architecture_verdict,
        "deadline_at",
        DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.to_iso8601()
      )

    {1, _} =
      Plan
      |> where([p], p.id == ^plan.id)
      |> Repo.update_all(set: [architecture_verdict: verdict])

    Repo.get!(Plan, plan.id)
  end

  defp reload(%Plan{id: id}), do: Repo.get!(Plan, id)
  defp reload(%Task{id: id}), do: Repo.get!(Task, id)

  defp architecture_entry(task_id) do
    (Repo.get!(Task, task_id).planning_step_outcomes || %{})
    |> Map.get("architecture", %{})
  end

  # ── THE FALSIFIER ─────────────────────────────────────────────────────
  #
  # Run BEFORE the fix was written, per the stage contract. If this passed
  # on `4cec479b` some settler I had not found was already running and the
  # whole stage would be wrong. It did not pass: the verdict read
  # `"pending"` and the outcome read `"complete"`. Detonation output is in
  # the stage report.

  describe "FALSIFIER: a user-assigned task's expired gate settles at the approval" do
    test "the human approval writes the expired verdict nobody else would", %{project: project} do
      user = user_fixture()
      {task, plan} = task_fixture(project)
      gated = open_gate!(task, plan)

      # POSITIVE CONTROL on the fixture itself. Without these two, an
      # agent-assigned fixture would sail through every assertion below
      # while testing a path that has a router and therefore does not have
      # the bug.
      refute TaskRouterWatcher.should_run?(reload(task)),
             "fixture must be user-assigned for planning — an agent-assigned task " <>
               "gets a router, which settles the gate and hides the defect"

      refute TaskRouterWatcher.router_running?(task.id)

      # And the contrast: the SAME predicate says yes to an agent assignee,
      # so the refute above is measuring the assignee and not a typo in the
      # struct shape.
      {agent_task, _agent_plan} = task_fixture(project, assignee_type: "agent")
      assert TaskRouterWatcher.should_run?(reload(agent_task))

      expired = expire_deadline!(gated)

      # Pre-state: the row still says pending, and the projection already
      # says expired. Both halves matter — the gap between them IS the bug.
      assert %{"state" => "pending"} = expired.architecture_verdict
      assert {:resolved, %{"state" => "expired"}} = Tasks.architecture_gate(expired)
      assert architecture_entry(task.id)["outcome"] == "complete"
      assert reload(task).planning_step == "architecting"

      assert {:ok, approved} = Tasks.approve_plan(expired, user.id)
      assert approved.status == "approved"

      verdict = reload(expired).architecture_verdict
      assert verdict["state"] == "expired"
      assert verdict["source"] == "deadline"
      assert is_binary(verdict["resolved_at"])

      # NOT `"human_override"`. The human did not override a gate — the
      # gate had already run out of time before they arrived, and
      # recording their click as an override would attribute a decision
      # nobody made.
      refute verdict["state"] == "human_override"
      assert verdict["resolved_by"] == nil

      # The cursor is returned to `:planning`, the same as every other exit
      # from the gate. Pinned by probe-then-pin (the probe asserted an
      # impossible value and printed `"planning"`), and paired with the
      # pre-approval control below so it cannot pass by the cursor simply
      # never having moved to `:architecting` in the first place.
      assert reload(task).planning_step == "planning"

      entry = architecture_entry(task.id)
      assert entry["outcome"] == "failed"
      assert entry["detail"] =~ "expired"
    end

    test "the same settlement happens on the agent-assigned late-click window", %{
      project: project
    } do
      user = user_fixture()
      {task, plan} = task_fixture(project, assignee_type: "agent")
      gated = open_gate!(task, plan)
      expired = expire_deadline!(gated)

      # No router is actually RUNNING here (nothing started one in this
      # test), which is the narrower window the stage names: a human
      # clicking Approve after the deadline but before any router observes
      # the task.
      refute TaskRouterWatcher.router_running?(task.id)

      assert {:ok, _approved} = Tasks.approve_plan(expired, user.id)

      assert %{"state" => "expired", "source" => "deadline"} =
               reload(expired).architecture_verdict

      assert architecture_entry(task.id)["outcome"] == "failed"
    end
  end

  # ── THE DISTINCTION ───────────────────────────────────────────────────

  describe "an expired-by-projection gate is observably different from a pass" do
    test "same plan status, three different fields", %{project: project} do
      user = user_fixture()

      # A: gate expires unanswered, human approves.
      {task_a, plan_a} = task_fixture(project)
      gated_a = open_gate!(task_a, plan_a)
      expired_a = expire_deadline!(gated_a)
      assert {:ok, _} = Tasks.approve_plan(expired_a, user.id)

      # B: architect answers `:pass` through the MCP channel, which settles
      # the submission and auto-approves.
      {task_b, plan_b} = task_fixture(project)
      gated_b = open_gate!(task_b, plan_b)

      assert {:ok, _} =
               Tasks.resolve_architecture_gate(gated_b, :pass,
                 source: "mcp",
                 resolved_by: Ecto.UUID.generate()
               )

      {:ok, _} = Tasks.approve_plan(reload(gated_b), user.id)

      a = reload(expired_a)
      b = reload(gated_b)

      # WHAT DOES NOT DISTINGUISH THEM, named explicitly because it is the
      # whole reason the other three fields have to.
      assert a.status == "approved"
      assert b.status == "approved"
      assert a.status == b.status

      assert a.architecture_verdict["state"] == "expired"
      assert b.architecture_verdict["state"] == "passed"
      refute a.architecture_verdict["state"] == b.architecture_verdict["state"]

      assert a.architecture_verdict["source"] == "deadline"
      assert b.architecture_verdict["source"] == "mcp"

      assert architecture_entry(task_a.id)["outcome"] == "failed"
      assert architecture_entry(task_b.id)["outcome"] == "complete"
    end

    test "AutoMerger refuses the expired one and not the passed one", %{project: project} do
      user = user_fixture()

      {task_a, plan_a} = task_fixture(project)
      gated_a = open_gate!(task_a, plan_a)
      expired_a = expire_deadline!(gated_a)
      assert {:ok, _} = Tasks.approve_plan(expired_a, user.id)

      {task_b, plan_b} = task_fixture(project)
      gated_b = open_gate!(task_b, plan_b)
      assert {:ok, _} = Tasks.resolve_architecture_gate(gated_b, :pass, source: "mcp")

      assert {:error, :planning_gate_failed, detail} =
               AutoMerger.execute_merge(reload(task_a), "owner/repo", 1, "squash")

      assert detail =~ "architecture"

      # POSITIVE CONTROL: the passed task reaches the same predicate and is
      # NOT refused on it. Without this the assertion above would also pass
      # if `planning_gate_failed?/1` had been made to return true for
      # everything.
      refute Tasks.planning_gate_failed?(reload(task_b))
      assert Tasks.planning_gate_failed?(reload(task_a))

      # `StackDeployer.planning_gate_section/1` is the other production
      # consumer and reads the same single definition. Assert on that
      # definition's output shape rather than on the private renderer.
      assert [%{step: "architecture", detail: detail_b}] =
               Tasks.failed_planning_steps(reload(task_a))

      assert detail_b =~ "expired"
      assert Tasks.failed_planning_steps(reload(task_b)) == []
    end
  end

  # ── THE RACE ──────────────────────────────────────────────────────────

  describe "a persisted verdict is never rewritten by the admission" do
    test "an already-expired row keeps its resolved_at and resolved_by", %{project: project} do
      user = user_fixture()
      architect_id = Ecto.UUID.generate()
      {task, plan} = task_fixture(project)
      gated = open_gate!(task, plan)
      expired = expire_deadline!(gated)

      # A router DID fire here, first.
      assert {:ok, settled} =
               Tasks.resolve_architecture_gate(expired, :expired, resolved_by: architect_id)

      before = settled.architecture_verdict
      assert before["state"] == "expired"
      assert before["resolved_by"] == architect_id

      # The planning-step timestamp is the SHARPER witness here. Every
      # verdict FIELD survives a hypothetical re-write unchanged (merging
      # `%{"state" => "expired"}` over an already-expired verdict is a
      # no-op, and `put_verdict_default/3` will not clobber a present
      # `resolved_at` / `resolved_by` / `source`), so the verdict
      # assertions below cannot by themselves prove the settler declined to
      # write — only `recorded_at` can.
      step_before = architecture_entry(task.id)["recorded_at"]
      assert is_binary(step_before)

      assert {:ok, _} = Tasks.approve_plan(reload(expired), user.id)

      after_verdict = reload(expired).architecture_verdict
      assert after_verdict["resolved_at"] == before["resolved_at"]
      assert after_verdict["resolved_by"] == architect_id
      assert after_verdict["state"] == "expired"
      assert after_verdict["source"] == before["source"]
      assert architecture_entry(task.id)["recorded_at"] == step_before
    end

    test "a persisted PASS is not overwritten by a stale deadline", %{project: project} do
      user = user_fixture()
      {task, plan} = task_fixture(project)
      gated = open_gate!(task, plan)

      # Answered, THEN the deadline passes. The architect won the race and
      # the projection must not be able to retro-expire a written verdict.
      assert {:ok, passed} = Tasks.resolve_architecture_gate(gated, :pass, source: "mcp")
      _ = expire_deadline!(passed)

      assert {:ok, _} = Tasks.approve_plan(reload(gated), user.id)

      verdict = reload(gated).architecture_verdict
      assert verdict["state"] == "passed"
      assert verdict["source"] == "mcp"
      assert architecture_entry(task.id)["outcome"] == "complete"
    end
  end

  # ── NO SECOND APPROVAL ────────────────────────────────────────────────
  #
  # MEASURED, not assumed. The first version of this block used the default
  # fixture (`auto_approve_plan: false`) and a mutation that replaced the
  # settler's body with `resolve_architecture_gate(plan, :expired)` — the
  # exact wrong fix the stage forbids — SURVIVED it, because
  # `maybe_auto_approve/1` returns `{:ok, plan}` untouched unless
  # `task.auto_approve_plan` or the stack's `auto_accept_plan` is set. The
  # re-entrancy hazard is real but it is CONDITIONAL, and a fixture that
  # does not satisfy the condition cannot see it. The `auto_approve_plan:
  # true` case below is the one that kills that mutation; the `false` case
  # is kept and DECLARED as passing trivially, because "the plan is not
  # double-approved" is worth pinning on the common path even though
  # nothing there could double-approve it.

  describe "settling at the admission does not re-enter approval" do
    test "TRIVIAL CONTROL (auto_approve_plan: false — nothing could re-enter)", %{
      project: project
    } do
      user = user_fixture()
      {task, plan} = task_fixture(project)
      gated = open_gate!(task, plan)
      expired = expire_deadline!(gated)

      assert {:ok, _} = Tasks.approve_plan(expired, user.id)

      approved = reload(expired)

      assert approved.approved_by == user.id
      assert approved.auto_approved_at == nil
      assert approved.status == "approved"
      assert [_only_one] = Repo.all(from(p in Plan, where: p.task_id == ^task.id))
    end

    test "THE DETECTOR (auto_approve_plan: true — the human's id survives)", %{project: project} do
      user = user_fixture()
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)
      expired = expire_deadline!(gated)

      # POSITIVE CONTROL that the auto path is genuinely armed on this
      # fixture. Without it the "true" case could silently degrade into the
      # trivial one — an empty plan, or a missing execution/review assignee,
      # makes `auto_approve_precondition/2` skip and the re-entrancy
      # disappears again without any assertion noticing.
      reloaded_task = reload(task)
      assert reloaded_task.auto_approve_plan
      assert reloaded_task.phase_assignees["execution"]["assignee_id"]
      assert reloaded_task.phase_assignees["review"]["assignee_id"]
      assert [_stage] = Repo.all(from(s in Platform.Tasks.Stage, where: s.plan_id == ^plan.id))

      assert {:ok, _} = Tasks.approve_plan(expired, user.id)

      approved = reload(expired)

      # If the settler called `resolve_architecture_gate/3` it would run
      # `settle_plan_submission -> maybe_auto_approve -> approve_plan(plan,
      # "system:auto", auto: true)` from INSIDE `approve_plan`, approving
      # this plan twice with two different actors. `auto_approved_at` is
      # the field that survives that inner write, so it is the load-bearing
      # assertion here — `approved_by` alone is not, because the outer
      # write lands second and overwrites it back to the human.
      assert approved.auto_approved_at == nil
      assert approved.approved_by == user.id
      assert approved.status == "approved"
      assert [_only_one] = Repo.all(from(p in Plan, where: p.task_id == ^task.id))

      # The gate still reads as the expiry it was — a re-entrant approval
      # would not change this, so it is a shape pin, not a second detector.
      assert %{"state" => "expired", "source" => "deadline"} = approved.architecture_verdict
    end
  end
end
