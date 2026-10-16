defmodule PlatformWeb.AccessChangeCardLiveTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Platform.Access.{Change, Grant, Grants, Impact, Proposal, Proposals, Scope}
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.{Accounts, Chat, Repo, Tasks}
  alias Platform.Tenancy.OrgMembership

  setup do
    org = acme_org_id()
    admin = user!("admin")
    membership = Repo.insert!(%OrgMembership{user_id: admin.id, org_id: org, role: "admin"})
    target = user!("target")
    Repo.insert!(%OrgMembership{user_id: target.id, org_id: org, role: "member", external: true})
    {:ok, project} = Tasks.create_project(%{name: "access-card-#{uniq()}", org_id: org})
    agent = Repo.insert!(%Agent{name: "Access agent", slug: "access-card-#{uniq()}"})

    runtime =
      Platform.RuntimeProfileFixtures.runtime!(
        admin.id,
        ["task", "canvas"],
        %{agent_id: agent.id},
        nil
      )

    for permission <- ["access.manage", "tasks.read"] do
      {:ok, _} = Grants.grant(%{principal: runtime, permission: permission, resource: project})
    end

    {:ok, space} =
      Chat.create_space(%{
        name: "access-card-#{uniq()}",
        slug: "access-card-#{uniq()}",
        kind: "channel",
        org_id: org
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{participant_type: "user", participant_id: admin.id})

    {:ok, agent_participant} =
      Chat.add_participant(space.id, %{participant_type: "agent", participant_id: agent.id})

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Access change"
      })

    %{
      admin: admin,
      target: target,
      runtime: runtime,
      space: space,
      canvas: canvas,
      membership: membership,
      participant: participant,
      agent_participant: agent_participant,
      project: project,
      ops: [
        %{
          action: "grant",
          principal: {:user, target.id},
          permission: "tasks.read",
          resource: {:project, project.id}
        }
      ]
    }
  end

  test "admin click commits once with human and runtime provenance across two sessions", ctx do
    proposal!(ctx)
    view = mount!(ctx.admin, ctx.space)
    other = mount!(ctx.admin, ctx.space)
    baseline = Repo.aggregate(Change, :count)
    click(view, ctx.canvas, "access_apply")
    assert Repo.aggregate(Change, :count) == baseline + 1
    change = Repo.one!(from(c in Change, order_by: [desc: c.id], limit: 1))
    assert change.actor_type == "user"
    assert change.actor_id == ctx.admin.id
    assert change.via_agent_id == ctx.runtime.id
    click(view, ctx.canvas, "access_apply")
    assert flash(view)["error"] =~ "already applied"
    click(other, ctx.canvas, "access_apply")
    assert flash(other)["error"] =~ "already applied"
    assert Repo.aggregate(Change, :count) == baseline + 1
  end

  test "cancel writes no grant or ledger row", ctx do
    proposal = proposal!(ctx)
    baseline = snapshot()
    count = Repo.aggregate(Change, :count)
    view = mount!(ctx.admin, ctx.space)
    click(view, ctx.canvas, "access_cancel")
    assert Repo.get!(Proposal, proposal.id).state == "cancelled"
    assert snapshot() == baseline
    assert Repo.aggregate(Change, :count) == count
  end

  test "a choice is required and then the selected option can apply", ctx do
    proposal!(ctx,
      options: [
        %{key: "one", label: "One", ops: ctx.ops},
        %{key: "two", label: "Two", ops: ctx.ops}
      ]
    )

    baseline = Repo.aggregate(Change, :count)
    view = mount!(ctx.admin, ctx.space)
    click(view, ctx.canvas, "access_apply")
    assert flash(view)["error"] =~ "Choose an option"
    assert Repo.aggregate(Change, :count) == baseline
    click(view, ctx.canvas, "access_choose:two")
    click(view, ctx.canvas, "access_apply")
    assert Repo.aggregate(Change, :count) == baseline + 1
  end

  test "fresh scope refuses a demoted admin even after mounting", ctx do
    proposal!(ctx)
    view = mount!(ctx.admin, ctx.space)
    Repo.update!(Ecto.Changeset.change(ctx.membership, role: "member"))
    baseline = Repo.aggregate(Change, :count)
    click(view, ctx.canvas, "access_apply")
    assert flash(view)["error"] =~ "access.manage"
    assert Repo.aggregate(Change, :count) == baseline
  end

  test "member without access.manage cannot apply", ctx do
    proposal!(ctx)
    member = user!("member")
    Repo.insert!(%OrgMembership{user_id: member.id, org_id: acme_org_id(), role: "member"})

    {:ok, _} =
      Chat.add_participant(ctx.space.id, %{participant_type: "user", participant_id: member.id})

    baseline = Repo.aggregate(Change, :count)
    view = mount!(member, ctx.space)
    click(view, ctx.canvas, "access_apply")
    assert flash(view)["error"] =~ "access.manage"
    assert Repo.aggregate(Change, :count) == baseline
  end

  test "lookalike canvas cannot use a real proposal id from the event payload", ctx do
    proposal = proposal!(ctx)
    real = Repo.get!(Chat.Canvas, ctx.canvas.id)

    {:ok, lookalike} =
      Chat.create_canvas(%{
        "space_id" => ctx.space.id,
        "created_by" => ctx.agent_participant.id,
        "title" => "Lookalike",
        "document" => real.document
      })

    baseline = snapshot()
    count = Repo.aggregate(Change, :count)
    view = mount!(ctx.admin, ctx.space)

    render_click(view, "canvas_action_click", %{
      "node-id" => "actions",
      "canvas-id" => lookalike.id,
      "action" => "access_apply",
      "proposal_id" => proposal.id
    })

    assert flash(view)["error"] =~ "not a live access change"
    assert snapshot() == baseline
    assert Repo.aggregate(Change, :count) == count
  end

  test "agent patch invalidates consent and leaves grants untouched", ctx do
    proposal!(ctx)
    canvas = Repo.get!(Chat.Canvas, ctx.canvas.id)

    assert {:ok, _} =
             Chat.patch_canvas({:agent, ctx.runtime.agent_id}, canvas, [
               {:append_child, "root",
                %{
                  "id" => "tampered",
                  "type" => "text",
                  "props" => %{"value" => "Different consent"},
                  "children" => []
                }}
             ])

    baseline = snapshot()
    count = Repo.aggregate(Change, :count)
    view = mount!(ctx.admin, ctx.space)
    click(view, ctx.canvas, "access_apply")
    assert flash(view)["error"] =~ "card changed"
    assert snapshot() == baseline
    assert Repo.aggregate(Change, :count) == count
  end

  test "undo restores the exact grant snapshots", ctx do
    proposal!(ctx)
    baseline = snapshot()
    view = mount!(ctx.admin, ctx.space)
    click(view, ctx.canvas, "access_apply")
    refute snapshot() == baseline
    click(view, ctx.canvas, "access_undo")
    assert snapshot() == baseline
  end

  test "the removal card includes every impacted person and runtime id", ctx do
    runtime = Platform.RuntimeProfileFixtures.runtime!(ctx.target.id, ["task"], %{}, nil)

    {:ok, grant} =
      Grants.grant(%{principal: ctx.target, permission: "tasks.read", resource: ctx.project})

    ctx = %{ctx | ops: [%{action: "revoke", id: grant.id}]}
    assert {:ok, impact} = Impact.diff(Scope.for_user(Accounts.get_user(ctx.admin.id)), ctx.ops)
    assert Enum.any?(impact.loses, &(&1.id == runtime.id))
    proposal!(ctx)
    view = mount!(ctx.admin, ctx.space)
    render_click(view, "canvas_open", %{"canvas-id" => ctx.canvas.id})
    html = render(view)

    for principal <- impact.loses do
      assert html =~ ~s(data-principal-id="#{principal.id}")
      assert html =~ principal.name
    end
  end

  test "action_row disabled is optional and a disabled item renders disabled" do
    render = fn actions ->
      render_component(&Platform.Chat.Canvas.Kinds.ActionRow.render/1,
        node: %{"id" => "actions", "props" => %{"actions" => actions}},
        canvas_id: "canvas"
      )
    end

    action = %{"label" => "Apply", "value" => "access_apply", "variant" => "primary"}
    html = render.([action])
    refute html =~ " disabled"
    assert html == render.([Map.put(action, "disabled", false)])
    assert render.([Map.put(action, "disabled", true)]) =~ " disabled"
  end

  defp proposal!(ctx, attrs \\ []) do
    attrs =
      Map.merge(%{space_id: ctx.space.id, canvas_id: ctx.canvas.id, ops: ctx.ops}, Map.new(attrs))

    {:ok, proposal} = Proposals.propose(ctx.runtime, attrs)
    proposal
  end

  defp mount!(user, space) do
    conn = build_conn() |> init_test_session(current_user_id: user.id)
    {:ok, view, _} = live(conn, "/chat/#{space.id}")
    view
  end

  defp click(view, canvas, action),
    do:
      render_click(view, "canvas_action_click", %{
        "node-id" => "actions",
        "canvas-id" => canvas.id,
        "action" => action
      })

  defp flash(view), do: :sys.get_state(view.pid).socket.assigns.flash
  defp snapshot, do: Repo.all(from(g in Grant, order_by: g.id)) |> Enum.map(&Grant.snapshot/1)
  defp uniq, do: System.unique_integer([:positive])

  defp user!(tag) do
    n = uniq()

    Repo.insert!(%User{
      name: "Card #{tag} #{n}",
      email: "access-card-#{n}@example.com",
      oidc_sub: "access-card-#{n}"
    })
  end
end
