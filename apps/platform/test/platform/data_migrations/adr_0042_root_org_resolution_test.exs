defmodule Platform.DataMigrations.Adr0042RootOrgResolutionTest do
  @moduledoc """
  Regression coverage for how `20260618181114_adr_0042_org_project_topology`
  resolves the org its backfill writes into (task 01a0dbc4 stage 1).

  The migration used to look the root up by the literal slug `"fabrikam"` and
  raise when it was absent. `20260519143620_seed_root_orgs.exs` seeds the
  root under `ROOT_ORG_SLUG` (default `"root"`), so every fresh install
  whose root was not slugged `fabrikam` crashed on its first migrate. The root
  is now resolved structurally: the single `orgs` row with
  `parent_org_id IS NULL`.

  CI never saw the crash because `config/test.exs` pinned
  `ROOT_ORG_SLUG=fabrikam`, so every test DB's root WAS slugged `fabrikam` (task
  01a116de stage 4 renamed the fixture root to `acme`). A test against a
  seeded row passes before and after the fix. Each case here
  therefore clears `orgs` first and builds its own topology inside the
  sandboxed, rolled-back transaction.

  Drives the public `root_org_id!/0` helper rather than `up/0`: `up/0`
  replays non-idempotent `ADD CONSTRAINT` statements and needs an
  `Ecto.Migration` runner, so it cannot be re-run on an already-migrated
  test DB.
  """
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Repo.Migrations.Adr0042OrgProjectTopology

  # Migration source lives under `priv/repo/migrations/` and is not on the
  # compile path — walk up from `test/platform/data_migrations/<this>.exs`
  # to `apps/platform/` and back down into `priv/repo/migrations/`.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260618181114_adr_0042_org_project_topology.exs"
                  ])

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  setup do
    # `TRUNCATE ... CASCADE`, not `Repo.delete_all/1`: rows elsewhere
    # (`org_wiki_pages`, `projects`, ...) FK-reference `orgs.id` with
    # ON DELETE RESTRICT. Transactional, so it rolls back with the test.
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE orgs CASCADE")
    :ok
  end

  defp insert_org!(slug, parent_id) do
    id = Platform.Types.UUIDv7.generate()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO orgs (id, parent_org_id, name, slug, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3, $4, NOW(), NOW())
      """,
      [Ecto.UUID.dump!(id), parent_id && Ecto.UUID.dump!(parent_id), slug, slug]
    )

    id
  end

  defp loaded(raw_id), do: Ecto.UUID.load!(raw_id)

  test "resolves a root org that is not slugged fabrikam" do
    red_star = insert_org!("red-star", nil)

    assert loaded(Adr0042OrgProjectTopology.root_org_id!()) == red_star
  end

  # The discriminating case: a slug-first lookup (or a `|| fabrikam` fallback)
  # returns the CHILD here. Only a structural lookup returns the root.
  test "returns the root, not a child org that happens to be slugged fabrikam" do
    red_star = insert_org!("red-star", nil)
    fabrikam_child = insert_org!("fabrikam", red_star)

    resolved = loaded(Adr0042OrgProjectTopology.root_org_id!())

    assert resolved == red_star
    refute resolved == fabrikam_child
  end

  test "raises naming the structural predicate when there is no root org" do
    assert_raise RuntimeError, ~r/parent_org_id IS NULL/, fn ->
      Adr0042OrgProjectTopology.root_org_id!()
    end
  end
end
