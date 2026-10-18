defmodule Platform.DataMigrations.SeedRootOrgsTest do
  @moduledoc """
  Regression coverage for `20260519143620_seed_root_orgs` (task 01a068f6
  stage 2).

  The migration used to seed five hardcoded operator-brand orgs (the
  operator's own root + Soylent, Wayne-Tech, SXI, Paragon tenants) — the exact bug this task
  fixes: every fresh Suite install came up owned by one customer's org
  structure. It now seeds exactly ONE root org (`parent_org_id IS NULL`),
  named/slugged from `ROOT_ORG_NAME`/`ROOT_ORG_SLUG`, defaulting to
  "Root Org"/"root" when neither is set, and no tenant orgs at all.

  Drives `up/0` directly against `Platform.Repo` inside the sandbox — the
  same pattern as the other `test/platform/data_migrations/*_test.exs`
  files. Migrations run to `:up` once, outside ExUnit's sandbox, before the
  suite boots (see `config/test.exs`), so this test DB already carries a
  root org seeded under the "acme"/"Acme" env pin that file sets. Each test
  here clears the `orgs` table first to reproduce a truly fresh database's
  first migrate.
  """
  use Platform.DataCase, async: false

  alias Platform.Regression.InstallIdentityScanner, as: Scanner
  alias Platform.Repo
  alias Platform.Repo.Migrations.SeedRootOrgs
  alias Platform.Tenancy.Org

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

  # The tenant names the old migration seeded. The operator's own root name
  # is checked with the install-identity scanner instead, so this file does
  # not spell it (task 01a14b9e stage 5).
  @brand_terms ~w(soylent wayne_tech wayne-tech sxi paragon)

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  setup do
    # Reproduce a genuinely empty database: this test DB's `orgs` table
    # already has the one root org seeded at boot (config/test.exs pins
    # ROOT_ORG_SLUG=acme/ROOT_ORG_NAME=Acme), which `up/0`'s
    # `ON CONFLICT (slug) DO NOTHING` would silently no-op against, and a
    # differently-slugged insert would trip the `orgs_single_root` partial
    # unique index. Clearing it first (inside this test's own sandboxed,
    # rolled-back transaction) is what actually exercises "a fresh
    # database's first migrate" rather than re-asserting a no-op.
    #
    # `TRUNCATE ... CASCADE`, not `Repo.delete_all/1`: a long-lived local
    # dev/test database accrues real rows elsewhere (`org_wiki_pages` etc.)
    # that FK-reference `orgs.id`, and plain `DELETE` refuses to touch a
    # referenced row. Transactional in Postgres like any other statement
    # here, so it rolls back with everything else this test does.
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE orgs CASCADE")

    original_name = System.get_env("ROOT_ORG_NAME")
    original_slug = System.get_env("ROOT_ORG_SLUG")

    on_exit(fn ->
      restore_env("ROOT_ORG_NAME", original_name)
      restore_env("ROOT_ORG_SLUG", original_slug)
    end)

    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  test "a fresh migrate with no env vars set seeds exactly one neutral root org" do
    System.delete_env("ROOT_ORG_NAME")
    System.delete_env("ROOT_ORG_SLUG")

    SeedRootOrgs.up()

    assert [%Org{name: "Root Org", slug: "root", parent_org_id: nil}] = Repo.all(Org)

    for org <- Repo.all(Org) do
      for term <- @brand_terms do
        refute String.downcase(org.name) == term, "org name matched brand term #{term}"
        refute String.downcase(org.slug) == term, "org slug matched brand term #{term}"
      end

      assert Scanner.hits(org.name) == [], "org name carries install identity"
      assert Scanner.hits(org.slug) == [], "org slug carries install identity"
    end
  end

  test "ROOT_ORG_NAME/ROOT_ORG_SLUG override the default" do
    System.put_env("ROOT_ORG_NAME", "Acme Corp")
    System.put_env("ROOT_ORG_SLUG", "acme")

    SeedRootOrgs.up()

    assert [%Org{name: "Acme Corp", slug: "acme", parent_org_id: nil}] = Repo.all(Org)
  end

  test "down/0 deletes only the configured slug" do
    System.delete_env("ROOT_ORG_NAME")
    System.delete_env("ROOT_ORG_SLUG")

    SeedRootOrgs.up()
    assert [%Org{slug: "root"}] = Repo.all(Org)

    SeedRootOrgs.down()
    assert Repo.all(Org) == []
  end

  # ── e2e_behavior case 1 (task 01a068f6 stage 3, validation 01a0daa5-23bc-7008) ──
  #
  # The prior tests above already exercise the same fresh-migrate shape;
  # this case is the plan's own named exhaustiveness assertion — checked
  # against every org row (not just the seeded one) and against the exact
  # brand-term list the plan's validation payload names: the operator's root
  # name, soylent, wayne_tech, sxi, paragon. The payload's expectation is
  # phrased as "matches OR CONTAINS", not exact-equality, so this uses
  # `String.contains?/2` for the tenant names, and the install-identity
  # scanner (whole tokens anywhere in the string) for the root name: a name
  # like "<root> Corp" would dodge an equality check but must still fail.
  # `ROOT_ORG_ADMIN_EMAIL_DOMAIN` is included in the cleared-env set per
  # the payload's stated setup even though `SeedRootOrgs.up/0` never reads
  # it — only `ROOT_ORG_NAME` and `ROOT_ORG_SLUG` affect this migration.
  test "case 1: a fresh migrate has zero operator-brand references anywhere in the orgs table" do
    System.delete_env("ROOT_ORG_NAME")
    System.delete_env("ROOT_ORG_SLUG")
    System.delete_env("ROOT_ORG_ADMIN_EMAIL_DOMAIN")

    SeedRootOrgs.up()

    orgs = Repo.all(Org)

    assert [%Org{name: "Root Org", slug: "root", parent_org_id: nil}] = orgs

    banned = ~w(soylent wayne_tech sxi paragon)

    for org <- orgs do
      assert Scanner.hits(org.name) == [],
             "org #{org.id} name #{inspect(org.name)} carries install identity"

      assert Scanner.hits(org.slug) == [],
             "org #{org.id} slug #{inspect(org.slug)} carries install identity"
    end

    for org <- orgs, term <- banned do
      refute String.contains?(String.downcase(org.name), term),
             "org #{org.id} name #{inspect(org.name)} contained banned term #{term}"

      refute String.contains?(String.downcase(org.slug), term),
             "org #{org.id} slug #{inspect(org.slug)} contained banned term #{term}"
    end
  end
end
