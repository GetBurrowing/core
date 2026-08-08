defmodule Platform.Tenancy.ScopeTest do
  @moduledoc """
  Pins `Tenancy.visibility/1` + `Tenancy.scope/3` — the one viewer-scope
  choke point — and the root-member / root-admin distinction they rest on.

  Fixture users get `@example.com` addresses on purpose:
  `Tenancy.derive_role_from_email/1` returns `:admin` for `@example.com`,
  which would blanket-bypass the very check under test.
  """
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp user!(name \\ "Scope Test User") do
    Repo.insert!(%User{
      email: "tenancy_scope_#{System.unique_integer([:positive])}@example.com",
      name: name,
      oidc_sub: "oidc-tenancy-scope-#{System.unique_integer([:positive])}"
    })
  end

  defp member!(user, org_id, role \\ "member") do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp project!(org_id) do
    %Project{}
    |> Project.changeset(%{
      name: "Scope Project #{System.unique_integer([:positive])}",
      org_id: org_id
    })
    |> Repo.insert!()
  end

  defp with_preloads(user), do: Repo.preload(user, org_memberships: :org)

  describe "visibility/1" do
    test "a plain member of one tenant org resolves to {:orgs, [that_id]}" do
      sxi = tenant_org_id("sxi")
      user = user!() |> member!(sxi)

      # Precondition: this user must NOT be a root admin, or the assertion
      # below would pass for the wrong reason.
      refute Tenancy.fabrikam_admin?(user)

      assert Tenancy.visibility(user) == {:orgs, [sxi]}
    end

    test "a root-org member (role: member) is :root_all but NOT a fabrikam admin" do
      user = user!() |> member!(fabrikam_org_id(), "member")

      assert Tenancy.root_member?(user)
      refute Tenancy.fabrikam_admin?(user)
      assert Tenancy.visibility(user) == :root_all
    end

    test "a root-org admin is :root_all AND a fabrikam admin" do
      user = user!() |> member!(fabrikam_org_id(), "admin")

      assert Tenancy.root_member?(user)
      assert Tenancy.fabrikam_admin?(user)
      assert Tenancy.visibility(user) == :root_all
    end

    test "nil, a map without an id, and a zero-membership user are all :none" do
      assert Tenancy.visibility(nil) == :none
      assert Tenancy.visibility(%{}) == :none

      orphan = user!("Orphan")
      assert Repo.all(Tenancy.viewer_org_ids_query(orphan.id)) == []
      assert Tenancy.visibility(orphan) == :none
    end

    test "ids are sorted and deduped so the value is comparable" do
      a = tenant_org_id("sxi")
      b = tenant_org_id("soylent")
      user = user!() |> member!(a) |> member!(b)

      assert {:orgs, ids} = Tenancy.visibility(user)
      assert ids == Enum.sort([a, b])
    end

    test "the preloaded and non-preloaded resolution paths agree" do
      plain = user!() |> member!(tenant_org_id("sxi"))
      root = user!() |> member!(fabrikam_org_id(), "member")
      orphan = user!()

      for user <- [plain, root, orphan] do
        preloaded = with_preloads(user)
        assert is_list(preloaded.org_memberships)

        assert Tenancy.visibility(preloaded) == Tenancy.visibility(user),
               "preloaded and Repo paths disagreed for #{user.email}"
      end
    end
  end

  describe "scope/3" do
    test ":none returns zero rows from a fixture proven to hold rows" do
      project!(tenant_org_id("sxi"))

      # ANTI-VACUITY: without this, the assertion below passes on an empty DB.
      assert Repo.aggregate(Project, :count) > 0

      assert Repo.aggregate(Tenancy.scope(Project, :none), :count) == 0
    end

    test "{:orgs, [a]} returns org A's project and NOT org B's" do
      a = tenant_org_id("sxi")
      b = tenant_org_id("soylent")
      pa = project!(a)
      pb = project!(b)

      ids = Project |> Tenancy.scope({:orgs, [a]}) |> Repo.all() |> Enum.map(& &1.id)

      assert pa.id in ids
      refute pb.id in ids
    end

    test ":root_all returns both orgs' projects, queryable untouched" do
      pa = project!(tenant_org_id("sxi"))
      pb = project!(tenant_org_id("soylent"))

      ids = Project |> Tenancy.scope(:root_all) |> Repo.all() |> Enum.map(& &1.id)

      assert pa.id in ids
      assert pb.id in ids
    end

    test "an empty allow-list fails closed rather than returning everything" do
      project!(tenant_org_id("sxi"))
      assert Repo.aggregate(Project, :count) > 0

      assert Repo.aggregate(Tenancy.scope(Project, {:orgs, []}), :count) == 0
    end

    test ":binding targets a named join so tasks can be scoped through projects" do
      import Ecto.Query

      a = tenant_org_id("sxi")
      b = tenant_org_id("soylent")
      pa = project!(a)
      pb = project!(b)

      joined =
        from(p in Project,
          join: o in assoc(p, :org),
          as: :org,
          select: p.id
        )

      ids = joined |> Tenancy.scope({:orgs, [a]}, field: :id, binding: :org) |> Repo.all()

      assert pa.id in ids
      refute pb.id in ids
    end
  end

  describe "root_member_preloaded?/1" do
    test "mirrors root_member?/1 and stays distinct from fabrikam_admin_preloaded?/1" do
      root_member = user!() |> member!(fabrikam_org_id(), "member") |> with_preloads()
      tenant_member = user!() |> member!(tenant_org_id("sxi")) |> with_preloads()

      assert Tenancy.root_member_preloaded?(root_member)
      refute Tenancy.fabrikam_admin_preloaded?(root_member)

      refute Tenancy.root_member_preloaded?(tenant_member)
      refute Tenancy.fabrikam_admin_preloaded?(tenant_member)

      refute Tenancy.root_member_preloaded?(nil)
      refute Tenancy.root_member_preloaded?(%{})
    end
  end
end
