defmodule Platform.Goals.BriefSignalsTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.{AskAnswer, Clock, Entry}
  setup do: setup_brief()

  test "noted and undo requests are reversible signals and never reverse the action", c do
    entry = action(c, %{details: %{"undo_note" => "Delete the draft"}})
    plain = action(c, %{title: "An irreversible action"})
    assert {:ok, _} = Goals.prepare_brief(c.owner, date())
    assert {:ok, [report]} = Goals.brief_items(c.owner, date())
    assert {:ok, _} = Goals.set_report_noted(c.owner, report.id, true)
    assert {:ok, [%{state: :done}]} = Goals.brief_items(c.owner, date())
    assert {:ok, _} = Goals.set_report_noted(c.owner, report.id, false)
    assert {:ok, requested} = Goals.request_undo(c.owner, c.goal.id, entry.id)
    assert {:ok, same} = Goals.request_undo(c.owner, c.goal.id, entry.id)
    assert requested.id == same.id
    assert {:ok, _} = Goals.request_undo(c.owner, c.goal.id, entry.id, "keep")
    assert Goals.request_undo(c.owner, c.goal.id, plain.id) == {:error, :not_undoable}
    assert Goals.request_undo(member!(c.org), c.goal.id, entry.id) == {:error, :not_found}
    assert Repo.get!(Entry, entry.id).details == entry.details
    assert Repo.aggregate(from(e in Entry, where: e.kind == "action"), :count) == 2
    assert Repo.aggregate(from(e in Entry, where: e.kind == "ask"), :count) == 2
  end

  test "undo cancellation cycles keep one request identity and retain every coach signal", c do
    queued(c)
    entry = action(c, %{details: %{"undo_note" => "Delete the draft"}})
    original = Repo.get!(Entry, entry.id)

    signals =
      for request <- ["undo", "keep", "undo", "keep"] do
        put_now(DateTime.add(Clock.now(), 1, :second))
        assert {:ok, signal} = Goals.request_undo(c.owner, c.goal.id, entry.id, request)
        assert {:ok, same} = Goals.request_undo(c.owner, c.goal.id, entry.id, request)
        assert same.id == signal.id
        signal
      end

    assert length(Enum.uniq_by(signals, & &1.id)) == 4
    assert Enum.map(signals, & &1.details["request"]) == ["undo", "keep", "undo", "keep"]
    assert Repo.get!(Entry, entry.id) == original
    wake = fire(c.goal)

    ids = Enum.map(signals, & &1.id)
    snapshot = Enum.filter(wake.briefing["since_last"]["entries"], &(&1["id"] in ids))

    assert Enum.map(snapshot, & &1["id"]) == Enum.reverse(ids)
    for signal <- signals, do: assert(Repo.get!(Entry, signal.id) == signal)
    assert Enum.count(signals, &String.starts_with?(&1.title, "Undo: ")) == 1
    assert original.inserted_at == original.updated_at
    {:ok, _} = Goals.prepare_brief(c.owner, date())
    {:ok, [report]} = Goals.brief_items(c.owner, date())
    assert Enum.find(report.entries, &(&1.id == entry.id)).undo == :available
  end

  test "questions are bounded and report linkage cannot point at someone else's item", c do
    action(c)
    {:ok, _} = Goals.prepare_brief(c.owner, date())
    {:ok, [report]} = Goals.brief_items(c.owner, date())
    assert {:error, _} = Goals.ask_coach(c.owner, c.goal.id, " ")
    assert {:error, _} = Goals.ask_coach(c.owner, c.goal.id, String.duplicate("x", 501))

    assert {:ok, question} =
             Goals.ask_coach(c.owner, c.goal.id, " Why this? ", item_id: report.id)

    assert question.title == "Why this?"
    assert question.details["brief_item_id"] == report.id
    assert question.details["request"] == "question"
    assert {:ok, [updated]} = Goals.brief_items(c.owner, date())
    assert Enum.any?(updated.questions, &(&1.id == question.id))
    assert Goals.set_report_noted(member!(c.org), report.id, true) == {:error, :not_found}
  end

  test "answers withdraw before the coach wakes and then become already seen", c do
    ask = queued(c, %{kind: "offer", payload: %{"draft" => "An outline"}})
    assert {:ok, _} = Goals.answer_ask(c.owner, ask.id, "used", %{"chosen" => "outline"})
    assert {:ok, %{status: "open"}} = Goals.withdraw_answer(c.owner, ask.id)
    assert Repo.aggregate(AskAnswer, :count) == 0
    assert {:ok, _} = Goals.answer_ask(c.owner, ask.id, "declined")
    fire(c.goal)
    assert Goals.withdraw_answer(c.owner, ask.id) == {:error, :already_seen}
    assert [%{answer: "declined"}] = Repo.all(AskAnswer)
  end

  test "the coach snapshot includes undo, questions and answer details", c do
    ask = queued(c, %{kind: "offer"})
    entry = action(c, %{details: %{"undo_note" => "Remove the draft"}})
    put_now(DateTime.add(Clock.now(), 60, :second))
    {:ok, _} = Goals.request_undo(c.owner, c.goal.id, entry.id)
    {:ok, _} = Goals.ask_coach(c.owner, c.goal.id, "Why these three?")

    details = %{
      "got" => 3,
      "missed" => 2,
      "choices" => [%{"title" => "Try the outline", "choice" => "do_it"}]
    }

    {:ok, _} = Goals.answer_ask(c.owner, ask.id, "used", details)
    wake = fire(c.goal)
    entries = wake.briefing["since_last"]["entries"]

    assert Enum.any?(
             entries,
             &(&1["title"] == "Undo: Drafted the outline" and &1["author_type"] == "user")
           )

    assert Enum.any?(entries, &(&1["title"] == "Why these three?"))
    assert Enum.any?(wake.briefing["since_last"]["answers"], &(&1["details"] == details))
    text = Goals.WakeUps.Briefing.text(wake.briefing)
    assert text =~ "got 3, missed 2"
    assert text =~ "Try the outline: do_it"
  end
end
