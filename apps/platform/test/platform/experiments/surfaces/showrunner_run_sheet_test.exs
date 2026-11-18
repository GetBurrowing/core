defmodule Platform.Experiments.Surfaces.ShowrunnerRunSheetTest do
  @moduledoc "Task 01a1eaf6 stage 1: the `showrunner.run_sheet` surface."

  use ExUnit.Case, async: true

  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.ShowrunnerRunSheet, as: S

  test "is a registered core surface with its key, subject, path and one target" do
    assert Surfaces.get("showrunner.run_sheet") == S
    assert S in Surfaces.core_surfaces()
    assert S.subject_type() == "episode"
    assert S.path() == :dispatch
    assert S.targets() == ["showrunner.run_sheet"]
    assert {:ok, _} = Jason.encode(S.payload_schema())
    assert S.payload_schema()["required"] == ["prompt_slug"]
  end

  test "the control is the seeded v1 slug with no directive" do
    assert {:ok, %{"prompt_slug" => "showrunner.run_sheet.v1", "directive" => nil} = control} =
             S.control_payload("showrunner.run_sheet")

    assert map_size(control) == 2
    assert S.validate_payload(control) == {:ok, control}
    assert S.render_directive(control) == nil
  end

  test "validate_payload normalises a good payload" do
    assert {:ok, %{"prompt_slug" => "showrunner.run_sheet.v2", "directive" => "Open cold."}} =
             S.validate_payload(%{
               prompt_slug: "showrunner.run_sheet.v2",
               directive: " Open cold. "
             })

    assert {:ok, %{"directive" => nil}} =
             S.validate_payload(%{"prompt_slug" => "showrunner.run_sheet.v1", "directive" => " "})

    assert S.render_directive(%{"directive" => " Open cold. "}) == "Open cold."
  end

  test "validate_payload refuses bad payloads" do
    slug_error =
      "prompt_slug must be a string starting with showrunner.run_sheet (at most 128 chars)"

    assert {:error, [^slug_error]} = S.validate_payload(%{})
    assert {:error, [^slug_error]} = S.validate_payload(%{"prompt_slug" => "dispatch.v1"})
    assert {:error, [^slug_error]} = S.validate_payload(%{"prompt_slug" => 7})

    assert {:error, ["unknown keys: model"]} =
             S.validate_payload(%{"prompt_slug" => "showrunner.run_sheet.v1", "model" => "x"})

    assert {:error, ["directive must be a string or null"]} =
             S.validate_payload(%{"prompt_slug" => "showrunner.run_sheet.v1", "directive" => 7})

    assert {:error, ["directive must be at most 4000 chars"]} =
             S.validate_payload(%{
               "prompt_slug" => "showrunner.run_sheet.v1",
               "directive" => String.duplicate("d", 4001)
             })

    assert {:error, ["payload must be an object"]} = S.validate_payload("x")
  end
end
