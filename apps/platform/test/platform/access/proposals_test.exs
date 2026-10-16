defmodule Platform.Access.ProposalsTest do
  use Platform.DataCase, async: false
  import Ecto.Query
  import Platform.TenancyFixtures

  alias Platform.Access.{
    Change,
    Changes,
    Grant,
    Grants,
    Live,
    Proposal,
    Proposals,
    RuntimeProfiles,
    Scope,
    ViewAs
  }

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.{Accounts, Chat, Repo, Tasks}

  test "required undo ledger and view-as APIs exist before proposals" do
    for {module, fun, arity} <- [
          {Changes, :commit, 4},
          {Changes, :undo, 3},
          {Changes, :list_changes, 2},
          {Grant, :snapshot, 1},
          {ViewAs, :compute, 2}
        ] do
      Code.ensure_loaded!(module)
      assert function_exported?(module, fun, arity)
    end

    assert Repo.query!("SELECT to_regclass('access_grant_changes')").rows != [[nil]]
  end

  setup do
    root = acme_org_id()
    org = tenant_org_id("proposal")
    owner = user!("owner")
    Repo.insert!(%Platform.Tenancy.OrgMembership{org_id: root, user_id: owner.id, role: "admin"})
    owner = Accounts.get_user(owner.id)
    target = user!("target")
    {:ok, project} = Tasks.create_project(%{name: "proposal-#{uniq()}", org_id: org})

    {:ok, agent} =
      Agent.changeset(%Agent{}, %{slug: "proposal-#{uniq()}", name: "Proposal Agent"})
      |> Repo.insert()

    {:ok, runtime} =
      AgentRuntime.changeset(%AgentRuntime{}, %{
        runtime_id: "proposal-#{uniq()}",
        agent_id: agent.id,
        owner_user_id: owner.id,
        status: "active"
      })
      |> Repo.insert()

    {:ok, _} =
      RuntimeProfiles.create_for_runtime(runtime, AgentRuntime.default_tool_profile(), nil)

    for permission <- ["access.manage", "tasks.read"] do
      {:ok, _} = Grants.grant(%{principal: runtime, resource: project, permission: permission})
    end

    {:ok, space} = Chat.create_space(%{name: "proposal-#{uniq()}", kind: "channel", org_id: org})

    {:ok, participant} =
      Chat.add_participant(space.id, %{participant_id: owner.id, participant_type: "user"})

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Access change"
      })

    %{
      scope: Scope.for_user(owner),
      owner: owner,
      target: target,
      project: project,
      runtime: runtime,
      space: space,
      canvas: canvas,
      ops: [
        %{
          action: "deny",
          principal: {:user, target.id},
          permission: "tasks.read",
          resource: {:project, project.id}
        }
      ]
    }
  end

  test "dry runs execute authorization and inspection without grants, ledger, audit or PubSub writes",
       ctx do
    Live.subscribe(ctx.target.id)
    before = counts()

    assert {:ok, %{change: nil, before: false, after: true}} =
             Grants.apply_ops(ctx.ops,
               actor: ctx.scope,
               dry_run: true,
               inspect_before: fn ->
                 Repo.exists?(from(g in Grant, where: g.principal_id == ^ctx.target.id))
               end,
               inspect_after: fn ->
                 Repo.exists?(from(g in Grant, where: g.principal_id == ^ctx.target.id))
               end
             )

    assert counts() == before
    refute_receive {:access_changed, _}

    assert {:error, :stale} =
             Grants.apply_ops(ctx.ops, actor: ctx.scope, precondition: fn -> {:error, :stale} end)

    assert counts() == before
  end

  test "human apply writes one attributed ledger row, double apply refuses, panel undo restores",
       ctx do
    row = proposal!(ctx)
    assert {:error, :human_required} = Proposals.apply(row.id, Scope.for_runtime(ctx.runtime))
    assert {:ok, applied} = Proposals.apply(row.id, ctx.scope)
    change = Repo.get!(Change, applied.change_id)
    assert change.actor_type == "user"
    assert change.actor_id == ctx.owner.id
    assert change.via_agent_id == ctx.runtime.id
    assert {:error, :not_proposed} = Proposals.apply(row.id, ctx.scope)

    assert Repo.aggregate(from(c in Change, where: c.via_agent_id == ^ctx.runtime.id), :count) ==
             1

    assert {:ok, %{state: "undone"}} = Proposals.undo_applied(row.id, ctx.scope)
    refute Repo.exists?(from(g in Grant, where: g.principal_id == ^ctx.target.id))
  end

  test "changed card content refuses apply", ctx do
    row = proposal!(ctx)

    Repo.update_all(from(c in Chat.Canvas, where: c.id == ^ctx.canvas.id),
      set: [document: %{"root" => %{"type" => "text", "props" => %{"text" => "tampered"}}}]
    )

    assert {:error, :card_changed} = Proposals.apply(row.id, ctx.scope)
    assert Repo.get!(Proposal, row.id).state == "stale"
  end

  test "membership joins invalidate consent", ctx do
    row = proposal!(ctx)

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      org_id: ctx.project.org_id,
      user_id: ctx.target.id,
      role: "member"
    })

    assert {:error, :stale} = Proposals.apply(row.id, ctx.scope)
  end

  test "changed grants invalidate consent", ctx do
    row = proposal!(ctx)

    {:ok, _} =
      Grants.grant(%{principal: ctx.target, permission: "canvas.read", resource: ctx.canvas})

    assert {:error, :stale} = Proposals.apply(row.id, ctx.scope)
  end

  test "expired proposals and nonparticipant humans cannot apply", ctx do
    row = proposal!(ctx)

    Repo.update_all(from(p in Proposal, where: p.id == ^row.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert {:error, :expired} = Proposals.apply(row.id, ctx.scope)
    assert {:error, :not_found} = Proposals.apply(row.id, Scope.for_user(ctx.target))
  end

  test "mixed batches refuse before mutating", ctx do
    assert {:error, :mixed_actions} =
             Grants.apply_ops(ctx.ops ++ [%{action: "grant"}], actor: ctx.scope)
  end

  defp proposal!(ctx) do
    {:ok, row} =
      Proposals.propose(ctx.runtime, %{
        canvas_id: ctx.canvas.id,
        space_id: ctx.space.id,
        ops: ctx.ops
      })

    row
  end

  defp counts, do: Enum.map([Grant, Change, Platform.Audit.Event], &Repo.aggregate(&1, :count))
  defp uniq, do: System.unique_integer([:positive])

  defp user!(tag) do
    n = uniq()

    Repo.insert!(%User{
      email: "proposal-#{tag}-#{n}@example.com",
      name: tag,
      oidc_sub: "proposal-#{n}"
    })
  end
end
