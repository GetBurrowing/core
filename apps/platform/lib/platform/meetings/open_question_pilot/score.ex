defmodule Platform.Meetings.OpenQuestionPilot.Score do
  @moduledoc """
  Scores one arm of the open_question pilot over a set of dataset rows
  (task 01a0e8b5). Every row goes through `OpenQuestionPilot.decide/3`,
  the same path production takes; nothing here re-derives a decision.

  ## What it reports

    * **precision / recall of `is_question`** over the rows that produced a
      decision. A row that errored is NOT a label: `errors` counts
      `:parse_error`, `:empty_output`, `:model_error` and
      `:budget_exhausted` separately, and those rows are outside the
      confusion matrix. `nil` when a denominator is zero.
    * **latency**, p50 / p95 (nearest rank) per chunk (wall time of
      `decide/3`) and per LM call (from the meter, split by purpose).
    * **tokens and cost**: prompt and completion tokens from the meter;
      cost = total tokens / 1000 x `:price_per_1k_tokens`. The default
      price is 0.0 because the classifier model is self-hosted, and the
      report says so in `cost_basis` rather than printing a bare `$0.00`.
    * **privacy**, a HARD constraint, at two levels over `privacy: true`
      rows:
        * (i) output: rows whose decision is routable as `open_question`
          or `action_items`;
        * (ii) artefact: every routable privacy row (any intent other than
          `off_topic`) is put through its handler's `gather_context/2` via
          `:artefact_check`; the count is rows that were NOT refused.
          `gather_context_check/2` builds the production check (the
          method of `scribe_misfire_rate_test.exs`).
      `privacy.ok?` is true only when both counts are zero.
    * **addressee** (information only; it does not change routing): of the
      rows labelled as questions to a named participant, how many B named.

  ## Options

  Everything `decide/3` takes (`:meter`, `:base_args`), plus:

    * `:artefact_check` (required) — `fn row, decision -> :refused | :not_refused end`.
    * `:price_per_1k_tokens` — default `0.0`.
    * `:cost_basis` — default `"self-hosted model: $0.00 per token"`.
  """

  alias Platform.Meetings.OpenQuestionPilot
  alias Platform.Meetings.OpenQuestionPilot.Meter
  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Handlers.MeetingBriefWorthy
  alias Platform.Responsibilities.Handlers.MeetingOpenQuestion
  alias Platform.Responsibilities.Responsibility

  @error_classes [:parse_error, :empty_output, :model_error, :budget_exhausted]
  @output_leak_intents ["open_question", "action_items"]

  @handlers %{
    "action_items" => MeetingActionItems,
    "brief_worthy" => MeetingBriefWorthy,
    "open_question" => MeetingOpenQuestion
  }

  @doc "Score `arm` over `rows`."
  @spec run([map()], OpenQuestionPilot.arm(), keyword()) :: map()
  def run(rows, arm, opts) do
    artefact_check = Keyword.fetch!(opts, :artefact_check)
    meter = Keyword.get(opts, :meter)
    calls_before = if meter, do: length(Meter.calls(meter)), else: 0

    per_row =
      Enum.map(rows, fn row ->
        started = System.monotonic_time(:microsecond)
        result = OpenQuestionPilot.decide(arm, row, opts)
        elapsed_ms = (System.monotonic_time(:microsecond) - started) / 1000

        %{row: row, result: result, latency_ms: elapsed_ms}
        |> Map.put(:artefact, artefact(row, result, artefact_check))
      end)

    calls = if meter, do: Enum.drop(Meter.calls(meter), calls_before), else: []
    price = Keyword.get(opts, :price_per_1k_tokens, 0.0)

    %{
      arm: arm_name(arm),
      n: length(rows),
      scored: Enum.count(per_row, &match?({:ok, _}, &1.result)),
      errors: errors(per_row),
      confusion: confusion(per_row),
      precision: precision(confusion(per_row)),
      recall: recall(confusion(per_row)),
      privacy: privacy(per_row),
      latency: %{
        chunk: percentiles(Enum.map(per_row, & &1.latency_ms)),
        lm_call: percentiles(call_latencies(calls)),
        lm_call_by_purpose:
          calls
          |> Enum.group_by(& &1.purpose)
          |> Map.new(fn {purpose, cs} -> {purpose, percentiles(call_latencies(cs))} end)
      },
      lm_calls: length(calls),
      tokens: tokens(calls),
      cost_usd: tokens(calls).total / 1000 * price,
      cost_basis: Keyword.get(opts, :cost_basis, "self-hosted model: $0.00 per token"),
      addressee: addressee(per_row),
      rows: Enum.map(per_row, &row_summary/1)
    }
  end

  @doc """
  The production artefact check: put a routable decision through its
  handler's `gather_context/2` in `meeting_id` / `room_id` (a meeting whose
  space holds no canvas), as `scribe_misfire_rate_test.exs` does.
  An intent with no meeting handler is `:not_refused`: nothing stops it.
  """
  @spec gather_context_check(String.t(), String.t()) :: (map(), map() -> :refused | :not_refused)
  def gather_context_check(meeting_id, room_id) do
    fn row, decision ->
      case Map.fetch(@handlers, decision.intent) do
        {:ok, handler} ->
          meta = %{
            kind: :event_topic,
            payload: %{
              intent_id: Platform.Types.UUIDv7.generate(),
              meeting_id: meeting_id,
              room_id: room_id,
              chunk_excerpt: row["text"],
              classified_intent: decision.intent,
              confidence: decision.confidence,
              speaker: nil
            }
          }

          case handler.gather_context(%Responsibility{key: handler.key()}, meta) do
            {:ok, _ctx} -> :not_refused
            {:error, _reason} -> :refused
          end

        :error ->
          :not_refused
      end
    end
  end

  # Only routable privacy rows are put through the artefact check.
  defp artefact(%{"privacy" => true} = row, {:ok, %{intent: intent} = decision}, check)
       when intent != "off_topic",
       do: check.(row, decision)

  defp artefact(_row, _result, _check), do: :not_checked

  defp errors(per_row) do
    base = Map.new(@error_classes, &{&1, 0})

    Enum.reduce(per_row, base, fn
      %{result: {:error, class}}, acc -> Map.update(acc, class, 1, &(&1 + 1))
      _, acc -> acc
    end)
  end

  defp confusion(per_row) do
    Enum.reduce(per_row, %{tp: 0, fp: 0, fn: 0, tn: 0}, fn
      %{row: row, result: {:ok, decision}}, acc ->
        cell =
          case {row["is_question"], decision.is_question} do
            {true, true} -> :tp
            {false, true} -> :fp
            {true, false} -> :fn
            {false, false} -> :tn
          end

        Map.update!(acc, cell, &(&1 + 1))

      _, acc ->
        acc
    end)
  end

  defp precision(%{tp: tp, fp: fp}) when tp + fp > 0, do: tp / (tp + fp)
  defp precision(_), do: nil

  defp recall(%{tp: tp, fn: fn_}) when tp + fn_ > 0, do: tp / (tp + fn_)
  defp recall(_), do: nil

  defp privacy(per_row) do
    rows = Enum.filter(per_row, & &1.row["privacy"])

    output =
      Enum.count(rows, fn
        %{result: {:ok, %{intent: intent}}} -> intent in @output_leak_intents
        _ -> false
      end)

    checked = Enum.count(rows, &(&1.artefact != :not_checked))
    not_refused = Enum.count(rows, &(&1.artefact == :not_refused))

    %{
      rows: length(rows),
      output_routable: output,
      artefact_checked: checked,
      artefact_not_refused: not_refused,
      ok?: output == 0 and not_refused == 0
    }
  end

  defp addressee(per_row) do
    labelled =
      Enum.filter(per_row, fn %{row: row} ->
        row["is_question"] and row["addressee"] != "none"
      end)

    correct =
      Enum.count(labelled, fn
        %{row: row, result: {:ok, %{imp: %{addressee: named}}}} -> named == row["addressee"]
        _ -> false
      end)

    %{
      labelled: length(labelled),
      named_correctly: correct,
      note: "information only; routing unchanged"
    }
  end

  defp tokens(calls) do
    prompt = calls |> Enum.map(& &1.usage.prompt_tokens) |> Enum.sum()
    completion = calls |> Enum.map(& &1.usage.completion_tokens) |> Enum.sum()
    %{prompt: prompt, completion: completion, total: prompt + completion}
  end

  defp call_latencies(calls), do: for(%{latency_ms: ms} <- calls, is_number(ms), do: ms)

  @doc "Nearest-rank p50 and p95 of a list of numbers; nil for an empty list."
  @spec percentiles([number()]) :: %{
          p50: number() | nil,
          p95: number() | nil,
          n: non_neg_integer()
        }
  def percentiles([]), do: %{p50: nil, p95: nil, n: 0}

  def percentiles(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    rank = fn p -> Enum.at(sorted, max(ceil(p * n) - 1, 0)) end
    %{p50: rank.(0.5), p95: rank.(0.95), n: n}
  end

  defp row_summary(%{row: row, result: result, latency_ms: ms, artefact: artefact}) do
    base = %{id: row["id"], expected: row["is_question"], latency_ms: ms, artefact: artefact}

    case result do
      {:ok, d} ->
        Map.merge(base, %{
          predicted: d.is_question,
          intent: d.intent,
          demotion_reason: d.demotion_reason,
          imp: d.imp
        })

      {:error, class} ->
        Map.merge(base, %{predicted: nil, error: class})
    end
  end

  defp arm_name(:prompt), do: "prompt"
  defp arm_name({:imp_program, _}), do: "imp_program"
end
