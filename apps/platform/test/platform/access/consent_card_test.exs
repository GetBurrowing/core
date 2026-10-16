defmodule Platform.Access.ConsentCardTest do
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Platform.Access.{Grant, Grants, Proposal, Proposals, Scope}
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.{Accounts, Chat, Repo, Tasks}

  setup do
    org = acme_org_id()
    root = user!("root")
    Repo.insert!(%Platform.Tenancy.OrgMembership{org_id: org, user_id: root.id, role: "admin"})
    guest = user!("guest")

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      org_id: org,
      user_id: guest.id,
      role: "member",
      external: true
    })

    {:ok, project} =
      Tasks.create_project(%{name: "Consent factual project #{uniq()}", org_id: org})

    agent = Repo.insert!(%Agent{name: "Consent agent", slug: "consent-#{uniq()}"})

    runtime =
      Platform.RuntimeProfileFixtures.runtime!(
        root.id,
        ["task", "canvas"],
        %{agent_id: agent.id},
        nil
      )

    {:ok, space} =
      Chat.create_space(%{
        name: "Consent #{uniq()}",
        slug: "consent-#{uniq()}",
        kind: "channel",
        org_id: org
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: root.id,
        joined_at: DateTime.utc_now()
      })

    %{
      human: Scope.for_user(Accounts.get_user(root.id)),
      runtime: runtime,
      guest: guest,
      project: project,
      space: space,
      participant: participant
    }
  end

  test "a single option shows the factual permission and resource even for delegation of admin power",
       ctx do
    proposal =
      propose!(ctx, [
        %{key: "one", label: "harmless agent prose", ops: [op(ctx, "grant", "access.manage")]}
      ])

    text = document_text(Repo.get!(Chat.Canvas, proposal.canvas_id).document)
    assert text =~ "Gain access: access.manage"
    assert text =~ ctx.project.name
    assert text =~ "user #{ctx.guest.name}"
    refute text =~ "harmless agent prose"

    assert Proposals.digest(Repo.get!(Chat.Canvas, proposal.canvas_id).document) ==
             proposal.card_digest
  end

  test "removing a deny describes restored access", ctx do
    {:ok, deny} =
      Grants.deny(%{principal: ctx.guest, permission: "tasks.read", resource: ctx.project})

    proposal =
      propose!(ctx, [%{key: "one", label: "ignored", ops: [%{action: "revoke", id: deny.id}]}])

    text = document_text(Repo.get!(Chat.Canvas, proposal.canvas_id).document)
    assert text =~ "Gain access: tasks.read"
    assert text =~ ctx.project.name
    refute text =~ "Lose access: tasks.read"
  end

  test "a selected choice, persisted consent card and server document agree before Apply", ctx do
    proposal =
      propose!(ctx, [
        %{key: "write", label: "ignored", ops: [op(ctx, "grant", "tasks.write")]},
        %{key: "manage", label: "ignored", ops: [op(ctx, "grant", "access.manage")]}
      ])

    assert proposal.selected_option == nil
    assert {:ok, selected} = Proposals.choose(proposal.id, "manage", ctx.human)
    stored = Repo.get!(Proposal, proposal.id)
    canvas = Repo.get!(Chat.Canvas, proposal.canvas_id)
    {:ok, %{document: server_document}} = Chat.Canvas.Server.describe(proposal.canvas_id)
    assert stored.selected_option == "manage"
    assert selected.selected_option == "manage"
    assert stored.card_digest == Proposals.digest(canvas.document)
    assert stored.card_digest == Proposals.digest(server_document)
    text = document_text(canvas.document)
    assert text =~ "Gain access: access.manage"
    operation = find_node(canvas.document["root"], "operation-0")

    assert operation["props"]["value"] ==
             "Gain access: access.manage · #{ctx.project.name} · user #{ctx.guest.name}"

    assert {:ok, applied} = Proposals.apply(stored.id, ctx.human)
    assert applied.state == "applied"

    assert Repo.exists?(
             from(g in Grant,
               where:
                 g.principal_id == ^ctx.guest.id and g.resource_id == ^ctx.project.id and
                   g.permission == "access.manage"
             )
           )

    refute Repo.exists?(
             from(g in Grant,
               where:
                 g.principal_id == ^ctx.guest.id and g.resource_id == ^ctx.project.id and
                   g.permission == "tasks.write"
             )
           )
  end

  test "advancing a normal chat read cursor preserves consent and Apply works", ctx do
    {:ok, message} =
      Chat.post_message(%{
        space_id: ctx.space.id,
        participant_id: ctx.participant.id,
        content_type: "text",
        content: "Read cursor fixture"
      })

    proposal =
      propose!(ctx, [%{key: "one", label: "ignored", ops: [op(ctx, "grant", "tasks.write")]}])

    base_hash = Proposals.state_hash()
    assert :ok = Chat.mark_space_read(ctx.participant.id, message.id)
    assert Repo.get!(Chat.Participant, ctx.participant.id).last_read_message_id == message.id
    assert Proposals.state_hash() == base_hash
    assert {:ok, %{state: "applied"}} = Proposals.apply(proposal.id, ctx.human)
  end

  test "root reset includes a cross-org grant even without tenant access.manage", ctx do
    tenant = tenant_org_id("consent-reset")
    {:ok, project} = Tasks.create_project(%{name: "Cross-org reset #{uniq()}", org_id: tenant})

    {:ok, grant} =
      Grants.grant(%{principal: ctx.guest, permission: "tasks.read", resource: project})

    assert Platform.Access.Delegation.root_admin?(ctx.human)
    refute Platform.Access.can?(ctx.human, "access.manage", tenant)
    ops = Grants.reset_ops({:user, ctx.guest.id}, ctx.human)
    assert %{action: "revoke", id: grant.id} in ops
  end

  test "denying an existing allow preserves its id and undo restores the exact snapshot", ctx do
    {:ok, grant} =
      Grants.grant(%{principal: ctx.guest, permission: "tasks.read", resource: ctx.project})

    before = Grant.snapshot(grant)

    proposal =
      propose!(ctx, [%{key: "one", label: "ignored", ops: [op(ctx, "deny", "tasks.read")]}])

    assert {:ok, %{state: "applied"}} = Proposals.apply(proposal.id, ctx.human)
    assert Repo.get!(Grant, grant.id).effect == "deny"
    assert {:ok, %{state: "undone"}} = Proposals.undo_applied(proposal.id, ctx.human)
    assert Grant.snapshot(Repo.get!(Grant, grant.id)) == before
  end

  test "canvas relocation invalidates consent while cosmetic canvas edits do not", ctx do
    {:ok, elsewhere} =
      Chat.create_space(%{
        name: "Relocation #{uniq()}",
        slug: "relocation-#{uniq()}",
        kind: "channel",
        org_id: ctx.project.org_id
      })

    {:ok, child} =
      Chat.create_canvas(%{
        "space_id" => ctx.space.id,
        "created_by" => ctx.participant.id,
        "title" => "Existing child"
      })

    proposal = propose!(ctx, [%{key: "one", ops: [op(ctx, "grant", "tasks.write")]}])
    original = Proposals.state_hash()

    Repo.update_all(from(c in Chat.Canvas, where: c.id == ^child.id),
      set: [title: "Cosmetic rename"]
    )

    assert Proposals.state_hash() == original

    Repo.update_all(from(c in Chat.Canvas, where: c.id == ^child.id),
      set: [space_id: elsewhere.id]
    )

    refute Proposals.state_hash() == original
    assert {:error, :stale} = Proposals.apply(proposal.id, ctx.human)
  end

  defp propose!(ctx, options) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => ctx.space.id,
        "created_by" => ctx.participant.id,
        "title" => "Consent"
      })

    {:ok, proposal} =
      Proposals.propose(ctx.runtime, %{
        canvas_id: canvas.id,
        space_id: ctx.space.id,
        options: options
      })

    proposal
  end

  defp op(ctx, action, permission),
    do: %{
      action: action,
      principal: {:user, ctx.guest.id},
      permission: permission,
      resource: {:project, ctx.project.id}
    }

  defp document_text(%{"root" => root}), do: node_text(root) |> Enum.join("\n")

  defp node_text(node),
    do:
      List.wrap(get_in(node, ["props", "value"])) ++
        Enum.flat_map(node["children"] || [], &node_text/1)

  defp find_node(%{"id" => id} = node, id), do: node
  defp find_node(node, id), do: Enum.find_value(node["children"] || [], &find_node(&1, id))
  defp uniq, do: System.unique_integer([:positive])

  defp user!(tag) do
    n = uniq()

    Repo.insert!(%User{
      name: "Consent #{tag} #{n}",
      email: "consent-#{n}@example.com",
      oidc_sub: "consent-#{n}"
    })
  end
end
