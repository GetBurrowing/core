defmodule Platform.Access.Scope do
  @moduledoc """
  One `%Scope{}` per actor, built once per request and once per socket
  (task `01a1386d-cb5c` stage 2;
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Permission model`).

      %Scope{actor, org, permissions, role_keys}

    * `actor` — the principal: a user (with `:org_memberships` and nested
      `:org` loaded), an `%AgentRuntime{}`, `{:meeting_invitee, term}`,
      `:system`, or `nil`.
    * `org` — the `%Org{}` of the membership `Tenancy.load_membership/1`
      picks (LiveAuth's `:current_user_org_membership`), or nil.
    * `permissions` — `%{permission => :all | [resource_id]}`.
    * `role_keys` — `%{org_id => MapSet}` of the actor's base role keys
      (`org_memberships.access_role_key`). The ADR names this field for
      stack member 8; it is populated here with base keys only, because the
      decision needs it: guest dominance and the `implicit_or_participant`
      kind admission are both read from it. No other field is added.

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

  Memberships union, `:all` absorbing a list. A rule list may mix resource
  types (canvas: participant space ids and membership org ids); callers pass
  the id the rule names.

  **The participant ids are a BUILD-TIME SNAPSHOT.** A long-lived socket must
  keep filtering through the live `ExternalScope.member_space_ids/1` subquery
  (stack member 2 stage 3), not through this list. The snapshot uses that same
  query, so the two cannot disagree at build time. It is one query, issued only
  when a held rule needs it.

  ## Three rules that are code, not role data

  Each is a named function so a mutation can target it:

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

  ## Runtimes

  `for_runtime/1` translates `allowed_bundles` into the transitional
  `mcp.<bundle>` permissions at `:all`. There is no owner intersection (agent
  capping is stack position 5) and `ToolAuthorization` is not consulted for a
  decision; `tool_names/1` reproduces `ToolAuthorization.effective_tools/1`'s
  composition, in `allowed_bundles` row order. An external-owned runtime's
  `role_keys` carry its owner's guest keys, which marks the scope external.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Access.Registry
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.ExternalScope
  alias Platform.Federation.{ToolAuthorization, ToolSurface}
  alias Platform.Repo
  alias Platform.Tenancy.{Org, OrgMembership}

  defstruct actor: nil, org: nil, permissions: %{}, role_keys: %{}

  @type permission_value :: :all | [binary()]
  @type t :: %__MODULE__{
          actor: term(),
          org: Org.t() | nil,
          permissions: %{String.t() => permission_value()},
          role_keys: %{(binary() | nil) => MapSet.t(String.t())}
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
    participants = participant_snapshot(user_id, contributing, rules)

    permissions =
      contributing
      |> role_permissions(rules, participants)
      |> widen_root_org(memberships)
      |> grant_root_admin(memberships, contributing)

    %__MODULE__{
      actor: user,
      org: primary_org(memberships),
      permissions: permissions,
      role_keys: role_keys(memberships)
    }
  end

  def for_user(_), do: %__MODULE__{}

  @doc """
  The Scope for an agent runtime: one `mcp.<bundle>` permission at `:all` per
  `allowed_bundles` entry the registry declares. No owner intersection.
  """
  @spec for_runtime(AgentRuntime.t()) :: t()
  def for_runtime(%AgentRuntime{} = runtime) do
    permissions =
      for bundle <- bundles(runtime),
          permission = Registry.bundle_permission(bundle),
          into: %{},
          do: {permission, :all}

    role_keys =
      if ToolAuthorization.external_principal?(runtime),
        do: owner_guest_keys(runtime.owner_user_id),
        else: %{}

    %__MODULE__{actor: runtime, permissions: permissions, role_keys: role_keys}
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

  @doc "Does the scope carry the guest restriction (any base role key `guest`)?"
  @spec guest?(t()) :: boolean()
  def guest?(%__MODULE__{role_keys: role_keys}),
    do: Enum.any?(role_keys, fn {_org, keys} -> MapSet.member?(keys, "guest") end)

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

  defp participant_snapshot(user_id, contributing, rules) do
    needed? =
      Enum.any?(contributing, fn membership ->
        rules
        |> Map.get(role_key(membership), %{})
        |> Map.values()
        |> Enum.any?(&participant_rule?/1)
      end)

    if needed? do
      %ExternalScope{user_id: user_id}
      |> ExternalScope.member_space_ids()
      |> Repo.all()
      |> normalize()
    else
      []
    end
  end

  defp role_permissions(memberships, rules, participants) do
    for membership <- memberships,
        {permission, rule} <- Map.get(rules, role_key(membership), %{}),
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
  defp resolve("participant_spaces", _membership, participants), do: participants
  defp resolve("implicit_or_participant", _membership, participants), do: participants
  defp resolve(_unknown, _membership, _participants), do: []

  defp merge(:all, _), do: :all
  defp merge(_, :all), do: :all
  defp merge(a, b) when is_list(a) and is_list(b), do: a ++ b

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

  defp implicit_rule?(%__MODULE__{role_keys: role_keys} = scope, permission) do
    keys =
      if guest?(scope),
        do: ["guest"],
        else: role_keys |> Map.values() |> Enum.flat_map(&MapSet.to_list/1)

    rules = Access.builtin_role_rules()

    Enum.any?(keys, fn key ->
      rules
      |> Map.get(key, %{})
      |> Map.get(permission)
      |> rule_list()
      |> Enum.member?("implicit_or_participant")
    end)
  end

  defp holds_bundle?(scope, bundle) do
    case Registry.bundle_permission(bundle) do
      nil -> false
      permission -> can?(scope, permission)
    end
  end

  defp bundles(%AgentRuntime{allowed_bundles: bundles}) when is_list(bundles), do: bundles
  defp bundles(_runtime), do: []

  defp owner_guest_keys(owner_user_id) when is_binary(owner_user_id) do
    from(m in OrgMembership,
      where: m.user_id == ^owner_user_id and m.external == true,
      select: m.org_id
    )
    |> Repo.all()
    |> Map.new(&{&1, MapSet.new(["guest"])})
  end

  defp owner_guest_keys(_), do: %{}
end
