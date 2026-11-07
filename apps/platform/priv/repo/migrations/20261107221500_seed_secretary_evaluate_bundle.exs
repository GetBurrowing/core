defmodule Platform.Repo.Migrations.SeedSecretaryEvaluateBundle do
  @moduledoc """
  Add `secretary.evaluate` to the `triage_officer` role's bundle on
  environments where the earlier role seed migrations already ran (task
  01a1b721 stage 2). Same shape as
  `20261010160200_seed_feedback_intake_bundle.exs`: Ecto runs each version
  once, so adding the key to `Platform.Roles.Seeds.default_roles/0` alone
  never reaches an already-migrated install. Scoped with
  `only_keys: ["triage_officer"]`; idempotent (`on_conflict: :nothing`).

  The bundle row only names WHOSE subscription login answers the
  secretary's one-shot, tool-less question
  (`Platform.Secretary.Model.Host`). Nothing fires it: there is no
  responsibility row and no handler for the key, so the responsibilities
  Router can never dispatch it.

  NO ASSIGNMENT IS SEEDED. The install's Burrow holds `triage_officer` by
  default (`Platform.Agents.Burrow.default_roles/0`).

  `down/0` deletes only the `(triage_officer, secretary.evaluate)` row.
  """

  use Ecto.Migration

  def up do
    Platform.Roles.Seeds.seed_defaults(only_keys: ["triage_officer"])
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM role_responsibilities WHERE role_key = $1 AND responsibility_key = $2",
      ["triage_officer", "secretary.evaluate"]
    )
  end
end
