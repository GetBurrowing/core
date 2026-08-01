defmodule Platform.Repo.Migrations.AddExternalToOrgMemberships do
  @moduledoc """
  Stack member 1 (rbac-external-users) — stage 1.

  Adds the **external-user marker** to `org_memberships` as an ADDITIVE
  BOOLEAN column `external`, orthogonal to `role`.

  ## Why a boolean, not a third role value

  `role` is the PRIVILEGE axis (`admin | member`) driven by a self-healing
  state machine (`derive_role_from_email/1`, `apply_derived_role/1`, the
  `roles_locked_at` lock, `promote_to_admin/2` / `revoke_admin/2`, the audit
  bridge). "External" is ORTHOGONAL to privilege — a scoped external user is
  a member-level participant in allowlisted spaces that additionally carries
  a segregation marker (enforced downstream by M6/M7/M8). Modelling it as a
  boolean lets the two axes vary independently and keeps 'external admin'
  expressible.

  Additive and backwards-compatible: **no change** to
  `org_memberships_role_check`, no data migration. Existing admin/member
  rows are untouched (default `false`).

  Admitted by task 019f8837 stages 1-3 — external-users schema foundation
  (rbac-external-users stack member M1, the only member adding migrations).
  """

  use Ecto.Migration

  def change do
    alter table(:org_memberships) do
      add(:external, :boolean, null: false, default: false)
    end
  end
end
