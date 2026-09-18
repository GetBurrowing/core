defmodule Platform.Repo.Migrations.SeedAgentsLeaderRole do
  @moduledoc """
  Re-seed the platform-fixed roles so the new `agents_leader` row lands
  on environments where the original seed migration
  (`20260624013500_seed_default_roles.exs`) already ran to `:up`
  (task `01a0b491-0718-7001-8bba-bf50f119bb13` stage 1).

  Fresh DBs pick `agents_leader` up from `Seeds.seed_defaults/0` through
  the earlier migration, but Ecto invokes each migration version once, so
  the code change alone never reaches prod or an already-migrated CI
  cache. This dedicated re-seed is the standard cutover; it mirrors
  `20260708120200_seed_architect_role.exs` which did the same for
  `architect`.

  Idempotent in both directions: `up/0` calls `seed_defaults/0`, whose
  inserts use `on_conflict: :nothing` on both `roles` and
  `role_responsibilities`; `down/0` deletes only the `agents_leader` key
  and the FK cascade clears its bundle rows.

  The bundled responsibility key `agents.goal_heartbeat` is registered in
  the Responsibilities registry by stage 3 of this task. Until then
  `Platform.Roles.responsibilities_for/1` returns the bundle fine while
  `Platform.Responsibilities.get_by_key/1` will not resolve it — the same
  expected gap the M4 seeds moduledoc documents, not a defect.

  NO ASSIGNMENT IS SEEDED. Pinning an agent to this role is a runtime
  operation through `role_assignments`, so that reassigning the leader
  later is the same operation as naming the first one.

  Runs after `20260918140100_add_agents_leader_to_roles_check.exs`
  extends the CHECK constraint, so this insert cannot violate it.
  """

  use Ecto.Migration

  def up do
    Platform.Roles.Seeds.seed_defaults()
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM roles WHERE key = $1",
      ["agents_leader"]
    )
  end
end
