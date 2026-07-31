defmodule Platform.Tasks.ArchitectureGateExpirySettlementTest do
  @moduledoc """
  Task 019fa605 stage 2 — the invariants stage 1's sweep must not be able to
  buy liveness by breaking.

  ## Why this file exists

  Stage 1 made an expired architecture gate on a router-less task settle, so
  an armed plan finally reaches `approved`. The failure mode WORSE than the
  stall it replaced is a sweep that gets there by quietly marking the gate
  `passed` — the plan would ship with no record that nobody reviewed it, and
  `AutoMerger` would merge it. Conflating "the architect approved" with "the
  architect never answered" is exactly what ADR-0046 member 4 and task
  `019fa510` exist to prevent.

  So every settlement assertion here is a CONJUNCTION: the plan is approved
  AND the verdict still reads `expired`/`deadline` AND
  `Tasks.planning_gate_failed?/1` is still true AND
  `AutoMerger.execute_merge/4` still refuses. Each half is worthless alone.

  ## Positive controls, not just negatives

  `planning_gate_failed?/1` returning true and `execute_merge/4` refusing
  would ALSO hold if those functions were true of everything. Every such
  assertion is therefore paired, in the same file, with a sibling task whose
  architect genuinely answered via `resolve_architecture_gate(:pass)` and
  which must NOT be reported failed and must NOT be refused a merge.

  The same rule governs the exclusions: every "nothing happened" assertion
  sits in a test that also shows the same code path speaking.

  ## Fixture arming is part of the test, not of the setup

  `maybe_auto_approve/1` returns `{:ok, plan}` UNTOUCHED unless
  `task.auto_approve_plan` or `task.stack.auto_accept_plan` is set, and
  `auto_approve_precondition/2` skips on an empty plan or a missing
  execution/review assignee. `019fa510` stage 5's first re-entrancy test
  survived the very mutation it was written to kill because its fixture did
  not satisfy that condition — the hazard is CONDITIONAL, and a fixture that
  does not arm it tests nothing.

  So `assert_armed!/2` runs INLINE in every test whose outcome depends on the
  auto path, and every outcome is keyed on `auto_approved_at` — never on
  `approved_by` alone, which an outer human write overwrites.

  ## Test-only stage

  No production code changes. The falsifier for a test-only stage is the
  file's own inability to pass without stage 1's fix and with stage 1's fix
  mutated; see the commit message for the three detonations.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Inbox
  alias Platform.Orchestration.TaskRouterWatcher
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{AutoMerger, Plan, Stacks, Stage, Task}

  defp u, do: System.unique_integer([:positive])

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Gate Expiry Settlement #{u()}"})
    %{project: project}
  end

  # ── fixtures (same discipline as stage 1's sweep test) ─────────────────

  defp sponsor_fixture do
    n = u()

    Repo.insert!(%Platform.Accounts.User{
      name: "Sponsor #{n}",
      email: "sponsor-#{n}@example.com",
      oidc_sub: "sub-#{n}"
    })
  end

  # THE LOAD-BEARING FIXTURE DETAIL: `assignee_type: "user"` on the PLANNING
  # phase. Against an agent-assigned task a router exists, arms the deadline
  # and settles the row, and this whole file would exercise a path the
  # production defect does not live on.
  defp task_fixture(project, opts) do
    assignee_type = Keyword.get(opts, :assignee_type, "user")
    assignee_id = Keyword.get(opts, :assignee_id, Ecto.UUID.generate())

    attrs = %{
      project_id: project.id,
      title: "Gate expiry settlement fixture #{u()}",
      status: "planning",
      auto_approve_plan: Keyword.get(opts, :auto_approve_plan, false),
      assignee_type: assignee_type,
      assignee_id: assignee_id,
      phase_assignees: %{
        "planning" => %{"assignee_id" => assignee_id, "assignee_type" => assignee_type},
        "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"},
        "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
      }
    }

    attrs =
      case Keyword.get(opts, :sponsor_user_id) do
        nil -> attrs
        id -> Map.put(attrs, :sponsor_user_id, id)
      end

    {:ok, task} = Tasks.create_task(attrs)
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})

    {task, plan}
  end

  # The state a GATED submit leaves behind: plan `pending_review`, gate open,
  # cursor at `:architecting`, `planning_step_outcomes["architecture"]`
  # written `complete` from `{:ok, :dispatched}` at submit time.
  defp open_gate!(task, plan) do
    {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()
    {:ok, gated} = Tasks.open_architecture_gate(submitted, nil)
    {:ok, _task} = Tasks.set_planning_step(task.id, :architecting)
    {:ok, _task} = Tasks.record_planning_step(task.id, :architecture, {:ok, :dispatched})
    gated
  end

  # Push `deadline_at` into the past leaving `state` as `"pending"` — the row
  # shape a real gate reaches when its timeout elapses and no router exists to
  # notice. Written through `update_all` so no changeset can normalise it.
  defp expire_deadline!(%Plan{} = plan, seconds_ago) do
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

  # Arming is asserted, never assumed. See the moduledoc.
  defp assert_armed!(%Task{} = task, %Plan{} = plan) do
    task = reload(task)
    assert task.auto_approve_plan
    assert task.phase_assignees["execution"]["assignee_id"]
    assert task.phase_assignees["review"]["assignee_id"]
    assert [_stage] = Repo.all(from(s in Stage, where: s.plan_id == ^plan.id))
    :ok
  end

  # An armed, router-less, overdue gate, ready for the sweep.
  defp armed_expired!(project, opts \\ []) do
    {task, plan} =
      task_fixture(project, Keyword.put_new(opts, :auto_approve_plan, true))

    gated = open_gate!(task, plan)
    _ = expire_deadline!(gated, Keyword.get(opts, :overdue_seconds, 3600))
    {task, plan}
  end

  defp plan_review_rows(user_id) do
    Inbox.list_unread_for_user(user_id, kind: "task_plan_review")
  end

  # Borrowed verbatim in spirit from `auto_merger_test.exs`: asserting only
  # `{:error, _, _}` would be VACUOUS, because the planning-gate refusal is
  # itself an `{:error, _, _}`. So the non-refused case additionally asserts
  # the error atom is not ours, and tolerates a missing `gh` binary — which
  # still proves the gate was passed and the shell-out reached.
  defp refute_planning_gate_refusal(fun) do
    try do
      result = fun.()

      refute match?({:error, :planning_gate_failed, _}, result),
             "planning gate must not refuse a task whose architect passed, got #{inspect(result)}"

      assert match?({:error, _, _}, result) or match?({:ok, _}, result),
             "expected to reach the shell-out, got #{inspect(result)}"
    rescue
      e in ErlangError ->
        assert e.original == :enoent,
               "expected :enoent from a missing gh binary, got #{inspect(e)}"
    end
  end

  # ── (a) the stage-5 invariant, paired with the fix ────────────────────

  describe "settlement approves the plan without erasing the failure record" do
    test "approved AND expired AND gate-failed AND merge-refused, all at once", %{
      project: project
    } do
      {task, plan} = armed_expired!(project)
      assert_armed!(task, plan)

      # Pre-state: the projection already says expired while the ROW still
      # says pending. That gap is the defect stage 1 closed.
      assert {:resolved, %{"state" => "expired", "source" => "deadline"}} =
               Tasks.architecture_gate(plan.id)

      assert reload(plan).architecture_verdict["state"] == "pending"
      refute TaskRouterWatcher.should_run?(reload(task))

      assert %{scanned: 1, settled: 1, observed: 0} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      settled = reload(plan)

      # THE LIVENESS HALF.
      assert settled.status == "approved"
      assert settled.auto_approved_at
      assert settled.approved_by == "system:auto"

      # THE HONESTY HALF. These must COEXIST with the half above. A verdict
      # reading `passed`, or a planning step reading `complete`, would mean
      # the sweep bought liveness by lying.
      assert settled.architecture_verdict["state"] == "expired"
      assert settled.architecture_verdict["source"] == "deadline"
      assert is_binary(settled.architecture_verdict["resolved_at"])

      assert Tasks.planning_gate_failed?(reload(task))
      assert [%{step: "architecture", detail: detail}] = Tasks.failed_planning_steps(reload(task))
      assert detail =~ "expired"

      # And the downstream consumer that matters: an approved plan whose
      # architecture gate expired is still refused an auto-merge, and the
      # refusal names the step and the reason.
      assert {:error, :planning_gate_failed, merge_detail} =
               AutoMerger.execute_merge(reload(task), "owner/repo", 1, "squash")

      assert merge_detail =~ "architecture"
      assert merge_detail =~ "expired"
    end

    test "POSITIVE CONTROL: a sibling whose architect passed is neither gate-failed nor merge-refused",
         %{project: project} do
      # Without this, every assertion in the test above would also hold if
      # `planning_gate_failed?/1` were true of everything and
      # `execute_merge/4` refused everything.
      {task, plan} = task_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)
      assert_armed!(task, plan)

      {:ok, _passed} = Tasks.resolve_architecture_gate(gated, :pass, source: "mcp")

      settled = reload(plan)

      # Same predicate, opposite answer on the honesty half.
      assert settled.status == "approved"
      assert settled.auto_approved_at
      assert settled.architecture_verdict["state"] == "passed"
      refute settled.architecture_verdict["source"] == "deadline"

      refute Tasks.planning_gate_failed?(reload(task))
      assert Tasks.failed_planning_steps(reload(task)) == []

      refute_planning_gate_refusal(fn ->
        AutoMerger.execute_merge(
          reload(task),
          "https://github.com/test/nonexistent-#{u()}",
          999_999,
          "squash"
        )
      end)
    end
  end

  # ── (b) the stack auto_accept_plan twin ───────────────────────────────

  describe "the stack auto_accept_plan twin shares the stall exactly" do
    test "the STACK arm settles a member whose own auto_approve_plan is false", %{
      project: project
    } do
      # `maybe_auto_approve/1` reads BOTH flags behind the SAME never-run
      # settlement, so `auto_accept_plan` stalls identically. Proving "a
      # plan got approved" is not enough — this proves WHICH arm fired.
      slug = "gate-settle-#{u()}"

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Gate settle #{slug}",
          base_branch: "main",
          rollup_branch: Stacks.rollup_branch_name(slug),
          auto_accept_plan: true
        })

      {task, plan} = task_fixture(project, auto_approve_plan: false)
      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      gated = open_gate!(task, plan)
      _ = expire_deadline!(gated, 3600)

      # A stack member's task-level `assignee_type` is DERIVED from its phase
      # assignees by `transition_task_status/2`'s `phase_pointer_attrs/2`
      # (task 019fb977 stage 4 folded the old
      # `maybe_apply_phase_assignee_and_reload/1` second write into the
      # status changeset; same derivation, one write), so asserting
      # `should_run?/1` is false is a real check, not a restatement.
      assert reload(task).auto_approve_plan == false
      assert Repo.preload(reload(task), :stack).stack.auto_accept_plan == true
      refute TaskRouterWatcher.should_run?(reload(task))
      assert reload(task).phase_assignees["execution"]["assignee_id"]
      assert reload(task).phase_assignees["review"]["assignee_id"]
      assert [_stage] = Repo.all(from(s in Stage, where: s.plan_id == ^plan.id))

      test_pid = self()
      handler = "auto-approved-stack-#{u()}"

      :ok =
        :telemetry.attach(
          handler,
          [:platform, :plan, :auto_approved],
          fn _e, _m, meta, _cfg -> send(test_pid, {:auto_approved, meta}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert %{scanned: 1, settled: 1, observed: 0} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      # THE PROOF OF WHICH ARM: `via: :stack`, not merely "something fired".
      assert_receive {:auto_approved, %{via: :stack, plan_id: fired_plan_id}}
      assert fired_plan_id == plan.id

      settled = reload(plan)
      assert settled.status == "approved"
      assert settled.auto_approved_at

      # The (a) invariants hold for the stack arm too — a stack member must
      # not be able to launder an unreviewed plan either.
      assert settled.architecture_verdict["state"] == "expired"
      assert settled.architecture_verdict["source"] == "deadline"
      assert is_binary(settled.architecture_verdict["resolved_at"])
      assert Tasks.planning_gate_failed?(reload(task))
      assert [%{step: "architecture", detail: d}] = Tasks.failed_planning_steps(reload(task))
      assert d =~ "expired"
    end

    test "POSITIVE CONTROL: a stack whose auto_accept_plan is FALSE does not settle its member",
         %{project: project} do
      # Pairs the assertion above: `via: :stack` firing must depend on the
      # flag, not on stack membership.
      slug = "gate-settle-off-#{u()}"

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Gate settle off #{slug}",
          base_branch: "main",
          rollup_branch: Stacks.rollup_branch_name(slug),
          auto_accept_plan: false
        })

      {task, plan} = task_fixture(project, auto_approve_plan: false)
      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      gated = open_gate!(task, plan)
      _ = expire_deadline!(gated, 3600)

      assert Repo.preload(reload(task), :stack).stack.auto_accept_plan == false

      assert %{scanned: 1, settled: 1, observed: 0} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      settled = reload(plan)

      # The GATE still settles — that half is unconditional.
      assert settled.architecture_verdict["state"] == "expired"
      # The approval does not, because neither flag is armed.
      assert settled.status == "pending_review"
      assert is_nil(settled.auto_approved_at)
    end
  end

  # ── (c) the non-armed control, and the sponsor row it also fixes ──────

  describe "non-armed control and the sponsor plan-review notification" do
    test "an unarmed plan stays pending_review AND finally notifies its sponsor", %{
      project: project
    } do
      # THE SECOND BUG THIS SWEEP FIXES FOR FREE. Before stage 1, a gated
      # plan whose gate expired with no router never reached
      # `maybe_emit_plan_review_inbox/1` at all, because that lives in the
      # deferred `settle_plan_submission/1` tail nothing ever ran. So its
      # sponsor was never told a plan was waiting on them.
      #
      # `plan_review_inbox_emit?/4` requires: settled plan `pending_review`,
      # `auto_approve_plan == false`, a binary `sponsor_user_id`, task not
      # terminal, and the sponsor is not the planner. The fixture satisfies
      # all five — the planner is a distinct random user id.
      sponsor = sponsor_fixture()

      {unarmed_task, unarmed_plan} =
        task_fixture(project, auto_approve_plan: false, sponsor_user_id: sponsor.id)

      unarmed_gated = open_gate!(unarmed_task, unarmed_plan)
      _ = expire_deadline!(unarmed_gated, 3600)

      # PAIRED, per the anti-vacuity rule. The armed task in the same sweep
      # must NOT produce a row (it auto-approves, so there is no human gate
      # to notify about) — an assertion that is only meaningful because the
      # unarmed task in the same tick DOES produce one.
      armed_sponsor = sponsor_fixture()

      {armed_task, armed_plan} =
        armed_expired!(project, sponsor_user_id: armed_sponsor.id)

      assert_armed!(armed_task, armed_plan)
      assert reload(unarmed_task).auto_approve_plan == false
      assert reload(unarmed_task).sponsor_user_id == sponsor.id

      # `create_task` with a sponsor also emits `task_sponsor_assigned`, so
      # scope every count to the plan-review kind.
      assert plan_review_rows(sponsor.id) == []
      assert plan_review_rows(armed_sponsor.id) == []

      assert %{scanned: 2, settled: 2, observed: 0} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      unarmed_settled = reload(unarmed_plan)
      assert unarmed_settled.status == "pending_review"
      assert is_nil(unarmed_settled.auto_approved_at)
      assert unarmed_settled.architecture_verdict["state"] == "expired"
      assert unarmed_settled.architecture_verdict["source"] == "deadline"
      assert Tasks.planning_gate_failed?(reload(unarmed_task))

      assert [row] = plan_review_rows(sponsor.id)
      assert row.source_type == "task"
      assert row.source_id == unarmed_task.id
      assert row.url == "/tasks/#{unarmed_task.id}"

      # The armed one approved, so its sponsor is correctly NOT summoned.
      assert reload(armed_plan).status == "approved"
      assert plan_review_rows(armed_sponsor.id) == []
    end
  end

  # ── (d) idempotence ───────────────────────────────────────────────────

  describe "idempotence on a recurring tick" do
    test "a second pass settles nothing, re-touches nothing, and duplicates no inbox row", %{
      project: project
    } do
      # A sweep on a 5-minute tick that is not idempotent emits a duplicate
      # sponsor notification forever. `record_architecture_verdict/3`'s
      # one-shot guarded UPDATE is the only thing standing between this
      # design and that outcome.
      sponsor = sponsor_fixture()

      {armed_task, armed_plan} = armed_expired!(project)

      {unarmed_task, unarmed_plan} =
        task_fixture(project, auto_approve_plan: false, sponsor_user_id: sponsor.id)

      unarmed_gated = open_gate!(unarmed_task, unarmed_plan)
      _ = expire_deadline!(unarmed_gated, 3600)

      assert_armed!(armed_task, armed_plan)

      assert %{scanned: 2, settled: 2, observed: 0} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      first_armed = reload(armed_plan)
      first_unarmed = reload(unarmed_plan)
      assert first_armed.auto_approved_at
      # The count going 0 -> 1 on the first pass is what makes "still 1"
      # below an assertion rather than a no-op.
      assert [first_row] = plan_review_rows(sponsor.id)

      # Second pass: the verdicts are terminal now, so the candidate query
      # (which matches `->>'state' = 'pending'`) sees nothing at all.
      assert %{scanned: 0, settled: 0, observed: 0} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      second_armed = reload(armed_plan)
      second_unarmed = reload(unarmed_plan)

      assert second_armed.auto_approved_at == first_armed.auto_approved_at
      assert second_armed.architecture_verdict == first_armed.architecture_verdict
      assert second_unarmed.architecture_verdict == first_unarmed.architecture_verdict
      assert second_unarmed.status == "pending_review"

      assert [^first_row] = plan_review_rows(sponsor.id)

      assert [_only_one] = Repo.all(from(p in Plan, where: p.task_id == ^armed_task.id))
      assert [_also_one] = Repo.all(from(p in Plan, where: p.task_id == ^unarmed_task.id))
    end
  end

  # ── (e) exclusions, each paired with a candidate that DOES settle ─────

  describe "exclusions" do
    test "a FUTURE deadline is observed while an overdue sibling in the same tick settles", %{
      project: project
    } do
      # `open_architecture_gate/2` stamps `now + architecture_gate_timeout_ms`,
      # so omitting `expire_deadline!/2` leaves a genuinely open gate.
      {future_task, future_plan} = task_fixture(project, auto_approve_plan: true)
      _ = open_gate!(future_task, future_plan)
      assert_armed!(future_task, future_plan)
      assert {:open, _} = Tasks.architecture_gate(future_plan.id)

      {overdue_task, overdue_plan} = armed_expired!(project)
      assert_armed!(overdue_task, overdue_plan)

      assert %{scanned: 2, settled: 1, observed: 1} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      assert reload(future_plan).status == "pending_review"
      assert reload(future_plan).architecture_verdict["state"] == "pending"
      assert reload(overdue_plan).status == "approved"
    end

    test "a gate overdue by 8 days is observed, not settled, while a 1-hour sibling settles", %{
      project: project
    } do
      # THE DEPLOY-DAY GUARD. Without it, the first production tick after
      # this ships settles every historical overdue gate at once and can
      # auto-approve plans abandoned weeks ago.
      {ancient_task, ancient_plan} = armed_expired!(project, overdue_seconds: 8 * 24 * 3600)
      assert_armed!(ancient_task, ancient_plan)

      {recent_task, recent_plan} = armed_expired!(project)
      assert_armed!(recent_task, recent_plan)

      assert %{scanned: 2, settled: 1, observed: 1} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      assert reload(ancient_plan).status == "pending_review"
      assert reload(ancient_plan).architecture_verdict["state"] == "pending"
      assert is_nil(reload(ancient_plan).auto_approved_at)
      refute Tasks.planning_gate_failed?(reload(ancient_task))

      assert reload(recent_plan).status == "approved"
    end

    test "draft and superseded plans carrying a stale pending verdict are not candidates", %{
      project: project
    } do
      # `p.status == "pending_review"` is load-bearing. Settling a superseded
      # version would drive `approve_plan/3` on a non-`pending_review` plan,
      # get `{:error, :invalid_transition}`, and log a `maybe_auto_approve`
      # warning on every tick forever.
      {_draft_task, draft_plan} = armed_expired!(project)

      {1, _} =
        Plan |> where([p], p.id == ^draft_plan.id) |> Repo.update_all(set: [status: "draft"])

      {superseded_task, superseded_plan} = armed_expired!(project)
      {live_task, live_plan} = armed_expired!(project)
      assert_armed!(live_task, live_plan)

      # Model the real supersession shape: v1 rejected, pointing at v2.
      {1, _} =
        Plan
        |> where([p], p.id == ^superseded_plan.id)
        |> Repo.update_all(set: [status: "rejected", superseded_by_plan_id: live_plan.id])

      assert reload(superseded_plan).superseded_by_plan_id == live_plan.id
      assert reload(superseded_task).id

      assert %{scanned: 1, settled: 1, observed: 0} =
               TaskRouterWatcher.sweep_expired_architecture_gates()

      # The one that DOES settle proves the sweep was capable of speaking.
      assert reload(live_plan).status == "approved"
      assert reload(live_plan).auto_approved_at

      assert reload(draft_plan).status == "draft"
      assert reload(draft_plan).architecture_verdict["state"] == "pending"
      assert reload(superseded_plan).status == "rejected"
      assert reload(superseded_plan).architecture_verdict["state"] == "pending"
    end
  end
end
