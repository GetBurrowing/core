defmodule Platform.Repo.Migrations.AddSocialQualityReview do
  @moduledoc """
  Work 01a20a7a: two-stage Social review, with brand quality reviewers and the content-bound pass
  recorded on a legacy post, before final human approval.

  Existing rows are unchanged: no reviewers and no pass. Only the global
  status CHECK is widened; the Studio boundary and approval CHECK stay intact.
  No post history action is added.
  """
  use Ecto.Migration

  # Listed in deployment/release/irreversible-migrations.txt: older binaries
  # cannot handle quality_review and ignore the quality-pass approval guard.
  # Fix forward; the updater barrier does not protect manual image swaps or
  # other deployment paths. See docs/runbooks/social-quality-review-migration.md.
  def up do
    alter table(:social_profiles) do
      add(:quality_reviewer_user_ids, {:array, :binary_id}, default: [], null: false)
    end

    alter table(:social_posts) do
      add(
        :quality_passed_by_user_id,
        references(:users, type: :binary_id, on_delete: :nilify_all)
      )

      add(:quality_passed_at, :utc_datetime_usec)
      add(:quality_pass_fingerprint, :string)
    end

    create(index(:social_posts, [:quality_passed_by_user_id]))

    drop(constraint(:social_posts, :social_posts_status_check))

    create(
      constraint(:social_posts, :social_posts_status_check,
        check:
          "status IN ('draft', 'quality_review', 'needs_approval', 'approved', 'planned', 'scheduled', 'published', 'failed')"
      )
    )
  end

  def down do
    raise Ecto.MigrationError,
          "refusing to roll back AddSocialQualityReview: older code cannot enforce quality review; fix forward or restore a compatible database and binary together"
  end
end
