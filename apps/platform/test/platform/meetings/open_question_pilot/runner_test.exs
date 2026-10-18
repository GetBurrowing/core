defmodule Platform.Meetings.OpenQuestionPilot.RunnerTest do
  @moduledoc """
  The pilot runner (task 01a0e8b5 stage 4) without a network: the hard
  caps end a GEPA run as `:budget_exhausted`, the output goes where it is
  told and never over the checked-in program, privacy selection is
  lexicographic, and the metric treats a privacy row as a constraint.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Mix.Tasks.Platform.OpenQuestionPilot.Run, as: RunTask
  alias Platform.Meetings.OpenQuestionPilot.Programs
  alias Platform.Meetings.OpenQuestionPilot.Runner
  alias Platform.TestTemp

  defmodule StaticProvider do
    @moduledoc false
    # A static model behind the provider contract: the classifier prompt
    # gets off_topic, an Imp task call gets a JSON "not a question",
    # anything else (a GEPA reflection) gets a fenced instruction. Every call
    # is counted in the calling test's :counters ref if one is registered.
    def chat(_credentials, messages, _opts) do
      if ref = :persistent_term.get({__MODULE__, :counter}, nil), do: :counters.add(ref, 1, 1)
      user = Enum.find_value(messages, "", &(to_string(&1.role) == "user" && &1.content))
      system = Enum.find_value(messages, "", &(to_string(&1.role) == "system" && &1.content))

      content =
        cond do
          system =~ "meetings.intent_classify" ->
            ~s({"intent": "off_topic", "target_role": null, "confidence": 0.5, "evidence_quote": ""})

          # A JSON answer to the Chat adapter fails its parse and Imp retries
          # with the JSON adapter: TWO model calls per row. That is exactly
          # the overshoot GEPA's between-iteration max_metric_calls check
          # cannot see (it counts metric calls, not model calls), so the
          # meter is what stops the run.
          user =~ "[[ ## excerpt ## ]]" ->
            ~s({"is_question": false, "addressee": "none"})

          true ->
            "```\nDecide whether the excerpt is a genuine open question.\n```"
        end

      {:ok,
       %{
         content: content,
         finish_reason: "stop",
         usage: %{"prompt_tokens" => 10, "completion_tokens" => 2}
       }}
    end
  end

  describe "the mix task's flags" do
    setup do
      previous = System.get_env("INTENT_EVAL_BASE_URL")
      System.delete_env("INTENT_EVAL_BASE_URL")

      on_exit(fn ->
        if previous,
          do: System.put_env("INTENT_EVAL_BASE_URL", previous),
          else: System.delete_env("INTENT_EVAL_BASE_URL")
      end)

      :ok
    end

    test "default to the stage's caps and the configured classifier endpoint" do
      opts = RunTask.parse_args!([])
      assert opts[:max_metric_calls] == 300
      assert opts[:hard_call_cap] == 400
      assert opts[:reflection_cap] == 40
      assert opts[:base_url] == "http://localhost:8085/v1"
      assert opts[:model] == "classifier"
      assert opts[:out_dir] == "priv/imp_pilot/open_question"

      opts = RunTask.parse_args!(~w(--hard-call-cap 30 --max-metric-calls 20 --out-dir /x))
      assert opts[:hard_call_cap] == 30
      assert opts[:max_metric_calls] == 20
      assert opts[:out_dir] == "/x"

      assert_raise Mix.Error, fn -> RunTask.parse_args!(~w(--skip-baseline)) end
    end

    # Task 01a14b9e stage 2: the endpoint is the operator's, given at run time.
    test "INTENT_EVAL_BASE_URL replaces the shipped endpoint; --base-url beats both" do
      System.put_env("INTENT_EVAL_BASE_URL", " http://192.0.2.10:8085/v1 ")
      assert RunTask.parse_args!([])[:base_url] == "http://192.0.2.10:8085/v1"

      assert RunTask.parse_args!(~w(--base-url http://192.0.2.20:8085/v1))[:base_url] ==
               "http://192.0.2.20:8085/v1"

      System.put_env("INTENT_EVAL_BASE_URL", "  ")
      assert RunTask.parse_args!([])[:base_url] == "http://localhost:8085/v1"
    end
  end

  describe "hard caps" do
    setup do
      dir = TestTemp.mkdir!("open-question-pilot-run")
      ref = :counters.new(1, [])
      :persistent_term.put({StaticProvider, :counter}, ref)

      on_exit(fn ->
        File.rm_rf!(dir)
        :persistent_term.erase({StaticProvider, :counter})
      end)

      {:ok, dir: dir}
    end

    test "--hard-call-cap 30 --max-metric-calls 20 halts GEPA as :budget_exhausted", %{dir: dir} do
      checked_in = Path.join(Programs.dir(), "program_b.json")
      before = File.exists?(checked_in) && File.read!(checked_in)

      {results, _log} =
        with_log(fn ->
          Runner.run(
            out_dir: dir,
            live_module: StaticProvider,
            hard_call_cap: 30,
            max_metric_calls: 20,
            props: %{},
            git_sha: "test"
          )
        end)

      optimiser = results["optimiser"]
      assert optimiser["stop_reason"] == "budget_exhausted"
      assert optimiser["task_lm_calls"] <= 30
      assert optimiser["task_lm_tickets"] > 30
      assert optimiser["hard_call_cap"] == 30

      # Everything landed in the tmp dir; the checked-in program is untouched.
      assert File.exists?(Path.join(dir, "results.json"))
      assert File.exists?(Path.join([dir, "cassettes", "test_prompt.jsonl"]))
      assert (File.exists?(checked_in) && File.read!(checked_in)) == before

      # Baseline A still ran on the whole test split.
      assert results["arms"]["prompt"]["n"] == 35
      assert results["spend"]["cost_usd"] == 0.0
    end
  end

  # Task 01a14dce stage 1: prompt_a.txt changed, so arm A is asked again.
  describe "rerecord_arm_a!/3" do
    setup do
      dir = TestTemp.mkdir!("open-question-pilot-rerecord")
      File.cp!(Path.join(Programs.dir(), "results.json"), Path.join(dir, "results.json"))
      ref = :counters.new(1, [])
      :persistent_term.put({StaticProvider, :counter}, ref)

      on_exit(fn ->
        File.rm_rf!(dir)
        :persistent_term.erase({StaticProvider, :counter})
      end)

      {:ok, dir: dir, counter: ref}
    end

    test "asks the model once per TEST row and replaces arm A's block only", %{
      dir: dir,
      counter: counter
    } do
      original = Path.join(Programs.dir(), "results.json") |> File.read!() |> Jason.decode!()
      checked_in_cassette = Path.join([Programs.dir(), "cassettes", "test_prompt.jsonl"])
      cassette_before = File.read!(checked_in_cassette)

      {results, _log} =
        with_log(fn ->
          Runner.rerecord_arm_a!(dir, "test reason",
            live_module: StaticProvider,
            base_url: "http://localhost:8085/v1",
            model: "classifier",
            props: %{"build_info" => "b-test"},
            git_sha: "test"
          )
        end)

      assert :counters.get(counter, 1) == 35
      assert results["prompt_a"]["sha256"] == Runner.arm_a_config()["prompt_sha256"]
      assert results["arms"]["prompt"]["n"] == 35
      assert results["arms"]["prompt"]["lm_calls"] == 35
      # StaticProvider answers off_topic to every row: nothing is a question.
      assert results["arms"]["prompt"]["confusion"]["tp"] == 0
      assert results["spend"]["calls"]["baseline_a"] == 35

      for key <- ["optimiser", "selection", "dataset", "provider", "program_b", "rescored"] do
        assert results[key] == original[key], "#{key} must be the original run's"
      end

      assert results["arms"]["imp_program"] == original["arms"]["imp_program"]

      assert [entry] = results["rerecorded"] -- (original["rerecorded"] || [])
      assert entry["reason"] == "test reason"
      assert entry["lm_calls"] == 35
      assert entry["base_url_host"] == "localhost"
      assert entry["build_info"] == "b-test"
      assert entry["previous_prompt_a_sha256"] == original["prompt_a"]["sha256"]

      # Written to the dir it was given, never over the checked-in cassette.
      assert Path.join(dir, "results.json") |> File.read!() |> Jason.decode!() == results
      assert File.exists?(Path.join([dir, "cassettes", "test_prompt.jsonl"]))
      assert File.read!(checked_in_cassette) == cassette_before
    end
  end

  describe "privacy selection is lexicographic" do
    @candidates [
      %{id: "c-best", val_score: 0.96},
      %{id: "c-second", val_score: 0.92},
      %{id: "c-third", val_score: 0.80}
    ]

    test "the best-val candidate that leaks one privacy row loses to the next clean one" do
      leaks = %{"c-best" => 1, "c-second" => 0, "c-third" => 0}
      result = Runner.select_admissible(@candidates, &Map.fetch!(leaks, &1.id))

      assert result.admissible
      assert result.chosen.id == "c-second"

      assert result.checked == [
               %{id: "c-best", val_score: 0.96, violations: 1},
               %{id: "c-second", val_score: 0.92, violations: 0}
             ]
    end

    test "no clean candidate means B is inadmissible" do
      result = Runner.select_admissible(@candidates, fn _ -> 2 end)
      refute result.admissible
      assert result.chosen == nil
      assert length(result.checked) == 3
    end
  end

  describe "the metric" do
    defp ex(fields), do: Runner.example(fields)

    test "a privacy row predicted true scores 0 with the privacy feedback, whatever its label" do
      for label <- [true, false] do
        row = %{
          "text" => "t",
          "participants" => ["A"],
          "is_question" => label,
          "privacy" => true,
          "id" => "p"
        }

        assert Runner.metric(ex(row), %{is_question: true}) ==
                 %{score: 0.0, feedback: Runner.privacy_feedback()}

        assert %{score: 1.0} = Runner.metric(ex(row), %{is_question: false})
      end
    end

    test "an ordinary row scores its label match" do
      row = %{
        "text" => "t",
        "participants" => ["A"],
        "is_question" => true,
        "privacy" => false,
        "id" => "q"
      }

      assert %{score: 1.0} = Runner.metric(ex(row), %{is_question: true})
      assert %{score: +0.0} = Runner.metric(ex(row), %{is_question: false})
      assert %{score: +0.0} = Runner.metric(ex(row), %{is_question: "maybe"})
    end
  end

  test "Wilson intervals" do
    assert Runner.wilson(0, 0) == nil
    assert [lo, hi] = Runner.wilson(9, 10)
    assert lo < 0.9 and hi > 0.9 and hi <= 1.0
  end
end
