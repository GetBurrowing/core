defmodule Platform.Lifecycle.StepRun do
  @moduledoc """
  Schema for the `lifecycle_step_runs` table — one durable row per step of
  one firing of one lifecycle hook edge (ADR-0046 Amendment 1,
  task 019fe1b6 stage 1).

  Storage only. Nothing here runs a step.

  ## `run_seq` groups a firing

  All rows written by a single firing of `(task_id, edge)` share a
  `run_seq`. A three-step pipeline firing once writes three rows at
  `run_seq = 1`. Anything asking "how many times did this edge fire?" must
  count DISTINCT `run_seq` — see `Platform.Lifecycle.Runs.run_count/2`.

  ## The status vocabulary, and why no two values may be collapsed

  `status` is an extensible string enum: a plain string column with no DB
  CHECK, guarded solely by `validate_inclusion(:status, @statuses)` below.
  Adding a status needs no migration.

  Six values, and the three failure-adjacent ones are distinct on purpose:

    * `started` — the row was written when the step was dispatched and has
      not resolved yet.
    * `completed` — the step ran and returned normally.
    * `diverted` — the step ran and sent the task back. Only a step declared
      `can_divert` can produce this; the first divert halts the remainder of
      the pipeline (Amendment 1 decision 4).
    * `failed` — the step RAN and returned an error.
    * `timed_out` — the step was KILLED by a budget. It is not `failed`,
      because the budget-kill question ("is this pipeline's budget too
      tight?") and the step-error question ("is this step broken?") have
      different answers and different fixes. A schema that cannot tell them
      apart cannot answer either.
    * `suppressed` — the run NEVER EXECUTED ANYTHING; the re-entry bound
      refused it. It is neither `failed` nor `timed_out`: no step code ran,
      so there is nothing to blame and nothing to retry differently.

  This is the same discipline ADR-0046 states for `not_applicable` vs
  `failed` in `### Per-step outcome` — "must never be conflated" — applied
  to the runner's richer vocabulary. Note that the ADR's own table names
  `not_applicable / complete / failed`; the six values here are the
  runner-tier extension of it, not a contradiction of it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(started completed diverted failed timed_out suppressed)

  @type t :: %__MODULE__{}

  schema "lifecycle_step_runs" do
    belongs_to(:task, Platform.Tasks.Task)
    field(:edge, :string)
    field(:run_seq, :integer)
    field(:step_name, :string)
    field(:position, :integer)
    field(:awaited, :boolean)
    field(:can_divert, :boolean)
    field(:status, :string)
    field(:reason, :string)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The allowed `status` values (extensible enum guarded by the changeset)."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Changeset for a step run.

  `step_name` and `position` are deliberately NOT required: a suppressed run
  never picked a step.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :task_id,
      :edge,
      :run_seq,
      :step_name,
      :position,
      :awaited,
      :can_divert,
      :status,
      :reason,
      :started_at,
      :finished_at
    ])
    |> validate_required([:task_id, :edge, :run_seq, :awaited, :can_divert, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:run_seq, greater_than: 0)
    |> foreign_key_constraint(:task_id)
  end
end
