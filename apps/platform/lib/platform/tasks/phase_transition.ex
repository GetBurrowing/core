defmodule Platform.Tasks.PhaseTransition do
  @moduledoc """
  One observed change of a task's `status`, recorded as it happens.

  Rows are append-only: a transition is a historical fact and is never
  amended. `actor_kind` is a four-value domain (`user` | `agent` | `system` |
  `unknown`) rather than a boolean, because the question the table exists to
  answer is whether an interval was spent waiting on a human or on the
  engine. `unknown` is honest — an unattributed write must be visibly
  unattributed rather than silently counted as engine time.

  There is deliberately no uniqueness over `(task_id, to_status)`: a task
  legitimately re-enters a status many times.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Tasks.Task

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @actor_kinds ~w(user agent system unknown)

  schema "task_phase_transitions" do
    belongs_to(:task, Task)
    field(:from_status, :string)
    field(:to_status, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:actor_kind, :string)
    field(:actor_id, :string)
    field(:actor_label, :string)
    field(:via, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The permitted `actor_kind` values. Read this rather than re-declaring the list."
  def actor_kinds, do: @actor_kinds

  def changeset(transition, attrs) do
    transition
    |> cast(attrs, [
      :task_id,
      :from_status,
      :to_status,
      :occurred_at,
      :actor_kind,
      :actor_id,
      :actor_label,
      :via
    ])
    |> validate_required([:task_id, :to_status, :occurred_at, :actor_kind])
    |> validate_inclusion(:to_status, Task.statuses())
    |> validate_from_status()
    |> validate_inclusion(:actor_kind, @actor_kinds)
    |> foreign_key_constraint(:task_id)
  end

  # `from_status` is nullable — null means "no prior status recorded" — so the
  # inclusion check only applies to a non-nil value.
  defp validate_from_status(changeset) do
    case get_field(changeset, :from_status) do
      nil -> changeset
      _ -> validate_inclusion(changeset, :from_status, Task.statuses())
    end
  end
end
