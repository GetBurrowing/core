defmodule Platform.Repo.Migrations.CreateSocialIdeaVotes do
  @moduledoc """
  Persists one vote per authenticated actor and idea without changing existing
  ideas or posts. Extension-local migration ownership follows ADR 0055:
  0055-extension-contract-and-build-time-modules.md § 6. Migrations.
  Rolling back removes the vote records, not their ideas or linked posts.
  """
  use Ecto.Migration

  # old-code-compatible: additive vote table; old releases do not read it.
  def change do
    create table(:social_idea_votes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:idea_id, references(:social_ideas, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:voter_user_id, references(:users, type: :binary_id, on_delete: :delete_all))
      add(:voter_agent_id, references(:agents, type: :binary_id, on_delete: :delete_all))
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:social_idea_votes, :social_idea_votes_one_actor,
        check: "num_nonnulls(voter_user_id, voter_agent_id) = 1"
      )
    )

    create(
      unique_index(:social_idea_votes, [:idea_id, :voter_user_id],
        where: "voter_user_id IS NOT NULL"
      )
    )

    create(
      unique_index(:social_idea_votes, [:idea_id, :voter_agent_id],
        where: "voter_agent_id IS NOT NULL"
      )
    )

    create(index(:social_idea_votes, [:profile_id]))
  end
end
