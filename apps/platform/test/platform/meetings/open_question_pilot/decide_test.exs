defmodule Platform.Meetings.OpenQuestionPilot.DecideTest do
  @moduledoc """
  `OpenQuestionPilot.decide/3`, both arms (task 01a0e8b5 stage 2). No
  network: arm A runs on a stub provider, arm B on `Imp.LM.Static`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.OpenQuestionPilot
  alias Platform.Meetings.OpenQuestionPilot.Program
  alias Platform.Meetings.ScribeMisfireCorpus, as: Corpus

  defmodule AProvider do
    @moduledoc false
    # Arm A's model. The test process scripts it: `{intent, quote}` or a
    # function of the chunk, under :pilot_a_answer.
    def chat(_credentials, messages, _opts) do
      chunk = Enum.find_value(messages, "", &(&1.role == "user" && &1.content))

      {intent, quote} =
        case Process.get(:pilot_a_answer) do
          fun when is_function(fun, 1) -> fun.(chunk)
          {intent, :chunk} -> {intent, chunk}
          {intent, quote} -> {intent, quote}
        end

      send(self(), {:a_called, chunk})

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "intent" => intent,
             "target_role" => if(intent == "off_topic", do: nil, else: "meeting_scribe"),
             "confidence" => 0.9,
             "evidence_quote" => quote
           })
       }}
    end
  end

  defmodule BrokenA do
    @moduledoc false
    def chat(_c, _m, _o), do: {:ok, %{content: "not json"}}
  end

  defp args(chunk) do
    %{
      provider_module: AProvider,
      agent: %{model: "stub"},
      prompt: "system prompt",
      chunk_text: chunk,
      room_id: nil,
      participant_names: ["Oskar", "Liesel", "Wren"]
    }
  end

  # An Imp program whose model answers `answer` and reports each call.
  defp program(answer) do
    test_pid = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(test_pid, {:b_called, messages})
          answer
        end
      )

    Imp.with_lm(Program.new(), lm)
  end

  defp decide(arm, chunk, a_answer) do
    Process.put(:pilot_a_answer, a_answer)
    {result, _log} = with_log(fn -> OpenQuestionPilot.decide(arm, args(chunk)) end)
    result
  end

  describe "arm :prompt" do
    test "is IntentClassifier.decide/1 with is_question projected from the intent" do
      chunk = "Which region do we roll the beta out to first?"

      assert {:ok, d} = decide(:prompt, chunk, {"open_question", :chunk})
      assert d.intent == "open_question"
      assert d.is_question
      assert d.arm == :prompt
      assert d.imp == nil

      Process.put(:pilot_a_answer, {"open_question", chunk})
      {{:ok, direct}, _} = with_log(fn -> IntentClassifier.decide(args(chunk)) end)
      assert Map.drop(d, [:arm, :is_question, :imp]) == direct

      assert {:ok, %{is_question: false, intent: "action_items"}} =
               decide(
                 :prompt,
                 "Dana to send the sprint notes by Friday",
                 {"action_items", :chunk}
               )
    end
  end

  describe "arm {:imp_program, _}" do
    test "B true promotes an A off_topic to open_question with the whole chunk as the quote" do
      chunk = "Oskar, which dataset did you use for the benchmark?"
      p = program(%{is_question: true, addressee: "Oskar"})

      assert {:ok, d} = decide({:imp_program, p}, chunk, {"off_topic", ""})
      assert_received {:b_called, _}
      assert d.intent == "open_question"
      assert d.is_question
      assert d.evidence_quote == chunk
      assert d.target_role == IntentClassifier.no_target_role()
      assert d.imp == %{is_question: true, addressee: "Oskar"}
      assert d.arm == :imp_program
    end

    test "B is shown the excerpt and the participant names" do
      p = program(%{is_question: true, addressee: "none"})

      decide(
        {:imp_program, p},
        "Should the export feature ship behind a flag?",
        {"off_topic", ""}
      )

      assert_received {:b_called, messages}
      user = Enum.find(messages, &(&1.role == :user)).content
      assert user =~ "Should the export feature ship behind a flag?"
      assert user =~ ~s(["Oskar", "Liesel", "Wren"])
    end

    test "B's addressee does not change target_role" do
      chunk = "Which region do we roll the beta out to first?"
      p = program(%{is_question: true, addressee: "Liesel"})

      assert {:ok, d} = decide({:imp_program, p}, chunk, {"open_question", :chunk})
      assert d.target_role == "meeting_scribe"
      assert d.imp.addressee == "Liesel"
    end

    test "B true goes through the SAME post-model gates as decide/1" do
      # For every corpus chunk, B-true must land exactly where decide/1
      # lands for a model that answered open_question citing the whole
      # chunk: one gate chain, two entrances.
      p = program(%{is_question: true, addressee: "none"})

      rows = Corpus.negatives() ++ Corpus.causes() ++ Corpus.privacy()
      assert length(rows) == 43

      demoted =
        for {_shape, _intent, text} <- rows do
          {:ok, via_b} = decide({:imp_program, p}, text, {"off_topic", ""})

          Process.put(:pilot_a_answer, {"open_question", text})

          {{:ok, via_a}, _} = with_log(fn -> IntentClassifier.decide(args(text)) end)

          keys = [
            :intent,
            :evidence_quote,
            :demoted_from,
            :demotion_reason,
            :addressee_nulled_from
          ]

          assert Map.take(via_b, keys) == Map.take(via_a, keys),
                 "gate outcome differs for #{inspect(text)}"

          via_b.demoted_from
        end

      # The gates actually fired on some of these (a vacuous comparison of
      # two never-gated paths would also be equal).
      assert Enum.count(demoted, &(&1 == "open_question")) > 0
    end

    test "B false demotes an A open_question with :imp_not_question" do
      chunk = "The pilot starts on Monday, doesn't it?"
      p = program(%{is_question: false, addressee: "none"})

      assert {:ok, d} = decide({:imp_program, p}, chunk, {"open_question", :chunk})
      assert d.intent == "off_topic"
      refute d.is_question
      assert d.demoted_from == "open_question"
      assert d.demotion_reason == :imp_not_question
      assert d.evidence_quote == ""
      assert d.target_role == IntentClassifier.no_target_role()
    end

    test "B false leaves an A off_topic as it was, with no demotion" do
      p = program(%{is_question: false, addressee: "none"})

      assert {:ok, d} =
               decide(
                 {:imp_program, p},
                 "Why do these meetings always overrun?",
                 {"off_topic", ""}
               )

      assert d.intent == "off_topic"
      assert d.demoted_from == nil
      assert d.demotion_reason == nil
      assert d.imp == %{is_question: false, addressee: "none"}
    end

    test "B is NOT asked when A says any other intent" do
      p = program(%{is_question: true, addressee: "none"})

      for intent <-
            ~w(action_items brief_worthy decision_recorded visual_adjust interaction_design) do
        chunk = "Dana to send the sprint notes to the team by Friday"
        assert {:ok, d} = decide({:imp_program, p}, chunk, {intent, :chunk})
        assert d.intent == intent
        assert d.imp == nil
        refute_received {:b_called, _}, "B was asked on #{intent}"
      end
    end

    test "B's answer in the chat adapter's text format is read" do
      p =
        program(
          "[[ ## is_question ## ]]\ntrue\n\n[[ ## addressee ## ]]\nWren\n\n[[ ## completed ## ]]"
        )

      assert {:ok, %{is_question: true, imp: %{addressee: "Wren"}}} =
               decide(
                 {:imp_program, p},
                 "Wren, when can the new build be on the test devices?",
                 {"off_topic", ""}
               )
    end

    test "an unparseable B answer is :parse_error, never a label" do
      p = program("I think so, probably")

      assert {:error, :parse_error} =
               decide(
                 {:imp_program, p},
                 "Are we keeping the old pricing tier or not?",
                 {"off_topic", ""}
               )
    end

    test "an A error is returned and B is not asked" do
      p = program(%{is_question: true, addressee: "none"})

      {result, _} =
        with_log(fn ->
          OpenQuestionPilot.decide({:imp_program, p}, %{args("x y z") | provider_module: BrokenA})
        end)

      assert result == {:error, :parse_error}
      refute_received {:b_called, _}
    end

    test "a dataset row is decided with base_args and its own participants" do
      row = %{
        "text" => "Noor, is the accessibility audit scheduled yet?",
        "participants" => ["Noor", "Bram"]
      }

      p = program(%{is_question: true, addressee: "Noor"})
      Process.put(:pilot_a_answer, {"off_topic", ""})

      {{:ok, d}, _} =
        with_log(fn ->
          OpenQuestionPilot.decide({:imp_program, p}, row,
            base_args: Map.drop(args("unused"), [:chunk_text, :participant_names])
          )
        end)

      assert d.is_question
      assert_received {:b_called, messages}
      assert Enum.find(messages, &(&1.role == :user)).content =~ ~s(["Noor", "Bram"])
    end
  end
end
