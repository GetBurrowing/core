defmodule Platform.Security.Scanners.CveScan.LockfileParser do
  @moduledoc """
  Pure parsers for the lockfile formats the CVE scanner walks (task
  `019f3e8e-4406` stage 3, ADR-0043).

  Each `parse_*` function accepts the raw file contents (or a path)
  and returns a list of `%{ecosystem: String.t(), name: String.t(),
  version: String.t()}` maps. Isolating the parsers here lets the
  scanner test cover them independently against small fixture
  strings without spinning up the OSV client or DB.

  ## Supported formats

    * `parse_mix_lock/1` — Elixir `mix.lock`. Regex-driven; only
      extracts hex packages (`{:hex, :name, "version", ...}`).
      Non-hex sources (`{:git, ...}`, `{:path, ...}`) are skipped
      because OSV.dev doesn't advise on them and the CVE picture is
      undefined for a git ref.
    * `parse_package_lock/1` — npm `package-lock.json` v2/v3
      lockfileVersion. Walks `.packages["node_modules/<name>"]`
      entries; skips the root package (empty-string key) and
      workspace symlinks (`link: true`).
    * `parse_cargo_lock/1` — Rust `Cargo.lock`. Regex-driven walk
      of `[[package]]` blocks. Skips `source = "git+..."` packages
      for the same reason as mix.lock.

  All three parsers return `{:ok, entries}` — an empty list is a
  valid success. Malformed input returns `{:error, reason}` (e.g.
  invalid JSON, missing `%{...}` map wrapper in mix.lock). The
  scanner treats an error result as "skip this lockfile, move on"
  and logs at warn.
  """

  @type entry :: %{ecosystem: String.t(), name: String.t(), version: String.t()}

  # ── mix.lock ────────────────────────────────────────────────────────────

  @doc """
  Parse `mix.lock` contents into a list of hex-package entries.

  Format sample:

      %{
        "phoenix": {:hex, :phoenix, "1.7.10", "<checksum>", [:mix], [...deps...], "hexpm", "<sha256>"},
        "req": {:hex, :req, "0.5.17", ...}
      }

  Only hex entries surface — `{:git, ...}` / `{:path, ...}` sources
  are silently dropped because OSV can't advise on them.
  """
  @spec parse_mix_lock(String.t()) :: {:ok, [entry()]} | {:error, term()}
  def parse_mix_lock(contents) when is_binary(contents) do
    entries =
      ~r/"(?<pkg>[A-Za-z0-9_\-\.]+)"\s*:\s*\{:hex,\s*:[A-Za-z0-9_]+,\s*"(?<ver>[^"]+)"/
      |> Regex.scan(contents, capture: :all_names)
      |> Enum.map(fn [pkg, ver] ->
        %{ecosystem: "Hex", name: pkg, version: ver}
      end)

    {:ok, entries}
  end

  # ── package-lock.json ────────────────────────────────────────────────────

  @doc """
  Parse `package-lock.json` contents into a list of npm entries.

  Supports lockfileVersion 2 and 3 (the `.packages` map layout).
  Falls back to lockfileVersion 1's `.dependencies` map when
  `.packages` is absent.

  Skips the root workspace (empty-string key in `.packages`) and any
  entry with `link: true` (workspace symlinks).
  """
  @spec parse_package_lock(String.t()) :: {:ok, [entry()]} | {:error, term()}
  def parse_package_lock(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, %{"packages" => packages}} when is_map(packages) ->
        entries =
          packages
          |> Enum.reject(fn {key, entry} ->
            key == "" or Map.get(entry, "link") == true
          end)
          |> Enum.flat_map(fn {key, entry} -> package_lock_entry(key, entry) end)

        {:ok, entries}

      {:ok, %{"dependencies" => deps}} when is_map(deps) ->
        entries = Enum.flat_map(deps, &package_lock_v1_dep/1)
        {:ok, entries}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  defp package_lock_entry(key, %{"version" => version}) when is_binary(version) do
    case strip_node_modules_prefix(key) do
      "" -> []
      name -> [%{ecosystem: "npm", name: name, version: version}]
    end
  end

  defp package_lock_entry(_key, _entry), do: []

  defp strip_node_modules_prefix("node_modules/" <> rest) do
    # A nested transitive dep can be reached via
    # `node_modules/a/node_modules/b`. OSV cares about `b` — the
    # deepest package name after the last `node_modules/` segment.
    # Scoped names like `@scope/pkg` are preserved (they contain a
    # slash but not the `node_modules/` sentinel).
    rest
    |> String.split("/node_modules/")
    |> List.last()
  end

  defp strip_node_modules_prefix(key), do: key

  defp package_lock_v1_dep({name, %{"version" => version}}) when is_binary(version) do
    [%{ecosystem: "npm", name: name, version: version}]
  end

  defp package_lock_v1_dep(_), do: []

  # ── Cargo.lock ─────────────────────────────────────────────────────────

  @doc """
  Parse `Cargo.lock` contents into a list of crates.io entries.

  Skips `source = "git+..."` packages — OSV's crates.io index doesn't
  cover them.

  Format sample:

      [[package]]
      name = "serde"
      version = "1.0.100"
      source = "registry+https://github.com/rust-lang/crates.io-index"
  """
  @spec parse_cargo_lock(String.t()) :: {:ok, [entry()]} | {:error, term()}
  def parse_cargo_lock(contents) when is_binary(contents) do
    blocks =
      contents
      |> String.split("[[package]]")
      |> Enum.drop(1)
      |> Enum.map(&extract_cargo_block/1)
      |> Enum.reject(&is_nil/1)

    {:ok, blocks}
  end

  defp extract_cargo_block(block) do
    name =
      case Regex.run(~r/^\s*name\s*=\s*"([^"]+)"/m, block) do
        [_, n] -> n
        _ -> nil
      end

    version =
      case Regex.run(~r/^\s*version\s*=\s*"([^"]+)"/m, block) do
        [_, v] -> v
        _ -> nil
      end

    source_ok? =
      case Regex.run(~r/^\s*source\s*=\s*"([^"]+)"/m, block) do
        # No source line at all = workspace-local package; skip
        # (they never carry a crates.io CVE by definition).
        nil -> false
        [_, "registry+" <> _] -> true
        [_, "sparse+" <> _] -> true
        _ -> false
      end

    if is_binary(name) and is_binary(version) and source_ok? do
      %{ecosystem: "crates.io", name: name, version: version}
    else
      nil
    end
  end

  # ── file-path helpers ────────────────────────────────────────────────────

  @doc """
  Discover lockfiles under `root`. Returns a list of
  `{format, absolute_path}` tuples where `format` is one of
  `:mix_lock | :package_lock | :cargo_lock`.

  Deliberately conservative — walks a small set of known locations
  rather than globbing the whole tree, because the scanner runs
  under a supervised task with a fixed 60s budget and a full walk
  of `~/sources` is expensive.
  """
  @spec discover_lockfiles(String.t()) :: [{atom(), String.t()}]
  def discover_lockfiles(root) when is_binary(root) do
    candidates = [
      {:mix_lock, Path.join(root, "mix.lock")},
      {:mix_lock, Path.join([root, "apps", "platform", "mix.lock"])},
      {:package_lock, Path.join([root, "assets", "package-lock.json"])},
      {:package_lock, Path.join([root, "apps", "platform", "assets", "package-lock.json"])},
      {:cargo_lock, Path.join(root, "Cargo.lock")}
    ]

    # Also walk any Cargo.lock under the tree — small in practice.
    cargo_glob = Path.wildcard(Path.join([root, "**", "Cargo.lock"]))

    extra_cargo =
      cargo_glob
      |> Enum.reject(&String.contains?(&1, "/deps/"))
      |> Enum.map(&{:cargo_lock, &1})

    (candidates ++ extra_cargo)
    |> Enum.uniq()
    |> Enum.filter(fn {_kind, path} -> File.regular?(path) end)
  end
end
