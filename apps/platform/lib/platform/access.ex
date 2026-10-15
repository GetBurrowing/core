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

  ## Precedence lives here, and only here
  (task `01a1386d-e528` stage 2,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`)

  `can?/3` and `permitted/3` (and `Platform.Access.Query.where_permitted/5`,
  which consumes `permitted/3`) are the one place grant effects decide
  anything. The order is the ADR's steps 3, 4, 6 and 7 (steps 1, 2 and 5 are
  members 2, 5 and 8):

    1. collect the explicit DENIES of the actor's principals for exactly
       this permission on the resource or on any resource above it on a
       downward edge (`Platform.Access.Lineage`);
    2. any deny → refuse;
    3. else a role-rule allow (member 2's `Scope`), or an explicit ALLOW on
       the resource or above it → permit;
    4. else refuse.

  Step 1 of the ADR (install level) is honoured without code here: a grant
  can never name an install-level permission (`Platform.Access.Grant`), so
  `install.admin` always takes the grant-less path, which is member 2's
  root-admin rule.

  **No grants means member 2's answer.** When the Scope carries no grant for
  the requested permission, `can?/3` returns `Scope.can?/3` for the same
  arguments, before any lineage is read. `permitted_ids/2` is member 2's
  function, unchanged in shape and meaning: the ROLE-RULE set
  (`:all | [id]`). It does not read grants and must not be used to filter
  rows once grants exist. The grant-aware set form is the new
  `permitted/3`, which returns a `%Platform.Access.Permitted{}` (the shape
  change is carried by a new function so every caller of member 2's shape
  keeps compiling and passing).

  **Resource forms.** A typed resource (`{:project, id}`, `{:task, id}`,
  `{:stack, id}`, `{:space, id}`, `{:canvas, id}`, `{:memory, path}`,
  `{:memory, path, at}`, `{:memory_node, id}`) is decided with full
  inheritance, and its role-rule allow reads the ids a rule could name for
  it (`Lineage.base_candidates/1`: its id, its org, a canvas's space). A
  `%Project{}`, `%Task{}`, `%Stack{}`, `%Space{}` or `%Canvas{}` struct gets
  the same inheritance for grants but keeps member 2's role-rule reading of
  the struct, so adding a grant can only add that grant's effect. A bare id
  or untyped map has no type to walk, so only grants naming exactly that id
  apply to it. `nil` ("anywhere") is permitted by a role rule or by any
  allow; a deny on one resource does not refuse "anywhere".

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

  alias Platform.Access.{Grant, Lineage, Permitted, Role, Scope}
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

  @doc """
  Does `scope` hold `permission` over `resource`, with explicit grants
  applied (deny wins, inheritance downward only)? See the moduledoc for the
  resource forms. With no grant for `permission` on the Scope this is
  exactly `Platform.Access.Scope.can?/3`.
  """
  @spec can?(Scope.t(), String.t(), term()) :: boolean()
  def can?(scope, permission, resource \\ nil)

  def can?(%Scope{actor: :system}, _permission, _resource), do: true

  def can?(%Scope{} = scope, permission, resource) when is_binary(permission) do
    case applicable(scope, permission) do
      [] -> role_allows?(scope, permission, resource)
      grants -> decide(scope, permission, resource, grants)
    end
  end

  def can?(scope, permission, resource), do: Scope.can?(scope, permission, resource)

  @doc """
  Member 2's ROLE-RULE set: `:all`, or the resource ids a role rule names.
  It does not read grants (see the moduledoc); use `permitted/3` to filter.
  See `Platform.Access.Scope.permitted_ids/2`.
  """
  @spec permitted_ids(Scope.t(), String.t()) :: :all | [binary()]
  def permitted_ids(scope, permission), do: Scope.permitted_ids(scope, permission)

  @doc """
  The grant-aware set form of `can?/3` for every resource of `type`
  (`:project`, `:task`, `:stack`, `:space`, `:canvas`, or `:memory_page` /
  `:memory_node`). See `Platform.Access.Permitted` for how to read it;
  `Platform.Access.Query.where_permitted/5` turns it into a query condition.
  """
  @spec permitted(Scope.t(), String.t(), atom()) :: Permitted.t()
  def permitted(%Scope{actor: :system}, permission, type),
    do: %Permitted{resource_type: permitted_type(type), permission: permission, allow: :all}

  def permitted(%Scope{} = scope, permission, type) when type in [:memory_page, :memory_node] do
    {allows, denies} = split(applicable(scope, permission))

    allow =
      case Scope.permitted_ids(scope, permission) do
        :all -> :all
        _ids -> node_ids(allows)
      end

    %Permitted{
      resource_type: :memory_node,
      permission: permission,
      allow: allow,
      deny: node_ids(denies)
    }
  end

  def permitted(%Scope{} = scope, permission, type) when is_binary(permission) do
    unless type in Lineage.id_types(),
      do: raise(ArgumentError, "unknown resource type for permitted/3: #{inspect(type)}")

    {allows, denies} = split(applicable(scope, permission))

    allow =
      case Scope.permitted_ids(scope, permission) do
        :all ->
          :all

        ids ->
          from_roles =
            case {ids, Scope.kind_admitted(scope, permission)} do
              {[], []} -> []
              {ids, kinds} -> Lineage.base_ids(type, ids, kinds)
            end

          Enum.uniq(from_roles ++ Lineage.descendant_ids(type, targets(allows)))
      end

    %Permitted{
      resource_type: type,
      permission: permission,
      allow: allow,
      deny: Lineage.descendant_ids(type, targets(denies))
    }
  end

  @doc """
  Does any grant of `scope`'s principals name `permission`? `false` means
  every grant-aware answer for `permission` is member 2's role-rule answer
  (or, for `within?/4` and `Platform.Access.Query.restrict/5`, the caller's
  existing check), so a caller may skip the grant work entirely.
  """
  @spec grants_apply?(Scope.t(), String.t()) :: boolean()
  def grants_apply?(%Scope{} = scope, permission) when is_binary(permission),
    do: applicable(scope, permission) != []

  def grants_apply?(_scope, _permission), do: false

  @doc """
  The EXPLICIT-GRANT part of `permitted/3`: `allow` holds only the ids an
  allow grant covers (no role rule), `deny` the ids a deny covers, both
  expanded down the inheritance edges (task 01a1386d-e528 stage 3). It is
  what `Platform.Access.Query.restrict/5` composes with a surface's existing
  check, which stands in for the role-rule allow.
  """
  @spec granted(Scope.t(), String.t(), atom()) :: Permitted.t()
  def granted(%Scope{} = scope, permission, type)
      when type in [:memory_page, :memory_node] and is_binary(permission) do
    # Memory (task 01a1386d-e528 stage 4): the NODE ids the explicit allows
    # and denies name, not expanded, read as `permitted/3` reads them.
    {allows, denies} = split(applicable(scope, permission))

    %Permitted{
      resource_type: :memory_node,
      permission: permission,
      allow: node_ids(allows),
      deny: node_ids(denies)
    }
  end

  def granted(%Scope{} = scope, permission, type) when is_binary(permission) do
    unless type in Lineage.id_types(),
      do: raise(ArgumentError, "unknown resource type for granted/3: #{inspect(type)}")

    {allows, denies} = split(applicable(scope, permission))

    %Permitted{
      resource_type: type,
      permission: permission,
      allow: Lineage.descendant_ids(type, targets(allows)),
      deny: Lineage.descendant_ids(type, targets(denies))
    }
  end

  @doc """
  `can?/3` in conjunction with a surface's EXISTING check, for one resource
  (task 01a1386d-e528 stage 3). `base?` is that check's answer; it stands in
  for step 3's role-rule allow. With no grant for `permission` the answer is
  `base?`, so a grant-less scope changes nothing. Otherwise a deny on the
  resource or above it refuses, then `base?` or an explicit allow on the
  resource or above it permits. The single-resource form of
  `Platform.Access.Query.restrict/5`.
  """
  @spec within?(Scope.t(), String.t(), term(), boolean()) :: boolean()
  def within?(%Scope{} = scope, permission, resource, base?)
      when is_binary(permission) and is_boolean(base?) do
    case applicable(scope, permission) do
      [] ->
        base?

      grants ->
        {allows, denies} = split(matching(resource, grants))

        cond do
          denies != [] -> false
          base? -> true
          true -> allows != []
        end
    end
  end

  def within?(_scope, _permission, _resource, base?) when is_boolean(base?), do: base?

  @doc """
  The conjunctive point check every bypass surface calls AFTER its own
  existing check has admitted the request (task 01a1386e-45a5 stage 1, stack
  member 7; `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`,
  "The grant-less short-circuit"): `:ok`, or `{:error, :denied}`.

  `resource` is addressed exactly as `can?/3` takes it (`{:project, id}`,
  `{:space, id}`, `{:canvas, id}`, `{:task, id}`, ...), so inheritance is
  `Platform.Access.Lineage`'s: a deny on a project refuses its tasks, their
  execution spaces and the canvases in or attached to them.

  ## Why a scope with no grants returns `:ok`

  Every call site keeps the check it had before this member (participation,
  `Tenancy.member_of?/2`, the MCP org filter) and calls this only once that
  check has admitted. Those existing checks already enforce what the role
  rules restrict, so the only NEW information a Scope can carry is its
  grants. With none, `check/3` has nothing to add and returns `:ok` without
  reading lineage or role rules. That is what keeps "an install with no
  grants behaves exactly as today" true by construction at every site,
  rather than by the role rules happening to agree with each legacy check.

  ## With grants: a deny narrows, an allow adds nothing here

  With grants the answer is `within?(scope, permission, resource, true)`:
  the site's existing check, which has already admitted, stands in for the
  role-rule allow (step 6), and a deny for exactly `permission` on the
  resource or anything above it refuses (steps 3-4). Not `can?/3`: that
  re-derives the role-rule allow from the Scope, which disagrees with the
  legacy checks these sites keep (a runtime's Scope carries no `files.read`
  or `canvas.read` before stack member 5; a guest's carries no `files.read`
  although `member_of?/2` admits it; an org-less project matches no
  `membership_org` rule), so a single unrelated grant would refuse reads
  today's code serves. An allow cannot widen past a check the site still
  runs first, so it can add nothing here.

  The ADR also requires the short-circuit to honour role restrictions
  (`access_space_restrictions`, stack member 8). That table does not exist
  on this member's base; whichever of members 7 and 8 lands second adds the
  restriction lookup HERE, so no site changes.
  """
  @spec check(Scope.t() | nil, String.t(), term()) :: :ok | {:error, :denied}
  def check(scope, permission, resource) when is_binary(permission) do
    cond do
      not Scope.has_grants?(scope) -> :ok
      within?(scope, permission, resource, true) -> :ok
      true -> {:error, :denied}
    end
  end

  # ── precedence ──────────────────────────────────────────────────────────

  defp applicable(%Scope{grants: grants}, permission),
    do: Enum.filter(grants, &(&1.permission == permission))

  defp decide(scope, permission, nil, grants) do
    role_allows?(scope, permission, nil) or Enum.any?(grants, &(&1.effect == "allow"))
  end

  defp decide(scope, permission, resource, grants) do
    {allows, denies} = split(matching(resource, grants))

    cond do
      denies != [] -> false
      role_allows?(scope, permission, resource) -> true
      true -> allows != []
    end
  end

  # The grants naming `resource` or a resource above it on a downward edge
  # (a bare id or untyped map: only grants naming exactly that id).
  defp matching(resource, grants) do
    case Lineage.typed(resource) do
      :untyped ->
        id = untyped_id(resource)
        Enum.filter(grants, &(&1.resource_id == id))

      typed ->
        above = MapSet.new(Lineage.ancestors(typed))
        Enum.filter(grants, &MapSet.member?(above, Grant.target(&1)))
    end
  end

  # Member 2's role-rule answer. A typed tuple reads every id a rule could
  # name for the resource; anything else is member 2's own reading.
  defp role_allows?(scope, permission, resource) when is_tuple(resource) do
    case Lineage.typed(resource) do
      :untyped ->
        Scope.can?(scope, permission, resource)

      typed ->
        Scope.permitted_ids(scope, permission) == :all or
          Enum.any?(Lineage.base_candidates(typed), &Scope.can?(scope, permission, &1))
    end
  end

  defp role_allows?(scope, permission, resource), do: Scope.can?(scope, permission, resource)

  defp split(grants), do: Enum.split_with(grants, &(&1.effect == "allow"))

  defp targets(grants), do: Enum.map(grants, &Grant.target/1)

  defp node_ids(grants),
    do: for(%Grant{resource_type: "memory_node", resource_id: id} <- grants, do: id)

  defp untyped_id(id) when is_binary(id), do: id
  defp untyped_id(%{id: id}), do: id
  defp untyped_id(_), do: nil

  defp permitted_type(type) when type in [:memory_page, :memory_node], do: :memory_node
  defp permitted_type(type), do: type

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
