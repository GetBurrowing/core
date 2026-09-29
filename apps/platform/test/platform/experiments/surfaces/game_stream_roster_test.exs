defmodule Platform.Experiments.Surfaces.GameStreamRosterTest do
  @moduledoc """
  The `game_stream.roster` surface (task 01a0dbd6 stage 2).

  The control is pinned as a LITERAL, typed from the plan (Saru's watch,
  4 players, 4 spectators), not read back from the module under test.
  """

  use Platform.DataCase

  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.GameStreamRoster

  @plan_control %{"open_as" => "watch", "max_players" => 4, "max_spectators" => 4}

  test "is registered with its key, subject type, path and one target" do
    assert Surfaces.get("game_stream.roster") == GameStreamRoster
    assert GameStreamRoster in Surfaces.list()
    assert GameStreamRoster.subject_type() == "task"
    assert GameStreamRoster.path() == :dispatch
    assert GameStreamRoster.targets() == ["play_session.start"]
  end

  test "the control is the plan's watch / 4 / 4" do
    assert GameStreamRoster.control() == @plan_control
    assert GameStreamRoster.control_payload("play_session.start", []) == {:ok, @plan_control}
    assert {:ok, @plan_control} = GameStreamRoster.validate_payload(@plan_control)
  end

  test "open_as join is a valid data variant" do
    join = %{@plan_control | "open_as" => "join"}
    assert {:ok, ^join} = GameStreamRoster.validate_payload(join)

    assert {:ok, ^join} =
             GameStreamRoster.validate_payload(
               Map.new(join, fn {k, v} -> {String.to_atom(k), v} end)
             )
  end

  test "validate_payload rejects missing, unknown and out-of-range keys" do
    assert {:error, errors} = GameStreamRoster.validate_payload(%{"open_as" => "grab"})
    assert Enum.any?(errors, &(&1 =~ "missing keys"))
    assert Enum.any?(errors, &(&1 =~ "open_as must be watch or join"))

    bad = Map.merge(@plan_control, %{"max_players" => 0, "max_spectators" => 99, "extra" => 1})
    assert {:error, errors} = GameStreamRoster.validate_payload(bad)
    assert Enum.any?(errors, &(&1 =~ "max_players must be an integer in 1..8"))
    assert Enum.any?(errors, &(&1 =~ "max_spectators must be an integer in 0..16"))
    assert Enum.any?(errors, &(&1 =~ "unknown keys: extra"))

    assert {:error, _} = GameStreamRoster.validate_payload("watch")
  end

  test "resolving with no experiment falls to :none, never raising" do
    subject = Subject.new("task", Ecto.UUID.generate())
    assert Surfaces.resolve("game_stream.roster", "play_session.start", subject) == :none
  end

  test "its worst-slot p95 metric is registered, lower is better" do
    assert Metrics.metric_module("game_stream_input_to_photon_worst_slot_p95") ==
             Platform.Experiments.Metrics.GameStreamInputToPhotonP95

    assert %{direction: :lower_is_better} =
             Enum.find(
               Metrics.catalog(),
               &(&1.slug == "game_stream_input_to_photon_worst_slot_p95")
             )
  end
end
