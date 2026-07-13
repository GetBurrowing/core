defmodule PlatformWeb.GithubWebhookRollupCascadeTest do
  @moduledoc """
  Regression test for the PR #531 hang (2026-07-13).

  Reproduces the exact production shape observed when a rollup PR
  merges: the stack advances to `done`, its 3 members should all
  cascade to `done`, and a `[:platform, :stacks, :deploy,
  :cascade_completed]` telemetry event should fire exactly once.

  Stage 2 wired `Stacks.cascade_members_to_done/2` to emit the
  event, so the happy-path assertion now passes. The negative-shape
  test (non-rollup PR guard) locks in that the cascade code path is
  NOT tripped by ordinary task PRs — it must not overfire.
  """
  use PlatformWeb.ConnCase, async: false

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stacks, Task, Validation}

  @github_webhook_path "/api/webhooks/github"

  # ── Runner stub ────────────────────────────────────────────────────────
  #
  # `StackDeployer.handle_rollup_pr_merged/2` triggers a rollup-branch
  # delete after the cascade. In async: false mode that shell-runs
  # synchronously — we stub it out so nothing actually shells out.

  defmodule NoopRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    @impl true
    def ensure_rollup_branch(_args),
      do: {:ok, %{status: :created, base_sha: "beefbeef"}}

    @impl true
    def merge_member_into_rollup(_args),
      do: {:ok, %{status: :merged, merge_sha: "cafecafe"}}

    @impl true
    def open_stack_pr(_args),
      do: {:ok, %{number: 1, url: "https://github.com/test/repo/pull/1"}}

    @impl true
    def diff_stat(_args), do: {:ok, ""}

    @impl true
    def revert_member_merge(_args),
      do: {:ok, %{status: :reverted, revert_sha: "revert00"}}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    @impl true
    def delete_rollup_branch(_args), do: {:ok, :deleted}
  end

  setup do
    prev = Application.get_env(:platform, :stack_deployer, [])

    Application.put_env(:platform, :stack_deployer,
      git_runner: NoopRunner,
      async: false
    )

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)
    end)

    :ok
  end

  # ── Regression: rollup-PR merge cascades stack + members to done ──────

  describe "rollup PR merge deploy cascade (task 019f5bc4-3521 / PR #531)" do
    test "3 deploying members + deploying stack all reach done with :cascade_completed telemetry fired once",
         %{conn: conn} do
      handler_id = "cascade-happy-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :deploy, :cascade_completed],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{stack: stack, rollup_branch: rollup_branch, members: members} =
        build_stranded_stack!(3, slug: "regression-cascade-#{System.unique_integer([:positive])}")

      payload =
        rollup_pr_closed_payload(rollup_branch, %{
          "number" => 999,
          "html_url" => "https://github.com/x/y/pull/999",
          "merge_commit_sha" => "rollup-happy-sha"
        })

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      # 1. Stack advanced to done.
      reloaded_stack = Repo.get!(Platform.Tasks.Stack, stack.id)
      assert reloaded_stack.status == "done"

      # 2. All members advanced to done.
      member_statuses =
        for %{task: task} <- members do
          Repo.get!(Task, task.id).status
        end

      assert member_statuses == ["done", "done", "done"],
             "expected all members to cascade to done; got #{inspect(member_statuses)}"

      # 3. :cascade_completed telemetry fired exactly once with the
      #    expected shape. This is the assertion that fails today.
      stack_id = stack.id

      assert_receive {:telemetry, [:platform, :stacks, :deploy, :cascade_completed],
                      %{count: 1, member_count: 3},
                      %{
                        stack_id: ^stack_id,
                        cascaded_count: 3,
                        skipped_count: 0,
                        trigger: :webhook
                      }},
                     500

      refute_received {:telemetry, [:platform, :stacks, :deploy, :cascade_completed], _, _}
    end

    test "non-rollup PR: per-task path fires, no :cascade_completed telemetry",
         %{conn: conn} do
      # Negative guard — a plain task/<uuid> merge must go through the
      # per-task pr_merged path and MUST NOT trip the stack cascade
      # emission. Passes today; locks in that the fix (stage 2) does
      # not overfire.
      handler_id = "cascade-negative-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :deploy, :cascade_completed],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{task: task, pr_validation: pr_validation} = build_solo_task_with_pr_merged!()

      payload =
        plain_pr_closed_payload("task/#{task.id}", %{
          "number" => 4242,
          "html_url" => "https://github.com/test/solo-repo/pull/4242",
          "merge_commit_sha" => "solo-sha"
        })

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      # Per-task path fired: pr_merged validation flipped to passed.
      reloaded = Repo.get!(Validation, pr_validation.id)
      assert reloaded.status == "passed"
      assert reloaded.evaluated_by == "github_webhook"
      # Not tagged as a stack fan-out — proves it went through the
      # per-task code path, not the stack rollup path.
      refute Map.get(reloaded.evidence || %{}, "fanned_out_from_stack_rollup_pr")

      # No stack cascade telemetry — the point of the guard.
      refute_receive {:telemetry, [:platform, :stacks, :deploy, :cascade_completed], _, _}, 200
    end
  end

  # ── Fixture helpers ────────────────────────────────────────────────────

  # Build a stack in the exact "PR #531" shape: stack at `deploying`
  # with `rollup_pr.opened_at` stamped, N member tasks all at
  # `deploying` with `stack_id` set, an approved plan carrying ONE
  # completed execution stage and NO per-task pr_merged validation
  # (stack members ship via the rollup PR — see
  # `Tasks.dispatch_deploy_for_task/1` returning
  # `{:error, :stack_ships_atomically}` for stacked tasks).
  defp build_stranded_stack!(member_count, opts) when member_count > 0 do
    slug =
      Keyword.get(opts, :slug, "rollup-cascade-#{System.unique_integer([:positive])}")

    rollup_branch = "stack/#{slug}"

    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    {:ok, project} =
      Tasks.create_project(%{
        name: "Cascade Regression #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/cascade-repo"
      })

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Cascade Regression Stack",
        base_branch: "main",
        rollup_branch: rollup_branch,
        status: "deploying",
        metadata: %{
          "rollup_pr" => %{
            "number" => 999,
            "url" => "https://github.com/x/y/pull/999",
            "opened_at" => now_iso
          }
        }
      })

    members =
      for position <- 1..member_count do
        {:ok, task} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Cascade member #{position}"
          })

        # A completed execution stage on an approved plan — enough to
        # satisfy the `require_approved_plan_for/2` guard. NO deploy
        # stage, NO pr_merged validation: stack members never carry
        # one.
        {:ok, plan} =
          Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

        {:ok, _stage} =
          Tasks.create_stage(%{
            plan_id: plan.id,
            position: 1,
            name: "Execute",
            description: "Execute stage",
            status: "passed"
          })

        {:ok, task} =
          Tasks.update_task(task, %{
            stack_id: stack.id,
            stack_position: position,
            status: "deploying"
          })

        %{task: task, plan: plan}
      end

    %{
      project: project,
      stack: stack,
      rollup_branch: rollup_branch,
      members: members
    }
  end

  # A solo (non-stack) task at `in_review` with a running deploy
  # stage carrying a pending pr_merged validation. Mirrors the shape
  # `create_task_with_ci_validation!` in `github_webhook_controller_test.exs`
  # produces, minus the ci_validation — we only need the pr_merged one.
  defp build_solo_task_with_pr_merged! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Solo Task #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/solo-repo"
      })

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Solo task"})

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Deploy: PR merge",
        description: "Deploy via PR merge"
      })

    {:ok, _} = Tasks.transition_stage(stage, "running")
    stage = Repo.get!(Platform.Tasks.Stage, stage.id)

    {:ok, pr_validation} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})

    %{project: project, task: task, plan: plan, stage: stage, pr_validation: pr_validation}
  end

  defp rollup_pr_closed_payload(rollup_branch, overrides) do
    pr =
      Map.merge(
        %{
          "merged" => true,
          "title" => "chore: rollup cascade regression",
          "number" => System.unique_integer([:positive]),
          "html_url" =>
            "https://github.com/test/cascade-repo/pull/#{System.unique_integer([:positive])}",
          "merge_commit_sha" => "rollup#{System.unique_integer([:positive])}",
          "merged_at" => "2026-07-13T06:18:00Z",
          "body" => "",
          "user" => %{"login" => "merge-bot"},
          "merged_by" => %{"login" => "ryanm"},
          "head" => %{"ref" => rollup_branch},
          "base" => %{"ref" => "main"}
        },
        overrides
      )

    %{"action" => "closed", "pull_request" => pr}
  end

  defp plain_pr_closed_payload(head_ref, overrides) do
    pr =
      Map.merge(
        %{
          "merged" => true,
          "title" => "feat: solo task",
          "number" => System.unique_integer([:positive]),
          "html_url" =>
            "https://github.com/test/solo-repo/pull/#{System.unique_integer([:positive])}",
          "merge_commit_sha" => "solo#{System.unique_integer([:positive])}",
          "merged_at" => "2026-07-13T06:18:00Z",
          "body" => "",
          "user" => %{"login" => "agent-bot"},
          "head" => %{"ref" => head_ref}
        },
        overrides
      )

    %{"action" => "closed", "pull_request" => pr}
  end
end
