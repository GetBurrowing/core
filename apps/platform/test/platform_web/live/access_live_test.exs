defmodule PlatformWeb.AccessLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Platform.Access.{Change, Grant, Grants, Scope, ViewAs}
  alias Platform.{Accounts, Repo, Tasks, Tenancy}
  alias Platform.Accounts.User
  alias Platform.Tenancy.OrgMembership

  defp user!(name) do
    n = System.unique_integer([:positive])
    Repo.insert!(%User{name: name, email: "panel-#{n}@example.com", oidc_sub: "panel-#{n}"})
  end

  defp membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp conn_for(user), do: build_conn() |> init_test_session(current_user_id: user.id)
  defp snapshot, do: Repo.all(from(g in Grant, order_by: g.id)) |> Enum.map(&Grant.snapshot/1)
  defp last_change, do: Repo.one(from(c in Change, order_by: [desc: c.id], limit: 1))

  setup do
    org = Tenancy.get_org_by_slug!("acme")
    root = user!("Panel root")
    member = user!("Panel member")
    membership!(root, org, "admin")
    membership!(member, org, "member")
    {:ok, project} = Tasks.create_project(%{name: "Panel project", org_id: org.id})
    %{root: Accounts.get_user(root.id), member: member, org: org, project: project}
  end

  test "panel undo restores the full snapshot and refuses repeated undo", ctx do
    before = snapshot()

    {:ok, _} =
      Grants.grant(%{principal: ctx.member, permission: "tasks.read", resource: ctx.project},
        actor: Scope.for_user(ctx.root)
      )

    change = last_change()
    refute snapshot() == before
    {:ok, view, _} = live(conn_for(ctx.root), "/access/user/#{ctx.member.id}")
    view |> element("[data-change-id='#{change.id}'] button") |> render_click()
    assert snapshot() == before
    html = view |> element("[data-change-id='#{change.id}'] button") |> render_click()
    assert html =~ "already_undone"
    assert snapshot() == before
  end

  test "superseded undo refuses without modifying grants", ctx do
    attrs = %{principal: ctx.member, permission: "tasks.read", resource: ctx.project}
    {:ok, grant} = Grants.grant(attrs, actor: Scope.for_user(ctx.root))
    first = last_change()
    {:ok, _} = Grants.revoke(grant, actor: Scope.for_user(ctx.root))
    before = snapshot()
    {:ok, view, _} = live(conn_for(ctx.root), "/access/user/#{ctx.member.id}")
    html = view |> element("[data-change-id='#{first.id}'] button") |> render_click()
    assert html =~ "superseded"
    assert snapshot() == before
  end

  test "reset is previewed, commits once, and one undo restores the rows", ctx do
    {:ok, _} =
      Grants.grant(%{principal: ctx.member, permission: "tasks.read", resource: ctx.project},
        actor: Scope.for_user(ctx.root)
      )

    before = snapshot()
    count = Repo.aggregate(Change, :count)
    {:ok, view, _} = live(conn_for(ctx.root), "/access/user/#{ctx.member.id}")
    view |> element("button[phx-click=reset]") |> render_click()
    assert has_element?(view, "#reset-card")
    assert snapshot() == before
    assert Repo.aggregate(Change, :count) == count

    view |> element("#reset-card button[phx-value-action=access_apply]") |> render_click()

    assert Repo.aggregate(Change, :count) == count + 1
    refute snapshot() == before
    change = last_change()
    view |> element("[data-change-id='#{change.id}'] button") |> render_click()
    assert snapshot() == before
  end

  test "view-as uses the shared rail renderer", ctx do
    {:ok, expected} = ViewAs.compute(Scope.for_user(ctx.root), {:user, ctx.member.id})
    {:ok, view, _} = live(conn_for(ctx.root), "/access/user/#{ctx.member.id}")
    html = view |> element("input[type=checkbox][phx-click=view-as]") |> render_click()

    keys =
      html
      |> Floki.parse_document!()
      |> Floki.find("[data-role=view-as-rail] [data-destination]")
      |> Enum.flat_map(&Floki.attribute(&1, "data-destination"))

    assert MapSet.new(keys) ==
             MapSet.new(Enum.map(PlatformWeb.AccessViewAs.rail_keys(expected), &to_string/1))

    assert html =~ "Viewing as Panel member"
    assert has_element?(view, "input[type=checkbox][phx-click=view-as][checked]")
    view |> element("button[phx-click=view-as]", "Exit") |> render_click()
    assert has_element?(view, "input[type=checkbox][phx-click=view-as]:not([checked])")
    refute has_element?(view, "[data-role=view-as-rail]")
  end

  test "members are refused while the root positive control mounts", ctx do
    assert {:ok, _, _} = live(conn_for(ctx.root), "/access")

    assert {:error, {:redirect, %{to: "/access-denied?module=admin"}}} =
             live(conn_for(ctx.member), "/access")
  end

  test "effective lines agree with the authoritative permission evaluator", ctx do
    {:ok, _} =
      Grants.deny(%{principal: ctx.member, permission: "tasks.write", resource: ctx.project},
        actor: Scope.for_user(ctx.root)
      )

    viewer = Scope.for_user(ctx.root)
    {:ok, lines} = Platform.Access.Effective.lines(viewer, {:user, ctx.member.id})
    {:ok, subject} = Platform.Access.Effective.scope_for({:user, ctx.member.id})
    assert Enum.any?(lines, &(&1.source == "deny"))

    for line <- lines do
      target = {String.to_existing_atom(line.where.type), line.where.id}
      assert line.allowed == Platform.Access.can?(subject, line.permission, target)
    end

    {:ok, _, html} = live(conn_for(ctx.root), "/access/user/#{ctx.member.id}")
    assert html =~ ~s(data-source="deny")
  end

  test "external guests are refused by the panel gate", ctx do
    guest = user!("Panel guest")
    assert {:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: ctx.org.id})

    denied = conn_for(guest) |> get("/access")
    assert denied.status == 403
    assert denied.assigns.access_denied
    refute denied.resp_body =~ ~s(id="access-panel")
  end

  test "a capped runtime names its owner and reset lists owned runtimes", ctx do
    owner = user!("Capped owner")
    assert {:ok, _} = Tenancy.mark_membership_external(%{user_id: owner.id, org_id: ctx.org.id})

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        name: "Panel assistant",
        slug: "panel-agent-#{System.unique_integer([:positive])}"
      })

    runtime =
      Platform.RuntimeProfileFixtures.runtime!(
        owner.id,
        ["task"],
        %{agent_id: agent.id, display_name: "Panel assistant"},
        nil
      )

    {:ok, _} =
      Grants.grant(
        %{principal: {:agent, agent.id}, permission: "tasks.write", resource: ctx.project},
        actor: Scope.for_user(ctx.root)
      )

    {:ok, agent_view, html} = live(conn_for(ctx.root), "/access/agent/#{runtime.id}")
    assert html =~ ~s(data-source="capped")
    assert html =~ "Capped owner"
    assert has_element?(agent_view, "[data-source=capped][data-allowed=false]")

    {:ok, _} =
      Grants.grant(%{principal: owner, permission: "tasks.read", resource: ctx.project},
        actor: Scope.for_user(ctx.root)
      )

    before = snapshot()
    count = Repo.aggregate(Change, :count)
    {:ok, view, _} = live(conn_for(ctx.root), "/access/user/#{owner.id}")
    view |> element("button[phx-click=reset]") |> render_click()
    card = view |> element("#reset-card") |> render()
    assert card =~ "Capped owner"
    assert card =~ "Panel assistant"
    assert snapshot() == before

    view |> element("#reset-card button[phx-value-action=access_apply]") |> render_click()

    assert Repo.aggregate(Change, :count) == count + 1
    change = last_change()
    view |> element("[data-change-id='#{change.id}'] button") |> render_click()
    assert snapshot() == before
  end

  test "project-only manager sees related subjects and only managed change rows", ctx do
    org_id = Platform.TenancyFixtures.tenant_org_id("panel-scope")
    org = Tenancy.get_org(org_id)
    manager = user!("Scoped manager")
    membership!(manager, org, "member")
    included = user!("Included guest")
    excluded = user!("Excluded guest")

    for user <- [included, excluded] do
      assert {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
    end

    {:ok, own} = Tasks.create_project(%{name: "Managed panel project", org_id: org.id})
    {:ok, other} = Tasks.create_project(%{name: "Other panel project", org_id: org.id})

    for permission <- ["access.manage", "tasks.read"] do
      {:ok, _} =
        Grants.grant(%{principal: manager, permission: permission, resource: own},
          actor: Scope.for_user(ctx.root)
        )
    end

    {:ok, _} =
      Grants.grant(%{principal: included, permission: "tasks.read", resource: own},
        actor: Scope.for_user(ctx.root)
      )

    included_change = last_change()

    {:ok, _} =
      Grants.grant(%{principal: excluded, permission: "tasks.read", resource: other},
        actor: Scope.for_user(ctx.root)
      )

    excluded_change = last_change()
    {:ok, view, _} = live(conn_for(manager), "/access/user/#{included.id}")
    assert has_element?(view, "#access-subject option[value='user:#{included.id}']")
    refute has_element?(view, "#access-subject option[value='user:#{excluded.id}']")
    assert has_element?(view, "[data-change-id='#{included_change.id}']")
    refute has_element?(view, "[data-change-id='#{excluded_change.id}']")
  end

  test "changed grants make a reset preview stale without another ledger row", ctx do
    attrs = %{principal: ctx.member, permission: "tasks.read", resource: ctx.project}
    {:ok, grant} = Grants.grant(attrs, actor: Scope.for_user(ctx.root))
    {:ok, view, _} = live(conn_for(ctx.root), "/access/user/#{ctx.member.id}")
    view |> element("button[phx-click=reset]") |> render_click()
    {:ok, _} = Grants.revoke(grant, actor: Scope.for_user(ctx.root))
    before = snapshot()
    count = Repo.aggregate(Change, :count)

    html =
      view |> element("#reset-card button[phx-value-action=access_apply]") |> render_click()

    assert html =~ "stale"
    assert snapshot() == before
    assert Repo.aggregate(Change, :count) == count
  end

  test "a card action without a reset preview cannot write", ctx do
    {:ok, view, _} = live(conn_for(ctx.root), "/access/user/#{ctx.member.id}")
    before = snapshot()
    count = Repo.aggregate(Change, :count)

    render_click(view, "canvas_action_click", %{
      "action" => "access_apply",
      "canvas-id" => "lookalike"
    })

    assert snapshot() == before
    assert Repo.aggregate(Change, :count) == count
    render_click(view, "canvas_action_click", %{"action" => "unknown"})
    assert snapshot() == before
    assert Repo.aggregate(Change, :count) == count
  end
end
