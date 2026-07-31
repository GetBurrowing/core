defmodule Platform.Federation.DeadLetterStat do
  @moduledoc """
  One cumulative dead-letter counter (task 019fa56b-ca2d stage 4).

  A row is `{runtime_id, responsibility_key, trigger_kind, disposition} ->
  count`, incremented in place and **never pruned**. It is deliberately a
  different kind of number from anything derivable from
  `federation_dead_letters`: that ledger dedupes pending fires and prunes
  terminal rows, so a count over it silently shrinks. See the migration
  `20260728000100_create_federation_dead_letter_stats.exs` for the full
  argument.

  ## The counter vocabulary is not the disposition vocabulary

  `counters/0` is `"recorded"` plus `DeadLetter.terminal_dispositions/0` — read
  from there rather than re-declared, for the reason `DeadLetter` states about
  its own list.

    * `recorded` — an ARRIVAL. Bumped on every `DeadLetters.record/1` attempt,
      including the ones the ledger's partial unique index collapsed. This is
      the total loss ever.
    * the terminal dispositions — where those losses WENT. Each is bumped once,
      when a row first enters that disposition.

  The live dispositions (`pending`, `replaying`) are absent on purpose. They
  describe a state, not an outcome, and stage 3's drain moves a row in and out
  of `replaying` whenever a runtime flaps — a cumulative count of them would
  measure flapping and would break the accounting invariant. The live term
  comes from the ledger, which never prunes a live row.
  """
  use Ecto.Schema

  alias Platform.Federation.DeadLetter

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  @recorded "recorded"
  @counters [@recorded | DeadLetter.terminal_dispositions()]

  @type t :: %__MODULE__{}

  schema "federation_dead_letter_stats" do
    field(:runtime_id, :string)
    field(:responsibility_key, :string)
    field(:trigger_kind, :string)
    field(:disposition, :string)
    field(:count, :integer, default: 0)
    field(:first_at, :utc_datetime_usec)
    field(:last_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The closed counter vocabulary: `recorded` plus every terminal disposition."
  @spec counters() :: [String.t()]
  def counters, do: @counters

  @doc "The arrival counter's name."
  @spec recorded() :: String.t()
  def recorded, do: @recorded

  @doc "Terminal-outcome counters — `counters/0` without the arrival counter."
  @spec outcome_counters() :: [String.t()]
  def outcome_counters, do: DeadLetter.terminal_dispositions()
end
