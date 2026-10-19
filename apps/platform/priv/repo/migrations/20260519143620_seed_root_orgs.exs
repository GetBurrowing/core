defmodule Platform.Repo.Migrations.SeedRootOrgs do
  @moduledoc """
  Seed this install's root org (task 01a068f6 stage 2).

  Originally seeded five hardcoded operator-brand orgs (Acme root + Initech,
  Vandelay-Ind, Globex, Hooli tenants) — the exact bug task 01a068f6 exists to
  fix: every fresh Suite install came up owned by one customer's org
  structure. Now seeds ONE root org (`parent_org_id IS NULL`), named and
  slugged from `ROOT_ORG_NAME`/`ROOT_ORG_SLUG` env vars, defaulting to
  "Root Org"/"root" when neither is set.

  ## Why `System.get_env/2` and not Application config

  `Platform.Tenancy.root_org_slug/0` reads `Application.get_env/3`, which
  is populated from `config/runtime.exs` — but a migration cannot assume
  `config/runtime.exs` ran before `mix ecto.migrate` reached this file (a
  release's migrator task, or a bare `Ecto.Migrator.run/4` call, may not
  load it). Reading `System.get_env/2` directly is self-contained: it
  works no matter how `up/0` gets invoked, and matches this migration's
  existing style of not depending on today's schema/app code (see below).

  ## Dropped: the four tenant-org inserts

  This migration no longer inserts Initech/Vandelay-Ind/Globex/Hooli. Those
  were operator-brand tenant orgs with no reason to exist on every fresh
  install; any install that wants child orgs creates them post-install via
  `Platform.Tenancy.create_org/2` (see `PlatformWeb.Live.AdminOrgsLive`).

  ## Raw SQL, no schema modules

  Data migrations use `Ecto.Adapters.SQL.query!/3` directly instead of
  `Platform.Tenancy.Org.changeset/2`. This is deliberate — schema modules
  evolve over time, but a migration must produce the same effect when
  replayed years from now. Coupling a migration to today's schema risks
  breakage when fields are renamed/removed.

  IDs are generated with `Platform.Types.UUIDv7.generate/0` (not
  `gen_random_uuid()`) so the seeded row has the same time-sortable
  UUIDv7 shape as application-inserted rows. The schema-version-stability
  concern doesn't apply to the UUID type — `Platform.Types.UUIDv7` is a
  bare function that produces a string, not a schema module.

  ## ON CONFLICT semantics

  The insert uses `ON CONFLICT (slug) DO NOTHING`. The migration is
  idempotent — re-running it on a DB that already has the seeded row
  is a no-op. This matters because:

    * Local dev DBs may already have this slug from manual setup.
    * The exactly-one-root partial unique index will reject a second
      `parent_org_id IS NULL` insert, so the ON CONFLICT keeps us defensive
      against partial prior runs.

  ## This migration is already inert on every existing install

  `mix ecto.migrate` skips a migration whose version has already run,
  regardless of file content. This version is already recorded in
  `schema_migrations` on every database that has ever run it (the first production install,
  a second install, every dev DB). Rewriting `up/0` therefore changes
  behavior ONLY for a genuinely empty database's first migrate.

  Reversal (`down/0`) deletes only the configured slug.
  """

  use Ecto.Migration

  @default_root_name "Root Org"
  @default_root_slug "root"

  defp root_name, do: System.get_env("ROOT_ORG_NAME", @default_root_name)
  defp root_slug, do: System.get_env("ROOT_ORG_SLUG", @default_root_slug)

  def up do
    root_id = Platform.Types.UUIDv7.generate()

    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      """
      INSERT INTO orgs (id, parent_org_id, name, slug, inserted_at, updated_at)
      VALUES ($1::uuid, NULL, $2, $3, NOW(), NOW())
      ON CONFLICT (slug) DO NOTHING
      """,
      [Ecto.UUID.dump!(root_id), root_name(), root_slug()]
    )
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM orgs WHERE slug = $1",
      [root_slug()]
    )
  end
end
