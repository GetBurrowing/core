defmodule Platform.Repo.Migrations.AddFlowToSocialClips do
  @moduledoc """
  Social Studio slice A (design owner addition): a durable Studio marker on
  clips, the same shape as `social_posts.flow`. `legacy` (default, every
  existing clip) or `studio`, with `social_clips_flow_check`. Provenance is
  this column, never inferred from the profile's `studio_enabled` toggle.
  In no cast list; Studio intake sets it at insert.

  Ships with Social as a build-time module's migration (ADR 0055).
  """

  use Ecto.Migration

  # add_flow_to_social_clips.

  def up do
    alter table(:social_clips) do
      add(:flow, :text, null: false, default: "legacy")
    end

    create(
      constraint(:social_clips, :social_clips_flow_check, check: "flow IN ('legacy', 'studio')")
    )
  end

  def down do
    drop(constraint(:social_clips, :social_clips_flow_check))

    alter table(:social_clips) do
      remove(:flow)
    end
  end
end
