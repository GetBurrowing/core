defmodule Platform.Goals.BriefLinkTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  setup do: setup_brief()

  test "delivery date is reader scoped and still requires visibility and addressing", c do
    reader = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})
    ask = queued(c, %{addressed_user_ids: [reader.id]})
    assert {:ok, nil} = Goals.ask_brief_date(reader, ask.id)
    assert {:error, :not_found} = Goals.ask_brief_date(c.owner, ask.id)
    assert {:ok, _} = Goals.prepare_brief(reader, date())
    day = date()
    assert {:ok, ^day} = Goals.ask_brief_date(reader, ask.id)
    {:ok, _} = Goals.close_goal(c.owner, c.goal.id, {:user, reader.id})
    assert {:error, :not_found} = Goals.ask_brief_date(reader, ask.id)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})
    assert {:ok, ^day} = Goals.ask_brief_date(reader, ask.id)

    for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
      assert {:error, :not_found} = Goals.ask_brief_date(reader, id)
    end
  end

  test "goal filter precedes the unchanged default limit and hides invisible goals", c do
    wanted = queued(c)
    # Fifty newer asks on other goals previously hid this goal's open item.
    now = Platform.Goals.Clock.now()

    for _ <- 1..50 do
      put_now(now)

      other =
        goal!(c.owner, c.org, %{
          agent_mode: "advise",
          coach_agent_id: c.coach.id,
          outreach: "pushy",
          rhythm: "daily"
        })

      queued(%{c | goal: other})
    end

    assert {:ok, default} = Goals.list_my_asks(c.owner)
    assert length(default) == 50
    refute Enum.any?(default, &(&1.id == wanted.id))
    assert {:ok, [%{id: id}]} = Goals.list_my_asks(c.owner, goal_id: c.goal.id)
    assert id == wanted.id
    hidden_reader = member!(c.org)
    assert {:ok, []} = Goals.list_my_asks(hidden_reader, goal_id: c.goal.id)
    assert {:ok, []} = Goals.list_my_asks(c.owner, goal_id: "not-a-uuid")
    assert {:ok, []} = Goals.list_my_asks(c.owner, goal_id: Ecto.UUID.generate())
    assert {:ok, all} = Goals.list_my_asks(c.owner, limit: 201)
    assert length(all) == 51
  end
end
