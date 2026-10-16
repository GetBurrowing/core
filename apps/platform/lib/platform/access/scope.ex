defmodule Platform.Access.Scope do
  @moduledoc """
  One `%Scope{}` per actor, built once per request and once per socket
  (task `01a1386d-cb5c` stage 2;
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Permission model`).

      %Scope{actor, org, permissions, role_keys, grants}

    * `actor` — the principal: a user (with `:org_memberships` and nested
      `:org` loaded), an `%AgentRuntime{}`, `{:meeting_invitee, term}`,
      `:system`, or `nil`.
    * `org` — the `%Org{}` of the membership `Tenancy.load_membership/1`
      picks (LiveAuth's `:current_user_org_membership`), or nil.
    * `permissions` — `%{permission => :all | [resource_id]}`.
    * `role_keys` — `%{org_id => MapSet}` of the actor's role keys: each
      membership's base key (`org_memberships.access_role_key`), unioned
      with every custom role the actor holds through an
      `access_role_assignments` row (task `01a1386e-59d1` stage 1). A user's
      assignments count only in orgs the user has a membership in; a
      runtime's keys are its owner's guest keys plus the AGENT's own
      assignments (never the owner's). Guest dominance and the
      `implicit_or_participant` kind admission read the base keys in it;
      `Platform.Access.holds_role?/3` is the only reader of the custom keys.
    * `grants` — the `%Platform.Access.Grant{}` rows (allow and deny) whose
      principal is this actor (task `01a1386d-e528` stage 2): the user id,
      every `{access_role_key, org_id}` pair of its memberships, or the
      runtime's agent id, plus every role-principal grant of a custom role
      the actor is assigned (task `01a1386e-59d1`). Loaded in ONE query by
      the builders, together with the actor's assignments
      (`Platform.Access.Grants.list_for_actor/3`), as a build-time snapshot
      (live apply is stack position 6). With no rows it
      is `[]`, the field default, so a grant-less Scope is equal to the one
      member 2 built. `can?/3` and `permitted_ids/2` here read role rules
      ONLY; the grant-aware decision is `Platform.Access.can?/3` /
      `Platform.Access.permitted/3`, the one place precedence lives.

  ## Nothing consumes this yet

  No production gate reads a Scope for a decision in this stack member. It is
  built and assigned as `:access_scope` only. That is why `for_user(nil)` can
  fail closed (empty permissions) where `Platform.Chat.ExternalScope.for_user(nil)`
  passes through: no caller's behaviour depends on it. Only `system/0` is
  unrestricted.

  ## How `for_user/1` resolves

  Each membership's `access_role_key` names a built-in role
  (`Platform.Access.builtin_role_rules/0`, cached, no query). Each permission's
  grant rule resolves against that membership:

    * `"all"` → `:all`;
    * `"membership_org"` → the membership's org id (strict membership; root-org
      widening never extends it);
    * `"participant_spaces"` → the user's `chat_participants` space ids;
    * `"implicit_or_participant"` → the same participant ids, PLUS admission
      of every `channel`, `system` and `execution` space by kind
      (`chat_live.ex` `@implicitly_joinable_kinds`). The kind admission is
      not enumerable as ids, so `can?/3` answers it when given the space
      (a map carrying `:kind`), and `permitted_ids/2` returns only the
      participant part, a lower bound;
    * a list of rules → their union.

  **Custom roles** (task `01a1386e-59d1` stage 1) contribute exactly like a
  built-in role: each assignment's role permissions resolve against the
  assignment's org (`membership_org` → that org), and union into
  `permissions`. Guest dominance holds: when any membership maps to
  `guest`, no custom role contributes a permission. A runtime's assigned
  roles contribute KEYS and role grants only, never permissions (an agent's
  reach is its bundles and roster until agent capping, stack position 5).
  With zero assignment rows the permissions and grants are member 2's and
  member 3's, unchanged.

  Memberships union, `:all` absorbing a list. A rule list may mix resource
  types (canvas: participant space ids and membership org ids); callers pass
  the id the rule names.

  **The participant ids are a BUILD-TIME SNAPSHOT.** A long-lived socket must
  keep filtering through the live `ExternalScope.member_space_ids/1` subquery
  (stack member 2 stage 3), not through this list. The snapshot uses that same
  query, so the two cannot disagree at build time. It is one query, issued only
  when a held rule needs it.

  ## Rules that are code, not role data

  Each is a named function so a mutation can target it (task `01a1386d-cb5c`
  stage 4 added the last two, each to reproduce a row the equivalence test
  found today's code answering differently):

    * `guest_dominates/1` — if ANY membership maps to `guest`, only the guest
      memberships contribute role permissions, and the root-admin rule never
      fires. Reproduces `Tenancy.external_user?/1`'s by-user semantics. A
      per-membership union would WIDEN a mixed user's chat reach.
    * `widen_root_org/2` — org visibility, `orgs.read`: `:all` when any
      membership is in a root org (`parent_org_id IS NULL`) at any role,
      otherwise the membership org ids, absent with no memberships. This is
      exactly `Tenancy.visibility/1` (`:root_all` / `{:orgs, ids}` / `:none`)
      and, like it, reads every membership including external ones: guest
      dominance governs role data and the root-admin rule, not visibility
      (the ADR's Presence row keeps an external user's visibility at
      `:root_all`).
    * `grant_root_admin/3` — a non-guest `admin` membership in a root org
      grants `install.admin` and the module-admin permissions at `:all`. It is
      never part of the built-in `admin` role, so a sub-org admin never holds
      it, and guest dominance means an external root admin never holds it
      (`Tenancy.root_admin?/1` ignores `external`; this rule does not).
    * `org_admin_per_membership/3` — the admin-only permissions (`admin` minus
      `member`) come from EVERY internal `admin` membership on its own org,
      after guest dominance. `Tenancy.org_admin?/2` reads one (user, org) row,
      so a mixed user's internal admin row is an org admin today. Guest
      dominance governs the chat / external-scope semantics and root admin,
      not org admin.
    * `no_membership_baseline/1` — a user with no membership is internal
      today: every channel, the whole board, every internal module page. They
      get the whole built-in `member` role, with its own rules, reproduced as
      is (narrowing is resource scoping, stack position 3).

  Guest status for the ExternalScope bridge (`rules_for/2`) is read from the
  same `guest_dominates/1` + `no_membership_baseline/1` sources the
  permissions were built from, never recomputed beside them.

  ## Runtimes

  `for_runtime/1` translates `allowed_bundles` into the transitional
  `mcp.<bundle>` permissions at `:all`. There is no owner intersection (agent
  capping is stack position 5) and `ToolAuthorization` is not consulted for a
  decision; `tool_names/1` reproduces `ToolAuthorization.effective_tools/1`'s
  composition, in `allowed_bundles` row order. An external-owned runtime's
  `role_keys` carry its owner's guest keys, which marks the scope external.
  `chat.read` is the agent's roster (`Chat.list_spaces_for_agent/2`), a
  build-time snapshot: a runtime's chat reach is its participation, as today.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Access.{Grants, Registry, ToolPermissions}
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.ExternalScope
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tenancy.{Org, OrgMembership}

  defstruct actor: nil,
            org: nil,
            permissions: %{},
            role_keys: %{},
            grants: [],
            own_cap: nil,
            owner_cap: nil

  @type permission_value :: :all | [binary()]
  @type t :: %__MODULE__{
          actor: term(),
          org: Org.t() | nil,
          permissions: %{String.t() => permission_value()},
          role_keys: %{(binary() | nil) => MapSet.t(String.t())},
          grants: [Platform.Access.Grant.t()],
          own_cap: t() | nil,
          owner_cap: t() | nil
        }

  @implicit_kinds ~w(channel system execution)
  @participant_rules ~w(participant_spaces implicit_or_participant)

  # ── Builders ────────────────────────────────────────────────────────────

  @doc """
  The Scope for a user. Resolves from preloaded `:org_memberships` (with nested
  `:org`) with no membership, org or role query, and from the Repo otherwise.
  `nil` and any non-user input (e.g. a display-name string) yield the empty,
  fail-closed scope.
  """
  @spec for_user(term()) :: t()
  def for_user(%{id: user_id} = user) when is_binary(user_id) do
    user = with_memberships(user)
    memberships = user.org_memberships
    rules = Access.builtin_role_rules()
    contributing = guest_dominates(memberships)
    sources = rule_sources(memberships, rules)
    participants = participant_snapshot(user_id, sources)
    base_keys = role_keys(memberships)

    {grants, assignments} =
      Grants.list_for_actor([{:user, user_id} | role_principals(base_keys)], {:user, user_id})

    custom = custom_role_sources(assignments, memberships)
    participants = participants || late_participants(user_id, custom)

    permissions =
      (sources ++ custom)
      |> role_permissions(participants || [])
      |> org_admin_per_membership(memberships, rules)
      |> widen_root_org(memberships)
      |> grant_root_admin(memberships, contributing)

    %__MODULE__{
      actor: user,
      org: primary_org(memberships),
      permissions: permissions,
      role_keys: assigned_keys(base_keys, assignments),
      grants: grants
    }
  end

  def for_user(_), do: %__MODULE__{}

  @doc """
  A hypothetical built-in role in `org`, including that role principal's
  grants. It has no user participant spaces, so participant-based chat rules
  resolve to an empty set.
  """
  @spec for_role(Org.t(), String.t()) :: t()
  def for_role(%Org{} = org, role_key) when role_key in ~w(admin member guest) do
    membership = %OrgMembership{
      org_id: org.id,
      org: org,
      role: if(role_key == "guest", do: "member", else: role_key),
      access_role_key: role_key,
      external: role_key == "guest"
    }

    rules = Access.builtin_role_rules()
    memberships = [membership]

    permissions =
      [{Map.get(rules, role_key, %{}), membership}]
      |> role_permissions([])
      |> org_admin_per_membership(memberships, rules)
      |> widen_root_org(memberships)
      |> grant_root_admin(memberships, memberships)

    %__MODULE__{
      actor: %{id: org.id, org_memberships: memberships},
      org: org,
      permissions: permissions,
      role_keys: %{org.id => MapSet.new([role_key])},
      grants: Grants.list_for_principals([{:role, role_key, org.id}])
    }
  end

  @doc """
  The Scope for an agent runtime: one `mcp.<bundle>` permission at `:all` per
  `allowed_bundles` entry the registry declares. No owner intersection.
  """
  @spec for_runtime(AgentRuntime.t()) :: t()
  def for_runtime(%AgentRuntime{} = runtime) do
    legacy_permissions =
      for bundle <- bundles(runtime),
          permission = Registry.bundle_permission(bundle),
          into: %{},
          do: {permission, :all}

    tool_permissions =
      for bundle <- bundles(runtime),
          permission <- ToolPermissions.bundle_permissions(bundle),
          into: %{},
          do: {permission, :all}

    permissions = put_agent_roster(Map.merge(legacy_permissions, tool_permissions), runtime)

    owner =
      case {runtime.owner_user_id, runtime.agent_id} do
        {owner_id, _} when is_binary(owner_id) ->
          %{id: owner_id} |> for_user() |> empty_if_no_membership()

        {nil, agent_id} when is_binary(agent_id) ->
          ownerless_member_scope()

        _ ->
          %__MODULE__{}
      end

    role_keys = if guest?(owner), do: owner.role_keys, else: %{}

    {grants, assignments} =
      Grants.list_for_actor(agent_principals(runtime), agent_actor(runtime))

    own = %__MODULE__{
      actor: runtime,
      permissions: permissions,
      role_keys: assigned_keys(role_keys, assignments),
      grants: grants
    }

    capped = intersect(own, owner)

    # The member-2 equivalence oracle still reads these transitional fields.
    # Tool authorization reads only the module permissions in `capped`.
    legacy = Map.take(permissions, Map.keys(legacy_permissions) ++ ["chat.read"])
    %{capped | permissions: Map.merge(capped.permissions, legacy)}
  end

  @doc "Intersect an agent's own permissions and grants with its owner's scope."
  @spec intersect(t(), t()) :: t()
  def intersect(%__MODULE__{} = own, %__MODULE__{} = owner) do
    permissions =
      for {permission, own_value} <- own.permissions,
          {:ok, owner_value} <- [Map.fetch(owner.permissions, permission)],
          into: %{},
          do: {permission, intersect_value(own_value, owner_value)}

    role_keys =
      if guest?(owner), do: owner.role_keys, else: own.role_keys

    %__MODULE__{
      actor: own.actor,
      org: owner.org,
      permissions: permissions,
      role_keys: role_keys,
      grants: own.grants ++ owner.grants,
      own_cap: own,
      owner_cap: owner
    }
  end

  @doc "A meeting invitee (unauthenticated link-token bearer): empty permissions."
  @spec for_meeting_invitee(term()) :: t()
  def for_meeting_invitee(invite), do: %__MODULE__{actor: {:meeting_invitee, invite}}

  @doc "The explicit unrestricted scope. The only one: every check permits."
  @spec system() :: t()
  def system, do: %__MODULE__{actor: :system}

  # ── Decisions ───────────────────────────────────────────────────────────

  @doc """
  Does `scope` hold `permission` over `resource`?

  `resource` is a resource id, a map carrying `:id` (and `:kind` for a chat
  space), or `nil` meaning "anywhere". `install.admin` is held only through the
  root-admin rule. `system/0` permits everything.
  """
  @spec can?(t(), String.t(), term()) :: boolean()
  def can?(scope, permission, resource \\ nil)

  def can?(%__MODULE__{actor: :system}, _permission, _resource), do: true

  def can?(%__MODULE__{permissions: permissions} = scope, permission, resource)
      when is_binary(permission) do
    case Map.get(permissions, permission) do
      :all -> true
      ids when is_list(ids) -> covers?(ids, resource) or kind_admits?(scope, permission, resource)
      nil -> false
    end
  end

  def can?(_scope, _permission, _resource), do: false

  @doc """
  The set form of `can?/3`: `:all`, or the resource ids held. Empty when not
  held. For `implicit_or_participant` this is the participant snapshot only;
  the kind-admitted spaces are answered by `can?/3` given the space.
  """
  @spec permitted_ids(t(), String.t()) :: :all | [binary()]
  def permitted_ids(%__MODULE__{actor: :system}, _permission), do: :all

  def permitted_ids(%__MODULE__{permissions: permissions}, permission) do
    case Map.get(permissions, permission) do
      :all -> :all
      ids when is_list(ids) -> ids
      nil -> []
    end
  end

  @doc """
  Does the scope CARRY `permission` at all, whatever it resolves to? A
  `membership_org` rule that resolves to `[]` for a user with no org is
  carried. This is the module-level question the rail asks ("may you open
  this module"); which rows inside it are visible is a `can?/3` question.
  """
  @spec carries?(t(), String.t()) :: boolean()
  def carries?(%__MODULE__{actor: :system}, _permission), do: true

  def carries?(%__MODULE__{permissions: permissions}, permission) when is_binary(permission),
    do: Map.has_key?(permissions, permission)

  def carries?(_scope, _permission), do: false

  @doc """
  The rail destination keys this scope declares: every registry rail entry
  whose required permission the scope `carries?/2`. Declared only; nothing
  gates the rail on it yet (rail gating is stack position 4). Callers
  intersect with the destinations actually installed.
  """
  @spec declared_rail(t()) :: [atom()]
  def declared_rail(%__MODULE__{} = scope) do
    for entry <- Registry.rail_entries(), carries?(scope, entry.permission), do: entry.key
  end

  @doc """
  The space kinds the `implicit_or_participant` rule admits for `permission`
  without a participant row: `#{inspect(@implicit_kinds)}` when the scope
  holds `permission` as an id list and a contributing role's rule for it is
  `implicit_or_participant`, else `[]`. The set form of `can?/3`'s kind
  admission, for `Platform.Access.permitted/3`.
  """
  @spec kind_admitted(t(), String.t()) :: [String.t()]
  def kind_admitted(%__MODULE__{permissions: permissions} = scope, permission)
      when is_binary(permission) do
    case Map.get(permissions, permission) do
      ids when is_list(ids) ->
        if implicit_rule?(scope, permission), do: @implicit_kinds, else: []

      _ ->
        []
    end
  end

  @doc """
  Does the scope hold ANY explicit grant row, allow or deny, for any
  permission (task 01a1386e-45a5 stage 1)? True when the `grants` field the
  builders load is non-empty, whichever principal the rows came through: the
  user id, a `{role key, org}` pair of its memberships, or a runtime's agent
  id. `false` for `nil`, `system/0` and every non-Scope value.

  This is the short-circuit `Platform.Access.check/3` reads: a scope with no
  grants is decided by each surface's existing check alone.
  """
  @spec has_grants?(t() | term()) :: boolean()
  def has_grants?(%__MODULE__{grants: [_ | _]}), do: true
  def has_grants?(_scope), do: false

  @doc "Does the scope carry the guest restriction (any base role key `guest`)?"
  @spec guest?(t()) :: boolean()
  def guest?(%__MODULE__{role_keys: role_keys}),
    do: Enum.any?(role_keys, fn {_org, keys} -> MapSet.member?(keys, "guest") end)

  @doc """
  The grant rules the scope's contributing roles carry for `permission`, as a
  flat, de-duplicated list (`[]` when no contributing role carries it). Guest
  dominance picks the contributors exactly as `for_user/1` does: a guest scope
  reads the `guest` role only.

  `Platform.Chat.ExternalScope` reads this to decide whether a Scope's chat
  read is participant-restricted (task `01a1386d-cb5c` stage 3).
  """
  @spec rules_for(t(), String.t()) :: [String.t()]
  def rules_for(%__MODULE__{actor: %{org_memberships: memberships}}, permission)
      when is_list(memberships) and is_binary(permission) do
    memberships
    |> rule_sources(Access.builtin_role_rules())
    |> Enum.flat_map(fn {rule_map, _membership} -> rule_list(Map.get(rule_map, permission)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # A non-user actor (a runtime) has no memberships of its own: its base keys
  # are its owner's guest keys, read from `role_keys`.
  def rules_for(%__MODULE__{role_keys: role_keys} = scope, permission)
      when is_binary(permission) do
    keys =
      if guest?(scope),
        do: ["guest"],
        else: role_keys |> Map.values() |> Enum.flat_map(&MapSet.to_list/1) |> Enum.uniq()

    rules = Access.builtin_role_rules()

    keys
    |> Enum.flat_map(fn key ->
      rules |> Map.get(key, %{}) |> Map.get(permission) |> rule_list()
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  The tool names this scope lists: the held bundles (a runtime's
  `allowed_bundles` in row order) through `ToolSurface.list_tools/1`, then
  `ToolSurface.scope_for_external/2` for a guest scope. The same composition
  as `ToolAuthorization.effective_tools/1`.
  """
  @spec tool_names(t()) :: [String.t()]
  def tool_names(%__MODULE__{actor: actor} = scope) do
    candidates =
      case actor do
        %AgentRuntime{} = runtime -> bundles(runtime)
        _ -> ToolSurface.all_bundles()
      end

    candidates
    |> Enum.filter(&holds_bundle?(scope, &1))
    |> ToolSurface.list_tools()
    |> ToolSurface.scope_for_external(guest?(scope))
    |> Enum.map(& &1.name)
  end

  # ── The three code rules ────────────────────────────────────────────────

  @doc false
  # Guest dominates: any guest membership makes the guest memberships the only
  # contributors of role data.
  @spec guest_dominates([OrgMembership.t()]) :: [OrgMembership.t()]
  def guest_dominates(memberships) do
    case Enum.filter(memberships, &(role_key(&1) == "guest")) do
      [] -> memberships
      guests -> guests
    end
  end

  @doc false
  # No-membership baseline: a user with NO org membership is internal today
  # (`Tenancy.external_user?/1` is false), so they see every channel through
  # the pass-through ExternalScope, the whole, unscoped board, and every
  # internal module page. This returns the built-in `member` role's rules,
  # all of them and with their own rule values, for such a user, and nothing
  # for anyone else. With no membership a `membership_org` rule resolves to
  # no org, so org-fenced reads stay empty as they are today. Reproduced as
  # is; narrowing it belongs to resource scoping (stack position 3).
  @spec no_membership_baseline([OrgMembership.t()]) :: map()
  def no_membership_baseline([]) do
    Map.get(Access.builtin_role_rules(), "member", %{})
  end

  def no_membership_baseline(_memberships), do: %{}

  @doc false
  # Org admin is per membership: every internal `admin` membership grants the
  # admin-only permissions (the built-in `admin` role minus `member`) on its
  # own org, whatever guest dominance did to the rest of the actor's role
  # data. Reproduces `Tenancy.org_admin?/2`, which reads one (user, org) row
  # and is true for a mixed user's internal admin row.
  @spec org_admin_per_membership(map(), [OrgMembership.t()], map()) :: map()
  def org_admin_per_membership(permissions, memberships, rules) do
    admin = Map.get(rules, "admin", %{})
    admin_only = Map.drop(admin, Map.keys(Map.get(rules, "member", %{})))

    for membership <- memberships,
        role_key(membership) == "admin",
        {permission, rule} <- admin_only,
        reduce: permissions do
      acc ->
        value = normalize(resolve(rule, membership, []))
        Map.update(acc, permission, value, &normalize(merge(&1, value)))
    end
  end

  @doc false
  # Root-org widening: org visibility as `Tenancy.visibility/1` computes it.
  @spec widen_root_org(map(), [OrgMembership.t()]) :: map()
  def widen_root_org(permissions, memberships) do
    cond do
      Enum.any?(memberships, &root_org_membership?/1) ->
        Map.put(permissions, "orgs.read", :all)

      memberships == [] ->
        permissions

      true ->
        Map.put(permissions, "orgs.read", normalize(Enum.map(memberships, & &1.org_id)))
    end
  end

  @doc false
  # Root admin: a non-guest admin membership in a root org. `contributing` is
  # the output of `guest_dominates/1`, so a user with any guest row never fires.
  @spec grant_root_admin(map(), [OrgMembership.t()], [OrgMembership.t()]) :: map()
  def grant_root_admin(permissions, memberships, contributing) do
    guest? = Enum.any?(memberships, &(role_key(&1) == "guest"))

    root_admin? =
      not guest? and
        Enum.any?(contributing, &(role_key(&1) == "admin" and root_org_membership?(&1)))

    if root_admin? do
      (Registry.install_level_permissions() ++ Registry.module_admin_permissions())
      |> Enum.reduce(permissions, &Map.put(&2, &1, :all))
    else
      permissions
    end
  end

  # ── Internals ───────────────────────────────────────────────────────────

  defp with_memberships(%{org_memberships: memberships} = user) when is_list(memberships) do
    if Enum.all?(memberships, &match?(%OrgMembership{org: %Org{}}, &1)),
      do: user,
      else: %{user | org_memberships: Repo.preload(memberships, :org)}
  end

  # Same preload `Accounts.get_user/1` runs, so the two paths agree.
  defp with_memberships(%_{org_memberships: _} = user),
    do: Repo.preload(user, org_memberships: :org)

  defp with_memberships(%{id: user_id} = user) do
    memberships = Repo.all(from(m in OrgMembership, where: m.user_id == ^user_id, preload: :org))
    Map.put(user, :org_memberships, memberships)
  end

  # The generated column. An unloaded key on an external row fails closed to
  # guest; on an internal row it contributes no role.
  defp role_key(%OrgMembership{access_role_key: key}) when is_binary(key), do: key
  defp role_key(%OrgMembership{external: true}), do: "guest"
  defp role_key(_), do: nil

  defp root_org_membership?(%OrgMembership{org: %Org{parent_org_id: nil}}), do: true
  defp root_org_membership?(_), do: false

  defp primary_org([%OrgMembership{org: %Org{} = org} | _]), do: org
  defp primary_org(_), do: nil

  defp role_keys(memberships) do
    Enum.reduce(memberships, %{}, fn membership, acc ->
      case role_key(membership) do
        nil ->
          acc

        key ->
          Map.update(acc, membership.org_id, MapSet.new([key]), &MapSet.put(&1, key))
      end
    end)
  end

  # The role data that contributes to a user's permissions: each membership
  # `guest_dominates/1` keeps, with its role's rules, plus the
  # `no_membership_baseline/1` rules (membership `nil`). `for_user/1` and
  # `rules_for/2` both read this, so the ExternalScope bridge takes guest
  # status from the same path the permissions were built from.
  defp rule_sources(memberships, rules) do
    from_roles =
      for membership <- guest_dominates(memberships),
          do: {Map.get(rules, role_key(membership), %{}), membership}

    from_roles ++ [{no_membership_baseline(memberships), nil}]
  end

  # The participant ids when a held rule needs them, else `nil` (not
  # loaded). `for_user/1` issues the query before the grants query, and only
  # issues it again after (`late_participants/2`) when the base roles did not
  # need it and a custom role does.
  defp participant_snapshot(user_id, sources) do
    needed? =
      Enum.any?(sources, fn {rule_map, _membership} ->
        rule_map |> Map.values() |> Enum.any?(&participant_rule?/1)
      end)

    if needed? do
      %ExternalScope{user_id: user_id}
      |> ExternalScope.member_space_ids()
      |> Repo.all()
      |> normalize()
    else
      nil
    end
  end

  defp late_participants(_user_id, []), do: nil
  defp late_participants(user_id, custom), do: participant_snapshot(user_id, custom)

  # Custom-role role data (task `01a1386e-59d1` stage 1): one source per
  # assignment, resolved against the assignment's org exactly as a built-in
  # role resolves against its membership's org. Guest dominance: when any
  # membership maps to `guest`, no custom role contributes a permission, so a
  # guest is never widened (their keys are still recorded in `role_keys`).
  defp custom_role_sources(assignments, memberships) do
    if Enum.any?(memberships, &(role_key(&1) == "guest")) do
      []
    else
      for %{org_id: org_id, permissions: permissions} <- assignments,
          is_map(permissions),
          do: {permissions, %OrgMembership{org_id: org_id}}
    end
  end

  # Base keys unioned with every assigned custom key, per org.
  defp assigned_keys(base_keys, assignments) do
    Enum.reduce(assignments, base_keys, fn %{org_id: org_id, role_key: key}, acc ->
      Map.update(acc, org_id, MapSet.new([key]), &MapSet.put(&1, key))
    end)
  end

  defp role_permissions(sources, participants) do
    for {rule_map, membership} <- sources,
        {permission, rule} <- rule_map,
        reduce: %{} do
      acc ->
        value = resolve(rule, membership, participants)
        Map.update(acc, permission, value, &merge(&1, value))
    end
    |> Map.new(fn {permission, value} -> {permission, normalize(value)} end)
  end

  defp resolve(rules, membership, participants) when is_list(rules),
    do: rules |> Enum.map(&resolve(&1, membership, participants)) |> Enum.reduce(&merge/2)

  defp resolve("all", _membership, _participants), do: :all
  defp resolve("membership_org", %OrgMembership{org_id: org_id}, _participants), do: [org_id]
  defp resolve("membership_org", nil, _participants), do: []
  defp resolve("participant_spaces", _membership, participants), do: participants
  defp resolve("implicit_or_participant", _membership, participants), do: participants
  defp resolve(_unknown, _membership, _participants), do: []

  defp merge(:all, _), do: :all
  defp merge(_, :all), do: :all
  defp merge(a, b) when is_list(a) and is_list(b), do: a ++ b

  defp intersect_value(:all, value), do: value
  defp intersect_value(value, :all), do: value

  defp intersect_value(own, owner) when is_list(own) and is_list(owner),
    do:
      own
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(owner))
      |> MapSet.to_list()
      |> Enum.sort()

  # `for_user/1` retains the internal user's legacy no-membership baseline.
  # Runtime ownership is stricter: no membership cannot authorize a tool.
  defp empty_if_no_membership(%__MODULE__{actor: %{org_memberships: []}} = scope),
    do: %{scope | permissions: %{}, grants: []}

  defp empty_if_no_membership(scope), do: scope

  # A synthetic runtime built for a local, ownerless agent tool call has no
  # database runtime row. Its bound is the built-in member vocabulary.
  defp ownerless_member_scope do
    permissions =
      Access.builtin_role_rules()
      |> Map.get("member", %{})
      |> Map.new(fn {permission, _rule} -> {permission, :all} end)

    %__MODULE__{permissions: permissions}
  end

  defp normalize(:all), do: :all

  defp normalize(ids) when is_list(ids),
    do: ids |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()

  defp participant_rule?(rule), do: Enum.any?(rule_list(rule), &(&1 in @participant_rules))

  defp rule_list(rule) when is_list(rule), do: rule
  defp rule_list(rule), do: [rule]

  defp covers?(ids, nil), do: ids != []
  defp covers?(ids, id) when is_binary(id), do: id in ids
  defp covers?(ids, %{id: id}) when is_binary(id), do: id in ids
  defp covers?(_ids, _resource), do: false

  # `implicit_or_participant`: the contributing roles' rule for `permission`
  # admits a space of an implicitly joinable kind without a participant row.
  defp kind_admits?(scope, permission, resource) do
    kind_ok? =
      case resource do
        nil -> true
        %{kind: kind} -> kind in @implicit_kinds
        _ -> false
      end

    kind_ok? and implicit_rule?(scope, permission)
  end

  defp implicit_rule?(scope, permission),
    do: "implicit_or_participant" in rules_for(scope, permission)

  defp holds_bundle?(scope, bundle) do
    case Registry.bundle_permission(bundle) do
      nil -> false
      permission -> can?(scope, permission)
    end
  end

  # A runtime's chat reach is its agent's participation, as today: the spaces
  # `Chat.list_spaces_for_agent/2` returns, as a build-time snapshot. No owner
  # cap (stack position 5).
  defp put_agent_roster(permissions, %AgentRuntime{agent_id: agent_id})
       when is_binary(agent_id) do
    roster = agent_id |> Platform.Chat.list_spaces_for_agent() |> Enum.map(& &1.id)
    Map.put(permissions, "chat.read", normalize(roster))
  end

  defp put_agent_roster(permissions, _runtime), do: permissions

  # The grant principals of a user's memberships: one per (role key, org).
  defp role_principals(role_keys) do
    for {org_id, keys} <- role_keys, is_binary(org_id), key <- Enum.sort(keys) do
      {:role, key, org_id}
    end
  end

  # An agent's grants are its OWN (no owner intersection: stack position 5).
  defp agent_principals(%AgentRuntime{agent_id: agent_id}) when is_binary(agent_id),
    do: [{:agent, agent_id}]

  defp agent_principals(_runtime), do: []

  defp agent_actor(%AgentRuntime{agent_id: agent_id}) when is_binary(agent_id),
    do: {:agent, agent_id}

  defp agent_actor(_runtime), do: nil

  defp bundles(%AgentRuntime{allowed_bundles: bundles}) when is_list(bundles), do: bundles
  defp bundles(_runtime), do: []
end
