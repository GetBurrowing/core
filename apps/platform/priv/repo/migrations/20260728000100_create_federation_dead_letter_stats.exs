defmodule Platform.Repo.Migrations.CreateFederationDeadLetterStats do
  @moduledoc """
  Cumulative dead-letter loss counters — task 019fa56b-ca2d stage 4.

  ## The measurement argument

  `Reachability.report/0` read 19 `:broadcastable` and 0 `:runtime_offline` at
  20:55Z on 2026-07-27, on a day that had already lost 39 fires to
  `:runtime_offline`. It was not wrong about presence; it was a SNAPSHOT of a
  time-varying class, and a snapshot cannot answer "how much have we lost".
  The fix is a monotonic counter, not a better snapshot.

  ## Why a separate table and not `SELECT count(*) FROM federation_dead_letters`

  The ledger is a WORK QUEUE. It dedupes duplicate pending fires (stage 1's
  partial unique index) and it prunes terminal rows after 30 days (stage 3's
  timer). Both are correct for a queue and **both destroy a cumulative
  measure**: the first undercounts a loss that really happened, the second makes
  the number shrink over time on its own. Counting off the ledger would
  reproduce this ticket's own defect one layer down.

  These counters increment on EVERY record attempt — including the ones the
  ledger deduped — and are never pruned.

  ## The invariant

      recorded == replayed
                + dropped_policy
                + dropped_stale
                + superseded_duplicate
                + abandoned
                + <live rows still in the ledger>

  Only ARRIVALS (`recorded`) and TERMINAL dispositions get counter rows. A live
  disposition (`pending`, `replaying`) is a state rather than an outcome: stage
  3's drain claims a row and reverts it whenever a runtime vanishes mid-delivery,
  so a cumulative `pending` would count flaps and no invariant could survive it.
  The live term is read from the ledger instead, which is sound precisely because
  `prune/1` never deletes a live row.

  ## NULLS NOT DISTINCT on the unique index

  `responsibility_key` and `trigger_kind` are nullable — a cron-shaped loss may
  name neither. Under Postgres' default (NULLS DISTINCT) two such rows never
  conflict, so every upsert would INSERT instead of incrementing and the table
  would grow one row per loss: an append-only log wearing a counter's name, and
  unbounded exactly where this table promises bounded cardinality.

  `NULLS NOT DISTINCT` requires Postgres 15+. Verified before writing: CI runs
  `postgres:16-alpine` (.github/workflows/ci.yml) and the dev/prod server is
  16.13, so the `COALESCE(...,'')` expression-index fallback the plan allowed for
  is not needed. Also verified empirically that `ON CONFLICT (col, ...)` arbiter
  inference resolves a NULLS NOT DISTINCT index from a bare column list — the
  `{:unsafe_fragment, ...}` restatement stage 1 needed applies to PARTIAL
  indexes, and this index has no predicate.

  Cardinality is bounded by responsibility keys x runtimes x counters — roughly
  21 x 8 x 6 — so this table never grows meaningfully. That is what makes
  "never pruned" an affordable promise rather than a deferred cleanup problem.
  """
  use Ecto.Migration

  def change do
    create table(:federation_dead_letter_stats, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # The PRESENCE TOKEN, matching `federation_dead_letters.runtime_id`.
      add(:runtime_id, :string, null: false)
      add(:responsibility_key, :string)
      add(:trigger_kind, :string)

      # `"recorded"` (an arrival) or one of the TERMINAL dispositions from
      # `Platform.Federation.DeadLetter.terminal_dispositions/0`.
      add(:disposition, :string, null: false)

      # :bigint — a counter that can never be reset must not be able to
      # overflow the way a 32-bit one eventually would.
      add(:count, :bigint, null: false, default: 0)

      add(:first_at, :utc_datetime_usec, null: false)
      add(:last_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :federation_dead_letter_stats,
        [:runtime_id, :responsibility_key, :trigger_kind, :disposition],
        nulls_distinct: false,
        name: :federation_dead_letter_stats_key_index
      )
    )

    # Stage 5's admin panel reads a per-key breakdown and a per-disposition
    # rollup; both are full-table scans without these.
    create(index(:federation_dead_letter_stats, [:responsibility_key]))
    create(index(:federation_dead_letter_stats, [:disposition]))
  end
end
