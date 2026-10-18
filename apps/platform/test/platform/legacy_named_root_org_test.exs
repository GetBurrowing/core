defmodule Platform.LegacyNamedRootOrgTest do
  @moduledoc """
  e2e_behavior case 3 (task 01a068f6 stage 3, validation 01a0daa5-23bc-700a).

  Proves the fix works on an already-migrated (legacy Legacy) database
  exactly the way it works on a fresh one, and that this task's changes
  do not delete or alter any pre-existing row on such a database.

  ## Why the rows are inserted directly, not seeded via `SeedRootOrgs.up/0`

  A real pre-existing install (Legacy's own production DB, or any install
  that migrated before task 01a068f6 stage 2 shipped) already has the
  OLD migration's effect baked into its `orgs` table — the version is
  recorded in `schema_migrations`, so `mix ecto.migrate` never re-runs
  `up/0` there regardless of what the file now contains (see the
  migration's own moduledoc, "this migration is already inert on every
  existing install"). Driving `up/0` again would not reproduce that
  database's actual state; inserting the rows directly, the way the OLD
  `up/0` body used to, does. This setup matches the validation payload's
  own framing: `schema_migrations` already records the seed migration's
  version, and `orgs`/`org_memberships` already contain the legacy Legacy
  root, its 4 tenant children, and real membership rows.

  ## Why 4 tenants, and why real membership rows

  The original hardcoded migration seeded exactly Soylent, Wayne-Tech,
  SXI, and Paragon under Legacy — all 4 are reproduced here so "untouched"
  is checked against the actual historical shape, not a partial stand-in.
  Two pre-existing `org_memberships` rows (one admin, one member) stand in
  for real production membership history; the byte-for-byte assertions
  below cover both org AND membership rows, per the validation payload.

  ## What this proves that `root_org_slug_test.exs` does not

  `root_org_slug_test.exs` covers a root org that keeps the seeded
  fixture slug (`"acme"` since task 01a116de stage 4) OR gets renamed away
  from it, always through the test
  DB's own boot-time seed. This file starts from a **from-scratch legacy
  shape** and checks that `get_root_org/0` and the structurally-migrated
  call sites need zero special-casing to keep operating on it — including
  a login for an EXISTING `@example.net` user (no email change), which
  exercises `find_or_create_from_oidc/1`'s idempotent-refresh path rather
  than the first-INSERT path the other e2e files cover. Nothing here is
  tenant-priority ordering, display labels, or `root_admin?`-style
  naming — those are a different, cosmetic concern from the structural
  root-resolution bug this task fixes and are out of scope for this
  stage's audit.

  `async: false`: clears and repopulates the shared `orgs` table directly
  with `TRUNCATE ... CASCADE`, same reasoning as
  `seed_root_orgs_test.exs`.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  defp insert_org!(attrs) do
    %Org{}
    |> Org.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_user!(email, oidc_sub) do
    n = System.unique_integer([:positive])

    %Accounts.User{}
    |> Accounts.User.changeset(%{email: email, name: "Legacy Legacy #{n}", oidc_sub: oidc_sub})
    |> Repo.insert!()
  end

  defp insert_membership!(user_id, org_id, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user_id, org_id: org_id, role: role})
    |> Repo.insert!()
  end

  setup do
    # Reproduce a from-scratch legacy install: exactly what the OLD
    # `up/0` body inserted, before task 01a068f6 stage 2 rewrote it, plus
    # real pre-existing membership history.
    #
    # `access_roles` carries an `org_id` FK to `orgs` (custom roles, task
    # 01a1386e-59d1 stage 1), so the CASCADE empties it too, built-in rows
    # included. A from-scratch install has the three built-in rows the roles
    # migration seeds, and every membership insert below needs them
    # (`org_memberships.access_role_key` references `access_roles.key`), so
    # they are copied aside and put back unchanged.
    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TEMP TABLE legacy_legacy_builtin_roles ON COMMIT DROP AS " <>
        "SELECT * FROM access_roles WHERE builtin"
    )

    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE orgs CASCADE")

    Ecto.Adapters.SQL.query!(
      Repo,
      "INSERT INTO access_roles SELECT * FROM legacy_legacy_builtin_roles"
    )

    # The legacy install also configures its own admin domain. The test
    # environment's pin is the neutral `acme.test` (task 01a116de stage 4),
    # so the legacy shape sets it here and restores it afterwards.
    previous_domain = Application.get_env(:platform, :root_org_admin_email_domain)
    Application.put_env(:platform, :root_org_admin_email_domain, "example.net")

    on_exit(fn ->
      Application.put_env(:platform, :root_org_admin_email_domain, previous_domain)
    end)

    legacy = insert_org!(%{name: "Legacy", slug: "legacy", parent_org_id: nil})
    soylent = insert_org!(%{name: "Soylent", slug: "soylent", parent_org_id: legacy.id})
    wayne_tech = insert_org!(%{name: "Wayne-Tech", slug: "wayne_tech", parent_org_id: legacy.id})
    sxi = insert_org!(%{name: "SXI", slug: "sxi", parent_org_id: legacy.id})
    paragon = insert_org!(%{name: "Paragon", slug: "paragon", parent_org_id: legacy.id})

    admin_user = insert_user!("alex.rivera@example.net", "oidc-legacy-admin")
    admin_membership = insert_membership!(admin_user.id, legacy.id, "admin")

    member_user = insert_user!("someone.else@example.net", "oidc-legacy-member")
    member_membership = insert_membership!(member_user.id, legacy.id, "member")

    %{
      legacy: legacy,
      soylent: soylent,
      wayne_tech: wayne_tech,
      sxi: sxi,
      paragon: paragon,
      admin_user: admin_user,
      admin_membership: admin_membership,
      member_user: member_user,
      member_membership: member_membership
    }
  end

  test "get_root_org/0 finds the legacy-slugged org structurally", %{legacy: legacy} do
    assert %Org{id: id, slug: "legacy"} = Tenancy.get_root_org()
    assert id == legacy.id
  end

  test "everything pre-existing is byte-for-byte unchanged after exercising the stage-1 code",
       %{
         legacy: legacy,
         soylent: soylent,
         wayne_tech: wayne_tech,
         sxi: sxi,
         paragon: paragon,
         admin_user: admin_user,
         admin_membership: admin_membership,
         member_membership: member_membership
       } do
    orgs_before = Repo.all(Org) |> Enum.sort_by(& &1.id)
    memberships_before = Repo.all(OrgMembership) |> Enum.sort_by(& &1.id)

    # Exercise the stage-1 structural machinery against this legacy shape,
    # including a login for the EXISTING @example.net admin user with no
    # new env vars set (no email change, so this drives
    # `find_or_create_from_oidc/1`'s idempotent-refresh branch, not the
    # first-INSERT branch the other e2e files already cover).
    assert %Org{slug: "legacy"} = Tenancy.get_root_org()
    assert Tenancy.derive_role_from_email(admin_user.email) == :admin

    assert {:ok, relogged_user} =
             Accounts.find_or_create_from_oidc(%{
               sub: admin_user.oidc_sub,
               email: admin_user.email,
               name: admin_user.name
             })

    assert relogged_user.id == admin_user.id

    orgs_after = Repo.all(Org) |> Enum.sort_by(& &1.id)
    memberships_after = Repo.all(OrgMembership) |> Enum.sort_by(& &1.id)

    assert orgs_before == orgs_after
    assert memberships_before == memberships_after

    # Named checks, not just the bulk comparison above, so a failure here
    # points straight at what changed.
    assert Repo.get(Org, legacy.id) == legacy
    assert Repo.get(Org, soylent.id) == soylent
    assert Repo.get(Org, wayne_tech.id) == wayne_tech
    assert Repo.get(Org, sxi.id) == sxi
    assert Repo.get(Org, paragon.id) == paragon
    assert Repo.get(OrgMembership, admin_membership.id) == admin_membership
    assert Repo.get(OrgMembership, member_membership.id) == member_membership
    assert length(orgs_after) == 5
    assert length(memberships_after) == 2
  end

  test "Tasks.create_project/1 with no org_id attaches to the legacy root with no special-casing",
       %{legacy: legacy} do
    n = System.unique_integer([:positive])

    assert {:ok, project} = Tasks.create_project(%{name: "Legacy Legacy Project #{n}"})
    assert project.org_id == legacy.id
  end

  test "WikiPage.changeset/2 with no org_id defaults to the legacy root", %{legacy: legacy} do
    n = System.unique_integer([:positive])

    page =
      %WikiPage{}
      |> WikiPage.changeset(%{file_key: "org/legacy-legacy-#{n}.md", content: "hello"})
      |> Repo.insert!()

    assert page.org_id == legacy.id
  end

  test "WikiJournalEntry.changeset/2 with no org_id defaults to the legacy root", %{
    legacy: legacy
  } do
    entry =
      %WikiJournalEntry{}
      |> WikiJournalEntry.changeset(%{content: "note", date: Date.utc_today()})
      |> Repo.insert!()

    assert entry.org_id == legacy.id
  end

  test "a first-time OIDC login for a NEW user lands its membership on the legacy root with no special-casing",
       %{legacy: legacy} do
    n = System.unique_integer([:positive])

    assert {:ok, user} =
             Accounts.find_or_create_from_oidc(%{
               sub: "oidc-legacy-legacy-login-#{n}",
               email: "legacy-#{n}@example.com",
               name: "Legacy Login #{n}"
             })

    assert %OrgMembership{org_id: org_id} =
             Repo.get_by(OrgMembership, user_id: user.id, org_id: legacy.id)

    assert org_id == legacy.id
  end

  test "promote_to_admin/1 with no explicit org writes to the legacy root", %{legacy: legacy} do
    user = insert_user!("legacy-promote@example.com", "oidc-legacy-promote")

    assert {:ok, membership} = Tenancy.promote_to_admin(user)
    assert membership.org_id == legacy.id
    assert membership.role == "admin"
  end
end
