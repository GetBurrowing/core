defmodule Platform.Meetings.IntentEval.E2E do
  @moduledoc """
  Pure historical task-delivery scoring helpers for the intent eval.

  Live candidate filing was removed by task 01a17f00-832c-7000-b480-64ab6d710532.
  A live transcript replay now correctly produces zero tasks before final
  triage; the legacy `graduated`/`correct` metrics describe historical task
  delivery observations, not the success criterion for the live rail.

  The caller owns the classifier, dispatcher, queue and database sandbox.
  This module provides gold-label stub answers, frame probes and scoring;
  it never files tasks itself.
  """

  alias Platform.Meetings.IntentFrames
  alias Platform.Meetings.IntentRouting

  @no_target_role "null"

  @doc """
  The JSON body a CORRECT classifier would return for this row.

  `intent` is the gold label, `target_role` is what a correct stage-3
  answer carries (see `stub_target_role/1`), and `evidence_quote` is a
  verbatim span of the utterance — without one the evidence gate demotes
  every positive to `off_topic` and the whole run scores zero for a
  reason that has nothing to do with the pipeline.
  """
  @spec stub_content(map()) :: String.t()
  def stub_content(row) do
    intent = row["label"]

    Jason.encode!(%{
      "intent" => intent,
      "target_role" => stub_target_role(row),
      "confidence" => 0.93,
      "dedupe_key" => "#{intent}:#{:erlang.phash2(row["text"])}",
      "evidence_quote" => evidence_quote(row)
    })
  end

  @doc """
  The `target_role` a correct answer carries.

  A slice that states `expected_target_role` is believed, INCLUDING when
  it states `null` — that is the whole content of stage 3's change, and
  a stub that quietly substituted the default role mapping would test
  the opposite of what shipped. Slices predating that field fall back to
  `IntentRouting`'s declared role for the intent.
  """
  @spec stub_target_role(map()) :: String.t()
  def stub_target_role(row) do
    if Map.has_key?(row, "expected_target_role") do
      row["expected_target_role"] || @no_target_role
    else
      case IntentRouting.entry(row["label"]) do
        %{role: role} -> role
        nil -> @no_target_role
      end
    end
  end

  @doc """
  The citation the stub emits: the utterance itself, verbatim.

  `off_topic` cites the empty string, which is what the prompt requires
  and what the evidence gate expects for a decline.

  Citing the WHOLE utterance is the widest legal citation window, so it
  is also the most permissive input to `IntentFrames.cancelling_frame/2`
  — an operator anywhere in the chunk begins before the quote ends. That
  makes the frame count reported here an UPPER BOUND: a row not
  cancelled under this citation cannot be cancelled under a narrower
  one. It does not work the other way round, so a cancelled row is
  worth checking against a narrower quote before calling it a real
  suppression.
  """
  @spec evidence_quote(map()) :: String.t()
  def evidence_quote(%{"label" => "off_topic"}), do: ""
  def evidence_quote(row), do: row["text"]

  @doc """
  Does `IntentFrames` cancel this row's ask, given the stub's citation?

  A pure, model-free probe, reported alongside the e2e outcome so a row
  that never became a task is attributable: the classifier answered
  correctly and a DETERMINISTIC gate vetoed it, which is a different
  finding from the model getting it wrong and a different finding again
  from the plumbing dropping it.
  """
  @spec frame_verdict(map()) :: :ok | {:cancelled, IntentFrames.class()}
  def frame_verdict(row), do: IntentFrames.cancelling_frame(row["text"], evidence_quote(row))

  @doc """
  Should this row end in a `tasks` row?

  True for every routable intent, false for `off_topic`. Both directions
  are asserted — see the moduledoc on why a decline that produces a task
  is as much a failure as a positive that does not.
  """
  @spec expected_task?(map()) :: boolean()
  def expected_task?(row), do: row["label"] != "off_topic"

  @doc """
  Fold per-row outcomes into a summary.

  Each result is the row plus:

    * `"task_id"` — the id of the `tasks` row it minted, or `nil`
    * `"queue_status"` / `"candidate_state"` — where it stopped
    * `"demoted_from"` — set when the evidence/frame gate downgraded it.
      The addressee gate does not demote (task 01a08fde): an off-roster
      ask keeps its intent with `target_role: "null"`, so it is never
      counted here
    * `"frame_verdict"` — `"ok"` or the cancelling class

  `correct` is the two-sided verdict: a positive that minted a task, or
  a decline that did not.
  """
  @spec score([map()]) :: map()
  def score(results) do
    positives = Enum.filter(results, &expected_task?/1)
    declines = Enum.reject(results, &expected_task?/1)

    %{
      "total" => length(results),
      "positives" => length(positives),
      "declines" => length(declines),
      "graduated" => Enum.count(positives, & &1["task_id"]),
      "correctly_declined" => Enum.count(declines, &is_nil(&1["task_id"])),
      "spurious_tasks" => Enum.count(declines, & &1["task_id"]),
      "demoted" => Enum.count(results, & &1["demoted_from"]),
      "frame_cancelled" => Enum.count(results, &(&1["frame_verdict"] != "ok")),
      "correct" => Enum.count(results, &correct?/1),
      "per_label" => per_group(results, & &1["label"]),
      "per_probe" => per_group(Enum.filter(results, & &1["probe"]), & &1["probe"]),
      "stopped_at" =>
        results
        |> Enum.reject(& &1["task_id"])
        |> Enum.frequencies_by(&"#{&1["queue_status"]}/#{&1["candidate_state"]}")
    }
  end

  defp correct?(row), do: expected_task?(row) == not is_nil(row["task_id"])

  defp per_group(results, key_fun) do
    results
    |> Enum.group_by(key_fun)
    |> Map.new(fn {key, rows} ->
      {key,
       %{
         "rows" => length(rows),
         "graduated" => Enum.count(rows, & &1["task_id"]),
         "expected_task" => Enum.count(rows, &expected_task?/1),
         "demoted" => Enum.count(rows, & &1["demoted_from"]),
         "frame_cancelled" => Enum.count(rows, &(&1["frame_verdict"] != "ok"))
       }}
    end)
  end

  @doc "Render a summary as the text written to stdout."
  @spec report(String.t(), map()) :: String.t()
  def report(slice, summary) do
    [
      "INTENT_EVAL_E2E slice=#{slice} rows=#{summary["total"]} " <>
        "(#{summary["positives"]} positive, #{summary["declines"]} decline)",
      "  ACCEPTANCE: a labelled utterance driven through the real pipeline to a row in `tasks`.",
      "",
      "  graduated to a task     : #{summary["graduated"]} of #{summary["positives"]} positives",
      "  correctly declined      : #{summary["correctly_declined"]} of #{summary["declines"]} declines",
      "  spurious tasks          : #{summary["spurious_tasks"]} (a task minted for small talk)",
      "  two-sided correct       : #{summary["correct"]} of #{summary["total"]}",
      "  demoted by a gate       : #{summary["demoted"]}",
      "  frame-cancelled         : #{summary["frame_cancelled"]} (IntentFrames, deterministic, no model)",
      "",
      "PER LABEL",
      Enum.map(Enum.sort(summary["per_label"]), fn {label, stats} ->
        "  #{String.pad_trailing(label, 20)} rows=#{stats["rows"]} " <>
          "graduated=#{stats["graduated"]}/#{stats["expected_task"]} " <>
          "demoted=#{stats["demoted"]} frame_cancelled=#{stats["frame_cancelled"]}"
      end),
      "",
      "PER PROBE",
      probe_lines(summary["per_probe"]),
      "",
      "WHERE THE NON-GRADUATING ROWS STOPPED (queue_status/candidate_state)",
      Enum.map(Enum.sort(summary["stopped_at"]), fn {where, count} ->
        "  #{String.pad_trailing(where, 32)} #{count}"
      end)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp probe_lines(per_probe) when map_size(per_probe) == 0, do: ["  (none)"]

  defp probe_lines(per_probe) do
    Enum.map(Enum.sort(per_probe), fn {probe, stats} ->
      "  #{String.pad_trailing(probe, 22)} rows=#{stats["rows"]} " <>
        "graduated=#{stats["graduated"]}/#{stats["expected_task"]} " <>
        "frame_cancelled=#{stats["frame_cancelled"]}"
    end)
  end
end
