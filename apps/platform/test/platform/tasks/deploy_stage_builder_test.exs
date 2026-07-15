defmodule Platform.Tasks.DeployStageBuilderTest do
  use ExUnit.Case, async: true

  alias Platform.Tasks.DeployStageBuilder

  describe "build_stage/2 — none" do
    test "returns :skip" do
      assert DeployStageBuilder.build_stage(%{"type" => "none"}, 3) == :skip
    end
  end

  describe "build_stage/2 — pr_merge" do
    test "auto_merge false: emits a single pr_merged validation" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{
          "require_review_approval" => false,
          "auto_merge" => false
        }
      }

      result = DeployStageBuilder.build_stage(strategy, 4)

      assert result.name == "Deploy: PR merge"
      assert result.position == 4
      assert result.validations == [%{kind: "pr_merged"}]
      assert result.description =~ "PR merge flow"
      assert result.description =~ "pr_merged validation"
      assert result.description =~ "Auto-merge is disabled"
      refute result.description =~ "manual_approval"
      refute result.description =~ "ci_passed"
    end

    test "auto_merge true: still emits a single pr_merged validation" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true, "merge_method" => "squash"}
      }

      result = DeployStageBuilder.build_stage(strategy, 1)

      assert result.validations == [%{kind: "pr_merged"}]
      assert result.description =~ "Auto-merge is enabled"
      assert result.description =~ "merge method: squash"
      refute result.description =~ "ci_check"
      refute result.description =~ "manual_approval"
    end

    test "auto_merge true defaults merge_method to squash" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true}
      }

      result = DeployStageBuilder.build_stage(strategy, 1)
      assert result.description =~ "merge method: squash"
    end

    test "description reflects require_review_approval" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"require_review_approval" => true}
      }

      result = DeployStageBuilder.build_stage(strategy, 1)
      assert result.description =~ "PR review approval is required"
    end

    test "works with empty config (defaults to single pr_merged validation)" do
      strategy = %{"type" => "pr_merge"}
      result = DeployStageBuilder.build_stage(strategy, 2)

      assert result.name == "Deploy: PR merge"
      assert result.position == 2
      # Always a single pr_merged validation regardless of auto_merge
      assert result.validations == [%{kind: "pr_merged"}]
    end
  end

  describe "build_stage/2 — docker_deploy" do
    test "returns stage with ci_passed and test_pass validations" do
      strategy = %{
        "type" => "docker_deploy",
        "config" => %{
          "host" => "dev@192.0.2.234",
          "image" => "ghcr.io/org/app:latest"
        }
      }

      result = DeployStageBuilder.build_stage(strategy, 5)

      assert result.name == "Deploy: Docker deploy"
      assert result.position == 5
      assert result.validations == [%{kind: "ci_passed"}, %{kind: "test_pass"}]
      assert result.description =~ "Docker"
      assert result.description =~ "dev@192.0.2.234"
      assert result.description =~ "ghcr.io/org/app:latest"
    end

    test "works without host/image in config" do
      strategy = %{"type" => "docker_deploy", "config" => %{}}
      result = DeployStageBuilder.build_stage(strategy, 1)

      assert result.name == "Deploy: Docker deploy"
      assert result.validations == [%{kind: "ci_passed"}, %{kind: "test_pass"}]
      refute result.description =~ "Target host:"
      refute result.description =~ "Image:"
    end
  end

  describe "build_stage/2 — fly" do
    test "returns stage with ci_passed and test_pass validations" do
      strategy = %{
        "type" => "fly",
        "config" => %{"app" => "my-fly-app"}
      }

      result = DeployStageBuilder.build_stage(strategy, 3)

      assert result.name == "Deploy: Fly deploy"
      assert result.position == 3
      assert result.validations == [%{kind: "ci_passed"}, %{kind: "test_pass"}]
      assert result.description =~ "Fly.io"
      assert result.description =~ "my-fly-app"
    end

    test "works without app in config" do
      strategy = %{"type" => "fly", "config" => %{}}
      result = DeployStageBuilder.build_stage(strategy, 1)

      assert result.name == "Deploy: Fly deploy"
      refute result.description =~ "Fly app:"
    end
  end

  describe "build_stage/2 — skill_driven" do
    test "returns stage with manual_approval validation" do
      strategy = %{
        "type" => "skill_driven",
        "skill_id" => "abc-123",
        "config" => %{}
      }

      result = DeployStageBuilder.build_stage(strategy, 3)

      assert result.name == "Deploy: Skill execution"
      assert result.position == 3
      assert result.validations == [%{kind: "manual_approval"}]
      assert result.description =~ "abc-123"
    end

    test "handles missing skill_id" do
      strategy = %{"type" => "skill_driven", "config" => %{}}
      result = DeployStageBuilder.build_stage(strategy, 1)

      assert result.description =~ "No skill ID specified"
    end

    test "includes additional context from config" do
      strategy = %{
        "type" => "skill_driven",
        "config" => %{"context" => "Deploy to staging first"}
      }

      result = DeployStageBuilder.build_stage(strategy, 1)
      assert result.description =~ "Deploy to staging first"
    end
  end

  describe "build_stage/2 — manual" do
    test "returns stage with manual_approval validation" do
      strategy = %{"type" => "manual"}
      result = DeployStageBuilder.build_stage(strategy, 2)

      assert result.name == "Deploy: Manual"
      assert result.position == 2
      assert result.validations == [%{kind: "manual_approval"}]
      assert result.description =~ "Manual deployment"
    end
  end

  describe "build_stage/2 — project_files" do
    test "returns stage with test_pass validation and description mentions the folder" do
      strategy = %{
        "type" => "project_files",
        "config" => %{
          "project_id" => "019f0000-0000-7000-8000-000000000000",
          "folder" => "Deliverables",
          "deliverable_canvas_id" => "019f0000-0000-7000-8000-000000000001"
        }
      }

      result = DeployStageBuilder.build_stage(strategy, 3)

      assert result.name == "Deploy: Project files"
      assert result.position == 3
      assert result.validations == [%{kind: "test_pass"}]
      assert result.description =~ "Files module"
      assert result.description =~ "Deliverables"
      assert result.description =~ "019f0000-0000-7000-8000-000000000000"
      assert result.description =~ "019f0000-0000-7000-8000-000000000001"
      refute result.description =~ "manual_approval"
      refute result.description =~ "ci_passed"
    end

    test "defaults folder to Deliverables when config omits it" do
      strategy = %{"type" => "project_files", "config" => %{}}
      result = DeployStageBuilder.build_stage(strategy, 1)

      assert result.name == "Deploy: Project files"
      assert result.validations == [%{kind: "test_pass"}]
      assert result.description =~ "Deliverables"
      # No explicit canvas → falls back to newest exec-space canvas
      assert result.description =~ "newest canvas in the task's execution space"
    end

    test "works with empty strategy (no config key)" do
      strategy = %{"type" => "project_files"}
      result = DeployStageBuilder.build_stage(strategy, 2)

      assert result.name == "Deploy: Project files"
      assert result.position == 2
      assert result.validations == [%{kind: "test_pass"}]
    end
  end

  describe "build_stage/2 — position" do
    test "uses the provided position for all strategy types" do
      for {type, pos} <- [
            {"pr_merge", 1},
            {"docker_deploy", 7},
            {"fly", 10},
            {"manual", 42},
            {"project_files", 6}
          ] do
        result = DeployStageBuilder.build_stage(%{"type" => type}, pos)
        assert result.position == pos, "Expected position #{pos} for type #{type}"
      end
    end
  end

  describe "validate_strategy/1" do
    test "returns :ok for all valid strategy types" do
      for type <- DeployStageBuilder.valid_strategy_types() do
        assert :ok == DeployStageBuilder.validate_strategy(%{"type" => type}),
               "Expected :ok for type #{type}"
      end
    end

    test "returns error for unknown type" do
      assert {:error, msg} = DeployStageBuilder.validate_strategy(%{"type" => "bogus"})
      assert msg =~ "unknown strategy type"
      assert msg =~ "bogus"
    end

    test "returns error when type key is missing" do
      assert {:error, _} = DeployStageBuilder.validate_strategy(%{})
    end

    test "returns error for non-map input" do
      assert {:error, _} = DeployStageBuilder.validate_strategy("not a map")
    end
  end

  describe "valid_merge_method?/1" do
    test "returns true for squash, merge, rebase" do
      assert DeployStageBuilder.valid_merge_method?("squash")
      assert DeployStageBuilder.valid_merge_method?("merge")
      assert DeployStageBuilder.valid_merge_method?("rebase")
    end

    test "returns false for unknown method" do
      refute DeployStageBuilder.valid_merge_method?("fast-forward")
      refute DeployStageBuilder.valid_merge_method?("")
    end
  end
end
