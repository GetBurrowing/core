defmodule Platform.Federation.DeadLetter do
  @moduledoc """
  One federation delivery failure, durably recorded (task 019fa56b-ca2d).

  Replaces the in-memory `DeadLetterBuffer`'s anonymous map. The difference that
  matters is not persistence alone — it is that a row carries the *envelope*.
  The old map was `%{runtime_id, agent_id, agent_slug, space_id, reason,
  timestamp}`, which names the failure but not the work; there was nothing in it
  to replay from.

  ## Disposition is a closed vocabulary

  `@dispositions` is exhaustive and enforced by `validate_inclusion/3`, mirroring
  `Platform.Tasks.Plan`'s `@architecture_gate_states` (plan.ex) and for the same
  reason: a disposition outside the list must have no representable value, so a
  typo fails at the write instead of producing a row that every downstream
  `case` silently ignores. Stage 4's counters and stage 5's badge colours both
  key off this list, and a guard that hardcodes its own copy is how the class
  comes back — hence the public `dispositions/0` accessor.

    * `pending` — captured, not yet acted on. The replay work queue.
    * `replaying` — claimed by a drain, delivery in flight. Non-terminal; the
      claim exists so two joins for the same runtime cannot double-deliver.
    * `replayed` — delivered on reconnect. Terminal.
    * `dropped_policy` — the policy declined this KIND of fire (cron, webhook,
      chat). Terminal.
    * `dropped_stale` — the policy would have replayed it, but a freshness
      predicate found the subject had moved on. Terminal, and deliberately
      distinct from `dropped_policy`: "we never replay this kind" and "this one
      specific fire aged out" are different facts about the system.
    * `superseded_duplicate` — collapsed into a newer fire for the same
      `{responsibility_key, subject_id}`. Terminal, and NOT deleted — it stays
      countable so the loss measure keeps it.
    * `abandoned` — exceeded the replay attempt limit. Terminal.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @dispositions ~w(pending replaying replayed dropped_policy dropped_stale superseded_duplicate abandoned)

  # Non-terminal dispositions. `prune/1` must never delete these — they are the
  # live replay queue, and a prune that ate them would turn a cleanup timer into
  # the very loss this table exists to stop.
  @live_dispositions ~w(pending replaying)

  @sources ~w(system_event chat)

  @subject_types ~w(stage plan task)

  @type t :: %__MODULE__{}

  schema "federation_dead_letters" do
    # The PRESENCE TOKEN (`agent_runtimes.runtime_id`), not the pk — this is
    # what `RuntimePresence.online?/1` and the `runtime:<id>` topic key on.
    field(:runtime_id, :string)
    # The `agent_runtimes.id` FK, for joins and UI only.
    field(:runtime_pk, :binary_id)
    field(:agent_id, :binary_id)
    field(:agent_slug, :string)
    field(:space_id, :binary_id)

    field(:source, :string)
    field(:responsibility_key, :string)
    field(:feature, :string)
    field(:trigger_kind, :string)

    field(:subject_type, :string)
    field(:subject_id, :binary_id)

    # The exact envelope that failed to broadcast. Nullable: chat-sourced rows
    # store none on purpose (see `Platform.Federation.DeadLetters`).
    field(:payload, :map)

    field(:reason, :string)
    field(:disposition, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:last_error, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:dispositioned_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The closed disposition vocabulary. Read this; never re-declare it."
  @spec dispositions() :: [String.t()]
  def dispositions, do: @dispositions

  @doc "Dispositions that are still in the replay queue and must survive pruning."
  @spec live_dispositions() :: [String.t()]
  def live_dispositions, do: @live_dispositions

  @doc "Terminal dispositions — eligible for pruning once old enough."
  @spec terminal_dispositions() :: [String.t()]
  def terminal_dispositions, do: @dispositions -- @live_dispositions

  @doc "The two producers that write this ledger."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "Correlation subject kinds a fire can be about."
  @spec subject_types() :: [String.t()]
  def subject_types, do: @subject_types

  @fields ~w(runtime_id runtime_pk agent_id agent_slug space_id source
             responsibility_key feature trigger_kind subject_type subject_id
             payload reason disposition attempts last_error occurred_at
             dispositioned_at)a

  @doc false
  def changeset(dead_letter, attrs) do
    dead_letter
    |> cast(attrs, @fields)
    |> validate_required([:runtime_id, :source, :disposition, :occurred_at])
    |> validate_inclusion(:disposition, @dispositions)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
  end
end
