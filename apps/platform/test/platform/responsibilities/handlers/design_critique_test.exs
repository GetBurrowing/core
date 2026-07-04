defmodule Platform.Responsibilities.Handlers.DesignCritiqueTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.DesignCritique` — the
  Designer bundle's registration-only placeholder that fills out the
  `design.critique` responsibility row so `Platform.Roles.Seeds` no
  longer references a key with no matching `responsibilities` row.

  Runtime lands in a follow-up ticket; this test file locks the spec
  shape + no-op behaviour so downstream stages catch drift.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers.DesignCritique
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: DesignCritique.key(),
      feature: "design",
      trigger_kind: "chat_pattern",
      trigger_config: %{"regex" => "(?i)@vega\\s+(critique|review)\\b"},
      scope: "per_space",
      context_provided: ["canvas_snapshot", "grounding_notes"],
      enabled: true
    }
  end

  describe "register/0" do
    test "returns exactly one spec with the canonical key + feature" do
      specs = DesignCritique.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "design.critique"
      assert spec.feature == "design"
      assert spec.trigger_kind == "chat_pattern"
      assert spec.trigger_config == %{"regex" => "(?i)@vega\\s+(critique|review)\\b"}
      assert spec.scope == "per_space"
      assert spec.context_provided == ["canvas_snapshot", "grounding_notes"]
      assert spec.default_prompt_template == "design.critique.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "output_contract is a map of string values — satisfies the M1 schema invariant" do
      [spec] = DesignCritique.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)
    end

    test "metadata flags the placeholder + names the owner + role" do
      [spec] = DesignCritique.register()

      assert spec.metadata["owner"] == "platform.design"
      assert spec.metadata["status"] == "placeholder"
      assert spec.metadata["role"] == "designer"
    end
  end

  describe "gather_context/2" do
    test "returns missing? slots for canvas_snapshot and grounding_notes" do
      assert {:ok, ctx} = DesignCritique.gather_context(responsibility(), %{})
      assert Map.has_key?(ctx, :canvas_snapshot)
      assert Map.has_key?(ctx, :grounding_notes)
      assert ctx.canvas_snapshot.missing? == true
      assert ctx.grounding_notes.missing? == true
    end
  end

  describe "handle_output/3" do
    test "logs the placeholder line and returns :ok" do
      log =
        capture_log(fn ->
          assert :ok =
                   DesignCritique.handle_output(
                     responsibility(),
                     %{"issues" => []},
                     %{kind: :chat_pattern}
                   )
        end)

      assert log =~ "[design.critique]"
      assert log =~ "placeholder handler"
      assert log =~ "design.critique.v1"
    end
  end

  describe "handle_output/2" do
    test "arity-2 delegates to arity-3" do
      log =
        capture_log(fn ->
          assert :ok = DesignCritique.handle_output(responsibility(), %{"issues" => []})
        end)

      assert log =~ "[design.critique]"
      assert log =~ "placeholder handler"
    end
  end

  describe "key/0 and template_slug/0" do
    test "key/0 matches the registered spec key" do
      [spec] = DesignCritique.register()
      assert DesignCritique.key() == spec.key
      assert DesignCritique.key() == "design.critique"
    end

    test "template_slug/0 matches the registered default_prompt_template" do
      [spec] = DesignCritique.register()
      assert DesignCritique.template_slug() == spec.default_prompt_template
      assert DesignCritique.template_slug() == "design.critique.v1"
    end
  end
end
