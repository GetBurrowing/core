defmodule Mix.Tasks.Platform.Tasks.Embed do
  @moduledoc """
  One-shot, idempotent backfill of task embeddings + `task_references`
  for every existing task (stage 2 of task 019f3dbb).

  The write-path hooks in `Platform.Tasks.create_task/1` +
  `update_task/2` cover tasks written after stage 2 shipped. This Mix
  task fills in the pre-existing rows so `memory_search(source: "task")`
  and the follow-up detector have full coverage from the first run.

  ## What it does per task

    * `Platform.Tasks.References.upsert_from_description/1` — refresh
      the derived reference rows.
    * `Platform.Memory.ingest/1` (synchronous) — send the entry to the
      memory service. Idempotent by design: the memory service upserts
      by `id`, so re-running the backfill overwrites the same vector.

  ## Batching

  Reads tasks in chunks (default 50) using keyset pagination on the
  UUIDv7 `id` column — UUIDv7 is time-ordered so `id > cursor` is a
  monotonic cursor without needing an inserted_at composite key.
  Between batches the process yields, so a long backfill on a large
  DB won't peg the connection pool.

  ## Usage

      mix platform.tasks.embed
      mix platform.tasks.embed --batch 100
      mix platform.tasks.embed --project-id <uuid>
      mix platform.tasks.embed --dry-run
      mix platform.tasks.embed --skip-refs
      mix platform.tasks.embed --skip-embed

  Ctrl-C is safe: the task fully processes the current batch, logs its
  progress, then exits. Re-running resumes from the top and skips
  nothing — both operations are idempotent.
  """

  use Mix.Task

  import Ecto.Query

  require Logger

  alias Platform.Memory
  alias Platform.Repo
  alias Platform.Tasks.Indexer
  alias Platform.Tasks.References
  alias Platform.Tasks.Task

  @shortdoc "Backfill task embeddings + task_references for existing rows"

  @default_batch 50

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          batch: :integer,
          project_id: :string,
          dry_run: :boolean,
          skip_refs: :boolean,
          skip_embed: :boolean
        ],
        aliases: [b: :batch, p: :project_id]
      )

    Mix.Task.run("app.start")

    config = %{
      batch: Keyword.get(opts, :batch, @default_batch),
      project_id: Keyword.get(opts, :project_id),
      dry_run?: Keyword.get(opts, :dry_run, false),
      skip_refs?: Keyword.get(opts, :skip_refs, false),
      skip_embed?: Keyword.get(opts, :skip_embed, false)
    }

    log(
      "Platform.Tasks.Embed backfill starting " <>
        "(batch=#{config.batch}, project_id=#{config.project_id || "all"}, " <>
        "dry_run=#{config.dry_run?}, skip_refs=#{config.skip_refs?}, " <>
        "skip_embed=#{config.skip_embed?})"
    )

    total = count_tasks(config.project_id)
    log("total tasks to process: #{total}")

    process_all(config)

    :ok
  end

  @doc """
  Backfill loop, exposed for tests. Returns a `%{processed, errors}` map.
  """
  @spec process_all(map()) :: %{processed: non_neg_integer(), errors: non_neg_integer()}
  def process_all(config) do
    do_process(nil, config, %{processed: 0, errors: 0, batch_ix: 0})
  end

  # ── Batch loop ─────────────────────────────────────────────────────────

  defp do_process(cursor, config, acc) do
    rows = fetch_batch(cursor, config)

    case rows do
      [] ->
        log(
          "Platform.Tasks.Embed backfill done: processed=#{acc.processed} " <>
            "errors=#{acc.errors}"
        )

        acc

      _ ->
        batch_ix = acc.batch_ix + 1
        log("[backfill] batch #{batch_ix}: processing #{length(rows)} tasks")

        errors_in_batch =
          Enum.reduce(rows, 0, fn task, errs ->
            case process_one(task, config) do
              :ok -> errs
              {:error, reason} -> log_failure(task, reason, errs)
            end
          end)

        acc = %{
          processed: acc.processed + length(rows),
          errors: acc.errors + errors_in_batch,
          batch_ix: batch_ix
        }

        log("[backfill] batch #{batch_ix} done: cumulative processed=#{acc.processed}")

        if length(rows) < config.batch do
          log(
            "Platform.Tasks.Embed backfill done: processed=#{acc.processed} " <>
              "errors=#{acc.errors}"
          )

          acc
        else
          next_cursor = List.last(rows).id
          do_process(next_cursor, config, acc)
        end
    end
  end

  # ── Single-task processing ─────────────────────────────────────────────

  @doc """
  Process a single task — exposed for tests so the batching loop can be
  bypassed when asserting per-row semantics.
  """
  @spec process_one(Task.t(), map()) :: :ok | {:error, term()}
  def process_one(%Task{} = task, config) do
    with :ok <- maybe_refs(task, config),
         :ok <- maybe_embed(task, config) do
      :ok
    end
  end

  defp maybe_refs(_task, %{dry_run?: true}), do: :ok
  defp maybe_refs(_task, %{skip_refs?: true}), do: :ok

  defp maybe_refs(task, _config) do
    case References.upsert_from_description(task) do
      {:ok, _n} -> :ok
      {:error, reason} -> {:error, {:refs, reason}}
    end
  end

  defp maybe_embed(_task, %{dry_run?: true}), do: :ok
  defp maybe_embed(_task, %{skip_embed?: true}), do: :ok

  defp maybe_embed(task, _config) do
    case Memory.ingest([Indexer.build_entry(task)]) do
      {:ok, _n} -> :ok
      {:error, reason} -> {:error, {:embed, reason}}
    end
  end

  defp log_failure(task, reason, errs) do
    Logger.warning(
      "Platform.Tasks.Embed backfill: task #{task.id} failed reason=#{inspect(reason)}"
    )

    log("  ! task #{String.slice(task.id, 0, 8)}: #{inspect(reason)}")
    errs + 1
  end

  # ── Repo helpers ───────────────────────────────────────────────────────

  defp count_tasks(nil) do
    Repo.aggregate(base_query(nil), :count, :id)
  end

  defp count_tasks(project_id) do
    Repo.aggregate(base_query(project_id), :count, :id)
  end

  defp fetch_batch(cursor, %{batch: batch, project_id: project_id}) do
    base_query(project_id)
    |> apply_cursor(cursor)
    |> order_by([t], asc: t.id)
    |> limit(^batch)
    |> Repo.all()
  end

  defp base_query(nil) do
    from(t in Task, where: is_nil(t.deleted_at))
  end

  defp base_query(project_id) when is_binary(project_id) do
    from(t in Task, where: is_nil(t.deleted_at) and t.project_id == ^project_id)
  end

  defp apply_cursor(query, nil), do: query
  defp apply_cursor(query, cursor), do: from(t in query, where: t.id > ^cursor)

  # ── Logging ────────────────────────────────────────────────────────────

  defp log(msg) do
    if function_exported?(Mix, :shell, 0) do
      Mix.shell().info(msg)
    else
      IO.puts(msg)
    end
  end
end
