defmodule PlatformWeb.ModuleAdminViewsTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.Grants
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  defp user!(role, org_id) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "module-admin-#{n}@example.com",
        name: "Module Admin #{n}",
        oidc_sub: "module-admin-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  test "root admin opens Pipeline and Prompts; members and sub-org admins cannot" do
    root = user!("admin", acme_org_id())
    member = user!("member", acme_org_id())
    sub_admin = user!("admin", tenant_org_id("module-admin-sub"))

    assert {:ok, _, _} = live(authed(root), "/tasks/pipeline")
    assert {:ok, _, _} = live(authed(root), "/admin/prompts")

    for user <- [member, sub_admin] do
      assert {:error, {_, %{to: "/access-denied?module=tasks"}}} =
               live(authed(user), "/tasks/pipeline")

      assert {:error, {_, %{to: "/access-denied?module=prompts"}}} =
               live(authed(user), "/admin/prompts")
    end
  end

  test "the old Pipeline URL redirects to its Tasks route" do
    root = user!("admin", acme_org_id())
    conn = get(authed(root), "/admin/pipeline")
    assert conn.status == 302
    assert redirected_to(conn) == "/tasks/pipeline"
  end

  test "a project-scoped tasks.manage grantee cannot read install-wide Pipeline data" do
    child = tenant_org_id("module-admin-grantee")
    user = user!("member", child)
    {:ok, project} = Tasks.create_project(%{name: "Module admin scope", org_id: child})
    {:ok, _} = Grants.grant(%{principal: user, permission: "tasks.manage", resource: project})

    assert {:error, {_, %{to: "/access-denied?module=tasks"}}} =
             live(authed(user), "/tasks/pipeline")
  end

  test "a project-scoped prompts.manage grantee cannot read install-wide templates" do
    child = tenant_org_id("module-admin-prompts-grantee")
    user = user!("member", child)
    {:ok, project} = Tasks.create_project(%{name: "Module prompts scope", org_id: child})

    {:ok, _} =
      Grants.grant(%{principal: user, permission: "prompts.manage", resource: project})

    assert {:error, {_, %{to: "/access-denied?module=prompts"}}} =
             live(authed(user), "/admin/prompts")
  end

  test "module-admin grantees cannot mount install-level LiveViews" do
    child = tenant_org_id("module-admin-install")
    grantee = user!("member", child)
    sub_admin = user!("admin", child)
    {:ok, project} = Tasks.create_project(%{name: "Module admin install", org_id: child})
    {:ok, _} = Grants.grant(%{principal: grantee, permission: "tasks.manage", resource: project})

    install_routes =
      for route <- Phoenix.Router.routes(PlatformWeb.Router),
          {view, _, _, %{name: session}} <- [route.metadata[:phoenix_live_view]],
          session in [:admin, :admin_sign_in],
          view != PlatformWeb.AdminPromptsLive,
          do: route.path

    assert install_routes != []

    for path <- install_routes, user <- [grantee, sub_admin] do
      if path == "/admin/sign-in-users" do
        if Platform.SignInAdmin.Config.enabled?() do
          assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
                   live(authed(user), path)
        else
          assert_raise PlatformWeb.Plugs.RequireSignInAdmin.NotFoundError, fn ->
            get(authed(user), path)
          end
        end
      else
        assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
                 live(authed(user), path)
      end
    end
  end
end
