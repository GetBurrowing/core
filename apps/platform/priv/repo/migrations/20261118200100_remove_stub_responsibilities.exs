defmodule Platform.Repo.Migrations.RemoveStubResponsibilities do
  @moduledoc """
  Remove four registration-only responsibilities (super agents restructure):

    * `design.spec_writer`, `design.brand_check` (Designer bundle)
    * `tasks.unblock`, `tasks.weekly_review` (Triage Officer bundle)

  Each was a stub: `gather_context/2` returned `"runtime not yet
  implemented"` slots and `handle_output/3` logged and discarded the
  answer. They still fired (chat pattern or cron), so each fire was a paid
  model round-trip nothing read, and each showed on the Control Center as a
  capability the platform does not have. The handler modules are gone from
  `BuiltIns.providers/0`; this migration removes what the registry's
  insert-or-update pass cannot, because it has no delete path:

    1. any `responsibility_overrides` row on the four keys;
    2. their `role_responsibilities` bundle rows;
    3. their `responsibilities` rows (including the operator `enabled` flag);
    4. their four `*.v1` prompt templates.

  Irreversible in data: `down/0` is a no-op. Rolling the code back
  re-registers the four rows on the old release's next boot, and the
  bundle rows return from the role-seeding migrations' pinned rosters only
  on a fresh DB.
  """

  use Ecto.Migration

  # old-code-compatible: the previous release still ships the four handler modules and re-upserts their responsibilities rows on boot; a fire against a row this migration deleted finds no row and no-ops

  @keys ["design.spec_writer", "design.brand_check", "tasks.unblock", "tasks.weekly_review"]

  @slugs [
    "design.spec_writer.v1",
    "design.brand_check.v1",
    "tasks.unblock.v1",
    "tasks.weekly_review.v1"
  ]

  def up do
    repo().query!("DELETE FROM responsibility_overrides WHERE responsibility_key = ANY($1)", [
      @keys
    ])

    repo().query!("DELETE FROM role_responsibilities WHERE responsibility_key = ANY($1)", [
      @keys
    ])

    repo().query!("DELETE FROM responsibilities WHERE key = ANY($1)", [@keys])
    repo().query!("DELETE FROM prompt_templates WHERE slug = ANY($1)", [@slugs])
  end

  def down, do: :ok

  @doc "The responsibility keys this migration removes."
  def keys, do: @keys

  @doc "The prompt template slugs this migration removes."
  def slugs, do: @slugs
end
