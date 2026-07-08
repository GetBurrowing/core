defmodule Platform.Security.FindingFiler do
  @moduledoc """
  Files security-scanner findings as Suite tasks (task
  `019f3e8e-4406` stage 5, ADR-0043).

  Two entrypoints, matching the two runtime shapes scanners have:

    * `file_finding/1` — single-finding path. Used when a scanner
      emits findings one at a time OR when a batch has already been
      pre-filtered. Applies the dedup gate + severity → priority
      mapping + task metadata shape.
    * `file_findings/1` — batch path. Accepts a list of findings
      from a single scanner run. When the batch exceeds
      `finding_digest_threshold` (default 10), it collapses into
      ONE consolidated weekly digest task with a markdown table
      instead of N individual rows. Below the threshold, delegates
      to `file_finding/1` per element.

  ## Dedup gate

  Before insert, `Platform.Tasks.list_tasks_by_metadata_key/2` is
  called with the finding's `fingerprint`. If any non-deleted task
  already carries that fingerprint, the write is skipped and the
  caller sees `{:error, :duplicate_fingerprint}`. Stage 5 upgraded
  the stage-2 shim's Elixir-side filter to a JSONB `->>` query so
  the gate scales past a handful of rows.

  ## Digest rule (stage 5)

  When `file_findings/1` sees > `finding_digest_threshold` findings
  from one scanner in one run, it files a single digest task instead
  of N individual tasks. The digest task's fingerprint is
  `"digest:<scanner_key>:<iso_week>"` so a follow-up sweep within the
  same ISO week dedups (one digest per scanner per week). The
  description is a markdown table sorted by severity (critical →
  high → medium → low) then by finding title.

  ## Finding descriptor shape

  ```elixir
  %{
    scanner_key: "security.cve_scan",       # required — one of the four security.* keys
    severity: :critical,                     # required — :critical | :high | :medium | :low
    title: "Something bad in package",       # required — will be prefixed with [security:<key>]
    description: "markdown body",            # optional
    fingerprint: "cve:CVE-2024-1234:plug:1.14.0",  # required — dedup key
    project_id: "<uuid>",                    # required — Suite project the task lands in
    sponsor_user_id: "<uuid>"                # optional — falls back to configured sponsor / nil
  }
  ```
  """

  require Logger

  alias Platform.Tasks
  alias Platform.Tasks.Task

  @severity_to_priority %{
    critical: "critical",
    high: "high",
    medium: "medium",
    low: "low"
  }

  @severity_order %{
    critical: 0,
    high: 1,
    medium: 2,
    low: 3
  }

  @default_digest_threshold 10

  @doc """
  File a single finding as a Suite task.

  Returns `{:ok, %Task{}}` on insert, `{:error, :duplicate_fingerprint}`
  when a non-deleted task already carries the same
  `metadata["security_fingerprint"]`, or `{:error, term}` on any
  other failure (missing required key, changeset error, etc.).
  """
  @spec file_finding(map()) ::
          {:ok, Task.t()}
          | {:error, :duplicate_fingerprint}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:missing_key, atom()}}
  def file_finding(finding) when is_map(finding) do
    with :ok <-
           require_keys(finding, [:scanner_key, :severity, :title, :fingerprint, :project_id]),
         :ok <- ensure_no_duplicate(finding.fingerprint, finding.scanner_key) do
      finding
      |> build_task_attrs()
      |> Tasks.create_task()
    end
  end

  @doc """
  File a batch of findings from a single scanner run.

  Below the digest threshold (default 10), each finding is filed
  individually via `file_finding/1` and the return is the total
  count of successful inserts (dedup hits count as 0). Above the
  threshold, ONE digest task is filed for the whole batch — a
  markdown table listing every finding, sorted severity-first —
  and the return is either `1` (digest task filed) or `0` (digest
  fingerprint already exists for this ISO week, i.e. dedup hit).

  Accepts an empty list — returns `0` without touching the DB.

  All findings in the batch must share the same `scanner_key` and
  `project_id`. When they don't, the batch is grouped by
  `scanner_key`; each sub-batch decides digest vs. individual
  independently. `project_id` is taken from the first finding for
  the digest path — mixing project_ids in a single batch is a
  caller bug (log warn but proceed).
  """
  @spec file_findings([map()]) :: non_neg_integer()
  def file_findings([]), do: 0

  def file_findings(findings) when is_list(findings) do
    threshold = digest_threshold()

    findings
    |> Enum.group_by(fn f -> Map.get(f, :scanner_key) end)
    |> Enum.reduce(0, fn {scanner_key, group}, acc ->
      acc + file_group(scanner_key, group, threshold)
    end)
  end

  # ── internals ────────────────────────────────────────────────────────

  defp file_group(nil, group, _threshold) do
    Logger.warning(
      "[FindingFiler] batch contains #{length(group)} findings with nil scanner_key — filing individually"
    )

    Enum.reduce(group, 0, fn finding, acc ->
      case file_finding(finding) do
        {:ok, _} -> acc + 1
        _ -> acc
      end
    end)
  end

  defp file_group(scanner_key, group, threshold) when length(group) > threshold do
    file_digest(scanner_key, group)
  end

  defp file_group(_scanner_key, group, _threshold) do
    Enum.reduce(group, 0, fn finding, acc ->
      case file_finding(finding) do
        {:ok, _} -> acc + 1
        {:error, :duplicate_fingerprint} -> acc
        {:error, other} -> log_error(finding, other) && acc
      end
    end)
  end

  defp file_digest(scanner_key, findings) do
    project_id = pick_project_id(findings)
    week = iso_week(DateTime.utc_now())
    fingerprint = "digest:#{scanner_key}:#{week}"

    if project_id == nil do
      Logger.warning(
        "[FindingFiler] digest skipped for scanner=#{scanner_key} — no project_id in first finding"
      )

      0
    else
      finding = %{
        scanner_key: scanner_key,
        severity: highest_severity(findings),
        title: "Weekly digest — #{length(findings)} findings",
        description: digest_description(scanner_key, findings, week),
        fingerprint: fingerprint,
        project_id: project_id,
        metadata: %{
          "digest_week" => week,
          "digest_count" => length(findings),
          "digest_scanner_key" => scanner_key
        }
      }

      case file_finding(finding) do
        {:ok, _task} ->
          Logger.info(
            "[FindingFiler] digest filed scanner=#{scanner_key} week=#{week} findings=#{length(findings)}"
          )

          1

        {:error, :duplicate_fingerprint} ->
          Logger.info(
            "[FindingFiler] digest dedup hit scanner=#{scanner_key} week=#{week} findings=#{length(findings)}"
          )

          0

        {:error, other} ->
          log_error(finding, other)
          0
      end
    end
  end

  defp pick_project_id(findings) do
    Enum.find_value(findings, fn f -> Map.get(f, :project_id) end)
  end

  defp highest_severity(findings) do
    findings
    |> Enum.min_by(
      fn f -> Map.get(@severity_order, Map.get(f, :severity, :low), 9) end,
      fn -> %{severity: :medium} end
    )
    |> Map.get(:severity, :medium)
  end

  # ISO-week bucket for weekly-digest dedup — `YYYY-Www` (e.g.
  # "2026-W28"). Matches ISO-8601 §5.1.2.
  defp iso_week(%DateTime{} = now) do
    date = DateTime.to_date(now)
    {year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
    "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  defp digest_description(scanner_key, findings, week) do
    sorted =
      findings
      |> Enum.sort_by(fn f ->
        {Map.get(@severity_order, Map.get(f, :severity, :low), 9), Map.get(f, :title, "")}
      end)

    rows =
      Enum.map_join(sorted, "\n", fn f ->
        sev = f |> Map.get(:severity, :low) |> Atom.to_string()
        title = f |> Map.get(:title, "") |> String.replace("|", "\\|")
        resource = f |> Map.get(:fingerprint, "") |> String.replace("|", "\\|")
        fix = f |> Map.get(:suggested_fix, "") |> String.replace("|", "\\|")

        "| #{sev} | #{title} | `#{resource}` | #{fix} |"
      end)

    """
    # #{scanner_key} — weekly digest (#{week})

    #{length(findings)} findings were consolidated into this digest because
    the raw count exceeded the `finding_digest_threshold` of
    #{digest_threshold()}. Investigate the highest-severity rows first;
    individual per-finding tasks are suppressed until either the count
    drops below the threshold or a new ISO week begins.

    | Severity | Title | Fingerprint | Suggested fix |
    | --- | --- | --- | --- |
    #{rows}
    """
  end

  defp digest_threshold do
    case Application.get_env(:platform, Platform.Security) do
      nil -> @default_digest_threshold
      kw -> Keyword.get(kw, :finding_digest_threshold, @default_digest_threshold)
    end
  end

  defp require_keys(finding, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Map.get(finding, key) do
        nil -> {:halt, {:error, {:missing_key, key}}}
        _ -> {:cont, :ok}
      end
    end)
  end

  # Stage 5 dedup: JSONB `->>` equality on `metadata->>security_fingerprint`.
  # A single indexable query, no in-memory filter. Stage 2 walked
  # `Platform.Tasks.list_tasks/1` and filtered in Elixir — cheap while
  # the finding count was tiny, but doesn't scale past a handful of
  # scans.
  defp ensure_no_duplicate(fingerprint, scanner_key) do
    case Tasks.list_tasks_by_metadata_key("security_fingerprint", fingerprint) do
      [] ->
        :ok

      [_ | _] ->
        Logger.info(
          "[FindingFiler] dedup hit — skipping key=#{scanner_key} fingerprint=#{fingerprint}"
        )

        {:error, :duplicate_fingerprint}
    end
  end

  defp build_task_attrs(finding) do
    scanner_key = finding.scanner_key
    severity = finding.severity
    priority = Map.get(@severity_to_priority, severity, "medium")
    summary = finding.title
    title = "[security:#{scanner_key}] #{summary}"

    metadata =
      finding
      |> Map.get(:metadata, %{})
      |> Map.merge(%{
        "security_fingerprint" => finding.fingerprint,
        "security_scanner" => scanner_key,
        "security_severity" => Atom.to_string(severity),
        "security_labels" => ["security-finding", scanner_key]
      })

    %{
      project_id: finding.project_id,
      title: title,
      description: Map.get(finding, :description),
      status: "backlog",
      priority: priority,
      metadata: metadata,
      sponsor_user_id: Map.get(finding, :sponsor_user_id)
    }
  end

  defp log_error(finding, reason) do
    Logger.warning(
      "[FindingFiler] file_finding failed fingerprint=#{Map.get(finding, :fingerprint)} reason=#{inspect(reason)}"
    )

    true
  end
end
