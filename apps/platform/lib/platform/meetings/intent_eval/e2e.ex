defmodule Platform.Meetings.IntentEval.E2E do
  @moduledoc """
  The end-to-end arm of the intent eval: score a labelled utterance by
  whether it produces a **row in `tasks`** (task `01a06575` stage 4).

  ## Why the offline harness could not have caught the live failure

  `Platform.Meetings.IntentEval.Harness` calls
  `IntentClassifier.decide/1` and stops there. `decide/1` is a
  provider call, a JSON parse and an evidence check — and it is THREE
  stages upstream of anything a meeting produces. It never touches the
  five-check skip chain in `deliver_chunk/3`, the debounce buffer,
  `IntentQueue`, the candidate mirror, `IntentDispatcher`, the 30-second
  countdown, `Candidates.claim_due/2` or `graduate/2`.

  Production had **280 `meeting_candidates` rows and zero with a
  `task_id`** while that harness scored `0.975` f1 on `off_topic` and
  fired on `59 of 60` control rows. Both numbers were honest. Neither
  was about the thing that was broken: the defect was a `state != :acting`
  predicate in `claim_due/2`, which no amount of classification accuracy
  reaches. An instrument that stops at `decide/1` is *demonstrably
  compatible with total failure*, and this module exists so that is no
  longer true of the eval as a whole.

  ## What this measures, and what it deliberately does NOT

  The stub answers with the row's **gold label**. That is not a
  concession, it is the design:

    * IN SCOPE — given a correct classification, does the platform turn
      it into a deliverable? Every stage from `classify_and_enqueue/4`
      to a `tasks` row, plus the deterministic gates
      (`IntentFrames`) that can veto a correct classification after the
      fact.
    * OUT OF SCOPE — whether the model classifies correctly. That is
      what `Harness` measures, and it needs a reachable endpoint. The
      two arms answer different questions and neither substitutes for
      the other.

  So a `graduated` count of 0 here means the plumbing is broken; it can
  never mean the model is bad. That separation is the point.

  ## Declines are scored too

  A row labelled `off_topic` must produce **no** task. Until task
  01a06575 stage 5 that was not a property of the platform: the
  candidate was armed at mirror time, before any dispatch decision for
  it existed, and only stopped counting down because the dispatcher
  reached it first and closed it. A dispatch slow enough to lose that
  race — a responsibility handler holding the meeting's serial cursor
  across a model round-trip, with small talk queued behind it — turned
  an aside into a task. `Candidates.routable_attrs?/1` now disarms an
  unroutable classification at classification time, so the decline is a
  rule rather than a race.

  So `expected_task?/1` is a two-sided prediction and both sides are
  counted: `graduated` and `correctly_declined` are separate columns and
  a report that only shows one is hiding half the failure modes.

  ## This module owns no processes

  It is pure. The caller supervises the classifier, the dispatcher and
  the queue, owns the DB sandbox, and drives the sweeper — because all
  of that is ExUnit's job and none of it belongs in a release. What
  lives here is the part that must not be re-derived per caller: the
  stub answer, the citation, the frame probe, and the scoring.
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
    * `"demoted_from"` — set when the evidence/frame gate downgraded it
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
