defmodule Platform.Repo.Migrations.SeedScientistRole do
  @moduledoc """
  Re-seed the platform-fixed roles so the new `scientist` row lands on
  environments where the earlier role seed migrations already ran to `:up`
  (task `01a0d415-b616-7001-b87d-bb5568a776d3` stage 3, the
  experimentation-layer ADR-0052, `docs/decisions/0052-experimentation-layer.md`).

  Ecto invokes each migration version once, so adding `scientist` to
  `Platform.Roles.Seeds.default_roles/0` alone never reaches prod or an
  already-migrated CI cache. This dedicated re-seed is the standard cutover;
  it mirrors `20260918140200_seed_agents_leader_role.exs`, which did the same
  for `agents_leader` and is pinned to its own era's roster in this stage so
  it cannot insert `scientist` before the CHECK admits it.

  Idempotent in both directions: `up/0` calls `seed_defaults/0`, whose
  inserts use `on_conflict: :nothing` on both `roles` and
  `role_responsibilities`; `down/0` deletes only the `scientist` key and the
  FK cascade clears its bundle rows.

  The bundled responsibility key `experiments.label_signal` is registered by
  `Platform.Responsibilities.Handlers.ExperimentsLabelSignal` in the same
  stage. Stage 5 of the task adds `experiments.scientist` to the bundle.

  NO ASSIGNMENT IS SEEDED. Pinning an agent to this role is a runtime
  operation through `role_assignments`. Until an agent is pinned, the blind
  labeler records every inbound mail as an `unlabelled` signal.

  Runs after `20260924190100_add_scientist_to_roles_check.exs` extends the
  CHECK constraint, so this insert cannot violate it.

  ## Pinned to its era's roster (task 019fa1ac-6685 stage 1)

  `up/0` used to call `seed_defaults/0` unqualified. That stayed correct
  only while `scientist` was the newest role: once task `019fa1ac-6685`
  added `janitor` to `Seeds.default_roles/0`, an unqualified call here
  would insert `janitor` on a FRESH database before
  `20261009060918_add_janitor_role.exs` admits it, and fail on
  `roles_key_check`. So it now seeds exactly the keys the CHECK admits at
  this version, as `20260918140200_seed_agents_leader_role.exs` was pinned
  when `scientist` arrived. Already-migrated databases never re-run this
  file, so the edit changes nothing for them.
  """

  use Ecto.Migration

  # Keys admitted by `roles_key_check` at this migration's version.
  @roster_at_this_version [
    "designer",
    "historian",
    "meeting_scribe",
    "meeting_producer",
    "triage_officer",
    "security_guard",
    "architect",
    "agents_leader",
    "scientist"
  ]

  def up do
    Platform.Roles.Seeds.seed_defaults(only_keys: @roster_at_this_version)
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM roles WHERE key = $1",
      ["scientist"]
    )
  end
end
