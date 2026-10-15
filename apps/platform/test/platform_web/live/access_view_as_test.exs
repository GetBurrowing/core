defmodule PlatformWeb.AccessViewAsTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Access.{Grants, Scope, ViewAs}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.{Org, OrgMembership}
  alias PlatformWeb.Components.IconRail

  defp user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "view-as-#{n}@example.com", name: name, oidc_sub: "view-as-#{n}"})
    |> Repo.insert!()
  end

  defp membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp conn_for(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp rail_keys(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-icon-rail] [data-destination]")
    |> Enum.map(&Floki.attribute(&1, "data-destination"))
    |> List.flatten()
    |> MapSet.new()
  end

  defp view_rail_keys(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-role=view-as-rail] [data-destination]")
    |> Enum.map(&Floki.attribute(&1, "data-destination"))
    |> List.flatten()
    |> MapSet.new()
  end

  setup do
    root_org = Tenancy.get_org_by_slug!("acme")
    root = user!("View root")
    member = user!("View member")
    guest = user!("View guest")
    membership!(root, root_org, "admin")
    membership!(member, root_org, "member")
    assert {:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: root_org.id})
    %{root: root, member: member, guest: guest, org: root_org}
  end

  test "root and member view-as rails equal their real rails, with a positive control", ctx do
    {:ok, _root_real, root_html} = conn_for(ctx.root) |> live("/tasks")
    {:ok, _member_real, member_html} = conn_for(ctx.member) |> live("/tasks")
    root_keys = rail_keys(root_html)
    member_keys = rail_keys(member_html)
    assert root_keys != member_keys

    {:ok, _root_view, root_view_html} =
      conn_for(ctx.root) |> live("/access/view-as/user/#{ctx.root.id}")

    {:ok, _member_view, member_view_html} =
      conn_for(ctx.root) |> live("/access/view-as/user/#{ctx.member.id}")

    assert view_rail_keys(root_view_html) == root_keys
    assert view_rail_keys(member_view_html) == member_keys
  end

  test "guest has the external surface and no rail; member role matches a member", ctx do
    {:ok, _guest_view, guest_html} =
      conn_for(ctx.root) |> live("/access/view-as/user/#{ctx.guest.id}")

    assert guest_html =~ ~s(data-role="view-as-surface">external_chat)
    assert view_rail_keys(guest_html) == MapSet.new()

    {:ok, _role_view, role_html} =
      conn_for(ctx.root) |> live("/access/view-as/role/#{ctx.org.id}:member")

    expected =
      IconRail.destinations(root_user: false)
      |> Enum.map(&to_string(&1.key))
      |> MapSet.new()

    assert view_rail_keys(role_html) == expected
  end

  test "channel resources match the real scoped listing and viewer intersection", ctx do
    {:ok, channel} =
      Chat.create_space(%{name: "View channel", slug: "view-#{System.unique_integer([:positive])}", kind: "channel", org_id: ctx.org.id})

    viewer = Scope.for_user(Accounts.get_user(ctx.root.id))
    {:ok, result} = ViewAs.compute(viewer, {:user, ctx.member.id})
    real = Chat.list_spaces(kind: "channel", scope: Scope.for_user(Accounts.get_user(ctx.member.id)))
    expected = Enum.filter(real, &Platform.Access.can?(viewer, "chat.read", &1))
    assert Enum.map(result.resources.channels, & &1.id) == Enum.map(expected, & &1.id)
    assert channel.id in Enum.map(expected, & &1.id)
  end

  test "unauthorized member is redirected", ctx do
    assert {:error, {:live_redirect, %{to: "/chat"}}} =
             conn_for(ctx.member) |> live("/access/view-as/user/#{ctx.root.id}")
  end

  test "project manager sees only the project shared with the target", ctx do
    n = System.unique_integer([:positive])

    {:ok, org} =
      Tenancy.create_org(ctx.root, %{name: "View tenant #{n}", slug: "view-tenant-#{n}"})

    manager = user!("View project manager")
    target = user!("View project target")
    assert {:ok, _} = Tenancy.mark_membership_external(%{user_id: manager.id, org_id: org.id})
    membership!(target, org, "member")
    {:ok, p} = Tasks.create_project(%{name: "Visible view project #{n}", org_id: org.id})
    {:ok, q} = Tasks.create_project(%{name: "Hidden view project #{n}", org_id: org.id})

    for permission <- ~w(access.manage tasks.read) do
      assert {:ok, _} =
               Grants.grant(%{principal: manager, permission: permission, resource: {:project, p.id}})
    end

    {:ok, result} =
      Scope.for_user(Accounts.get_user(manager.id)) |> ViewAs.compute({:user, target.id})

    assert Enum.map(result.resources.projects, & &1.id) == [p.id]
    refute q.id in Enum.map(result.resources.projects, & &1.id)
  end

  test "agent target is explicitly labelled uncapped", ctx do
    n = System.unique_integer([:positive])
    runtime_id = "view-as-runtime-#{n}"
    assert {:ok, _runtime} =
             Federation.register_runtime(ctx.member.id, %{
               runtime_id: runtime_id,
               display_name: "View runtime #{n}",
               allowed_bundles: []
             })

    {:ok, _view, html} = conn_for(ctx.root) |> live("/access/view-as/agent/#{runtime_id}")
    assert html =~ "not capped at owner (pos 5)"
  end
end
