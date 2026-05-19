defmodule Platform.Repo.Migrations.SeedRootOrgs do
  @moduledoc """
  Seed the five canonical orgs for Suite: Fabrikam (root) + Soylent, Wayne-Tech,
  SXI, Paragon (tenants).

  ## Raw SQL, no schema modules

  Data migrations use `Ecto.Adapters.SQL.query!/3` directly instead of
  `Platform.Tenancy.Org.changeset/2`. This is deliberate — schema modules
  evolve over time, but a migration must produce the same effect when
  replayed years from now. Coupling a migration to today's schema risks
  breakage when fields are renamed/removed.

  IDs are generated with `Platform.Types.UUIDv7.generate/0` (not
  `gen_random_uuid()`) so the seeded rows have the same time-sortable
  UUIDv7 shape as application-inserted rows. The schema-version-stability
  concern doesn't apply to the UUID type — `Platform.Types.UUIDv7` is a
  bare function that produces a string, not a schema module.

  ## ON CONFLICT semantics

  Each insert uses `ON CONFLICT (slug) DO NOTHING`. The migration is
  idempotent — re-running it on a DB that already has the seeded rows
  is a no-op. This matters because:

    * Local dev DBs may already have one of these slugs from manual setup.
    * The exactly-one-root partial unique index will reject a second
      `parent_org_id IS NULL` insert, so the ON CONFLICT keeps us defensive
      against partial prior runs.

  Reversal (`down/0`) deletes only the five named slugs.
  """

  use Ecto.Migration

  @fabrikam_slug "fabrikam"
  @tenant_slugs ~w(soylent wayne_tech sxi paragon)

  @tenant_names %{
    "soylent" => "Soylent",
    "wayne_tech" => "Wayne-Tech",
    "sxi" => "SXI",
    "paragon" => "Paragon"
  }

  def up do
    fabrikam_id = Platform.Types.UUIDv7.generate()

    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      """
      INSERT INTO orgs (id, parent_org_id, name, slug, inserted_at, updated_at)
      VALUES ($1::uuid, NULL, $2, $3, NOW(), NOW())
      ON CONFLICT (slug) DO NOTHING
      """,
      [Ecto.UUID.dump!(fabrikam_id), "Fabrikam", @fabrikam_slug]
    )

    # Re-read the Fabrikam id from the DB. If the insert was a no-op (slug
    # collision from a prior run) we need the existing row's id so the
    # tenants get the correct parent.
    %{rows: [[real_fabrikam_id]]} =
      Ecto.Adapters.SQL.query!(
        Platform.Repo,
        "SELECT id FROM orgs WHERE slug = $1",
        [@fabrikam_slug]
      )

    for slug <- @tenant_slugs do
      tenant_id = Platform.Types.UUIDv7.generate()

      Ecto.Adapters.SQL.query!(
        Platform.Repo,
        """
        INSERT INTO orgs (id, parent_org_id, name, slug, inserted_at, updated_at)
        VALUES ($1::uuid, $2::uuid, $3, $4, NOW(), NOW())
        ON CONFLICT (slug) DO NOTHING
        """,
        [Ecto.UUID.dump!(tenant_id), real_fabrikam_id, Map.fetch!(@tenant_names, slug), slug]
      )
    end
  end

  def down do
    all_slugs = [@fabrikam_slug | @tenant_slugs]

    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM orgs WHERE slug = ANY($1)",
      [all_slugs]
    )
  end
end
