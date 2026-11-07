defmodule Platform.Experiments.Surfaces.LearnedDefaultsTest do
  @moduledoc "Task 01a1b6a1 stage 1: the `habits.learned_defaults` surface."

  use Platform.DataCase, async: true

  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.LearnedDefaults, as: S

  @control %{
    "prefill_threshold" => 0.6,
    "min_signals" => 3,
    "act_after_accepts" => 5,
    "half_life_days" => 30
  }

  test "is registered with its key, subject, path and one target" do
    assert Surfaces.get("habits.learned_defaults") == S
    assert S in Surfaces.core_surfaces()
    assert S.subject_type() == "user"
    assert S.path() == :draft
    assert S.targets() == ["chat.message_attention"]
    assert {:ok, _} = Jason.encode(S.payload_schema())
  end

  test "the control payload is the four literals" do
    assert {:ok, control} = S.control_payload("chat.message_attention")
    assert control == @control
  end

  test "validate_payload accepts the control and normalises atom keys" do
    assert {:ok, @control} = S.validate_payload(@control)

    assert {:ok,
            %{
              "prefill_threshold" => 1.0,
              "min_signals" => 1,
              "act_after_accepts" => 50,
              "half_life_days" => 365
            }} =
             S.validate_payload(%{
               prefill_threshold: 1,
               min_signals: 1,
               act_after_accepts: 50,
               half_life_days: 365
             })

    assert {:ok, %{"prefill_threshold" => +0.0}} = S.validate_payload(%{"prefill_threshold" => 0})
  end

  test "validate_payload refuses an out-of-range threshold" do
    assert {:error, ["prefill_threshold must be a number in 0..1"]} =
             S.validate_payload(%{"prefill_threshold" => 1.01})

    assert {:error, ["prefill_threshold must be a number in 0..1"]} =
             S.validate_payload(%{"prefill_threshold" => -0.1})

    assert {:error, ["prefill_threshold must be a number in 0..1"]} =
             S.validate_payload(%{"prefill_threshold" => "0.6"})
  end

  test "validate_payload refuses the integer knobs outside their ranges" do
    assert {:error, ["min_signals must be an integer in 1..50"]} =
             S.validate_payload(%{"min_signals" => 0})

    assert {:error, ["min_signals must be an integer in 1..50"]} =
             S.validate_payload(%{"min_signals" => 51})

    assert {:error, ["act_after_accepts must be an integer in 1..50"]} =
             S.validate_payload(%{"act_after_accepts" => 51})

    assert {:error, ["half_life_days must be an integer in 1..365"]} =
             S.validate_payload(%{"half_life_days" => 366})

    assert {:error, ["half_life_days must be an integer in 1..365"]} =
             S.validate_payload(%{"half_life_days" => 30.5})
  end

  test "validate_payload refuses an unknown key" do
    assert {:error, ["unknown keys: auto_act"]} = S.validate_payload(%{"auto_act" => true})
    assert {:error, ["payload must be an object"]} = S.validate_payload("x")
  end

  test "habits.prefill_accept_rate is registered" do
    assert "habits.prefill_accept_rate" in Metrics.known_metrics()

    assert Metrics.metric_module("habits.prefill_accept_rate") ==
             Platform.Experiments.Metrics.PrefillAcceptRate
  end
end
