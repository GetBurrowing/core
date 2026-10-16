defmodule Platform.Access.AgentAccessAcceptanceTest do
  @moduledoc """
  Five agent-first access acceptance lines. Ground truth enumerates the database
  directly and uses fresh scopes; it does not reuse Impact's candidate list,
  proposal impact, Effective sources, or the card builder to predict losses.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Change, Grant, Grants, Proposal, Scope, ViewAs}
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.{Chat, Repo, Tasks}
  alias Platform.Tenancy.OrgMembership

  setup do
    org = acme_org_id()
    root = user!("root")
    member!(root, org, "admin")
    guest = user!("guest")
    member!(guest, org, "guest")
    {:ok, p} = Tasks.create_project(%{name: "acceptance-p-#{uniq()}", org_id: org})
    {:ok, q} = Tasks.create_project(%{name: "acceptance-q-#{uniq()}", org_id: org})
    {:ok, grant} = Grants.grant(%{principal: guest, permission: "tasks.read", resource: p})
    first_change = last_change()

    {runtime, token} =
      runtime!(root, ~w(federation space context_read messaging canvas task access))

    {guest_runtime, _} = runtime!(guest, ["task", "messaging"])

    {:ok, space} =
      Chat.create_space(%{
        name: "acceptance-#{uniq()}",
        slug: "acceptance-#{uniq()}",
        kind: "channel",
        org_id: org
      })

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_id: root.id,
        participant_type: "user",
        joined_at: DateTime.utc_now()
      })

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_id: runtime.agent_id,
        participant_type: "agent",
        joined_at: DateTime.utc_now()
      })

    %{
      org: org,
      root: root,
      guest: guest,
      p: p,
      q: q,
      grant: grant,
      first_change: first_change,
      runtime: runtime,
      guest_runtime: guest_runtime,
      token: token,
      space: space
    }
  end

  describe "an agent cannot apply a change without a human click" do
    test "MCP proposal, status, patch and undo write nothing; human Apply writes once", ctx do
      baseline = counts()
      proposal = propose!(ctx, [deny_user(ctx.guest, "tasks.read", :project, ctx.p.id)])
      status = tool!(ctx.token, "access_apply", %{"proposal_id" => proposal["proposal_id"]})
      assert status["state"] == "awaiting_human_approval"
      canvas = Repo.get!(Chat.Canvas, proposal["canvas_id"])

      assert {:ok, _} =
               Chat.patch_canvas({:agent, ctx.runtime.agent_id}, canvas, [
                 {:append_child, "root",
                  %{
                    "id" => "agent-edit",
                    "type" => "text",
                    "props" => %{"value" => "Changed card"},
                    "children" => []
                  }}
               ])

      undo =
        tool!(ctx.token, "access_undo", %{
          "change_id" => ctx.first_change.id,
          "space_id" => ctx.space.id
        })

      assert Repo.get!(Proposal, undo["proposal_id"]).kind == "undo"
      assert counts() == baseline
      view = chat!(ctx.root, ctx.space)
      apply_card(view, proposal)
      assert flash(view)["error"] =~ "card changed"
      assert counts() == baseline

      fresh = propose!(ctx, [deny_user(ctx.guest, "tasks.read", :project, ctx.p.id)])
      apply_card(view, fresh)
      assert Repo.aggregate(Change, :count) == elem(baseline, 1) + 1
      change = last_change()
      assert change.actor_type == "user"
      assert change.actor_id == ctx.root.id
      assert change.via_agent_id == ctx.runtime.id
      assert Repo.get!(Proposal, fresh["proposal_id"]).change_id == change.id

      assert tool!(ctx.token, "access_apply", %{"proposal_id" => fresh["proposal_id"]})["state"] ==
               "applied"

      apply_card(view, fresh)
      assert flash(view)["error"] =~ "already applied"
      assert Repo.aggregate(Change, :count) == elem(baseline, 1) + 1
    end
  end

  describe "access_explain matches view-as" do
    test "every person, runtime and role pair matches real project and channel lists, including allow plus deny",
         ctx do
      # The subject holds a user allow and a role deny simultaneously. An
      # implementation that notices any allow without evaluating precedence
      # cannot pass this negative control.
      {:ok, _} = Grants.grant(%{principal: ctx.guest, permission: "tasks.read", resource: ctx.q})

      {:ok, _} =
        Grants.deny(%{principal: {:role, "guest"}, permission: "tasks.read", resource: ctx.q})

      {:ok, _} =
        Chat.add_participant(ctx.space.id, %{
          participant_id: ctx.guest.id,
          participant_type: "user",
          joined_at: DateTime.utc_now()
        })

      targets = [
        {%{"type" => "user", "id" => ctx.root.id}, {:user, ctx.root.id}},
        {%{"type" => "user", "id" => ctx.guest.id}, {:user, ctx.guest.id}},
        {%{"type" => "agent", "id" => ctx.guest_runtime.id}, {:agent, ctx.guest_runtime.id}},
        {%{"type" => "role", "id" => "member", "org_id" => ctx.org}, {:role, ctx.org, "member"}}
      ]

      resources = [
        {"project", ctx.p.id, :projects},
        {"project", ctx.q.id, :projects},
        {"space", ctx.space.id, :channels}
      ]

      results =
        for {encoded, target} <- targets, {type, id, group} <- resources do
          {:ok, view} = ViewAs.compute(Scope.for_runtime(ctx.runtime), target)
          expected = Enum.any?(Map.fetch!(view.resources, group), &(&1.id == id))

          actual =
            tool!(ctx.token, "access_explain", %{
              "target" => encoded,
              "resource" => %{"type" => type, "id" => id}
            })

          assert actual["allowed"] == expected,
                 "explain mismatch for #{inspect(target)} / #{type}:#{id}"

          assert actual["in_view_as"] == expected
          {target, id, actual["allowed"]}
        end

      assert {{:user, ctx.guest.id}, ctx.p.id, true} in results
      assert {{:user, ctx.guest.id}, ctx.q.id, false} in results
    end
  end

  describe "undo from the panel restores prior state" do
    test "panel undo restores every grant snapshot column and refuses a repeated undo", ctx do
      before = snapshots()
      card = propose!(ctx, [deny_user(ctx.guest, "tasks.read", :project, ctx.p.id)])
      chat = chat!(ctx.root, ctx.space)
      apply_card(chat, card)
      refute snapshots() == before
      change = last_change()
      {:ok, panel, _} = live(conn_for(ctx.root), "/access/user/#{ctx.guest.id}")
      panel |> element("[data-change-id='#{change.id}'] button[phx-click=undo]") |> render_click()
      assert snapshots() == before
      count = Repo.aggregate(Change, :count)
      panel |> element("[data-change-id='#{change.id}'] button[phx-click=undo]") |> render_click()
      assert snapshots() == before
      assert Repo.aggregate(Change, :count) == count
    end
  end

  describe "stale proposals are refused" do
    test "a changed grant row refuses the old card and a fresh proposal succeeds", ctx do
      old = propose!(ctx, [%{"action" => "revoke", "id" => ctx.grant.id}])
      assert {:ok, _} = Grants.revoke(ctx.grant)
      baseline = counts()
      view = chat!(ctx.root, ctx.space)
      apply_card(view, old)
      assert flash(view)["error"] =~ "stale"
      assert Repo.get!(Proposal, old["proposal_id"]).state == "stale"
      assert counts() == baseline
      fresh = propose!(ctx, [deny_user(ctx.guest, "tasks.read", :project, ctx.p.id)])
      apply_card(view, fresh)
      assert Repo.get!(Proposal, fresh["proposal_id"]).state == "applied"
      assert Repo.aggregate(Change, :count) == elem(baseline, 1) + 1
    end

    test "a newly joined member invalidates the loss list, while a recomputed card succeeds",
         ctx do
      op = %{
        "action" => "deny",
        "principal" => ["role", "member"],
        "permission" => "chat.read",
        "resource" => ["space", ctx.space.id]
      }

      old = propose!(ctx, [op])
      newcomer = user!("new-member")
      member!(newcomer, ctx.org, "member")

      {:ok, _} =
        Chat.add_participant(ctx.space.id, %{
          participant_type: "user",
          joined_at: DateTime.utc_now(),
          participant_id: newcomer.id
        })

      baseline = counts()
      view = chat!(ctx.root, ctx.space)
      apply_card(view, old)
      assert Repo.get!(Proposal, old["proposal_id"]).state == "stale"
      assert counts() == baseline
      fresh = propose!(ctx, [op])

      assert newcomer.id in document_principals(
               Repo.get!(Chat.Canvas, fresh["canvas_id"]).document
             )

      apply_card(view, fresh)
      assert Repo.get!(Proposal, fresh["proposal_id"]).state == "applied"
      assert Repo.aggregate(Change, :count) == elem(baseline, 1) + 1
    end
  end

  describe "the removal list names every person and agent who loses access" do
    test "rendered names equal exhaustive can? ground truth, including a cross-org grantee and guest's runtime",
         ctx do
      internal = user!("internal")
      member!(internal, ctx.org, "member")
      {internal_runtime, _} = runtime!(internal, ["messaging"])
      cross = user!("cross-org")
      member!(cross, tenant_org_id("acceptance-other"), "guest")
      {cross_runtime, _} = runtime!(cross, ["messaging"])
      {:ok, _} = Grants.grant(%{principal: cross, permission: "chat.read", resource: ctx.space})

      for user <- [ctx.guest, internal] do
        {:ok, _} =
          Chat.add_participant(ctx.space.id, %{
            participant_id: user.id,
            participant_type: "user",
            joined_at: DateTime.utc_now()
          })
      end

      resource = {:space, ctx.space.id}
      before = ground_truth("chat.read", resource)

      for principal <- [
            {"user", internal.id},
            {"agent", internal_runtime.id},
            {"user", cross.id},
            {"agent", cross_runtime.id},
            {"user", ctx.guest.id},
            {"agent", ctx.guest_runtime.id}
          ] do
        assert before[principal], "positive control missing #{inspect(principal)}"
      end

      ops =
        for principal <- [["role", "member"], ["role", "guest"], ["user", cross.id]] do
          %{
            "action" => "deny",
            "principal" => principal,
            "permission" => "chat.read",
            "resource" => ["space", ctx.space.id]
          }
        end

      card = propose!(ctx, ops)
      view = chat!(ctx.root, ctx.space)
      render_click(view, "canvas_open", %{"canvas-id" => card["canvas_id"]})
      html = render(view)

      rendered =
        html
        |> Floki.parse_document!()
        |> Floki.find("[data-principal-id]")
        |> Enum.flat_map(&Floki.attribute(&1, "data-principal-id"))
        |> MapSet.new()

      apply_card(view, card)
      assert Repo.get!(Proposal, card["proposal_id"]).state == "applied"
      after_state = ground_truth("chat.read", resource)

      expected =
        before
        |> Enum.filter(fn {principal, allowed} ->
          allowed and not Map.fetch!(after_state, principal)
        end)
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new()

      assert MapSet.size(expected) > 0
      assert rendered == MapSet.new(expected, &elem(&1, 1))
      assert MapSet.member?(expected, {"agent", cross_runtime.id})
      assert MapSet.member?(expected, {"agent", ctx.guest_runtime.id})
      refute MapSet.member?(expected, {"user", ctx.root.id})
      refute MapSet.member?(expected, {"agent", ctx.runtime.id})

      for {type, id} <- expected do
        name =
          if type == "user",
            do: Repo.get!(User, id).name,
            else:
              Repo.get!(AgentRuntime, id).display_name || Repo.get!(AgentRuntime, id).runtime_id

        assert html =~ name
      end
    end
  end

  defp ground_truth(permission, resource) do
    people =
      for user <- Repo.all(User),
          do: {{"user", user.id}, Access.can?(Scope.for_user(user), permission, resource)}

    agents =
      for runtime <- Repo.all(AgentRuntime),
          do:
            {{"agent", runtime.id}, Access.can?(Scope.for_runtime(runtime), permission, resource)}

    Map.new(people ++ agents)
  end

  defp document_principals(%{"root" => root}), do: node_principals(root)

  defp node_principals(node),
    do:
      List.wrap(get_in(node, ["props", "principal_id"])) ++
        Enum.flat_map(node["children"] || [], &node_principals/1)

  defp deny_user(user, permission, type, id),
    do: %{
      "action" => "deny",
      "principal" => ["user", user.id],
      "permission" => permission,
      "resource" => [Atom.to_string(type), id]
    }

  defp propose!(ctx, ops),
    do:
      tool!(ctx.token, "access_propose", %{
        "space_id" => ctx.space.id,
        "options" => [%{"ops" => ops}]
      })

  defp tool!(token, name, args) do
    response =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => args}
      })
      |> json_response(200)

    assert %{"result" => %{"isError" => false, "content" => [%{"text" => json} | _]}} = response
    Jason.decode!(json)
  end

  defp conn_for(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp chat!(user, space) do
    {:ok, view, _} = live(conn_for(user), "/chat/#{space.id}")
    view
  end

  defp apply_card(view, card),
    do:
      render_click(view, "canvas_action_click", %{
        "canvas-id" => card["canvas_id"],
        "node-id" => "actions",
        "action" => "access_apply"
      })

  defp flash(view), do: :sys.get_state(view.pid).socket.assigns.flash
  defp snapshots, do: Repo.all(from(g in Grant, order_by: g.id)) |> Enum.map(&Grant.snapshot/1)

  defp counts,
    do:
      {Repo.aggregate(Grant, :count), Repo.aggregate(Change, :count),
       Repo.aggregate(Platform.Audit.Event, :count)}

  defp last_change, do: Repo.one!(from(c in Change, order_by: [desc: c.id], limit: 1))

  defp runtime!(owner, modules) do
    agent = Repo.insert!(%Agent{name: "Acceptance agent", slug: "acceptance-agent-#{uniq()}"})
    token = AgentRuntime.generate_token()

    runtime =
      Platform.RuntimeProfileFixtures.runtime!(
        owner.id,
        modules,
        %{agent_id: agent.id, auth_token_hash: AgentRuntime.hash_token(token), status: "active"},
        nil
      )

    {runtime, token}
  end

  defp member!(user, org_id, role),
    do:
      Repo.insert!(%OrgMembership{
        user_id: user.id,
        org_id: org_id,
        role: if(role == "guest", do: "member", else: role),
        external: role == "guest"
      })

  defp uniq, do: System.unique_integer([:positive])

  defp user!(tag) do
    n = uniq()

    Repo.insert!(%User{
      name: "Acceptance #{tag} #{n}",
      email: "acceptance-#{n}@example.com",
      oidc_sub: "acceptance-#{n}"
    })
  end
end
