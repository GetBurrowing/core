# Every build-time module and release host must lock core's dependencies
# exactly as core does (task 01a0ee08; the "Two lockfiles" cost in
# `0055-extension-contract-and-build-time-modules.md § 1. A module is its own Mix project; core takes no dependency on it`).
#
# Mix ignores a path dependency's lockfile, so `apps/<module>/mix.lock`
# resolves core's tree independently of `apps/platform/mix.lock`; nothing but
# this check keeps the with-modules build on the versions the without-modules
# build tested. Every entry in core's lockfile must appear, unchanged, in each
# other `apps/*/mix.lock`. Extra entries (a module's own deps) are allowed.
#
# Run from the repo root: `elixir scripts/check-module-lockfiles.exs`.
# Mirrors apps/platform/test/platform/module_lockfiles_test.exs.

read_lock = fn path ->
  # As Mix reads it: quoted keys are mix.lock's own format, so no warnings.
  {lock, _binding} =
    path |> File.read!() |> Code.string_to_quoted!(emit_warnings: false) |> Code.eval_quoted()

  lock
end

core_path = "apps/platform/mix.lock"
core = read_lock.(core_path)

others =
  "apps/*/mix.lock"
  |> Path.wildcard()
  |> Enum.reject(&(&1 == core_path))
  |> Enum.sort()

if others == [] do
  IO.puts(
    "::error::no module or host lockfile found next to #{core_path}; is this the repo root?"
  )

  System.halt(1)
end

describe = fn
  nil -> "absent"
  entry when is_tuple(entry) and tuple_size(entry) >= 3 -> inspect(elem(entry, 2))
  entry -> inspect(entry)
end

failures =
  Enum.flat_map(others, fn path ->
    lock = read_lock.(path)

    for {dep, entry} <- Enum.sort(core), Map.get(lock, dep) != entry do
      "#{path}: #{dep} is #{describe.(Map.get(lock, dep))}, core locks #{describe.(entry)}"
    end
  end)

case failures do
  [] ->
    IO.puts("lockfiles agree: #{map_size(core)} core entries in #{Enum.join(others, ", ")}")

  _ ->
    IO.puts("::error::#{length(failures)} lockfile entr(ies) drift from #{core_path}:")
    Enum.each(failures, &IO.puts("  " <> &1))

    IO.puts(
      "Copy apps/platform/mix.lock over the drifting file and rerun `mix deps.get` there; " <>
        "a module's own deps are re-added on top."
    )

    System.halt(1)
end
