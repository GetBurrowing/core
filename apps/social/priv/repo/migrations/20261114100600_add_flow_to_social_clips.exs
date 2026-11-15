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

  # old-code-compatible: additive: flow is NOT NULL with default 'legacy', so every clip the
  # previous release inserts satisfies the CHECK. With Studio clips present, old
  # code would treat them as legacy clips.
  # Safe for the previous release only while no Studio rows exist; once they do,
  # rollback is barred by listing 20261114100000 in
  # deployment/release/irreversible-migrations.txt (the updater refuses to roll
  # back from the release that crossed it, once the crossing run completes; an
  # interrupted crossing run is not covered). This waiver depends on that listing.

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
