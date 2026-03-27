defmodule Platform.Tasks.AutoMergerTest do
  use Platform.DataCase, async: true

  alias Platform.Tasks
  alias Platform.Tasks.AutoMerger

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

  describe "auto_merge false → manual_approval still required" do
    test "pr_merge with auto_merge: false does not auto-merge" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => false}
      }

      # should_auto_merge? returns false
      refute AutoMerger.should_auto_merge?(strategy)

      # DeployStageBuilder uses manual_approval for pr_merged validation
      stage_def =
        Platform.Tasks.DeployStageBuilder.build_stage(strategy, 1)

      pr_merged_validation = Enum.find(stage_def.validations, &(&1.kind != "ci_passed"))
      assert pr_merged_validation.kind == "manual_approval"
    end

    test "pr_merge with auto_merge: true uses ci_check for pr_merged" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true}
      }

      assert AutoMerger.should_auto_merge?(strategy)

      stage_def =
        Platform.Tasks.DeployStageBuilder.build_stage(strategy, 1)

      pr_merged_validation = Enum.find(stage_def.validations, &(&1.kind != "ci_passed"))
      assert pr_merged_validation.kind == "ci_check"
    end
  end
end
