defmodule Platform.Repo.Migrations.AddRecycledFromIdeaId do
  @moduledoc """
  Task 01a16c51: links recycled Inbox ideas to their measured original and
  prevents duplicate children when concurrent recycle requests race.
  """
  use Ecto.Migration

  def change do
    alter table(:social_ideas) do
      add(
        :recycled_from_idea_id,
        references(:social_ideas, type: :binary_id, on_delete: :restrict)
      )
    end

    create(
      unique_index(:social_ideas, [:recycled_from_idea_id],
        where: "recycled_from_idea_id IS NOT NULL"
      )
    )
  end
end
