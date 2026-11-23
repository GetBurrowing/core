defmodule Platform.Goals.Conversation do
  @moduledoc """
  Each goal's own conversation space (task 01a20939 stage 1).

  The space is the New goal conversation the goal was set up in: at confirm,
  `Platform.Goals.Proposals.confirm_proposal/3` points
  `goals.conversation_space_id` at the proposal's space, so onboarding is the
  first history in it. A goal with no proposal (seeded, handed off, or made
  with `Platform.Goals.create_goal/2` directly) gets one lazily, through
  `ensure_space/1`. Migration 20261123180100 links the goals confirmed before
  this release.

  It is a `kind: "dm"`, `is_direct: false` space with metadata
  `"surface" => "goals"`: core's generic "owned by another surface" marker,
  which `Platform.Chat.rail_visible?/1` reads to keep the space out of the
  chat rail, its unread badge, the command palette and the app API. Kind dm
  keeps core's DM routing; `is_direct: false` keeps it out of
  `Platform.Chat.find_or_create_dm/3`. A goal's space also carries
  `"goal_id"` in its metadata.

  Members are the goal's OWNER and its CURRENT COACH, nobody else, ever:

    * sharing a goal (user, team or space grants) adds no one, and
      contributor agents are never added;
    * the space is NEVER recorded as a `goal_grants` row. Visibility rule 4
      (`Platform.Goals.Visibility`) would then make every participant a
      goal viewer;
    * on a coach change (`members_sync/2`, from `Platform.Goals`'s update
      path) the old coach's participant row is deleted and the new coach is
      added with `history_visible_from` set to now, so a later coach
      inherits no history. chat_participants has no `left_at` column:
      leaving is deleting the row.

  Nothing here checks who is asking: callers decide that first. Logger and
  telemetry, where any, carry ids only.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{Participant, Space}
  alias Platform.Goals.{Goal, GoalClock}
  alias Platform.Repo

  @surface "goals"

  @doc """
  Creates a goals conversation space in `org_id` with `user` and `agent` as
  its only participants (`agent` may be nil for a coachless goal), metadata
  `"surface" => "goals"` merged with `extra_metadata`. Run it inside the
  caller's transaction, so a refused write leaves no space behind.
  """
  @spec create_space(User.t(), Agent.t() | nil, binary(), map()) ::
          {:ok, Space.t()} | {:error, term()}
  def create_space(%User{} = user, agent, org_id, extra_metadata \\ %{})
      when is_map(extra_metadata) do
    metadata = Map.merge(Map.new(extra_metadata, fn {k, v} -> {to_string(k), v} end), surface())

    with {:ok, space} <-
           Chat.create_space(%{
             kind: "dm",
             is_direct: false,
             name: space_name(metadata),
             created_by: user.id,
             org_id: org_id,
             metadata: metadata
           }),
         :ok <- add_member(space, "user", user.id, user.name || user.email || "User"),
         :ok <- maybe_add_agent(space, agent, nil) do
      {:ok, space}
    end
  end

  @doc """
  Links `space_id` to `goal` as its conversation: sets
  `goals.conversation_space_id` and merges `"goal_id"` into the space's
  metadata. Run it inside the caller's transaction.
  """
  @spec link(Goal.t(), binary()) :: {:ok, Goal.t()} | {:error, term()}
  def link(%Goal{} = goal, space_id) when is_binary(space_id) do
    with %Space{} = space <- Repo.get(Space, space_id),
         {:ok, _space} <- tag(space, goal.id) do
      goal
      |> Ecto.Changeset.change(conversation_space_id: space.id)
      |> Goal.name_constraints()
      |> Ecto.Changeset.unique_constraint(:conversation_space_id)
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  The goal's live conversation space, created if it has none (or its space
  was archived or deleted). Idempotent and safe to call concurrently: in one
  transaction it locks the goal's clock row and then the goal row
  (`FOR UPDATE`, the lock order of `Platform.Goals.update_goal/3`), so two
  callers serialise and the second finds the first one's space. Should a
  write still lose on the unique index, the goal is re-read and the
  winner's space returned.
  """
  @spec ensure_space(Goal.t()) :: {:ok, Space.t()} | {:error, term()}
  def ensure_space(%Goal{id: goal_id}) when is_binary(goal_id) do
    result =
      Repo.transaction(fn ->
        lock_clock(goal_id)

        case lock_goal(goal_id) do
          nil -> Repo.rollback(:not_found)
          goal -> ensure_locked(goal)
        end
      end)

    case result do
      {:ok, %Space{} = space} -> {:ok, space}
      {:error, %Ecto.Changeset{} = changeset} -> lost_race(goal_id, changeset)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_locked(goal) do
    case live_space(goal.conversation_space_id) do
      %Space{} = space ->
        space

      nil ->
        with {:ok, space} <- new_space(goal),
             {:ok, _goal} <- set_space(goal, space) do
          space
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp lost_race(goal_id, changeset) do
    if Keyword.has_key?(changeset.errors, :conversation_space_id) do
      with %Goal{conversation_space_id: id} when is_binary(id) <- Repo.get(Goal, goal_id),
           %Space{} = space <- live_space(id) do
        {:ok, space}
      else
        _ -> {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  defp new_space(%Goal{} = goal) do
    case Repo.get(User, goal.owner_user_id) do
      %User{} = owner ->
        create_space(owner, coach(goal), goal.org_id, %{"goal_id" => goal.id})

      nil ->
        {:error, :not_found}
    end
  end

  defp set_space(goal, space) do
    goal
    |> Ecto.Changeset.change(conversation_space_id: space.id)
    |> Goal.name_constraints()
    |> Ecto.Changeset.unique_constraint(:conversation_space_id)
    |> Repo.update()
  end

  @doc """
  Brings the goal's space membership back to owner + current coach after a
  coach change (`old_coach_id` was the coach before it). Deletes every
  participant row that is not the owner or the current coach (the old
  coach's included), and adds the new coach with `history_visible_from` now,
  so it reads nothing written before it joined. A goal with no space has
  nothing to sync: its space, when made, starts with the current coach.
  Run it inside the update's transaction.
  """
  @spec members_sync(Goal.t(), binary() | nil) :: :ok | {:error, term()}
  def members_sync(%Goal{conversation_space_id: nil}, _old_coach_id), do: :ok

  def members_sync(%Goal{coach_agent_id: same}, same), do: :ok

  def members_sync(%Goal{conversation_space_id: space_id} = goal, _old_coach_id) do
    rows = Chat.list_participants(space_id)

    with :ok <- remove_others(rows, goal) do
      coach = coach(goal)

      if coach && not Enum.any?(rows, &member?(&1, "agent", coach.id)) do
        maybe_add_agent(%Space{id: space_id}, coach, DateTime.utc_now())
      else
        :ok
      end
    end
  end

  @doc """
  The goal's conversation members, owner first: `[%{type: "user" | "agent",
  id, display_name}]`. Empty when the goal has no space yet.
  """
  @spec members(Goal.t()) :: [%{type: String.t(), id: binary(), display_name: String.t()}]
  def members(%Goal{conversation_space_id: nil}), do: []

  def members(%Goal{conversation_space_id: space_id}) do
    space_id
    |> Chat.list_participants()
    |> Enum.sort_by(&if(&1.participant_type == "user", do: 0, else: 1))
    |> Enum.map(
      &%{type: &1.participant_type, id: &1.participant_id, display_name: &1.display_name}
    )
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp surface, do: %{"surface" => @surface}

  defp space_name(%{"goal_id" => _}), do: "Goal"
  defp space_name(_metadata), do: "New goal"

  defp tag(%Space{} = space, goal_id) do
    Chat.update_space(space, %{metadata: Map.put(space.metadata || %{}, "goal_id", goal_id)})
  end

  defp live_space(nil), do: nil

  defp live_space(space_id) do
    Repo.one(from(s in Space, where: s.id == ^space_id and is_nil(s.archived_at)))
  end

  # The lock order of update_goal/3: clock, then goal. A goal that was never
  # ticked has no clock row; locking the goal still serialises callers.
  defp lock_clock(goal_id) do
    Repo.one(from(c in GoalClock, where: c.goal_id == ^goal_id, lock: "FOR UPDATE"))
  end

  defp lock_goal(goal_id) do
    Repo.one(from(g in Goal, where: g.id == ^goal_id, lock: "FOR UPDATE"))
  end

  defp coach(%Goal{coach_agent_id: nil}), do: nil
  defp coach(%Goal{coach_agent_id: id}), do: Repo.get(Agent, id)

  defp member?(%Participant{participant_type: type, participant_id: id}, type, id), do: true
  defp member?(_row, _type, _id), do: false

  defp remove_others(rows, goal) do
    rows
    |> Enum.reject(
      &(member?(&1, "user", goal.owner_user_id) or member?(&1, "agent", goal.coach_agent_id))
    )
    |> Enum.reduce_while(:ok, fn row, :ok ->
      case Chat.remove_participant(row) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_add_agent(_space, nil, _history_from), do: :ok

  defp maybe_add_agent(space, %Agent{} = agent, history_from),
    do: add_member(space, "agent", agent.id, agent.name, history_from)

  defp add_member(space, type, id, display_name, history_from \\ nil) do
    case Chat.add_participant(space.id, %{
           participant_type: type,
           participant_id: id,
           display_name: display_name,
           joined_at: DateTime.utc_now(),
           history_visible_from: history_from
         }) do
      {:ok, _participant} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
