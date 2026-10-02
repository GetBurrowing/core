defmodule Platform.Experiments.Surfaces.GameStreamEncoderTest do
  @moduledoc """
  The `game_stream.encoder_preset` surface (task 01a0db5f stage 2).

  The control is pinned as a LITERAL: stage 1's measured winner, typed from
  that stage's recorded evidence (`chosen_control_preset`), not read back
  from the module under test.
  """

  use Platform.DataCase

  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.GameStreamEncoder

  @stage1_control %{
    "preset" => "p1",
    "tune" => "ll",
    "bitrate_kbps" => 8000,
    "fps" => 60,
    "width" => 1280,
    "height" => 720,
    "gop_frames" => 120
  }

  test "is registered with its key, subject type, path and one target" do
    assert Surfaces.get("game_stream.encoder_preset") == GameStreamEncoder
    assert GameStreamEncoder.subject_type() == "task"
    assert GameStreamEncoder.path() == :dispatch
    assert GameStreamEncoder.targets() == ["play_session.start"]
  end

  test "the control is stage 1's chosen preset" do
    assert GameStreamEncoder.control() == @stage1_control
    assert GameStreamEncoder.control_payload("play_session.start", []) == {:ok, @stage1_control}
    assert {:ok, @stage1_control} = GameStreamEncoder.validate_payload(@stage1_control)
  end

  test "validate_payload rejects missing, unknown and out-of-range keys" do
    assert {:error, errors} = GameStreamEncoder.validate_payload(%{"preset" => "p9"})
    assert Enum.any?(errors, &(&1 =~ "missing keys"))
    assert Enum.any?(errors, &(&1 =~ "preset must be one of"))

    bad = Map.merge(@stage1_control, %{"tune" => "hq", "fps" => 500, "extra" => 1})
    assert {:error, errors} = GameStreamEncoder.validate_payload(bad)
    assert Enum.any?(errors, &(&1 =~ "tune must be"))
    assert Enum.any?(errors, &(&1 =~ "fps must be an integer"))
    assert Enum.any?(errors, &(&1 =~ "unknown keys: extra"))

    assert {:error, _} = GameStreamEncoder.validate_payload("p1")
  end

  test "resolving with no experiment falls to :none, never raising" do
    subject = Subject.new("task", Ecto.UUID.generate())
    assert Surfaces.resolve("game_stream.encoder_preset", "play_session.start", subject) == :none
  end
end
