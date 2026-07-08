defmodule Platform.Tasks.References do
  @moduledoc """
  Scanner + upsert for the `task_references` derived table (stage 2 of task
  019f3dbb).

  A row in `task_references` means "the source task's description text
  mentions the target task's UUID". Stage 1 shipped the migration + schema
  + a one-shot backfill of pre-existing descriptions; this module carries
  the ongoing write-path scanner that runs synchronously on task
  create/update and keeps the derived rows in sync with the current
  description.

  ## Semantics

  Every write is a **refresh**, not an append: given the current
  description text, we compute the exact set of `(source, target)` rows
  that should exist for this source and reconcile:

    * Delete rows where `source_task_id = task.id` and `target_task_id NOT IN`
      the new set — so removing a UUID from the description also removes
      the reference row.
    * Insert (via `ON CONFLICT DO NOTHING`) a row per target id that
      * appears in the description as a UUIDv7 substring,
      * targets a task that actually exists in `tasks`, and
      * is not the source task itself (no self-references).

  Both operations run in a single `Repo.transaction/1` so an aborted
  scanner call can never leave `task_references` half-refreshed.

  ## Advisory failure model

  The scanner is advisory to the write path — `create_task`/`update_task`
  invoke `upsert_from_description/1` and log at `:warning` on failure,
  but the task write itself is never rolled back. A DB hiccup during
  reference upsert is a nightly-backfill problem, not a task-create
  failure. Stage 2's Mix task (`Mix.Tasks.Platform.Tasks.Embed`) also
  runs the scanner across every task so a transient miss self-heals on
  the next backfill.
  """

  import Ecto.Query

  require Logger

  alias Platform.Repo
  alias Platform.Tasks.Task
  alias Platform.Tasks.TaskReference

  # UUIDv7 shape (task ids across the platform): `019` prefix, version
  # nibble `7`, standard 8-4-4-4-12 grouping. Case-insensitive because
  # descriptions may quote the id in either case; we lower-case the
  # captured value for a stable set-diff.
  @uuid_regex ~r/\b(019[a-f0-9]{5}-[a-f0-9]{4}-7[a-f0-9]{3}-[a-f0-9]{4}-[a-f0-9]{12})\b/i

  @doc """
  Return the current UUIDv7 regex (exposed so tests can reference the
  same source-of-truth pattern without duplicating the literal).
  """
  @spec uuid_regex() :: Regex.t()
  def uuid_regex, do: @uuid_regex

  @doc """
  Extract unique UUIDv7-shaped substrings from `text`. Returns lower-cased
  ids in insertion order (deduped). Pure — safe to call from tests.
  """
  @spec extract_uuids(String.t() | nil) :: [String.t()]
  def extract_uuids(nil), do: []
  def extract_uuids(""), do: []

  def extract_uuids(text) when is_binary(text) do
    @uuid_regex
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [uuid] -> String.downcase(uuid) end)
    |> Enum.uniq()
  end

  @doc """
  Reconcile `task_references` rows for `task` based on the current
  `task.description` text. Refuses to fire when the source task carries
  no id (e.g. a bare `%Task{}` struct).

  Returns `{:ok, n}` where `n` is the count of rows in the final set
  for this source (0 when the description contains no valid references),
  or `{:error, reason}` if the transaction failed. Errors are already
  logged at `:warning` — the caller need not re-log.
  """
  @spec upsert_from_description(Task.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def upsert_from_description(%Task{id: source_id, description: description})
      when is_binary(source_id) do
    targets =
      description
      |> extract_uuids()
      |> Enum.reject(&(&1 == String.downcase(source_id)))
      |> filter_existing()

    result =
      Repo.transaction(fn ->
        delete_stale(source_id, targets)
        insert_fresh(source_id, targets)
        length(targets)
      end)

    case result do
      {:ok, count} ->
        {:ok, count}

      {:error, reason} ->
        Logger.warning(
          "Platform.Tasks.References upsert failed for source=#{inspect(source_id)}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  rescue
    e ->
      Logger.warning(
        "Platform.Tasks.References upsert crashed for source=#{inspect(source_id)}: " <>
          inspect(e)
      )

      {:error, e}
  end

  def upsert_from_description(_), do: {:ok, 0}

  # ── Private ────────────────────────────────────────────────────────────

  # Keep only ids that already exist in `tasks`. Ghost references (ids
  # that look UUIDv7-shaped but were never real tasks, e.g. in a copy-
  # pasted quote) are silently dropped — the FK on `task_references`
  # would reject them anyway, and we prefer a silent no-op to a noisy
  # constraint violation.
  defp filter_existing([]), do: []

  defp filter_existing(ids) do
    Task
    |> where([t], t.id in ^ids)
    |> select([t], t.id)
    |> Repo.all()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp delete_stale(source_id, []) do
    # No valid targets — clear every existing row for this source.
    from(r in TaskReference, where: r.source_task_id == ^source_id)
    |> Repo.delete_all()

    :ok
  end

  defp delete_stale(source_id, targets) do
    from(r in TaskReference,
      where: r.source_task_id == ^source_id and r.target_task_id not in ^targets
    )
    |> Repo.delete_all()

    :ok
  end

  defp insert_fresh(_source_id, []), do: :ok

  defp insert_fresh(source_id, targets) do
    now = DateTime.utc_now()

    rows =
      for t <- targets do
        %{source_task_id: source_id, target_task_id: t, inserted_at: now}
      end

    Repo.insert_all(TaskReference, rows,
      on_conflict: :nothing,
      conflict_target: [:source_task_id, :target_task_id]
    )

    :ok
  end
end
