defmodule Platform.Repo.Migrations.AddComposerProvenanceToSocialPosts do
  @moduledoc """
  Composer 1/5 (task 01a14aca): a nullable jsonb column on `social_posts`
  holding a composed post's POST-SIDE facts (platform, prompt slug,
  composition id, edited?, edit count before send). Every existing row and
  every non-composer post stays NULL. The experiment arm is deliberately not
  stored here; it is on the `experiment_assignments` row of the
  composition. Additive only
  (`0055-extension-contract-and-build-time-modules.md § 6. Migrations`).
  """

  use Ecto.Migration

  def change do
    alter table(:social_posts) do
      add(:composer_provenance, :map, null: true)
    end
  end
end
