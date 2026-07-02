defmodule Platform.Repo.Migrations.AddMeetingProducerToRolesCheck do
  use Ecto.Migration

  @moduledoc """
  Extend the `roles_key_check` CHECK constraint to admit the new
  `meeting_producer` role (task 019f2451, stage 1).

  Adds `meeting_producer` to the closed-roster enum enforced at the DB
  layer by `roles_key_check`, mirroring the changeset-level
  `@valid_keys` update in `Platform.Roles.Role`.

  `down/0` reverts to the pre-existing four-key roster. Data-safety
  note: if a `roles` row with `key = 'meeting_producer'` already
  exists at rollback time, restoring the old CHECK will fail — that's
  the intended failure mode (silently dropping the row would be
  worse). The stage-2 seed row is a separate migration, so a paired
  rollback of both migrations in reverse order avoids the trap.

  Deferred to stage 2: seeding the `meeting_producer` row in
  `Platform.Roles.Seeds` + the matching seed migration. Deferred to
  stage 3: responsibility handler wiring.
  """

  def up do
    drop(constraint(:roles, :roles_key_check))

    create(
      constraint(:roles, :roles_key_check,
        check:
          "key IN ('designer','historian','meeting_scribe','meeting_producer','triage_officer')"
      )
    )
  end

  def down do
    drop(constraint(:roles, :roles_key_check))

    create(
      constraint(:roles, :roles_key_check,
        check: "key IN ('designer','historian','meeting_scribe','triage_officer')"
      )
    )
  end
end
