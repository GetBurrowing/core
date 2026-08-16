defmodule Platform.Repo.Migrations.SeedFederationPreambleTemplate do
  use Ecto.Migration

  @moduledoc """
  Task 01a00c99 stage 1 — make the federation preamble exist as a
  `prompt_templates` row in every environment.

  Re-run seed_defaults to insert the `federation.preamble` template on existing
  deployments, which were migrated before that slug had a descriptor.
  Idempotent — seed_defaults/0 is insert-only and skips slugs that exist.

  How the row exists in each environment:

    * fresh / dev / test databases get it from `seed_defaults/0` at setup;
    * existing dev and production databases get it when this migration runs
      during deploy.

  No manual DB step in any environment.

  Nothing reads the row yet — the constant `federation_preamble/0` is still the
  served source. This migration only makes the row exist, byte-identical to
  that constant.
  """
  def up do
    Platform.Orchestration.PromptTemplates.seed_defaults()
  end

  def down do
    :ok
  end
end
