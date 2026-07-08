defmodule Platform.Repo.Migrations.AddArchitectToRolesCheck do
  use Ecto.Migration

  @moduledoc """
  Extend the `roles_key_check` CHECK constraint to admit the new
  `architect` role (task 019f3da3 stage 1 — ADR-0044).

  Adds `architect` to the closed-roster enum enforced at the DB layer
  by `roles_key_check`, mirroring the changeset-level `@valid_keys`
  update in `Platform.Roles.Role`. The `architect` role bundles the
  three placeholder responsibilities registered in this same stage:
  `architecture.review_plan`, `architecture.audit_diff`, and
  `architecture.cron_sweep`.

  IMPORTANT: this migration runs AFTER task 019f3e8e's
  `20260708000000_add_security_guard_to_roles_check.exs` in prod,
  which admitted `security_guard`. The re-created CHECK constraint
  MUST include every key already valid in prod at this migration's
  timestamp — including `security_guard` — or the constraint fails
  against the existing `security_guard` roles row. The `up/0` list
  below is therefore the SEVEN-key roster (six previously-admitted
  keys + `architect`).

  `down/0` reverts to the six-key roster (five legacy roles +
  `security_guard` from task 019f3e8e). Data-safety note: if a
  `roles` row with `key = 'architect'` already exists at rollback
  time, restoring the old CHECK will fail — that's the intended
  failure mode (silently dropping the row would be worse). The seed
  row for the `architect` role is inserted via
  `Platform.Roles.Seeds.seed_defaults/0` (called from the pre-existing
  seed migrations), so a paired rollback requires clearing the row
  first.

  Deferred to stages 2-5 of ADR-0044: hook sites, real prompt
  templates, cron sweep, and the timeline doc.
  """

  def up do
    drop(constraint(:roles, :roles_key_check))

    create(
      constraint(:roles, :roles_key_check,
        check:
          "key IN ('designer','historian','meeting_scribe','meeting_producer','triage_officer','security_guard','architect')"
      )
    )
  end

  def down do
    drop(constraint(:roles, :roles_key_check))

    create(
      constraint(:roles, :roles_key_check,
        check:
          "key IN ('designer','historian','meeting_scribe','meeting_producer','triage_officer','security_guard')"
      )
    )
  end
end
