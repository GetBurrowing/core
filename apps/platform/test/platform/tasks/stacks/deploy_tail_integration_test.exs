defmodule Platform.Tasks.Stacks.DeployTailIntegrationTest do
  @moduledoc """
  Integration coverage for the deploy-TAIL lifecycle fix (task 019f8ae6):
  stack members must walk themselves through `in_review -> deploying -> done`
  on the triggering events, with no manual reconcile and no stale
  re-dispatch.

  Codifies the RBAC-stack incident (2026-07-22) and asserts the regression is
  gone, mirroring `commencement_gate_integration_test.exs`'s discipline of an
  integration test that had encoded the bug and was flipped to assert the
  corrected behavior. Drives the full tail through the public seams:

    * `PlanEngine.evaluate_validation/2` — pass review-stage validations;
      the last pass fires `Stacks.advance_member_to_deploying/1` on the event.
    * `Stacks.advance_member_to_deploying/1` — the `in_review -> deploying`
      promote helper.
    * `StackDeployer.handle_rollup_pr_merged/2` — simulate the rollup PR
      `pull_request.closed`/merged webhook; sweeps `no_op_wait_for_rollup`
      members `deploying -> done`.

  `async: false` because members share the global board topic and the tests
  drive `recompute_stack_status/1` (which reads shared deployer config).
  """
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Stacks, StackDeployer, Task}

  describe "in_review -> deploying on the last e2e pass (direction 2)" do
    test "member stays in_review until the LAST validation passes, then flips to deploying" do
      {_stack, member, [v1, v2]} = review_member(validations: 2)

      assert Tasks.get_task_record(member.id).status == "in_review"

      # Pass all-but-last: the member stays in_review (gate still closed).
      {:ok, _} = PlanEngine.evaluate_validation(v1.id, %{status: "passed"})
      assert Tasks.get_task_record(member.id).status == "in_review"

      # Pass the final one: the SAME evaluate_validation call path advances
      # the member in_review -> deploying — no 15-minute reconcile sweep.
      {:ok, _} = PlanEngine.evaluate_validation(v2.id, %{status: "passed"})
      assert Tasks.get_task_record(member.id).status == "deploying"
    end
  end

  describe "deploying -> done on rollup merge (direction 1)" do
    test "handle_rollup_pr_merged sweeps no_op members to done and is idempotent on replay" do
      {stack, [m1, m2]} = no_op_stack(2)

      m1 = force_status(m1, "deploying")
      m2 = force_status(m2, "deploying")
      stack = seed_rollup_pr(stack)

      # First delivery: both members swept deploying -> done, stack done.
      assert {:ok, done_stack} = StackDeployer.handle_rollup_pr_merged(stack, "c0ffee01")
      assert done_stack.status == "done"
      assert Enum.all?(Stacks.members(stack), &(&1.status == "done"))
      assert Tasks.get_task_record(m1.id).status == "done"
      assert Tasks.get_task_record(m2.id).status == "done"

      # Replay (webhook re-delivery): returns without error, all still done.
      assert {:ok, _} = StackDeployer.handle_rollup_pr_merged(Repo.reload!(stack), "c0ffee01")
      assert Enum.all?(Stacks.members(stack), &(&1.status == "done"))
    end
  end

  describe "full tail — the incident regression is gone" do
    test "3 members pass all validations, rollup merges, every member + stack ends done" do
      {stack, members} = review_stack(3, validations: 1)

      # Each member passes its (single) review validation → self-advances
      # in_review -> deploying via the event hook.
      Enum.each(members, fn %{member: member, validations: [v]} ->
        {:ok, _} = PlanEngine.evaluate_validation(v.id, %{status: "passed"})
        assert Tasks.get_task_record(member.id).status == "deploying"
      end)

      stack = seed_rollup_pr(stack)

      # Rollup PR merges once.
      assert {:ok, _} = StackDeployer.handle_rollup_pr_merged(stack, "c1ea4001")

      # REGRESSION GUARD (RBAC stack deadlock, 2026-07-22): no member left at
      # in_review or deploying — every member AND the stack end at done, with
      # no manual reconcile.
      assert Enum.all?(Stacks.members(stack), &(&1.status == "done"))
      assert Repo.reload!(stack).status == "done"
    end
  end

  describe "mixed-state stack — partial progress is respected" do
    test "pending member stays, deploying member completes, done member is undisturbed" do
      {stack, [dm, pm, qm]} = no_op_stack(3)

      # D: already done.
      dm = force_status(dm, "done")

      # P: in_review with one still-pending validation (the rest passed).
      pm = to_review_member(pm, validations: 2)
      [pv1, pv2] = plan_validations(pm)
      {:ok, _} = PlanEngine.evaluate_validation(pv1.id, %{status: "passed"})
      # Only ONE of P's validations passes — it must NOT advance.
      _ = pv2

      # Q: a no_op_wait_for_rollup member already at deploying.
      qm = force_status(qm, "deploying")

      stack = seed_rollup_pr(stack)
      assert {:ok, _} = StackDeployer.handle_rollup_pr_merged(stack, "beef0001")

      # P stays in_review — a member with any still-pending validation is not
      # prematurely advanced.
      assert Tasks.get_task_record(pm.id).status == "in_review"

      # Q transitioned deploying -> done on the rollup merge.
      assert Tasks.get_task_record(qm.id).status == "done"

      # D stays done and advance_member_to_deploying/1 against it is a clean
      # :noop (not at in_review) with no side effects.
      assert Tasks.get_task_record(dm.id).status == "done"
      assert :noop = Stacks.advance_member_to_deploying(Tasks.get_task_record(dm.id))
      assert Tasks.get_task_record(dm.id).status == "done"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Build a stack (live rollup_branch → members resolve to
  # no_op_wait_for_rollup) with `count` bare members. Returns `{stack, members}`.
  defp no_op_stack(count) when count > 0 do
    {stack, _project} = new_stack()

    members =
      Enum.map(1..count, fn i ->
        {:ok, task} =
          Tasks.create_task(%{
            project_id: stack.project_id,
            title: "Tail member #{i} " <> short_id()
          })

        {:ok, attached} = Stacks.add_task(stack, task)
        attached
      end)

    {stack, members}
  end

  # Build a stack of `count` review-ready members. Each is at in_review with a
  # merge stamp, deploy_target, and an approved plan whose single review stage
  # carries `validations` pending validations. Returns
  # `{stack, [%{member: t, validations: [v, ...]}, ...]}`.
  defp review_stack(count, opts) when count > 0 do
    {stack, _project} = new_stack()

    members =
      Enum.map(1..count, fn i ->
        {:ok, task} =
          Tasks.create_task(%{
            project_id: stack.project_id,
            title: "Review member #{i} " <> short_id()
          })

        {:ok, attached} = Stacks.add_task(stack, task)
        member = to_review_member(attached, opts)
        %{member: member, validations: plan_validations(member)}
      end)

    {stack, members}
  end

  # A single review-ready member inside its own fresh stack. Returns
  # `{stack, member, validations}`.
  defp review_member(opts) do
    {stack, [%{member: member, validations: validations}]} = review_stack(1, opts)
    {stack, member, validations}
  end

  # Drive an already-attached stack member into the review-ready shape: status
  # in_review, deploy_target set, merged_into_rollup_at stamped, and an
  # approved plan with one running review stage carrying `validations` pending
  # validations.
  defp to_review_member(%Task{} = attached, opts) do
    count = Keyword.get(opts, :validations, 1)

    {:ok, member} =
      Tasks.update_task(attached, %{
        status: "in_review",
        deploy_target: "production",
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => hex_sha(),
            "at" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: member.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Task-level review",
        status: "running"
      })

    Enum.each(1..count, fn i ->
      {:ok, _} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "test_pass",
          status: "pending",
          title: "check #{i}"
        })
    end)

    Tasks.get_task_record(member.id)
  end

  defp plan_validations(%Task{id: task_id}) do
    %{stages: stages} = Tasks.current_plan(task_id)

    stages
    |> Enum.flat_map(& &1.validations)
    |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})
  end

  defp new_stack do
    {:ok, project} = Tasks.create_project(%{name: "Deploy Tail Project " <> short_id()})
    slug = "deploy-tail-" <> short_id()

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Deploy Tail Stack",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    {stack, project}
  end

  # Populate the stack's metadata["rollup_pr"] in the shape
  # StackDeployer.handle_rollup_pr_merged/2 expects (a `number`; `merged_at`
  # is stamped by the handler on first delivery).
  defp seed_rollup_pr(stack) do
    stack = Repo.reload!(stack)
    meta = stack.metadata || %{}

    {:ok, updated} =
      Stacks.update_stack(stack, %{
        status: "deploying",
        metadata: Map.put(meta, "rollup_pr", %{"number" => 137})
      })

    updated
  end

  defp force_status(%Task{} = task, status) do
    task
    |> Task.changeset(%{status: status})
    |> Repo.update!()
  end

  # Readable placeholders (e.g. "member1") fail the metadata changeset
  # silently — a real hex sha is required.
  defp hex_sha, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp short_id, do: Ecto.UUID.generate() |> String.slice(0, 8)
end
