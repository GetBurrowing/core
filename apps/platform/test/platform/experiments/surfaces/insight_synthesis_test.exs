defmodule Platform.Experiments.Surfaces.InsightSynthesisTest do
  @moduledoc "Task 01a13867 stage 1: the `memory.insight_synthesis` surface and its metric."

  use Platform.DataCase, async: true

  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.InsightSynthesis, as: S

  test "is registered with its key, subject, path and one target" do
    assert Surfaces.get("memory.insight_synthesis") == S
    assert S.subject_type() == "dreaming_run"
    assert S.path() == :dispatch
    assert S.targets() == ["memory.dreaming"]
    assert {:ok, _} = Jason.encode(S.payload_schema())
  end

  test "the control is no directive, min_confidence high and auto_apply_min_confidence medium" do
    assert {:ok,
            %{
              "directive" => nil,
              "min_confidence" => "high",
              "auto_apply_min_confidence" => "medium"
            } = control} = S.control_payload("memory.dreaming")

    assert map_size(control) == 3

    assert S.payload_schema()["properties"]["auto_apply_min_confidence"]["enum"] ==
             ~w(high medium low)

    assert S.render_directive(%{"directive" => nil, "min_confidence" => "high"}) == nil
  end

  test "validate_payload normalises a good payload" do
    assert {:ok, %{"directive" => "Ask more.", "min_confidence" => "medium"}} =
             S.validate_payload(%{directive: "  Ask more. ", min_confidence: "medium"})

    assert {:ok, %{"directive" => nil, "min_confidence" => "low"}} =
             S.validate_payload(%{"directive" => "   ", "min_confidence" => "low"})

    assert {:ok, %{"auto_apply_min_confidence" => "high"}} =
             S.validate_payload(%{
               "min_confidence" => "high",
               "auto_apply_min_confidence" => "high"
             })

    # Absent means the control's value, so a variant written before the key
    # existed stays valid.
    assert {:ok, %{"auto_apply_min_confidence" => "medium"}} =
             S.validate_payload(%{"min_confidence" => "high"})
  end

  test "an invalid auto_apply_min_confidence is refused" do
    for bad <- ["certain", nil, 3] do
      assert {:error, ["auto_apply_min_confidence must be one of: high, medium, low"]} =
               S.validate_payload(%{
                 "min_confidence" => "high",
                 "auto_apply_min_confidence" => bad
               })
    end
  end

  test "validate_payload refuses bad payloads" do
    assert {:error, ["min_confidence must be one of: high, medium, low"]} =
             S.validate_payload(%{"directive" => "x"})

    assert {:error, ["unknown keys: model"]} =
             S.validate_payload(%{"min_confidence" => "high", "model" => "big"})

    assert {:error, ["directive must be a string or null"]} =
             S.validate_payload(%{"min_confidence" => "high", "directive" => 7})

    assert {:error, ["directive must be at most 4000 chars"]} =
             S.validate_payload(%{
               "min_confidence" => "high",
               "directive" => String.duplicate("d", 4001)
             })

    assert {:error, ["payload must be an object"]} = S.validate_payload("x")
  end

  test "a treatment directive is rendered" do
    assert S.render_directive(%{"directive" => "Prefer questions.", "min_confidence" => "high"}) ==
             "Prefer questions."
  end

  test "insight_acceptance_rate is registered and reports no data as :insufficient_data" do
    assert "insight_acceptance_rate" in Metrics.known_metrics()

    assert Metrics.metric_module("insight_acceptance_rate") ==
             Metrics.InsightAcceptanceRate

    assert :insufficient_data =
             Metrics.InsightAcceptanceRate.compute(Ecto.UUID.generate(), "control")
  end
end
