defmodule Platform.Repo.Migrations.AddCountdownColumnsToMeetingCandidates do
  use Ecto.Migration

  @moduledoc """
  The countdown's deadline, and the human who stopped it (task 01a03fba).

  ## Why the deadline is a COLUMN and not a timer

  The obvious home for "act on this in 30 seconds" is the intent queue's
  own `ack_timer`. It cannot go there, for three measured reasons:

    1. `Platform.Meetings.IntentQueue.Server`'s `ack_timer` is a single
       `{intent_id, ref, phase}` tuple (`server.ex:1204`). It holds ONE
       deadline. The cursor gate it belongs to fires only on the
       transition into `:dispatched` (`server.ex:1086`); `handle_call({:enqueue, ...})`
       (`server.ex:793`) has no cursor check at all, so N candidates sit
       open per meeting simultaneously and one tuple cannot describe them.
    2. That GenServer is `restart: :temporary`
       (`intent_queue/supervisor.ex:52`) and its ETS table dies with it,
       so a crash would silently drop every pending deadline with no
       record that one had ever been armed.
    3. `Platform.Meetings.Candidates.graduate/2` does not use the queue
       at all — it calls `Platform.Tasks.create_task/2` /
       `Platform.Chat.create_canvas/1` directly. The countdown gates
       GRADUATION, not dispatch.

  A durable column polled by a sweeper is therefore the shape, matching
  `Platform.Tenancy.ContainerPurger` / `Platform.Files.Purger` /
  `Platform.Chat.SpacePurger`: tick, scan a due-by `*_at` column, act.

  ## `acts_at` is not `last_utterance_at`

  They move together on the extension path and are still two columns,
  for the same argument that split `heard_at` from `last_utterance_at`
  in `20260828220000`. `last_utterance_at` is a MEASUREMENT — when we
  last heard something about this card. `acts_at` is a DECISION — when
  we will act on it. Collapsing them would mean the stop button had to
  corrupt a measurement in order to express "never", and it would mean a
  candidate created outside the threading path (`Candidates.create/1`
  does not default `last_utterance_at`) silently became one that could
  never fire.

  `nil` is the disarmed state and it is the value that means "nothing
  will happen on its own": a stopped card, and a card opened while the
  meeting's automation is off, are both `nil` here.

  ## The partial index is the sweep's whole query

  The sweeper runs every second against a table that only grows, and the
  rows it wants are the small armed minority. `WHERE acts_at IS NOT NULL`
  keeps the index to that minority rather than carrying an entry for
  every closed candidate the org has ever produced.

  ## `closed_by_participant_id` — "with the human named"

  Verified on 2026-08-29 that `meeting_candidates` had nowhere to record
  WHO closed a candidate: `closed_by` matched 0 lines in
  `lib/platform/meetings/`, and the only attribution slot was
  `closed_note`, a free string. A stop button whose whole point is that
  a person took responsibility for it needs a real reference, not a
  sentence somebody could have typed.

  A plain `:uuid`, not a `references/2`, matching every other pointer on
  this table (see `20260827094944_create_meeting_candidates.exs`): a
  deleted participant must not cascade away the record that they once
  pressed stop.

  Reversible: `add/3` inverts to `remove/1` under `change/0`. No
  backfill — an existing candidate was never armed and was never stopped
  by anybody, and nil is the truthful reading of both.
  """

  def change do
    alter table(:meeting_candidates) do
      # When the countdown fires. nil = disarmed. See moduledoc.
      add(:acts_at, :utc_datetime_usec)

      # The participant who pressed stop. See moduledoc.
      add(:closed_by_participant_id, :uuid)
    end

    create(
      index(:meeting_candidates, [:acts_at],
        where: "acts_at IS NOT NULL",
        name: :meeting_candidates_armed_acts_at_index
      )
    )
  end
end
