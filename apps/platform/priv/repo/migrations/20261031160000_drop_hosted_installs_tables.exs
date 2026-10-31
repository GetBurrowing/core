defmodule Platform.Repo.Migrations.DropHostedInstallsTables do
  @moduledoc """
  Task 01a19249-3433-7000-8507-405c6c506cad, stage 5: Kobo's hosted one-click
  installs moved out of core into Burrow Cloud (GetBurrowing/burrow-cloud),
  which now owns that data in its own database. The rows were imported there
  (stage 4) before this ships, and a pg_dump of both tables was taken first.

    * Drops `installs` and `install_request_settings`, `IF EXISTS`: a fresh
      database never created them (their create migrations were removed in
      the same change). Nothing references either table, so no CASCADE.
    * Deletes the ONE `vault_access_grants` row that admitted the former
      provisioner principal (`grantee_type 'system'`, its fixed uuid below),
      and writes an `update` access-log row for it, as a revoke does. The
      shared credential it pointed at (`digital-ocean-api-infra`) is NOT
      touched: removing a credential is a person's call.
    * `down/0` raises: the data lives in Burrow Cloud and is not restored
      here.
  """
  use Ecto.Migration

  @principal_id "e3ee1349-ca10-46f7-aaa9-65205a820f86"
  @system_accessor_id "00000000-0000-0000-0000-000000000000"

  @doc "The statements `up/0` runs, in order (also run by the migration test)."
  def up_sql do
    [
      "DROP TABLE IF EXISTS installs",
      "DROP TABLE IF EXISTS install_request_settings",
      revoke_grant_sql()
    ]
  end

  @doc "Deletes exactly the former provisioner's grant row and logs the removal."
  def revoke_grant_sql do
    """
    WITH del AS (
      DELETE FROM vault_access_grants
      WHERE grantee_type = 'system' AND grantee_id = '#{@principal_id}'::uuid
      RETURNING credential_id
    )
    INSERT INTO vault_access_log
      (id, credential_id, credential_slug, credential_scope_type, accessor_type,
       accessor_id, action, metadata, inserted_at)
    SELECT gen_random_uuid(), c.id, c.slug, c.scope_type, 'system',
           '#{@system_accessor_id}'::uuid, 'update',
           jsonb_build_object('grant', 'removed', 'system_principal', 'installs-provisioner',
                              'via', 'migration'),
           now()
    FROM del JOIN vault_credentials c ON c.id = del.credential_id
    """
  end

  def up do
    Enum.each(up_sql(), &execute/1)
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "irreversible: the hosted installs data lives in Burrow Cloud " <>
          "(task 01a19249 stage 5); it is not restored into core"
  end
end
