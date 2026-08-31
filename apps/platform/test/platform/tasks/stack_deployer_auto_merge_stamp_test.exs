defmodule Platform.Tasks.StackDeployerAutoMergeStampTest do
  @moduledoc """
  Task 01a05394 stage 5 — the rollup PR open stamps
  `rollup_pr.auto_merge_armed == false` and warns when the project's
  deploy config claims `auto_merge: true`.

  `GitRunner.open_stack_pr/1` runs `gh pr create` only; nothing on the
  stack path arms `gh pr merge --auto`. A project configured with
  `auto_merge: true` therefore gets task-level auto-merge and NOTHING at
  the rollup level, and until this stage nothing said so. The decision
  is to make that belief impossible to hold quietly, not to arm it.

  Two tests per observable: an absence assertion needs one test per
  side or it is vacuous. The test logger is pinned to `:warning`, so
  the warning is readable in `capture_log`.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Tasks
  alias Platform.Tasks.{StackDeployer, Stacks}

  defmodule PrRunner do
    @moduledoc false

    def open_stack_pr(_args),
      do: {:ok, %{number: 5100, url: "https://github.com/test/repo/pull/5100"}}

    def diff_stat(_args), do: {:ok, " 1 file changed"}

    def sha_reachable?(_args), do: {:ok, true}
  end

  setup do
    prev = Application.get_env(:platform, :stack_deployer, [])

    Application.put_env(:platform, :stack_deployer,
      git_runner: PrRunner,
      async: false
    )

    on_exit(fn -> Application.put_env(:platform, :stack_deployer, prev) end)
    :ok
  end

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()

  # Same shape as the stage-4 fixture: every member landed on the rollup,
  # stack at `deploying`, no `rollup_pr` yet. `deploy_config` is the only
  # thing that varies between the two sides.
  defp pr_ready_stack!(deploy_config) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "auto-merge stamp #{uniq()}",
        repo_url: "https://github.com/test/auto-merge-stamp-#{uniq()}",
        deploy_config: deploy_config
      })

    slug = "auto-merge-stamp-#{uniq()}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stack #{slug}",
        base_branch: "main",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    {:ok, task} = Tasks.create_task(%{title: "member #{uniq()}", project_id: project.id})

    {:ok, task} =
      Tasks.update_task(task, %{
        stack_id: stack.id,
        stack_position: 1,
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => "abc1234",
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      })

    {:ok, _task} = Tasks.update_task(task, %{status: "in_review"})
    {:ok, stack} = Stacks.update_stack(stack, %{status: "deploying"})

    refute Map.has_key?(stack.metadata || %{}, "rollup_pr")
    stack
  end

  @auto_merge_config %{
    "default_strategy" => %{"type" => "pr_merge", "config" => %{"auto_merge" => true}}
  }
  @plain_config %{"default_strategy" => %{"type" => "pr_merge"}}

  describe "project deploy config sets auto_merge: true" do
    test "rollup_pr.auto_merge_armed is stamped false and a warning names the stack and PR" do
      stack = pr_ready_stack!(@auto_merge_config)

      log =
        capture_log(fn ->
          assert {:ok, %{status: :opened, number: 5100}} =
                   StackDeployer.maybe_open_stack_pr(stack)
        end)

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.metadata["rollup_pr"]["number"] == 5100
      assert Map.fetch(reloaded.metadata["rollup_pr"], "auto_merge_armed") == {:ok, false}

      assert log =~ "[warning]"
      assert log =~ "stack #{stack.id} rollup PR #5100"
      assert log =~ "stack rollup PRs do not arm auto-merge"
      assert log =~ "requires a human or webhook-driven merge"
    end
  end

  describe "project deploy config without auto_merge" do
    test "rollup_pr.auto_merge_armed is still stamped false and NO warning is logged" do
      stack = pr_ready_stack!(@plain_config)

      log =
        capture_log(fn ->
          assert {:ok, %{status: :opened, number: 5100}} =
                   StackDeployer.maybe_open_stack_pr(stack)
        end)

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.metadata["rollup_pr"]["number"] == 5100
      assert Map.fetch(reloaded.metadata["rollup_pr"], "auto_merge_armed") == {:ok, false}

      refute log =~ "do not arm auto-merge"
      refute log =~ "auto_merge: true"
    end
  end
end
