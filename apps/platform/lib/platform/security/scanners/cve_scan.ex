defmodule Platform.Security.Scanners.CveScan do
  @moduledoc """
  CVE scanner for the `security.cve_scan` responsibility (task
  `019f3e8e-4406` stage 3, ADR-0043).

  On each Sweeper tick with a `security_guard` role assignment in
  place, this module:

    1. Discovers lockfiles under
       `Application.get_env(:platform, :security_scanner_repo_root,
       File.cwd!())` — `mix.lock`, `package-lock.json`, `Cargo.lock`.
    2. Parses each file via `LockfileParser` into a flat list of
       `{ecosystem, name, version}` entries.
    3. Batches the entries into a single `POST /v1/querybatch`
       against OSV.dev (mockable via `:cve_scan_osv_client` config).
    4. For each returned vuln, classifies severity from either
       `database_specific.severity` (a plain `CRITICAL | HIGH |
       MEDIUM | LOW` string) or the CVSS numeric score parsed from
       `severity[].score`.
    5. Files a task per critical/high finding via
       `Platform.Security.FindingFiler.file_finding/1`. Medium/low
       findings are skipped unless the OSV entry has been sitting
       modified > 30 days ago with no upstream fix — the "stale
       long-tail" rule from the task description.
    6. Returns `{:ok, findings_filed}` — one integer, the number of
       task rows the scanner actually inserted (dedup hits count as
       0 because they don't create rows). The Sweeper folds this
       into its `sweep_tick` telemetry.

  ## Progressive-enhancement seam

  The Sweeper already guards this module — it never calls
  `run_scan/2` when `Roles.assignee_for("security.cve_scan")` is
  `nil`. This module additionally short-circuits with a `warn` log
  and `{:ok, 0}` when the target project id isn't configured, so a
  half-set-up prod (role assigned but no security-triage project
  yet) fails legibly instead of raising a missing-key changeset.

  ## Configuration

      config :platform,
        security_scanner_repo_root: File.cwd!(),
        cve_scan_osv_client: Platform.Security.Scanners.CveScan.OsvClient

      config :platform, Platform.Security,
        project_id: "<uuid>",
        cve_scan_stale_days: 30
  """

  require Logger

  alias Platform.Security.FindingFiler
  alias Platform.Security.Scanners.CveScan.LockfileParser

  @stale_days_default 30

  @doc """
  Run a CVE scan and file any findings. Sweeper-facing entrypoint —
  the arity + return contract mirror all four scanner modules so the
  Sweeper's supervised-task path can call any of them uniformly.

  Arguments:
    * `responsibility` — the `%Platform.Responsibilities.Responsibility{}`
      row the Sweeper resolved for `security.cve_scan`.
    * `trigger_meta` — sweeper-supplied `%{scanned_at, agent_slug,
      agent_id}` map, currently forwarded into log lines for
      operator legibility.
  """
  @spec run_scan(map(), map()) :: {:ok, non_neg_integer()}
  def run_scan(_responsibility, trigger_meta) do
    repo_root =
      Application.get_env(:platform, :security_scanner_repo_root) || File.cwd!()

    lockfiles = LockfileParser.discover_lockfiles(repo_root)

    if lockfiles == [] do
      Logger.info(
        "[Security.Scanners.CveScan] no lockfiles under root=#{repo_root} — nothing to scan"
      )

      {:ok, 0}
    else
      Logger.info(
        "[Security.Scanners.CveScan] scanning lockfiles=#{Enum.map(lockfiles, fn {kind, path} -> "#{kind}:#{Path.relative_to(path, repo_root)}" end) |> Enum.join(",")} " <>
          "trigger=#{inspect(Map.take(trigger_meta, [:agent_slug]))}"
      )

      entries = collect_entries(lockfiles)

      if entries == [] do
        {:ok, 0}
      else
        scan_entries(entries)
      end
    end
  rescue
    error ->
      # Scanner crash isolation lives at the Sweeper level, but a
      # rescue here means we return a well-formed {:ok, count} even
      # when a lockfile is unparseable — the sweeper's telemetry
      # stays legible.
      Logger.error("[Security.Scanners.CveScan] scanner raised — #{Exception.message(error)}")

      {:ok, 0}
  end

  # ── internals ────────────────────────────────────────────────────────

  defp collect_entries(lockfiles) do
    lockfiles
    |> Enum.flat_map(fn {kind, path} -> parse_lockfile(kind, path) end)
    |> Enum.uniq_by(fn %{ecosystem: e, name: n, version: v} -> {e, n, v} end)
  end

  defp parse_lockfile(kind, path) do
    case File.read(path) do
      {:ok, contents} ->
        result =
          case kind do
            :mix_lock -> LockfileParser.parse_mix_lock(contents)
            :package_lock -> LockfileParser.parse_package_lock(contents)
            :cargo_lock -> LockfileParser.parse_cargo_lock(contents)
          end

        case result do
          {:ok, entries} ->
            entries

          {:error, reason} ->
            Logger.warning(
              "[Security.Scanners.CveScan] parse failed kind=#{kind} path=#{path} reason=#{inspect(reason)}"
            )

            []
        end

      {:error, reason} ->
        Logger.warning(
          "[Security.Scanners.CveScan] read failed path=#{path} reason=#{inspect(reason)}"
        )

        []
    end
  end

  defp scan_entries(entries) do
    queries =
      Enum.map(entries, fn %{ecosystem: eco, name: name, version: ver} ->
        %{package: %{name: name, ecosystem: eco}, version: ver}
      end)

    case osv_client().query_batch(queries) do
      {:ok, results} when is_list(results) ->
        file_findings(entries, results)

      {:error, reason} ->
        Logger.warning(
          "[Security.Scanners.CveScan] OSV query failed reason=#{inspect(reason)} — 0 findings filed"
        )

        {:ok, 0}
    end
  end

  defp file_findings(entries, results) do
    project_id = configured_project_id()

    cond do
      is_nil(project_id) ->
        Logger.warning(
          "[Security.Scanners.CveScan] no project_id configured — set config :platform, Platform.Security, project_id: <uuid>"
        )

        {:ok, 0}

      true ->
        findings =
          entries
          |> Enum.zip(results)
          |> Enum.flat_map(fn {entry, result} -> extract_findings(entry, result) end)
          |> Enum.map(&Map.put(&1, :project_id, project_id))

        # Stage 5: batch path applies the > threshold digest rule so a
        # 20-CVE scan collapses into one weekly rollup task instead of
        # burying the board. Below threshold falls through to per-finding
        # `file_finding/1` with its dedup gate.
        {:ok, FindingFiler.file_findings(findings)}
    end
  end

  # OSV returns `%{"vulns" => [...]}` per query; missing / empty
  # vulns → nothing to file.
  defp extract_findings(entry, %{"vulns" => vulns}) when is_list(vulns) do
    Enum.flat_map(vulns, fn vuln -> vuln_to_finding(entry, vuln) end)
  end

  defp extract_findings(_entry, _), do: []

  defp vuln_to_finding(entry, vuln) do
    severity = classify_severity(vuln)
    modified_at = parse_modified(Map.get(vuln, "modified"))
    fixed_version = extract_fixed_version(vuln, entry)

    if include_finding?(severity, modified_at, fixed_version) do
      cve_id = extract_cve_id(vuln)

      [build_finding(entry, vuln, severity, cve_id, fixed_version)]
    else
      []
    end
  end

  # Include critical + high always; medium + low only when the vuln
  # has been modified > 30 days ago with no upstream fix (task-desc
  # "long stale tail" rule).
  defp include_finding?(:critical, _modified_at, _fixed_version), do: true
  defp include_finding?(:high, _modified_at, _fixed_version), do: true

  defp include_finding?(sev, modified_at, fixed_version) when sev in [:medium, :low] do
    is_nil(fixed_version) and stale?(modified_at)
  end

  defp include_finding?(_sev, _, _), do: false

  defp stale?(nil), do: false

  defp stale?(%DateTime{} = modified_at) do
    stale_days =
      case Application.get_env(:platform, Platform.Security) do
        nil -> @stale_days_default
        kw -> Keyword.get(kw, :cve_scan_stale_days, @stale_days_default)
      end

    age_seconds = DateTime.diff(DateTime.utc_now(), modified_at, :second)
    age_seconds > stale_days * 24 * 3600
  end

  # OSV vulns carry severity in two places:
  #   * `database_specific.severity` = "CRITICAL" | "HIGH" | ...
  #   * `severity[]` = [%{"type" => "CVSS_V3", "score" => "CVSS:3.1/..."}]
  # Prefer the plain string; fall back to CVSS score parsing.
  defp classify_severity(vuln) do
    case get_in(vuln, ["database_specific", "severity"]) do
      "CRITICAL" -> :critical
      "HIGH" -> :high
      "MEDIUM" -> :medium
      "MODERATE" -> :medium
      "LOW" -> :low
      _ -> classify_from_cvss(vuln)
    end
  end

  defp classify_from_cvss(vuln) do
    score =
      vuln
      |> Map.get("severity", [])
      |> Enum.find_value(&extract_cvss_score/1)

    cond do
      is_nil(score) -> :low
      score >= 9.0 -> :critical
      score >= 7.0 -> :high
      score >= 4.0 -> :medium
      true -> :low
    end
  end

  # Scores can be either a bare numeric ("9.8") or a CVSS vector
  # string ("CVSS:3.1/AV:N/AC:L/..."). CVSS vectors carry the
  # numeric score only when the OSV entry additionally supplies a
  # `score_num` — but most entries only carry the vector. When we
  # only have the vector, fall back to :high as a conservative
  # bias (the task description's "critical/high" filter tolerates a
  # false positive better than a false negative on real advisories).
  defp extract_cvss_score(%{"score" => score}) when is_binary(score) do
    case Float.parse(score) do
      {value, _} -> value
      :error -> extract_cvss_vector_score(score)
    end
  end

  defp extract_cvss_score(%{"score" => score}) when is_number(score), do: score * 1.0
  defp extract_cvss_score(_), do: nil

  # A CVSS:3.x vector doesn't inline the numeric — but we can lean on
  # the pattern's presence to bias toward :high (see comment above).
  defp extract_cvss_vector_score("CVSS:" <> _rest), do: 7.5
  defp extract_cvss_vector_score(_), do: nil

  # Prefer the first `CVE-*` alias; fall back to the raw OSV id.
  defp extract_cve_id(vuln) do
    aliases = Map.get(vuln, "aliases", [])

    Enum.find(aliases, fn a -> is_binary(a) and String.starts_with?(a, "CVE-") end) ||
      Map.get(vuln, "id", "UNKNOWN")
  end

  defp parse_modified(nil), do: nil

  defp parse_modified(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_modified(_), do: nil

  # Walk `.affected[]` for a matching package name/ecosystem and
  # look for the first `{fixed: "..."}` event.
  defp extract_fixed_version(vuln, entry) do
    affected = Map.get(vuln, "affected", [])

    Enum.find_value(affected, fn a ->
      pkg = Map.get(a, "package", %{})

      if Map.get(pkg, "name") == entry.name and
           Map.get(pkg, "ecosystem") == entry.ecosystem do
        a
        |> Map.get("ranges", [])
        |> Enum.find_value(&fixed_from_range/1)
      end
    end)
  end

  defp fixed_from_range(%{"events" => events}) when is_list(events) do
    Enum.find_value(events, fn
      %{"fixed" => version} -> version
      _ -> nil
    end)
  end

  defp fixed_from_range(_), do: nil

  defp build_finding(entry, vuln, severity, cve_id, fixed_version) do
    title =
      "CVE #{cve_id} in #{entry.name} #{entry.version} (severity: #{Atom.to_string(severity)})"

    description = build_description(entry, vuln, cve_id, fixed_version)

    %{
      scanner_key: "security.cve_scan",
      severity: severity,
      title: title,
      description: description,
      fingerprint: "cve:#{cve_id}:#{entry.name}:#{entry.version}",
      metadata: %{
        "cve_id" => cve_id,
        "ecosystem" => entry.ecosystem,
        "package" => entry.name,
        "installed_version" => entry.version,
        "fixed_version" => fixed_version,
        "osv_id" => Map.get(vuln, "id")
      }
    }
  end

  defp build_description(entry, vuln, cve_id, fixed_version) do
    summary = Map.get(vuln, "summary") || Map.get(vuln, "details") || "No summary from OSV."
    advisory_url = "https://osv.dev/vulnerability/#{Map.get(vuln, "id", cve_id)}"

    upgrade = upgrade_command(entry, fixed_version)

    """
    | Field | Value |
    | --- | --- |
    | Package | `#{entry.name}` |
    | Ecosystem | `#{entry.ecosystem}` |
    | Installed | `#{entry.version}` |
    | Fixed in | `#{fixed_version || "(no upstream fix yet)"}` |
    | CVE | [`#{cve_id}`](https://nvd.nist.gov/vuln/detail/#{cve_id}) |
    | Advisory | [`#{Map.get(vuln, "id", cve_id)}`](#{advisory_url}) |

    ## Summary

    #{summary}

    ## Suggested upgrade

    ```
    #{upgrade}
    ```
    """
  end

  defp upgrade_command(%{ecosystem: "Hex", name: name}, fixed_version)
       when is_binary(fixed_version) do
    ~s|# in mix.exs bump #{name} to ~> #{fixed_version}\nmix deps.update #{name}|
  end

  defp upgrade_command(%{ecosystem: "Hex", name: name}, _),
    do: "mix deps.update #{name}  # no fixed version — check upstream advisory"

  defp upgrade_command(%{ecosystem: "npm", name: name}, fixed_version)
       when is_binary(fixed_version) do
    "npm install #{name}@#{fixed_version}"
  end

  defp upgrade_command(%{ecosystem: "npm", name: name}, _),
    do: "npm update #{name}  # no fixed version — check upstream advisory"

  defp upgrade_command(%{ecosystem: "crates.io", name: name}, fixed_version)
       when is_binary(fixed_version) do
    "cargo update -p #{name} --precise #{fixed_version}"
  end

  defp upgrade_command(%{ecosystem: "crates.io", name: name}, _),
    do: "cargo update -p #{name}  # no fixed version — check upstream advisory"

  defp upgrade_command(%{name: name}, _), do: "# review upstream advisory for `#{name}`"

  defp configured_project_id do
    case Application.get_env(:platform, Platform.Security) do
      nil -> nil
      kw -> Keyword.get(kw, :project_id)
    end
  end

  defp osv_client do
    Application.get_env(
      :platform,
      :cve_scan_osv_client,
      Platform.Security.Scanners.CveScan.OsvClient
    )
  end
end
