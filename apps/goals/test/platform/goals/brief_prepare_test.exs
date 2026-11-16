defmodule Platform.Goals.BriefPrepareTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.{AskAnswer, BriefItem, Clock}
  setup do: setup_brief()

  test "an ask is not sent again and ignored is recorded exactly once at the next brief", c do
    ask = queued(c)
    day = date()
    assert {:ok, %{new: 1, ignored: 0}} = Goals.prepare_brief(c.owner, day)
    assert {:ok, %{new: 0, ignored: 0}} = Goals.prepare_brief(c.owner, day)
    assert Repo.aggregate(AskAnswer, :count) == 0
    assert {:ok, %{new: 0, ignored: 1}} = Goals.prepare_brief(c.owner, advance())

    for _ <- 1..3 do
      assert {:ok, %{new: 0, ignored: 0}} = Goals.prepare_brief(c.owner, advance())
    end

    assert [%{answer: "ignored", ask_id: id}] = Repo.all(AskAnswer)
    assert id == ask.id
    assert Repo.aggregate(BriefItem, :count) == 1
    assert {:ok, [old]} = Goals.brief_items(c.owner, day)
    assert old.state == :open
    assert {:ok, []} = Goals.brief_items(c.owner, date())
  end

  test "an answered ask is never marked ignored", c do
    ask = queued(c)
    assert {:ok, _} = Goals.prepare_brief(c.owner, date())
    assert {:ok, _} = Goals.answer_ask(c.owner, ask.id, "used")
    assert {:ok, %{ignored: 0}} = Goals.prepare_brief(c.owner, advance())
    assert [%{answer: "used"}] = Repo.all(AskAnswer)
  end

  test "reports advance their window, extend the same day and omit empty windows", c do
    action(c, %{title: "First"})
    day = date()
    assert {:ok, %{new: 1}} = Goals.prepare_brief(c.owner, day)
    assert {:ok, %{new: 0}} = Goals.prepare_brief(c.owner, day)
    put_now(DateTime.add(Clock.now(), 60, :second))
    action(c, %{title: "Second"})
    assert {:ok, %{new: 1}} = Goals.prepare_brief(c.owner, day)
    assert {:ok, [report]} = Goals.brief_items(c.owner, day)
    assert Enum.map(report.entries, & &1.title) == ["First", "Second"]
    assert {:ok, %{new: 0}} = Goals.prepare_brief(c.owner, advance())
    assert {:ok, []} = Goals.brief_items(c.owner, date())
    action(c, %{title: "Third"})
    assert {:ok, %{new: 1}} = Goals.prepare_brief(c.owner, date())
    assert {:ok, [report]} = Goals.brief_items(c.owner, date())
    assert Enum.map(report.entries, & &1.title) == ["Third"]
  end

  test "the first report excludes actions outside the configured window", c do
    advance(10)
    action(c, %{title: "Too old", occurred_at: DateTime.add(Clock.now(), -8 * 86_400, :second)})
    action(c, %{title: "Recent"})
    assert {:ok, %{new: 1}} = Goals.prepare_brief(c.owner, date())
    assert {:ok, [report]} = Goals.brief_items(c.owner, date())
    assert Enum.map(report.entries, & &1.title) == ["Recent"]
  end

  test "hidden items remain untouched and become ignored once after visibility returns", c do
    reader = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})
    ask = queued(c, %{addressed_user_ids: [reader.id]})
    assert {:ok, %{new: 1}} = Goals.prepare_brief(reader, date())
    {:ok, _} = Goals.close_goal(c.owner, c.goal.id, {:user, reader.id})

    for _ <- 1..2 do
      assert {:ok, %{new: 0, ignored: 0}} = Goals.prepare_brief(reader, advance())
    end

    assert Repo.aggregate(AskAnswer, :count) == 0
    assert [%{ignored_at: nil}] = Repo.all(BriefItem)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})
    assert {:ok, %{new: 0, ignored: 1}} = Goals.prepare_brief(reader, date())
    assert {:ok, %{new: 0, ignored: 0}} = Goals.prepare_brief(reader, advance())
    assert [%{ask_id: id, answer: "ignored"}] = Repo.all(AskAnswer)
    assert id == ask.id
  end

  @tag timeout: 180_000
  test "one prepare includes all 201 addressed asks without a cap", c do
    previous = Application.fetch_env(:goals, :limits)

    Application.put_env(:goals, :limits, %{
      max_open_asks: %{"pushy" => 250},
      ask_expiry_days: 1000,
      retro_every: %{"daily" => 1000}
    })

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:goals, :limits, value)
        :error -> Application.delete_env(:goals, :limits)
      end
    end)

    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{retro_every: nil})
    for i <- 1..201, do: queued(c, %{title: "Ask #{i}"})
    assert {:ok, default} = Goals.list_my_asks(c.owner)
    assert length(default) == 50
    assert {:ok, capped} = Goals.list_my_asks(c.owner, limit: 1000)
    assert length(capped) == 200
    assert {:ok, %{new: 201}} = Goals.prepare_brief(c.owner, date())
    assert {:ok, items} = Goals.brief_items(c.owner, date())
    assert length(items) == 201
    assert {:ok, %{new: 0}} = Goals.prepare_brief(c.owner, date())
  end
end
