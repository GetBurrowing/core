defmodule Platform.Experiments.Surfaces.HrProfileTest do
  @moduledoc "Task 01a1aa47 stage 4: the `hr.profile` surface."

  use Platform.DataCase, async: true

  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.HrProfile, as: S

  test "is registered with its key, subject, path and one target" do
    assert Surfaces.get("hr.profile") == S
    assert S.subject_type() == "workspace"
    assert S.path() == :dispatch
    assert S.targets() == ["hr.profile"]
    assert {:ok, _} = Jason.encode(S.payload_schema())
  end

  test "the control is no directive, 30 days and a 0.84 threshold" do
    assert {:ok,
            %{"directive" => nil, "staleness_days" => 30, "fuzzy_threshold" => 0.84} = control} =
             S.control_payload("hr.profile")

    assert map_size(control) == 3
    assert S.render_directive(S.control()) == nil
  end

  test "validate_payload normalises a good payload and fills the control's values" do
    assert {:ok,
            %{"directive" => "Favour recency.", "staleness_days" => 7, "fuzzy_threshold" => 0.9}} =
             S.validate_payload(%{
               directive: " Favour recency. ",
               staleness_days: 7,
               fuzzy_threshold: 0.9
             })

    assert {:ok, %{"directive" => nil, "staleness_days" => 30, "fuzzy_threshold" => 0.84}} =
             S.validate_payload(%{"directive" => "   "})

    assert S.render_directive(%{"directive" => "  Favour recency. "}) == "Favour recency."
  end

  test "validate_payload refuses bad payloads" do
    assert {:error, ["unknown keys: model"]} = S.validate_payload(%{"model" => "big"})

    assert {:error, ["directive must be a string or null"]} =
             S.validate_payload(%{"directive" => 7})

    assert {:error, ["directive must be at most 4000 chars"]} =
             S.validate_payload(%{"directive" => String.duplicate("d", 4001)})

    assert {:error, ["staleness_days must be an integer in 1..90"]} =
             S.validate_payload(%{"staleness_days" => 0})

    assert {:error, ["staleness_days must be an integer in 1..90"]} =
             S.validate_payload(%{"staleness_days" => 91})

    assert {:error, ["fuzzy_threshold must be a number in 0.70..0.99"]} =
             S.validate_payload(%{"fuzzy_threshold" => 0.5})

    assert {:error, ["payload must be an object"]} = S.validate_payload("x")
  end
end
