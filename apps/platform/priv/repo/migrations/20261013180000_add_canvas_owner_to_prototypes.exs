defmodule Platform.Repo.Migrations.AddCanvasOwnerToPrototypes do
  @moduledoc """
  Task 01a1316b-677a stage 1: a `scripts: true` canvas embed runs as a
  single-file prototype OWNED by its canvas node.

    * `canvas_id` — the owning canvas. `on_delete: :nilify_all`, so a
      hard-deleted canvas leaves an ordinary prototype that normal retention
      then reclaims (`Platform.Prototypes.Purger`).
    * `canvas_node_id` — the embed node's id within that canvas. Node ids are
      canvas-local strings, not UUIDs.
    * One prototype per (canvas, node): a partial unique index, because every
      prototype that is not canvas-owned has both columns NULL.
  """

  use Ecto.Migration

  def change do
    alter table(:prototypes) do
      add(:canvas_id, references(:chat_canvases, type: :binary_id, on_delete: :nilify_all))
      add(:canvas_node_id, :string)
    end

    create(
      unique_index(:prototypes, [:canvas_id, :canvas_node_id],
        where: "canvas_id IS NOT NULL",
        name: :prototypes_canvas_node_index
      )
    )
  end
end
