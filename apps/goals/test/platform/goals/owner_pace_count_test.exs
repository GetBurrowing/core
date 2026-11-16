defmodule Platform.Goals.OwnerPaceCountTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  import Platform.Goals.PaceFixtures
  alias Platform.Goals
  alias Platform.Goals.OwnerPace
  setup do: setup_brief()

  test "three ignored delivery dates count three; a final answer resets the bound", c do
    asks = for _ <- 1..3, do: ignore_brief(c)
    assert OwnerPace.ignored_briefs(c.goal) == 3
    assert {:ok, _} = Goals.answer_ask(c.owner, hd(asks).id, "used")
    assert OwnerPace.ignored_briefs(c.goal) == 0
    ignore_brief(c)
    assert OwnerPace.ignored_briefs(c.goal) == 1
  end

  test "three asks in one brief count once", c do
    asks = for _ <- 1..3, do: queued(c)
    Goals.prepare_brief(c.owner, date())
    advance()
    Goals.prepare_brief(c.owner, date())
    assert length(asks) == 3
    assert OwnerPace.ignored_briefs(c.goal) == 1
  end

  test "ignored answers from other readers do not count or move the owner's bound", c do
    reader = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})
    ask = queued(c, %{addressed_user_ids: [reader.id]})
    Goals.prepare_brief(reader, date())
    advance()
    Goals.prepare_brief(reader, date())
    assert OwnerPace.ignored_briefs(c.goal) == 0
    ignore_brief(c)
    advance()
    Goals.answer_ask(reader, ask.id, "used")
    assert OwnerPace.ignored_briefs(c.goal) == 1
  end

  test "a declined replacement removes its brief and bounds older rows", c do
    first = ignore_brief(c)
    ignore_brief(c)
    advance()
    Goals.answer_ask(c.owner, first.id, "declined")
    assert OwnerPace.ignored_briefs(c.goal) == 0
  end
end
