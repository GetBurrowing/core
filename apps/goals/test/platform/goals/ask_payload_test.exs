defmodule Platform.Goals.AskPayloadTest do
  use Platform.DataCase, async: false
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  setup do: setup_brief()

  test "questions store moved lines and suggestions and offers with ideas are classified", c do
    payload = %{
      "moved" => [%{"direction" => "up", "text" => "Drafts completed"}],
      "suggestions" => [%{"title" => "Try this", "why" => "It saves a step"}]
    }

    ask = queued(c, %{payload: payload})
    assert ask.payload == payload
    idea = %{"why" => "Less work", "measure" => "One hour saved", "steps" => ["Draft", "Review"]}
    idea_ask = queued(c, %{kind: "offer", payload: %{"idea" => idea}})
    {:ok, _} = Goals.prepare_brief(c.owner, date())
    assert {:ok, items} = Goals.brief_items(c.owner, date())
    assert Enum.any?(items, &(&1.kind == :idea and &1.ask.id == idea_ask.id))
  end

  test "malformed moved, suggestions and idea payloads refuse atomically", c do
    wake = fire(c.goal)

    for {kind, payload} <- [
          {"question", %{"moved" => [%{"direction" => "sideways", "text" => "Moved"}]}},
          {"question", %{"suggestions" => [%{"title" => " "}]}},
          {"question", %{"suggestions" => List.duplicate(%{"title" => "One"}, 11)}},
          {"offer", %{"idea" => %{"why" => "Because", "measure" => "One", "steps" => []}}},
          {"offer", %{"idea" => %{"why" => "Because", "measure" => " ", "steps" => ["First"]}}}
        ] do
      assert {:error, %Ecto.Changeset{}} =
               Goals.close_wake_up(
                 c.coach,
                 wake.id,
                 "ask",
                 ask_attrs(%{kind: kind, payload: payload})
               )
    end

    assert Repo.aggregate(Goals.Ask, :count) == 0
  end
end
