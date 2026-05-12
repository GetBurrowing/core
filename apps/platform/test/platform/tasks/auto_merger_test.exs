defmodule Platform.Tasks.AutoMergerTest do
  use Platform.DataCase, async: true

  alias Platform.Tasks
  alias Platform.Tasks.{AutoMerger, Stacks}

  describe "should_auto_merge?/1" do
    test "returns true for pr_merge with auto_merge: true" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true, "merge_method" => "squash"}
      }

      assert AutoMerger.should_auto_merge?(strategy)
    end

    test "returns false for pr_merge with auto_merge: false" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => false}
      }

      refute AutoMerger.should_auto_merge?(strategy)
    end

    test "returns false for pr_merge with no auto_merge key (default)" do
      strategy = %{"type" => "pr_merge", "config" => %{}}
      refute AutoMerger.should_auto_merge?(strategy)
    end

    test "returns false for pr_merge with missing config" do
      strategy = %{"type" => "pr_merge"}
      refute AutoMerger.should_auto_merge?(strategy)
    end

    test "returns false for non-pr_merge strategies" do
      refute AutoMerger.should_auto_merge?(%{
               "type" => "docker_deploy",
               "config" => %{"auto_merge" => true}
             })

      refute AutoMerger.should_auto_merge?(%{"type" => "manual"})
      refute AutoMerger.should_auto_merge?(%{"type" => "none"})
    end
  end

  describe "merge_method/1" do
    test "returns configured merge method" do
      assert AutoMerger.merge_method(%{"config" => %{"merge_method" => "rebase"}}) == "rebase"
      assert AutoMerger.merge_method(%{"config" => %{"merge_method" => "merge"}}) == "merge"
      assert AutoMerger.merge_method(%{"config" => %{"merge_method" => "squash"}}) == "squash"
    end

    test "defaults to squash when not specified" do
      assert AutoMerger.merge_method(%{"config" => %{}}) == "squash"
      assert AutoMerger.merge_method(%{}) == "squash"
    end
  end

  describe "record_merge_result/2" do
    setup do
      {:ok, project} =
        Tasks.create_project(%{
          name: "AutoMerge Test #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/auto-merge"
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Auto merge test"
        })

      {:ok, plan} =
        Tasks.create_plan(%{
          task_id: task.id,
          status: "approved"
        })

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Deploy: PR merge"
        })

      {:ok, _} = Tasks.transition_stage(stage, "running")

      {:ok, pr_validation} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "ci_check"
        })

      %{pr_validation: pr_validation}
    end

    test "passes validation on successful merge", %{pr_validation: pr_validation} do
      {:ok, updated} =
        AutoMerger.record_merge_result(pr_validation.id, {:ok, "abc123def456"})

      assert updated.status == "passed"
      assert updated.evaluated_by == "auto_merger"
      assert updated.evidence["merge_sha"] == "abc123def456"
      assert updated.evidence["merged_by"] == "auto_merger"
    end

    test "fails validation on merge error", %{pr_validation: pr_validation} do
      {:ok, updated} =
        AutoMerger.record_merge_result(
          pr_validation.id,
          {:error, :conflict, "Merge conflict detected"}
        )

      assert updated.status == "failed"
      assert updated.evaluated_by == "auto_merger"
      assert updated.evidence["error_type"] == "conflict"
      assert updated.evidence["details"] == "Merge conflict detected"
    end

    test "fails validation on branch protection error", %{pr_validation: pr_validation} do
      {:ok, updated} =
        AutoMerger.record_merge_result(
          pr_validation.id,
          {:error, :branch_protection, "Required review approvals not met"}
        )

      assert updated.status == "failed"
      assert updated.evidence["error_type"] == "branch_protection"
    end
  end

  # ── ADR 0041 (T5 stage 3): stack-member guard ───────────────────────────

  describe "defer_for_stack?/1" do
    test "true for a task with non-nil stack_id" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Defer Test #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/defer"
        })

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "defer-#{System.unique_integer([:positive])}",
          name: "Defer Stack",
          rollup_branch: "stack/defer"
        })

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Member"})

      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      assert AutoMerger.defer_for_stack?(task)
      assert AutoMerger.defer_for_stack?(task.id)
    end

    test "false for a task with nil stack_id" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Defer Test #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/defer"
        })

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Lone"})

      refute AutoMerger.defer_for_stack?(task)
      refute AutoMerger.defer_for_stack?(task.id)
    end

    test "false for nil and unknown id" do
      refute AutoMerger.defer_for_stack?(nil)
      refute AutoMerger.defer_for_stack?(Ecto.UUID.generate())
    end
  end

  describe "execute_merge/4 with task context" do
    test "stack-member task returns {:ok, :deferred} and never shells out" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "ExecDefer #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/exec-defer"
        })

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "exec-defer-#{System.unique_integer([:positive])}",
          name: "Defer Exec",
          rollup_branch: "stack/exec-defer"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      # If this didn't short-circuit, it would attempt to shell out to
      # `gh pr merge` against a fake repo. The deferred return proves
      # the guard fired before the shell-out.
      assert {:ok, :deferred} =
               AutoMerger.execute_merge(task, "https://github.com/test/exec-defer", 42, "squash")
    end

    test "non-stack task delegates to execute_merge/3 (would attempt shell-out)" do
      # We can't easily mock System.cmd, so we exercise the delegation
      # path by passing a non-stack task and confirming the result
      # proves we reached the gh CLI shell-out rather than the
      # `{:ok, :deferred}` short-circuit.
      #
      # The shell-out outcome varies by environment:
      #   * gh present, repo missing → `{:error, _atom, _details}`
      #   * gh missing (CI sandbox)  → raises `ErlangError :enoent`
      # Both prove delegation; neither is `{:ok, :deferred}`.
      {:ok, project} =
        Tasks.create_project(%{
          name: "Delegate #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/exec-delegate"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Lone"})

      assert_delegates_to_shell_out(fn ->
        AutoMerger.execute_merge(
          task,
          "https://github.com/test/nonexistent-#{System.unique_integer([:positive])}",
          999_999,
          "squash"
        )
      end)
    end

    test "nil task delegates to execute_merge/3" do
      assert_delegates_to_shell_out(fn ->
        AutoMerger.execute_merge(
          nil,
          "https://github.com/test/nonexistent-#{System.unique_integer([:positive])}",
          999_999,
          "squash"
        )
      end)
    end
  end

  # Asserts that `fun` reached the `gh` shell-out path (i.e. did not
  # short-circuit with `{:ok, :deferred}`). Accepts either an error
  # tuple (gh available but the command failed) or an ErlangError
  # `:enoent` (gh binary missing, as in the CI sandbox).
  defp assert_delegates_to_shell_out(fun) do
    try do
      result = fun.()

      refute match?({:ok, :deferred}, result),
             "expected shell-out delegation, got #{inspect(result)}"

      assert match?({:error, _, _}, result),
             "expected {:error, _, _} from gh shell-out, got #{inspect(result)}"
    rescue
      e in ErlangError ->
        # `gh` binary not on PATH (typical CI sandbox). This still
        # proves delegation: we got past the stack-deferred guard and
        # attempted to invoke `gh`. Any other rescue would be a bug.
        assert e.original == :enoent,
               "expected :enoent from missing gh binary, got #{inspect(e)}"
    end
  end

  describe "record_merge_result/2 with :deferred" do
    test "passes through deferred result without touching the validation" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Deferred Record #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/deferred-record"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Deploy: PR merge"
        })

      {:ok, _} = Tasks.transition_stage(stage, "running")

      {:ok, pr_validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})

      assert {:ok, :deferred} =
               AutoMerger.record_merge_result(pr_validation.id, {:ok, :deferred})

      reloaded = Platform.Repo.get!(Platform.Tasks.Validation, pr_validation.id)
      assert reloaded.status == "pending"
    end
  end

  describe "pr_merge → single pr_merged validation regardless of auto_merge" do
    test "pr_merge with auto_merge: false does not auto-merge but still uses pr_merged" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => false}
      }

      # should_auto_merge? returns false
      refute AutoMerger.should_auto_merge?(strategy)

      # DeployStageBuilder emits a single pr_merged validation; the merge gate
      # is the GitHub pull_request.closed webhook, not a manual_approval row.
      stage_def =
        Platform.Tasks.DeployStageBuilder.build_stage(strategy, 1)

      assert stage_def.validations == [%{kind: "pr_merged"}]
    end

    test "pr_merge with auto_merge: true also uses a single pr_merged validation" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true}
      }

      assert AutoMerger.should_auto_merge?(strategy)

      stage_def =
        Platform.Tasks.DeployStageBuilder.build_stage(strategy, 1)

      assert stage_def.validations == [%{kind: "pr_merged"}]
    end
  end
end
