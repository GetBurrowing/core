defmodule Platform.DataMigrations.SeedRootOrgsTest do
  @moduledoc """
  Regression coverage for `20260519143620_seed_root_orgs` (task 01a068f6
  stage 2).

  The migration used to seed five hardcoded operator-brand orgs (the
  operator's own root + Initech, Vandelay-Ind, Globex, Hooli tenants) — the exact bug this task
  fixes: every fresh Suite install came up owned by one customer's org
  structure. It now seeds exactly ONE root org (`parent_org_id IS NULL`),
  named/slugged from `ROOT_ORG_NAME`/`ROOT_ORG_SLUG`, defaulting to
  "Root Org"/"root" when neither is set, and no tenant orgs at all.

  Drives `up/0` directly against `Platform.Repo` inside the sandbox — the
  same pattern as the other `test/platform/data_migrations/*_test.exs`
  files. Migrations run to `:up` once, outside ExUnit's sandbox, before the
  suite boots (see `config/test.exs`), so this test DB already carries a
  root org seeded under the "acme"/"Acme" env pin that file sets. Each test
  here parks that root first (`park_root_org!/0`) so no root is left, which
  is the state a fresh database's first migrate sees, and then asserts on
  the rows `up/0`/`down/0` added or removed relative to the snapshot the
  park returns. On a fresh database that delta IS the whole table, so the
  assertions keep their meaning without emptying `orgs`.
  """
  use Platform.DataCase, async: false

  alias Platform.Regression.InstallIdentityScanner, as: Scanner
  alias Platform.Repo
  alias Platform.Repo.Migrations.SeedRootOrgs
  alias Platform.Tenancy.Org
  alias Platform.TenancyFixtures

  # Migration source lives under `priv/repo/migrations/` and is not on the
  # compile path — walk up from `test/platform/data_migrations/<this>.exs`
  # to `apps/platform/` and back down into `priv/repo/migrations/`.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260519143620_seed_root_orgs.exs"
                  ])

  # The names the old migration seeded are checked with the install-identity
  # scanner, so this file spells none of them: the root since task 01a14b9e
  # stage 5, the tenants since task 01a14dd9 (a list of placeholder slugs
  # here would guard against names no migration ever seeded). The exact
  # one-row match in each test already refutes any tenant row.

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  setup do
    # Reproduce a fresh database's first migrate: this test DB's `orgs`
    # table already has the one root org seeded at boot (config/test.exs
    # pins ROOT_ORG_SLUG=acme/ROOT_ORG_NAME=Acme), and a second
    # `parent_org_id IS NULL` insert would trip the `orgs_single_root`
    # partial unique index. Parking it leaves no root, inside this test's
    # own sandboxed, rolled-back transaction.
    #
    # Not `TRUNCATE orgs CASCADE` (what this used to do): its ACCESS
    # EXCLUSIVE locks on `orgs` and every FK-referencing table queue behind
    # concurrent tests and stall them (see `park_root_org!/0`). Not
    # `DELETE` either: deleting the root takes a FOR UPDATE row lock that
    # waits on every concurrent test holding an FK reference to it.
    preexisting = TenancyFixtures.park_root_org!()

    original_name = System.get_env("ROOT_ORG_NAME")
    original_slug = System.get_env("ROOT_ORG_SLUG")

    on_exit(fn ->
      restore_env("ROOT_ORG_NAME", original_name)
      restore_env("ROOT_ORG_SLUG", original_slug)
    end)

    %{preexisting: preexisting}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  # Every org row this test's migration calls added: the whole `orgs`
  # table minus the rows that existed (parked) before the test ran.
  defp new_orgs(preexisting) do
    Repo.all(from(o in Org, where: o.id not in ^preexisting))
  end

  test "a fresh migrate with no env vars set seeds exactly one neutral root org", %{
    preexisting: preexisting
  } do
    System.delete_env("ROOT_ORG_NAME")
    System.delete_env("ROOT_ORG_SLUG")

    SeedRootOrgs.up()

    assert [%Org{name: "Root Org", slug: "root", parent_org_id: nil}] = new_orgs(preexisting)

    for org <- new_orgs(preexisting) do
      assert Scanner.hits(org.name) == [], "org name carries install identity"
      assert Scanner.hits(org.slug) == [], "org slug carries install identity"
    end
  end

  # Any non-default pair proves the override. Not "acme": the parked boot
  # root still holds that slug, and `up/0`'s `ON CONFLICT (slug) DO NOTHING`
  # would no-op against it (renaming the parked row instead would take a
  # FOR UPDATE row lock on it, since `slug` is a unique key column).
  test "ROOT_ORG_NAME/ROOT_ORG_SLUG override the default", %{preexisting: preexisting} do
    System.put_env("ROOT_ORG_NAME", "Acme Corp")
    System.put_env("ROOT_ORG_SLUG", "acme-corp")

    SeedRootOrgs.up()

    assert [%Org{name: "Acme Corp", slug: "acme-corp", parent_org_id: nil}] =
             new_orgs(preexisting)
  end

  test "down/0 deletes only the configured slug", %{preexisting: preexisting} do
    System.delete_env("ROOT_ORG_NAME")
    System.delete_env("ROOT_ORG_SLUG")

    SeedRootOrgs.up()
    assert [%Org{slug: "root"}] = new_orgs(preexisting)

    SeedRootOrgs.down()
    assert new_orgs(preexisting) == []
    # "Only": every row other than the one it seeded is still there.
    assert Enum.sort(Repo.all(from(o in Org, select: o.id))) == Enum.sort(preexisting)
  end

  # ── e2e_behavior case 1 (task 01a068f6 stage 3, validation 01a0daa5-23bc-7008) ──
  #
  # The prior tests above already exercise the same fresh-migrate shape;
  # this case is the plan's own named exhaustiveness assertion — checked
  # against every org row (not just the seeded one) and against the
  # brand terms the plan's validation payload names: the operator's root
  # name and the four tenant names. The payload's expectation is phrased as
  # "matches OR CONTAINS", not exact-equality, so every name and slug goes
  # through the install-identity scanner (whole tokens anywhere in the
  # string): a name like "<root> Corp" would dodge an equality check but
  # must still fail. Task 01a14dd9 puts the tenant names on the scanner
  # (its stage 5), so this file no longer spells them.
  # `ROOT_ORG_ADMIN_EMAIL_DOMAIN` is included in the cleared-env set per
  # the payload's stated setup even though `SeedRootOrgs.up/0` never reads
  # it — only `ROOT_ORG_NAME` and `ROOT_ORG_SLUG` affect this migration.
  # "Every org row" is every row the migrate added (`new_orgs/1`), which on
  # a fresh database is the whole table.
  test "case 1: a fresh migrate has zero operator-brand references anywhere in the orgs table",
       %{preexisting: preexisting} do
    System.delete_env("ROOT_ORG_NAME")
    System.delete_env("ROOT_ORG_SLUG")
    System.delete_env("ROOT_ORG_ADMIN_EMAIL_DOMAIN")

    SeedRootOrgs.up()

    orgs = new_orgs(preexisting)

    assert [%Org{name: "Root Org", slug: "root", parent_org_id: nil}] = orgs

    for org <- orgs do
      assert Scanner.hits(org.name) == [],
             "org #{org.id} name #{inspect(org.name)} carries install identity"

      assert Scanner.hits(org.slug) == [],
             "org #{org.id} slug #{inspect(org.slug)} carries install identity"
    end
  end
end
