defmodule Platform.TestSupport.SourceIndex do
  @moduledoc """
  Read-only, per-VM cache of source-tree reads for source-scanning guard tests.

  A guard that walks `lib/` (or the repo's markdown) and matches on text used to
  repeat the `Path.wildcard/1` walk and every `File.read!/1` once per test, per
  module. Over a sharded run that is the same files read dozens of times; one
  such module timed out at 60 s on a hosted runner (see
  `message_actions_removed_test.exs`). This module reads each file and runs each
  distinct glob once per BEAM, then serves later callers from `:persistent_term`.

  Properties:

    * Read-only. It never writes to the tree, so a consumer stays `async: true`
      safe. Concurrent first callers may both do the work; both store equal
      values.
    * `File`/`Path` only. It never shells out to `git`: the CI job container has
      no `.git`, and a `git` exit 128 in `setup_all` reads as a crash.
    * Semantics are identical to the calls it replaces: `wildcard/2` returns what
      `Path.wildcard/2` returns (same order) and `read!/1` what `File.read!/1`
      returns, so a guard's patterns and globs are unchanged by moving onto it.
    * A file is re-read when its mtime or size changed since it was cached, so a
      test that rewrites a file it later scans is not served stale text.
  """

  @doc "Cached `Path.wildcard/2`."
  @spec wildcard(Path.t(), keyword()) :: [Path.t()]
  def wildcard(pattern, opts \\ []) do
    key = {__MODULE__, :glob, pattern, opts}

    case :persistent_term.get(key, :miss) do
      :miss ->
        paths = Path.wildcard(pattern, opts)
        :persistent_term.put(key, paths)
        paths

      paths ->
        paths
    end
  end

  @doc "Cached `File.read!/1`, refreshed when the file's mtime or size changes."
  @spec read!(Path.t()) :: binary()
  def read!(path) do
    key = {__MODULE__, :file, path}
    stat = File.stat!(path, time: :posix)
    stamp = {stat.mtime, stat.size}

    case :persistent_term.get(key, :miss) do
      {^stamp, content} ->
        content

      _ ->
        content = File.read!(path)
        :persistent_term.put(key, {stamp, content})
        content
    end
  end

  @doc "`{path, content}` for every file matching `pattern`."
  @spec read_glob(Path.t(), keyword()) :: [{Path.t(), binary()}]
  def read_glob(pattern, opts \\ []) do
    for path <- wildcard(pattern, opts), do: {path, read!(path)}
  end
end
