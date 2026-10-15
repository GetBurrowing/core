defmodule Platform.Access.Delegation do
  @moduledoc """
  Who may CHANGE a grant (task 01a1386e-30bd stage 2, RBAC stack member 6;
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Delegation and audit`).

  This module decides who may change a grant. It never decides what a grant
  MEANS: every permission check below is a call to `Platform.Access.can?/3`,
  and no grant's effect is weighed against another's. The one place a row's
  `effect` is read here is to classify the CHANGE (does adding or removing
  this row widen or narrow access), never to decide access. Precedence lives
  only in `Platform.Access`.

  ## `authorize/2`

  `Platform.Access.Changes` calls it inside the change's transaction with
  the change's actual row diff (`%{added: snapshots, removed: snapshots}`,
  `Platform.Access.Grant.snapshot/1` maps), so what is authorized is exactly
  what the change does. An undo is therefore authorized as its inverse change
  without a separate path: its added rows are the restored `before`, its
  removed rows the original `after`. The actor's scope is a build-time
  snapshot, so checking it after the mutation reads the same answer as
  before it. The rules, per row on resource R with permission p:

    * every row needs `can?(actor, "access.manage", R)`. That inherits
      DOWNWARD through `Platform.Access.Lineage`: a manager of project P
      manages its tasks' execution spaces and canvases. Nothing flows
      upward;
    * an added ALLOW also needs `can?(actor, p, R)`: nobody grants beyond
      what they hold (granting `access.manage` itself included);
    * an added DENY needs `access.manage` only, because it narrows;
    * a removed ALLOW needs `access.manage` only; a removed DENY widens
      access, so it is checked like an added allow;
    * an added row's `org_id` must equal R's owning org (the org
      `Platform.Access.Grants` would derive), and a role principal must name
      a built-in role (roles carry no org until stack position 8, so the
      role is that org's role exactly when the org binding holds).

  A root admin (`install.admin`) is authorized for every change, as an
  audited bypass: `{:ok, :root_admin_bypass}`, recorded `bypass:
  "root_admin"` on the ledger row. The org binding still applies; it is a
  data-integrity rule, not a permission. `Scope.system/0` is the operator
  path and is not checked here.

  ## The last-manager guard

  `manager_baseline/1` (before the mutation) and `ensure_manager_remains/2`
  (after it, before the ledger row) refuse a change that leaves a resource
  that HAD one or more managers with none. A user manages R iff
  `can?(Scope.for_user(user), "access.manage", R)`, over the users holding a
  membership in R's org plus the user principals of `access.manage` grants
  in it. Root-admin bypass does not count: a sub-org's managers are its own.

  Only resources carrying an `access.manage` row in the change are checked: a
  grant or deny applies to its own permission only, so no other row can
  change who manages anything. R's ORG is not checked separately: grants
  cannot name an org (`Platform.Access.Grant` resource types), so no grant
  change moves who manages the org itself; that is a membership question.

  **Org-role demotion is NOT guarded here, deliberately.** The only demotion
  code is `Platform.Tenancy.revoke_admin/2`, the operator/IEx path, and it
  has no human- or agent-facing caller (`SignInAdmin`'s private `set_role/3`
  runs only on invite). `test/platform/access/delegation_test.exs` pins that
  no `PlatformWeb` or MCP module calls it.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Access.{Registry, Scope}
  alias Platform.Accounts.User
  alias Platform.Chat.{Canvas, Space}
  alias Platform.Org.Wiki.Node
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  @manage "access.manage"

  @typedoc "A refusal: the permission missing, on which resource, and why."
  @type denial :: %{
          missing: String.t(),
          resource: {atom(), binary()},
          rule: :not_granted | :beyond_held | :last_admin | :org_mismatch
        }

  @typedoc "A change as rows: `Grant.snapshot/1` maps added and removed."
  @type change_spec :: %{added: [map()], removed: [map()]}

  # ── authorize ─────────────────────────────────────────────────────────

  @doc """
  May `actor` (a `%Scope{}`) make `change_spec`? See the moduledoc.
  `:ok`, `{:ok, :root_admin_bypass}` or `{:error, denial}`.
  """
  @spec authorize(Scope.t(), change_spec()) ::
          :ok | {:ok, :root_admin_bypass} | {:error, denial()}
  def authorize(%Scope{actor: :system}, _spec), do: :ok

  def authorize(%Scope{} = actor, %{} = spec) do
    added = Map.get(spec, :added, [])
    removed = Map.get(spec, :removed, [])

    with :ok <- first_error(added, &bound_to_org/1) do
      if root_admin?(actor) do
        {:ok, :root_admin_bypass}
      else
        with :ok <- first_error(added, &row_allowed?(actor, &1, :added)) do
          first_error(removed, &row_allowed?(actor, &1, :removed))
        end
      end
    end
  end

  @doc "Is `scope` a root admin (holds `install.admin`)? The bypass, never a manager."
  @spec root_admin?(Scope.t()) :: boolean()
  def root_admin?(%Scope{actor: :system}), do: false
  def root_admin?(%Scope{} = scope), do: Access.can?(scope, "install.admin")

  # An added allow or a removed deny widens access: access.manage AND p.
  # An added deny or a removed allow narrows it: access.manage only.
  defp row_allowed?(actor, %{"effect" => effect, "permission" => permission} = row, side) do
    resource = resource(row)

    cond do
      not Access.can?(actor, @manage, resource) ->
        {:error, denial(@manage, resource, :not_granted)}

      widens?(effect, side) and not Access.can?(actor, permission, resource) ->
        {:error, denial(permission, resource, :beyond_held)}

      true ->
        :ok
    end
  end

  defp widens?("allow", :added), do: true
  defp widens?("deny", :removed), do: true
  defp widens?(_effect, _side), do: false

  defp bound_to_org(%{"org_id" => org_id} = row) do
    resource = resource(row)

    cond do
      org_id != resource_org_id(resource) ->
        {:error, denial(row["permission"], resource, :org_mismatch)}

      row["principal_type"] == "role" and
          row["principal_role_key"] not in Registry.builtin_role_keys() ->
        {:error, denial(row["permission"], resource, :org_mismatch)}

      true ->
        :ok
    end
  end

  defp first_error(rows, fun) do
    Enum.find_value(rows, :ok, fn row ->
      case fun.(row) do
        :ok -> nil
        {:error, _} = error -> error
      end
    end)
  end

  defp denial(permission, resource, rule),
    do: %{missing: permission, resource: resource, rule: rule}

  # ── the last-manager guard ────────────────────────────────────────────

  @doc """
  The resources among `resources` (`{type, id}` pairs, or `Grant.snapshot/1`
  maps, whose `access.manage` rows are the only ones that count) that have at
  least one manager now. Call it before the mutation; pass the result to
  `ensure_manager_remains/2` after it.
  """
  @spec manager_baseline([{atom(), binary()} | map()]) :: [{atom(), binary()}]
  def manager_baseline(resources) do
    resources
    |> Enum.flat_map(&managed_resource/1)
    |> Enum.uniq()
    |> Enum.filter(&has_manager?/1)
  end

  @doc """
  `:ok` when every resource in `baseline` (from `manager_baseline/1`) still
  has a manager, else `{:error, %{rule: :last_admin, …}}` naming the first
  one that has none. `_opts` is reserved.
  """
  @spec ensure_manager_remains([{atom(), binary()}], keyword()) :: :ok | {:error, denial()}
  def ensure_manager_remains(baseline, _opts \\ []) do
    case Enum.reject(baseline, &has_manager?/1) do
      [] -> :ok
      [resource | _] -> {:error, denial(@manage, resource, :last_admin)}
    end
  end

  @doc """
  The users who manage `resource` (`can?(Scope.for_user(u), "access.manage",
  resource)`), over R's org's members and the user principals of its
  `access.manage` grants. Root-admin bypass is not counted.
  """
  @spec managers({atom(), binary()}) :: [User.t()]
  def managers(resource), do: Enum.filter(candidates(resource), &manages?(&1, resource))

  defp has_manager?(resource), do: Enum.any?(candidates(resource), &manages?(&1, resource))

  defp manages?(user, {:org, id}), do: Access.can?(Scope.for_user(user), @manage, id)
  defp manages?(user, resource), do: Access.can?(Scope.for_user(user), @manage, resource)

  defp managed_resource({type, id} = resource) when is_atom(type) and is_binary(id),
    do: [resource]

  defp managed_resource(%{"permission" => @manage} = row), do: [resource(row)]
  defp managed_resource(_row), do: []

  # Org members first, admins first among them, so `Enum.any?/2` usually
  # stops at the first scope it builds.
  defp candidates(resource) do
    org_id = resource_org_id(resource)

    member_ids =
      Repo.all(
        from(m in OrgMembership,
          where: m.org_id == ^org_id,
          order_by: [desc: m.role == "admin", asc: m.inserted_at],
          select: m.user_id
        )
      )

    grantee_ids =
      Repo.all(
        from(g in Platform.Access.Grant,
          where:
            g.org_id == ^org_id and g.principal_type == "user" and g.permission == @manage and
              g.effect == "allow",
          select: g.principal_id
        )
      )

    ids = Enum.uniq(member_ids ++ grantee_ids)

    users =
      Repo.all(
        from(u in User,
          where: u.id in ^ids and is_nil(u.archived_at),
          preload: [org_memberships: :org]
        )
      )
      |> Map.new(&{&1.id, &1})

    for id <- ids, user = Map.get(users, id), do: user
  end

  # ── resources ─────────────────────────────────────────────────────────

  defp resource(%{"resource_type" => type, "resource_id" => id}),
    do: {String.to_existing_atom(type), id}

  # R's owning org, derived exactly as `Platform.Access.Grants` derives a
  # grant's `org_id`: the project's, the space's, the canvas's space's, the
  # node's, falling back to the install's root org when that is NULL.
  defp resource_org_id({:org, id}), do: id

  defp resource_org_id({:project, id}),
    do: Repo.one(from(p in Project, where: p.id == ^id, select: p.org_id)) || root_org_id()

  defp resource_org_id({:space, id}),
    do: Repo.one(from(s in Space, where: s.id == ^id, select: s.org_id)) || root_org_id()

  defp resource_org_id({:canvas, id}) do
    Repo.one(
      from(c in Canvas,
        left_join: s in Space,
        on: s.id == c.space_id,
        where: c.id == ^id,
        select: s.org_id
      )
    ) || root_org_id()
  end

  defp resource_org_id({:memory_node, id}),
    do: Repo.one(from(n in Node, where: n.id == ^id, select: n.org_id)) || root_org_id()

  defp root_org_id do
    case Platform.Tenancy.get_root_org() do
      %{id: id} -> id
      nil -> nil
    end
  end
end
