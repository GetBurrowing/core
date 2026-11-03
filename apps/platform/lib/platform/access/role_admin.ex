defmodule Platform.Access.RoleAdmin do
  @moduledoc """
  The authorized write path for custom roles and their assignments (task
  `01a1a2e4-9265` stage 1). `Platform.Access.Roles` does no actor
  authorization; this module is the ONLY caller `platform_web` may use for
  role writes.

  Every function takes the acting `%Scope{}` first, which the caller
  rebuilds fresh per event, and answers `{:error, :forbidden}` unless
  `Platform.Access.Effective.manages_org?/2` holds for the org the role (or
  assignment) belongs to.

  ## Permissions a role may be given

  A role created or edited here stores each checked permission at rule
  `"membership_org"` (an edit keeps an existing rule on a permission that
  stays checked). Two refusals stop an admin minting reach they do not
  hold:

    * `{:error, {:exceeds_actor, perms}}` — permissions the actor does not
      itself `Platform.Access.holds_anywhere?/2`;
    * `{:error, {:module_admin, perms}}` — module-admin permissions
      (`Platform.Access.Registry.module_admin_permissions/0`, e.g.
      `tasks.manage`, `prompts.manage`), which no org admin may hand out
      even when the actor is a root admin who holds them.

  ## Lifting an owner cap

  `grant_capped/3` is the one-step fix behind the agent page's capped line
  (`Platform.Access.Caps`). Only the OWNER's assignment lifts the cap: an
  agent's own role assignments contribute keys and role grants, never
  permissions (`Platform.Access.Scope` moduledoc), so `owner?: false` is
  refused with `{:error, :owner_required}`.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Access.{Caps, Effective, Registry, Role, RoleAssignment, Roles, Scope}
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Repo

  @default_rule "membership_org"

  @type error ::
          :forbidden
          | :builtin
          | :role_not_found
          | :not_found
          | :owner_required
          | :role_lacks_permission
          | {:exceeds_actor, [String.t()]}
          | {:module_admin, [String.t()]}
          | term()

  # ── roles ─────────────────────────────────────────────────────────────

  @doc "Create a custom role in `org_id`. `attrs`: `%{name, permissions: [permission]}`."
  @spec create_role(Scope.t(), binary(), map()) :: {:ok, Role.t()} | {:error, error()}
  def create_role(%Scope{} = actor, org_id, attrs) when is_binary(org_id) do
    attrs = Map.new(attrs)

    with :ok <- authorize(actor, org_id),
         {:ok, permissions} <- permission_list(Map.get(attrs, :permissions, [])),
         :ok <- within_actor(actor, permissions) do
      Roles.create_custom_role(org_id, %{
        name: Map.get(attrs, :name),
        permissions: Map.new(permissions, &{&1, @default_rule})
      })
    end
  end

  def create_role(_actor, _org_id, _attrs), do: {:error, :forbidden}

  @doc """
  Update a custom role's `:name` and/or `:permissions` (a list). A
  permission that stays checked keeps its existing rule; a newly checked one
  gets `"membership_org"`. Built-ins answer `{:error, :builtin}`.
  """
  @spec update_role(Scope.t(), String.t(), map()) :: {:ok, Role.t()} | {:error, error()}
  def update_role(%Scope{} = actor, role_key, attrs) when is_binary(role_key) do
    attrs = Map.new(attrs)

    with {:ok, role} <- fetch_role(role_key),
         :ok <- authorize(actor, role_org(actor, role)),
         {:ok, changes} <- role_changes(actor, role, attrs) do
      # Roles refuses a built-in as the second gate.
      Roles.update_custom_role(role, changes)
    end
  end

  def update_role(_actor, _role_key, _attrs), do: {:error, :forbidden}

  @doc "Delete a custom role (its assignments cascade). Built-ins: `{:error, :builtin}`."
  @spec delete_role(Scope.t(), String.t()) :: {:ok, Role.t()} | {:error, error()}
  def delete_role(%Scope{} = actor, role_key) when is_binary(role_key) do
    with {:ok, role} <- fetch_role(role_key),
         :ok <- authorize(actor, role_org(actor, role)) do
      Roles.delete_custom_role(role)
    end
  end

  def delete_role(_actor, _role_key), do: {:error, :forbidden}

  @doc "The custom roles of `org_id`, by name. Built-ins are not listed."
  @spec list_custom_roles(Scope.t(), binary()) :: {:ok, [Role.t()]} | {:error, :forbidden}
  def list_custom_roles(%Scope{} = actor, org_id) when is_binary(org_id) do
    with :ok <- authorize(actor, org_id) do
      {:ok, org_id |> Roles.list_roles() |> Enum.reject(& &1.builtin)}
    end
  end

  def list_custom_roles(_actor, _org_id), do: {:error, :forbidden}

  # ── assignments ───────────────────────────────────────────────────────

  @doc "Assign a custom role to a principal (a user, agent, runtime or `{type, id}`)."
  @spec assign(Scope.t(), String.t(), Roles.principal()) ::
          {:ok, RoleAssignment.t()} | {:error, error()}
  def assign(%Scope{} = actor, role_key, principal) when is_binary(role_key) do
    with {:ok, role} <- fetch_role(role_key),
         :ok <- authorize(actor, role_org(actor, role)) do
      Roles.assign(%{principal: principal, role: role})
    end
  end

  def assign(_actor, _role_key, _principal), do: {:error, :forbidden}

  @doc "Delete an assignment, authorized against the assignment's org."
  @spec unassign(Scope.t(), binary()) :: {:ok, RoleAssignment.t()} | {:error, error()}
  def unassign(%Scope{} = actor, assignment_id) when is_binary(assignment_id) do
    with {:ok, assignment} <- fetch_assignment(assignment_id),
         :ok <- authorize(actor, assignment.org_id) do
      Roles.unassign(assignment)
    end
  end

  def unassign(_actor, _assignment_id), do: {:error, :forbidden}

  @doc """
  The assignments of a custom role, oldest first, each with the principal's
  display name: `%{assignment, principal_type, principal_id, name}`.
  """
  @spec list_assignments_for_role(Scope.t(), String.t()) ::
          {:ok, [map()]} | {:error, error()}
  def list_assignments_for_role(%Scope{} = actor, role_key) when is_binary(role_key) do
    with {:ok, role} <- fetch_role(role_key),
         :ok <- authorize(actor, role_org(actor, role)) do
      assignments =
        Repo.all(
          from(a in RoleAssignment,
            where: a.role_key == ^role.key,
            order_by: [asc: a.inserted_at, asc: a.id]
          )
        )

      names = principal_names(assignments)

      {:ok,
       Enum.map(assignments, fn a ->
         %{
           assignment: a,
           principal_type: a.principal_type,
           principal_id: a.principal_id,
           name: Map.get(names, {a.principal_type, a.principal_id}, a.principal_id)
         }
       end)}
    end
  end

  def list_assignments_for_role(_actor, _role_key), do: {:error, :forbidden}

  # ── lifting an owner cap ──────────────────────────────────────────────

  @doc """
  Give `runtime`'s owner (and, with `agent?: true`, the agent) a custom role
  carrying `permission`, in one transaction, in the OWNER's org:

    * `role: {:existing, key}` — the role must belong to that org and carry
      `permission`, else `{:error, :role_lacks_permission}`;
    * `role: {:new, name, perms}` — `perms` must include `permission`; the
      role is created under `create_role/3`'s rules.

  `owner?: false` is `{:error, :owner_required}`. An assignment that already
  exists counts as success.
  """
  @spec grant_capped(Scope.t(), AgentRuntime.t(), map()) ::
          {:ok, %{role: Role.t(), assignments: [RoleAssignment.t()]}} | {:error, error()}
  def grant_capped(%Scope{} = actor, %AgentRuntime{} = runtime, attrs) do
    attrs = Map.new(attrs)
    permission = Map.get(attrs, :permission)
    %{user: owner, org_id: org_id} = Caps.owner(runtime)

    with :ok <- authorize(actor, org_id),
         :ok <- owner_required(Map.get(attrs, :owner?, true), owner) do
      Repo.transaction(fn ->
        role = unwrap(grant_role(actor, org_id, permission, Map.get(attrs, :role)))

        principals =
          [{:user, owner.id}] ++
            if Map.get(attrs, :agent?, true) and is_binary(runtime.agent_id),
              do: [{:agent, runtime.agent_id}],
              else: []

        %{role: role, assignments: Enum.map(principals, &unwrap(ensure_assigned(role, &1)))}
      end)
    end
  end

  def grant_capped(_actor, _runtime, _attrs), do: {:error, :forbidden}

  # ── internals ─────────────────────────────────────────────────────────

  defp authorize(%Scope{} = actor, org_id) when is_binary(org_id) do
    if Effective.manages_org?(actor, org_id), do: :ok, else: {:error, :forbidden}
  end

  defp authorize(_actor, _org_id), do: {:error, :forbidden}

  # A built-in role has no org; the actor is authorized over their own org
  # so an org admin reaches Roles' `{:error, :builtin}` and anyone else is
  # refused first.
  defp role_org(_actor, %Role{builtin: false, org_id: org_id}), do: org_id
  defp role_org(%Scope{org: %{id: org_id}}, %Role{builtin: true}), do: org_id
  defp role_org(_actor, _role), do: nil

  defp fetch_role(key) do
    case Roles.get_role(key) do
      %Role{} = role -> {:ok, role}
      nil -> {:error, :role_not_found}
    end
  end

  defp fetch_assignment(id) do
    with true <- Platform.UUID.valid?(id),
         %RoleAssignment{} = assignment <- Repo.get(RoleAssignment, id) do
      {:ok, assignment}
    else
      _ -> {:error, :not_found}
    end
  end

  defp permission_list(permissions) when is_list(permissions) do
    if Enum.all?(permissions, &is_binary/1),
      do: {:ok, Enum.uniq(permissions)},
      else: {:error, :invalid_permissions}
  end

  defp permission_list(_), do: {:error, :invalid_permissions}

  defp within_actor(actor, permissions) do
    module_admin = Enum.filter(permissions, &(&1 in Registry.module_admin_permissions()))
    exceeds = Enum.reject(permissions, &Access.holds_anywhere?(actor, &1))

    cond do
      module_admin != [] -> {:error, {:module_admin, module_admin}}
      exceeds != [] -> {:error, {:exceeds_actor, exceeds}}
      true -> :ok
    end
  end

  defp role_changes(_actor, %Role{builtin: true}, attrs), do: {:ok, Map.take(attrs, [:name])}

  defp role_changes(actor, %Role{} = role, attrs) do
    changes = Map.take(attrs, [:name])

    case Map.fetch(attrs, :permissions) do
      :error ->
        {:ok, changes}

      {:ok, permissions} ->
        with {:ok, permissions} <- permission_list(permissions),
             :ok <- within_actor(actor, permissions) do
          rules =
            Map.new(permissions, &{&1, Map.get(role.permissions || %{}, &1, @default_rule)})

          {:ok, Map.put(changes, :permissions, rules)}
        end
    end
  end

  defp owner_required(false, _owner), do: {:error, :owner_required}
  defp owner_required(_flag, %User{}), do: :ok
  defp owner_required(_flag, _no_owner), do: {:error, :owner_required}

  defp grant_role(_actor, org_id, permission, {:existing, key}) when is_binary(key) do
    case Roles.get_role(key) do
      %Role{builtin: false, org_id: ^org_id, permissions: permissions} = role ->
        if Map.has_key?(permissions || %{}, permission),
          do: {:ok, role},
          else: {:error, :role_lacks_permission}

      _ ->
        {:error, :role_lacks_permission}
    end
  end

  defp grant_role(actor, org_id, permission, {:new, name, permissions})
       when is_list(permissions) do
    if permission in permissions,
      do: create_role(actor, org_id, %{name: name, permissions: permissions}),
      else: {:error, :role_lacks_permission}
  end

  defp grant_role(_actor, _org_id, _permission, _role), do: {:error, :role_lacks_permission}

  # A failed INSERT aborts the Postgres transaction, so an existing tuple is
  # found first rather than caught from the unique constraint.
  defp ensure_assigned(%Role{} = role, {type, id}) do
    existing =
      Repo.all(
        from(a in RoleAssignment,
          where:
            a.org_id == ^role.org_id and a.principal_type == ^Atom.to_string(type) and
              a.principal_id == ^id and a.role_key == ^role.key and a.source == "manual",
          limit: 1
        )
      )

    case existing do
      [%RoleAssignment{} = assignment] -> {:ok, assignment}
      [] -> Roles.assign(%{principal: {type, id}, role: role})
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)

  defp principal_names(assignments) do
    ids_of = fn type ->
      for %RoleAssignment{principal_type: ^type, principal_id: id} <- assignments, do: id
    end

    users =
      Repo.all(from(u in User, where: u.id in ^ids_of.("user"), select: {u.id, u.name, u.email}))

    agents =
      Repo.all(from(a in Agent, where: a.id in ^ids_of.("agent"), select: {a.id, a.name}))

    Map.new(
      Enum.map(users, fn {id, name, email} -> {{"user", id}, name || email || id} end) ++
        Enum.map(agents, fn {id, name} -> {{"agent", id}, name || id} end)
    )
  end
end
