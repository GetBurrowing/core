defmodule Platform.Tasks.ValidationRegistryTest do
  use ExUnit.Case, async: true

  alias Platform.Tasks.ValidationRegistry

  describe "kinds/0" do
    test "returns all known validation kinds" do
      kinds = ValidationRegistry.kinds()

      assert "ci_check" in kinds
      assert "ci_passed" in kinds
      assert "pr_merged" in kinds
      assert "lint_pass" in kinds
      assert "type_check" in kinds
      assert "test_pass" in kinds
      assert "code_review" in kinds
      assert "manual_approval" in kinds
      assert length(kinds) == 8
    end
  end

  describe "get/1" do
    test "returns definition for known kind" do
      assert {:ok, definition} = ValidationRegistry.get("ci_check")
      assert definition.kind == "ci_check"
      assert definition.label == "CI Check"
      assert definition.deterministic == true
      assert is_binary(definition.description)
    end

    test "returns error for unknown kind" do
      assert {:error, :unknown_kind} = ValidationRegistry.get("nonexistent")
    end

    test "returns correct definition for each kind" do
      for kind <- ValidationRegistry.kinds() do
        assert {:ok, %{kind: ^kind}} = ValidationRegistry.get(kind)
      end
    end
  end

  describe "valid_kind?/1" do
    test "returns true for known kinds" do
      assert ValidationRegistry.valid_kind?("ci_check")
      assert ValidationRegistry.valid_kind?("manual_approval")
    end

    test "returns false for unknown kinds" do
      refute ValidationRegistry.valid_kind?("nonexistent")
      refute ValidationRegistry.valid_kind?("")
    end
  end

  describe "deterministic?/1" do
    test "returns true for deterministic kinds" do
      assert ValidationRegistry.deterministic?("ci_check")
      assert ValidationRegistry.deterministic?("ci_passed")
      assert ValidationRegistry.deterministic?("lint_pass")
      assert ValidationRegistry.deterministic?("type_check")
      assert ValidationRegistry.deterministic?("test_pass")
    end

    test "returns false for non-deterministic kinds" do
      refute ValidationRegistry.deterministic?("code_review")
      refute ValidationRegistry.deterministic?("manual_approval")
      refute ValidationRegistry.deterministic?("pr_merged")
    end

    test "returns false for unknown kinds" do
      refute ValidationRegistry.deterministic?("nonexistent")
    end
  end

  describe "all/0" do
    test "returns all definitions" do
      definitions = ValidationRegistry.all()
      assert length(definitions) == 8

      for def <- definitions do
        assert is_binary(def.kind)
        assert is_binary(def.label)
        assert is_boolean(def.deterministic)
        assert is_binary(def.description)
      end
    end
  end
end
