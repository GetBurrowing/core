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

  # ── Per-repository gating (task 019fa63a stage 4) ───────────────────────

  describe "should_auto_merge?/2" do
    @strategy_on %{"type" => "pr_merge", "config" => %{"auto_merge" => true}}
    @strategy_off %{"type" => "pr_merge", "config" => %{"auto_merge" => false}}

    test "returns :yes for a repo with required CI and auto_merge on" do
      assert AutoMerger.should_auto_merge?(@strategy_on, %{"ci" => "required"}) == :yes

      assert AutoMerger.should_auto_merge?(@strategy_off, %{
               "ci" => "required",
               "auto_merge" => true
             }) == :yes
    end

    test "returns {:no, :disabled} when auto_merge is off" do
      assert AutoMerger.should_auto_merge?(@strategy_off, %{"ci" => "required"}) ==
               {:no, :disabled}

      assert AutoMerger.should_auto_merge?(@strategy_on, %{
               "ci" => "required",
               "auto_merge" => false
             }) == {:no, :disabled}
    end

    # THE LOAD-BEARING CASE. `ci: "none"` means there is no CI signal that
    # could ever authorize a machine merge, so `auto_merge: true` at BOTH
    # levels must not produce one.
    test "returns {:no, :no_ci_to_gate} for ci: \"none\" even with auto_merge on everywhere" do
      assert AutoMerger.should_auto_merge?(@strategy_on, %{
               "ci" => "none",
               "auto_merge" => true,
               "config" => %{"auto_merge" => true}
             }) == {:no, :no_ci_to_gate}

      assert AutoMerger.should_auto_merge?(@strategy_on, %{ci: "none", config: %{}}) ==
               {:no, :no_ci_to_gate}
    end

    # `not_applicable` vs `failed` in `Task.planning_step_outcomes`, one layer
    # down: "we chose not to" and "it can never happen" are different facts
    # and a caller must be able to branch on which one it got.
    test "the two refusals are not the same value" do
      no_ci =
        AutoMerger.should_auto_merge?(@strategy_on, %{"ci" => "none", "auto_merge" => true})

      disabled = AutoMerger.should_auto_merge?(@strategy_off, %{"ci" => "required"})

      assert no_ci == {:no, :no_ci_to_gate}
      assert disabled == {:no, :disabled}

      refute no_ci == disabled,
             "collapsing these makes a gate that can never open indistinguishable " <>
               "from one that merely has not opened yet"
    end

    test "reads the atom-keyed entry Tasks.resolve_deploy_repos/1 returns" do
      entry = %{
        repo_url: "https://github.com/Startup-Suite/core",
        slug: "Startup-Suite/core",
        config: %{"auto_merge" => true},
        ci: "required",
        role: :primary
      }

      assert AutoMerger.should_auto_merge?(@strategy_off, entry) == :yes

      assert AutoMerger.should_auto_merge?(@strategy_on, %{entry | ci: "none"}) ==
               {:no, :no_ci_to_gate}
    end

    test "reads the payload DeployStageBuilder writes onto each pr_merged gate" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true},
        "repos" => [
          %{"repo_url" => "https://github.com/Startup-Suite/core", "ci" => "required"},
          %{"repo_url" => "Startup-Suite/claude-code-suite-channel", "ci" => "none"}
        ]
      }

      [core, bridge] =
        Platform.Tasks.DeployStageBuilder.build_stage(strategy, 1).validations

      assert AutoMerger.should_auto_merge?(strategy, core.evaluation_payload) == :yes

      assert AutoMerger.should_auto_merge?(strategy, bridge.evaluation_payload) ==
               {:no, :no_ci_to_gate}
    end

    test "an unrecognized ci value gates rather than merges" do
      # Mirrors `Tasks.normalize_repo_ci/2`: only the literal "none" opts out,
      # so a typo produces a gate that waits, not a merge nobody authorized.
      assert AutoMerger.should_auto_merge?(@strategy_on, %{"ci" => "nope"}) == :yes
      assert AutoMerger.should_auto_merge?(@strategy_off, %{"ci" => "nope"}) == {:no, :disabled}
    end

    test "a nil entry falls back to the strategy-wide answer" do
      assert AutoMerger.should_auto_merge?(@strategy_on, nil) == :yes
      assert AutoMerger.should_auto_merge?(@strategy_off, nil) == {:no, :disabled}
    end
  end

  describe "merge_method/2" do
    test "prefers the repo entry's own method" do
      strategy = %{"config" => %{"merge_method" => "squash"}}

      assert AutoMerger.merge_method(strategy, %{"merge_method" => "rebase"}) == "rebase"

      assert AutoMerger.merge_method(strategy, %{"config" => %{"merge_method" => "merge"}}) ==
               "merge"
    end

    test "falls back to the strategy when the entry says nothing" do
      strategy = %{"config" => %{"merge_method" => "rebase"}}

      assert AutoMerger.merge_method(strategy, %{"ci" => "required"}) == "rebase"
      assert AutoMerger.merge_method(strategy, nil) == "rebase"
      assert AutoMerger.merge_method(%{}, %{}) == "squash"
    end
  end

  describe "record_auto_merge_refusal/3" do
    test "records the refusal and leaves the gate pending" do
      %{pr_validation: validation} = task_with_pr_validation!()

      assert {:ok, updated} =
               AutoMerger.record_auto_merge_refusal(validation, :no_ci_to_gate, "Owner/Repo")

      assert updated.evidence["auto_merge"] == "refused"
      assert updated.evidence["reason"] == "no_ci_to_gate"
      assert updated.evidence["repo"] == "Owner/Repo"

      # NOT `record_merge_result/2` — that would evaluate the validation as
      # `failed` and close the gate against the human merge that is the
      # entire point of a repository with no CI.
      assert Platform.Repo.get!(Platform.Tasks.Validation, validation.id).status == "pending"
    end

    test "is idempotent for the same reason" do
      %{pr_validation: validation} = task_with_pr_validation!()

      {:ok, first} =
        AutoMerger.record_auto_merge_refusal(validation, :no_ci_to_gate, "Owner/Repo")

      assert AutoMerger.record_auto_merge_refusal(first, :no_ci_to_gate, "Owner/Repo") ==
               :already_recorded
    end

    test "preserves evidence written by other paths" do
      %{pr_validation: validation} = task_with_pr_validation!()

      validation =
        validation
        |> Ecto.Changeset.change(%{evidence: %{"unmatched_repo_deliveries" => []}})
        |> Platform.Repo.update!()

      {:ok, updated} =
        AutoMerger.record_auto_merge_refusal(validation, :no_ci_to_gate, "Owner/Repo")

      assert updated.evidence["unmatched_repo_deliveries"] == []
      assert updated.evidence["auto_merge"] == "refused"
    end

    defp task_with_pr_validation! do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Refusal #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/Startup-Suite/core"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Refusal"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy: PR merge"})

      {:ok, _} = Tasks.transition_stage(stage, "running")
      {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})

      %{task: task, pr_validation: validation}
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

  # ── ADR-0046 member 4 stage 4: the planning-gate guard ────────────────────
  #
  # `:planning_gate_failed` is deliberately NOT a value
  # `classify_merge_error/1` can produce — that function only ever returns
  # `:conflict`, `:branch_protection`, `:ci_required` or `:unknown` — so
  # asserting the exact atom is itself proof the shell-out did not happen.
  # Same seam as "stack-member task returns {:ok, :deferred} and never
  # shells out" above: the repo URL is fake, so any real `gh` invocation
  # would surface as one of those four atoms (or an `:enoent` raise where
  # `gh` is absent), never as ours.

  describe "execute_merge/4 planning gate" do
    test "failed gate: returns {:error, :planning_gate_failed, detail} and never shells out" do
      task =
        task_with_planning_outcomes!("Gate broke", %{
          "architecture" => %{
            "outcome" => "failed",
            "detail" => "econnrefused",
            "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        })

      assert {:error, :planning_gate_failed, detail} =
               AutoMerger.execute_merge(
                 task,
                 "https://github.com/test/nonexistent-#{System.unique_integer([:positive])}",
                 999_999,
                 "squash"
               )

      # The detail names the step and carries the recorded reason, so the
      # failed validation's evidence says WHY, not merely THAT.
      assert detail =~ "architecture"
      assert detail =~ "econnrefused"
      assert detail =~ "not a skip"
    end

    test "guard runs AHEAD of the stack-member guard: a stack member with a failed gate refuses rather than defers" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "GateStack #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/gate-stack"
        })

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "gate-stack-#{System.unique_integer([:positive])}",
          name: "Gate Stack",
          rollup_branch: "stack/gate-stack"
        })

      task =
        %Platform.Tasks.Task{}
        |> Platform.Tasks.Task.changeset(%{
          project_id: project.id,
          title: "Stack member with a broken gate",
          status: "in_review",
          stack_id: stack.id,
          stack_position: 1
        })
        |> Platform.Repo.insert!()
        |> Platform.Tasks.Task.planning_step_changeset(%{
          planning_step_outcomes: %{
            "architecture" => %{"outcome" => "failed", "detail" => "timeout"}
          }
        })
        |> Platform.Repo.update!()

      # Without the ordering this would be `{:ok, :deferred}` — the
      # stack-member guard would win. It does not strand the stack:
      # rollup fan-out is `Stacks.cascade_members_to_done/2`, a status
      # flip, not a validation evaluation.
      assert {:error, :planning_gate_failed, _detail} =
               AutoMerger.execute_merge(task, "https://github.com/test/gate-stack", 42, "squash")
    end

    # `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`
    test "not_applicable is NOT a failed gate — delegates to the shell-out" do
      task =
        task_with_planning_outcomes!("Nobody holds it", %{
          "architecture" => %{
            "outcome" => "not_applicable",
            "detail" => nil,
            "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        })

      refute_planning_gate_refusal(fn ->
        AutoMerger.execute_merge(
          task,
          "https://github.com/test/nonexistent-#{System.unique_integer([:positive])}",
          999_999,
          "squash"
        )
      end)
    end

    test "complete outcome and absent key both delegate to the shell-out" do
      complete =
        task_with_planning_outcomes!("Ran fine", %{
          "architecture" => %{"outcome" => "complete", "detail" => nil}
        })

      absent = task_with_planning_outcomes!("Never recorded", %{})

      refute_planning_gate_refusal(fn ->
        AutoMerger.execute_merge(
          complete,
          "https://github.com/test/nonexistent-#{System.unique_integer([:positive])}",
          999_999,
          "squash"
        )
      end)

      refute_planning_gate_refusal(fn ->
        AutoMerger.execute_merge(
          absent,
          "https://github.com/test/nonexistent-#{System.unique_integer([:positive])}",
          999_999,
          "squash"
        )
      end)
    end
  end

  # `assert_delegates_to_shell_out/1` alone would be VACUOUS here: it
  # accepts any `{:error, _, _}`, and the planning-gate refusal is itself
  # an `{:error, _, _}`. So the non-failed outcomes additionally assert the
  # error atom is not ours.
  defp refute_planning_gate_refusal(fun) do
    try do
      result = fun.()

      refute match?({:error, :planning_gate_failed, _}, result),
             "planning gate must not fire for a non-failed outcome, got #{inspect(result)}"

      assert match?({:error, _, _}, result),
             "expected {:error, _, _} from gh shell-out, got #{inspect(result)}"
    rescue
      e in ErlangError ->
        # `gh` missing — still proves we reached the shell-out rather
        # than short-circuiting on the gate.
        assert e.original == :enoent,
               "expected :enoent from missing gh binary, got #{inspect(e)}"
    end
  end

  describe "record_merge_result/2 with :planning_gate_failed" do
    test "marks pr_merged failed with error_type planning_gate_failed and the detail in evidence" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "GateRecord #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/gate-record"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Gate record"})
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy: PR merge"})

      {:ok, _} = Tasks.transition_stage(stage, "running")

      {:ok, pr_validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})

      detail = "architecture — econnrefused"

      assert {:ok, _} =
               AutoMerger.record_merge_result(
                 pr_validation.id,
                 {:error, :planning_gate_failed, detail}
               )

      reloaded = Platform.Repo.get!(Platform.Tasks.Validation, pr_validation.id)
      assert reloaded.status == "failed"
      assert reloaded.evidence["error_type"] == "planning_gate_failed"
      assert reloaded.evidence["details"] == detail
    end
  end

  # `planning_step_outcomes` is not castable by `Task.changeset/2` (stage 1
  # kept it off the unguarded `Tasks.update_task/3` surface), so seed it
  # through the narrow changeset. `Repo.insert!` rather than
  # `Tasks.create_task/1` keeps these rows off the context-level write path
  # that trips the `TaskRouterWatcher` sandbox race in async modules.
  defp task_with_planning_outcomes!(title, outcomes) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "GateTask #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/gate-task"
      })

    %Platform.Tasks.Task{}
    |> Platform.Tasks.Task.changeset(%{
      project_id: project.id,
      title: title,
      status: "in_review"
    })
    |> Platform.Repo.insert!()
    |> Platform.Tasks.Task.planning_step_changeset(%{planning_step_outcomes: outcomes})
    |> Platform.Repo.update!()
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
