defmodule Platform.Files.CardBackfill do
  @moduledoc """
  Catalogs the documents that were already ingested (task 01a0008c stage 3).

  The telemetry emitter (`Platform.Files.CatalogEmitter`) only ever sees
  the future. Every file already sitting at `ingest_status: "ingested"`
  will never emit another `[:platform, :files, :ingested, :stop]`, so
  without this module the catalog starts empty and stays that way until
  somebody uploads something.

  That is not a cold-start nicety. The design canvas's worked example of
  supersession is the pair of order forms in the Globex corpus, and **both of
  them are already ingested** — a future-only catalog cannot demonstrate
  the feature it was built for.

  ## Enumeration goes through the seam, exclusively

  Candidates come from `Platform.Files.list_catalogable_files/2` and
  nowhere else. There is no `Repo.all(File)` in this module and there must
  not be one.

  `Ingester.ingest_async/1`'s `human_only` short-circuit protects the
  *telemetry* path: no `:stop` event ever fires for such a row, so the
  emitter inherits the boundary for free. A backfill inherits **nothing** —
  it goes looking for rows precisely because nothing is firing events at
  it — and a hand-rolled query here would walk a `human_only` document
  straight into a third-party LLM. That asymmetry is the reason stage 1
  built the seam as a function instead of leaving three call sites to
  re-derive the same `where` clauses.

  Projects are enumerated with `Platform.Tasks.list_projects_unscoped/1`
  because the seam is project-scoped; `:project_id` narrows a run to one.

  ## Dry-run is the default, at both layers

  `run/1` treats a missing `:dry_run` as **true**, and the mix task
  requires `--write`. Two defaults rather than one because the expensive
  direction is the one a typo should not reach: this loop spends real
  provider money per file, and a caller who forgot the option gets a
  census, not a bill. Sized against the Globex corpus the full run is roughly
  a dollar (~39 documents, image-heavy PDF whose extracted text is far
  below its ~35MB of source bytes), which is cheap enough to run and
  expensive enough that it should be asked for.

  ## Serial, deliberately

  One file at a time, no `Task`, no concurrency knob — the same constraint
  the emitter is built around, for the same reason: nothing upstream of
  either applies backpressure to a provider.

  ## Idempotent, and re-runnable as the retry

  A file that already has a `card_file_key` is reported under
  `:already_catalogued` and skipped, so a second run catalogs nothing
  further. The inverse is the system's entire retry strategy: a provider
  error leaves `card_file_key` nil, which makes the row a candidate again
  on the next run. There is no retry queue anywhere in this subsystem, by
  design.

  A row whose text never landed (`{:error, :no_extracted_text}` — the
  shape a deduped file has, since `Ingester.do_run/3`'s dedup clause
  copies chunks without writing `platform_file_texts`) reports as an error
  every run rather than silently disappearing. That is honest: it is a
  real uncatalogued document, and hiding it would make the census lie.
  """

  require Logger

  alias Platform.Files
  alias Platform.Files.Cataloger
  alias Platform.Tasks

  @type report :: %{
          dry_run: boolean(),
          projects: non_neg_integer(),
          catalogable: non_neg_integer(),
          already_catalogued: non_neg_integer(),
          candidates: [String.t()],
          catalogued: non_neg_integer(),
          noops: [{String.t(), atom()}],
          errors: [{String.t(), term()}]
        }

  @doc """
  Read-only census. Writes nothing and calls no provider.

  Options: `:project_id` to scope to one project, `:limit` to cap the
  candidate list (applied after eligibility, so the census counts stay
  true).
  """
  @spec measure(keyword()) :: report()
  def measure(opts \\ []) do
    project_ids = project_ids(opts)

    catalogable = Enum.flat_map(project_ids, &Files.list_catalogable_files/1)

    {done, todo} = Enum.split_with(catalogable, &(not is_nil(&1.card_file_key)))

    %{
      dry_run: true,
      projects: length(project_ids),
      catalogable: length(catalogable),
      already_catalogued: length(done),
      candidates: todo |> maybe_limit(Keyword.get(opts, :limit)) |> Enum.map(& &1.id),
      catalogued: 0,
      noops: [],
      errors: []
    }
  end

  @doc """
  Measures, then — only when told to — catalogs the candidates serially.

  `:dry_run` defaults to **true**. Pass `dry_run: false` to spend money.
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)
    report = %{measure(opts) | dry_run: dry_run?}

    if dry_run? do
      report
    else
      catalog_all(report, opts)
    end
  end

  @doc """
  Renders a report as operator-readable lines. Every bucket prints,
  including the zeroes — a run that prints nothing is indistinguishable
  from a run that found nothing.
  """
  @spec format_report(report()) :: String.t()
  def format_report(report) do
    [
      "File catalog card backfill#{if report.dry_run, do: " (DRY RUN — nothing written)", else: ""}",
      "  projects scanned: #{report.projects}",
      "  catalogable files (via Files.list_catalogable_files/2): #{report.catalogable}",
      "  already catalogued (card_file_key set): #{report.already_catalogued}",
      "  candidates: #{length(report.candidates)}",
      "  cards written: #{report.catalogued}",
      "  deliberate no-ops: #{format_pairs(report.noops)}",
      "  errors (left for the next run): #{format_pairs(report.errors)}"
    ]
    |> Enum.join("\n")
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  # The candidate ids are re-resolved to rows through the seam a second
  # time rather than carried over as structs from the census. Same
  # function, one query per project: a row can be soft-deleted or have its
  # intent flipped to `human_only` between the census and its turn in a
  # loop that takes seconds per file, and the census's struct would still
  # look eligible. Anything that stops coming back is reported as a no-op
  # rather than quietly dropped, so the buckets still account for every
  # candidate.
  defp catalog_all(report, opts) do
    wanted = MapSet.new(report.candidates)

    {report, seen} =
      opts
      |> project_ids()
      |> Enum.reduce({report, MapSet.new()}, fn project_id, acc ->
        project_id
        |> Files.list_catalogable_files()
        |> Enum.filter(&(MapSet.member?(wanted, &1.id) and is_nil(&1.card_file_key)))
        |> Enum.reduce(acc, fn file, {acc_report, acc_seen} ->
          {apply_result(acc_report, file.id, Cataloger.catalog_file(file)),
           MapSet.put(acc_seen, file.id)}
        end)
      end)

    wanted
    |> MapSet.difference(seen)
    |> Enum.sort()
    |> Enum.reduce(report, fn id, acc ->
      %{acc | noops: acc.noops ++ [{id, :no_longer_catalogable}]}
    end)
  end

  defp apply_result(acc, _id, {:ok, _page}), do: %{acc | catalogued: acc.catalogued + 1}

  defp apply_result(acc, id, {:ok, :noop, reason}),
    do: %{acc | noops: acc.noops ++ [{id, reason}]}

  defp apply_result(acc, id, {:error, reason}) do
    Logger.info("[Files.CardBackfill] no card for file #{id}: #{inspect(reason)}")
    %{acc | errors: acc.errors ++ [{id, reason}]}
  end

  defp project_ids(opts) do
    case Keyword.get(opts, :project_id) do
      nil -> Enum.map(Tasks.list_projects_unscoped(), & &1.id)
      project_id when is_binary(project_id) -> [project_id]
    end
  end

  defp maybe_limit(files, nil), do: files
  defp maybe_limit(files, limit) when is_integer(limit), do: Enum.take(files, limit)

  defp format_pairs([]), do: "none"

  defp format_pairs(pairs),
    do: Enum.map_join(pairs, ", ", fn {id, reason} -> "#{id}=#{inspect(reason)}" end)
end
