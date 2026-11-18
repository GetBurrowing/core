defmodule Platform.Repo.Migrations.AddStudioEnabledToSocialProfiles do
  @moduledoc """
  Social Studio slice A: `social_profiles.studio_enabled`, off by default.
  In no cast list; only `Platform.Social.Studio.set_enabled/4` writes it.

  Ships with Social as a build-time module's migration (ADR 0055).
  """

  use Ecto.Migration

  # add_studio_enabled_to_social_profiles.

  def change do
    alter table(:social_profiles) do
      add(:studio_enabled, :boolean, null: false, default: false)
    end
  end
end
