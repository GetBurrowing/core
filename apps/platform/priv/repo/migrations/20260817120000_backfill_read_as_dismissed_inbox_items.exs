defmodule Platform.Repo.Migrations.BackfillReadAsDismissedInboxItems do
  @moduledoc """
  Task `01a00108` stage 4: preserve every historical clear across the moment
  "cleared" stops meaning `read_at OR dismissed_at` and starts meaning
  `dismissed_at` alone.

  ## Why this exists

  Until this stage, opening an inbox row WAS clearing it. `InboxLive`'s
  `handle_event("open", ...)` calls `Inbox.mark_read/2`, the row leaves
  `Inbox.unread_scope/1`, and it drops off both the `/inbox` list and the rail
  badge — that was deliberate, and it is the mechanism Harper was describing
  when he said he had to click each and every message to clear it out.

  The same commit as this migration narrows `unread_scope/1` to
  `is_nil(dismissed_at)`. Read rows therefore become visible again. Without this
  backfill, the inbox has been live since `20260723185711` and EVERY row any
  user ever opened and never explicitly dismissed would re-materialise, at once,
  as new work — the exact opposite of the "let me tick things off in bulk"
  request this task exists to serve.

  Copying `read_at` into `dismissed_at` says: whatever you cleared, by the
  mechanism that was current at the time you cleared it, stays cleared. The
  timestamp is carried over rather than set to `now()` on purpose, so the row's
  history reads as "cleared when you actually opened it" rather than "everyone
  cleared everything the day we deployed".

  ## Running it twice

  Idempotent, by the `dismissed_at IS NULL` clause rather than by luck. A second
  run matches only rows still unclear, so it cannot overwrite a `dismissed_at` a
  real dismissal wrote — including a dismissal that landed AFTER the first run,
  whose timestamp is the truthful one and must win over an older `read_at`.
  Re-running touches zero rows on an unchanged database.

  What it is NOT idempotent against is a row read for the first time after the
  deploy: that row's `read_at` is set while `dismissed_at` stays null, so a
  second run WOULD clear a row the user opened but deliberately left on their
  list. This is a one-shot historical repair, not a recurring job, and it must
  never be wired to a scheduler. `down/0` is deliberately a no-op — see below.

  ## Why `down/0` does not undo it

  Nulling `dismissed_at` wherever it equals `read_at` would also erase real
  dismissals that happen to carry that timestamp, and there is no column
  recording which writer set the value. An un-dismissal cannot be distinguished
  from a dismissal, so the safe rollback is to leave the data alone: rolling
  back the code restores the old predicate, under which a row with both
  timestamps set is cleared either way. The rows stay clear in both directions,
  which is the property that matters.

  No index is added or needed. `20260723185711_create_inbox_items.exs` already
  creates `index(:inbox_items, [:user_id, :dismissed_at])`, and `read_at` has no
  index at all — the new predicate is better served by what exists than the old
  one was.
  """
  use Ecto.Migration

  # The exact statement the migration runs. Exposed via `backfill_sql/0` so the
  # regression test can execute THIS SQL rather than a copy of it that could
  # drift; see `test/platform/repo/backfill_read_as_dismissed_test.exs`.
  @backfill_sql """
  UPDATE inbox_items
     SET dismissed_at = read_at
   WHERE read_at IS NOT NULL
     AND dismissed_at IS NULL
  """

  def up, do: execute(@backfill_sql)

  # Intentionally inert. See "Why `down/0` does not undo it" above.
  def down, do: :ok

  @doc false
  def backfill_sql, do: @backfill_sql
end
