defmodule Platform.Repo.Migrations.CreateTaskCanvasAttachments do
  use Ecto.Migration

  @moduledoc """
  Task Canvas Attachments — stage 1 (task 019ef734).

  Creates the soft-reference attachment table the new
  `task_attach_canvas` MCP tool will write to: a join row linking a
  task to a canvas that's relevant context for it (a screenshot of a
  bug, a design doc, a review evidence sheet, etc.).

  ## Cardinality

    * `task_id` — FK into `tasks(id)` with `ON DELETE CASCADE`.
      Attachments die with the task; there is no value in keeping
      orphan attachments around once the task is hard-deleted.

    * `canvas_id` — soft reference, `binary_id`, **no FK**. Canvases
      live in spaces; deleting a canvas should leave the attachment
      row stale (the lookup yields nothing) rather than cascade into
      the task surface. The planner explicitly chose this so canvas
      lifecycle stays decoupled from task lifecycle.

  ## Indexes

    * `unique_index(:task_id, :canvas_id)` so re-attaching the same
      canvas to the same task is idempotent — the MCP tool can
      `INSERT … ON CONFLICT DO NOTHING` or trap a unique_violation
      and treat it as success.

    * Plain `index(:task_id)` so the dispatch-bundler (stage 4) can
      list a task's attached canvases without a sequential scan.

  This stage ships the migration plus the `Platform.Tasks.CanvasAttachment`
  schema module. Deferred to later stages: context wrapper (stage 2),
  MCP tools (stage 3), dispatch bundler (stage 4), LiveView surface
  (stage 5).
  """

  def change do
    create table(:task_canvas_attachments, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :task_id,
        references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:canvas_id, :binary_id, null: false)
      add(:note, :text, null: true)
      add(:attached_by_kind, :string, null: false)
      add(:attached_by_id, :binary_id, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:task_canvas_attachments, [:task_id, :canvas_id],
        name: :task_canvas_attachments_pair_idx
      )
    )

    create(index(:task_canvas_attachments, [:task_id]))
  end
end
