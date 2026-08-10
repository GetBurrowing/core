defmodule Platform.Responsibilities.Handlers.DesignBrandCheckTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.DesignBrandCheck` — the
  Designer bundle's registration-only placeholder that fills out the
  `design.brand_check` responsibility row.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers.DesignBrandCheck
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: DesignBrandCheck.key(),
      feature: "design",
      trigger_kind: "chat_pattern",
      trigger_config: %{"regex" => "(?i)@designer\\s+brand\\b"},
      scope: "per_space",
      context_provided: ["canvas_snapshot", "brand_guidelines"],
      enabled: true
    }
  end

  describe "register/0" do
    test "returns exactly one spec with the canonical key + feature" do
      specs = DesignBrandCheck.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "design.brand_check"
      assert spec.feature == "design"
      assert spec.trigger_kind == "chat_pattern"
      assert spec.trigger_config == %{"regex" => "(?i)@designer\\s+brand\\b"}
      assert spec.scope == "per_space"
      assert spec.context_provided == ["canvas_snapshot", "brand_guidelines"]
      assert spec.default_prompt_template == "design.brand_check.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "output_contract is a map of string values" do
      [spec] = DesignBrandCheck.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value)
      end)

      assert Map.has_key?(spec.output_contract, "verdict")
      assert Map.has_key?(spec.output_contract, "reasons")
      assert Map.has_key?(spec.output_contract, "fixes")
    end

    test "metadata flags the placeholder + names the owner + role" do
      [spec] = DesignBrandCheck.register()

      assert spec.metadata["owner"] == "platform.design"
      assert spec.metadata["status"] == "placeholder"
      assert spec.metadata["role"] == "designer"
    end
  end

  describe "gather_context/2" do
    test "returns missing? slots for canvas_snapshot and brand_guidelines" do
      assert {:ok, ctx} = DesignBrandCheck.gather_context(responsibility(), %{})
      assert ctx.canvas_snapshot.missing? == true
      assert ctx.brand_guidelines.missing? == true
    end
  end

  describe "handle_output/3" do
    test "logs the placeholder line and returns :ok" do
      log =
        capture_log(fn ->
          assert :ok =
                   DesignBrandCheck.handle_output(
                     responsibility(),
                     %{"verdict" => "on_brand"},
                     %{kind: :chat_pattern}
                   )
        end)

      assert log =~ "[design.brand_check]"
      assert log =~ "placeholder handler"
      assert log =~ "design.brand_check.v1"
    end
  end

  describe "handle_output/2" do
    test "arity-2 delegates to arity-3" do
      log =
        capture_log(fn ->
          assert :ok = DesignBrandCheck.handle_output(responsibility(), %{"verdict" => "drift"})
        end)

      assert log =~ "[design.brand_check]"
    end
  end

  describe "key/0 and template_slug/0" do
    test "match the registered spec" do
      [spec] = DesignBrandCheck.register()
      assert DesignBrandCheck.key() == "design.brand_check"
      assert DesignBrandCheck.template_slug() == spec.default_prompt_template
      assert DesignBrandCheck.template_slug() == "design.brand_check.v1"
    end
  end
end
