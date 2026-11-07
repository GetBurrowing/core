defmodule Platform.Experiments.Surfaces.UxFrictionDetectionTest do
  @moduledoc "Task 01a1af00 stage 1: the `ux.friction_detection` surface."

  use Platform.DataCase, async: true

  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.UxFrictionDetection, as: S

  test "is registered with its key, subject, path and one target" do
    assert Surfaces.get("ux.friction_detection") == S
    assert S.subject_type() == "workspace"
    assert S.path() == :dispatch
    assert S.targets() == ["ux.friction_detection"]
    assert {:ok, _} = Jason.encode(S.payload_schema())
  end

  test "its metric is registered and computable" do
    assert S.metric() in Metrics.known_metrics()
    assert Metrics.metric_module(S.metric()) == Platform.Experiments.Metrics.UxFindingKeepRate
  end

  test "the control is no directive, a 0.80 threshold and three occurrences" do
    assert {:ok,
            %{"directive" => nil, "grouping_threshold" => 0.8, "min_occurrences" => 3} = control} =
             S.control_payload("ux.friction_detection")

    assert map_size(control) == 3
    assert S.render_directive(S.control()) == nil
    assert {:ok, ^control} = S.validate_payload(control)
  end

  test "validate_payload normalises a good payload and fills the control's values" do
    assert {:ok,
            %{
              "directive" => "Count only repeated asks.",
              "grouping_threshold" => 0.9,
              "min_occurrences" => 5
            }} =
             S.validate_payload(%{
               directive: " Count only repeated asks. ",
               grouping_threshold: 0.9,
               min_occurrences: 5
             })

    assert {:ok, %{"directive" => nil, "grouping_threshold" => 0.8, "min_occurrences" => 3}} =
             S.validate_payload(%{"directive" => "   "})

    assert {:ok, %{"grouping_threshold" => 1.0 / 2}} =
             S.validate_payload(%{"grouping_threshold" => 0.5})

    assert S.render_directive(%{"directive" => "  Be strict. "}) == "Be strict."
  end

  test "validate_payload refuses bad payloads" do
    assert {:error, ["unknown keys: model"]} = S.validate_payload(%{"model" => "big"})

    assert {:error, ["directive must be a string or null"]} =
             S.validate_payload(%{"directive" => 7})

    assert {:error, ["directive must be at most 4000 chars"]} =
             S.validate_payload(%{"directive" => String.duplicate("d", 4001)})

    for bad <- [0.49, 1.0, "0.8"] do
      assert {:error, ["grouping_threshold must be a number in 0.50..0.99"]} =
               S.validate_payload(%{"grouping_threshold" => bad})
    end

    for bad <- [0, 21, 2.5] do
      assert {:error, ["min_occurrences must be an integer in 1..20"]} =
               S.validate_payload(%{"min_occurrences" => bad})
    end

    assert {:error, ["payload must be an object"]} = S.validate_payload("x")
  end
end
