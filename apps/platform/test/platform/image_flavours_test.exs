defmodule Platform.ImageFlavoursTest do
  @moduledoc """
  The image flavours (ADR 0055 stage 4, task 01a0ee08): `apps/platform/Dockerfile`
  builds the without-modules image, and each with-modules release host under
  `apps/*/` has its own Dockerfile that builds core plus its modules.

  The flavours may differ in how they BUILD the release, never in what the
  image installs, exposes or runs. So every other image Dockerfile's runtime
  stage must equal core's line for line, except the single
  `COPY --from=build` line that names where its release was built. Without
  this a fix to core's runtime stage (a package, the CMD, the volume) would
  silently miss the image three production installs run.

  The Dockerfiles are globbed, never listed, so core names no module.
  Read as TEXT: this cannot prove an image builds, only that the two files
  did not drift. The builds themselves are CI's `build-and-push` and the
  stage-4 rig (`scripts/module-enable-later-rig.sh`).
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @core_dockerfile Path.join(@repo_root, "apps/platform/Dockerfile")
  @image_dockerfiles Path.wildcard(Path.join(@repo_root, "apps/*/Dockerfile"))

  @runtime_marker "# ── Stage 2: Runtime ──────────────────────────────────────────"
  @release_copy ~r{^COPY --from=build --chown=app:app /app/(\S+/)?_build/prod/rel/platform \./$}

  defp runtime_stage(path) do
    lines = path |> File.read!() |> String.split("\n")

    start =
      Enum.find_index(lines, &(&1 == @runtime_marker)) ||
        flunk("#{Path.relative_to(path, @repo_root)} has no `#{@runtime_marker}` line")

    Enum.drop(lines, start)
  end

  defp normalize(lines), do: Enum.map(lines, &Regex.replace(@release_copy, &1, "<release copy>"))

  test "core's Dockerfile and at least one with-modules Dockerfile are found" do
    # Positive control: the comparison below iterates this list.
    assert @core_dockerfile in @image_dockerfiles
    assert length(@image_dockerfiles) >= 2
  end

  test "every image's runtime stage is core's, except where the release was built" do
    core = runtime_stage(@core_dockerfile)

    assert Enum.count(core, &Regex.match?(@release_copy, &1)) == 1,
           "core's runtime stage no longer has exactly one release COPY line; " <>
             "update @release_copy rather than loosening the comparison"

    for path <- @image_dockerfiles -- [@core_dockerfile] do
      other = runtime_stage(path)
      rel = Path.relative_to(path, @repo_root)

      assert Enum.count(other, &Regex.match?(@release_copy, &1)) == 1,
             "#{rel}: expected exactly one `COPY --from=build ... rel/platform ./` line"

      if normalize(other) != normalize(core) do
        diff =
          List.myers_difference(normalize(core), normalize(other))
          |> Enum.reject(&match?({:eq, _}, &1))

        flunk("#{rel}'s runtime stage differs from core's: #{inspect(diff)}")
      end
    end
  end

  test "the comparison sees a drifted runtime stage" do
    # Positive control for the equality above: one changed package line in a
    # copy of core's runtime stage must be visible to `normalize/1`.
    core = runtime_stage(@core_dockerfile)

    drifted =
      Enum.map(core, &String.replace(&1, "libncurses6", "libncurses5"))

    assert drifted != core, "the probe line `libncurses6` is gone from core's runtime stage"
    refute normalize(drifted) == normalize(core)
  end

  test "every with-modules image builds its release from its own project" do
    for path <- @image_dockerfiles -- [@core_dockerfile] do
      [copy] = path |> runtime_stage() |> Enum.filter(&Regex.match?(@release_copy, &1))
      project = path |> Path.dirname() |> Path.basename()

      assert copy =~ "/app/apps/#{project}/_build/prod/rel/platform",
             "#{Path.relative_to(path, @repo_root)} copies a release it did not build: #{copy}"
    end
  end
end
