defmodule Platform.Repo.Migrations.IndexTaskCanvasAttachmentsByCanvas do
  use Ecto.Migration

  @moduledoc """
  Task 019fb01b stage 2 — the index the `:task_agent` canvas grant needs.

  `Platform.Tasks.CanvasAttachments.list_canvas_tasks/1` is the reverse lookup
  (canvas → tasks) behind both of `Platform.Chat.CanvasAccess`'s
  attachment-derived grants: `:task_reader` (task 019e2c4b) and `:task_agent`
  (this task).

  `20260624013019_create_task_canvas_attachments.exs` created the table with
  `unique_index([:task_id, :canvas_id])` (line 59) and `index([:task_id])`
  (line 64). Neither leads with `canvas_id`, and Postgres will not use a
  composite index whose leading column is absent from the predicate, so
  `where a.canvas_id = $1` is a sequential scan today.

  That was survivable while the only caller was one page load per human. It is
  not now: from stages 3 and 4 the lookup runs on every gated MCP canvas read,
  including `canvas.describe`, `canvas.versions` and `canvas_get`.

  Repo precedent for exactly this shape:
  `index(:chat_messages, [:canvas_id])` (20260418120000) and
  `index(:chat_attachments, [:canvas_id])` (20260419120000).

  Plain `create index/2`, not `concurrently`: the table is young and small, and
  every other index in its history was created inside the default
  transactional migration. A concurrent build would need
  `@disable_ddl_transaction` and buys nothing at this row count.
  """

  def change do
    create(index(:task_canvas_attachments, [:canvas_id]))
  end
end
