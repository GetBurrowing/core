defmodule Platform.Repo.Migrations.SeedMeetingTriageOfficerSkill do
  use Ecto.Migration

  @moduledoc """
  Seed the `meeting-triage-officer` skill via `Platform.Skills.seed_defaults/0`
  (task 019f5e2b stack member M4 Stage 3). The helper iterates the hardcoded
  `do_default_skills/0` list and inserts each skill only if the slug is
  missing — idempotent.

  Mirrors the shape of `20260326190000_seed_deploying_prompt_template.exs`.
  Down: no-op (skill rows are not migration-owned once seeded — Rowan curates
  them manually thereafter).
  """
  def up do
    Platform.Skills.seed_defaults()
  end

  def down do
    :ok
  end
end
