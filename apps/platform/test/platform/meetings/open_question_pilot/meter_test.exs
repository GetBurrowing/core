defmodule Platform.Meetings.OpenQuestionPilot.MeterTest do
  @moduledoc """
  The pilot's one instrument (task 01a0e8b5 stage 2): hard call cap,
  per-call capture, cassette record/replay, and `ProviderLM` riding the
  same transport and options as arm A. No network.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Meetings.OpenQuestionPilot
  alias Platform.Meetings.OpenQuestionPilot.Meter
  alias Platform.Meetings.OpenQuestionPilot.Program
  alias Platform.Meetings.OpenQuestionPilot.ProviderLM
  alias Platform.TestTemp

  defmodule LiveStub do
    @moduledoc false
    # Stands in for Ollama.chat/3. Answers by what the messages look like:
    # an intent-classifier call (system prompt "system prompt") gets
    # :pilot_a_intent, an Imp call gets :pilot_b_reply. Reports every call.

    # Arm B's default reply is in the chat adapter's own format, so Imp
    # parses it on the first call (a JSON reply makes the chat adapter fall
    # back to the JSON adapter: a second call).
    @b_true "[[ ## is_question ## ]]\ntrue\n\n[[ ## addressee ## ]]\nnone\n\n[[ ## completed ## ]]"

    def chat(credentials, messages, opts) do
      send(self(), {:live_called, credentials, messages, opts})
      system = Enum.find_value(messages, "", &(&1.role == "system" && &1.content))
      user = Enum.find_value(messages, "", &(&1.role == "user" && &1.content))

      content =
        if system == "system prompt" do
          Jason.encode!(%{
            "intent" => Process.get(:pilot_a_intent, "off_topic"),
            "target_role" => nil,
            "confidence" => 0.8,
            "evidence_quote" =>
              if(Process.get(:pilot_a_intent, "off_topic") == "off_topic", do: "", else: user)
          })
        else
          Process.get(:pilot_b_reply, @b_true)
        end

      {:ok,
       %{
         content: content,
         model: "stub",
         finish_reason: "stop",
         usage: %{"prompt_tokens" => 100, "completion_tokens" => 7}
       }}
    end
  end

  @agent %{model: "qwen-stub", base_url: "http://llm.invalid:8085/v1"}

  defp args(chunk) do
    %{
      provider_module: LiveStub,
      agent: @agent,
      prompt: "system prompt",
      chunk_text: chunk,
      room_id: nil,
      participant_names: ["Oskar", "Liesel"]
    }
  end

  defp decide(arm, chunk, meter) do
    {result, _log} =
      with_log(fn -> OpenQuestionPilot.decide(arm, args(chunk), meter: meter) end)

    result
  end

  defp live_calls do
    receive do
      {:live_called, _c, _m, _o} -> 1 + live_calls()
    after
      0 -> 0
    end
  end

  describe "hard call cap" do
    test "refuses call N+1 with :budget_exhausted and never reaches the provider" do
      meter = Meter.new(cap: 2, live_module: LiveStub)
      msgs = [%{role: "user", content: "hi"}]

      assert {:ok, _} = Meter.chat(meter, :prompt_arm, %{}, msgs, [])
      assert {:ok, _} = Meter.chat(meter, :imp_program, %{}, msgs, [])
      assert {:error, :budget_exhausted} = Meter.chat(meter, :prompt_arm, %{}, msgs, [])
      assert {:error, :budget_exhausted} = Meter.chat(meter, :imp_program, %{}, msgs, [])

      assert live_calls() == 2
      assert Meter.tickets(meter) == 4

      assert meter |> Meter.calls() |> Enum.map(& &1.outcome) ==
               [:ok, :ok, :budget_exhausted, :budget_exhausted]
    end

    test "is enforced under concurrency: exactly cap calls get through" do
      meter = Meter.new(cap: 25, live_module: LiveStub)

      results =
        1..200
        |> Task.async_stream(
          fn _ -> Meter.chat(meter, :prompt_arm, %{}, [%{role: "user", content: "x"}], []) end,
          max_concurrency: 50
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 25
      assert Enum.count(results, &(&1 == {:error, :budget_exhausted})) == 175
    end

    test "surfaces through decide/3 as :budget_exhausted on either arm" do
      # cap 0: arm A itself is refused.
      assert {:error, :budget_exhausted} =
               decide(:prompt, "Which region first?", Meter.new(cap: 0, live_module: LiveStub))

      # cap 1: A's call spends it, B is refused.
      meter = Meter.new(cap: 1, live_module: LiveStub)

      assert {:error, :budget_exhausted} =
               decide({:imp_program, Program.new()}, "Which region first?", meter)

      assert live_calls() == 1
    end
  end

  describe "one instrument for both arms" do
    test "ProviderLM sends the same transport options arm A's call_provider sends" do
      meter = Meter.new(cap: 10, live_module: LiveStub)

      assert {:ok, _} = decide({:imp_program, Program.new()}, "Which region first?", meter)

      assert_received {:live_called, a_creds, _a_msgs, a_opts}
      assert_received {:live_called, b_creds, _b_msgs, b_opts}

      assert a_opts == b_opts
      assert a_creds == b_creds

      assert Keyword.take(b_opts, [
               :temperature,
               :max_tokens,
               :chat_template_kwargs,
               :model,
               :base_url
             ]) ==
               [
                 base_url: "http://llm.invalid:8085/v1",
                 model: "qwen-stub",
                 temperature: 0.0,
                 max_tokens: 1024,
                 chat_template_kwargs: %{"enable_thinking" => false}
               ]

      assert ProviderLM.provider_opts(@agent) == b_opts
    end

    test "captures latency and usage per call, tagged by arm" do
      meter = Meter.new(cap: 10, live_module: LiveStub)
      assert {:ok, _} = decide({:imp_program, Program.new()}, "Which region first?", meter)

      assert [%{purpose: :prompt_arm} = a, %{purpose: :imp_program} = b] = Meter.calls(meter)

      for call <- [a, b] do
        assert is_integer(call.latency_ms)
        assert call.usage == %{prompt_tokens: 100, completion_tokens: 7}
        assert call.outcome == :ok
      end
    end

    test "blank provider content is :empty_output on arm B, not a parse error" do
      meter = Meter.new(cap: 10, live_module: LiveStub)
      Process.put(:pilot_b_reply, "   ")

      assert {:error, :empty_output} =
               decide({:imp_program, Program.new()}, "Which region first?", meter)
    end
  end

  describe "cassette" do
    setup do
      dir = TestTemp.mkdir!("open-question-pilot-cassette")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, path: Path.join(dir, "cassette.jsonl")}
    end

    test "a recorded run replays with no provider at all", %{path: path} do
      chunks = ["Which region first?", "The pilot starts on Monday, doesn't it?"]
      Process.put(:pilot_a_intent, "open_question")

      recorder = Meter.new(cap: 10, mode: :record, live_module: LiveStub, cassette_path: path)
      live = Enum.map(chunks, &decide({:imp_program, Program.new()}, &1, recorder))
      :ok = Meter.flush!(recorder)
      assert live_calls() == 4

      replayer = Meter.new(cap: 10, mode: :replay, cassette_path: path)
      assert replayer.live_module == nil
      replayed = Enum.map(chunks, &decide({:imp_program, Program.new()}, &1, replayer))

      assert replayed == live
      assert live_calls() == 0

      assert Enum.map(Meter.calls(replayer), & &1.latency_ms) ==
               Enum.map(Meter.calls(recorder), & &1.latency_ms)
    end

    test "a replay miss on arm A raises, even though decide/1 rescues its provider" do
      meter = Meter.new(cap: 10, mode: :replay, cassette: %{})

      error = assert_raise Meter.Miss, fn -> decide(:prompt, "Which region first?", meter) end
      assert Meter.misses(meter) == 1
      assert [key] = Meter.miss_keys(meter)
      assert error.message =~ key
      assert live_calls() == 0
    end

    test "a replay miss on arm B raises", %{path: path} do
      Process.put(:pilot_a_intent, "off_topic")
      recorder = Meter.new(cap: 10, mode: :record, live_module: LiveStub, cassette_path: path)
      # Record arm A only.
      {:ok, _} = decide(:prompt, "Which region first?", recorder)
      :ok = Meter.flush!(recorder)

      replayer = Meter.new(cap: 10, mode: :replay, cassette_path: path)

      assert_raise Meter.Miss, fn ->
        decide({:imp_program, Program.new()}, "Which region first?", replayer)
      end

      assert [
               %{purpose: :prompt_arm, outcome: :ok},
               %{purpose: :imp_program, outcome: :cassette_miss}
             ] =
               Meter.calls(replayer)
    end
  end
end
