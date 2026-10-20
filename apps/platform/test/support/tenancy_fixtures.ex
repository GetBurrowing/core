defmodule Platform.TenancyFixtures do
  @moduledoc """
  Test helpers for the MT/RBAC tenancy schema.

  Once the `orgs` FK constraints land (see migration
  `20260519143600_create_orgs.exs`), columns like
  `runtime_events.owner_org_id`, `audit_events.actor_org_id`, and
  `invocation_visibility_grants.grantee_org_id` can no longer hold an
  arbitrary `Ecto.UUID.generate()`. They must reference a real `orgs.id`.

  These helpers return org ids so tests can populate the FK columns with
  values that exist.

      import Platform.TenancyFixtures

      attrs = %{actor_org_id: acme_org_id(), …}

  ## Get-or-create, not "rely on the seed migration" (task 01a068f6 stage 2)

  `acme_org_id/0` and `tenant_org_id/1` used to hard-rely on
  `20260519143620_seed_root_orgs.exs` having seeded exactly those five
  named orgs as part of `mix ecto.migrate`, via `get_org_by_slug!/1` —
  which RAISES if the row is absent. That migration no longer seeds
  tenant orgs at all, and only seeds a root org named/slugged from
  `ROOT_ORG_NAME`/`ROOT_ORG_SLUG` (see its moduledoc) — "acme" only
  because `config/test.exs` pins those env vars for this environment.

  Both functions now get-or-create: look up by slug first (the common
  case — most tests share the same seeded/previously-created rows within
  a test's sandboxed transaction), and synthesize the row on demand when
  it's missing, so a caller never has to know or care whether the seed
  migration produced it.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  @tenant_names %{
    "initech" => "Initech",
    "vandelay_ind" => "Vandelay-Ind",
    "globex" => "Globex",
    "hooli" => "Hooli"
  }

  @doc """
  Return the id of this install's root (Acme) org, creating one on demand.

  Structural fallback, not slug-blind: if a root org already exists under
  ANY slug (e.g. a caller that migrated without the "acme" env pin), that
  row is reused — inserting a second `parent_org_id: nil` row would trip
  the `orgs_single_root` partial unique index.
  """
  @spec acme_org_id() :: binary()
  def acme_org_id do
    case Tenancy.get_org_by_slug("acme") do
      %Org{id: id} -> id
      nil -> (Tenancy.get_root_org() || create_root_org!()).id
    end
  end

  @doc """
  Return the id of a seeded tenant org by slug, creating it on demand
  parented to this install's root org.

  Well-known slugs (`"initech"`, `"vandelay_ind"`, `"globex"`, `"hooli"`) get
  their historical display name; any other slug is created with a
  humanized version of the slug as its name.
  """
  @spec tenant_org_id(String.t()) :: binary()
  def tenant_org_id(slug) when is_binary(slug) do
    case Tenancy.get_org_by_slug(slug) do
      %Org{id: id} -> id
      nil -> create_tenant_org!(slug).id
    end
  end

  defp create_root_org! do
    %Org{}
    |> Org.changeset(%{name: "Acme", slug: "acme", parent_org_id: nil})
    |> Repo.insert!()
  end

  defp create_tenant_org!(slug) do
    name = Map.get(@tenant_names, slug, Phoenix.Naming.humanize(slug))

    case Tenancy.create_org(root_admin!(), %{name: name, slug: slug}) do
      {:ok, org} ->
        org

      {:error, reason} ->
        raise "Platform.TenancyFixtures.tenant_org_id/1 could not create " <>
                "#{inspect(slug)}: #{inspect(reason)}"
    end
  end

  @doc """
  Insert a user with an internal `admin` membership in this install's root
  org: a root admin.

  `Tenancy.create_org/2` is Acme-admin-only (see `Platform.Tenancy.Lifecycle`)
  — there is no system/unauthenticated path — so `tenant_org_id/1` uses one.
  Public since task 01a1386d-fb6e stage 2: install-level writes
  (`Platform.Access.authorize_install/1`) need a HUMAN actor that is allowed
  to make them, and an unsaved `%User{id: Ecto.UUID.generate()}` holds no
  membership and is refused.
  """
  @spec root_admin!() :: User.t()
  def root_admin! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "tenancy-fixtures-admin-#{n}@example.com",
        name: "TenancyFixtures Admin #{n}",
        oidc_sub: "tenancy-fixtures-admin-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "admin"})
    |> Repo.insert!()

    user
  end

  @doc """
  Give `user` a plain `"member"` `org_memberships` row in every seeded org.

  For tests whose subject is NOT tenancy. Viewer-scoped reads —
  `Tasks.list_projects_for_user/2` and friends — return `[]` for a user with
  no memberships, so a fixture user built with a bare `Repo.insert!(%User{})`
  now renders an empty project sidebar and every unrelated assertion about
  project names fails for a reason that has nothing to do with the test.

  Deliberately `"member"`, not `"admin"`: an admin bypasses org scoping
  wholesale, which would silently mask a real scoping regression in any test
  that used this helper. Scoping itself is pinned by dedicated tests that
  build their own single-org viewer.
  """
  @spec member_of_all_orgs!(struct()) :: struct()
  def member_of_all_orgs!(user) do
    Enum.each(Tenancy.list_orgs(), fn org ->
      %Tenancy.OrgMembership{}
      |> Tenancy.OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
      |> Platform.Repo.insert!()
    end)

    user
  end

  @doc """
  Leave the caller's sandbox with NO root org, without `TRUNCATE orgs`.

  Re-parents the current root (the one row with `parent_org_id IS NULL`)
  under a throwaway child, so the two form a detached cycle: afterwards no
  row has `parent_org_id IS NULL`, and the caller can insert its own root
  or assert the no-root behaviour. Returns the ids of every org that
  existed before the call plus the throwaway child, i.e. the rows a test
  should treat as pre-existing when it asserts on the `orgs` table.

  Why not `TRUNCATE orgs CASCADE`: it takes ACCESS EXCLUSIVE on `orgs` and
  on every table that FK-references it, so it queues behind any
  concurrently running test whose sandbox transaction has read or written
  one of them, and every newer lock request on those tables queues behind
  it. In CI that produced simultaneous 15 s pool timeouts in unrelated
  tests (runs 39331856392, 39347244298). This takes ROW EXCLUSIVE on
  `orgs` and a FOR NO KEY UPDATE row lock on the root (its
  `orgs_single_root` index is partial, so it is not a key column), which
  does not conflict with the FOR KEY SHARE that other transactions' FK
  checks take on the root. The change is uncommitted, so it is invisible
  to every other transaction, and the sandbox rolls it back.
  """
  @spec park_root_org!() :: [binary()]
  def park_root_org! do
    existing = Repo.all(from(o in Org, select: o.id))

    case Repo.one(from(o in Org, where: is_nil(o.parent_org_id))) do
      nil ->
        existing

      root ->
        n = System.unique_integer([:positive])

        child =
          Repo.insert!(%Org{
            name: "parked-root-#{n}",
            slug: "parked-root-#{n}",
            parent_org_id: root.id
          })

        {1, _} =
          Repo.update_all(from(o in Org, where: o.id == ^root.id), set: [parent_org_id: child.id])

        [child.id | existing]
    end
  end
end
