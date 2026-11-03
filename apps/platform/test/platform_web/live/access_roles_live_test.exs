defmodule PlatformWeb.AccessRolesLiveTest do
  @moduledoc """
  Task 01a1a2e4-9265 stage 4: the Custom roles admin page. Every write goes
  through `Platform.Access.RoleAdmin`, so a pushed event from someone who
  cannot manage the role's org writes nothing, and the built-in roles are
  never editable here.

  Fixture: two sibling tenant orgs `a` and `b` (a tenant admin is not a root
  admin, so it holds no module-admin permission).
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.{Role, RoleAssignment, Roles, RuntimeProfiles}
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation
  alias Platform.Federation.ToolAuthorization
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    a = tenant_org_id("roles_live_a_#{n}")
    b = tenant_org_id("roles_live_b_#{n}")
    %{conn: conn, a: a, b: b, admin: member!(a, "admin")}
  end

  defp member!(org_id, role \\ "member") do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "roles-live-#{role}-#{n}@example.com",
        name: "Roles Live #{role} #{n}",
        oidc_sub: "roles-live-#{role}-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp as_user(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp agent_for!(owner) do
    n = System.unique_integer([:positive])
    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "roles-live-#{n}"})

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "roles-live-#{n}",
        name: "Chaz #{n}",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert()

    runtime = runtime |> AgentRuntime.changeset(%{agent_id: agent.id}) |> Repo.update!()
    {:ok, _} = RuntimeProfiles.set_tool_profile(runtime, ["prototype"])
    {agent, runtime}
  end

  defp publisher!(org_id) do
    {:ok, role} =
      Roles.create_custom_role(org_id, %{
        name: "Prototype publisher #{System.unique_integer([:positive])}",
        permissions: %{
          "prototypes.read" => "membership_org",
          "prototypes.publish" => "membership_org"
        }
      })

    role
  end

  defp assignments_count, do: Repo.aggregate(RoleAssignment, :count)

  test "a member is redirected to access-denied server-side", %{conn: conn, a: a} do
    assert {:error, {:redirect, %{to: "/access-denied" <> _}}} =
             live(as_user(conn, member!(a)), "/access/roles")
  end

  test "empty state, read-only built-ins, and create", ctx do
    {:ok, view, html} = live(as_user(ctx.conn, ctx.admin), "/access/roles")

    assert html =~ "Custom roles"
    assert has_element?(view, ~s([data-role="custom-roles-empty"]), "No custom roles yet")
    assert has_element?(view, ~s([data-role="custom-roles-empty"] [data-role="custom-role-new"]))
    refute has_element?(view, ~s([data-role="custom-roles-table"]))

    for name <- ~w(Admin Member Guest) do
      assert has_element?(view, ~s([data-role="builtin-roles"]), name)
    end

    builtin = view |> element(~s([data-role="builtin-roles"])) |> render()
    refute builtin =~ "phx-click"
    refute builtin =~ "href"

    view
    |> element(~s([data-role="custom-roles-empty"] [data-role="custom-role-new"]))
    |> render_click()

    assert has_element?(view, ~s([data-role="custom-role-editor"]))

    # Only permissions the viewer holds, never module-admin ones.
    assert has_element?(
             view,
             ~s([data-role="custom-role-permission"][value="prototypes.publish"])
           )

    refute has_element?(view, ~s([data-role="custom-role-permission"][value="tasks.manage"]))
    refute has_element?(view, ~s([data-role="custom-role-permission"][value="prompts.manage"]))
    refute has_element?(view, ~s([data-role="custom-role-permission"][value="agents.manage_all"]))
    assert render(view) =~ "Publish prototypes"

    view
    |> form("#custom-role-form", %{
      "name" => "Publishers",
      "permissions" => ["prototypes.publish", "prototypes.read"]
    })
    |> render_submit()

    role = Repo.one!(from(r in Role, where: r.org_id == ^ctx.a and r.name == "Publishers"))

    assert role.permissions == %{
             "prototypes.publish" => "membership_org",
             "prototypes.read" => "membership_org"
           }

    assert_patch(view, "/access/roles/#{role.key}")
  end

  test "the list shows the permission count and the assigned names", ctx do
    role = publisher!(ctx.a)
    user = member!(ctx.a)
    {agent, _} = agent_for!(user)
    {:ok, _} = Roles.assign(%{principal: user, role: role})
    {:ok, _} = Roles.assign(%{principal: agent, role: role})

    {:ok, view, _} = live(as_user(ctx.conn, ctx.admin), "/access/roles")

    row = ~s([data-role="custom-role-row"][data-key="#{role.key}"])
    assert has_element?(view, row, role.name)

    assert has_element?(
             view,
             row <> ~s( [data-role="custom-role-permissions"]),
             "2 · publish, read"
           )

    assigned = view |> element(row <> ~s( [data-role="custom-role-assigned"])) |> render()
    assert assigned =~ user.name
    assert assigned =~ agent.name
    assert has_element?(view, ~s([data-role="custom-role-new"]))
    refute has_element?(view, ~s([data-role="custom-roles-empty"]))
  end

  test "edit permissions, assign a user and an agent, and unassign with a confirmation", ctx do
    role = publisher!(ctx.a)
    owner = member!(ctx.a)
    {agent, runtime} = agent_for!(owner)

    {:ok, view, _} = live(as_user(ctx.conn, ctx.admin), "/access/roles/#{role.key}")
    assert has_element?(view, ~s([data-role="custom-role-editor"]))

    view
    |> form("#custom-role-form", %{"name" => role.name, "permissions" => ["prototypes.publish"]})
    |> render_submit()

    assert Roles.get_role(role.key).permissions == %{"prototypes.publish" => "membership_org"}

    for principal <- ["user:#{owner.id}", "agent:#{agent.id}"] do
      view |> form("#custom-role-assign-form", %{"principal" => principal}) |> render_submit()
    end

    assert has_element?(view, ~s([data-role="custom-role-assignment"]), owner.name)
    assert has_element?(view, ~s([data-role="custom-role-assignment"]), agent.name)
    assert :ok = ToolAuthorization.authorize("prototype_publish", runtime)

    owner_row =
      Repo.one!(
        from(a in RoleAssignment,
          where: a.role_key == ^role.key and a.principal_type == "user"
        )
      )

    view
    |> element(
      ~s([data-role="custom-role-assignment"][data-id="#{owner_row.id}"] [data-role="custom-role-remove"])
    )
    |> render_click()

    confirm = view |> element(~s([data-role="custom-role-unassign-confirm"])) |> render()
    assert confirm =~ "#{owner.name} will stop being able to publish prototypes."
    assert confirm =~ agent.name
    # Nothing is removed until the confirmation.
    assert Repo.get(RoleAssignment, owner_row.id)

    view |> element(~s([data-role="custom-role-unassign-yes"])) |> render_click()

    refute Repo.get(RoleAssignment, owner_row.id)
    refute has_element?(view, ~s([data-role="custom-role-unassign-confirm"]))
    assert {:error, :forbidden} = ToolAuthorization.authorize("prototype_publish", runtime)
  end

  test "a built-in role's edit route renders no form, and a pushed save_role changes nothing",
       ctx do
    before = Roles.get_role("member")

    {:ok, view, html} = live(as_user(ctx.conn, ctx.admin), "/access/roles/member")
    assert html =~ "Built-in roles can&#39;t be edited."
    refute has_element?(view, ~s([data-role="custom-role-editor"]))
    refute has_element?(view, "#custom-role-form")

    html =
      render_hook(view, "save_role", %{
        "key" => "member",
        "name" => "Hacked",
        "permissions" => ["prototypes.publish"]
      })

    assert html =~ "Built-in roles can&#39;t be edited."
    after_ = Roles.get_role("member")

    assert :erlang.term_to_binary(after_.permissions) ==
             :erlang.term_to_binary(before.permissions)

    assert after_.name == before.name
    assert after_.updated_at == before.updated_at
    refute Map.has_key?(after_.permissions, "prototypes.publish")
  end

  test "an org-a admin pushing assign_role for an org-b role is refused and writes nothing",
       ctx do
    b_role = publisher!(ctx.b)
    b_member = member!(ctx.b)
    {:ok, view, _} = live(as_user(ctx.conn, ctx.admin), "/access/roles")
    before = assignments_count()

    html =
      render_hook(view, "assign_role", %{
        "key" => b_role.key,
        "principal" => "user:#{b_member.id}"
      })

    assert html =~ "Only an org admin can change roles."
    assert assignments_count() == before

    html = render_hook(view, "save_role", %{"key" => b_role.key, "name" => "Taken over"})
    assert html =~ "Only an org admin can change roles."
    assert Roles.get_role(b_role.key).name == b_role.name

    # Org b's roles are never listed for an org-a admin.
    refute render(view) =~ b_role.name
  end
end
