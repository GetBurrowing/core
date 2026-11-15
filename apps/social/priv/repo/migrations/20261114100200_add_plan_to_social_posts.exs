defmodule Platform.Repo.Migrations.AddPlanToSocialPosts do
  @moduledoc """
  Social Studio slice A: the internal plan, the `planned` status, and the
  flow boundary CHECKs.

    * `planned_by_user_id` (FK users, nilified),
      `planned_set_at`. The planned time itself is the existing `scheduled_at`.
    * `social_posts_status_check` gains `planned`;
      `social_posts_approved_needs_approver_check` gains `planned` (a plan
      needs an approver and an approval time).
    * `social_posts_planned_only_studio_check`: `planned` is Studio-only.
    * `social_posts_studio_boundary_check`: a Studio row is confined to
      draft, needs_approval, approved and planned, and can hold no vendor id
      (`external_id`, `external_url`, `analytics_external_id`) and no publish
      timer (`publish_after`). It is the SECOND line of defence: it cannot
      undo an external send, so every send-side code path refuses a Studio
      row first.

  Additive and widening for existing rows (all `legacy`); `down/0` restores
  the two original CHECKs.

  Ships with Social as a build-time module's migration (ADR 0055).
  """

  use Ecto.Migration

  # old-code-compatible: additive and widening: two nullable columns, an index, a status CHECK
  # and approver CHECK that are supersets of the old ones, and two CHECKs that
  # constrain only flow = 'studio' rows, which the previous release never writes.
  # With Studio rows present, old code could meet status 'planned' and the
  # boundary CHECK would refuse its send-side writes only after an external send.
  # Safe for the previous release only while no Studio rows exist; once they do,
  # rollback is barred by listing 20261114100000 in
  # deployment/release/irreversible-migrations.txt (the updater refuses to roll
  # back from the release that crossed it). This waiver depends on that listing.

  # planned_by_user_id, planned_set_at, planned status, boundary CHECKs.

  def up do
    alter table(:social_posts) do
      add(:planned_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:planned_set_at, :utc_datetime_usec)
    end

    create(index(:social_posts, [:planned_by_user_id]))

    drop(constraint(:social_posts, :social_posts_status_check))
    drop(constraint(:social_posts, :social_posts_approved_needs_approver_check))

    create(
      constraint(:social_posts, :social_posts_status_check,
        check:
          "status IN ('draft', 'needs_approval', 'approved', 'planned', 'scheduled', 'published', 'failed')"
      )
    )

    create(
      constraint(:social_posts, :social_posts_approved_needs_approver_check,
        check:
          "status NOT IN ('approved', 'planned', 'scheduled', 'published') OR " <>
            "(approved_by_user_id IS NOT NULL AND approved_at IS NOT NULL)"
      )
    )

    create(
      constraint(:social_posts, :social_posts_planned_only_studio_check,
        check: "status <> 'planned' OR flow = 'studio'"
      )
    )

    create(
      constraint(:social_posts, :social_posts_studio_boundary_check,
        check:
          "flow = 'legacy' OR (" <>
            "status IN ('draft', 'needs_approval', 'approved', 'planned') AND " <>
            "external_id IS NULL AND external_url IS NULL AND " <>
            "analytics_external_id IS NULL AND publish_after IS NULL)"
      )
    )
  end

  def down do
    drop(constraint(:social_posts, :social_posts_studio_boundary_check))
    drop(constraint(:social_posts, :social_posts_planned_only_studio_check))
    drop(constraint(:social_posts, :social_posts_approved_needs_approver_check))
    drop(constraint(:social_posts, :social_posts_status_check))

    create(
      constraint(:social_posts, :social_posts_status_check,
        check:
          "status IN ('draft', 'needs_approval', 'approved', 'scheduled', 'published', 'failed')"
      )
    )

    create(
      constraint(:social_posts, :social_posts_approved_needs_approver_check,
        check:
          "status NOT IN ('approved', 'scheduled', 'published') OR " <>
            "(approved_by_user_id IS NOT NULL AND approved_at IS NOT NULL)"
      )
    )

    drop(index(:social_posts, [:planned_by_user_id]))

    alter table(:social_posts) do
      remove(:planned_set_at)
      remove(:planned_by_user_id)
    end
  end
end
