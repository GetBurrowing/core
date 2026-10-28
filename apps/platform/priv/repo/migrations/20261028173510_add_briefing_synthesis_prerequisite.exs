defmodule Platform.Repo.Migrations.AddBriefingSynthesisPrerequisite do
  @moduledoc """
  Task 01a1830b: persist optional snapshot-scoped synthesis readiness so briefing delivery can wait across restarts until completion or its bounded deadline.
  """
  use Ecto.Migration

  def change do
    alter table(:meeting_completion_runs) do
      add(:synthesis, :map, null: false, default: %{})
    end
  end
end
