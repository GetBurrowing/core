defmodule Platform.Repo.Migrations.CreateMeetingWhiteboards do
  @moduledoc """
  Task `019fcfcf-c9bd-7b41-a10e-a7b6750e25df`, stage 1 — persistence for
  the meeting whiteboard (an Excalidraw scene) so a drawing survives a
  reload, a rejoin, and the end of the meeting.

  ## Shape

  Exactly ONE board per meeting in v1, enforced by a unique index on
  `meeting_id` rather than by convention. The alternative — many boards
  per meeting with a "current" pointer — buys a tab strip nobody has
  asked for and costs a second source of truth about which scene is
  live.

  ## Columns

    * `meeting_id` — FK `meetings`, `on_delete: :delete_all`, NOT NULL,
      UNIQUE. The board is meaningless without its meeting and dies
      with it.
    * `scene` — `:map`, default `%{}`. The authoritative `.excalidraw`
      payload: the `elements` list, the subset of `appState` worth
      persisting, and `files` (embedded images). Stored whole rather
      than shredded into element rows because the editor reads and
      writes whole scenes; an element table would be a schema that only
      ever round-trips.
    * `scene_version` — integer, NOT NULL, default 0. Monotonic
      optimistic-concurrency counter. v1 is SINGLE-EDITOR: this column
      is what makes last-writer-wins detectable instead of silent. A
      save arriving with an expected version below the stored one is
      rejected, not merged — there is deliberately no reconciler, no
      OT, and no CRDT here.
    * `last_edited_by_user_id` — FK `users`, `on_delete: :nilify_all`,
      NULLABLE. Attribution is a nice-to-have; the drawing is the
      durable fact, so losing the user must not lose the board.

  ## Deliberate omissions

    * **No history/revision table.** Nothing in this task reads one.
      `scene_version` answers "did I race someone", which is the only
      question v1 asks.
    * **No `space_id`.** It is reachable through `meetings`, and a
      denormalised copy is a column that drifts.
  """

  use Ecto.Migration

  def change do
    create table(:meeting_whiteboards, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :meeting_id,
        references(:meetings, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:scene, :map, default: %{})
      add(:scene_version, :integer, null: false, default: 0)

      add(
        :last_edited_by_user_id,
        references(:users, type: :binary_id, on_delete: :nilify_all)
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:meeting_whiteboards, [:meeting_id]))
  end
end
