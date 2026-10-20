defmodule Platform.Repo.Migrations.AddAuthoredByToMemoryInsights do
  @moduledoc """
  Task `01a15587-afc8-7000-b76d-4e1c48eee5ed`, stage 2: record who wrote an
  insight's block.

  `memory_insights.authored_by` is the `authored_by` of the journal entry the
  block was ingested from (an agent id or a user id), or NULL when the
  writer is unknown (the `Platform.Org.Context` journal-file hook). Only an
  insight authored by the current `memory.dreaming` holder may be acted on
  unattended (`Platform.Memory.Insights.Unattended.eligible?/1`).

  Nullable and with no foreign key on purpose: the value names either an
  agent or a user, and it is only ever compared for equality, never joined.
  Existing rows stay NULL, so none of them becomes eligible.
  """

  use Ecto.Migration

  def change do
    alter table(:memory_insights) do
      add(:authored_by, :uuid)
    end
  end
end
