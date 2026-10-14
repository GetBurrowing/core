defmodule Platform.Access do
  @moduledoc """
  The public façade for RBAC v2 authorization (task `01a1386d-cb5c`, stack
  `rbac-roles`; `0058-rbac-v2-roles-scopes-and-agent-capping.md § Permission model`).

  `Platform.Access` is the one owner of the decision. `scope_for/1` builds a
  `%Platform.Access.Scope{}` for an actor, and `can?/3` and `permitted_ids/2`
  answer from it. Every check goes through `Platform.Access.Scope`, so there is
  one decision point and no second gate beside it.

  ## Nothing in production consumes a Scope yet

  Stack member 2 builds the Scope and assigns it as `:access_scope`
  (`PlatformWeb.LiveAuth.on_mount(:default)`, `PlatformWeb.Plugs.RequireAuth`).
  No gate reads it for a decision. Later members (resource scoping, rail
  gating, agent capping) consume it.

  ## Built-in roles are read once and cached

  `builtin_roles/0` reads the `builtin: true` rows of `access_roles` from the
  Repo on first use and keeps them in `:persistent_term`, so building a Scope
  on the hot path (every request, every socket mount) issues no role query.
  The rows are written only by the stage-1 migration, which seeds them; nothing
  edits them at runtime. Custom roles (stack position 8) are NOT cached here:
  the member that makes roles editable must add invalidation (or replace this
  cache) in the same change. An empty read is never cached.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Access.{Role, Scope}
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo

  @cache_key {__MODULE__, :builtin_roles}

  @doc """
  Build the Scope for an actor: an `%AgentRuntime{}` goes through
  `Scope.for_runtime/1`, anything else through `Scope.for_user/1` (which fails
  closed for `nil` and any non-user input).
  """
  @spec scope_for(term()) :: Scope.t()
  def scope_for(%AgentRuntime{} = runtime), do: Scope.for_runtime(runtime)
  def scope_for(user), do: Scope.for_user(user)

  @doc "See `Platform.Access.Scope.can?/3`."
  @spec can?(Scope.t(), String.t(), term()) :: boolean()
  def can?(scope, permission, resource \\ nil), do: Scope.can?(scope, permission, resource)

  @doc "See `Platform.Access.Scope.permitted_ids/2`."
  @spec permitted_ids(Scope.t(), String.t()) :: :all | [binary()]
  def permitted_ids(scope, permission), do: Scope.permitted_ids(scope, permission)

  @doc "The built-in `access_roles` rows (admin, guest, member), ordered by key. Cached."
  @spec builtin_roles() :: [Role.t()]
  def builtin_roles do
    case :persistent_term.get(@cache_key, nil) do
      nil -> load_builtin_roles()
      roles -> roles
    end
  end

  @doc "The built-in roles as `%{key => permissions}`, from the cache."
  @spec builtin_role_rules() :: %{String.t() => map()}
  def builtin_role_rules, do: Map.new(builtin_roles(), &{&1.key, &1.permissions})

  @doc "Drop the built-in role cache. The next `builtin_roles/0` re-reads the Repo."
  @spec reset_builtin_roles_cache() :: :ok
  def reset_builtin_roles_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp load_builtin_roles do
    roles = Repo.all(from(r in Role, where: r.builtin, order_by: r.key))

    if roles != [], do: :persistent_term.put(@cache_key, roles)

    roles
  end
end
