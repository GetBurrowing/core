defmodule Platform.Goals.SpaceCardTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.{Chat, Goals}

  setup do
    enable_goals!()
    org = org_id!()
    owner = root_admin!()
    join_org!(owner, org)
    viewer = member!(org)
    coach = agent!()
    space = space!(org)
    participant = join_space!(space.id, :user, owner.id)
    join_space!(space.id, :user, viewer.id)
    join_space!(space.id, :agent, coach.id)
    goal = goal!(owner, org, %{coach_agent_id: coach.id, source_key: "self_reported", unit: "pieces", target_value: 300})
    {:ok, _} = Goals.open_goal(owner, goal.id, {:space, space.id})
    %{org: org, owner: owner, viewer: viewer, coach: coach, space: space, goal: goal, participant: participant}
  end

  test "one canvas one owner message and one pin, idempotent with fixed copy", c do
    before = counts()
    assert {:ok, grant} = Goals.ensure_space_card(c.owner, c.goal.id, c.space.id)
    assert counts() == Enum.map(before, &(&1 + 1))
    canvas = Chat.get_canvas(grant.card_canvas_id)
    assert canvas.title == "Goal"
    assert canvas.document["root"]["type"] == "goal_space_card"
    assert canvas.document["root"]["props"] == %{"goal_id" => c.goal.id}
    message = Repo.one!(from(m in Chat.Message, where: m.canvas_id == ^canvas.id))
    assert message.content == "Shared a goal"
    assert message.participant_id == c.participant.id
    assert {:ok, ^grant} = Goals.ensure_space_card(c.owner, c.goal.id, c.space.id)
    assert counts() == Enum.map(before, &(&1 + 1))
  end

  test "owner authority and visibility are checked before any card writes", c do
    before = counts()
    assert {:error, :forbidden} = Goals.ensure_space_card(c.viewer, c.goal.id, c.space.id)
    assert {:error, :forbidden} = Goals.ensure_space_card(c.coach, c.goal.id, c.space.id)
    assert {:error, :not_found} = Goals.ensure_space_card(user!(), c.goal.id, c.space.id)
    assert {:error, :not_linked} = Goals.ensure_space_card(c.owner, c.goal.id, space!(c.org).id)
    assert counts() == before
  end

  test "canvas identity and current space participation gate content", c do
    {:ok, grant} = Goals.ensure_space_card(c.owner, c.goal.id, c.space.id)
    assert {:ok, view} = Goals.space_card(c.viewer, grant.card_canvas_id)
    assert view.card.goal.id == c.goal.id
    refute view.can_hand?
    assert {:ok, %{can_hand?: true}} = Goals.space_card(c.owner, grant.card_canvas_id)
    assert {:ok, %{can_hand?: false}} = Goals.space_card(c.coach, grant.card_canvas_id)
    assert {:error, :not_found} = Goals.space_card(user!(), grant.card_canvas_id)
    outsider = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, outsider.id})
    assert {:error, :not_found} = Goals.space_card(outsider, grant.card_canvas_id)
    other = space!(c.org)
    author = join_space!(other.id, :user, outsider.id)
    {:ok, lookalike, _} = Chat.create_canvas_with_message(other.id, author.id, %{title: "Goal", document: Chat.get_canvas(grant.card_canvas_id).document})
    assert {:error, :not_found} = Goals.space_card(outsider, lookalike.id)
    {:ok, _} = Goals.close_goal(c.owner, c.goal.id, {:space, c.space.id})
    assert {:error, :not_found} = Goals.space_card(c.owner, grant.card_canvas_id)
    assert {:error, :not_found} = Goals.space_card(c.viewer, grant.card_canvas_id)
  end

  test "closing and reopening uses a new card", c do
    {:ok, first} = Goals.ensure_space_card(c.owner, c.goal.id, c.space.id)
    {:ok, _} = Goals.close_goal(c.owner, c.goal.id, {:space, c.space.id})
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, c.space.id})
    {:ok, second} = Goals.ensure_space_card(c.owner, c.goal.id, c.space.id)
    refute first.card_canvas_id == second.card_canvas_id
    assert {:error, :not_found} = Goals.space_card(c.owner, first.card_canvas_id)
  end

  test "missing canvas is not shown and is recreated", c do
    {:ok, first} = Goals.ensure_space_card(c.owner, c.goal.id, c.space.id)
    Repo.delete!(Chat.get_canvas(first.card_canvas_id))
    assert {:error, :not_found} = Goals.space_card(c.owner, first.card_canvas_id)
    assert {:ok, second} = Goals.ensure_space_card(c.owner, c.goal.id, c.space.id)
    refute first.card_canvas_id == second.card_canvas_id
  end

  defp counts, do: Enum.map([Chat.Canvas, Chat.Message, Chat.Pin], &Repo.aggregate(&1, :count))
end
