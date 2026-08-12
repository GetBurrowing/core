defmodule Platform.Files.HTMLBackfill do
  @moduledoc """
  Re-ingests already-uploaded HTML rows now that `Platform.Files.Extractor`
  has a `text/html` clause (task 019ff1ab stage 1).

  ## Measure before you change anything

  `measure/1` is read-only and reports the whole population — every row
  whose stored `content_type` mentions HTML *or* whose filename ends
  `.html` / `.htm`. `run/1` measures first and then acts only on the
  covered slice. The count is what makes the result checkable
  afterwards: a backfill nobody sized cannot be sanity-checked once it
  has run.

  ## Coverage is asked, never listed

  Whether a row is covered is decided by
  `Platform.Files.Extractor.supported_content_type?/1` — the same
  predicate the dispatch table backs. A second hand-typed list of MIME
  types here would drift from the router silently. A row stored as
  `application/octet-stream` (or any other uncovered type) is therefore
  **left alone**: re-ingesting it would not extract anything, and
  sniffing the bytes to decide it is "really" HTML is a deliberate
  non-goal.

  ## Skipped rows are reported, not swallowed

  Every bucket appears in the report and in `format_report/1` output
  even when it is zero, because a run that prints nothing is
  indistinguishable from a run that found nothing.

  ## The report counts finished work, not requests

  `run/1` re-ingests **synchronously** (`Platform.Files.request_ingest/2`
  with `mode: :sync`). The async path returns as soon as a supervised
  task is spawned, and the mix task wrapping this module halts the VM
  the moment it has printed — killing the task mid-extract. The run then
  reported `1` for a row that ended at `pending` with no text: a report
  that named work it had not done. `:changed` now counts rows that
  reached `ingested`; anything else lands in `:errors` with its reason.

  Only the batch caller changed. `request_ingest/1` still defaults to
  `mode: :async` for the upload LiveView and the MCP upload tool, whose
  BEAM outlives the task.

  ## Idempotent, and stranded rows are reachable again

  A candidate is a covered, non-deleted row that is either held back
  (`ingest_intent: "human_only"`), terminal-without-text (`ingest_status`
  in `"failed"` / `"not_attempted"`), or **stale-pending**: parked at
  `pending` with no `updated_at` movement for `:stale_pending_after`
  (default #{15 * 60}s). Stale-pending exists because rows stranded by
  the pre-fix async run are otherwise unreachable forever — `pending` is
  not a retry state, so every later run reported `0` and looked
  correctly idempotent. The age floor is what keeps it from stealing a
  genuinely in-flight upload; those are counted under
  `:skipped_already_ingesting` as before.

  A row that completes is `ingested`, out of the candidate set, so a
  second run still changes nothing further.

  Soft-deleted rows are skipped on purpose: `Platform.Files.delete_file/2`
  removes their chunks, and re-ingesting one would put deleted content
  back in front of search.

  ## One pipeline, not two

  Re-ingest goes through `Platform.Files.request_ingest/1` — the single
  retry/override entry point — rather than a bespoke extraction loop.
  A second extraction path is how the two drift.
  """

  import Ecto.Query

  alias Platform.Files
  alias Platform.Files.Extractor
  alias Platform.Files.File, as: FileRow
  alias Platform.Repo

  @type report :: %{
          scanned: non_neg_integer(),
          covered: non_neg_integer(),
          skipped_uncovered_content_type: %{optional(String.t()) => non_neg_integer()},
          skipped_deleted: non_neg_integer(),
          skipped_already_ingesting: non_neg_integer(),
          stale_pending: non_neg_integer(),
          candidates: [String.t()],
          changed: non_neg_integer(),
          errors: [{String.t(), term()}]
        }

  @doc """
  Read-only census of the HTML population. Writes nothing.
  """
  @spec measure(keyword()) :: report()
  def measure(opts \\ []) do
    rows = population(opts)
    cutoff = stale_cutoff(opts)

    {covered, uncovered} =
      Enum.split_with(rows, &Extractor.supported_content_type?(&1.content_type))

    {deleted, live} = Enum.split_with(covered, &(&1.deleted_at != nil))
    {candidates, already} = Enum.split_with(live, &candidate?(&1, cutoff))

    %{
      scanned: length(rows),
      covered: length(covered),
      skipped_uncovered_content_type: Enum.frequencies_by(uncovered, & &1.content_type),
      skipped_deleted: length(deleted),
      skipped_already_ingesting: length(already),
      stale_pending: Enum.count(candidates, &stale_pending?(&1, cutoff)),
      candidates: Enum.map(candidates, & &1.id),
      changed: 0,
      errors: []
    }
  end

  @doc """
  Measures, then re-ingests the covered candidates.

  Options:

    * `:project_id` — restrict to one project (used by tests).
    * `:dry_run` — measure only; `:changed` stays 0.
    * `:stale_pending_after` — seconds a row may sit at `pending`
      before it counts as stranded and becomes a candidate again.

  Returns only after every candidate has finished ingesting or failed,
  so the caller may exit immediately afterwards without losing work.
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    report = measure(opts)

    if Keyword.get(opts, :dry_run, false) do
      report
    else
      {changed, errors} =
        Enum.reduce(report.candidates, {0, []}, fn id, {changed, errors} ->
          case Files.request_ingest(Files.get_file(id), mode: :sync) do
            {:ok, %{ingest_status: "ingested"}} ->
              {changed + 1, errors}

            {:ok, %{ingest_status: status}} ->
              {changed, [{id, {:unexpected_status, status}} | errors]}

            {:error, reason} ->
              {changed, [{id, reason} | errors]}
          end
        end)

      %{report | changed: changed, errors: Enum.reverse(errors)}
    end
  end

  @doc """
  Renders a report as operator-readable lines. Every bucket is printed,
  including the zeroes.
  """
  @spec format_report(report()) :: String.t()
  def format_report(report) do
    uncovered =
      case Enum.sort(report.skipped_uncovered_content_type) do
        [] ->
          "  left unchanged (content type not covered by the extractor): none"

        pairs ->
          detail = Enum.map_join(pairs, ", ", fn {ct, n} -> "#{ct}=#{n}" end)
          "  left unchanged (content type not covered by the extractor): #{detail}"
      end

    Enum.join(
      [
        "HTML ingest backfill",
        "  scanned (html content type or .html/.htm filename): #{report.scanned}",
        "  covered by the extractor dispatch table: #{report.covered}",
        uncovered,
        "  left unchanged (soft-deleted): #{report.skipped_deleted}",
        "  left unchanged (already attempting or ingested): #{report.skipped_already_ingesting}",
        "  retried after being stranded at pending: #{Map.get(report, :stale_pending, 0)}",
        "  re-ingested (extracted and indexed): #{report.changed}",
        "  failed to re-ingest: #{length(report.errors)}"
      ],
      "\n"
    )
  end

  @default_stale_pending_after 15 * 60

  defp candidate?(%{ingest_intent: "human_only"}, _cutoff), do: true

  defp candidate?(%{ingest_status: status}, _cutoff) when status in ~w(failed not_attempted),
    do: true

  defp candidate?(row, cutoff), do: stale_pending?(row, cutoff)

  # A row parked at `pending` with nothing writing to it is not "in
  # flight", it is abandoned — and `pending` is not otherwise a retry
  # state, so nothing else would ever pick it up. The age floor is the
  # only thing separating the two, since neither carries a worker pid.
  defp stale_pending?(%{ingest_status: "pending", updated_at: updated_at}, cutoff)
       when not is_nil(updated_at),
       do: DateTime.compare(updated_at, cutoff) == :lt

  defp stale_pending?(_row, _cutoff), do: false

  defp stale_cutoff(opts) do
    seconds = Keyword.get(opts, :stale_pending_after, @default_stale_pending_after)
    DateTime.add(DateTime.utc_now(), -seconds, :second)
  end

  defp population(opts) do
    FileRow
    |> where(
      [f],
      ilike(f.content_type, "%html%") or
        ilike(f.original_filename, "%.html") or ilike(f.original_filename, "%.htm") or
        ilike(f.name, "%.html") or ilike(f.name, "%.htm")
    )
    |> maybe_project(Keyword.get(opts, :project_id))
    |> select([f], %{
      id: f.id,
      content_type: f.content_type,
      ingest_status: f.ingest_status,
      ingest_intent: f.ingest_intent,
      deleted_at: f.deleted_at,
      updated_at: f.updated_at
    })
    |> Repo.all()
  end

  defp maybe_project(query, nil), do: query
  defp maybe_project(query, project_id), do: where(query, [f], f.project_id == ^project_id)
end
