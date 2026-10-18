defmodule Platform.Repo.Migrations.AddRolesLockedAtToOrgMemberships do
  @moduledoc """
  Adds `roles_locked_at :utc_datetime_usec` to `org_memberships` to support
  the Stage 3 manual-override overlay on top of the Stage 2 email-domain
  admin rule.

  ## Semantics

  When `roles_locked_at` is non-NULL on a membership row, the self-healing
  hook in `Platform.Accounts` SKIPS evaluation for that row — manual grant
  wins. Two real cases drive this:

    * A contractor with an `@example.com` email who should NOT have admin
      gets `role = :member` AND `roles_locked_at = NOW()` — the rule sees
      the lock and leaves the row alone.

    * A non-Acme collaborator who SHOULD have admin gets `role = :admin`
      AND `roles_locked_at = NOW()` — the rule (which would otherwise
      default them to `:member` on email-change) sees the lock and leaves
      the row alone.

  Setting / clearing the lock is the job of `Platform.Tenancy.promote_to_admin/2`
  and `Platform.Tenancy.revoke_admin/2`. Clearing the lock (re-arming the
  rule for that user) is intentionally NOT exposed as a public API in this
  stage — that's a deliberate ops action for a future stage.

  ## Additive

  Column is nullable; existing rows default to NULL (= rule applies normally).
  No backfill needed.
  """

  use Ecto.Migration

  def up do
    alter table(:org_memberships) do
      add(:roles_locked_at, :utc_datetime_usec)
    end
  end

  def down do
    alter table(:org_memberships) do
      remove(:roles_locked_at)
    end
  end
end
