defmodule Platform.Repo.Migrations.CreateSocialPostApprovals do
  @moduledoc """
  Social Studio slice A: one receipt per approval, bound to
  `(post, version, account)`. Rows are never deleted: a new version moves a
  `current` row to `superseded`, a withdrawal to `revoked`. `post_id` and
  `account_id` are `restrict`, so a post that has a receipt cannot be removed
  by an FK cascade either. At most one `current` row per post (partial unique
  index `social_post_approvals_one_current`). No backfill: legacy posts get
  no rows.

  Ships with Social as a build-time module's migration (ADR 0055).
  """

  use Ecto.Migration

  # old-code-compatible: a new table the previous release never reads or writes; its partial
  # unique index and NOT NULL columns apply only to rows Studio inserts. With
  # receipts present, its restrict FKs would refuse old code deleting a receipted
  # post, account or approving user.
  # Safe for the previous release only while no Studio rows exist; once they do,
  # rollback is barred by listing 20261114100000 in
  # deployment/release/irreversible-migrations.txt (the updater refuses to roll
  # back from the release that crossed it). This waiver depends on that listing.

  # create_social_post_approvals.

  def up do
    create table(:social_post_approvals, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:post_id, references(:social_posts, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:version, :integer, null: false)

      add(:account_id, references(:social_accounts, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:approved_by_user_id, references(:users, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:approved_at, :utc_datetime_usec, null: false)
      add(:state, :text, null: false, default: "current")
      add(:ended_at, :utc_datetime_usec)
      add(:ended_by_kind, :text)
      add(:ended_by_id, :binary_id)
      add(:ended_reason, :text)
      add(:content_fingerprint, :text, null: false)
      add(:snapshot, :map, null: false, default: %{})
    end

    create(index(:social_post_approvals, [:post_id, :version]))
    create(index(:social_post_approvals, [:account_id]))
    create(index(:social_post_approvals, [:approved_by_user_id]))

    create(
      unique_index(:social_post_approvals, [:post_id],
        where: "state = 'current'",
        name: :social_post_approvals_one_current
      )
    )

    create(
      constraint(:social_post_approvals, :social_post_approvals_state_check,
        check: "state IN ('current', 'superseded', 'revoked')"
      )
    )

    create(
      constraint(:social_post_approvals, :social_post_approvals_version_check,
        check: "version >= 1"
      )
    )
  end

  def down do
    drop(table(:social_post_approvals))
  end
end
