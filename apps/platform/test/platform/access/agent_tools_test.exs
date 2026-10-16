defmodule Platform.Access.AgentToolsTest do
  @moduledoc """
  MCP acceptance for human consent. The no-back-door source check is syntactic:
  it detects direct Proposals.apply calls, not dynamically constructed calls.
  Runtime write-count assertions independently cover the MCP apply/undo paths.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Platform.Access.{
    Change,
    Grant,
    Grants,
    Proposal,
    Proposals,
    RuntimeProfile,
    Scope,
    ViewAs
  }

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.{Accounts, Chat, Repo, Tasks}
  alias Platform.Tenancy.OrgMembership

  @access_tools ~w(access_explain access_propose access_apply access_undo)
  @guest_tools ~w(send_media react space_list space_get_context space_get_messages space_search_messages)

  setup do
    org = acme_org_id()
    root = user!("root")
    Repo.insert!(%OrgMembership{user_id: root.id, org_id: org, role: "admin"})
    guest = user!("guest")
    Repo.insert!(%OrgMembership{user_id: guest.id, org_id: org, role: "member", external: true})
    {:ok, p} = Tasks.create_project(%{name: "access-mcp-p-#{uniq()}", org_id: org})
    {:ok, q} = Tasks.create_project(%{name: "access-mcp-q-#{uniq()}", org_id: org})
    {:ok, _} = Grants.grant(%{principal: guest, permission: "tasks.read", resource: p})

    {runtime, token} =
      runtime!(root, ~w(federation space context_read messaging canvas task access))

    {guest_runtime, _} = runtime!(guest, ["task"])

    {:ok, space} =
      Chat.create_space(%{
        name: "access-mcp-#{uniq()}",
        slug: "access-mcp-#{uniq()}",
        kind: "channel",
        org_id: org
      })

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_id: root.id,
        participant_type: "user",
        joined_at: DateTime.utc_now()
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_id: runtime.agent_id,
        participant_type: "agent",
        joined_at: DateTime.utc_now()
      })

    %{
      root: root,
      guest: guest,
      runtime: runtime,
      guest_runtime: guest_runtime,
      token: token,
      p: p,
      q: q,
      space: space,
      participant: participant,
      org: org
    }
  end

  test "explain agrees with real ViewAs for people, runtimes and the member role", ctx do
    viewer = Scope.for_runtime(ctx.runtime)

    targets = [
      {%{"type" => "user", "id" => ctx.root.id}, {:user, ctx.root.id}},
      {%{"type" => "user", "id" => ctx.guest.id}, {:user, ctx.guest.id}},
      {%{"type" => "agent", "id" => ctx.guest_runtime.id}, {:agent, ctx.guest_runtime.id}},
      {%{"type" => "role", "id" => "member", "org_id" => ctx.org}, {:role, ctx.org, "member"}}
    ]

    for {encoded, target} <- targets, project <- [ctx.p, ctx.q] do
      assert {:ok, view} = ViewAs.compute(viewer, target)

      actual =
        ok_call(ctx.token, "access_explain", %{
          "target" => encoded,
          "resource" => %{"type" => "project", "id" => project.id}
        })

      in_view = Enum.any?(view.resources.projects, &(&1.id == project.id))
      assert actual["allowed"] == in_view
      assert actual["in_view_as"] == in_view
    end
  end

  test "capped explain names the owner and refuses the missing write permission", ctx do
    actual =
      ok_call(ctx.token, "access_explain", %{
        "target" => %{"type" => "agent", "id" => ctx.guest_runtime.id},
        "resource" => %{"type" => "project", "id" => ctx.p.id},
        "permission" => "tasks.write"
      })

    refute actual["allowed"]

    assert {:ok, view} =
             ViewAs.compute(Scope.for_runtime(ctx.runtime), {:agent, ctx.guest_runtime.id})

    assert actual["in_view_as"] == Enum.any?(view.resources.projects, &(&1.id == ctx.p.id))

    assert Enum.any?(
             actual["sources"],
             &(&1["source"] == "capped" and &1["note"] =~ ctx.guest.name)
           )
  end

  test "missing resources and resources unreadable to the calling runtime are not_found", ctx do
    missing =
      call(ctx.token, "access_explain", %{
        "target" => %{"type" => "user", "id" => ctx.root.id},
        "resource" => %{"type" => "project", "id" => Ecto.UUID.generate()}
      })

    assert Jason.encode!(missing) =~ "not_found"
    {:ok, _} = Grants.deny(%{principal: ctx.root, permission: "tasks.read", resource: ctx.q})

    hidden =
      call(ctx.token, "access_explain", %{
        "target" => %{"type" => "user", "id" => ctx.guest.id},
        "resource" => %{"type" => "project", "id" => ctx.q.id}
      })

    assert Jason.encode!(hidden) =~ "not_found"
  end

  test "propose posts one canvas message, binds its digest, and apply only reads status", ctx do
    before = counts()
    audits = audit_types()
    messages = Repo.aggregate(Chat.Message, :count)
    card = propose!(ctx)
    assert Repo.aggregate(Chat.Message, :count) == messages + 1
    row = Repo.get!(Proposal, card["proposal_id"])
    canvas = Repo.get!(Chat.Canvas, card["canvas_id"])
    assert row.card_digest == Proposals.digest(canvas.document)
    assert row.canvas_id == canvas.id
    assert counts() == before
    assert audit_types() == Enum.sort(audits ++ card_audits())
    status_audits = audit_types()

    for _ <- 1..2 do
      status = ok_call(ctx.token, "access_apply", %{"proposal_id" => row.id})
      assert status["state"] == "awaiting_human_approval"
      assert status["change_id"] == nil
      assert counts() == before
      assert audit_types() == status_audits
    end
  end

  test "an agent's canvas patch cannot approve its access proposal", ctx do
    card = propose!(ctx)
    canvas = Repo.get!(Chat.Canvas, card["canvas_id"])

    assert {:ok, _} =
             Chat.patch_canvas({:agent, ctx.runtime.agent_id}, canvas, [
               {:append_child, "root",
                %{
                  "id" => "tamper",
                  "type" => "text",
                  "props" => %{"value" => "Changed consent"},
                  "children" => []
                }}
             ])

    before = counts()
    audits = audit_types()

    assert {:error, :card_changed} =
             Proposals.apply(card["proposal_id"], Scope.for_user(Accounts.get_user(ctx.root.id)))

    assert counts() == before
    assert audit_types() == Enum.sort(audits ++ ["chat.canvas.updated"])
  end

  test "undo creates a consent card and commits nothing", ctx do
    {:ok, _} = Grants.deny(%{principal: ctx.guest, permission: "tasks.write", resource: ctx.q})
    change = Repo.one!(from(c in Change, order_by: [desc: c.id], limit: 1))
    before = counts()
    audits = audit_types()

    response =
      ok_call(ctx.token, "access_undo", %{"change_id" => change.id, "space_id" => ctx.space.id})

    row = Repo.get!(Proposal, response["proposal_id"])
    assert row.kind == "undo"
    assert row.undoes_change_id == change.id
    assert hd(row.options)["label"] =~ "tasks.write"
    assert hd(row.options)["label"] =~ ctx.q.name
    assert hd(row.options)["label"] =~ ctx.guest.name
    assert counts() == before
    assert audit_types() == Enum.sort(audits ++ card_audits())

    assert ok_call(ctx.token, "access_apply", %{"proposal_id" => row.id})["state"] ==
             "awaiting_human_approval"

    assert counts() == before
  end

  test "a member without access.manage cannot list or call the access tools", ctx do
    member = user!("member")
    Repo.insert!(%OrgMembership{user_id: member.id, org_id: ctx.org, role: "member"})
    {_runtime, token} = runtime!(member, ["access"])
    assert Enum.all?(@access_tools, &(&1 not in names(token)))

    assert call(token, "access_explain", %{
             "target" => %{"type" => "user", "id" => ctx.root.id},
             "resource" => %{"type" => "project", "id" => ctx.p.id}
           })["error"]["code"] == -32001
  end

  test "default profiles stay without access while a NULL root profile gets the whole catalogue",
       ctx do
    initial_null_count =
      Repo.aggregate(from(p in RuntimeProfile, where: is_nil(p.tool_profile)), :count)

    IO.puts("ACCESS_NULL_PROFILES fixture_count=#{initial_null_count}")
    {runtime, token} = runtime!(ctx.root, AgentRuntime.default_tool_profile())
    assert Enum.all?(@access_tools, &(&1 not in names(token)))
    profile = Repo.get!(RuntimeProfile, runtime.id)
    Repo.update!(Ecto.Changeset.change(profile, tool_profile: nil))
    assert Enum.all?(@access_tools, &(&1 in names(token)))
  end

  test "the six-tool guest oracle survives an explicitly loaded access bundle", ctx do
    guest = user!("oracle-guest")

    Repo.insert!(%OrgMembership{
      user_id: guest.id,
      org_id: ctx.org,
      role: "member",
      external: true
    })

    {_runtime, token} = runtime!(guest, ~w(federation space context_read messaging task access))
    assert Enum.sort(names(token)) == Enum.sort(@guest_tools)
  end

  test "direct apply callers and scripted canvas bindings expose no MCP approval path" do
    root = Path.expand("../../../lib", __DIR__)

    callers =
      Path.wildcard(Path.join(root, "**/*.ex"))
      |> Enum.filter(&(File.read!(&1) =~ "Proposals.apply("))

    assert Enum.all?(
             callers,
             &String.ends_with?(&1, [
               "/platform/access/proposals.ex",
               "/platform_web/live/chat/canvas_hooks.ex",
               "/platform_web/live/access_live.ex"
             ])
           )

    assert Enum.any?(callers, &String.ends_with?(&1, "/canvas_hooks.ex"))

    refute Enum.any?(
             Map.keys(Platform.Canvas.ScriptEngine.Bindings.registry()),
             &String.starts_with?(&1, "access")
           )
  end

  defp propose!(ctx),
    do:
      ok_call(ctx.token, "access_propose", %{
        "space_id" => ctx.space.id,
        "options" => [
          %{
            "ops" => [
              %{
                "action" => "deny",
                "principal" => ["role", "guest"],
                "permission" => "tasks.read",
                "resource" => ["project", ctx.p.id]
              }
            ]
          }
        ]
      })

  defp runtime!(owner, modules) do
    agent = Repo.insert!(%Agent{name: "MCP access agent", slug: "access-mcp-#{uniq()}"})
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

  defp card_audits,
    do: [
      "chat.canvas.created",
      "chat.message.posted",
      "chat.canvas.updated",
      "chat.canvas.updated"
    ]

  defp audit_types,
    do: Repo.all(from(e in Platform.Audit.Event, select: e.event_type, order_by: e.event_type))

  # Cards are audited content: the three explicit artifact event types below
  # are expected writes. Every other audit row, including grant_changed, stays
  # unchanged before consent. Total artifact deltas are asserted separately.
  defp counts,
    do:
      {Repo.aggregate(Grant, :count), Repo.aggregate(Change, :count),
       Repo.aggregate(
         from(e in Platform.Audit.Event,
           where:
             e.event_type not in [
               "chat.canvas.created",
               "chat.canvas.updated",
               "chat.message.posted"
             ]
         ),
         :count
       )}

  defp names(token),
    do: rpc(token, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])

  defp ok_call(token, name, args) do
    response = call(token, name, args)
    assert %{"result" => %{"content" => [%{"text" => json} | _], "isError" => false}} = response
    Jason.decode!(json)
  end

  defp call(token, name, args),
    do: rpc(token, "tools/call", %{"name" => name, "arguments" => args})

  defp rpc(token, method, params) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    |> json_response(200)
  end

  defp uniq, do: System.unique_integer([:positive])

  defp user!(tag) do
    n = uniq()

    Repo.insert!(%User{
      name: "MCP #{tag} #{n}",
      email: "access-mcp-#{n}@example.com",
      oidc_sub: "access-mcp-#{n}"
    })
  end
end
