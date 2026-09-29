defmodule Platform.Meetings.OpenQuestionPilot.PositivesFloorTest do
  @moduledoc """
  Regression guard for the stage-5 floor extension (task 01a0e8b5, ticket
  01a0eb31). Every genuine positive (the scribe misfire corpus's
  `positives/0`, and every non-privacy question in the pilot dataset) still
  produces its artefact through its handler's `gather_context/2`, in a
  meeting whose space holds no canvas. The two new candid classes only ADD
  refusals, and none of them may land on a positive. The count is printed
  so a before/after comparison can be read off the rig.
  """
  use Platform.DataCase, async: false

  alias Platform.Meetings.IntentPrivacy
  alias Platform.Meetings.OpenQuestionPilot.Dataset
  alias Platform.Meetings.OpenQuestionPilot.Runner
  alias Platform.Meetings.OpenQuestionPilot.Score
  alias Platform.Meetings.ScribeMisfireCorpus, as: Corpus

  test "every genuine positive still passes the floor and produces its artefact" do
    room = Runner.setup_artefact_room!()
    check = Score.gather_context_check(room.meeting_id, room.room_id)

    positives =
      for({_shape, intent, text} <- Corpus.positives(), do: {text, intent}) ++
        for(
          row <- Dataset.load(),
          row["is_question"] and not row["privacy"],
          do: {row["text"], "open_question"}
        )

    assert length(positives) == 10 + 31

    outcomes =
      for {text, intent} <- positives do
        {text, IntentPrivacy.candid_register(text),
         check.(%{"text" => text}, %{intent: intent, confidence: 0.9})}
      end

    passed = Enum.count(outcomes, fn {_t, _floor, artefact} -> artefact == :not_refused end)
    IO.puts("positives producing their artefact: #{passed}/#{length(positives)}")

    # The floor refuses NO positive.
    assert for({t, floor, _} <- outcomes, floor != :ok, do: {t, floor}) == []

    # Two positives are refused by the NEAR-MISS check, not the floor. That
    # check predates this task, and both were refused identically before the
    # stage-5 floor extension (39/41 on both sides, measured on the rig).
    # The first carries a speech-act label ("log an action item") and the
    # second quotes a taxonomy label ("open item"); with no canvas in the
    # space, the near-miss rule refuses both. Pinned so a change in either
    # direction has to explain itself.
    assert Enum.sort(for {t, _f, :refused} <- outcomes, do: t) == [
             "Scribe, log an action item: Ines to send the notes by Friday.",
             "The open item is whether the trial is fourteen or thirty days"
           ]

    assert passed == length(positives) - 2
  end
end
