defmodule Platform.Access.ModuleGatingAcceptanceTest do
  @moduledoc """
  End-to-end acceptance for RBAC module gating (task 01a1386d-fb6e, stage 5).

  Stage 2 counted 37 Tasks write entry points, exceeding the plan's bound of
  25. Tasks therefore remains closed to guests even with a tasks.read grant.
  This suite pins the HTTP and rail fence without claiming that Tasks writes
  have a context check they do not yet have.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Grants, Registry, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Branding
  alias Platform.Experiments
  alias Platform.Prototypes.Settings, as: PrototypeSettings
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.{IconRail, MoreSheet}

  setup do
    Platform.Experiments.TestSurfaces.register()
    root = acme_org_id()
    child = tenant_org_id("module-gating-acceptance")
    admin = user!("admin", root, "admin")
    member = user!("member", child, "member")
    sub_admin = user!("sub-admin", child, "admin")
    guest = user!("guest", child, "member", true)
    {:ok, p} = Tasks.create_project(%{name: unique("acceptance P"), org_id: child})
    {:ok, q} = Tasks.create_project(%{name: unique("acceptance Q"), org_id: child})
    task = Repo.insert!(%Task{project_id: q.id, title: unique("Q task"), status: "backlog"})

    %{admin: admin, member: member, sub_admin: sub_admin, guest: guest, p: p, q: q, task: task}
  end

  defp unique(prefix), do: "#{prefix} #{System.unique_integer([:positive])}"

  defp user!(tag, org_id, role, external \\ false) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "module-gating-#{tag}-#{n}@example.com",
        name: "Module Gating #{tag}",
        oidc_sub: "module-gating-#{tag}-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: role,
      external: external
    })
    |> Repo.insert!()

    user
  end

  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)
  defp scope(user), do: user.id |> Accounts.get_user() |> Scope.for_user()

  defp denial_content(conn) do
    [content] = Regex.run(~r|<main\b.*</main>|s, conn.resp_body)
    content
  end

  defp keys(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("data-destination")
    |> Enum.map(&String.to_atom/1)
  end

  defp rail_keys(scope) do
    assigns = %{access_scope: scope}

    desktop =
      rendered_to_string(~H"<IconRail.icon_rail access_scope={@access_scope} />")
      |> keys("[data-icon-rail] .icon-rail-tab:not(.icon-rail-tab--child)")

    mobile =
      rendered_to_string(~H"<IconRail.bottom_rail access_scope={@access_scope} />")
      |> keys("[data-bottom-rail] .bottom-nav-tab")
      |> List.delete(:more)

    more =
      rendered_to_string(
        ~H"<MoreSheet.more_sheet open={true} access_scope={@access_scope} current_user={nil} />"
      )
      |> keys(".more-sheet-row[data-destination]")

    %{desktop: desktop, mobile: mobile, more: more}
  end

  describe "1. a guest's rail shows only granted modules" do
    test "all three surfaces follow the single registry decision, including a project grant", ctx do
      internal = rail_keys(scope(ctx.member))
      assert :tasks in internal.desktop
      assert :tasks in internal.mobile
      assert :files in internal.more

      guest = rail_keys(scope(ctx.guest))
      assert guest == %{desktop: [:chat], mobile: [:chat], more: []}

      {:ok, _} =
        Grants.grant(%{principal: ctx.guest, permission: "tasks.read", resource: ctx.p})

      granted_scope = scope(ctx.guest)
      assert Access.holds_anywhere?(granted_scope, "tasks.read")
      refute Registry.rail_entry(:tasks).guest_admissible
      assert rail_keys(granted_scope) == guest
    end
  end

  describe "2. a denied module URL shows the access message" do
    test "guest denials have the same standalone body as a missing task", ctx do
      assert {:ok, _, _} = live(authed(ctx.member), "/files")
      assert {:ok, _, _} = live(authed(ctx.admin), "/admin/branding")

      for path <- ["/tasks/#{ctx.task.id}", "/files", "/org_memory"] do
        conn = get(authed(ctx.guest), path)
        assert conn.status == 403
        assert conn.resp_body =~ "You don't have access, ask an admin"
        refute conn.resp_body =~ "data-icon-rail"
        refute conn.resp_body =~ "data-bottom-rail"
      end

      existing = get(authed(ctx.guest), "/tasks/#{ctx.task.id}")
      missing = get(authed(ctx.guest), "/tasks/#{Ecto.UUID.generate()}")
      # The endpoint creates a fresh CSRF token in each response's head. The
      # denial content itself must be byte-identical for real and absent ids.
      assert denial_content(existing) == denial_content(missing)

      assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
               live(authed(ctx.member), "/admin/branding")
    end

    test "a project grant cannot open Tasks while its write surface is unbounded", ctx do
      {:ok, _} =
        Grants.grant(%{principal: ctx.guest, permission: "tasks.read", resource: ctx.p})

      assert Access.holds_anywhere?(scope(ctx.guest), "tasks.read")
      assert get(authed(ctx.guest), "/tasks").status == 403
      assert {:ok, _, _} = live(authed(ctx.member), "/tasks")
    end
  end

  describe "3. contexts re-check authorization" do
    test "Experiments and Branding refuse a non-root caller before writes", ctx do
      {:ok, draft} =
        Experiments.create_experiment(%{
          slug: unique("acceptance"),
          name: unique("Experiment"),
          surface_key: "test.budget",
          surface_target: unique("target")
        })

      assert {:error, :unauthorized} = Experiments.start(draft, ctx.member)
      assert Repo.get!(Platform.Experiments.Experiment, draft.id).status == "draft"
      assert {:ok, _} = Experiments.start(draft, ctx.admin)

      assert {:error, :unauthorized} = Branding.update_identity(ctx.sub_admin, %{})
      assert {:ok, _} = Branding.update_identity(ctx.admin, %{})
    end

    test "Tasks scope predicate refuses guest writes; the legacy no-opt system path remains", ctx do
      s = scope(ctx.guest)
      assert Access.authorize(s, "tasks.write", {:project, ctx.q.id}) ==
               {:error, :unauthorized}

      assert {:ok, %Task{}} = Tasks.update_task(ctx.task, %{title: unique("system update")})
    end
  end

  describe "4. a module admin cannot reach install settings" do
    test "project module-admin grant leaves install pages and contexts closed", ctx do
      {:ok, _} =
        Grants.grant(%{principal: ctx.member, permission: "tasks.manage", resource: ctx.p})

      assert Access.module_access?(scope(ctx.member), :tasks, "tasks.manage")
      assert {:error, {_, %{to: "/access-denied?module=tasks"}}} =
               live(authed(ctx.member), "/tasks/pipeline")

      for user <- [ctx.member, ctx.sub_admin] do
        assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
                 live(authed(user), "/admin/branding")

        assert Access.authorize_install(user) == {:error, :unauthorized}
        assert Branding.update_identity(user, %{}) == {:error, :unauthorized}
        assert PrototypeSettings.update(user, %{}) == {:error, :unauthorized}
      end

      assert {:ok, _, _} = live(authed(ctx.admin), "/admin/branding")
      assert {:ok, _} = PrototypeSettings.update(ctx.admin, %{})
    end
  end
end
