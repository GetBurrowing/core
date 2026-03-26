defmodule Platform.Tasks.DeployStageBuilderTest do
  use ExUnit.Case, async: true

  alias Platform.Tasks.DeployStageBuilder

  describe "build_stage/2 — none" do
    test "returns :skip" do
      assert DeployStageBuilder.build_stage(%{"type" => "none"}, 3) == :skip
    end
  end

  describe "build_stage/2 — pr_merge" do
    test "returns stage with test_pass and manual_approval validations" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{
          "require_ci_pass" => true,
          "require_review_approval" => false,
          "auto_merge" => false
        }
      }

      result = DeployStageBuilder.build_stage(strategy, 4)

      assert result.name == "Deploy: PR merge"
      assert result.position == 4
      assert result.validations == [%{kind: "test_pass"}, %{kind: "manual_approval"}]
      assert result.description =~ "PR merge flow"
      assert result.description =~ "CI must pass"
      assert result.description =~ "Auto-merge is disabled"
    end

    test "description reflects auto_merge enabled" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => true}
      }

      result = DeployStageBuilder.build_stage(strategy, 1)
      assert result.description =~ "Auto-merge is enabled"
    end

    test "description reflects require_review_approval" do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"require_review_approval" => true}
      }

      result = DeployStageBuilder.build_stage(strategy, 1)
      assert result.description =~ "PR review approval is required"
    end

    test "works with empty config" do
      strategy = %{"type" => "pr_merge"}
      result = DeployStageBuilder.build_stage(strategy, 2)

      assert result.name == "Deploy: PR merge"
      assert result.position == 2
      assert length(result.validations) == 2
    end
  end

  describe "build_stage/2 — docker_deploy" do
    test "returns stage with test_pass and manual_approval validations" do
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
      assert result.validations == [%{kind: "test_pass"}, %{kind: "manual_approval"}]
      assert result.description =~ "Docker"
      assert result.description =~ "dev@192.0.2.234"
      assert result.description =~ "ghcr.io/org/app:latest"
    end

    test "works without host/image in config" do
      strategy = %{"type" => "docker_deploy", "config" => %{}}
      result = DeployStageBuilder.build_stage(strategy, 1)

      assert result.name == "Deploy: Docker deploy"
      refute result.description =~ "Target host:"
      refute result.description =~ "Image:"
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

  describe "build_stage/2 — position" do
    test "uses the provided position for all strategy types" do
      for {type, pos} <- [{"pr_merge", 1}, {"docker_deploy", 7}, {"manual", 42}] do
        result = DeployStageBuilder.build_stage(%{"type" => type}, pos)
        assert result.position == pos, "Expected position #{pos} for type #{type}"
      end
    end
  end
end
