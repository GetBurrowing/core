defmodule Platform.Tasks.CanvasAttachment do
  @moduledoc """
  Schema for a task → canvas attachment (task_attach_canvas, stage 1).

  A `CanvasAttachment` is a soft-reference join row linking a task to
  a canvas that's relevant context for it. The MCP tool surface lets
  agents and users pin canvases (bug screenshots, design docs, review
  evidence sheets) to a task so the dispatch bundler can surface them
  to downstream agents alongside the task body.

  ## Cardinality

    * `task_id` → `tasks.id`, `belongs_to`, FK with
      `ON DELETE CASCADE` at the DB layer. Attachments die with the
      task.

    * `canvas_id` is a soft reference (`binary_id`, no FK). Canvases
      live in spaces; deleting a canvas leaves the attachment row
      stale, not broken. Consumers (stage 4 dispatch bundler) treat a
      missing canvas as a no-op, not an error.

  ## Idempotent re-attach

  `(task_id, canvas_id)` is unique (DB index
  `:task_canvas_attachments_pair_idx`). The MCP tool surface treats a
  unique-constraint violation as success — re-attaching the same
  canvas is a no-op rather than a duplicate row.

  ## Attribution

  `attached_by_kind` is `"agent"` or `"user"` — mirroring the
  existing review-item / message-author conventions. `attached_by_id`
  is the corresponding agent or user id; we don't carry separate
  `agent_id` / `user_id` columns because the kind+id pair is the
  canonical attribution shape across the schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Tasks.Task

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @attached_by_kinds ~w(agent user)

  schema "task_canvas_attachments" do
    belongs_to(:task, Task, foreign_key: :task_id)
    field(:canvas_id, :binary_id)
    field(:note, :string)
    field(:attached_by_kind, :string)
    field(:attached_by_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  def attached_by_kinds, do: @attached_by_kinds

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :task_id,
      :canvas_id,
      :note,
      :attached_by_kind,
      :attached_by_id
    ])
    |> validate_required([:task_id, :canvas_id, :attached_by_kind, :attached_by_id])
    |> validate_inclusion(:attached_by_kind, @attached_by_kinds)
    |> unique_constraint([:task_id, :canvas_id],
      name: :task_canvas_attachments_pair_idx
    )
    |> foreign_key_constraint(:task_id)
  end
end
