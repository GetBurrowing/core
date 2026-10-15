defmodule PlatformWeb.ModuleGateTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ModuleGate

  @gated_sessions [:authenticated, :canvas_standalone, :external_chat, :admin, :admin_sign_in]

  defp user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "module-gate-#{n}@example.com",
      name: "Module Gate #{n}",
      oidc_sub: "oidc-module-gate-#{n}"
    })
    |> Repo.insert!()
  end

  defp member!(user, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: role
    })
    |> Repo.insert!()

    user
  end

  defp authed(conn, user), do: init_test_session(conn, current_user_id: user.id)

  test "every LiveView in a gated session has an explicit disposition" do
    known = Map.keys(ModuleGate.view_modules()) ++ ModuleGate.ungated_views()

    missing =
      for route <- Phoenix.Router.routes(PlatformWeb.Router),
          {view, _action, _opts, %{name: session}} <-
            [route.metadata[:phoenix_live_view]],
          session in @gated_sessions,
          view not in known,
          do: {route.path, view}

    assert missing == []
  end

  test "the authenticated session installs the mount gate for live navigation" do
    router = File.read!("lib/platform_web/router.ex")

    assert router =~
             ~r/live_session :authenticated,\s*on_mount: \[[^]]*\{PlatformWeb.ModuleGate, :default\}/s
  end

  test "member denied an admin deep link reaches the access page", %{conn: conn} do
    user = user!() |> member!("member")

    assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
             conn |> authed(user) |> live("/admin/branding")

    denied = conn |> authed(user) |> get("/access-denied?module=admin")
    assert denied.status == 403
    assert denied.resp_body =~ "You don't have access, ask an admin"
    assert denied.resp_body =~ "Module: Admin"
  end

  test "only a known module key is rendered on the denial page", %{conn: conn} do
    user = user!() |> member!("member")
    denied = conn |> authed(user) |> get("/access-denied?module=secret-value")
    assert denied.status == 403
    refute denied.resp_body =~ "secret-value"
  end

  test "root admin still opens admin, and a member opens tasks", %{conn: conn} do
    admin = user!() |> member!("admin")
    member = user!() |> member!("member")

    assert {:ok, _view, _html} = conn |> authed(admin) |> live("/admin")
    assert {:ok, _view, _html} = build_conn() |> authed(member) |> live("/tasks")
  end

  test "a guest gets the same 403 message for tasks and files", %{conn: conn} do
    user = user!()

    {:ok, _} =
      Tenancy.mark_membership_external(%{
        user_id: user.id,
        org_id: Tenancy.get_org_by_slug!("sxi").id
      })

    for path <- ["/tasks", "/files"] do
      denied = conn |> authed(user) |> get(path)
      assert denied.status == 403
      assert denied.resp_body =~ "You don't have access, ask an admin"
    end
  end

  test "the mount gate refuses a guest Tasks socket even after a chat admission" do
    user = user!()

    {:ok, _} =
      Tenancy.mark_membership_external(%{
        user_id: user.id,
        org_id: Tenancy.get_org_by_slug!("sxi").id
      })

    socket = %Phoenix.LiveView.Socket{
      endpoint: PlatformWeb.Endpoint,
      view: PlatformWeb.TasksLive,
      assigns: %{
        __changed__: %{},
        access_scope: Scope.for_user(Platform.Accounts.get_user(user.id))
      }
    }

    assert {:halt, _socket} = ModuleGate.on_mount(:default, %{}, %{}, socket)
  end
end
