defmodule Platform.ModuleLockfilesTest do
  @moduledoc """
  Every build-time module and release host locks core's dependencies exactly
  as core does (ADR 0055, task 01a0ee08 stage 3; the "Two lockfiles" cost in
  `0055-extension-contract-and-build-time-modules.md § 1. A module is its own Mix project; core takes no dependency on it`).

  Mix ignores a path dependency's lockfile, so `apps/<module>/mix.lock`
  resolves core's tree on its own. The stage 1 spike measured what that does
  when nothing enforces agreement: at least 40 of core's packages differed
  (`phoenix` 1.8.5 against 1.8.15, `postgrex` 0.22.0 against 0.22.4). A
  with-modules build would then ship versions the without-modules suite
  never ran. Every entry in `apps/platform/mix.lock` must therefore appear,
  unchanged, in each other `apps/*/mix.lock`. Extra entries (a module's own
  deps) are allowed.

  The listing is every lockfile on disk, not the configured modules, so core
  names no module here. The CI step "Check module lockfiles against core's"
  (`scripts/check-module-lockfiles.exs`) runs the same check before any build.
  """

  use ExUnit.Case, async: true

  @platform_root Path.expand("../..", __DIR__)
  @apps_root Path.expand("..", @platform_root)
  @core_lock Path.join(@platform_root, "mix.lock")

  defp read_lock(path) do
    # As Mix reads it: quoted keys are mix.lock's own format, so no warnings.
    {lock, _binding} =
      path |> File.read!() |> Code.string_to_quoted!(emit_warnings: false) |> Code.eval_quoted()

    lock
  end

  defp other_lockfiles do
    @apps_root
    |> Path.join("*/mix.lock")
    |> Path.wildcard()
    |> Enum.reject(&(&1 == @core_lock))
    |> Enum.sort()
  end

  @doc false
  # The entries of `core` that `other` lacks or locks differently, as
  # `{dep, other_entry_or_nil, core_entry}`.
  def drift(core, other) do
    for {dep, entry} <- Enum.sort(core), Map.get(other, dep) != entry do
      {dep, Map.get(other, dep), entry}
    end
  end

  defp version(nil), do: "absent"
  defp version(entry) when is_tuple(entry) and tuple_size(entry) >= 3, do: inspect(elem(entry, 2))
  defp version(entry), do: inspect(entry)

  test "at least one module or host lockfile sits beside core's" do
    assert other_lockfiles() != [],
           "no apps/*/mix.lock beside #{@core_lock}: the check below would pass vacuously"
  end

  test "every module and host lockfile locks core's entries exactly as core does" do
    core = read_lock(@core_lock)

    report =
      for path <- other_lockfiles(),
          {dep, theirs, ours} <- drift(core, read_lock(path)) do
        "  #{Path.relative_to(path, @apps_root)}: #{dep} is #{version(theirs)}, core locks #{version(ours)}"
      end

    assert report == [],
           """
           #{length(report)} lockfile entr(ies) drift from apps/platform/mix.lock:

           #{Enum.join(report, "\n")}

           Copy apps/platform/mix.lock over the drifting file and rerun
           `mix deps.get` in that app; its own deps are re-added on top.
           """
  end

  describe "drift/2 (positive control: the comparison can fire)" do
    @entry {:hex, :phoenix, "1.8.5", "aa", [:mix], [], "hexpm", "bb"}

    test "an identical lock has no drift, and extra entries are allowed" do
      core = %{phoenix: @entry}
      assert drift(core, core) == []
      assert drift(core, Map.put(core, :module_only_dep, @entry)) == []
    end

    test "a different version is drift" do
      bumped = put_elem(@entry, 2, "1.8.15")
      assert drift(%{phoenix: @entry}, %{phoenix: bumped}) == [{:phoenix, bumped, @entry}]
    end

    test "a missing entry is drift" do
      assert drift(%{phoenix: @entry}, %{}) == [{:phoenix, nil, @entry}]
    end
  end
end
