defmodule Platform.Access.Roles do
  @moduledoc """
  The context API for custom roles and role assignments (task
  `01a1386e-59d1` stage 1, stack `rbac-roles` member 8;
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Built-in roles`).

  Custom roles and assignments are created through this module ONLY: there
  is no MCP tool and no admin UI for them in this stack member (the Access
  panel is stack position 9).

  ## Custom roles

  A custom role is a named permission set owned by one org. Its key is
  minted here as `"custom:" <> uuidv7`, so it can never collide with a
  built-in key and is a valid `access_grants.principal_role_key`: a grant to
  a custom role is `Platform.Access.Grants.grant(%{principal: {:role, key}, …})`.
  See `Platform.Access.Role.custom_changeset/2` for what a custom role may
  carry.

  The three built-in roles are immutable through this API: every write
  naming one returns `{:error, :builtin}`.

  `delete_custom_role/1` deletes the row; the database cascades its
  assignments (`access_role_assignments.role_key`) and its role-principal
  grants (`access_grants.principal_role_key`, member 3), both
  `on_delete: :delete_all`.

  ## Assignments

  An assignment lets a principal hold a custom role in the role's org.
  Built-in roles are not assignable (`{:error, :builtin_not_assignable}`):
  the base role comes from the membership's generated `access_role_key`.

    * A user principal must hold a NON-external membership in the org,
      else `{:error, :no_membership}`. This module never creates a
      membership.
    * An agent principal must exist, else `{:error, :agent_not_found}`.
      Agents hold no role unless an assignment names them.

  ## Snapshots

  A Scope reads assignments when it is built (`Platform.Access.Scope`), so
  an assignment applies to the next Scope built for the principal. Live
  apply to open sockets is stack position 6.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Access.{Role, RoleAssignment}
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Repo
  alias Platform.Tenancy.{Org, OrgMembership}

  @custom_prefix "custom:"

  @typedoc "A principal as `assign/1` and `list_assignments_for/1` take it."
  @type principal ::
          User.t() | Agent.t() | AgentRuntime.t() | {:user, binary()} | {:agent, binary()}

  # ── custom roles ──────────────────────────────────────────────────────

  @doc """
  Create a custom role in `org` (an `%Org{}` or an org id). `attrs` carries
  `:name` and `:permissions` (`%{permission => rule}`).
  """
  @spec create_custom_role(Org.t() | binary(), map()) :: {:ok, Role.t()} | {:error, term()}
  def create_custom_role(%Org{id: org_id}, attrs), do: create_custom_role(org_id, attrs)

  def create_custom_role(org_id, attrs) when is_binary(org_id) do
    if Platform.UUID.valid?(org_id) and Repo.get(Org, org_id) do
      %Role{key: mint_key(), builtin: false, org_id: org_id}
      |> Role.custom_changeset(Map.new(attrs))
      |> Repo.insert()
    else
      {:error, :org_not_found}
    end
  end

  @doc "Update a custom role's `:name` and/or `:permissions`. Built-ins: `{:error, :builtin}`."
  @spec update_custom_role(Role.t() | String.t(), map()) :: {:ok, Role.t()} | {:error, term()}
  def update_custom_role(role, attrs) do
    with {:ok, %Role{} = role} <- fetch_custom(role) do
      role
      |> Role.custom_changeset(Map.new(attrs))
      |> Repo.update()
    end
  end

  @doc """
  Delete a custom role. Its assignments and role-principal grants go with
  it (FK cascade). Built-ins: `{:error, :builtin}`.
  """
  @spec delete_custom_role(Role.t() | String.t()) :: {:ok, Role.t()} | {:error, term()}
  def delete_custom_role(role) do
    with {:ok, %Role{} = role} <- fetch_custom(role) do
      case Repo.transaction(fn ->
             # Serialize deletion with Restrictions' FOR SHARE role lock.
             Repo.one!(from r in Role, where: r.key == ^role.key, lock: "FOR UPDATE")
             spaces = Repo.all(from r in Platform.Access.SpaceRestriction,
               where: r.role_key == ^role.key, select: r.space_id, order_by: r.space_id)
             if spaces != [], do: Repo.rollback({:role_restricts_spaces, spaces})
             Repo.delete!(role)
           end) do
        result -> result
      end
    end
  end

  @doc """
  The roles `org` offers: the three built-ins, then that org's custom roles
  by name. Another org's custom roles are never listed.
  """
  @spec list_roles(Org.t() | binary()) :: [Role.t()]
  def list_roles(%Org{id: org_id}), do: list_roles(org_id)

  def list_roles(org_id) when is_binary(org_id) do
    builtins = Repo.all(from(r in Role, where: r.builtin, order_by: r.key))

    custom =
      if Platform.UUID.valid?(org_id) do
        Repo.all(
          from(r in Role,
            where: not r.builtin and r.org_id == ^org_id,
            order_by: [asc: fragment("lower(?)", r.name), asc: r.key]
          )
        )
      else
        []
      end

    builtins ++ custom
  end

  @doc "Fetch a role by key (built-in or custom). `nil` when absent."
  @spec get_role(String.t()) :: Role.t() | nil
  def get_role(key) when is_binary(key), do: Repo.get_by(Role, key: key)

  @doc "Is `key` a custom role key (by shape)?"
  @spec custom_key?(term()) :: boolean()
  def custom_key?(@custom_prefix <> _), do: true
  def custom_key?(_), do: false

  # ── assignments ───────────────────────────────────────────────────────

  @doc """
  Assign a custom role to a principal:

      Roles.assign(%{principal: user, role: role})
      Roles.assign(%{principal: {:agent, agent_id}, role: "custom:…", source: "idp"})

  The assignment's org is the role's org (`:org_id`, when given, must equal
  it, else `{:error, :org_mismatch}`). `:source` defaults to `"manual"`.
  Assigning a tuple that already exists returns `{:error, %Ecto.Changeset{}}`
  with a unique-constraint error.
  """
  @spec assign(map()) :: {:ok, RoleAssignment.t()} | {:error, term()}
  def assign(attrs) do
    attrs = Map.new(attrs)

    with {:ok, %Role{} = role} <- fetch_assignable(Map.get(attrs, :role)),
         {:ok, org_id} <- assignment_org(role, Map.get(attrs, :org_id)),
         {:ok, {type, id}} <- principal(Map.get(attrs, :principal)),
         :ok <- principal_may_hold(type, id, org_id) do
      %RoleAssignment{}
      |> RoleAssignment.changeset(%{
        org_id: org_id,
        principal_type: type,
        principal_id: id,
        role_key: role.key,
        source: Map.get(attrs, :source, "manual")
      })
      |> Repo.insert()
    end
  end

  @doc "Delete an assignment by struct or id. `{:error, :not_found}` when absent."
  @spec unassign(RoleAssignment.t() | binary()) ::
          {:ok, RoleAssignment.t()} | {:error, :not_found}
  def unassign(%RoleAssignment{id: id}), do: unassign(id)

  def unassign(id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         %RoleAssignment{} = assignment <- Repo.get(RoleAssignment, id) do
      Repo.delete(assignment)
    else
      _ -> {:error, :not_found}
    end
  end

  def unassign(_), do: {:error, :not_found}

  @doc "Every assignment naming `principal`, oldest first. `[]` for an unknown principal shape."
  @spec list_assignments_for(principal()) :: [RoleAssignment.t()]
  def list_assignments_for(principal) do
    case principal(principal) do
      {:ok, {type, id}} ->
        Repo.all(
          from(a in RoleAssignment,
            where: a.principal_type == ^type and a.principal_id == ^id,
            order_by: [asc: a.id]
          )
        )

      {:error, _} ->
        []
    end
  end

  # ── internals ─────────────────────────────────────────────────────────

  defp mint_key, do: @custom_prefix <> Platform.Types.UUIDv7.generate()

  defp fetch_custom(%Role{builtin: true}), do: {:error, :builtin}
  defp fetch_custom(%Role{key: key}), do: fetch_custom(key)

  defp fetch_custom(key) when is_binary(key) do
    case get_role(key) do
      nil -> {:error, :role_not_found}
      %Role{builtin: true} -> {:error, :builtin}
      %Role{} = role -> {:ok, role}
    end
  end

  defp fetch_custom(_), do: {:error, :role_not_found}

  defp fetch_assignable(role) do
    case fetch_custom(role) do
      {:error, :builtin} -> {:error, :builtin_not_assignable}
      other -> other
    end
  end

  defp assignment_org(%Role{org_id: org_id}, nil) when is_binary(org_id), do: {:ok, org_id}
  defp assignment_org(%Role{org_id: org_id}, org_id) when is_binary(org_id), do: {:ok, org_id}
  defp assignment_org(_role, _other), do: {:error, :org_mismatch}

  defp principal(%User{id: id}), do: principal({:user, id})
  defp principal(%Agent{id: id}), do: principal({:agent, id})
  defp principal(%AgentRuntime{agent_id: id}) when is_binary(id), do: principal({:agent, id})

  defp principal({type, id}) when type in [:user, :agent] and is_binary(id) do
    if Platform.UUID.valid?(id),
      do: {:ok, {Atom.to_string(type), id}},
      else: {:error, :invalid_principal}
  end

  defp principal(_), do: {:error, :invalid_principal}

  defp principal_may_hold("user", user_id, org_id) do
    internal? =
      Repo.exists?(
        from(m in OrgMembership,
          where: m.user_id == ^user_id and m.org_id == ^org_id and m.external == false
        )
      )

    if internal?, do: :ok, else: {:error, :no_membership}
  end

  defp principal_may_hold("agent", agent_id, _org_id) do
    if Repo.exists?(from(a in Agent, where: a.id == ^agent_id)),
      do: :ok,
      else: {:error, :agent_not_found}
  end
end
