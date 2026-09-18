defmodule Platform.Repo.Migrations.SeedDesignTaskDirection do
  use Ecto.Migration

  # Keys admitted by `roles_key_check` at this migration's version.
  @roster_at_this_version [
    "designer",
    "historian",
    "meeting_scribe",
    "meeting_producer",
    "triage_officer",
    "security_guard",
    "architect"
  ]

  @moduledoc """
    Land the two rows the `design.task_direction` responsibility needs on an
    ALREADY-MIGRATED database (ADR-0046 stack member 7, task
    `019f9b29-5ecd` stage 3).

    The `responsibilities` row itself is NOT seeded here and does not need to
    be: `Platform.Responsibilities.Registry` upserts every module in
    `BuiltIns.providers/0` on boot, so adding the handler to that list is
    sufficient. What boot does not cover is the two seed-once tables:

      1. **The `designer` role bundle.** `Platform.Roles.Seeds.seed_defaults/0`
         runs from `20260624013500_seed_default_roles.exs`, and Ecto invokes a
         migration exactly once per version — so a fourth bundle key added to
         `@default_roles` never reaches an environment that already ran it.
         Mirrors `20260708120200_seed_architect_role.exs`. Idempotent: both
         inserts use `on_conflict: :nothing` against natural-key unique
         indexes (`roles_pkey`, `role_responsibilities_pair_idx`).

         No `roles_key_check` change is needed — `designer` is an existing
         key and the CHECK constrains role keys, not bundle keys.

      2. **The `design.task_direction.v1` prompt template.**
         `PromptTemplates.seed_defaults/0` is INSERT-only, which is exactly
         right for a NEW slug and exactly wrong for changing an existing
         body. If this template's wording ever needs to change after this
         migration ships, it needs its own force-update migration — see
         `20260726210000_force_update_architect_review_plan_citation_guidance.exs`,
         which exists because that lesson was learned the hard way. Mirrors
         `20260710120000_seed_stacks_dep_inference_template.exs`.

    `down/0` removes only what `up/0` introduced: the one bundle pair and the
    one template slug. It deliberately does NOT unwind the rest of either
    seed set — those rows predate this migration.
    
    PINNED ROSTER (task `01a0b491` stage 1). `seed_defaults/0` was called
    unqualified here. It walks the CURRENT `@default_roles`, so every new
    role added to that list later would be inserted at THIS migration's
    timestamp — where `roles_key_check` does not yet admit it, and the
    insert raises. `agents_leader` (task `01a0b491`) was the first to hit
    it. Scoping the call to the keys valid at this timestamp preserves
    this migration's semantics exactly and stops the next added role from
    breaking a fresh `ecto.migrate`. Same escape hatch, same reason, as
    `20260624013500_seed_default_roles.exs` and
    `20260702200500_seed_meeting_producer_role.exs`.
  """

  @role_key "designer"
  @responsibility_key "design.task_direction"
  @template_slug "design.task_direction.v1"

  def up do
    Platform.Roles.Seeds.seed_defaults(only_keys: @roster_at_this_version)
    Platform.Orchestration.PromptTemplates.seed_defaults()

    :ok
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM role_responsibilities WHERE role_key = $1 AND responsibility_key = $2",
      [@role_key, @responsibility_key]
    )

    case Platform.Orchestration.PromptTemplates.get_template_by_slug(@template_slug) do
      nil -> :ok
      template -> {:ok, _} = Platform.Orchestration.PromptTemplates.delete_template(template)
    end

    :ok
  end
end
