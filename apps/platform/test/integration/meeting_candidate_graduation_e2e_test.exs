defmodule Platform.Integration.MeetingCandidateGraduationE2ETest do
  @moduledoc """
  The candidate rail, end to end, all the way to a row in `tasks`
  (task 01a06575 stage 2).

  Production had 280 `meeting_candidates` and ZERO with a `task_id` —
  including the ones the classifier had labelled correctly. Every test
  in this repo that touched graduation started from
  `Candidates.record_heard/1` and a candidate that stayed `:heard`,
  which is a state the live pipeline never leaves a card in. So the
  countdown was covered and the rail was not.

  This walks the whole chain a real utterance walks:

      Meetings.append_segment/2
        -> PubSub.broadcast_transcript_chunk/2
        -> IntentClassifier                (stubbed provider, answers `action_items`)
        -> IntentQueue.enqueue/2           -> mirror_enqueue -> meeting_candidates row, ARMED
        -> IntentDispatcher                (responsibility fork)
        -> "meeting:action_item_intent"    (REAL broadcast)
        -> intent_ack(:working)            (what the recipient agent does next)
        -> CandidateSweeper.sweep(now: …)  (past the deadline)
        -> Candidates.graduate/2 -> Platform.Tasks.create_task/2
        -> a row in `tasks`

  Only two things are stood in for, and both are genuinely outside the
  platform: the classifier's LLM call (the `provider_module:` seam the
  sibling e2e tests use) and the recipient agent's `intent_ack`, which
  in production arrives over MCP from somebody else's machine.

  ## The assertion is on the `tasks` row

  Not on `candidate.task_id` being non-nil, and not on the candidate's
  `state` or `disposition`. A candidate can be `:closed` / `:accepted`
  with no deliverable anywhere — that is exactly the shape the 280
  production rows had — and an id column can hold a value pointing at
  nothing. The only fact worth asserting is that the task EXISTS.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Meetings.CandidateSweeper
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentDispatcher
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tasks.Task, as: WorkTask

  @responsibility_key "meetings.intent_classify"
  @prompt_slug "meetings.intent_classify.v1"

  # The topic `IntentRouting` maps `action_items` onto. Singular "item"
  # — see that module.
  @action_items_topic "meeting:action_item_intent"

  defmodule StubProvider do
    @moduledoc """
    Reads a fun off the classifier process's dictionary. Same shape as
    `Platform.Integration.MeetingIntentDispatcherE2ETest.StubProvider`,
    kept private here so a change there cannot silently reshape this
    test.
    """

    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  setup do
    classifier_name = :"candidate_graduation_classifier_#{System.unique_integer([:positive])}"
    dispatcher_name = :"candidate_graduation_dispatcher_#{System.unique_integer([:positive])}"

    {:ok, classifier_pid} =
      start_supervised({IntentClassifier, name: classifier_name, provider_module: StubProvider})

    {:ok, _dispatcher_pid} =
      start_supervised({IntentDispatcher, name: dispatcher_name, tick_interval_ms: 60_000})

    classifier_agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "candidate-graduation-classifier-#{System.unique_integer([:positive])}",
        name: "Candidate Graduation Classifier",
        status: "active",
        kind: "native"
      })
      |> Repo.insert!()

    {:ok, _} = Roles.set_override(@responsibility_key, classifier_agent.id)

    case PromptTemplates.get_template_by_slug(@prompt_slug) do
      nil -> :ok
      template -> PromptTemplates.delete_template(template)
    end

    {:ok, classifier_pid: classifier_pid}
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp create_meeting! do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Candidate Graduation Project #{n}",
        org_id: Platform.Tenancy.get_org_by_slug!("acme").id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Candidate Graduation Meeting #{n}",
        slug: "candidate-graduation-meeting-#{n}"
      })

    {:ok, _} = IntentQueue.ensure_started(meeting.id, ack_timeout_ms: 60_000)
    on_exit(fn -> IntentQueue.stop(meeting.id) end)

    {project, meeting}
  end

  defp plant_stub_fun(classifier_pid, fun) do
    ref = make_ref()
    send(classifier_pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      500 -> flunk("classifier did not ack stub fun plant")
    end
  end

  defp append_transcript_segment!(meeting, room_id, participant, text) do
    {:ok, transcript} =
      Meetings.ensure_transcript(%{room_id: room_id, space_id: meeting.chat_space_id})

    {:ok, _} =
      Meetings.append_segment(transcript.id, %{
        participant_identity: participant,
        text: text,
        start_time: 0,
        end_time: 1000
      })

    :ok
  end

  defp await_single_row(meeting_id, status, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_single_row(meeting_id, status, deadline)
  end

  defp do_await_single_row(meeting_id, status, deadline) do
    case IntentQueue.list(meeting_id) do
      [%{status: ^status} = row] ->
        row

      other ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("expected one #{inspect(status)} row for #{meeting_id}, got #{inspect(other)}")
        else
          Process.sleep(10)
          do_await_single_row(meeting_id, status, deadline)
        end
    end
  end

  defp await_candidate(intent_id, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_candidate(intent_id, deadline)
  end

  defp do_await_candidate(intent_id, deadline) do
    case Candidates.get_by_intent_id(intent_id) do
      %MeetingCandidate{} = candidate ->
        candidate

      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("no meeting_candidates row mirrored for intent #{intent_id}")
        else
          Process.sleep(10)
          do_await_candidate(intent_id, deadline)
        end
    end
  end

  # ── The rail ───────────────────────────────────────────────────────────────

  describe "a correctly classified action_items utterance" do
    test "reaches its deadline and mints a row in `tasks`", %{classifier_pid: classifier_pid} do
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, @action_items_topic)

      plant_stub_fun(classifier_pid, fn _credentials, _messages, _opts ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "intent" => "action_items",
               "target_role" => "meeting_scribe",
               "confidence" => 0.93,
               "evidence_quote" => "Priya is going to write the migration by Thursday"
             })
         }}
      end)

      {project, meeting} = create_meeting!()

      :ok =
        append_transcript_segment!(
          meeting,
          "candidate-graduation-room",
          "priya",
          "Priya is going to write the migration by Thursday"
        )

      # The dispatcher's responsibility fork fired — this is a correctly
      # classified, routable, non-`off_topic` utterance and it went to
      # the scribe, not to `:dispatch_failed`.
      row = await_single_row(meeting.id, :dispatched)
      assert to_string(row.classified_intent) == "action_items"
      assert_receive {:action_item_intent, %{intent_id: broadcast_intent_id}}, 2_000
      assert broadcast_intent_id == row.id

      candidate = await_candidate(row.id)
      assert candidate.classified_intent == "action_items"

      # It is ARMED. If this is nil the card never had a deadline and
      # everything below is moot.
      assert candidate.acts_at,
             "candidate was mirrored with no acts_at — it never started counting down"

      # What the recipient agent does next, in production, over MCP:
      # it picks the dispatch up and says it is working.
      {:ok, _acked} =
        IntentQueue.ack(meeting.id, row.id, Ecto.UUID.generate(), :working)

      # The ack has landed, so the card is now mid-flight with an agent.
      # It must STILL be armed: the countdown gates graduation, the
      # cursor gates dispatch, and they are different rails.
      acked_candidate = Repo.get!(MeetingCandidate, candidate.id)

      # BOTH halves, because `acts_at` alone does not say it. Closing a
      # candidate does not nil `acts_at` — `Candidates.close/2` writes
      # `closed_reason`, `closed_at` and the state and leaves the
      # deadline where it was — so a card that had been closed out from
      # under this ack would satisfy the assertion below while being
      # permanently unclaimable (`claim_due/2` excludes `:closed`). The
      # state was named only inside the failure MESSAGE, where it is
      # rendered after the assertion has already decided.
      refute acked_candidate.state == :closed,
             "the ack closed the candidate — it can never be claimed " <>
               "(closed_reason=#{inspect(acked_candidate.closed_reason)} " <>
               "queue_status=#{inspect(acked_candidate.queue_status)})"

      assert acked_candidate.acts_at,
             "the ack disarmed the countdown (state=#{acked_candidate.state})"

      # Past the deadline. `now` is injected rather than slept for — the
      # countdown is 30 real seconds and stays 30 real seconds.
      fired = CandidateSweeper.sweep(now: DateTime.add(candidate.acts_at, 1, :second))

      assert Enum.map(fired, & &1.id) == [candidate.id],
             "the sweeper claimed nothing at the deadline. " <>
               "candidate state=#{inspect(acked_candidate.state)} " <>
               "queue_status=#{inspect(acked_candidate.queue_status)} " <>
               "acts_at=#{inspect(acked_candidate.acts_at)}"

      reloaded = Repo.get!(MeetingCandidate, candidate.id)

      assert reloaded.task_id,
             "the candidate graduated with no task_id"

      # THE assertion. A non-nil id pointing at nothing would satisfy
      # the line above.
      task = Repo.get(WorkTask, reloaded.task_id)

      assert task, "candidate.task_id=#{reloaded.task_id} points at no row in `tasks`"
      assert task.project_id == project.id
      assert task.metadata["source"] == "meetings.candidate"
      assert task.metadata["candidate_id"] == candidate.id
    end
  end
end
