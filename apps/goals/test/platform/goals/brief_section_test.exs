defmodule Platform.Goals.BriefSectionTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.Brief.Section
  setup do: setup_brief()

  test "adapter is quiet for unknown, disabled or unauthorized readers and returns context counts",
       c do
    queued(c)
    revoke_goals_use!(c.owner)
    day = date()
    missing = Ecto.UUID.generate()
    assert Section.prepare(missing, day) == 0
    assert Section.summary(missing, day) == nil
    assert Section.prepare(c.owner.id, day) == 0
    assert Section.summary(c.owner.id, day) == nil
    grant_goals_use!(c.owner)

    Application.put_env(:goals, :enabled, false)
    assert Section.prepare(c.owner.id, day) == 0
    assert Section.summary(c.owner.id, day) == nil
    Application.put_env(:goals, :enabled, true)
    assert Section.prepare(c.owner.id, day) == 1
    assert Section.summary(c.owner.id, day) == %{total: 1, open: 1, calls: 1}
    assert {:ok, %{total: 1, open: 1, calls: 1}} = Goals.brief_summary(c.owner, day)
  end
end
