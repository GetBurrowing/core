defmodule Platform.Goals.SpaceCards do
  @moduledoc "Space cards are addressed by the grant's canvas id, never document props (task 01a1dfc1-dffb)."
  import Ecto.Query
  require Logger
  alias Platform.Accounts.User
  alias Platform.Goals.{Grant, Visibility}
  alias Platform.{Chat, Repo}

  def ensure(actor, goal, space_id) do
    with {:ok, space_id} <- Ecto.UUID.cast(space_id),
         %Grant{} = grant <- grant(actor, goal.id, space_id),
         {:ok, participant} <- Chat.SpaceAccess.authorize_writer(space_id, {:user, actor.id}) do
      if grant.card_canvas_id && Chat.get_canvas(grant.card_canvas_id),
        do: {:ok, grant}, else: create(actor, goal, grant, participant)
    else
      nil -> {:error, :not_linked}
      :error -> {:error, :not_found}
      error -> error
    end
  end

  defp grant(actor, goal_id, space_id) do
    Repo.one(from(gr in Grant,
      join: g in subquery(Visibility.visible_goals(actor)), on: g.id == gr.goal_id,
      where: gr.goal_id == ^goal_id and gr.audience_type == "space" and gr.space_id == ^space_id,
      lock: "FOR UPDATE OF g0"))
  end

  defp create(actor, goal, grant, participant) do
    document = %{"version" => 1, "revision" => 1, "root" => %{
      "id" => "goal", "type" => "goal_space_card", "props" => %{"goal_id" => goal.id}}}
    with {:ok, canvas, message} <- Chat.create_canvas_with_message(grant.space_id, participant.id,
           %{title: "Goal", message_content: "Shared a goal", document: document}),
         {:ok, grant} <- grant |> Ecto.Changeset.change(card_canvas_id: canvas.id) |> Repo.update() do
      case Chat.pin_message({:user, actor.id}, %{space_id: grant.space_id, message_id: message.id}) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("Goals card pin refused: #{inspect(reason)}")
      end
      {:ok, grant}
    end
  end

  def view(actor, canvas_id) do
    with {:ok, canvas_id} <- Ecto.UUID.cast(canvas_id),
         %Chat.Canvas{} <- Chat.get_canvas(canvas_id),
         %Grant{} = grant <- Repo.one(from(gr in Grant,
           join: g in subquery(Visibility.visible_goals(actor)), on: g.id == gr.goal_id,
           where: gr.card_canvas_id == ^canvas_id and gr.audience_type == "space")),
         {:ok, _} <- Chat.SpaceAccess.authorize_writer(grant.space_id, principal(actor)),
         {:ok, card} <- Platform.Goals.describe_goal(actor, grant.goal_id),
         {:ok, number} <- Platform.Goals.goal_number(actor, grant.goal_id),
         {:ok, contributors} <- Platform.Goals.list_contributors(actor, grant.goal_id),
         %{} = space <- Chat.get_space(grant.space_id) do
      directs? = may_direct?(actor, space.id)
      blocker = blocker(actor, card.goal, space)
      {:ok, %{card: card, number: number, space: %{id: space.id, name: space.name},
        handed?: not is_nil(grant.handed_at), contributors: contributors,
        can_hand?: directs? and is_nil(blocker),
        can_take_back?: match?(%User{}, actor) and (card.role == :owner or directs?),
        hand_blocker: if(directs?, do: blocker)}}
    else
      _ -> {:error, :not_found}
    end
  end

  defp principal(%User{id: id}), do: {:user, id}
  defp principal(%Platform.Agents.Agent{id: id}), do: {:agent, id}
  defp principal(_), do: nil
  defp may_direct?(%User{id: id}, space_id),
    do: Platform.Tenancy.root_admin?(%{id: id}) and Chat.participant?(space_id, id)
  defp may_direct?(_, _), do: false
  defp blocker(actor, %{coach_agent_id: nil} = goal, space) do
    if match?(%User{}, actor) and actor.id == goal.owner_user_id do
      case Chat.Sidebar.agents_leader(space) do
        %{id: id} -> if Chat.get_agent_participant(space.id, id), do: nil, else: :coach_not_in_space
        _ -> :no_coach
      end
    else
      :no_coach
    end
  end
  defp blocker(_, goal, space),
    do: if(Chat.get_agent_participant(space.id, goal.coach_agent_id), do: nil, else: :coach_not_in_space)
end
