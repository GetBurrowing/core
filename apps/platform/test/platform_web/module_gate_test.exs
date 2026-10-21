defmodule PlatformWeb.ModuleGateTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Access.{Grant, Grants, Scope}
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

  test "the generic extension host checks its registered page permission" do
    Platform.FixtureExtension.register([Platform.FixtureExtension])
    user = user!() |> member!("member")

    socket = %Phoenix.LiveView.Socket{
      endpoint: PlatformWeb.Endpoint,
      view: PlatformWeb.ExtensionPageLive,
      assigns: %{
        __changed__: %{},
        access_scope: Scope.for_user(Platform.Accounts.get_user(user.id))
      }
    }

    assert {:cont, _} = ModuleGate.on_mount(:default, %{"prefix" => "fixture"}, %{}, socket)
    denied = %{socket | assigns: Map.put(socket.assigns, :access_scope, %Scope{})}
    assert {:halt, _} = ModuleGate.on_mount(:default, %{"prefix" => "fixture"}, %{}, denied)
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
        org_id: Tenancy.get_org_by_slug!("globex").id
      })

    for path <- ["/tasks", "/files"] do
      denied = conn |> authed(user) |> get(path)
      assert denied.status == 403
      assert denied.resp_body =~ "You don't have access, ask an admin"
    end
  end

  test "the mount gate refuses guest Tasks and Changelog sockets after chat admission" do
    user = user!()

    {:ok, _} =
      Tenancy.mark_membership_external(%{
        user_id: user.id,
        org_id: Tenancy.get_org_by_slug!("globex").id
      })

    for view <- [PlatformWeb.TasksLive, PlatformWeb.ChangelogLive] do
      socket = %Phoenix.LiveView.Socket{
        endpoint: PlatformWeb.Endpoint,
        view: view,
        assigns: %{
          __changed__: %{},
          access_scope: Scope.for_user(Platform.Accounts.get_user(user.id))
        }
      }

      assert {:halt, _socket} = ModuleGate.on_mount(:default, %{}, %{}, socket)
    end
  end

  # ── Module locks (task 01a14721 stage 3) ──────────────────────────────

  @locked_paths [
    {"/control", :agents, PlatformWeb.ControlCenterLive},
    {"/files", :files, PlatformWeb.FilesLive},
    {"/org_memory", :context, PlatformWeb.OrgMemoryLive},
    {"/inbox", :inbox, PlatformWeb.InboxLive},
    # The Activity page is retired (task 01a1557a-7a71 stage 4); the
    # `activity` module now gates /changelog, so the lock keeps coverage here.
    {"/changelog", :activity, PlatformWeb.ChangelogLive},
    {"/email", :email, PlatformWeb.EmailLive},
    {"/skills", :skills, PlatformWeb.SkillsLive},
    {"/control/experiments", :experiments, PlatformWeb.ExperimentsLive}
  ]

  defp lock_all_but!(user, keep) do
    org = Tenancy.get_org_by_slug!("acme").id

    for module <- Grant.lockable_modules() -- keep do
      {:ok, _} =
        Grants.deny(%{principal: {:user, user.id}, permission: module, resource: {:module, org}})
    end

    user
  end

  defp gate(user, view) do
    socket = %Phoenix.LiveView.Socket{
      endpoint: PlatformWeb.Endpoint,
      view: view,
      assigns: %{
        __changed__: %{},
        access_scope: Scope.for_user(Platform.Accounts.get_user(user.id))
      }
    }

    ModuleGate.on_mount(:default, %{}, %{}, socket)
  end

  describe "a member locked out of every module but chat, tasks and meetings" do
    setup do
      locked = user!() |> member!("member") |> lock_all_but!(~w(chat tasks meetings))
      twin = user!() |> member!("member")
      %{locked: locked, twin: twin}
    end

    test "a GET by URL of each locked module's page redirects to its access-denied page", ctx do
      for {path, key, view} <- @locked_paths do
        # Positive control: the router maps the path to the view, and the
        # unlocked twin passes the same gate for it.
        assert %{phoenix_live_view: {^view, _, _, _}} =
                 Phoenix.Router.route_info(PlatformWeb.Router, "GET", path, "localhost")

        assert {:cont, _} = gate(ctx.twin, view), path
        assert {:halt, _} = gate(ctx.locked, view), path

        conn = build_conn() |> authed(ctx.locked) |> get(path)
        assert redirected_to(conn, 302) == "/access-denied?module=#{key}", path

        assert {:error, {:redirect, %{to: to}}} = build_conn() |> authed(ctx.locked) |> live(path)
        assert to == "/access-denied?module=#{key}", path
      end
    end

    test "a live_redirect from /chat to each locked module's page is refused", ctx do
      for {path, key, _view} <- @locked_paths do
        {:ok, chat, _} = build_conn() |> authed(ctx.locked) |> live("/chat")
        assert {:error, {:redirect, %{to: to}}} = live_redirect(chat, to: path)
        assert to == "/access-denied?module=#{key}", path
      end
    end

    test "/chat, /tasks and /meetings still open", ctx do
      for path <- ["/chat", "/tasks", "/meetings"] do
        assert {:ok, _view, _html} = build_conn() |> authed(ctx.locked) |> live(path), path
      end
    end
  end
end
