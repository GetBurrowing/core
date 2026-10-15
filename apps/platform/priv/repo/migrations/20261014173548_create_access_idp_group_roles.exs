defmodule Platform.Repo.Migrations.CreateAccessIdpGroupRoles do
  use Ecto.Migration

  def up do
    create table(:access_idp_group_roles, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:group_value, :text, null: false)

      add(
        :role_key,
        references(:access_roles, column: :key, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all))
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:access_idp_group_roles, :access_idp_group_roles_guest_org_check,
        check:
          "(role_key = 'guest' AND org_id IS NULL) OR (role_key <> 'guest' AND org_id IS NOT NULL)"
      )
    )

    execute("""
    CREATE UNIQUE INDEX access_idp_group_roles_tuple_index
      ON access_idp_group_roles (group_value, role_key, org_id) NULLS NOT DISTINCT
    """)

    create(index(:access_idp_group_roles, [:role_key]))
  end

  def down do
    drop(table(:access_idp_group_roles))
  end
end
