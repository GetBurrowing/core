defmodule Platform.Roles do
  @moduledoc """
  Context module for the platform-fixed role/responsibility system
  (M4 stage 3 of task `019ef65b-a361-7873-871b-3375bf60ead7`).

  This module is the canonical surface for:

    * Reading the closed roster of `Platform.Roles.Role` records.
    * Querying the role↔responsibility bundle (`bundle_for/1`).
    * Pinning a single agent to a role (`assign_role/2`) — Decision 1
      from the M4 stack: one-agent-per-role, no shared ownership.
    * Overriding a single responsibility at the leaf (`set_override/2`)
      — Decision 3 from the stack: at most one override per
      responsibility key.
    * Resolving "who handles this responsibility?" via `assignee_for/1`
      — the function the rest of the platform calls when it needs to
      route work to an agent.

  ## Decisions baked into this module

  The three decisions from the M4 stack are NOT re-litigated here.
  They're stated and enforced:

    * **Decision 1 — one-agent-per-role.** `assign_role/2` does NOT
      replace an existing assignment. Callers must `unassign_role/1`
      first. Explicit > implicit so accidental hand-offs surface as a
      changeset error rather than a silent overwrite.
    * **Decision 2 — closed role roster.** `Platform.Roles.Role.valid_keys/0`
      is the authoritative list. The schema validates inclusion and
      the DB CHECK enforces it from the other side.
    * **Decision 3 — at most one override per responsibility.**
      `set_override/2` uses `on_conflict: {:replace, [...]}` against
      the `responsibility_key` unique index. Calling it twice with
      different agents is a swap, not a duplicate insertion.

  ## Resolver semantics

  `assignee_for/1` is the workhorse. Resolution order:

    1. If `responsibility_overrides` has a row for `responsibility_key`,
       return the preloaded `%Platform.Agents.Agent{}` from that row.
    2. Else find every role whose bundle contains `responsibility_key`,
       look up the assignment for that role, and return the preloaded
       agent.
    3. Else `nil`.

  Step 2 should produce at most one role per key — M1's responsibilities
  registry is the canonical source and the role bundles are seeded
  disjoint in stage 4. As a defensive guard against drift, we log a
  warning when multiple roles match and return the first.

  No GenServer wiring — this is pure functions over the DB.
  """

  import Ecto.Query

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Roles.ResponsibilityOverride
  alias Platform.Roles.Role
  alias Platform.Roles.RoleAssignment
  alias Platform.Roles.RoleResponsibility

  # ── Role finders ──────────────────────────────────────────────────────

  @doc """
  List every role in the closed roster, ordered by `:key` for stable
  display.

  ## Examples

      iex> roles = Platform.Roles.list_roles()
      iex> Enum.all?(roles, &match?(%Platform.Roles.Role{}, &1))
      true
  """
  @spec list_roles() :: [Role.t()]
  def list_roles do
    Role
    |> order_by([r], asc: r.key)
    |> Repo.all()
  end

  @doc """
  Fetch a role by its natural key (`"designer"`, `"historian"`, …),
  raising on not found. Use when you know the caller has a valid key
  and you want to surface bad data loudly.

  ## Examples

      iex> try do
      ...>   Platform.Roles.get_role!("definitely-not-a-real-role")
      ...> rescue
      ...>   Ecto.NoResultsError -> :raised
      ...> end
      :raised
  """
  @spec get_role!(String.t()) :: Role.t() | no_return()
  def get_role!(key) when is_binary(key), do: Repo.get!(Role, key)

  @doc """
  Fetch a role by its natural key. Returns `nil` if not found — use
  this on UI surfaces where a missing key shouldn't crash the page.

  ## Examples

      iex> Platform.Roles.get_role("definitely-not-a-real-role")
      nil
  """
  @spec get_role(String.t()) :: Role.t() | nil
  def get_role(key) when is_binary(key), do: Repo.get(Role, key)

  @doc """
  Return the bundle of responsibility keys for a role, in stable
  alphabetical order. Returns `[]` for an unknown role rather than
  raising — bundles are sparse by design and "no responsibilities"
  is a valid (if useless) state.

  ## Examples

      iex> Platform.Roles.bundle_for("designer") |> is_list()
      true
  """
  @spec bundle_for(String.t()) :: [String.t()]
  def bundle_for(role_key) when is_binary(role_key) do
    RoleResponsibility
    |> where([rr], rr.role_key == ^role_key)
    |> order_by([rr], asc: rr.responsibility_key)
    |> select([rr], rr.responsibility_key)
    |> Repo.all()
  end

  # ── Assignments ───────────────────────────────────────────────────────

  @doc """
  Pin `agent_id` to `role_key`. Returns `{:ok, %RoleAssignment{}}` on
  success, `{:error, changeset}` if the role is already assigned (the
  unique constraint on `role_key` surfaces as a changeset error) or
  any other DB-level rejection.

  **Does NOT replace** an existing assignment — Decision 1. Callers
  must `unassign_role/1` first if they intend to re-pin.

  ## Examples

      iex> Platform.Roles.assign_role("designer", "00000000-0000-0000-0000-000000000000")
      ...> |> elem(0)
      :error
  """
  @spec assign_role(String.t(), binary()) ::
          {:ok, RoleAssignment.t()} | {:error, Ecto.Changeset.t()}
  def assign_role(role_key, agent_id) when is_binary(role_key) and is_binary(agent_id) do
    %RoleAssignment{}
    |> RoleAssignment.changeset(%{role_key: role_key, agent_id: agent_id})
    |> Repo.insert()
  end

  @doc """
  Remove the assignment for `role_key` if any. Returns `:ok`
  regardless of whether a row existed — idempotent for caller
  ergonomics (use the resolver to verify the post-state if needed).

  ## Examples

      iex> Platform.Roles.unassign_role("definitely-not-a-real-role")
      :ok
  """
  @spec unassign_role(String.t()) :: :ok
  def unassign_role(role_key) when is_binary(role_key) do
    {_count, _} =
      RoleAssignment
      |> where([ra], ra.role_key == ^role_key)
      |> Repo.delete_all()

    :ok
  end

  @doc """
  Return every role the agent currently holds, ordered by `:key`. An
  agent may hold zero, one, or several roles — `RoleAssignment` only
  forbids one-agent-per-role from the role side.

  ## Examples

      iex> Platform.Roles.roles_for("00000000-0000-0000-0000-000000000000")
      []
  """
  @spec roles_for(binary()) :: [Role.t()]
  def roles_for(agent_id) when is_binary(agent_id) do
    from(r in Role,
      join: ra in RoleAssignment,
      on: ra.role_key == r.key,
      where: ra.agent_id == ^agent_id,
      order_by: [asc: r.key]
    )
    |> Repo.all()
  end

  @doc """
  Return the responsibility-key bundle for a role with optional
  filtering.

    * `exclude_overridden: true` — subtracts any keys present in
      `responsibility_overrides`. Used by M7's Show-advanced split
      view, which lists the role's "default" responsibilities
      separately from the ones the operator has overridden.

  Defaults to the same shape as `bundle_for/1`.

  ## Examples

      iex> Platform.Roles.responsibilities_for("designer") |> is_list()
      true

      iex> Platform.Roles.responsibilities_for("designer", exclude_overridden: true)
      ...> |> is_list()
      true
  """
  @spec responsibilities_for(String.t(), keyword()) :: [String.t()]
  def responsibilities_for(role_key, opts \\ []) when is_binary(role_key) do
    bundle = bundle_for(role_key)

    if Keyword.get(opts, :exclude_overridden, false) do
      overridden = MapSet.new(list_overridden_keys())
      Enum.reject(bundle, &MapSet.member?(overridden, &1))
    else
      bundle
    end
  end

  # ── Overrides ─────────────────────────────────────────────────────────

  @doc """
  Set (insert-or-replace) the override for `responsibility_key` so it
  routes to `agent_id`. Decision 3: at most one override per
  responsibility — calling twice with different agents swaps the
  pointer in place.

  Returns `{:ok, %ResponsibilityOverride{}}` on success or
  `{:error, changeset}` on FK / validation rejection.

  ## Examples

      iex> Platform.Roles.set_override("not-real", "00000000-0000-0000-0000-000000000000")
      ...> |> elem(0)
      :error
  """
  @spec set_override(String.t(), binary()) ::
          {:ok, ResponsibilityOverride.t()} | {:error, Ecto.Changeset.t()}
  def set_override(responsibility_key, agent_id)
      when is_binary(responsibility_key) and is_binary(agent_id) do
    %ResponsibilityOverride{}
    |> ResponsibilityOverride.changeset(%{
      responsibility_key: responsibility_key,
      agent_id: agent_id
    })
    |> Repo.insert(
      on_conflict: {:replace, [:agent_id, :updated_at]},
      conflict_target: :responsibility_key
    )
  end

  @doc """
  Delete the override for `responsibility_key` if any. Idempotent —
  returns `:ok` regardless of whether a row existed.

  ## Examples

      iex> Platform.Roles.clear_override("definitely-not-a-real-key")
      :ok
  """
  @spec clear_override(String.t()) :: :ok
  def clear_override(responsibility_key) when is_binary(responsibility_key) do
    {_count, _} =
      ResponsibilityOverride
      |> where([o], o.responsibility_key == ^responsibility_key)
      |> Repo.delete_all()

    :ok
  end

  # ── Resolver ──────────────────────────────────────────────────────────

  @doc """
  The workhorse the rest of the platform calls when it needs to ask
  "which agent should handle `responsibility_key`?".

  Resolution order:

    1. If `responsibility_overrides` has a row for this key, return
       its preloaded `%Platform.Agents.Agent{}`.
    2. Else find the role(s) whose bundle contains the key, look up
       the role assignment, and return the preloaded agent. If
       multiple roles bundle the same key (M1 should prevent this;
       belt + braces) we log a warning and return the first.
    3. Else `nil`.

  Return shape is a preloaded `%Platform.Agents.Agent{}` — no opaque
  tuples — so call sites can pattern-match against the struct or
  forward it as-is to runtime dispatch helpers.

  ## Examples

      iex> Platform.Roles.assignee_for("definitely-not-a-real-key")
      nil
  """
  @spec assignee_for(String.t()) :: Agent.t() | nil
  def assignee_for(responsibility_key) when is_binary(responsibility_key) do
    case lookup_override_agent(responsibility_key) do
      %Agent{} = agent -> agent
      nil -> lookup_role_assigned_agent(responsibility_key)
    end
  end

  # ── Internal helpers ──────────────────────────────────────────────────

  defp lookup_override_agent(responsibility_key) do
    from(o in ResponsibilityOverride,
      where: o.responsibility_key == ^responsibility_key,
      join: a in Agent,
      on: a.id == o.agent_id,
      select: a
    )
    |> Repo.one()
  end

  defp lookup_role_assigned_agent(responsibility_key) do
    agents =
      from(a in Agent,
        join: ra in RoleAssignment,
        on: ra.agent_id == a.id,
        join: rr in RoleResponsibility,
        on: rr.role_key == ra.role_key,
        where: rr.responsibility_key == ^responsibility_key,
        order_by: [asc: ra.role_key],
        select: a
      )
      |> Repo.all()

    case agents do
      [] ->
        nil

      [agent] ->
        agent

      [agent | _rest] ->
        Logger.warning(
          "multiple role bundles match responsibility_key=#{inspect(responsibility_key)}; " <>
            "returning first assignment by role_key order. " <>
            "M1's responsibilities registry should keep bundles disjoint."
        )

        agent
    end
  end

  defp list_overridden_keys do
    ResponsibilityOverride
    |> select([o], o.responsibility_key)
    |> Repo.all()
  end
end
