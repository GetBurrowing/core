defmodule Platform.Repo.Migrations.CreateAccessSpaceRestrictions do
  use Ecto.Migration

  @moduledoc """
  Channel role restrictions for task 01a1386e-59d1 stage 2.
  Deleting the LAST restricting role through a raw database cascade removes
  the last row and makes the space UNRESTRICTED. The context API refuses
  deletion while any restriction names the role, per
  0058-rbac-v2-roles-scopes-and-agent-capping.md § Built-in roles.
  """

  def up do
    create table(:access_space_restrictions, primary_key: false) do
      add :space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all), primary_key: true
      add :role_key, references(:access_roles, column: :key, type: :text, on_delete: :delete_all), primary_key: true
      add :restricted_by, :binary_id
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end

  def down do
    drop table(:access_space_restrictions)
  end
end
