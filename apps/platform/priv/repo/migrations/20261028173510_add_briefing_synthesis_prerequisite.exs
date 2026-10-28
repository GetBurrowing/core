defmodule Platform.Repo.Migrations.AddBriefingSynthesisPrerequisite do
  use Ecto.Migration

  def change do
    alter table(:meeting_completion_runs) do
      add(:synthesis, :map, null: false, default: %{})
    end
  end
end
