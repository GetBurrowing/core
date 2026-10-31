defmodule Platform.Repo.Migrations.GrantInstallsProvisionerDoToken do
  @moduledoc """
  Task 01a18f0c-441d-7000-a8ca-f1a29e96bd37, stage 1: let the installs
  provisioner read the DigitalOcean token.

  `Platform.Installs.DigitalOcean` reads the shared vault secret
  `digital-ocean-api-infra` as `{:system, "installs-provisioner"}`. A
  shared secret is readable ONLY through an explicit `use` grant, so on prod
  that read was `:access_denied`. This writes the one grant row that admits
  exactly that reader: `grantee_type 'system'` and the reader's fixed uuid
  from `Platform.Vault.system_principals/0`. The token is not copied; the
  reader fetches the one shared row.

    * A no-op when the secret is absent (a fresh or dev database).
    * Idempotent: `ON CONFLICT DO NOTHING` on `vault_access_grants_unique_grant`,
      and the `update` access-log row is written only when the grant row was
      inserted, the same row an admin grant writes
      (`%{"grant" => "added", "system_principal" => name}`).
    * Revocable like any agent grant: `/admin/vault/<slug>`, System readers,
      or `Platform.Vault.Shared.revoke_system_grant/3`. `down/0` removes it.

  The uuid is a literal here, not read from app code, so this migration means
  the same thing whatever the code later says.
  """
  use Ecto.Migration

  @slug "digital-ocean-api-infra"
  @principal "installs-provisioner"
  @principal_id "e3ee1349-ca10-46f7-aaa9-65205a820f86"
  @system_accessor_id "00000000-0000-0000-0000-000000000000"

  @doc "The idempotent grant statement (also run by the migration test)."
  def grant_sql do
    """
    WITH cred AS (
      SELECT id, slug, scope_type FROM vault_credentials
      WHERE slug = '#{@slug}' AND scope_type = 'shared'
    ),
    ins AS (
      INSERT INTO vault_access_grants
        (id, credential_id, grantee_type, grantee_id, permissions, inserted_at)
      SELECT gen_random_uuid(), cred.id, 'system', '#{@principal_id}'::uuid, ARRAY['use'], now()
      FROM cred
      ON CONFLICT (credential_id, grantee_type, grantee_id) DO NOTHING
      RETURNING credential_id
    )
    INSERT INTO vault_access_log
      (id, credential_id, credential_slug, credential_scope_type, accessor_type,
       accessor_id, action, metadata, inserted_at)
    SELECT gen_random_uuid(), cred.id, cred.slug, cred.scope_type, 'system',
           '#{@system_accessor_id}'::uuid, 'update',
           jsonb_build_object('grant', 'added', 'system_principal', '#{@principal}',
                              'via', 'migration'),
           now()
    FROM ins JOIN cred ON cred.id = ins.credential_id
    """
  end

  def up, do: execute(grant_sql())

  def down do
    execute("""
    DELETE FROM vault_access_grants g
    USING vault_credentials c
    WHERE g.credential_id = c.id AND c.slug = '#{@slug}' AND c.scope_type = 'shared'
      AND g.grantee_type = 'system' AND g.grantee_id = '#{@principal_id}'::uuid
    """)
  end
end
