defmodule Platform.Repo.Migrations.SeedFeedbackIntakeBundle do
  @moduledoc """
  Add `feedback.intake` to the `triage_officer` role's bundle on environments
  where the earlier role seed migrations already ran (task 01a11ec3 stage 3).

  Ecto invokes each migration version once, so adding the key to
  `Platform.Roles.Seeds.default_roles/0` alone never reaches an
  already-migrated install. Scoped with `only_keys: ["triage_officer"]`, the
  only role whose bundle changed. Idempotent: `seed_defaults/1` inserts with
  `on_conflict: :nothing` on both `roles` and `role_responsibilities`.

  The bundle row only names WHOSE MODEL classifies an issue. The intake never
  dispatches that agent through its runtime, so the agent's own capability
  bundles never come into play: `Platform.Feedback.Classifier` calls the
  model through `Platform.Agents.ToollessChat`, which drops any tool option.

  NO ASSIGNMENT IS SEEDED. Until an agent is pinned to `triage_officer` (or
  to the `feedback.intake` key by override), intake records every in-scope
  issue as `pending` and files nothing.

  `down/0` deletes only the `(triage_officer, feedback.intake)` bundle row.
  """

  use Ecto.Migration

  def up do
    Platform.Roles.Seeds.seed_defaults(only_keys: ["triage_officer"])
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM role_responsibilities WHERE role_key = $1 AND responsibility_key = $2",
      ["triage_officer", "feedback.intake"]
    )
  end
end
