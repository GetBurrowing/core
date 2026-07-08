defmodule Platform.Repo.Migrations.AddSecurityGuardToRolesCheck do
  use Ecto.Migration

  @moduledoc """
  Extend the `roles_key_check` CHECK constraint to admit the new
  `security_guard` role (task `019f3e8e-4406`, stage 1 — see ADR-0043).

  Adds `security_guard` to the closed-roster enum enforced at the DB
  layer by `roles_key_check`, mirroring the changeset-level
  `@valid_keys` update in `Platform.Roles.Role`. Follows the same shape
  as `20260702000000_add_meeting_producer_to_roles_check.exs`.

  `down/0` reverts to the pre-existing five-key roster
  (designer / historian / meeting_scribe / meeting_producer /
  triage_officer). Data-safety note: if a `roles` row with
  `key = 'security_guard'` already exists at rollback time, restoring
  the old CHECK will fail — that's the intended failure mode. The
  paired seed migration must be rolled back first.

  Deferred to stage 2+: the `Platform.Security.Sweeper` runtime + the
  four scanner bodies. This stage lands only the declarative shell.
  """

  def up do
    drop(constraint(:roles, :roles_key_check))

    create(
      constraint(:roles, :roles_key_check,
        check:
          "key IN ('designer','historian','meeting_scribe','meeting_producer','triage_officer','security_guard')"
      )
    )
  end

  def down do
    drop(constraint(:roles, :roles_key_check))

    create(
      constraint(:roles, :roles_key_check,
        check:
          "key IN ('designer','historian','meeting_scribe','meeting_producer','triage_officer')"
      )
    )
  end
end
