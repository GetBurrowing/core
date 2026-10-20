defmodule Platform.ParallelUI.Markers do
  @moduledoc """
  Finds `Platform.ParallelUI` markers in source files.

  A marker is a comment leader (`#`, `//` or `<%!--`), optional whitespace,
  `parallel-ui:`, whitespace, then an id matching
  `Platform.ParallelUI.id_regex/0`. The same text without a comment leader, for
  example inside a string literal, is not a marker.

  ## Roots

  `default_roots/0` is `lib`, `priv/repo/migrations` and `assets/js` under
  `apps/platform`, and nothing else. `test/` is deliberately not scanned, which
  keeps the guard's own test file and fixtures out of the live scan.

  There is no exclusion list. If this module, `Platform.ParallelUI` or the
  report task ever matches its own pattern, the zero-entry live check reports
  an `unregistered` marker pointing at that file.

  ## Source tree only

  `default_roots/0` is resolved from `__DIR__` at compile time, so in a release
  build it points at a source tree that does not exist and `scan/0` finds
  nothing. Only tests and the mix task call it. Do not call it from runtime
  code.
  """

  @app_dir Path.expand("../../..", __DIR__)

  @root_names ["lib", "priv/repo/migrations", "assets/js"]

  @extensions ~w(.ex .exs .heex .js .ts)

  @marker_regex ~r/(?:#|\/\/|<%!--)\s*parallel-ui:\s+([a-z0-9][a-z0-9_.-]*)(?=\s|--%>|$)/

  @type scan_result :: %{
          markers: [Platform.ParallelUI.marker()],
          files_scanned: non_neg_integer()
        }

  @doc "Absolute paths of the three scanned roots under `apps/platform`."
  @spec default_roots() :: [Path.t()]
  def default_roots, do: Enum.map(@root_names, &Path.join(@app_dir, &1))

  @doc "The file extensions scanned."
  @spec extensions() :: [String.t()]
  def extensions, do: @extensions

  @doc """
  Walks `roots` and returns every marker plus the number of files read.

  Paths under `apps/platform` are reported relative to it; anything else is
  reported as given. A root that does not exist contributes zero files, which
  is why callers assert on `:files_scanned`.
  """
  @spec scan([Path.t()]) :: scan_result()
  def scan(roots \\ default_roots()) do
    files =
      roots
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*")))
      |> Enum.filter(&(Path.extname(&1) in @extensions and File.regular?(&1)))
      |> Enum.uniq()
      |> Enum.sort()

    %{markers: Enum.flat_map(files, &scan_file/1), files_scanned: length(files)}
  end

  defp scan_file(path) do
    display = Path.relative_to(path, @app_dir)

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      @marker_regex
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(fn [id] -> %{id: id, path: display, line: line} end)
    end)
  end
end
