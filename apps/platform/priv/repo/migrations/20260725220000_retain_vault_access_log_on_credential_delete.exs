defmodule Platform.Repo.Migrations.RetainVaultAccessLogOnCredentialDelete do
  @moduledoc """
  Makes the vault access log survive the deletion of the credential it describes.

  ## Supersedes 20260314070000_fix_vault_access_log_fk

  That migration changed `vault_access_log.credential_id` from `ON DELETE NO
  ACTION` to `ON DELETE CASCADE`, on the reasoning that "log entries are
  subordinate to the credential they describe". It was solving a real problem:
  `NO ACTION` made a credential with any history undeletable, which is worse
  than the alternative it chose. But `CASCADE` means the database destroys the
  audit trail whenever a credential is destroyed, which contradicts both
  ADR 0006 ("the vault_access_log is append-only") and the `Platform.Vault.AccessLog`
  moduledoc ("An immutable access log entry. Append-only — no changeset, never
  updated or deleted"). A trail that disappears exactly when someone revokes a
  credential is missing the event most worth auditing.

  The 2026-03-14 decision weighed `NO ACTION` against `CASCADE` and picked the
  lesser evil of the two. `ON DELETE SET NULL` is the third option it did not
  consider, and it satisfies both constraints at once: credentials stay
  deletable, and their history stays on disk.

  ## Why not soft-delete the credential instead

    * A soft-deleted credential keeps its Cloak ciphertext on disk. For a vault,
      "delete" has to actually destroy key material — an operator who revokes a
      secret is asking for the bytes to be gone, not hidden.
    * Soft-delete would force an `is_nil(deleted_at)` filter into the unique
      index `vault_credentials_unique_slug_per_scope`. That index would then
      refuse to re-create a credential at a previously-deleted slug, breaking
      `Platform.Vault.put/4` and `put_inline/2` — and `put_inline/2` backs the
      onboarding inline-credential form
      (`platform_web/live/control_center/onboarding_events.ex`), so this is a
      live regression across five-plus call sites.

  ## What this does

  `credential_id` becomes nullable and is nulled out by the constraint when the
  credential goes away. A row whose `credential_id` is null would otherwise be
  unreadable, so `credential_slug` and `credential_scope_type` are denormalised
  onto the log at write time (and backfilled here for existing rows). They are
  deliberately plain columns, not references: their whole job is to outlive the
  row they were copied from.

  Note this migration removes the *database's* half of the problem only.
  `Platform.Vault.delete/2` also purges the log rows explicitly in application
  code; that purge is removed in the next stage. Either one alone destroys the
  trail, so both have to go.
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE vault_access_log ALTER COLUMN credential_id DROP NOT NULL")

    execute("""
    ALTER TABLE vault_access_log
      DROP CONSTRAINT vault_access_log_credential_id_fkey,
      ADD CONSTRAINT vault_access_log_credential_id_fkey
        FOREIGN KEY (credential_id)
        REFERENCES vault_credentials(id)
        ON DELETE SET NULL
    """)

    alter table(:vault_access_log) do
      add(:credential_slug, :string)
      add(:credential_scope_type, :string)
    end

    flush()

    # Backfill from the credentials that still exist. Rows whose credential was
    # already cascaded away are gone for good — this migration cannot recover
    # history that the previous constraint destroyed, only stop the bleeding.
    execute("""
    UPDATE vault_access_log AS l
       SET credential_slug = c.slug,
           credential_scope_type = c.scope_type
      FROM vault_credentials AS c
     WHERE l.credential_id = c.id
    """)

    # The trail has to stay queryable once credential_id is null.
    create(index(:vault_access_log, [:credential_slug]))
  end

  # DESTRUCTIVE. Restoring NOT NULL is impossible while orphaned rows exist, so
  # rolling back deletes exactly the audit rows this migration was written to
  # preserve. That is the honest cost of going back to CASCADE; there is nowhere
  # else to put a log entry whose credential no longer exists.
  def down do
    execute("DELETE FROM vault_access_log WHERE credential_id IS NULL")

    drop(index(:vault_access_log, [:credential_slug]))

    alter table(:vault_access_log) do
      remove(:credential_slug)
      remove(:credential_scope_type)
    end

    flush()

    execute("""
    ALTER TABLE vault_access_log
      DROP CONSTRAINT vault_access_log_credential_id_fkey,
      ADD CONSTRAINT vault_access_log_credential_id_fkey
        FOREIGN KEY (credential_id)
        REFERENCES vault_credentials(id)
        ON DELETE CASCADE
    """)

    execute("ALTER TABLE vault_access_log ALTER COLUMN credential_id SET NOT NULL")
  end
end
