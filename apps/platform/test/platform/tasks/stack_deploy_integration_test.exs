defmodule Platform.Tasks.StackDeployIntegrationTest do
  @moduledoc """
  Stack v2 stage 5 end-to-end coverage.

  Exercises the whole "seed 3-member stack → drive validations → dispatch
  deploy → simulate rollup PR merge → verify terminal state" pipeline
  through the real webhook controller. Complements the unit-level tests
  in `stacks_test.exs` and `stack_deployer_test.exs` by asserting the
  seams compose correctly across module boundaries.

  Also carries the stage-5 regression guard: a NON-stacked task still
  gets its per-task `pr_merge` deploy stage injected — the stack-scoped
  atomic-ship guard (`Tasks.dispatch_deploy_for_task/1`) does NOT
  over-fire and clobber the solo-task path.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, PlanEngine, Stacks, Stage}

  @github_webhook_path "/api/webhooks/github"

  # ── FakeRunner: in-memory git_runner behaviour ────────────────────────

  defmodule FakeRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    use Agent

    def start_link(_opts \\ []) do
      initial = %{
        ensure_calls: [],
        merge_calls: [],
        pr_calls: [],
        delete_calls: [],
        # Gap 1 (task 019f921d) integration knob: number of leading
        # `ensure_rollup_branch` calls to FAIL, simulating a lost/dropped
        # async create at stack-start. The merge-time ensure that follows
        # must self-heal the missing branch.
        fail_ensures: 0
      }

      Agent.start_link(fn -> initial end, name: __MODULE__)
    end

    def stop, do: Agent.stop(__MODULE__)

    # Simulate the initial async rollup-branch create being lost: the next
    # `n` ensure calls return {:error, ...}; subsequent calls succeed.
    def fail_next_ensures(n) when is_integer(n) and n >= 0 do
      Agent.update(__MODULE__, fn s -> %{s | fail_ensures: n} end)
    end

    def ensure_calls, do: Agent.get(__MODULE__, & &1.ensure_calls) |> Enum.reverse()
    def merge_calls, do: Agent.get(__MODULE__, & &1.merge_calls) |> Enum.reverse()
    def pr_calls, do: Agent.get(__MODULE__, & &1.pr_calls) |> Enum.reverse()
    def delete_calls, do: Agent.get(__MODULE__, & &1.delete_calls) |> Enum.reverse()

    @impl true
    def ensure_rollup_branch(args) do
      Agent.get_and_update(__MODULE__, fn s ->
        s = %{s | ensure_calls: [args | s.ensure_calls]}

        if s.fail_ensures > 0 do
          {{:error, :simulated_lost_create}, %{s | fail_ensures: s.fail_ensures - 1}}
        else
          {{:ok, %{status: :created, base_sha: "base00000"}}, s}
        end
      end)
    end

    @impl true
    def merge_member_into_rollup(args) do
      Agent.update(__MODULE__, fn s -> %{s | merge_calls: [args | s.merge_calls]} end)
      # Hex-shaped sha so the `merged_into_rollup_at` map-shape validator
      # (Bug #3) accepts the stamp stamp_merged writes.
      {:ok,
       %{
         status: :merged,
         merge_sha: "deadbe" <> Integer.to_string(System.unique_integer([:positive]))
       }}
    end

    @impl true
    def open_stack_pr(args) do
      Agent.update(__MODULE__, fn s -> %{s | pr_calls: [args | s.pr_calls]} end)

      {:ok,
       %{
         number: 4242,
         url: "https://github.com/test/repo/pull/4242"
       }}
    end

    @impl true
    def diff_stat(_args), do: {:ok, ""}

    @impl true
    def revert_member_merge(_args),
      do: {:ok, %{status: :reverted, revert_sha: "revert0000"}}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    @impl true
    def delete_rollup_branch(args) do
      Agent.update(__MODULE__, fn s -> %{s | delete_calls: [args | s.delete_calls]} end)
      {:ok, :deleted}
    end

    # Bug #2 (task 019f708f): default to reachable so the integration
    # test's ff-only merges promote through without needing per-SHA
    # reachability seeding.
    @impl true
    def sha_reachable?(_args), do: {:ok, true}
  end

  setup do
    prev = Application.get_env(:platform, :stack_deployer, [])
    {:ok, _} = FakeRunner.start_link()

    Application.put_env(:platform, :stack_deployer,
      git_runner: FakeRunner,
      async: false
    )

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)

      try do
        FakeRunner.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  # ── Happy path: 3-member stack ships as ONE rollup PR ─────────────────

  describe "single-PR happy path" do
    test "3-member stack: validations pass → dispatch fires once → rollup merges → all done + cleanup",
         %{conn: conn} do
      handler_id = "int-happy-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:platform, :stacks, :deploy, :dispatched],
            [:platform, :stacks, :deploy, :pr_merged],
            [:platform, :tasks, :deploy_dispatch, :rejected_stack_member]
          ],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{stack: stack, members: members, rollup_branch: rollup_branch} =
        build_stack_scenario!("single-pr-happy", 3)

      # ── Drive each member's plan through validations ────────────────
      #
      # Each member's plan carries a single non-deploy validation
      # (test_pass). Pass them all — the LAST evaluate_validation
      # should trigger PlanEngine.maybe_inject_deploy_or_complete/2 →
      # Stacks.dispatch_stack_deploy/1 → transition to "deploying" +
      # dispatched telemetry.
      for %{validation: v} <- members do
        {:ok, _} =
          PlanEngine.evaluate_validation(v.id, %{
            status: "passed",
            evaluated_by: "test",
            evidence: %{"result" => "ok"}
          })
      end

      # ── Assert exactly ONE :dispatched telemetry event ──────────────
      assert_received {:telemetry, [:platform, :stacks, :deploy, :dispatched], _,
                       %{stack_id: stack_id}}

      assert stack_id == stack.id
      refute_received {:telemetry, [:platform, :stacks, :deploy, :dispatched], _, _}

      # ── Assert NO per-member `pr_merge` dispatch was rejected here ──
      # (dispatch_deploy_for_task/1 blocks stack members up-front, so
      # the rejection telemetry fires from an INJECTION attempt. In
      # this scenario the guard is at the plan-engine seam BEFORE the
      # would-be injection, so :rejected_stack_member fires N times
      # (once per member's plan completion). That's the invariant we
      # want — every member's per-task path was correctly refused.)
      for _ <- members do
        assert_received {:telemetry,
                         [:platform, :tasks, :deploy_dispatch, :rejected_stack_member], _, _}
      end

      # ── The dispatch should have queued exactly ONE open_stack_pr ──
      # under the FakeRunner (async: false, so synchronous by the time
      # evaluate_validation/2 returns).
      assert length(FakeRunner.pr_calls()) == 1

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.status == "deploying"
      assert reloaded.metadata["rollup_pr"]["number"] == 4242

      # ── Simulate the GitHub `pull_request.closed` webhook ───────────
      payload = rollup_merged_payload(rollup_branch)
      conn = signed_github_post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      # ── Stack now at done + members at done + branch cleanup ────────
      done_stack = Stacks.get_stack(stack.id)
      assert done_stack.status == "done"
      assert is_binary(done_stack.metadata["rollup_pr"]["merged_at"])

      for %{task: task} <- members do
        assert Tasks.get_task_record(task.id).status == "done"
      end

      # ── Rollup-branch delete was invoked exactly once ───────────────
      assert length(FakeRunner.delete_calls()) == 1
      [delete_call] = FakeRunner.delete_calls()
      assert delete_call.rollup_branch == rollup_branch
      assert delete_call.stack_id == stack.id

      # ── :pr_merged telemetry fires exactly once with correct shape ──
      assert_received {:telemetry, [:platform, :stacks, :deploy, :pr_merged],
                       %{count: 1, duration_ms_in_deploying: duration_ms}, pr_merged_meta}

      assert pr_merged_meta.stack_id == stack.id
      assert pr_merged_meta.member_count == 3
      assert is_binary(pr_merged_meta.merge_commit_sha)
      assert pr_merged_meta.rollup_branch == rollup_branch
      # Duration was computed off the rollup_pr.opened_at we stamped
      # in finalize_pr_opened; should be a non-negative integer ms.
      assert is_integer(duration_ms) and duration_ms >= 0

      refute_received {:telemetry, [:platform, :stacks, :deploy, :pr_merged], _, _}
    end
  end

  # ── Gap composition (task 019f921d): forming → done, zero hand-recon ────
  #
  # The guard that proves the FOUR fixes work TOGETHER — the thing missing
  # when the Inbox stack needed hand-reconciliation at every step. A
  # synthetic 3-member stack (M1 root; M2 dep M1; M3 dep M2) walks:
  #   forming → commence → members merge (branch self-healed) → members
  #   auto-advance in_review→deploying off their own stamp → rollup PR opens
  #   (recognizing a done+bare-string member) → rollup PR merges → all done
  # with NO manual stage_complete / status poke / rpc reconciliation.

  describe "four-gap composition: synthetic stack, full lifecycle, zero hand-reconciliation" do
    test "forming → members merged → auto-advance → PR opens (mixed shapes) → merged → all done",
         %{conn: conn} do
      # Gap 1: the initial async rollup-branch create is LOST — the first
      # ensure (fired by commence's handle_stack_transition) fails; the
      # merge-time ensure must self-heal it.
      FakeRunner.fail_next_ensures(1)

      %{stack: stack, members: [m1, m2, m3], rollup_branch: rollup_branch} =
        build_forming_stack!("gap-compose", 3)

      # Members start at backlog on a `forming` stack.
      assert Stacks.get_stack(stack.id).status == "forming"

      # ── Gap 3: commence the forming-but-ready stack (no manual flip) ──
      assert {:ok, %{stack: commenced}} = Stacks.commence_if_ready(stack)
      assert commenced.status == "in_progress"
      assert Tasks.get_task_record(m1.task.id).status == "in_progress"
      assert Tasks.get_task_record(m2.task.id).status == "stack_pending"
      assert Tasks.get_task_record(m3.task.id).status == "stack_pending"

      # The initial ensure (from the commence transition) was attempted and
      # FAILED — the rollup branch was NOT created up front.
      assert length(FakeRunner.ensure_calls()) == 1

      # ── Gaps 1+2: drive M1 to review-ready; passing its LAST validation
      # merges it (ensure self-heals the branch) and auto-advances it
      # in_review → deploying off its own stamp — no extra validation event.
      drive_member_to_merged!(m1)

      m1_rec = Tasks.get_task_record(m1.task.id)
      assert m1_rec.status == "deploying", "M1 should auto-advance to deploying off its stamp"
      # Stamp is the canonical map shape.
      assert is_map(m1_rec.metadata["merged_into_rollup_at"])
      assert is_binary(m1_rec.metadata["merged_into_rollup_at"]["sha"])

      # Gap 1 self-heal: a SUCCESSFUL ensure ran at merge time (call #2)
      # after the failed initial create, and the merge landed.
      assert length(FakeRunner.ensure_calls()) >= 2
      assert Enum.any?(FakeRunner.merge_calls(), &(&1.member_task_id == m1.task.id))

      # M1's merge stamp unblocked the dependent M2 → in_progress (no poke).
      assert Tasks.get_task_record(m2.task.id).status == "in_progress"

      # ── Drive M2 the same way; it unblocks M3. ──
      drive_member_to_merged!(m2)
      assert Tasks.get_task_record(m2.task.id).status == "deploying"
      assert Tasks.get_task_record(m3.task.id).status == "in_progress"

      # ── Gap 4 setup: leave M3 in the exact stranded shape from the
      # incident — `done` with a BARE-STRING merged_into_rollup_at stamp
      # (the manual-reconciliation shape the OLD deploy gate rejected). We
      # bypass the map-shape validator to reproduce that legacy shape.
      m3.task
      |> Ecto.Changeset.change(%{
        status: "done",
        metadata:
          Map.put(
            m3.task.metadata || %{},
            "merged_into_rollup_at",
            DateTime.utc_now() |> DateTime.to_iso8601()
          )
      })
      |> Repo.update!()

      # ── Gap 4 + self-heal: simulate the fire-and-forget PR-open being
      # DROPPED — flip the stack to `deploying` with NO rollup_pr (as
      # dispatch_stack_deploy would, minus the open that never landed).
      {:ok, _} = Stacks.update_stack(Stacks.get_stack(stack.id), %{status: "deploying"})
      assert is_nil(Stacks.get_stack(stack.id).metadata["rollup_pr"])

      pr_calls_before = length(FakeRunner.pr_calls())

      # The durable reconcile re-fires maybe_open_stack_pr and the gate now
      # recognizes ALL members ready — M1/M2 deploying+map AND M3
      # done+bare-string — so the PR opens on retry (no :not_ready).
      assert Stacks.reconcile_deploying_stacks() == 1
      assert length(FakeRunner.pr_calls()) == pr_calls_before + 1

      reopened = Stacks.get_stack(stack.id)
      assert reopened.status == "deploying"
      assert reopened.metadata["rollup_pr"]["number"] == 4242

      # A second reconcile is idempotent — no duplicate open.
      assert Stacks.reconcile_deploying_stacks() == 0
      assert length(FakeRunner.pr_calls()) == pr_calls_before + 1

      # ── Terminal: the rollup PR merges (GitHub webhook) → stack done +
      # every member done + rollup branch cleaned up. Zero hand-recon.
      payload = rollup_merged_payload(rollup_branch)
      conn = signed_github_post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      assert Stacks.get_stack(stack.id).status == "done"
      assert Tasks.get_task_record(m1.task.id).status == "done"
      assert Tasks.get_task_record(m2.task.id).status == "done"
      assert Tasks.get_task_record(m3.task.id).status == "done"
    end
  end

  # ── Regression: non-stacked task still gets its per-task deploy stage ─

  describe "non-stacked task regression guard" do
    test "solo task's plan-complete injects the per-task `pr_merge` deploy stage" do
      handler_id = "int-regression-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:platform, :stacks, :deploy, :dispatched],
            [:platform, :stacks, :deploy, :pr_merged],
            [:platform, :tasks, :deploy_dispatch, :rejected_stack_member]
          ],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, project} =
        Tasks.create_project(%{
          name: "Regression Solo #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/regression-repo",
          deploy_config: %{"default_strategy" => %{"type" => "pr_merge"}}
        })

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Solo regression"})

      {:ok, task} =
        Tasks.update_task(task, %{
          status: "in_review",
          branch_name: "task/#{task.id}"
        })

      # Approved plan with a single validation stage + a passing test_pass
      # validation. When we flip the validation to passed, plan-complete
      # runs and `maybe_inject_deploy_or_complete/2` should inject a
      # `Deploy: PR merge` stage since this task is NOT in a stack.
      {:ok, plan} =
        Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Build",
          description: "Build stage",
          status: "running"
        })

      {:ok, validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      assert {:ok, _} =
               PlanEngine.evaluate_validation(validation.id, %{
                 status: "passed",
                 evaluated_by: "test",
                 evidence: %{"result" => "ok"}
               })

      # Deploy stage was injected — the plan now carries a stage whose
      # name starts with "Deploy: ".
      plan =
        Plan
        |> Repo.get!(plan.id)
        |> Repo.preload(stages: from(s in Stage, order_by: s.position))

      deploy_stage = Enum.find(plan.stages, &String.starts_with?(&1.name, "Deploy: "))
      assert deploy_stage != nil, "expected Deploy: stage to be injected on solo task"

      # NO stack telemetry should have fired on this per-task path.
      refute_received {:telemetry, [:platform, :stacks, :deploy, :dispatched], _, _}
      refute_received {:telemetry, [:platform, :stacks, :deploy, :pr_merged], _, _}

      # The rejected_stack_member telemetry MUST NOT fire because this
      # task has no `stack_id`.
      refute_received {:telemetry, [:platform, :tasks, :deploy_dispatch, :rejected_stack_member],
                       _, _}
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  # Seed a project + stack + N members. Each member is at `in_review`
  # with an approved plan, a running stage, and a single pending
  # `test_pass` validation. `metadata["merged_into_rollup_at"]` is
  # pre-stamped so the maybe_open_stack_pr gate passes (in the real
  # flow, per-member merges stamp this — we short-circuit to keep the
  # test focused on the deploy-dispatch + webhook seams). Also stamps
  # a rollup_pr.opened_at value ahead of time by pre-running the
  # dispatch mock; NO — we let the actual dispatch path stamp
  # rollup_pr since that's what we're exercising.
  defp build_stack_scenario!(slug, member_count) when member_count > 0 do
    rollup_branch = "stack/#{slug}"

    {:ok, project} =
      Tasks.create_project(%{
        name: "Stack v2 Integration #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/stack-integration-repo"
      })

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stack #{slug}",
        base_branch: "main",
        rollup_branch: rollup_branch,
        status: "in_progress"
      })

    members =
      for position <- 1..member_count do
        {:ok, task} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Member #{position}"
          })

        {:ok, task} =
          Tasks.update_task(task, %{
            stack_id: stack.id,
            stack_position: position,
            status: "in_review",
            metadata: %{
              "merged_into_rollup_at" => %{
                # Bug #3 (task 019f708f) shape validator requires hex-only,
                # >= 7 chars. Pad the position into a valid hex-shaped SHA.
                "sha" => "abcdef" <> String.pad_leading(Integer.to_string(position), 2, "0"),
                "at" => DateTime.utc_now() |> DateTime.to_iso8601()
              }
            }
          })

        {:ok, plan} =
          Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

        {:ok, stage} =
          Tasks.create_stage(%{
            plan_id: plan.id,
            position: 1,
            name: "Build",
            description: "Build stage",
            status: "running"
          })

        {:ok, validation} =
          Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

        %{task: task, plan: plan, stage: stage, validation: validation}
      end

    %{project: project, stack: stack, rollup_branch: rollup_branch, members: members}
  end

  # Gap-composition fixture: a `forming` stack whose N members form a
  # dependency chain (M2 dep M1, M3 dep M2), each at `backlog` with an
  # approved plan, a single running review stage, a pending `test_pass`
  # validation, and `deploy_target` set (so the in_review→deploying advance
  # resolves the no_op_wait_for_rollup strategy). NOTHING is pre-stamped —
  # the merge stamps land through the real merge path.
  defp build_forming_stack!(slug, member_count) when member_count > 0 do
    rollup_branch = "stack/#{slug}"

    {:ok, project} =
      Tasks.create_project(%{
        name: "Gap Compose #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/gap-compose-repo"
      })

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stack #{slug}",
        base_branch: "main",
        rollup_branch: rollup_branch
      })

    {members, _prev} =
      Enum.reduce(1..member_count, {[], nil}, fn position, {acc, prev} ->
        deps = if prev, do: [%{"task_id" => prev.id, "kind" => "blocks"}], else: []

        {:ok, task} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Member #{position}",
            dependencies: deps
          })

        {:ok, task} =
          Tasks.update_task(task, %{
            stack_id: stack.id,
            stack_position: position,
            deploy_target: "production"
          })

        {:ok, plan} =
          Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

        {:ok, stage} =
          Tasks.create_stage(%{
            plan_id: plan.id,
            position: 1,
            name: "Task-level review",
            status: "running"
          })

        {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

        member = %{task: task, plan: plan, stage: stage, validation: validation}
        {[member | acc], task}
      end)

    %{
      project: project,
      stack: Stacks.get_stack(stack.id),
      rollup_branch: rollup_branch,
      members: Enum.reverse(members)
    }
  end

  # Drive a commenced member (at in_progress) to a merged+advanced state via
  # the real engine path only: move it to in_review (its executor finishing
  # execution), then pass its LAST review validation. That single pass
  # re-fires the rollup merge (which ensures the branch, Gap 1) and advances
  # the member in_review→deploying off its own fresh stamp (Gap 2) — no
  # manual stage_complete, no status poke.
  defp drive_member_to_merged!(%{task: task, validation: validation}) do
    task = Tasks.get_task_record(task.id)
    {:ok, _} = Tasks.transition_task(task, "in_review")

    {:ok, _} =
      PlanEngine.evaluate_validation(validation.id, %{
        status: "passed",
        evaluated_by: "test",
        evidence: %{"result" => "ok"}
      })

    :ok
  end

  defp rollup_merged_payload(rollup_branch) do
    %{
      "action" => "closed",
      "pull_request" => %{
        "merged" => true,
        "title" => "chore: stack rollup",
        "number" => 4242,
        "html_url" => "https://github.com/test/stack-integration-repo/pull/4242",
        "merge_commit_sha" => "rollup#{System.unique_integer([:positive])}",
        "merged_at" => "2026-07-11T20:00:00Z",
        "body" => "",
        "user" => %{"login" => "merge-bot"},
        "merged_by" => %{"login" => "human-merger"},
        "head" => %{"ref" => rollup_branch},
        "base" => %{"ref" => "main"}
      }
    }
  end
end
