defmodule Platform.Goals.AsksTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  alias Platform.Goals
  alias Platform.Goals.{Ask, AskAnswer, Clock}
  setup do: setup_outcome()

  defp create_ask(c, attrs \\ %{}) do
    wake = fire(c.goal)
    {:ok, %{ask: ask}} = Goals.close_wake_up(c.coach, wake.id, "ask", ask_attrs(attrs))
    ask
  end

  test "only addressed viewers receive asks and visibility is checked again at read time", c do
    addressed = member!(c.org)
    other = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, addressed.id})
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, other.id})
    ask = create_ask(c, %{addressed_user_ids: [addressed.id]})
    assert {:ok, [listed]} = Goals.list_my_asks(addressed)
    assert listed.id == ask.id
    assert {:ok, []} = Goals.list_my_asks(other)
    assert {:ok, []} = Goals.list_my_asks(c.coach)
    assert {:ok, [listed]} = Goals.list_asks(addressed, c.goal.id)
    assert listed.id == ask.id
    assert {:ok, []} = Goals.list_asks(other, c.goal.id)
    assert {:ok, [_]} = Goals.list_asks(c.owner, c.goal.id)
    assert {:ok, [_]} = Goals.list_asks(c.coach, c.goal.id)
    assert Goals.answer_ask(other, ask.id, "used") == {:error, :not_found}
    {:ok, _} = Goals.close_goal(c.owner, c.goal.id, {:user, addressed.id})
    assert {:ok, []} = Goals.list_my_asks(addressed)
    assert Goals.answer_ask(addressed, ask.id, "used") == {:error, :not_found}
  end

  test "an invisible addressee and invalid practice cards refuse atomically", c do
    wake = fire(c.goal)
    before = row_counts()

    assert Goals.close_wake_up(
             c.coach,
             wake.id,
             "ask",
             ask_attrs(%{addressed_user_ids: [member!(c.org).id]})
           ) == {:error, :addressee_cannot_see_goal}

    assert row_counts() == before

    for cards <- [
          [],
          List.duplicate(%{"front" => "Front", "back" => "Back"}, 21),
          [%{"front" => " ", "back" => "Back"}]
        ] do
      assert {:error, %Ecto.Changeset{}} =
               Goals.close_wake_up(
                 c.coach,
                 wake.id,
                 "ask",
                 ask_attrs(%{kind: "practice", payload: %{"cards" => cards}})
               )

      assert row_counts() == before
    end

    assert {:ok, %{ask: ask}} =
             Goals.close_wake_up(
               c.coach,
               wake.id,
               "ask",
               ask_attrs(%{
                 kind: "practice",
                 payload: %{"cards" => [%{"front" => "Prompt", "back" => "Answer"}]}
               })
             )

    assert ask.payload["cards"] == [%{"front" => "Prompt", "back" => "Answer"}]
  end

  test "answers persist details, final answers cannot change and ignored may become final once",
       c do
    for answer <- ~w(used declined ignored) do
      ask = create_ask(c)
      details = %{"got" => ["one"], "missed" => ["two"]}
      assert {:ok, _} = Goals.answer_ask(c.owner, ask.id, answer, details)
      row = Repo.one!(from(a in AskAnswer, where: a.ask_id == ^ask.id))
      assert row.answer == answer
      assert row.details == details
      assert row.answered_at == Clock.now()
      assert Repo.get!(Ask, ask.id).status == "closed"
      assert {:ok, asks} = Goals.list_asks(c.owner, c.goal.id)
      listed = Enum.find(asks, &(&1.id == ask.id))
      assert length(listed.answers) == 1
      assert {:ok, []} = Goals.list_my_asks(c.owner)

      if answer == "ignored" do
        assert {:ok, _} = Goals.answer_ask(c.owner, ask.id, "used")
        assert Repo.one!(from(a in AskAnswer, where: a.ask_id == ^ask.id)).answer == "used"
      end

      before = Repo.aggregate(AskAnswer, :count)
      assert Goals.answer_ask(c.owner, ask.id, "declined") == {:error, :already_answered}
      assert Repo.aggregate(AskAnswer, :count) == before
      assert Goals.answer_ask(member!(c.org), ask.id, "used") == {:error, :not_found}
      next = fire(c.goal)
      assert Enum.any?(next.briefing["since_last"]["answers"], &(&1["ask_id"] == ask.id))

      assert {:ok, _} =
               Goals.close_wake_up(c.coach, next.id, "wait", %{reason: "Recorded answer"})
    end
  end

  test "each addressed user answers independently; expired asks still accept answers", c do
    reader = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})
    ask = create_ask(c, %{addressed_user_ids: [c.owner.id, reader.id]})
    assert {:ok, _} = Goals.answer_ask(c.owner, ask.id, "used")
    assert Repo.get!(Ask, ask.id).status == "open"
    Repo.update!(Ecto.Changeset.change(ask, expires_at: Clock.now()))
    Clock.tick(Clock.now())
    assert Repo.get!(Ask, ask.id).status == "expired"
    assert {:ok, _} = Goals.answer_ask(reader, ask.id, "declined")
    assert Repo.get!(Ask, ask.id).status == "closed"
  end

  test "ask length and addressee bounds refuse without consuming a wake-up", c do
    wake = fire(c.goal)
    before = row_counts()

    for attrs <- [%{title: String.duplicate("x", 201)}, %{body: String.duplicate("x", 4001)}] do
      assert {:error, %Ecto.Changeset{}} =
               Goals.close_wake_up(c.coach, wake.id, "ask", ask_attrs(attrs))

      assert row_counts() == before
    end

    readers =
      for _ <- 1..21 do
        reader = member!(c.org)
        {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})
        reader.id
      end

    assert Goals.close_wake_up(c.coach, wake.id, "ask", ask_attrs(%{addressed_user_ids: readers})) ==
             {:error, :addressee_cannot_see_goal}

    assert row_counts() == before

    assert {:ok, _} =
             Goals.close_wake_up(
               c.coach,
               wake.id,
               "ask",
               ask_attrs(%{title: String.duplicate("x", 200), body: String.duplicate("x", 4000)})
             )
  end
end

