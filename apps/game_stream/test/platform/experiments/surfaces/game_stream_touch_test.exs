defmodule Platform.Experiments.Surfaces.GameStreamTouchTest do
  @moduledoc """
  The `game_stream.touch` surface (task 01a0fe45 stage 1).

  The control and the ranges are pinned as LITERALS, typed from the plan
  (slop 8 px in 0..32, 60 moves/s in 15..120), not read back from the
  module under test.
  """

  use Platform.DataCase

  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.GameStreamTouch

  @plan_control %{"slop_px" => 8, "move_hz" => 60}

  test "is registered with its key, subject type, path and one target" do
    assert Surfaces.get("game_stream.touch") == GameStreamTouch
    assert GameStreamTouch in Surfaces.list()
    assert GameStreamTouch.subject_type() == "task"
    assert GameStreamTouch.path() == :dispatch
    assert GameStreamTouch.targets() == ["play_session.start"]
  end

  test "the control is the plan's 8 px slop and 60 moves per second" do
    assert GameStreamTouch.control() == @plan_control
    assert GameStreamTouch.control_payload("play_session.start", []) == {:ok, @plan_control}
    assert {:ok, @plan_control} = GameStreamTouch.validate_payload(@plan_control)
  end

  test "atom keys are accepted and normalised to strings" do
    assert {:ok, @plan_control} = GameStreamTouch.validate_payload(%{slop_px: 8, move_hz: 60})
  end

  test "the range edges are valid; one past each edge is not" do
    for slop <- [0, 32], hz <- [15, 120] do
      payload = %{"slop_px" => slop, "move_hz" => hz}
      assert {:ok, ^payload} = GameStreamTouch.validate_payload(payload)
    end

    assert {:error, errors} =
             GameStreamTouch.validate_payload(%{"slop_px" => -1, "move_hz" => 14})

    assert "slop_px must be an integer in 0..32" in errors
    assert "move_hz must be an integer in 15..120" in errors

    assert {:error, errors} =
             GameStreamTouch.validate_payload(%{"slop_px" => 33, "move_hz" => 121})

    assert "slop_px must be an integer in 0..32" in errors
    assert "move_hz must be an integer in 15..120" in errors

    assert {:error, errors} =
             GameStreamTouch.validate_payload(%{"slop_px" => 8.0, "move_hz" => "60"})

    assert length(errors) == 2
  end

  test "validate_payload rejects missing and unknown keys, and a non-map" do
    assert {:error, errors} = GameStreamTouch.validate_payload(%{"slop_px" => 8})
    assert "missing keys: move_hz" in errors

    assert {:error, errors} =
             GameStreamTouch.validate_payload(Map.put(@plan_control, "long_press_ms", 500))

    assert "unknown keys: long_press_ms" in errors

    assert {:error, errors} = GameStreamTouch.validate_payload(%{})
    assert "missing keys: slop_px, move_hz" in errors

    assert {:error, ["payload must be an object"]} = GameStreamTouch.validate_payload(8)
  end

  test "the schema requires both keys and states the plan's ranges" do
    schema = GameStreamTouch.payload_schema()
    assert schema["required"] == ["slop_px", "move_hz"]

    assert %{"minimum" => 0, "maximum" => 32, "type" => "integer"} =
             schema["properties"]["slop_px"]

    assert %{"minimum" => 15, "maximum" => 120, "type" => "integer"} =
             schema["properties"]["move_hz"]
  end

  test "resolving with no experiment falls to :none, never raising" do
    subject = Subject.new("task", Ecto.UUID.generate())
    assert Surfaces.resolve("game_stream.touch", "play_session.start", subject) == :none
  end
end
