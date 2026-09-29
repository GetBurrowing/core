defmodule Platform.Meetings.IntentPrivacyTest do
  @moduledoc """
  Tests for `Platform.Meetings.IntentPrivacy` — the candid-register floor
  (task `01a0e58f`, acceptance 2 and 3).

  The shape was filed from the 2026-09-14 one-to-one: a commitment verb,
  a deadline and a named owner, spoken in a candid register. Every row
  here is synthesised and every name is invented. The one fixture the
  ticket fixes verbatim is "Priya to deliver list of demands to Marcus by
  end of week".

  ## Named mutations — each applied and reverted, measured on the rig
  (`intent_privacy_test.exs` + `test/platform/responsibilities`, 1103 tests)

    * **M-p2** — "make `candid_register` return :ok when confidence <
      0.9". Impossible by construction: the function takes ONE argument,
      the text, so there is no confidence for it to read. Substituted:
      add a `candid_register/2` clause. Measured: 1 failure — "the floor
      takes the text and nothing else / candid_register/1 is the only
      arity".
    * **M-p3** — delete the `:demands` lexicon entry. Measured: 12
      failures — "the ticket's fixture is candid as :demands", "matching
      is case-insensitive", the independence test, and every Priya-line
      refusal in the three handler files and the dispatch test.
  """

  use ExUnit.Case, async: true

  alias Platform.Meetings.IntentPrivacy

  @priya "Priya to deliver list of demands to Marcus by end of week"

  describe "each candid class" do
    # M-p3 kills this.
    test "the ticket's fixture is candid as :demands" do
      assert {:candid, :demands} = IntentPrivacy.candid_register(@priya)
    end

    test "compensation" do
      assert {:candid, :compensation} =
               IntentPrivacy.candid_register("Kasia asked about a pay rise before the review")
    end

    test "departure" do
      assert {:candid, :departure} =
               IntentPrivacy.candid_register("Rafe is handing in his notice on Monday")
    end

    test "a grievance about a named colleague" do
      assert {:candid, :grievance} =
               IntentPrivacy.candid_register("Ines keeps undermining Tobias in standup")
    end

    test "matching is case-insensitive" do
      assert {:candid, :demands} =
               IntentPrivacy.candid_register("PRIYA TO DELIVER LIST OF DEMANDS BY FRIDAY")
    end
  end

  # Task 01a0e8b5 stage 5 (ticket 01a0eb31). The open_question pilot's
  # synthesised TEST split showed the four original classes letting two
  # SHAPES through. Filed as shapes: the two pilot rows plus invented
  # variants. Every row here was :ok before these classes existed.
  describe "personnel outcome of a named person" do
    for text <- [
          "Has anyone told Anouk the outcome of her promotion case?",
          "Did Tobiah hear about the promotion decision yet?",
          "Is Priyanka's performance rating on the agenda today?",
          "Is Wendell still on probation after the incident review?",
          "Fenwick wants his performance review moved off the shared calendar"
        ] do
      test "#{inspect(text)} is candid as :personnel_outcome" do
        assert {:candid, :personnel_outcome} = IntentPrivacy.candid_register(unquote(text))
      end
    end

    test "the phrase with no person in its sentence is process talk" do
      assert :ok = IntentPrivacy.candid_register("the performance review of the checkout service")
      assert :ok = IntentPrivacy.candid_register("Promotion decision for the landing page is due")
      assert :ok = IntentPrivacy.candid_register("the launch promotion runs on Friday")
    end
  end

  describe "a request explained by personal circumstances" do
    for text <- [
          "Caspian asked to move to part-time for family reasons",
          "Leopold asked to work from home for health reasons",
          "Rosalind needs compassionate leave next week",
          "Oriel wants Fridays off for childcare"
        ] do
      test "#{inspect(text)} is candid as :personal_circumstances" do
        assert {:candid, :personal_circumstances} = IntentPrivacy.candid_register(unquote(text))
      end
    end
  end

  # Ordinary commitments must pass. A floor that refused everything would
  # pass the block above perfectly.
  describe "anti-vacuity — ordinary work passes" do
    for text <- [
          "Dana to send the sprint notes to the team by Friday",
          "raise a ticket for the login bug",
          "leave a comment on the PR",
          "Write my strategy"
        ] do
      test "#{inspect(text)} is :ok" do
        assert :ok = IntentPrivacy.candid_register(unquote(text))
      end
    end

    # The grievance class needs a NAME in the same sentence. The phrase on
    # its own is ordinary process talk.
    test "a grievance phrase with no named colleague is :ok" do
      assert :ok = IntentPrivacy.candid_register("the build keeps undermining our deploy times")
    end

    test "a name in a DIFFERENT sentence from the grievance phrase is :ok" do
      assert :ok =
               IntentPrivacy.candid_register(
                 "Dana owns the release. The flaky test keeps undermining the build."
               )
    end

    test "an acronym or a weekday is not a name" do
      assert :ok = IntentPrivacy.candid_register("the flaky test keeps undermining CI on Monday")
    end

    test "blank and non-binary input is :ok" do
      assert :ok = IntentPrivacy.candid_register("")
      assert :ok = IntentPrivacy.candid_register("   ")
      assert :ok = IntentPrivacy.candid_register(nil)
    end
  end

  # A lexical floor has no semantics. Pinned rather than left for
  # production to discover: an ordinary errand that happens to use a
  # grievance verb next to a name is refused. That is the price of a
  # floor that never reads a model or a confidence.
  describe "the accepted cost" do
    test "\"fire off\" next to a name is refused as a grievance" do
      assert {:candid, :grievance} =
               IntentPrivacy.candid_register("Can you fire off the invite to Dana today")
    end
  end

  # The known miss, pinned so a widening has to argue for itself here. A
  # word capitalised only because it opens a sentence is not evidence of
  # a name, so a grievance whose only name is the first word passes.
  describe "the known miss" do
    test "a grievance whose only name opens the sentence is not caught" do
      assert :ok = IntentPrivacy.candid_register("Ines is undermining me in standup")
    end
  end

  describe "the floor takes the text and nothing else" do
    # M-p2's replacement. With one argument there is no confidence, no
    # precision and no gate setting for the floor to read.
    test "candid_register/1 is the only arity" do
      arities =
        IntentPrivacy.__info__(:functions)
        |> Keyword.get_values(:candid_register)

      assert arities == [1]
    end

    test "the module source reads no gate setting and no confidence" do
      source =
        File.read!(Path.expand("../../../lib/platform/meetings/intent_privacy.ex", __DIR__))

      refute source =~ "meeting_utterance_gates"
      refute source =~ "confidence"
    end
  end
end

defmodule Platform.Meetings.IntentPrivacyIndependenceTest do
  @moduledoc """
  The floor is independent of the stage 1-2 utterance gates. With those
  gates disabled through the same application env the falsifier uses,
  the Priya line is still refused at `gather_context/2`. `async: false`
  because it writes application env.
  """

  use ExUnit.Case, async: false

  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Handlers.MeetingBriefWorthy
  alias Platform.Responsibilities.Handlers.MeetingOpenQuestion
  alias Platform.Responsibilities.Responsibility

  setup do
    previous = Application.get_env(:platform, :meeting_utterance_gates)
    Application.put_env(:platform, :meeting_utterance_gates, :disabled)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:platform, :meeting_utterance_gates),
        else: Application.put_env(:platform, :meeting_utterance_gates, previous)
    end)

    :ok
  end

  test "with the utterance gates disabled, every handler still refuses the Priya line" do
    meta = %{
      kind: :event_topic,
      payload: %{
        intent_id: Platform.Types.UUIDv7.generate(),
        meeting_id: Platform.Types.UUIDv7.generate(),
        chunk_excerpt: "Priya to deliver list of demands to Marcus by end of week",
        confidence: 1.0
      }
    }

    for handler <- [MeetingActionItems, MeetingBriefWorthy, MeetingOpenQuestion] do
      assert {:error, :candid_register} =
               handler.gather_context(%Responsibility{key: handler.key()}, meta),
             "#{inspect(handler)} dispatched a candid line with the utterance gates disabled"
    end
  end
end
