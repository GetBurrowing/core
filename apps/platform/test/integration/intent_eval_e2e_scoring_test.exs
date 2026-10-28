defmodule Platform.Integration.IntentEvalE2EScoringTest do
  @moduledoc "Gold-label transcript replay must preserve candidate evidence without filing live tasks."

  use Platform.DataCase, async: false

  import Ecto.Query, only: [where: 2, where: 3, order_by: 2]

  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Meetings.CandidateSweeper
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.Countdown
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentDispatcher
  alias Platform.Meetings.IntentEval
  alias Platform.Meetings.IntentEval.E2E
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tasks.Task, as: WorkTask

  @responsibility_key "meetings.intent_classify"
  @slice "unaddressed_meeting_speech_48"

  # The two utterances of the held-cursor contention case. The small
  # talk is the reviewer's own: an ordinary aside, spoken behind a
  # routable ask, in an ordinary meeting.
  @routable_utterance "we should make the dashboard load faster"
  @small_talk_utterance "did you catch the game last night, that last quarter was something"

  # Every terminal-or-settled signal the classifier can emit for one
  # chunk. Waiting on this pair rather than polling for a queue row is
  # what lets a content-gated utterance finish in milliseconds instead
  # of burning a poll timeout — and it records WHY it was skipped.
  @classified [:platform, :meetings, :intent_classified]
  @skipped [:platform, :meetings, :intent_classifier, :skipped]

  defmodule StubProvider do
    @moduledoc """
    Same shape as the sibling e2e tests' stubs: reads a fun off the
    classifier process's dictionary. Kept private to this file so a
    change to a sibling cannot silently reshape this run.
    """
    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  setup do
    classifier_name = :"intent_eval_e2e_classifier_#{System.unique_integer([:positive])}"
    dispatcher_name = :"intent_eval_e2e_dispatcher_#{System.unique_integer([:positive])}"

    {:ok, classifier_pid} =
      start_supervised({IntentClassifier, name: classifier_name, provider_module: StubProvider})

    {:ok, _dispatcher_pid} =
      start_supervised({IntentDispatcher, name: dispatcher_name, tick_interval_ms: 60_000})

    classifier_agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "intent-eval-e2e-classifier-#{System.unique_integer([:positive])}",
        name: "Intent Eval E2E Classifier",
        status: "active",
        kind: "native"
      })
      |> Repo.insert!()

    {:ok, _} = Roles.set_override(@responsibility_key, classifier_agent.id)

    handler = "intent-eval-e2e-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [@classified, @skipped],
        fn event, _measurements, metadata, _ ->
          send(test_pid, {:classifier_settled, event, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, classifier_pid: classifier_pid}
  end

  # ── The run ────────────────────────────────────────────────────────────────

  describe "the labelled corpus during a live meeting" do
    @tag timeout: 600_000
    test "neither actionable utterances nor declines file tasks before final triage", %{
      classifier_pid: classifier_pid
    } do
      rows = load_slice!(@slice)
      assert length(rows) == 48, "the slice changed size without this test being updated"

      results = Enum.map(rows, &run_row(&1, classifier_pid))
      summary = E2E.score(results)

      # The report is the deliverable. Printed unconditionally so the
      # numbers exist whether the run passes or fails — a stage that can
      # only report on success reports nothing on the day it matters.
      IO.puts("\n" <> E2E.report(@slice, summary) <> "\n")

      # Task creation is now intentionally deferred to final triage. Keep
      # the classifier/frame facts pinned while requiring zero live filings.
      assert summary["graduated"] == 0
      assert summary["spurious_tasks"] == 0
      assert summary["positives"] == 38
      assert summary["declines"] == 10
      assert summary["correctly_declined"] == 10
      assert summary["demoted"] == 7
      assert summary["frame_cancelled"] == 7
      assert Enum.all?(results, &is_nil(&1["task_id"]))
    end
  end

  describe "small talk queued behind a held serial cursor" do
    @tag timeout: 120_000
    test "does not graduate into a task, whatever the dispatcher is doing", %{
      classifier_pid: classifier_pid
    } do
      # THE SHAPE, reproduced: one routable utterance dispatched to a
      # responsibility handler — which HOLDS the meeting's serial cursor
      # across its model round-trip, under a 90s ack window — and one
      # piece of small talk spoken behind it, sitting `:queued` because
      # the cursor is busy.
      #
      # Nothing here is pathological. There is no injected delay: the
      # handler simply has not answered yet, which is the ordinary state
      # of a dispatched row for as long as a model call takes. The
      # `off_topic` row's countdown was armed at MIRROR TIME, before any
      # dispatch decision for it existed, so it graduates on schedule
      # while it waits — and the only thing that normally stops it is
      # the dispatcher getting to it first. That is a race, not a rule.
      plant_stub_fun(classifier_pid, fn _credentials, messages, _opts ->
        {:ok, %{content: contention_stub_content(user_content(messages))}}
      end)

      {_project, meeting} = create_meeting!()
      on_exit(fn -> IntentQueue.stop(meeting.id) end)

      room_id = "held-cursor-contention-#{System.unique_integer([:positive])}"

      # 1. Alice says something routable. It dispatches to the
      #    `meetings.action_items` responsibility and takes the cursor.
      append_transcript_segment!(meeting, room_id, "alice", @routable_utterance,
        id: Ecto.UUID.generate()
      )

      routable_row = await_row_with_status(meeting.id, :dispatched)
      assert to_string(routable_row.classified_intent) == "action_items"

      # 2. Bruno makes small talk while the handler is still thinking.
      append_transcript_segment!(meeting, room_id, "bruno", @small_talk_utterance,
        id: Ecto.UUID.generate()
      )

      small_talk_row = await_row_with_status(meeting.id, :queued)
      assert to_string(small_talk_row.classified_intent) == "off_topic"

      # The cursor is HELD by the routable row, which is why the small
      # talk is still `:queued` and no dispatch decision for it exists.
      assert IntentQueue.cursor(meeting.id) == routable_row.id,
             "the cursor was not held by the routable row — this test is not " <>
               "reproducing the contention it claims to"

      small_talk = await_candidate_for_intent(small_talk_row.id)
      assert small_talk.classified_intent == "off_topic"

      # 3. The sweep is past the deadline the card WOULD have had, and
      #    is computed from the utterance clock rather than read off
      #    `acts_at` — a test that skips the sweep when the row is
      #    disarmed cannot tell a fix from a row it never swept.
      now =
        DateTime.add(
          small_talk.last_utterance_at || small_talk.heard_at,
          Countdown.countdown_seconds() + 5,
          :second
        )

      fired = CandidateSweeper.sweep(now: now)

      routable = await_candidate_for_intent(routable_row.id)
      assert routable.classified_intent == "action_items"
      assert is_nil(routable.acts_at)
      assert is_nil(Repo.get!(MeetingCandidate, routable.id).task_id)
      assert fired == []

      # Still held: the handler never answered, so the small talk was
      # never dispatched, never declined, and never closed by anybody.
      assert IntentQueue.cursor(meeting.id) == routable_row.id
      assert %{status: :queued} = queue_row(meeting.id, small_talk_row.id)

      reloaded = Repo.get!(MeetingCandidate, small_talk.id)

      refute reloaded.task_id,
             "small talk graduated into a task while it waited on a dispatch decision " <>
               "(candidate state=#{inspect(reloaded.state)} " <>
               "queue_status=#{inspect(reloaded.queue_status)} " <>
               "acts_at=#{inspect(reloaded.acts_at)})"

      # The id column is not the fact. Ask `tasks` directly, the same
      # way the corpus arm does.
      spurious =
        WorkTask
        |> where([t], fragment("?->>'candidate_id' = ?", t.metadata, ^small_talk.id))
        |> Repo.all()

      assert spurious == [],
             "a row in `tasks` exists for the off_topic candidate: " <>
               inspect(Enum.map(spurious, & &1.title))
    end

    test "an off_topic classification is never armed in the first place", %{
      classifier_pid: classifier_pid
    } do
      # The property behind the case above, stated directly: whether a
      # dispatcher is fast, slow or absent must not decide whether small
      # talk can become work. A disarmed card cannot be claimed by any
      # sweep, at any latency.
      plant_stub_fun(classifier_pid, fn _credentials, messages, _opts ->
        {:ok, %{content: contention_stub_content(user_content(messages))}}
      end)

      {_project, meeting} = create_meeting!()
      on_exit(fn -> IntentQueue.stop(meeting.id) end)

      room_id = "off-topic-arming-#{System.unique_integer([:positive])}"
      append_transcript_segment!(meeting, room_id, "bruno", @small_talk_utterance)

      row = await_row_with_status(meeting.id, :dispatch_failed)
      assert to_string(row.classified_intent) == "off_topic"

      candidate = await_candidate_for_intent(row.id)

      refute candidate.acts_at,
             "an off_topic candidate is carrying a live countdown " <>
               "(acts_at=#{inspect(candidate.acts_at)})"
    end
  end

  describe "the deterministic frame gate, measured with no model at all" do
    test "delegation-phrased asks are cancelled by IntentFrames whatever the prompt says" do
      rows = load_slice!(@slice)
      delegation = Enum.filter(rows, &(&1["probe"] == "frame_delegation"))

      assert length(delegation) == 6

      verdicts = Map.new(delegation, &{&1["id"], E2E.frame_verdict(&1)})

      # Every one of them carries a real intent under question 1 of the
      # stage-3 prompt, and every one is vetoed before it can become
      # anything. This assertion is the CONFLICT, pinned: stage 3
      # removed the definition `:frame_delegation` justified itself by
      # ("off_topic by the prompt's own definition") and left the gate
      # standing. Fixing that is a decision, not a patch; measuring it
      # is this stage's job.
      assert Enum.all?(verdicts, fn {_id, verdict} ->
               verdict == {:cancelled, :frame_delegation}
             end),
             "expected all six delegation rows cancelled as :frame_delegation, got " <>
               inspect(verdicts)

      # And the cancellation is NOT an artefact of the stub citing the
      # whole utterance: narrowed to the delegation clause alone, the
      # operator is still inside the quote.
      assert Platform.Meetings.IntentFrames.cancelling_frame(
               "just ask her to to create the documents when she's got a minute",
               "ask her to to create the documents"
             ) == {:cancelled, :frame_delegation}
    end

    test "`before we forget it` is read as a retraction — a NEW over-suppression this corpus found" do
      rows = load_slice!(@slice)

      cancelled =
        rows
        |> Enum.reject(&(&1["probe"] == "frame_delegation"))
        |> Enum.map(&{&1["text"], E2E.frame_verdict(&1)})
        |> Enum.reject(fn {_text, verdict} -> verdict == :ok end)

      # Exactly one, and it is a FALSE positive of the gate that no
      # previously committed slice could see.
      #
      # `:frame_retraction`'s lexicon contains `forget (it|that)`. In
      # "before we forget it" that string is not a retraction at all —
      # it is an intensifier ON the ask ("write that down BEFORE we
      # forget it"), the opposite of taking it back. The gate has no
      # semantics, so it cannot tell them apart, and the ask is demoted.
      #
      # DELIBERATELY NOT FIXED. Narrowing the lexicon is a decision
      # about a shipped gate with its own measured budget, not a patch
      # to slip into an eval stage. What this stage owes is the
      # measurement, pinned here so the cost is a number somebody can
      # act on rather than a surprise in production.
      assert cancelled == [
               {"we should probably we should probably write that down somewhere before we forget it",
                {:cancelled, :frame_retraction}}
             ],
             "the frame gate's cost on this corpus changed: " <> inspect(cancelled)

      # The narrow reading confirms it is the lexicon and not the wide
      # citation window: the operator sits inside any honest quote of
      # the ask.
      assert Platform.Meetings.IntentFrames.cancelling_frame(
               "we should write that down before we forget it",
               "write that down before we forget it"
             ) == {:cancelled, :frame_retraction}

      # And the same words WITHOUT the idiom survive, so this is a
      # property of `forget it`, not of the sentence.
      assert Platform.Meetings.IntentFrames.cancelling_frame(
               "we should write that down before the meeting ends",
               "write that down before the meeting ends"
             ) == :ok
    end
  end

  # ── One row, end to end ────────────────────────────────────────────────────

  defp run_row(row, classifier_pid) do
    {_project, meeting} = create_meeting!()

    plant_stub_fun(classifier_pid, fn _credentials, _messages, _opts ->
      {:ok, %{content: E2E.stub_content(row)}}
    end)

    room_id = "intent-eval-e2e-#{String.slice(row["id"], 0, 8)}"
    append_transcript_segment!(meeting, room_id, "human-speaker", row["text"])

    skip_reason = await_settled(meeting.id)

    # WAIT FOR THE DISPATCHER before firing the countdown. The classifier's
    # telemetry fires when the row is ENQUEUED; the dispatcher is a
    # separate process and its transition — `:dispatched` for a routable
    # intent, `:dispatch_failed` for a null target — lands after it. An
    # earlier draft of this file swept immediately and scored 8 of 10
    # `off_topic` rows as graduating into tasks, because the sweeper
    # claimed the candidate while it was still `:queued` and open. That
    # was the harness outrunning the platform, not small talk becoming
    # work, and it is exactly the kind of number this stage must not
    # publish.
    queue_row = if skip_reason, do: nil, else: await_dispatch_settled(meeting.id)
    candidate = candidate_for(meeting.id)

    # THE ACK, which this harness did not issue until task 01a06575
    # stage 5 — and whose absence made this file blind to the very
    # defect it was written for.
    #
    # `@queue_state_map` maps `dispatched -> :shaping` and
    # `acked -> :acting`. With no ack, every positive sat at `:shaping`
    # when the sweeper ran, so `claim_due/2`'s `:acting` predicate —
    # the stage-2 defect, the reason production held 280 candidates and
    # zero `task_id`s — was never on the path. Reverting that fix left
    # this run BYTE-IDENTICAL and green while the stage test files went
    # red, which is the failure this module's own moduledoc names.
    #
    # In production the ack is what the recipient agent does next, over
    # MCP, within a second or two: `IntentContext.ack_preamble/1` is
    # composed onto the front of its system turn precisely so it acks
    # immediately. So a run that never acks is not a cheaper version of
    # the live rail — it is a different rail.
    queue_row = maybe_ack_working(meeting.id, queue_row)
    candidate = maybe_sweep(candidate)

    IntentQueue.stop(meeting.id)

    task = candidate && candidate.task_id && Repo.get(WorkTask, candidate.task_id)

    Map.merge(row, %{
      "task_id" => task && task.id,
      "queue_status" => (queue_row && to_string(queue_row.status)) || skip_reason || "no_row",
      "candidate_state" => (candidate && to_string(candidate.state)) || "no_candidate",
      "demoted_from" => candidate && candidate.demoted_from,
      "frame_verdict" => frame_verdict_string(row)
    })
  end

  defp frame_verdict_string(row) do
    case E2E.frame_verdict(row) do
      :ok -> "ok"
      {:cancelled, class} -> to_string(class)
    end
  end

  # Fire the countdown by injecting `now`, exactly as the stage-2
  # graduation test does. The 30 real seconds stay 30 real seconds.
  defp maybe_sweep(nil), do: nil

  # A disarmed card is swept over, not skipped past: the row is still
  # re-read so `candidate_state` reports where it ACTUALLY stopped
  # rather than where it was when the poll gave up. Since stage 5 an
  # `off_topic` card is disarmed at classification and lands here.
  defp maybe_sweep(%MeetingCandidate{acts_at: nil} = candidate),
    do: Repo.get!(MeetingCandidate, candidate.id)

  defp maybe_sweep(%MeetingCandidate{} = candidate) do
    _fired = CandidateSweeper.sweep(now: DateTime.add(candidate.acts_at, 1, :second))
    Repo.get!(MeetingCandidate, candidate.id)
  end

  # The recipient agent's first move. Only a `:dispatched` row can be
  # acked — a `:dispatch_failed` decline has already left the cursor and
  # answers `{:error, {:invalid_ack_state, _}}` — so the outcome is
  # matched rather than asserted, and the un-acked row is returned
  # unchanged for the report to record.
  defp maybe_ack_working(meeting_id, %{status: :dispatched} = row) do
    case IntentQueue.ack(meeting_id, row.id, Ecto.UUID.generate(), :working) do
      {:ok, acked} -> acked
      {:error, _reason} -> row
    end
  end

  defp maybe_ack_working(_meeting_id, row), do: row

  # ── Held-cursor contention helpers ─────────────────────────────────────────

  # The stub answers per UTTERANCE rather than per run, because the
  # contention case needs two different classifications in one meeting.
  # The user message IS the chunk text (`IntentClassifier.call_provider/5`),
  # so the answer is keyed off exactly what the model would have read.
  defp contention_stub_content(@small_talk_utterance) do
    Jason.encode!(%{
      "intent" => "off_topic",
      "target_role" => "null",
      "confidence" => 0.91,
      # Empty, as the prompt requires of a decline — a decline that
      # cites text is demoted by the evidence gate, which would make
      # this row `off_topic` for the wrong reason.
      "evidence_quote" => ""
    })
  end

  defp contention_stub_content(text) do
    Jason.encode!(%{
      "intent" => "action_items",
      "target_role" => "meeting_scribe",
      "confidence" => 0.93,
      "evidence_quote" => text
    })
  end

  defp user_content(messages) do
    messages
    |> List.last()
    |> Map.get(:content)
  end

  defp await_row_with_status(meeting_id, status, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_row_with_status(meeting_id, status, deadline)
  end

  defp do_await_row_with_status(meeting_id, status, deadline) do
    row = meeting_id |> IntentQueue.list() |> Enum.find(&(&1.status == status))

    cond do
      row ->
        row

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "no #{inspect(status)} row for meeting #{meeting_id}; queue holds " <>
            inspect(Enum.map(IntentQueue.list(meeting_id), &{&1.classified_intent, &1.status}))
        )

      true ->
        Process.sleep(10)
        do_await_row_with_status(meeting_id, status, deadline)
    end
  end

  defp queue_row(meeting_id, intent_id) do
    meeting_id |> IntentQueue.list() |> Enum.find(&(&1.id == intent_id))
  end

  defp await_candidate_for_intent(intent_id, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_candidate_for_intent(intent_id, deadline)
  end

  defp do_await_candidate_for_intent(intent_id, deadline) do
    case Candidates.get_by_intent_id(intent_id) do
      %MeetingCandidate{classified_intent: intent} = candidate when not is_nil(intent) ->
        candidate

      other ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("no classified candidate mirrored for intent #{intent_id}: #{inspect(other)}")
        else
          Process.sleep(10)
          do_await_candidate_for_intent(intent_id, deadline)
        end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp load_slice!(name) do
    root = IntentEval.root()

    {_header, rows} =
      IntentEval.read_jsonl(Path.join(root, "slices/#{name}.jsonl"))

    rows
  end

  defp create_meeting! do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Intent Eval E2E Project #{n}",
        org_id: Platform.Tenancy.get_org_by_slug!("acme").id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Intent Eval E2E Meeting #{n}",
        slug: "intent-eval-e2e-meeting-#{n}"
      })

    {:ok, _} = IntentQueue.ensure_started(meeting.id, ack_timeout_ms: 60_000)

    {project, meeting}
  end

  defp plant_stub_fun(classifier_pid, fun) do
    ref = make_ref()
    send(classifier_pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      1_000 -> flunk("classifier did not ack stub fun plant")
    end
  end

  defp append_transcript_segment!(meeting, room_id, participant, text, opts \\ []) do
    {:ok, transcript} =
      Meetings.ensure_transcript(%{room_id: room_id, space_id: meeting.chat_space_id})

    # `IntentClassifier` keys a chunk on `segment[:id] || transcript_id`,
    # so two segments appended to ONE transcript without ids are one
    # chunk as far as the candidate store is concerned — the second
    # reconciles onto the first's row and gets no card. The corpus arm
    # gives every row its own room and never meets this; the contention
    # case needs two distinct chunks in ONE meeting, so it passes ids.
    segment =
      %{
        participant_identity: participant,
        text: text,
        start_time: 0,
        end_time: 1000
      }
      |> then(fn segment ->
        case Keyword.get(opts, :id) do
          nil -> segment
          id -> Map.put(segment, :id, id)
        end
      end)

    {:ok, _} = Meetings.append_segment(transcript.id, segment)

    :ok
  end

  # Returns nil when the chunk was classified, or the skip reason when a
  # guard refused it. A skip is a REAL outcome for this corpus — the
  # content gate legitimately drops backchannel — so it is recorded, not
  # treated as a timeout.
  defp await_settled(meeting_id, timeout \\ 5_000) do
    receive do
      {:classifier_settled, @classified, %{meeting_id: ^meeting_id}} ->
        nil

      {:classifier_settled, @skipped, %{meeting_id: ^meeting_id, reason: reason}} ->
        "skipped:#{reason}"
    after
      timeout -> "no_signal"
    end
  end

  # Poll until the dispatcher has committed the row out of `:queued`.
  # Returns nil when the classifier never enqueued one (a content-gated
  # utterance), which is a legitimate outcome and not a timeout.
  defp await_dispatch_settled(meeting_id, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_dispatch_settled(meeting_id, deadline)
  end

  defp do_await_dispatch_settled(meeting_id, deadline) do
    row = meeting_id |> IntentQueue.list() |> List.first()

    cond do
      match?(%{status: status} when status != :queued, row) -> row
      System.monotonic_time(:millisecond) > deadline -> row
      true -> do_await_dispatch_settled(meeting_id, deadline)
    end
  end

  # The mirror writes the candidate inside the enqueue, and the
  # classifier's telemetry fires after it — but the dispatcher's
  # transition is a separate process, so the candidate's terminal state
  # is polled for briefly rather than read once.
  defp candidate_for(meeting_id, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_candidate_for(meeting_id, deadline)
  end

  defp do_candidate_for(meeting_id, deadline) do
    candidate =
      MeetingCandidate
      |> where(meeting_id: ^meeting_id)
      |> order_by(asc: :inserted_at)
      |> Repo.all()
      |> List.first()

    settled? =
      case candidate do
        nil -> false
        %{classified_intent: nil} -> false
        _ -> true
      end

    cond do
      settled? -> candidate
      System.monotonic_time(:millisecond) > deadline -> candidate
      true -> do_candidate_for(meeting_id, deadline)
    end
  end
end
