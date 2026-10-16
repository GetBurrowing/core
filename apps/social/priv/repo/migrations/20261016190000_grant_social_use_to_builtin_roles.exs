defmodule Platform.Repo.Migrations.GrantSocialUseToBuiltinRoles do
  @moduledoc """
  Preserve internal users' Social extension capability while integrating RBAC v2.

  Rollup task 01a1386e-72e1-7001-8b7e-dc59b2faf1d4, ADR 0058: the module
  remains opt-in per runtime profile and constrained by its owner's permission.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE access_roles
    SET permissions = jsonb_set(permissions, '{social.use}', '"all"'::jsonb),
        updated_at = NOW()
    WHERE builtin = true AND key IN ('admin', 'member')
    """)
  end

  def down do
    execute("""
    UPDATE access_roles
    SET permissions = permissions - 'social.use', updated_at = NOW()
    WHERE builtin = true AND key IN ('admin', 'member')
    """)
  end
end
