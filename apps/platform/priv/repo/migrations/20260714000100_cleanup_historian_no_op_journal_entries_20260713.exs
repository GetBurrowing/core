defmodule Platform.Repo.Migrations.CleanupHistorianNoOpJournalEntries20260713 do
  @moduledoc """
  Task 019f5e7d stage 3 — one-shot data cleanup for the ~80 self-generated
  "backlog drained" / "no new entries" no-op journal entries in
  `org/journal/2026-07-13.md`.

  Stage 2 of this task closed the source (three historian dispatch
  templates now instruct "RETURN SILENTLY" rather than writing an
  empty acknowledgement entry) so the previously-accumulated garbage
  entries are now safely stranded. This migration purges them from
  `org_wiki_journal_entries` and drops one audit-trail row per pass so
  the deletion is queryable via `Platform.Audit.list/1` +
  `event_type: "platform.historian.cleanup"`.

  ## Signature

  Delete rows where **all** of the following hold:

    * `date = '2026-07-13'` — the observed spam window.
    * `content ILIKE '%backlog drained%'` OR
      `content ILIKE '%No new entries%'` OR
      `content ILIKE '%Wiki current%'`
      — the three canonical no-op phrases the pre-fix historian template
      emitted; matched on content only (NOT author) so a future rename
      of the historian agent leaves the predicate intact.
    * `content NOT ILIKE '%Applied:%'` — the load-bearing "Historn:
      backlog-drain pass. Applied: kickoff-followup-meeting.md ..."
      entry documents three real fixes + saru.md creation and MUST
      survive. Real curation entries always cite specifics via
      `Applied:`; no-op entries never do.

  ## Non-goals (rows that MUST survive)

    * Any entry with `Applied:` in its content, regardless of date.
    * Any entry outside 2026-07-13.
    * Entries longer than a few sentences that don't match any of the
      three no-op phrases (the predicate is signature-first, length is
      not part of the filter).

  ## Two-step: audit before delete

  `up/0` collects the target `id` list first, records a single
  `Platform.Audit.Event` synchronously (event_type
  `"platform.historian.cleanup"`, `metadata.deleted_entry_ids` +
  `metadata.deleted_count`), then performs the `DELETE`. Recording
  via `Platform.Audit.record/1` directly — not via `:telemetry` —
  because the historian telemetry handler in `Platform.Audit.TelemetryHandler`
  routes historian events through `Task.Supervisor.start_child/2`,
  which spawns outside the migration's Repo transaction and would
  create a visibility race with the DELETE that lands in the same
  transaction.

  ## Idempotence

  Re-invoking `delete_no_op_entries/1` on a database that already had
  this migration applied is a no-op — the predicate matches zero rows
  the second time through, and the audit-record helper is skipped when
  the id list is empty.

  ## One-way door

  `down/0` is a warning-only no-op. We do not preserve the deleted row
  bodies (they are known garbage) and re-creating them would
  re-perpetuate the self-triggering dispatch loop stage 2 closed. If a
  rollback is ever required, restore from a database backup taken
  before this migration ran, not from `down/0`.

  ## Test hook

  The SQL lives in `delete_no_op_entries/1` and the audit write in
  `record_cleanup_audit/1` so the migration test can drive both against
  `Platform.Repo` inside a sandbox transaction without a full
  `Ecto.Migrator.up/4` cycle. The migration's `up/0` calls the same
  functions under the `repo()`-provided handle used at deploy time.
  """

  use Ecto.Migration
  import Ecto.Query

  alias Platform.Org.WikiJournalEntry

  @target_date ~D[2026-07-13]
  @migration_id "20260714000100"
  @audit_event_type "platform.historian.cleanup"

  def up do
    {n, ids} = delete_no_op_entries(Platform.Repo)
    record_cleanup_audit(ids)

    IO.puts(
      "[cleanup] Deleted #{n} no-op historian journal entries from #{@target_date}: " <>
        inspect(ids)
    )
  end

  def down do
    IO.warn(
      "cleanup migration is one-way; deleted journal rows cannot be restored — " <>
        "restore from a database backup taken before #{@migration_id} if regression required"
    )

    :ok
  end

  @doc """
  Delete rows matching the no-op signature on the given repo.

  Returns `{num_deleted, [id]}` — `id` is the string-form UUID via
  `Platform.Types.UUIDv7`'s `load/1`. Callers that need raw binary
  form can `Ecto.UUID.dump!/1`.
  """
  @spec delete_no_op_entries(module()) :: {non_neg_integer(), [binary()]}
  def delete_no_op_entries(repo) do
    ids =
      no_op_query()
      |> select([e], e.id)
      |> repo.all()

    {n, _} =
      repo.delete_all(from(e in WikiJournalEntry, where: e.id in ^ids))

    {n, ids}
  end

  @doc """
  Record a single audit event for the cleanup pass. No-op when
  `entry_ids` is empty (idempotent re-run).
  """
  @spec record_cleanup_audit([binary()]) :: :ok
  def record_cleanup_audit([]), do: :ok

  def record_cleanup_audit(entry_ids) when is_list(entry_ids) do
    {:ok, _event} =
      Platform.Audit.record(%{
        event_type: @audit_event_type,
        actor_type: "system",
        action: "execute",
        resource_type: "wiki_journal",
        resource_id: Date.to_iso8601(@target_date),
        metadata: %{
          "deleted_entry_ids" => entry_ids,
          "deleted_count" => length(entry_ids),
          "migration" => @migration_id,
          "date" => Date.to_iso8601(@target_date)
        }
      })

    :ok
  end

  # Signature filter — content-only, exclude Applied:
  defp no_op_query do
    from(e in WikiJournalEntry,
      where:
        e.date == ^@target_date and
          (fragment("? ILIKE ?", e.content, "%backlog drained%") or
             fragment("? ILIKE ?", e.content, "%No new entries%") or
             fragment("? ILIKE ?", e.content, "%Wiki current%")) and
          not fragment("? ILIKE ?", e.content, "%Applied:%")
    )
  end
end
