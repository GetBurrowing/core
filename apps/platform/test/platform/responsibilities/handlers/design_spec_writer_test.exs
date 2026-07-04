defmodule Platform.Responsibilities.Handlers.DesignSpecWriterTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.DesignSpecWriter` — the
  Designer bundle's registration-only placeholder that fills out the
  `design.spec_writer` responsibility row.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers.DesignSpecWriter
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: DesignSpecWriter.key(),
      feature: "design",
      trigger_kind: "chat_pattern",
      trigger_config: %{"regex" => "(?i)@vega\\s+spec\\b"},
      scope: "per_space",
      context_provided: ["canvas_snapshot", "grounding_notes"],
      enabled: true
    }
  end

  describe "register/0" do
    test "returns exactly one spec with the canonical key + feature" do
      specs = DesignSpecWriter.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "design.spec_writer"
      assert spec.feature == "design"
      assert spec.trigger_kind == "chat_pattern"
      assert spec.trigger_config == %{"regex" => "(?i)@vega\\s+spec\\b"}
      assert spec.scope == "per_space"
      assert spec.context_provided == ["canvas_snapshot", "grounding_notes"]
      assert spec.default_prompt_template == "design.spec_writer.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "output_contract is a map of string values" do
      [spec] = DesignSpecWriter.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value)
      end)
    end

    test "metadata flags the placeholder + names the owner + role" do
      [spec] = DesignSpecWriter.register()

      assert spec.metadata["owner"] == "platform.design"
      assert spec.metadata["status"] == "placeholder"
      assert spec.metadata["role"] == "designer"
    end
  end

  describe "gather_context/2" do
    test "returns missing? slots for canvas_snapshot and grounding_notes" do
      assert {:ok, ctx} = DesignSpecWriter.gather_context(responsibility(), %{})
      assert ctx.canvas_snapshot.missing? == true
      assert ctx.grounding_notes.missing? == true
    end
  end

  describe "handle_output/3" do
    test "logs the placeholder line and returns :ok" do
      log =
        capture_log(fn ->
          assert :ok =
                   DesignSpecWriter.handle_output(
                     responsibility(),
                     %{"spec" => %{}},
                     %{kind: :chat_pattern}
                   )
        end)

      assert log =~ "[design.spec_writer]"
      assert log =~ "placeholder handler"
      assert log =~ "design.spec_writer.v1"
    end
  end

  describe "handle_output/2" do
    test "arity-2 delegates to arity-3" do
      log =
        capture_log(fn ->
          assert :ok = DesignSpecWriter.handle_output(responsibility(), %{"spec" => %{}})
        end)

      assert log =~ "[design.spec_writer]"
    end
  end

  describe "key/0 and template_slug/0" do
    test "match the registered spec" do
      [spec] = DesignSpecWriter.register()
      assert DesignSpecWriter.key() == "design.spec_writer"
      assert DesignSpecWriter.template_slug() == spec.default_prompt_template
      assert DesignSpecWriter.template_slug() == "design.spec_writer.v1"
    end
  end
end
