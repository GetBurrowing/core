defmodule Platform.Repo.Migrations.DismissReadNonActionInboxItems do
  @moduledoc """
  Task `01a11703` stage 1: dismiss every inbox row the user has already OPENED
  whose kind is not an action kind, so the first deploy of "opening
  acknowledges" lands on an inbox that already reflects it.

  ## Why this exists

  From `01a00108` stage 4 (#811) until this task, opening a row only wrote
  `read_at`, and every opened row stayed on `/inbox`. The same commit as this
  migration makes `/inbox`'s open handler call `Platform.Inbox.open_item/2`,
  which dismisses every kind outside `Platform.Inbox.action_kinds/0` in the
  same write that marks it read. Without this backfill, every mention, meeting
  notice, sponsor note and failed-hook row a user opened in that window would
  stay on the list, and "inbox 0" would need a manual Clear all on deploy day.

  `dismissed_at` is set to `read_at`, not `now()`, so the row reads as
  "acknowledged when you opened it", which is what `open_item/2` would have
  written at the time. The kinds are literal on purpose: a migration must not
  call app code that can change after it ships. They equal
  `Platform.Inbox.action_kinds/0` at the time of writing.

  Action rows (`task_plan_review`, `review_request_pending`) are left alone:
  an opened approval is still outstanding until it is resolved.

  ## Running it twice

  Idempotent, by the `dismissed_at IS NULL` clause. A second run on an
  unchanged database touches zero rows. A row read for the first time AFTER
  the deploy goes through `open_item/2`, which already dismisses non-action
  kinds, so a re-run would only ever catch a row restored by an undo after it
  was opened, which the user asked to keep. This is a one-shot repair; never
  wire it to a scheduler.

  ## Why `down/0` does not undo it

  Same reasoning as `20260817120000_backfill_read_as_dismissed_inbox_items.exs`:
  nulling `dismissed_at` wherever it equals `read_at` would also erase real
  dismissals (including every `open_item/2` acknowledgement, which writes the
  two columns equal by design), and no column records which writer set the
  value. Rolling back the code leaves these rows dismissed, which is a state
  the old code also produces and handles.
  """
  use Ecto.Migration

  # The exact statement the migration runs. Exposed via `backfill_sql/0` so the
  # regression test executes THIS SQL rather than a copy that could drift; see
  # `test/platform/repo/dismiss_read_non_action_inbox_items_test.exs`.
  @backfill_sql """
  UPDATE inbox_items
     SET dismissed_at = read_at
   WHERE read_at IS NOT NULL
     AND dismissed_at IS NULL
     AND kind NOT IN ('task_plan_review', 'review_request_pending')
  """

  def up, do: execute(@backfill_sql)

  # Intentionally inert. See "Why `down/0` does not undo it" above.
  def down, do: :ok

  @doc false
  def backfill_sql, do: @backfill_sql
end
