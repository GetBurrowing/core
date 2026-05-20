defmodule Platform.Repo.Migrations.CreateOrgHistorianCursors do
  use Ecto.Migration

  @moduledoc """
  T1 stage 3 — create `org_historian_cursors` per ADR-0041 (Org Wiki).

  The Historian agent (T6) walks corpora (pages, journal, messages,
  transcripts, ...) and remembers per-workspace progress here. The
  cursor format is corpus-defined — a UUID for some, a bigserial string
  for others — so `last_processed_id` is opaque `:text`.

  Composite primary key on `(workspace_id, corpus)` — one cursor per
  workspace per corpus. No Ecto schema module in this stage; T6 builds
  `Platform.Agents.HistorianCursor` (or sibling) when it wires the
  schedule + triggers.
  """

  def change do
    create table(:org_historian_cursors, primary_key: false) do
      add(:workspace_id, :uuid, null: false, primary_key: true)
      add(:corpus, :text, null: false, primary_key: true)

      add(:last_processed_id, :text, null: true)
      add(:last_processed_at, :utc_datetime_usec, null: true)
      add(:last_run_at, :utc_datetime_usec, null: true)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:org_historian_cursors, [:workspace_id]))
  end
end
