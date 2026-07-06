defmodule Platform.Repo.Migrations.CleanupLivekitPhantomFlood20260704 do
  @moduledoc """
  Task 019f3312 stage 4 — one-shot data cleanup for the LiveKit phantom
  transcript flood on 2026-07-04.

  Between 01:15 and 01:30 UTC on 2026-07-04, an unauthenticated caller
  exploited the pre-stage-2 LiveKit webhook (unsigned) + pre-stage-1
  room-guard mismatch to create a flurry of `meeting_transcripts` rows
  that never accumulated any segments. Stages 1 and 2 of this task
  closed the source (room-guard tightened + HMAC-JWT signature check
  on the webhook), so the orphan rows are now safely stranded.

  ## Predicate

  Delete rows where **all** of the following hold:

    * `inserted_at BETWEEN 2026-07-04 01:15:00Z AND 2026-07-04 01:30:00Z`
      — the observed exploit window; boundary times are inclusive.
    * `segments = '[]'::jsonb` — a real transcript accumulates at least
      one speaker-attributed chunk; empty-segment rows are the phantom
      flood signature.
    * `status IN ('recording', 'processing')` — terminal statuses
      (`complete`, `failed`, plus any future `finalized` / `summarized`)
      are protected. A terminal row inside the window with empty
      segments would be evidence of a legitimate no-speech recording,
      not a phantom insert.

  ## Non-goals (rows that MUST survive)

    * In-progress rows outside the exploit window.
    * In-progress rows inside the window that actually accumulated
      segments (the recorder observed audio).
    * Any row with a terminal status, regardless of timestamp or
      segment count.

  ## Idempotence

  Re-running `delete_orphans/1` on a database that already had this
  migration applied is a no-op — the WHERE predicate matches zero rows
  the second time through.

  ## One-way door

  `down/0` is intentionally a warning-only no-op. We do not preserve
  the deleted row bodies (they are known garbage) and re-creating them
  would defeat the purpose of the cleanup. If a rollback is ever
  needed, restore from a database backup taken before this migration
  ran, not from `down/0`.

  ## Test hook

  The SQL lives in `delete_orphans/1` so the migration test can drive
  it against `Platform.Repo` inside a sandbox transaction without a
  full `Ecto.Migrator.up/4` cycle (which would blow past the
  sandbox's checkout owner). The migration's `up/0` calls the same
  function under the `repo()` runner-provided handle used at deploy.
  """
  use Ecto.Migration

  @window_start ~U[2026-07-04 01:15:00Z]
  @window_end ~U[2026-07-04 01:30:00Z]

  def up do
    {n, ids} = delete_orphans(repo())

    IO.puts(
      "[cleanup] Deleted #{n} phantom meeting_transcripts rows: " <>
        inspect(ids)
    )
  end

  def down do
    IO.warn("cleanup migration is one-way; rows not restored")
  end

  @doc """
  Delete rows matching the phantom-flood predicate on the given repo.

  Returns `{num_deleted, [id]}` — `id` is the raw UUID binary as
  returned by Postgres. Callers that need string form should map
  through `Ecto.UUID.cast!/1`.
  """
  @spec delete_orphans(module()) :: {non_neg_integer(), [binary()]}
  def delete_orphans(repo) do
    %{num_rows: n, rows: rows} =
      repo.query!(
        "DELETE FROM meeting_transcripts " <>
          "WHERE inserted_at BETWEEN $1 AND $2 " <>
          "AND segments = '[]'::jsonb " <>
          "AND status IN ('recording', 'processing') " <>
          "RETURNING id",
        [@window_start, @window_end]
      )

    {n, List.flatten(rows)}
  end
end
