defmodule Platform.Responsibilities.RoleTriggerTest do
  @moduledoc """
  A chat trigger addresses a role, never an agent. The refutations on `@vega`
  AND `@saru` are the point: fixing a stale handle by swapping in the current
  one would reproduce the defect one reassignment later.
  """
  use ExUnit.Case, async: true

  alias Platform.Responsibilities.RoleTrigger

  @designer_spec RoleTrigger.chat_regex("designer", "spec")
  @designer_brand RoleTrigger.chat_regex("designer", "brand")
  @designer_critique RoleTrigger.chat_regex("designer", "(critique|review)")

  describe "chat_regex/3" do
    test "every built pattern compiles" do
      for source <- [@designer_spec, @designer_brand, @designer_critique] do
        assert {:ok, %Regex{}} = Regex.compile(source), "did not compile: #{source}"
      end
    end

    test "matches the role token" do
      assert Regex.match?(Regex.compile!(@designer_spec), "@designer spec this")
      assert Regex.match?(Regex.compile!(@designer_brand), "@designer brand this")
      assert Regex.match?(Regex.compile!(@designer_critique), "@designer critique this")
      assert Regex.match?(Regex.compile!(@designer_critique), "@designer review this")
    end

    test "is case-insensitive on the token" do
      assert Regex.match?(Regex.compile!(@designer_spec), "@Designer SPEC this")
    end

    test "does not match any agent handle, past or present" do
      compiled = Regex.compile!(@designer_spec)

      refute Regex.match?(compiled, "@vega spec this")
      refute Regex.match?(compiled, "@saru spec this")
    end

    test "requires whitespace between token and verb" do
      refute Regex.match?(Regex.compile!(@designer_spec), "@designerspec this")
    end

    test "raises on an unknown role key" do
      assert_raise ArgumentError, ~r/unknown role key/, fn ->
        RoleTrigger.chat_regex("desginer", "spec")
      end

      assert_raise ArgumentError, ~r/unknown role key/, fn ->
        RoleTrigger.chat_regex("design.spec_writer", "spec")
      end
    end

    test "accepts every key on the closed role roster" do
      for key <- Platform.Roles.Role.valid_keys() do
        assert {:ok, %Regex{}} = Regex.compile(RoleTrigger.chat_regex(key, "spec"))
      end
    end

    test ":trailing lands verbatim at the very end" do
      trailing = "(?:\\s+(?:\\S*\\/chat\\/canvas\\/)?([0-9a-fA-F-]{36}))?"
      source = RoleTrigger.chat_regex("designer", "(critique|review)", trailing: trailing)

      assert String.ends_with?(source, trailing)
      assert source == @designer_critique <> trailing
      assert {:ok, compiled} = Regex.compile(source)

      id = "11111111-2222-4333-8444-555555555555"

      assert [_full, _verb, ^id] = Regex.run(compiled, "@designer critique #{id}")
      assert Regex.match?(compiled, "@designer critique this")
    end
  end
end
