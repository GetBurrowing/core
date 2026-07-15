defmodule Platform.Tasks.ChatPin do
  @moduledoc """
  Schema for a task → chat pin (Pin-to-Chat, stage 2, task 019f62a1).

  A `ChatPin` marks that a specific participant (user or agent) has
  pinned a task's execution chat space to their sidebar. It's the join
  row `Platform.Tasks.ChatPins` writes when the sponsor pins a task and
  reads to surface the `Pinned` rail section for each participant.

  ## Naming note

  Called `Platform.Tasks.ChatPin` (NOT `Platform.Tasks.Pin`) because
  `Platform.Chat.Pin` already exists for the message-level pin surface
  (`chat_live` bookmark icon). Keeping the two pin concepts as distinct
  modules avoids alias collisions in every file that touches both.

  ## Cardinality

    * `task_id` — FK into `tasks(id)` with `ON DELETE CASCADE`. Pins die
      with the task.

    * `(participant_kind, participant_id)` — the pinning identity.
      `participant_kind` is `"user"` or `"agent"`. `participant_id` is
      an email for users and an agent slug for agents; stored as text so
      one column carries either shape.

  ## Idempotency

  DB-level `unique_index(:task_id, :participant_kind, :participant_id)`
  enforces that a `(task, participant)` pair has at most one row. The
  context layer relies on this constraint plus `on_conflict: :nothing`
  to make `ChatPins.pin/3` idempotent — repeated pins from the same
  mentioner short-circuit rather than duplicate rows or crash.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Tasks.Task

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @participant_kinds ~w(user agent)

  schema "task_chat_pins" do
    belongs_to(:task, Task, foreign_key: :task_id)
    field(:participant_kind, :string)
    field(:participant_id, :string)
    field(:pinned_by, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Canonical participant kinds accepted at the schema layer."
  @spec participant_kinds() :: [String.t()]
  def participant_kinds, do: @participant_kinds

  @doc """
  Changeset for a new pin row.

  Requires all four fields. Validates `participant_kind` inclusion so
  callers can't stash arbitrary strings (which would silently break the
  rail-lookup query). Unique constraint mirrors the DB index name so a
  duplicate insert surfaces as a changeset error rather than an
  Ecto raise.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(pin, attrs) do
    pin
    |> cast(attrs, [:task_id, :participant_kind, :participant_id, :pinned_by])
    |> validate_required([:task_id, :participant_kind, :participant_id, :pinned_by])
    |> validate_inclusion(:participant_kind, @participant_kinds)
    |> unique_constraint([:task_id, :participant_kind, :participant_id],
      name: :task_chat_pins_task_participant_idx
    )
    |> foreign_key_constraint(:task_id)
  end
end
