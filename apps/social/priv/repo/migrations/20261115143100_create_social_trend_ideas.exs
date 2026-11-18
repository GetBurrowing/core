defmodule Platform.Repo.Migrations.CreateSocialTrendIdeas do
  @moduledoc """
  Social (ADR 0055) records one idea per profile and external source item,
  so repeated or concurrent requests resolve to the same idea.
  """
  use Ecto.Migration

  # old-code-compatible: old releases do not use this new mapping table.
  def change do
    create table(:social_trend_ideas, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:idea_id, references(:social_ideas, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:source, :text, null: false)
      add(:story_id, :text, null: false)
    end

    create(unique_index(:social_trend_ideas, [:profile_id, :source, :story_id]))
  end
end
