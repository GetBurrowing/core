defmodule Platform.Repo.Migrations.GrantAgentManagementToBuiltinAdmin do
  @moduledoc "Add the agent management rule to the built-in admin role; reversible data change."
  use Ecto.Migration

  def up do
    execute("""
    UPDATE access_roles
    SET permissions = jsonb_set(permissions, '{agents.manage_all}', '"membership_org"'::jsonb),
        updated_at = NOW()
    WHERE builtin = true AND key = 'admin'
    """)
  end

  def down do
    execute("""
    UPDATE access_roles
    SET permissions = permissions - 'agents.manage_all', updated_at = NOW()
    WHERE builtin = true AND key = 'admin'
    """)
  end
end
