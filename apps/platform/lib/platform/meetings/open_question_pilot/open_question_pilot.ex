defmodule Platform.Meetings.OpenQuestionPilot do
  @moduledoc """
  The ONE decision path of the open_question pilot (task 01a0e8b5): which
  program decides whether a meeting utterance becomes an `open_question`
  candidate.

  Production (the experiment surface) and the offline scorer both call
  `decide/3`. Neither reimplements it.

  This file lives at `open_question_pilot/open_question_pilot.ex`, not
  beside the directory, because Imp may only be referenced from under
  `lib/platform/meetings/open_question_pilot/` (see
  `test/platform/meetings/open_question_pilot/imp_scope_guard_test.exs`).

  ## Arms

    * `:prompt` (control) — `IntentClassifier.decide/1`, unchanged: the
      six-way `meetings.intent_classify.v1` call and its gates.
      `is_question` is the projection `intent == "open_question"`.
    * `{:imp_program, program}` — arm A's `decide/1` runs FIRST and keeps
      the other four positive intents. Only when A says `open_question` or
      `off_topic` is the Imp program asked
      `%{excerpt: chunk, participants: names}`:
        * B true -> intent `open_question` with the WHOLE chunk as
          `evidence_quote`, pushed through the SAME post-model gates via
          `IntentClassifier.gate_answer/2` (citation, frames, addressee).
          `target_role` is A's when A said open_question, else the
          no-target sentinel. B's addressee does NOT change it.
        * B false -> `off_topic`. If A had said open_question, the row
          carries `demoted_from: "open_question"`,
          `demotion_reason: :imp_not_question`.
      B's addressee is recorded under `:imp` for scoring only.

  No gate, lexicon or confidence threshold is changed by this module.

  ## Options

    * `:meter` — an `OpenQuestionPilot.Meter`. When given, arm A's provider
      is replaced by `OpenQuestionPilot.MeteredProvider` over it and arm B's
      program runs on `OpenQuestionPilot.ProviderLM` over it, so both arms
      are counted, timed and cassetted by one instrument. Without it the
      decide/1 args' provider and the program's own LM are used as given.
    * `:base_args` — the `IntentClassifier.decide/1` argument map minus
      `:chunk_text`; required when the second argument is a dataset row,
      unless `:args_for` is given.
    * `:args_for` — `fn row -> decide/1 args end`, for a caller whose args
      vary per row (the pilot runner renders arm A's prompt per row).

  ## Returns

  `{:ok, decision}` — `decide/1`'s decision map plus `:arm`,
  `:is_question` (the projection) and `:imp` (`nil` for arm A or when B
  was not asked, else `%{is_question: _, addressee: _}`).

  `{:error, class}` where class is `:parse_error`, `:empty_output`,
  `:model_error` or `:budget_exhausted`. Error classes are never folded
  into a label. A cassette replay miss RAISES `Meter.Miss`.
  """

  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.OpenQuestionPilot.Meter
  alias Platform.Meetings.OpenQuestionPilot.MeteredProvider
  alias Platform.Meetings.OpenQuestionPilot.ProviderLM

  @type arm :: :prompt | {:imp_program, term()}
  @type error_class :: :parse_error | :empty_output | :model_error | :budget_exhausted

  # The intents on which arm B is asked. Every other intent is A's.
  @b_asked ["open_question", "off_topic"]

  @doc "Decide one chunk (a `decide/1` args map) or one dataset row under `arm`."
  @spec decide(arm(), map(), keyword()) :: {:ok, map()} | {:error, error_class()}
  def decide(arm, row_or_chunk, opts \\ []) do
    args = to_args(row_or_chunk, opts)
    meter = Keyword.get(opts, :meter)

    with {:ok, a} <- run_a(args, meter) do
      case arm do
        :prompt ->
          {:ok, finish(a, :prompt, nil)}

        {:imp_program, program} ->
          if a.intent in @b_asked,
            do: run_b(program, a, args, meter),
            else: {:ok, finish(a, :imp_program, nil)}
      end
    end
  end

  # Per-chunk call cap on the imp_program arm in production: A's one call,
  # plus B's call and the one adapter fallback Imp makes on a parse failure,
  # plus one of slack. A chunk past it is `:budget_exhausted`, never a
  # runaway.
  @live_call_cap 4

  @doc """
  The production read point's entrance (`IntentClassifier.classify_and_enqueue/4`).

  `:prompt` is `decide(:prompt, args)` with no meter: exactly
  `IntentClassifier.decide(args)`, so the control arm's provider traffic is
  unchanged. `{:imp_program, _}` runs under a fresh live meter over
  `provider_module` (the classifier's own), capped per chunk, and the meter
  is torn down afterwards.
  """
  @spec decide_live(arm(), map(), module()) :: {:ok, map()} | {:error, error_class()}
  def decide_live(:prompt, args, _provider_module), do: decide(:prompt, args)

  def decide_live({:imp_program, _} = arm, args, provider_module) do
    meter = Meter.new(cap: @live_call_cap, live_module: provider_module)

    try do
      decide(arm, args, meter: meter)
    after
      Meter.close(meter)
    end
  end

  @doc "The participant names a chunk or row is shown to arm B with."
  @spec participant_names(map()) :: [String.t()]
  def participant_names(args) do
    (Map.get(args, :participant_names) || Map.get(args, :participants) || [])
    |> Enum.map(fn
      name when is_binary(name) -> name
      %{display_name: name} -> name
      other -> to_string(other)
    end)
  end

  # ── arm A ────────────────────────────────────────────────────────────────

  defp run_a(args, nil), do: IntentClassifier.decide(args)

  defp run_a(args, %Meter{} = meter) do
    misses = Meter.misses(meter)
    previous = MeteredProvider.bind(meter)

    result =
      try do
        IntentClassifier.decide(%{args | provider_module: MeteredProvider})
      after
        if previous, do: MeteredProvider.bind(previous), else: MeteredProvider.unbind()
      end

    # decide/1 rescues whatever its provider raises; a replay miss must
    # not come back as :model_error.
    raise_on_new_miss!(meter, misses)

    case result do
      {:error, :model_error} ->
        if match?(%{outcome: :budget_exhausted}, Meter.last(meter, :prompt_arm)),
          do: {:error, :budget_exhausted},
          else: result

      other ->
        other
    end
  end

  # ── arm B ────────────────────────────────────────────────────────────────

  defp run_b(program, a, args, meter) do
    program = if meter, do: Imp.with_lm(program, ProviderLM.new(meter, args.agent)), else: program
    misses = if meter, do: Meter.misses(meter), else: 0

    result =
      Imp.call(program, %{excerpt: args.chunk_text, participants: participant_names(args)})

    if meter, do: raise_on_new_miss!(meter, misses)

    with {:ok, prediction} <- classify_b(result) do
      {:ok, apply_b(prediction, a, args)}
    end
  end

  defp classify_b({:ok, prediction}) do
    case bool(field(prediction, :is_question)) do
      {:ok, is_question} ->
        {:ok, %{is_question: is_question, addressee: addressee(field(prediction, :addressee))}}

      :error ->
        {:error, :parse_error}
    end
  end

  defp classify_b({:error, %Imp.AdapterParseError{}}), do: {:error, :parse_error}
  defp classify_b({:error, {:empty_output, _}}), do: {:error, :empty_output}
  defp classify_b({:error, :budget_exhausted}), do: {:error, :budget_exhausted}
  defp classify_b({:error, _}), do: {:error, :model_error}

  defp apply_b(%{is_question: true} = imp, a, args) do
    target_role =
      if a.intent == "open_question", do: a.target_role, else: IntentClassifier.no_target_role()

    {:ok, gated} =
      IntentClassifier.gate_answer(
        %{
          intent: "open_question",
          target_role: target_role,
          confidence: a.confidence,
          evidence_quote: args.chunk_text
        },
        args
      )

    finish(gated, :imp_program, imp)
  end

  defp apply_b(%{is_question: false} = imp, %{intent: "open_question"} = a, _args) do
    a
    |> Map.merge(%{
      intent: "off_topic",
      target_role: IntentClassifier.no_target_role(),
      evidence_quote: "",
      demoted_from: "open_question",
      demotion_reason: :imp_not_question,
      addressee_nulled_from: nil
    })
    |> finish(:imp_program, imp)
  end

  defp apply_b(%{is_question: false} = imp, a, _args), do: finish(a, :imp_program, imp)

  # ── shared ───────────────────────────────────────────────────────────────

  defp finish(decision, arm, imp) do
    decision
    |> Map.put(:arm, arm)
    |> Map.put(:is_question, decision.intent == "open_question")
    |> Map.put(:imp, imp)
  end

  defp to_args(%{chunk_text: _} = args, _opts), do: args

  defp to_args(%{"text" => _} = row, opts) do
    case Keyword.get(opts, :args_for) do
      fun when is_function(fun, 1) -> fun.(row)
      nil -> base_args(row, opts)
    end
  end

  defp base_args(%{"text" => text} = row, opts) do
    opts
    |> Keyword.fetch!(:base_args)
    |> Map.put(:chunk_text, text)
    |> Map.put(:participant_names, Map.get(row, "participants", []))
  end

  defp raise_on_new_miss!(meter, before) do
    if Meter.misses(meter) > before do
      keys = meter |> Meter.miss_keys() |> Enum.drop(before)

      raise Meter.Miss,
        message:
          "open_question pilot cassette miss during decide/3 for key(s) #{Enum.join(keys, ", ")} " <>
            "— replay never falls through to a live call"
    end
  end

  defp field(%Imp.Prediction{} = prediction, key), do: Imp.get(prediction, key)
  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp bool(value) when is_boolean(value), do: {:ok, value}
  defp bool("true"), do: {:ok, true}
  defp bool("false"), do: {:ok, false}
  defp bool(_), do: :error

  defp addressee(name) when is_binary(name) do
    case String.trim(name) do
      "" ->
        "none"

      trimmed ->
        if String.downcase(trimmed) in ["none", "null", "nobody"], do: "none", else: trimmed
    end
  end

  defp addressee(_), do: "none"
end
