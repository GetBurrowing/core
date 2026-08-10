defmodule Platform.Responsibilities.Handlers.DesignStubTriggersTest do
  @moduledoc """
  Behavioural cover for the two Designer-bundle stub chat triggers
  (`design.spec_writer`, `design.brand_check`): the registered regex must
  address the ROLE and no agent handle.

  These assertions run against the value `register/0` returns, never against a
  source scan. A grep for a departed handle cannot distinguish a matcher from
  prose — `design_critique.ex` deliberately keeps the old handle in its
  moduledoc as the record of why it was dropped, so a "no such string in lib/"
  assertion is unsatisfiable by construction. The registry is where behaviour
  lives; that is what we assert on.

  Sibling: `test/platform/responsibilities/role_trigger_test.exs` covers the
  builder itself.
  """
  use ExUnit.Case, async: true

  alias Platform.Responsibilities.Handlers.DesignBrandCheck
  alias Platform.Responsibilities.Handlers.DesignSpecWriter

  defp compiled_trigger(module) do
    [spec] = module.register()
    assert spec.trigger_kind == "chat_pattern"
    assert {:ok, regex} = Regex.compile(spec.trigger_config["regex"])
    {spec, regex}
  end

  describe "design.spec_writer trigger" do
    test "matches the designer role token and no agent handle" do
      {spec, regex} = compiled_trigger(DesignSpecWriter)

      assert Regex.match?(regex, "@designer spec the onboarding canvas")
      assert Regex.match?(regex, "@DESIGNER SPEC the onboarding canvas")

      # A trigger that names a person outlives the person exactly once and
      # then lies. Both historical handles must now be inert.
      refute Regex.match?(regex, "@vega spec the onboarding canvas")
      refute Regex.match?(regex, "@saru spec the onboarding canvas")

      # The role key has exactly one source in the handler.
      assert spec.metadata["role"] == "designer"
      assert spec.trigger_config["regex"] =~ "@" <> spec.metadata["role"]
    end

    test "does not fire on the role token without the verb" do
      {_spec, regex} = compiled_trigger(DesignSpecWriter)

      refute Regex.match?(regex, "@designer can you take a look?")
      refute Regex.match?(regex, "@designer brand check please")
    end
  end

  describe "design.brand_check trigger" do
    test "matches the designer role token and no agent handle" do
      {spec, regex} = compiled_trigger(DesignBrandCheck)

      assert Regex.match?(regex, "@designer brand check this poster")
      assert Regex.match?(regex, "@DESIGNER BRAND check this poster")

      refute Regex.match?(regex, "@vega brand check this poster")
      refute Regex.match?(regex, "@saru brand check this poster")

      assert spec.metadata["role"] == "designer"
      assert spec.trigger_config["regex"] =~ "@" <> spec.metadata["role"]
    end

    test "does not fire on the role token without the verb" do
      {_spec, regex} = compiled_trigger(DesignBrandCheck)

      refute Regex.match?(regex, "@designer can you take a look?")
      refute Regex.match?(regex, "@designer spec this out")
    end
  end

  describe "both stubs stay registered" do
    test "each module still registers exactly one chat_pattern responsibility" do
      # `Platform.Responsibilities.upsert_by_key/1` has no DELETE path, so a
      # dropped registration would leave a live row matching with no module
      # behind it — strictly worse than a stale token.
      for module <- [DesignSpecWriter, DesignBrandCheck] do
        assert [%{trigger_kind: "chat_pattern"}] = module.register()
      end
    end
  end
end
