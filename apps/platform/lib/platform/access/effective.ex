defmodule Platform.Access.Effective do
  @moduledoc """
  Named explanations of the subject's effective access. ViewAs authorizes the
  inspection and supplies its real scope. Every allowed flag comes from
  Access.can?/3; annotations describe the effective source, not an independent
  authorization decision. Overridden allows are not reported as effective grants.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Access.{Grant, Lineage, Registry, Scope, ViewAs}
  alias Platform.Accounts
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation
  alias Platform.Repo

  @resources [
    {:project, Platform.Tasks.Project, "tasks"},
    {:task, Platform.Tasks.Task, "tasks"},
    {:stack, Platform.Tasks.Stack, "tasks"},
    {:space, Platform.Chat.Space, "chat"},
    {:canvas, Platform.Chat.Canvas, "canvas"},
    {:memory_node, Platform.Org.Wiki.Node, "memory"}
  ]

  @doc "Effective resource rows, or the same authorization refusal as ViewAs."
  def lines(%Scope{} = viewer, subject) do
    with {:ok, view} <- ViewAs.compute(viewer, subject) do
      rows =
        for {type, schema, module} <- @resources,
            resource <- Repo.all(from(r in schema, order_by: r.id)),
            target = {type, resource.id},
            Access.can?(viewer, module <> ".read", target),
            permission <- permissions(view.scope, module, target),
            row <- resource_lines(view.scope, permission, target, resource),
            do: row

      {:ok, Enum.sort_by(rows, &{&1.where.type, &1.where.id, &1.permission, &1.source})}
    end
  end

  @doc "Named subjects the viewer may inspect, using ViewAs authorization for each."
  def subjects(%Scope{} = viewer) do
    people =
      Repo.all(from(u in Platform.Accounts.User, order_by: u.id))
      |> Enum.map(
        &%{type: "user", id: &1.id, name: &1.name || &1.email || &1.id, target: {:user, &1.id}}
      )

    agents =
      Repo.all(from(r in AgentRuntime, order_by: r.id))
      |> Enum.map(
        &%{
          type: "agent",
          id: &1.id,
          name: &1.display_name || &1.runtime_id,
          target: {:agent, &1.id}
        }
      )

    roles =
      for org <- Repo.all(from(o in Platform.Tenancy.Org, order_by: o.id)),
          key <- Registry.builtin_role_keys() do
        %{
          type: "role",
          id: org.id <> ":" <> key,
          org_id: org.id,
          key: key,
          name: "#{org.name} · #{key}",
          target: {:role, org.id, key}
        }
      end

    managed =
      for {type, schema, read} <- [
            {:project, Platform.Tasks.Project, "tasks.read"},
            {:space, Platform.Chat.Space, "chat.read"}
          ],
          resource <- Repo.all(schema),
          target = {type, resource.id},
          Access.can?(viewer, "access.manage", target),
          do: {read, target}

    (people ++ agents ++ roles)
    |> Enum.filter(fn subject ->
      case ViewAs.compute(viewer, subject.target) do
        {:ok, view} -> inspectable_subject?(viewer, view.scope, managed)
        _ -> false
      end
    end)
    |> Enum.sort_by(&{&1.type, &1.name, &1.id})
  end

  defp inspectable_subject?(viewer, scope, managed) do
    memberships =
      case scope do
        %Scope{owner_cap: %Scope{actor: %{org_memberships: rows}}} when is_list(rows) -> rows
        %Scope{actor: %{org_memberships: rows}} when is_list(rows) -> rows
        _ -> []
      end

    Access.can?(viewer, "install.admin") or
      Enum.any?(memberships, &Access.can?(viewer, "access.manage", &1.org_id)) or
      Enum.any?(managed, fn {read, resource} -> Access.can?(scope, read, resource) end)
  end

  @doc "Resolve a person, runtime (database id or runtime slug), or built-in role."
  def scope_for({:user, id}) when is_binary(id) do
    case Accounts.get_user(id) do
      nil -> {:error, :not_found}
      user -> {:ok, Scope.for_user(user)}
    end
  end

  def scope_for({:agent, id}) when is_binary(id) do
    runtime =
      Federation.get_runtime_by_runtime_id(id) ||
        if Platform.UUID.valid?(id), do: Federation.get_runtime(id)

    case runtime do
      %AgentRuntime{} -> {:ok, Scope.for_runtime(runtime)}
      nil -> {:error, :not_found}
    end
  end

  def scope_for({:role, org_id, key}) when key in ~w(admin member guest) do
    case Platform.Tenancy.get_org(org_id) do
      nil -> {:error, :not_found}
      org -> {:ok, Scope.for_role(org, key)}
    end
  end

  def scope_for(_), do: {:error, :not_found}

  defp permissions(scope, module, target) do
    explicit =
      for grant <- scope.grants,
          Grant.target(grant) in Lineage.ancestors(target),
          do: grant.permission

    (Enum.filter(Registry.permission_names(), &String.starts_with?(&1, module <> ".")) ++
       explicit ++ ["access.manage"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp resource_lines(scope, permission, target, resource) do
    allowed = Access.can?(scope, permission, target)
    ancestors = MapSet.new(Lineage.ancestors(target))

    grants =
      Enum.filter(
        scope.grants,
        &(&1.permission == permission and MapSet.member?(ancestors, Grant.target(&1)))
      )

    base = %{
      permission: permission,
      where: %{
        type: target |> elem(0) |> Atom.to_string(),
        id: elem(target, 1),
        name: resource_name(resource)
      },
      allowed: allowed
    }

    cond do
      capped?(scope, permission, target) ->
        owner = if scope.actor.owner_user_id, do: Accounts.get_user(scope.actor.owner_user_id)

        [
          Map.merge(base, %{
            source: "capped",
            note:
              "Limited by owner #{if owner, do: owner.name || owner.email, else: "(missing owner)"}",
            owner_id: scope.actor.owner_user_id
          })
        ]

      not allowed and restricted?(scope, permission, target) ->
        [Map.merge(base, %{source: "restricted", note: "Channel role restriction"})]

      not allowed ->
        grants
        |> Enum.filter(&(&1.effect == "deny"))
        |> Enum.map(&grant_line(base, &1, target, "deny"))

      true ->
        case Enum.filter(grants, &(&1.effect == "allow")) do
          [] ->
            [Map.merge(base, %{source: "role", note: "Role defaults and assigned roles"})]

          allows ->
            Enum.map(
              allows,
              &grant_line(
                base,
                &1,
                target,
                if(Grant.target(&1) == target, do: "grant", else: "inherited")
              )
            )
        end
    end
  end

  defp grant_line(base, grant, target, source) do
    Map.merge(base, %{
      source: source,
      grant_id: grant.id,
      principal_type: grant.principal_type,
      principal_id: grant.principal_id,
      role_key: grant.principal_role_key,
      inherited_from:
        if(Grant.target(grant) == target,
          do: nil,
          else: %{type: grant.resource_type, id: grant.resource_id}
        ),
      note:
        if(Grant.target(grant) == target,
          do: grant_provenance(grant),
          else: "Inherited from #{grant.resource_type} #{grant.resource_id}"
        )
    })
  end

  defp grant_provenance(grant) do
    user = Accounts.get_user(grant.granted_by)
    name = if user, do: user.name || user.email, else: "System"

    change =
      Repo.one(
        from(c in Platform.Access.Change,
          where: c.org_id == ^grant.org_id and c.action in ["grant", "deny"],
          where:
            fragment(
              "EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS entry WHERE entry->>'id' = ?)",
              c.after,
              ^grant.id
            ),
          order_by: [asc: c.id],
          limit: 1
        )
      )

    via = if change && change.via_agent_id, do: Federation.get_runtime(change.via_agent_id)
    attribution = if via, do: "#{name} via #{via.display_name || via.runtime_id}", else: name
    date = Calendar.strftime(grant.inserted_at, "%Y-%m-%d %H:%M")
    "#{attribution} · #{date}"
  end

  defp capped?(%Scope{own_cap: %Scope{} = own, owner_cap: %Scope{} = owner}, permission, target),
    do: Access.can?(own, permission, target) and not Access.can?(owner, permission, target)

  defp capped?(_, _, _), do: false

  defp restricted?(scope, permission, {type, id}) when type in [:space, :canvas],
    do:
      String.ends_with?(permission, ".read") and
        id in Access.restriction_ids(scope, permission, type)

  defp restricted?(_, _, _), do: false

  defp resource_name(resource),
    do: Map.get(resource, :name) || Map.get(resource, :title) || resource.id
end
