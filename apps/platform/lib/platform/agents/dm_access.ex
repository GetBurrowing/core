defmodule Platform.Agents.DmAccess do
  @moduledoc """
  Who in the org may open a direct message with an agent (task 01a19776).

  Each agent carries a `dm_policy`:

    * `"everyone"` (the default and the migration backfill): any internal
      member, which is the behaviour before this setting existed.
    * `"admins"`: the agent's admins and owners only.
    * `"specific"`: admins, owners, and the people listed in
      `agent_dm_allowed_users`.

  "Admin" is not a new notion: it is `Platform.Access.Agents.manage?/2`, the
  same gate the Control Center uses for agent edits. "Owner" is any
  `agent_runtimes.owner_user_id` for the agent, read by `agent_id` and by the
  legacy `agents.runtime_id`. It is checked on its own so an owner is always
  allowed even without agents-module access, which `manage?/2` requires of an
  owner.

  `permitted?/2` decides for an INTERNAL initiator only. It does not judge
  external users: Chat composes it after `Platform.Chat.external_dm_permitted?/3`,
  so an external user named in the list stays refused. This module must not
  call back into `Platform.Chat`.

  The policy is written only through `set_policy/4`, gated on `manage?/2`.
  Keep it off the MCP/tool surface: agents authenticate as an install admin, so
  `manage?/2` is vacuously true for them.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Platform.Access.Agents, as: AgentAccess
  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentDmAllowedUser, AgentRuntime}
  alias Platform.Repo
  alias Platform.Tenancy

  @type summary :: %{
          policy: String.t(),
          owners: [%{id: binary(), name: String.t() | nil}],
          people: [%{id: binary(), name: String.t() | nil}]
        }

  @doc "The accepted `dm_policy` values."
  @spec policies() :: [String.t()]
  def policies, do: Agent.valid_dm_policies()

  @doc """
  May the internal user `user_id` DM `agent`?

  Order: policy `"everyone"` answers true with no further query; then an
  owner, then an admin (`Platform.Access.Agents.manage?/2`); then, only under
  `"specific"`, a row in the allowed list. Anything else, an unknown agent, or
  a malformed id is false.
  """
  @spec permitted?(binary() | nil, Agent.t() | binary() | nil) :: boolean()
  def permitted?(user_id, %Agent{dm_policy: "everyone"}) when is_binary(user_id), do: true

  def permitted?(user_id, %Agent{} = agent) when is_binary(user_id) do
    Platform.UUID.valid?(user_id) and
      (owner?(agent, user_id) or admin?(agent, user_id) or listed?(agent, user_id))
  end

  def permitted?(user_id, agent_id) when is_binary(user_id) and is_binary(agent_id) do
    case get_agent(agent_id) do
      nil -> false
      agent -> permitted?(user_id, agent)
    end
  end

  def permitted?(_user_id, _agent), do: false

  @doc "Every runtime owner of `agent`, by `agent_id` and by the legacy `runtime_id`."
  @spec owner_ids(Agent.t()) :: [binary()]
  def owner_ids(%Agent{id: agent_id, runtime_id: runtime_id}) do
    query =
      from(r in AgentRuntime,
        where: not is_nil(r.owner_user_id),
        select: r.owner_user_id,
        distinct: true
      )

    query =
      if is_binary(runtime_id),
        do: where(query, [r], r.agent_id == ^agent_id or r.id == ^runtime_id),
        else: where(query, [r], r.agent_id == ^agent_id)

    Repo.all(query)
  end

  @doc "The user ids on `agent`'s specific-people list (kept whatever the policy)."
  @spec allowed_user_ids(Agent.t()) :: [binary()]
  def allowed_user_ids(%Agent{id: agent_id}) do
    Repo.all(
      from(a in AgentDmAllowedUser,
        where: a.agent_id == ^agent_id,
        order_by: [asc: a.inserted_at, asc: a.id],
        select: a.user_id
      )
    )
  end

  @doc "The policy, the owners and the listed people of `agent`, named, for the UI."
  @spec summary(Agent.t()) :: summary()
  def summary(%Agent{} = agent) do
    owners = owner_ids(agent)
    people = allowed_user_ids(agent)
    names = names(owners ++ people)

    %{
      policy: agent.dm_policy || "everyone",
      owners: named(owners, names),
      people: named(people, names)
    }
  end

  @doc """
  Set `agent`'s policy, and with a list of `user_ids` replace its allowed
  people, in one transaction.

  Only a scope that `Platform.Access.Agents.manage?/2` admits may do this;
  anyone else gets `{:error, :forbidden}` and nothing is written. `user_ids`
  of `nil` leaves the list untouched, so flipping the policy away from
  `"specific"` and back restores it. An external user, a malformed id or an
  unknown user in the list is a changeset error on `:allowed_user_ids`.
  """
  @spec set_policy(Scope.t(), Agent.t(), String.t(), [binary()] | nil) ::
          {:ok, Agent.t()} | {:error, :forbidden | Changeset.t()}
  def set_policy(scope, agent, policy, user_ids \\ nil)

  def set_policy(%Scope{} = scope, %Agent{} = agent, policy, user_ids)
      when is_nil(user_ids) or is_list(user_ids) do
    if AgentAccess.manage?(scope, agent) do
      do_set_policy(agent, policy, user_ids)
    else
      {:error, :forbidden}
    end
  end

  def set_policy(_scope, _agent, _policy, _user_ids), do: {:error, :forbidden}

  defp do_set_policy(agent, policy, user_ids) do
    changeset =
      agent
      |> Agent.dm_policy_changeset(policy)
      |> validate_user_ids(user_ids)

    Repo.transaction(fn ->
      with {:ok, updated} <- Repo.update(changeset) do
        if is_list(user_ids), do: replace_allowed(updated, Enum.uniq(user_ids))
        updated
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp validate_user_ids(changeset, nil), do: changeset

  defp validate_user_ids(changeset, user_ids) do
    ids = Enum.uniq(user_ids)

    cond do
      not Enum.all?(ids, &Platform.UUID.valid?/1) ->
        Changeset.add_error(changeset, :allowed_user_ids, "contains an invalid id")

      length(existing_user_ids(ids)) != length(ids) ->
        Changeset.add_error(changeset, :allowed_user_ids, "contains an unknown user")

      MapSet.size(Tenancy.external_user_ids(ids)) > 0 ->
        Changeset.add_error(changeset, :allowed_user_ids, "cannot include external users")

      true ->
        changeset
    end
  end

  defp existing_user_ids([]), do: []

  defp existing_user_ids(ids),
    do: Repo.all(from(u in User, where: u.id in ^ids, select: u.id))

  defp replace_allowed(%Agent{id: agent_id}, user_ids) do
    Repo.delete_all(from(a in AgentDmAllowedUser, where: a.agent_id == ^agent_id))
    now = DateTime.utc_now()

    rows =
      Enum.map(user_ids, fn user_id ->
        %{
          id: Platform.Types.UUIDv7.generate(),
          agent_id: agent_id,
          user_id: user_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows != [], do: Repo.insert_all(AgentDmAllowedUser, rows)
    :ok
  end

  defp owner?(agent, user_id), do: user_id in owner_ids(agent)

  defp admin?(agent, user_id) do
    case Accounts.get_user(user_id) do
      nil -> false
      user -> AgentAccess.manage?(Scope.for_user(user), agent)
    end
  end

  defp listed?(%Agent{dm_policy: "specific", id: agent_id}, user_id) do
    Repo.exists?(
      from(a in AgentDmAllowedUser, where: a.agent_id == ^agent_id and a.user_id == ^user_id)
    )
  end

  defp listed?(_agent, _user_id), do: false

  defp get_agent(agent_id) do
    if Platform.UUID.valid?(agent_id), do: Repo.get(Agent, agent_id)
  end

  defp names([]), do: %{}

  defp names(ids) do
    Map.new(Repo.all(from(u in User, where: u.id in ^Enum.uniq(ids), select: {u.id, u.name})))
  end

  defp named(ids, names), do: Enum.map(ids, &%{id: &1, name: Map.get(names, &1)})
end
