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
    Repo.insert!(%User{
      name: name,
      email: "panel-#{n}@example.com",
      oidc_sub: "panel-#{n}",
      preferences: %{"first_run_goal" => "existing"}
    })
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

  test "reset consent names every removed allow and deny before any write", ctx do
    actor = Scope.for_user(ctx.root)
    {:ok, other} = Tasks.create_project(%{name: "Second reset project", org_id: ctx.org.id})

    {:ok, _} =
      Grants.grant(%{principal: ctx.member, permission: "tasks.manage", resource: ctx.project},
        actor: actor
      )

    {:ok, _} =
      Grants.grant(%{principal: ctx.member, permission: "tasks.manage", resource: other},
        actor: actor
      )

    {:ok, _} =
      Grants.deny(%{principal: ctx.member, permission: "tasks.write", resource: ctx.project},
        actor: actor
      )

    before = snapshot()
    count = Repo.aggregate(Change, :count)
    {:ok, view, _} = live(conn_for(ctx.root), "/access/user/#{ctx.member.id}")
    view |> element("button[phx-click=reset]") |> render_click()
    card = view |> element("#reset-card") |> render()
    assert card =~ "Remove allow tasks.manage on Panel project for Panel member"
    assert card =~ "Remove allow tasks.manage on Second reset project for Panel member"
    assert card =~ "Remove deny tasks.write on Panel project for Panel member"
    assert snapshot() == before
    assert Repo.aggregate(Change, :count) == count
    view |> element("#reset-card button[phx-value-action=access_apply]") |> render_click()
    assert Repo.aggregate(Change, :count) == count + 1
    change = last_change()
    view |> element("[data-change-id='#{change.id}'] button") |> render_click()
    assert snapshot() == before
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

  # ── Module locks (task 01a14721 stage 3) ───────────────────────────────

  defp files_tile?(html), do: html =~ ~s(data-destination="files")

  test "an admin locks files from the panel; the member's rail drops it live; Undo restores",
       ctx do
    before = snapshot()
    {:ok, member_view, member_html} = live(conn_for(ctx.member), "/chat")
    # Positive control: the member's rail carries Files before the lock.
    assert files_tile?(member_html)

    {:ok, panel, _} = live(conn_for(ctx.root), "/access/user/#{ctx.member.id}")
    refute has_element?(panel, "[data-role=module-lock]")

    # A submit without choosing a module locks nothing.
    html = render_submit(panel, "lock-module", %{"module" => "", "org" => ctx.org.id})
    assert html =~ "choose_a_module"
    assert snapshot() == before

    panel
    |> form("#access-lock-form", %{"module" => "files", "org" => ctx.org.id})
    |> render_submit()

    assert has_element?(panel, "[data-source=Locked][data-module=files]", "Locked: Files")
    assert has_element?(panel, "[data-source=Locked] td", ctx.org.name)

    lock = last_change()
    assert lock.action == "deny"

    assert has_element?(
             panel,
             "[data-change-id='#{lock.id}']",
             "Locked Files module in #{ctx.org.name} for Panel member"
           )

    refute files_tile?(render(member_view))

    refute Platform.Access.module_access?(
             Scope.for_user(Accounts.get_user(ctx.member.id)),
             :files
           )

    panel |> element("[data-change-id='#{lock.id}'] button") |> render_click()

    refute has_element?(panel, "[data-role=module-lock]")
    undo = last_change()
    assert undo.action == "undo"

    assert has_element?(
             panel,
             "[data-change-id='#{undo.id}']",
             "Restored Files module in #{ctx.org.name} for Panel member (lock undone)"
           )

    assert files_tile?(render(member_view))
    assert snapshot() == before
  end

  test "the Unlock button on a Locked line revokes the lock through the ledger", ctx do
    {:ok, _} =
      Grants.deny(
        %{principal: ctx.member, permission: "skills", resource: {:module, ctx.org.id}},
        actor: Scope.for_user(ctx.root)
      )

    {:ok, panel, _} = live(conn_for(ctx.root), "/access/user/#{ctx.member.id}")
    assert has_element?(panel, "[data-source=Locked][data-module=skills]", "Locked: Skills")
    count = Repo.aggregate(Change, :count)

    panel
    |> element("[data-source=Locked][data-module=skills] button", "Unlock")
    |> render_click()

    refute has_element?(panel, "[data-source=Locked]")
    assert Repo.aggregate(Change, :count) == count + 1

    assert Platform.Access.module_access?(
             Scope.for_user(Accounts.get_user(ctx.member.id)),
             :skills
           )
  end

  test "a non-manager of the org is refused a lock by Delegation and nothing is written", ctx do
    org_id = Platform.TenancyFixtures.tenant_org_id("panel-lock")
    org = Tenancy.get_org(org_id)
    manager = user!("Project-only manager")
    membership!(manager, org, "member")
    subject = user!("Lock subject")
    membership!(subject, org, "member")
    {:ok, own} = Tasks.create_project(%{name: "Lock panel project", org_id: org.id})

    for permission <- ["access.manage", "tasks.read"] do
      {:ok, _} =
        Grants.grant(%{principal: manager, permission: permission, resource: own},
          actor: Scope.for_user(ctx.root)
        )
    end

    {:ok, _} =
      Grants.grant(%{principal: subject, permission: "tasks.read", resource: own},
        actor: Scope.for_user(ctx.root)
      )

    {:ok, view, _} = live(conn_for(manager), "/access/user/#{subject.id}")
    # The manager can inspect the subject (positive control) but is offered
    # no lock: they manage a project, not the org.
    assert has_element?(view, "#access-subject option[value='user:#{subject.id}']")
    refute has_element?(view, "#access-lock-form")

    before = snapshot()
    count = Repo.aggregate(Change, :count)

    html = render_submit(view, "lock-module", %{"module" => "files", "org" => org.id})

    assert html =~ "Access change refused"
    assert snapshot() == before
    assert Repo.aggregate(Change, :count) == count
    assert Platform.Access.module_access?(Scope.for_user(Accounts.get_user(subject.id)), :files)
  end

  # Found on dev-on-test_host: the root admin's `membership_org` admin rule names
  # only the root org, so a bare `can?(access.manage, sub_org)` is false for
  # them. They manage a sub-org through Delegation's root-admin bypass, and
  # the panel must show and offer that sub-org's locks.
  test "a root admin sees and sets a sub-org member's module locks", ctx do
    sub = Platform.TenancyFixtures.tenant_org_id("panel-sub-lock")
    org = Tenancy.get_org(sub)
    member = user!("Sub member")
    membership!(member, org, "member")

    {:ok, _} =
      Grants.deny(
        %{principal: member, permission: "inbox", resource: {:module, sub}},
        actor: Scope.for_user(ctx.root)
      )

    {:ok, panel, _} = live(conn_for(ctx.root), "/access/user/#{member.id}")
    assert has_element?(panel, "[data-source=Locked][data-module=inbox]", "Locked: Inbox")
    assert has_element?(panel, "[data-source=Locked] td", org.name)
    assert has_element?(panel, "#access-lock-org option[value='#{sub}']")
    refute has_element?(panel, "#access-lock-module option[value=inbox]")

    panel
    |> form("#access-lock-form", %{"module" => "files", "org" => sub})
    |> render_submit()

    assert has_element?(panel, "[data-source=Locked][data-module=files]", "Locked: Files")
    refute Platform.Access.module_access?(Scope.for_user(Accounts.get_user(member.id)), :files)
  end
end
