defmodule Platform.Access.Impact do
  @moduledoc """
  Effective-access differences measured inside the ledger's rollback-only transaction.

  Candidates include every persisted user and runtime. This deliberate superset
  includes cross-org grantees, external participants and owner-capped runtimes.
  Scopes are rebuilt in each inspection; no cached grant snapshot crosses the
  mutation. Results contain names and individual resources, never a truncated list.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Access.{Change, Changes, Grant, Grants, Lineage, Query, Scope}
  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo

  @schemas [
    task: Platform.Tasks.Task,
    stack: Platform.Tasks.Stack,
    space: Platform.Chat.Space,
    canvas: Platform.Chat.Canvas
  ]

  @doc "Preview a batch of grant operations, or the undo of a committed change."
  def diff(%Scope{} = actor, ops) when is_list(ops) do
    with {:ok, targets} <- op_targets(ops) do
      inspect = fn -> inspect_access(targets, ops) end

      ops
      |> Grants.apply_ops(
        actor: actor,
        dry_run: true,
        inspect_before: inspect,
        inspect_after: inspect
      )
      |> result()
    end
  end

  def diff(%Scope{} = actor, change_id) when is_binary(change_id) do
    with true <- Platform.UUID.valid?(change_id),
         %Change{} = change <- Repo.get(Change, change_id) do
      targets = Enum.map(change.before ++ change.after, &snapshot_target/1) |> Enum.uniq()
      inspect = fn -> inspect_access(targets, []) end

      change_id
      |> Changes.undo(actor,
        dry_run: true,
        inspect_before: inspect,
        inspect_after: inspect
      )
      |> result()
    else
      _ -> {:error, :not_found}
    end
  end

  def diff(_, _), do: {:error, :invalid_operations}

  defp op_targets(ops) do
    Enum.reduce_while(ops, {:ok, []}, fn op, {:ok, targets} ->
      case op_target(op) do
        {:ok, target} -> {:cont, {:ok, [target | targets]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.uniq(targets)}
      error -> error
    end
  end

  defp op_target(%{action: "revoke", id: id}) when is_binary(id) do
    if Platform.UUID.valid?(id) do
      case Repo.get(Grant, id) do
        nil -> {:error, :not_found}
        grant -> {:ok, {grant.permission, resource(grant.resource_type, grant.resource_id)}}
      end
    else
      {:error, :not_found}
    end
  end

  # A module lock (task 01a14721 stage 2): a deny names `{:module, org_id}`
  # and is previewed as whether each principal may still open the module. An
  # allow on a module is refused, as `Grants.apply_ops/2` refuses it.
  defp op_target(%{action: "grant", resource: {:module, _}}), do: {:error, :module_allow_refused}

  # An org-level grant is deny-only (task 01a18d38 stage 2), as
  # `Grants.apply_ops/2` refuses an org allow.
  defp op_target(%{action: "grant", resource: {:org, _}}), do: {:error, :org_allow_refused}

  defp op_target(%{action: "deny", permission: module, resource: {:module, org_id}})
       when is_binary(module) and is_binary(org_id),
       do: {:ok, {module, {:module, org_id}}}

  defp op_target(%{action: action, permission: permission, resource: target})
       when action in ["grant", "deny"] and is_binary(permission) do
    case Lineage.typed(target) do
      :untyped -> {:error, :invalid_resource}
      typed -> {:ok, {permission, typed}}
    end
  end

  defp op_target(_), do: {:error, :invalid_operations}

  defp snapshot_target(row),
    do: {row["permission"], resource(row["resource_type"], row["resource_id"])}

  defp resource("project", id), do: {:project, id}
  defp resource("space", id), do: {:space, id}
  defp resource("canvas", id), do: {:canvas, id}
  defp resource("memory_node", id), do: {:memory_node, id}
  defp resource("module", id), do: {:module, id}
  defp resource("org", id), do: {:org, id}

  defp inspect_access(targets, ops) do
    users = Repo.all(from(u in User, order_by: u.id))
    owners = Map.new(users, &{&1.id, &1.name || &1.email || &1.id})

    people =
      Enum.map(users, fn user ->
        {%{type: "user", id: user.id, name: owners[user.id]}, Scope.for_user(user)}
      end)

    agents =
      Repo.all(from(r in AgentRuntime, order_by: r.id))
      |> Enum.map(fn runtime ->
        {%{
           type: "agent",
           id: runtime.id,
           agent_id: runtime.agent_id,
           name: runtime.display_name || runtime.runtime_id,
           owner_id: runtime.owner_user_id,
           owner_name: owners[runtime.owner_user_id]
         }, Scope.for_runtime(runtime)}
      end)

    Enum.reduce(people ++ agents, %{direct: %{}, inherited: %{}, capped: []}, fn
      {person, scope}, acc ->
        Enum.reduce(targets, acc, fn {permission, target}, acc ->
          entry = Map.merge(person, %{permission: permission, resource: encode(target)})
          key = {person.type, person.id, permission, target}
          allowed = allowed?(scope, permission, target)
          direct = Map.put(acc.direct, key, {entry, allowed})
          inherited = inherited(scope, person, permission, target, acc.inherited)

          capped =
            case scope do
              %Scope{own_cap: %Scope{} = own, owner_cap: %Scope{} = owner} ->
                if proposed_agent_allow?(ops, person, permission, target) and
                     Access.can?(own, permission, target) and
                     not Access.can?(owner, permission, target) do
                  [Map.put(entry, :kind, "capped") | acc.capped]
                else
                  acc.capped
                end

              _ ->
                acc.capped
            end

          %{direct: direct, inherited: inherited, capped: capped}
        end)
    end)
  end

  # A module target's "permission" is the module name: allowed while the
  # module is not locked for the principal.
  defp allowed?(scope, module, {:module, _org_id}), do: not Access.module_locked?(scope, module)
  defp allowed?(scope, permission, target), do: Access.can?(scope, permission, target)

  defp proposed_agent_allow?(ops, person, permission, target) do
    Enum.any?(ops, fn
      %{action: "grant", principal: {:agent, id}, permission: ^permission, resource: resource} ->
        id == Map.get(person, :agent_id) and Lineage.typed(resource) == target

      _ ->
        false
    end)
  end

  defp inherited(_scope, _person, _module, {:module, _org_id}, acc), do: acc

  defp inherited(scope, person, permission, {:memory, path, _}, acc),
    do: inherited_memory(scope, person, permission, path, acc)

  defp inherited(scope, person, permission, {:memory_node, id}, acc) do
    alias Platform.Org.Wiki.NodePath

    path =
      Repo.one(
        from(p in NodePath, where: p.node_id == ^id and is_nil(p.valid_to), select: p.path)
      )

    if path, do: inherited_memory(scope, person, permission, path, acc), else: acc
  end

  defp inherited(scope, person, permission, target, acc) do
    Enum.reduce(@schemas, acc, fn {type, schema}, acc ->
      ids = Lineage.descendant_ids(type, [target])

      ids =
        case target do
          {^type, id} -> List.delete(ids, id)
          _ -> ids
        end

      if ids == [] do
        acc
      else
        readable =
          from(r in schema, where: r.id in ^ids, select: r.id)
          |> Query.where_permitted(scope, permission, type, %{id: :id})
          |> Repo.all()
          |> MapSet.new()

        Enum.reduce(ids, acc, fn id, acc ->
          child = {type, id}
          entry = Map.merge(person, %{permission: permission, resource: encode(child)})

          Map.put(
            acc,
            {person.type, person.id, permission, child},
            {entry, MapSet.member?(readable, id)}
          )
        end)
      end
    end)
  end

  defp inherited_memory(scope, person, permission, path, acc) do
    alias Platform.Org.Wiki.NodePath
    # Prefix inheritance is meaningful only for a directory node.
    if String.ends_with?(path, "/") do
      children =
        Repo.all(from(p in NodePath, where: is_nil(p.valid_to)))
        |> Enum.filter(&(&1.path != path and String.starts_with?(&1.path, path)))

      ids = Enum.map(children, & &1.id)

      readable =
        from(p in NodePath, where: p.id in ^ids, select: p.node_id)
        |> Query.where_permitted(scope, permission, :memory_page, %{path: :path})
        |> Repo.all()
        |> MapSet.new()

      Enum.reduce(children, acc, fn child, acc ->
        target = {:memory_node, child.node_id}
        entry = Map.merge(person, %{permission: permission, resource: encode(target)})

        Map.put(
          acc,
          {person.type, person.id, permission, target},
          {entry, MapSet.member?(readable, child.node_id)}
        )
      end)
    else
      acc
    end
  end

  defp encode({type, id}), do: %{type: Atom.to_string(type), id: id}
  defp encode({:memory, path, _}), do: %{type: "memory", id: path}

  defp result({:ok, %{before: before, after: after_state}}) do
    loses = changed(before.direct, after_state.direct, true, false)
    gains = changed(before.direct, after_state.direct, false, true)

    inherited =
      Enum.map(
        changed(before.inherited, after_state.inherited, true, false),
        &Map.put(&1, :effect, "loses")
      ) ++
        Enum.map(
          changed(before.inherited, after_state.inherited, false, true),
          &Map.put(&1, :effect, "gains")
        )

    affected = loses ++ gains ++ inherited
    count = affected |> Enum.map(&{&1.type, &1.id}) |> Enum.uniq() |> length()

    {:ok,
     %{
       loses: loses,
       gains: gains,
       inherited: sort(inherited),
       conflicts: sort(after_state.capped),
       count: count
     }}
  end

  defp result({:error, _} = error), do: error

  defp changed(before, after_state, was, now) do
    after_state
    |> Enum.flat_map(fn {key, {entry, allowed}} ->
      case Map.get(before, key) do
        {_, ^was} when allowed == now -> [entry]
        _ -> []
      end
    end)
    |> sort()
  end

  defp sort(entries),
    do: Enum.sort_by(entries, &{&1.type, &1.id, &1.permission, &1.resource.type, &1.resource.id})
end
