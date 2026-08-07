defmodule Platform.TenancyFixtures do
  @moduledoc """
  Test helpers for the MT/RBAC tenancy schema.

  Once the `orgs` FK constraints land (see migration
  `20260519143600_create_orgs.exs`), columns like
  `runtime_events.owner_org_id`, `audit_events.actor_org_id`, and
  `invocation_visibility_grants.grantee_org_id` can no longer hold an
  arbitrary `Ecto.UUID.generate()`. They must reference a real `orgs.id`.

  These helpers return the seeded org ids so tests can populate the
  FK columns with values that exist.

      import Platform.TenancyFixtures

      attrs = %{actor_org_id: fabrikam_org_id(), …}

  Both `fabrikam_org_id/0` and `tenant_org_id/1` rely on the seed migration
  (`20260519143620_seed_root_orgs.exs`) having run as part of
  `mix ecto.migrate` — they do not seed on demand.
  """

  alias Platform.Tenancy

  @doc "Return the id of the seeded Fabrikam (root) org."
  @spec fabrikam_org_id() :: binary()
  def fabrikam_org_id, do: Tenancy.get_org_by_slug!("fabrikam").id

  @doc """
  Return the id of a seeded tenant org by slug.

  Valid slugs: `"soylent"`, `"wayne_tech"`, `"sxi"`, `"paragon"`.
  """
  @spec tenant_org_id(String.t()) :: binary()
  def tenant_org_id(slug) when is_binary(slug), do: Tenancy.get_org_by_slug!(slug).id

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
end
