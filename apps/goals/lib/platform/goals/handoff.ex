defmodule Platform.Goals.Handoff do
  @moduledoc """
  Handing a shared goal to a space's agents (task 01a1dfc1-dffb, Goals 7/8
  stage 1). Called only through `Platform.Goals.hand_goal_to_space/3`,
  `take_goal_back/3` and `list_contributors/2`, which check the switch, load
  the goal through `Platform.Goals.Visibility.visible_goals/1` (locked, in
  the context's own transaction, for the two writes) and pass it here.

  The hand-off lives ON the space grant (`goal_grants.handed_at`): there is
  no second link. A goal is linked to a space only by `open_goal/3`, the
  owner's act; this module never creates a grant, never adds anyone to a
  space, and closing the goal to the space (`close_goal/3` deletes the
  grant) removes the hand-off with it.

  Who may hand: a user who passes BOTH `Platform.Tenancy.root_admin?/1` and
  `Platform.Chat.participant?/2` for the space, core's rule for who may
  point a channel's agents at a goal. Owning the goal is neither needed nor
  enough. Taking back is that user or the owner.

  Contributors are derived on every call, never stored: the agent
  participants of every space whose grant for the goal is handed, with an
  active agent row, the coach excluded. An agent that leaves the space stops
  being a contributor at once.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Goals.{Goal, Grant, Visibility}
  alias Platform.Repo

  @type contributor :: %{
          agent_id: binary(),
          name: String.t(),
          space_id: binary(),
          space_name: String.t()
        }

  @doc false
  @spec hand(term(), Goal.t(), boolean(), term()) ::
          {:ok, %{goal: Goal.t(), grant: Grant.t()}} | {:error, atom()}
  def hand(actor, %Goal{} = goal, owner?, raw_space_id) do
    with {:ok, space_id} <- cast_id(raw_space_id),
         {:ok, grant} <- space_grant(actor, goal, space_id),
         :ok <- check_may_direct(actor, space_id),
         {:ok, goal} <- ensure_coach(actor, goal, owner?, space_id),
         :ok <- check_coach_in_space(goal, space_id) do
      mark_handed(actor, goal, grant)
    end
  end

  @doc false
  @spec take_back(term(), Goal.t(), boolean(), term()) ::
          {:ok, %{goal: Goal.t(), grant: Grant.t()}} | {:error, atom()}
  def take_back(actor, %Goal{} = goal, owner?, raw_space_id) do
    with {:ok, space_id} <- cast_id(raw_space_id),
         {:ok, grant} <- space_grant(actor, goal, space_id),
         :ok <- if(owner?, do: :ok, else: check_may_direct(actor, space_id)) do
      clear_handed(goal, grant)
    end
  end

  @doc false
  @spec contributors(term(), Goal.t()) :: [contributor()]
  def contributors(actor, %Goal{} = goal) do
    spaces =
      Repo.all(
        from(gr in Grant,
          join: g in subquery(Visibility.visible_goals(actor)),
          on: g.id == gr.goal_id,
          join: s in Platform.Chat.Space,
          on: s.id == gr.space_id,
          where:
            gr.goal_id == ^goal.id and gr.audience_type == "space" and
              not is_nil(gr.handed_at),
          order_by: [asc: s.name, asc: s.id],
          select: {s.id, s.name}
        )
      )

    memberships =
      for {space_id, space_name} <- spaces,
          participant <- Platform.Chat.list_participants(space_id, participant_type: "agent"),
          do: {participant.participant_id, space_id, space_name || ""}

    names = active_agent_names(memberships, goal.coach_agent_id)

    memberships
    |> Enum.filter(fn {agent_id, _, _} -> Map.has_key?(names, agent_id) end)
    |> Enum.uniq_by(fn {agent_id, _, _} -> agent_id end)
    |> Enum.map(fn {agent_id, space_id, space_name} ->
      %{
        agent_id: agent_id,
        name: Map.fetch!(names, agent_id),
        space_id: space_id,
        space_name: space_name
      }
    end)
    |> Enum.sort_by(&{String.downcase(&1.name), &1.agent_id})
  end

  defp active_agent_names([], _coach_id), do: %{}

  defp active_agent_names(memberships, coach_id) do
    ids = memberships |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> List.delete(coach_id)

    from(a in Agent, where: a.id in ^ids and a.status == "active", select: {a.id, a.name})
    |> Repo.all()
    |> Map.new(fn {id, name} -> {id, name || ""} end)
  end

  # The goal's grant for this space, read from the actor's visible goals and
  # locked so a concurrent hand and take-back serialise.
  defp space_grant(actor, goal, space_id) do
    grant =
      Repo.one(
        from(gr in Grant,
          join: g in subquery(Visibility.visible_goals(actor)),
          on: g.id == gr.goal_id,
          where:
            gr.goal_id == ^goal.id and gr.audience_type == "space" and gr.space_id == ^space_id,
          lock: "FOR UPDATE OF g0"
        )
      )

    if grant, do: {:ok, grant}, else: {:error, :not_linked}
  end

  defp check_may_direct(%User{id: user_id}, space_id) when is_binary(user_id) do
    if Platform.Tenancy.root_admin?(%{id: user_id}) and
         Platform.Chat.participant?(space_id, user_id),
       do: :ok,
       else: {:error, :forbidden}
  end

  defp check_may_direct(_actor, _space_id), do: {:error, :forbidden}

  defp ensure_coach(_actor, %Goal{coach_agent_id: id} = goal, _owner?, _space_id)
       when is_binary(id),
       do: {:ok, goal}

  # Setting the coach stays the owner's: it goes through update_goal/3, the
  # same path the owner's own edit takes, so the clock is synced.
  defp ensure_coach(actor, goal, true, space_id) do
    case Platform.Chat.Sidebar.agents_leader(Platform.Chat.get_space(space_id)) do
      %Agent{id: leader_id} ->
        Platform.Goals.update_goal(actor, goal.id, %{coach_agent_id: leader_id})

      _ ->
        {:error, :no_coach}
    end
  end

  defp ensure_coach(_actor, _goal, _owner?, _space_id), do: {:error, :no_coach}

  defp check_coach_in_space(goal, space_id) do
    case Platform.Chat.get_agent_participant(space_id, goal.coach_agent_id) do
      nil -> {:error, :coach_not_in_space}
      _participant -> :ok
    end
  end

  defp mark_handed(_actor, goal, %Grant{handed_at: %DateTime{}} = grant),
    do: {:ok, %{goal: goal, grant: grant}}

  defp mark_handed(%User{id: user_id}, goal, grant) do
    grant
    |> Ecto.Changeset.change(handed_at: Platform.Goals.Clock.now(), handed_by_user_id: user_id)
    |> Grant.name_constraints()
    |> Repo.update()
    |> with_goal(goal)
  end

  defp clear_handed(goal, %Grant{handed_at: nil} = grant), do: {:ok, %{goal: goal, grant: grant}}

  defp clear_handed(goal, grant) do
    grant
    |> Ecto.Changeset.change(handed_at: nil, handed_by_user_id: nil)
    |> Grant.name_constraints()
    |> Repo.update()
    |> with_goal(goal)
  end

  defp with_goal({:ok, grant}, goal), do: {:ok, %{goal: goal, grant: grant}}
  defp with_goal(error, _goal), do: error

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
