defmodule Platform.Memory.MemoryServiceEnvAsyncGuardTest do
  @moduledoc """
  Task 01a0feff — the `:platform` app env key `:memory_service` is
  ONE global key (written with `Application.put_env/3`).
  `Platform.Memory.enabled?/0` and `Platform.Memory.search/2` read it at call time, inside `Wiki.Search`'s Task.async_stream channels.

  When an `async: true` module writes it, a concurrently running module
  sees the other module's provider (a sibling's Noop turns a `:crash` stub's
  dead channel into a live empty one), and interleaved save/restore pairs
  can leave a stub installed in global env after the async phase ends,
  where `async: false` modules inherit it. Both flakes on main came from
  this shape.

  This guard scans the test tree and fails, naming each file, when a file
  both declares `async: true` on its `use ...Case` line and writes
  `:memory_service` (the `:memory_service_req_client` key is a different
  key and is not matched).

  It reads files only, so it is itself `async: true`.
  """

  use ExUnit.Case, async: true

  # Writer: put_env of :platform :memory_service — whitespace (incl.
  # newlines) tolerated between args; `:memory_service_req_client` and any
  # other `:memory_service_*` key excluded by the negative lookahead.
  @writer ~r/put_env\(\s*:platform,\s*:memory_service\b(?!_)/

  # Async declaration: only the `use Foo.Case, ... async: true` line counts.
  # Prose in a moduledoc that mentions `async: true` must not.
  @async_use ~r/^\s*use\s+[\w.]+\s*,[^\n]*\basync:\s*true\b/m

  # Positive control floor. 26 writer files at d4702c85; a scan finding
  # fewer than this is a broken scan, not a clean tree.
  @min_writers 20

  defp test_root, do: Path.expand("../..", __DIR__)

  defp scan do
    test_root()
    |> Path.join("**/*_test.exs")
    |> Path.wildcard()
    |> Enum.map(fn path -> {Path.relative_to(path, test_root()), File.read!(path)} end)
    |> Enum.filter(fn {_rel, src} -> Regex.match?(@writer, src) end)
  end

  test "the scan finds the :memory_service writers (positive control)" do
    writers = scan()

    assert length(writers) >= @min_writers,
           "scan found #{length(writers)} :memory_service writer files under " <>
             "#{test_root()}; expected at least #{@min_writers}. The scan is broken."

    # The scan must see THIS repo's known writer, or it is looking elsewhere.
    assert Enum.any?(writers, fn {rel, _} -> rel =~ "org/wiki/search_test.exs" end)
  end

  test "the async pattern matches a `use` line and ignores moduledoc prose" do
    assert Regex.match?(@async_use, "  use Platform.DataCase, async: true\n")
    refute Regex.match?(@async_use, "  `Platform.FilesTest` is `async: true` and\n")
    refute Regex.match?(@async_use, "  use Platform.DataCase, async: false\n")
    # Split literals so this file's own source does not match @writer.
    call = "Application.put_env(" <> ":platform, "
    assert Regex.match?(@writer, call <> ":memory_service, [])")
    assert Regex.match?(@writer, call <> "\n  :memory_service,\n  provider: X)")
    refute Regex.match?(@writer, call <> ":memory_service_req_client, x)")
  end

  test "no async: true test module writes the global :memory_service env" do
    offenders =
      scan()
      |> Enum.filter(fn {_rel, src} -> Regex.match?(@async_use, src) end)
      |> Enum.map(fn {rel, _} -> rel end)
      |> Enum.sort()

    assert offenders == [],
           "these test files are `async: true` AND write the global " <>
             "`:platform` `:memory_service` app env key, which " <>
             "races every other module reading it. Make them `async: false`:\n" <>
             Enum.map_join(offenders, "\n", &("  " <> &1))
  end
end
