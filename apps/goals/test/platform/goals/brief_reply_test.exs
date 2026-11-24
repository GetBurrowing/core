defmodule Platform.Goals.BriefReplyTest do
  @moduledoc """
  Task 01a20de3 stage 2: the daily brief records "ignored" for an old ask
  item only when the owner has not answered that ask in words (a goal
  conversation message whose metadata "ask_id" names it). The item still
  gets its ignored_at either way.
  """
  use Platform.DataCase, async: false
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.{AskAnswer, BriefItem, OwnerPace}

  setup do
    old = Application.fetch_env(:goals, :wake_up_dispatcher)
    Application.put_env(:goals, :wake_up_dispatcher, fn _signal -> :ok end)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:goals, :wake_up_dispatcher, value)
        :error -> Application.delete_env(:goals, :wake_up_dispatcher)
      end
    end)

    setup_brief()
  end

  test "brief ignore_old does not write ignored for a replied ask, and still does for an unreplied one",
       c do
    replied = queued(c)
    unreplied = queued(c)
    assert {:ok, _} = Goals.prepare_brief(c.owner, date())
    assert Repo.aggregate(BriefItem, :count) == 2

    {:ok, _} = Goals.say_in_goal(c.owner, c.goal.id, "REPLY-TOKEN-1", ask_id: replied.id)
    {:ok, _} = Goals.say_in_goal(c.owner, c.goal.id, "REPLY-TOKEN-2")

    assert {:ok, %{ignored: 1}} = Goals.prepare_brief(c.owner, advance())
    assert [%AskAnswer{ask_id: id, answer: "ignored"}] = Repo.all(AskAnswer)
    assert id == unreplied.id

    # Both items are settled, so neither is looked at again.
    assert Enum.all?(Repo.all(BriefItem), &(&1.ignored_at != nil))
    assert {:ok, %{ignored: 0}} = Goals.prepare_brief(c.owner, advance())
    assert Repo.aggregate(AskAnswer, :count) == 1
    assert OwnerPace.ignored_briefs(Repo.get!(Goals.Goal, c.goal.id)) == 1
  end
end
