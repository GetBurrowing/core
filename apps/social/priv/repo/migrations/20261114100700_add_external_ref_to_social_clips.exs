defmodule Platform.Repo.Migrations.AddExternalRefToSocialClips do
  @moduledoc """
  Social Studio slice C (ADR 0055): the idempotency key and the
  stored claim for clips imported through `Platform.Social.Intake`.

    * `external_ref`: the exporter's stable name for the clip (for example
      `<project name>/<candidate id>`). Unique per profile, only where set, so
      every existing clip (null) is unaffected and no data migration runs.
    * `import_claim`: what the manifest said, kept as a claim and never read as
      a decision: `approval_claim` (the exporter's own approval status) and
      `payload_sha256` (a digest of the imported fields, so a replay can tell
      an equivalent entry from a reused ref with different content).
  """

  use Ecto.Migration

  def change do
    alter table(:social_clips) do
      add(:external_ref, :text)
      add(:import_claim, :map)
    end

    create(
      unique_index(:social_clips, [:profile_id, :external_ref],
        where: "external_ref IS NOT NULL",
        name: :social_clips_profile_external_ref_index
      )
    )

    create(
      constraint(:social_clips, :social_clips_external_ref_check,
        check: "external_ref IS NULL OR (char_length(external_ref) BETWEEN 1 AND 200)"
      )
    )
  end
end
