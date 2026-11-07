defmodule Platform.Repo.Migrations.BurrowHoldsUnheldRoles do
  @moduledoc """
  One-shot data migration (task 01a1b741 stage 1): on an existing install,
  give the Burrow agent every role no agent holds.

  `Platform.Agents.Burrow.ensure/2` fills unheld roles, but it runs only from
  `/setup/connect-ai`, so an install set up before Burrow held the whole
  roster would never reach it. This migration does that fill once.

  Plain SQL, no app modules. The Burrow agent is found the way
  `Burrow.get/0` finds it: the agent with slug `burrow` whose runtime is
  install-managed (`agent_runtimes.managed_by = 'install'`). Ids come from
  `gen_random_uuid()`, as in
  `20260702192606_backfill_historian_role_assignments.exs`.

  `ON CONFLICT (role_key) DO NOTHING`: a role another agent holds keeps its
  holder. With no Burrow (a fresh install, where `ensure/2` fills later) or
  with every role held, nothing is inserted.

  ## `down/0`

  A deliberate no-op. Rolling back cannot tell the rows this migration wrote
  from rows the owner or `ensure/2` wrote since, so deleting them could clear
  a role someone chose. Clear a role in the Control Center instead.
  """

  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO role_assignments (id, role_key, agent_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), r.key, b.id, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc'
    FROM roles r
    CROSS JOIN (
      SELECT a.id
      FROM agents a
      JOIN agent_runtimes rt ON rt.id = a.runtime_id
      WHERE a.slug = 'burrow' AND rt.managed_by = 'install'
      ORDER BY a.name ASC
      LIMIT 1
    ) b
    WHERE NOT EXISTS (SELECT 1 FROM role_assignments ra WHERE ra.role_key = r.key)
    ON CONFLICT (role_key) DO NOTHING
    """)
  end

  def down do
    # No-op on purpose: see the moduledoc. These rows cannot be told apart
    # from assignments made after this ran, so removing them could undo an
    # owner's choice.
    :ok
  end
end
