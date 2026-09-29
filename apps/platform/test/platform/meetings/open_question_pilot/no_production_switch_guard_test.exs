defmodule Platform.Meetings.OpenQuestionPilot.NoProductionSwitchGuardTest do
  @moduledoc """
  The pilot's stop rule, enforced (task 01a0e8b5 stage 4): nothing in core
  may switch production to the Imp arm. No migration, seed or config file
  names the `meetings.open_question_classifier` surface, and after every
  migration has run there is no experiment and no surface default on it.
  An experiment on the surface is a human's data change, never a deploy.
  """
  use Platform.DataCase, async: true

  alias Platform.Experiments.Experiment
  alias Platform.Experiments.SurfaceDefault

  @surface "meetings.open_question_classifier"
  @app_root Path.expand("../../../..", __DIR__)

  # Files that create or configure rows, and so must never mention the surface.
  @forbidden_globs [
    "priv/repo/migrations/**/*",
    "priv/repo/seeds/**/*",
    "priv/repo/*.exs",
    "config/**/*",
    "lib/**/seed*.ex",
    "lib/mix/tasks/**/*"
  ]

  test "no migration, seed, config or mix task names the surface" do
    files =
      @forbidden_globs
      |> Enum.flat_map(&Path.wildcard(Path.join(@app_root, &1)))
      |> Enum.filter(&File.regular?/1)
      |> Enum.uniq()

    # A scan of zero files would pass vacuously.
    assert Enum.any?(files, &String.contains?(&1, "priv/repo/migrations/"))
    assert Enum.any?(files, &String.contains?(&1, "config/runtime.exs"))

    hits =
      for file <- files, File.read!(file) =~ @surface, do: Path.relative_to(file, @app_root)

    assert hits == []
  end

  test "after all migrations there is no experiment and no default on the surface" do
    assert Repo.all(from(e in Experiment, where: e.surface_key == ^@surface)) == []
    assert Repo.all(from(d in SurfaceDefault, where: d.surface_key == ^@surface)) == []
  end
end
