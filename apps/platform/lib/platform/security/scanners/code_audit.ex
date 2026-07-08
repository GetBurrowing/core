defmodule Platform.Security.Scanners.CodeAudit do
  @moduledoc """
  Code-audit scanner for the `security.code_audit` responsibility
  (task `019f3e8e-4406` stage 4, ADR-0043).

  Every Sweeper tick with a `security_guard` role assignment in
  place, this module:

    1. Loads the rubric from `priv/security/patterns.yaml` via
       `PatternLoader.load/0`. On any load error, logs warn +
       returns `{:ok, 0}` — the scanner never crashes the Sweeper.
    2. Walks `lib/**/*.ex` under
       `Application.get_env(:platform, :security_scanner_repo_root,
       File.cwd!())` — the same knob the CVE scanner uses so tests
       can point at a tmp dir with fixture code.
    3. For each `kind: regex` pattern, runs
       `Regex.scan/3 |> compute_line_number/2` over each file. Each
       match becomes a finding.
    4. For each `kind: ast_probe` pattern, parses the file via
       `Code.string_to_quoted/2` and dispatches to
       `Platform.Security.Scanners.CodeAudit.AstProbes.<probe>/1`.
    5. Files each finding via
       `Platform.Security.FindingFiler.file_finding/1`. Fingerprint
       shape: `code_audit:<pattern_id>:<relative_file>:<line>`.
    6. Returns `{:ok, findings_filed}` — one integer, the number of
       task rows the scanner inserted (dedup hits count as 0).

  ## Test seams

    * `security_scanner_repo_root` — where the scanner walks for
      `.ex` files.
    * `code_audit_patterns_path` — override the rubric location
      per-test; defaults to `PatternLoader.default_path/0`.
    * `Platform.Security.project_id` — the Suite project findings
      land in. Missing → warn + `{:ok, 0}`.
    * `code_audit_ignore_relative_prefixes` — list of relative-path
      prefixes to skip when walking. Defaults to
      `["deps/", "_build/", ".elixir_ls/"]`. Guards against
      scanning vendored/generated code the operator doesn't own.
  """

  require Logger

  alias Platform.Security.FindingFiler
  alias Platform.Security.Scanners.CodeAudit.AstProbes
  alias Platform.Security.Scanners.CodeAudit.PatternLoader

  @default_ignore_prefixes ["deps/", "_build/", ".elixir_ls/", "priv/static/"]
  @default_walk_relative_dirs ["lib", "apps"]

  @doc """
  Run a code audit and file any findings. Sweeper-facing entrypoint
  matching the four-scanner uniform contract.
  """
  @spec run_scan(map(), map()) :: {:ok, non_neg_integer()}
  def run_scan(_responsibility, _trigger_meta) do
    repo_root =
      Application.get_env(:platform, :security_scanner_repo_root) || File.cwd!()

    with {:ok, patterns} <- load_patterns(),
         project_id when is_binary(project_id) <- configured_project_id() do
      files = discover_ex_files(repo_root)

      Logger.info(
        "[Security.Scanners.CodeAudit] scanning root=#{repo_root} files=#{length(files)} " <>
          "patterns=#{length(patterns)}"
      )

      findings =
        files
        |> Enum.flat_map(fn path -> scan_file(path, patterns, repo_root) end)

      filed = file_all(findings, project_id)

      {:ok, filed}
    else
      nil ->
        Logger.warning(
          "[Security.Scanners.CodeAudit] no project_id configured — set config :platform, Platform.Security, project_id: <uuid>"
        )

        {:ok, 0}

      {:error, reason} ->
        Logger.warning(
          "[Security.Scanners.CodeAudit] rubric load failed reason=#{inspect(reason)} — 0 findings filed"
        )

        {:ok, 0}
    end
  rescue
    error ->
      Logger.error("[Security.Scanners.CodeAudit] scanner raised — #{Exception.message(error)}")

      {:ok, 0}
  end

  # ── internals ────────────────────────────────────────────────────────

  defp load_patterns do
    path =
      Application.get_env(:platform, :code_audit_patterns_path) ||
        PatternLoader.default_path()

    PatternLoader.load(path)
  end

  defp discover_ex_files(root) do
    ignore = ignore_prefixes()

    @default_walk_relative_dirs
    |> Enum.flat_map(fn dir -> Path.wildcard(Path.join([root, dir, "**", "*.ex"])) end)
    |> Enum.uniq()
    |> Enum.reject(fn path ->
      rel = Path.relative_to(path, root)
      Enum.any?(ignore, fn prefix -> String.starts_with?(rel, prefix) end)
    end)
  end

  defp ignore_prefixes do
    Application.get_env(
      :platform,
      :code_audit_ignore_relative_prefixes,
      @default_ignore_prefixes
    )
  end

  defp scan_file(path, patterns, repo_root) do
    case File.read(path) do
      {:ok, contents} ->
        relative = Path.relative_to(path, repo_root)

        Enum.flat_map(patterns, fn pattern ->
          apply_pattern(pattern, contents, path, relative)
        end)

      {:error, _} ->
        []
    end
  end

  defp apply_pattern(%{kind: :regex} = pattern, contents, _abs, relative) do
    pattern.compiled
    |> Regex.scan(contents, return: :index)
    |> Enum.map(fn matches -> line_number_for_index(contents, hd(matches)) end)
    |> Enum.map(fn line ->
      build_regex_finding(pattern, relative, line, snippet_at(contents, line))
    end)
  end

  defp apply_pattern(%{kind: :ast_probe} = pattern, contents, abs, relative) do
    probe = pattern.compiled
    Code.ensure_loaded(AstProbes)

    with {:ok, ast} <- Code.string_to_quoted(contents),
         true <- function_exported?(AstProbes, probe, 1),
         {:ok, hits} <-
           apply(AstProbes, probe, [%{path: abs, contents: contents, ast: ast}]) do
      Enum.map(hits, fn hit ->
        build_probe_finding(pattern, relative, hit)
      end)
    else
      false ->
        Logger.warning(
          "[Security.Scanners.CodeAudit] probe #{inspect(probe)} not exported — skipping"
        )

        []

      _ ->
        []
    end
  end

  # Compute the 1-based line number that contains byte offset `start`.
  defp line_number_for_index(contents, {start, _len}) when is_integer(start) do
    prefix = binary_part(contents, 0, min(start, byte_size(contents)))
    prefix |> String.split("\n") |> length() |> max(1)
  end

  defp line_number_for_index(_, _), do: 1

  defp snippet_at(contents, line) when is_integer(line) and line > 0 do
    lines = String.split(contents, "\n")
    total = length(lines)
    start_line = max(line - 2, 1)
    end_line = min(line + 2, total)

    lines
    |> Enum.slice((start_line - 1)..(end_line - 1))
    |> Enum.with_index(start_line)
    |> Enum.map_join("\n", fn {text, l} -> "#{l}: #{text}" end)
  end

  defp snippet_at(_, _), do: ""

  defp build_regex_finding(pattern, relative, line, snippet) do
    build_finding(pattern, relative, line, snippet, %{})
  end

  defp build_probe_finding(pattern, relative, hit) do
    build_finding(
      pattern,
      relative,
      Map.get(hit, :line, 1),
      Map.get(hit, :snippet, ""),
      Map.get(hit, :extra, %{})
    )
  end

  defp build_finding(pattern, relative, line, snippet, extra) do
    title =
      "Code-audit finding: #{pattern.id} in #{relative}:#{line} (severity: #{Atom.to_string(pattern.severity)})"

    description = build_description(pattern, relative, line, snippet)

    %{
      scanner_key: "security.code_audit",
      severity: pattern.severity,
      title: title,
      description: description,
      fingerprint: "code_audit:#{pattern.id}:#{relative}:#{line}",
      metadata:
        Map.merge(
          %{
            "pattern_id" => pattern.id,
            "file" => relative,
            "line" => line,
            "kind" => Atom.to_string(pattern.kind)
          },
          extra
        )
    }
  end

  defp build_description(pattern, relative, line, snippet) do
    body_lines =
      [
        "## Match",
        "",
        "**File:** `#{relative}`",
        "**Line:** `#{line}`",
        "**Rubric:** `#{pattern.id}` (`#{pattern.kind}`)",
        "",
        pattern.description &&
          """
          ## Description

          #{pattern.description}
          """,
        snippet != "" &&
          """
          ## Snippet

          ```elixir
          #{snippet}
          ```
          """,
        pattern.suggested_fix &&
          """
          ## Suggested fix

          #{pattern.suggested_fix}
          """
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == false))

    Enum.join(body_lines, "\n")
  end

  # Stage 5: use the batch path so a big pattern rubric collapses into a
  # weekly digest task when the count exceeds `finding_digest_threshold`.
  # Below the threshold falls through to per-finding `file_finding/1` with
  # its dedup gate.
  defp file_all(findings, project_id) do
    findings
    |> Enum.map(&Map.put(&1, :project_id, project_id))
    |> FindingFiler.file_findings()
  end

  defp configured_project_id do
    case Application.get_env(:platform, Platform.Security) do
      nil -> nil
      kw -> Keyword.get(kw, :project_id)
    end
  end
end
