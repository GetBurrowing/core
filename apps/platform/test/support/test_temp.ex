defmodule Platform.TestTemp do
  @moduledoc """
  Builds temp paths that are unique across OS processes, not merely within one
  BEAM.

  ## Why this exists

  The construction this replaces was
  `Path.join(System.tmp_dir!(), "\#{prefix}-\#{System.unique_integer([:positive])}")`.
  `System.tmp_dir!()` is machine-global and `System.unique_integer/1` is unique
  only within ONE VM, restarting from a low value in every new `mix test`. Two
  concurrently running BEAMs therefore converge on the SAME path.

  Measured: two concurrent OS processes produced the identical path
  `<tmp>/platform-files-storage-test-1539`, and
  `System.unique_integer([:positive, :monotonic])` returned exactly `1` in every
  fresh BEAM.

  The symptom is shared-state interference, not a `mkdir` failure. Most callers
  use `File.mkdir_p!/1`, which returns `:ok` on an existing directory and so
  raises nothing. What actually breaks is that both runs write into one root and
  whichever finishes first deletes the other's fixtures in its own cleanup.

  ## Entropy composition

  Each component defeats a different failure mode, and the composition is
  deliberate:

    * `:crypto.strong_rand_bytes/1` — makes a collision between any two calls,
      anywhere, probabilistically negligible. This carries almost all of the
      uniqueness.
    * `System.pid()` (the OS pid) — makes uniqueness across OS processes
      *structural* rather than probabilistic. This is the component that fixes
      the defect above, and note that no single-BEAM test can observe it, since
      it is constant within a run.
    * `System.unique_integer([:positive, :monotonic])` — intra-BEAM
      disambiguation only. It is NEVER the sole source: a fresh BEAM restarts it
      near `1`, which is the whole bug.

  Lowercase base32 without padding is safe both as a path segment and as a git
  branch name, mirroring the prior art in
  `test/platform/execution/local_runner_test.exs`.

  ## Direction

  Every path is rooted at `System.tmp_dir!()`, resolved at runtime. There is no
  fallback to a hardcoded directory: `System.tmp_dir!()` is `$TMPDIR` on macOS
  and commonly `/tmp` on Linux, so hardcoding either is wrong on the other.

  ## Two functions, two contracts

  `path/1` returns a path and creates NOTHING, because a substantial minority of
  callers need a FILE path and a creating helper would put a directory where a
  file belongs. `mkdir!/1` creates the directory and returns the path.

  ## Cleanup is the caller's

  `mkdir!/1` deliberately does not register its own `on_exit`: that would couple
  this helper to ExUnit's caller context and surprise `setup_all` users, and
  caller-owned cleanup is exactly what races when two runs share a root. Stale
  directories accumulate under `System.tmp_dir!()` when callers do not clean up,
  so register it yourself:

      setup do
        dir = Platform.TestTemp.mkdir!("widget-cache")
        on_exit(fn -> File.rm_rf(dir) end)
        {:ok, dir: dir}
      end

  A file path needs no directory:

      config_path = Platform.TestTemp.path("widget-config") <> ".json"
  """

  @doc """
  Returns a unique path under `System.tmp_dir!()` for `prefix`.

  Creates nothing on disk.
  """
  @spec path(String.t()) :: String.t()
  def path(prefix) when is_binary(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{unique_token()}")
  end

  @doc """
  Returns a unique path under `System.tmp_dir!()` for `prefix`, creating it as a
  directory.

  Does NOT register cleanup — the caller owns that; see the moduledoc.
  """
  @spec mkdir!(String.t()) :: String.t()
  def mkdir!(prefix) when is_binary(prefix) do
    dir = path(prefix)
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Returns a token unique across OS processes.

  See the moduledoc for which component defeats which failure mode.
  """
  @spec unique_token() :: String.t()
  def unique_token do
    random = Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
    counter = System.unique_integer([:positive, :monotonic])

    "#{random}-#{System.pid()}-#{counter}"
  end
end
