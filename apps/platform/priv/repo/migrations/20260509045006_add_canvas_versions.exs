defmodule Platform.Repo.Migrations.AddCanvasVersions do
  use Ecto.Migration

  @moduledoc """
  Canvas version history (task 019e0ac0).

  Each row is a full document snapshot at a given revision. The version row
  is written in the same path as the canvas mutation it records — successful
  `create_canvas` produces revision 1, each successful `patch_canvas` produces
  revision N+1. Rejected patches do NOT produce a row (the existing rejection
  contract is preserved).

  `written_by` is denormalized so canvas history survives later participant
  deletions. `ops` holds the patch ops list that produced the version (or nil
  for the initial create). `document` is the post-mutation full document.

  Composite unique index on (canvas_id, revision) is the primary lookup +
  the integrity guarantee that a single canvas never has two rows at the
  same revision. BRIN on (canvas_id, written_at) is for cheap time-range
  scans without paying btree-index cost on what is essentially append-only
  data.
  """

  def change do
    create table(:canvas_versions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:canvas_id, references(:chat_canvases, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:revision, :integer, null: false)
      add(:document, :map, null: false)
      add(:ops, :map)
      add(:written_by, :map, null: false)
      add(:written_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:canvas_versions, [:canvas_id, :revision]))
    create(index(:canvas_versions, [:canvas_id, :written_at], using: :brin))
  end
end
