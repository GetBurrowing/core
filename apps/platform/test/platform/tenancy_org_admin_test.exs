defmodule Platform.TenancyOrgAdminTest do
  @moduledoc """
  `Platform.Tenancy.org_admin?/2` and `internal_member?/2` (task 01a0cf21
  stage 1). Relies on the seeded orgs (Acme root + tenants).
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "org-admin-#{n}@example.com",
      name: "Org Admin #{n}",
      oidc_sub: "oidc-org-admin-#{n}"
    })
    |> Repo.insert!()
  end

  defp member!(user, org_id, role, external \\ false) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: role,
      external: external
    })
    |> Repo.insert!()
  end

  setup do
    %{
      org_id: Tenancy.get_org_by_slug!("soylent").id,
      other_org_id: Tenancy.get_org_by_slug!("sxi").id,
      acme_id: Tenancy.get_org_by_slug!("acme").id
    }
  end

  test "a non-external admin of the org is an org admin", %{org_id: org_id} do
    user = user!()
    member!(user, org_id, "admin")
    assert Tenancy.org_admin?(user, org_id)
    assert Tenancy.internal_member?(user, org_id)
  end

  test "a member is not an org admin but is an internal member", %{org_id: org_id} do
    user = user!()
    member!(user, org_id, "member")
    refute Tenancy.org_admin?(user, org_id)
    assert Tenancy.internal_member?(user, org_id)
  end

  test "an EXTERNAL admin is neither", %{org_id: org_id} do
    user = user!()
    member!(user, org_id, "admin", true)
    refute Tenancy.org_admin?(user, org_id)
    refute Tenancy.internal_member?(user, org_id)
  end

  test "admin of ANOTHER org is not an admin of this one", ctx do
    user = user!()
    member!(user, ctx.other_org_id, "admin")
    refute Tenancy.org_admin?(user, ctx.org_id)
    refute Tenancy.internal_member?(user, ctx.org_id)
  end

  test "an Acme root admin with no admin row in the org gets no bypass", ctx do
    user = user!()
    member!(user, ctx.acme_id, "admin")
    member!(user, ctx.org_id, "member")

    # Control: the user really is a root admin, so the refusal is not vacuous.
    assert Tenancy.root_admin?(user)
    refute Tenancy.org_admin?(user, ctx.org_id)
    assert Tenancy.org_admin?(user, ctx.acme_id)
  end

  test "garbage input returns false and never raises", %{org_id: org_id} do
    user = user!()
    member!(user, org_id, "admin")
    refute Tenancy.org_admin?(user, "soylent")
    refute Tenancy.org_admin?(user, "not-a-uuid")
    refute Tenancy.org_admin?(nil, org_id)
    refute Tenancy.org_admin?(%{id: "not-a-uuid"}, org_id)
    refute Tenancy.org_admin?(user, nil)
    refute Tenancy.internal_member?(user, "not-a-uuid")
  end
end
