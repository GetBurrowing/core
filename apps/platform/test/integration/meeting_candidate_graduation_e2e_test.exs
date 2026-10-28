defmodule Platform.Integration.MeetingCandidateGraduationE2ETest do
  @moduledoc "Transcript classification and working/completed acknowledgements never file live tasks."

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
    test "records live work without a countdown task or a completed-ack task", %{
      classifier_pid: classifier_pid
    } do
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

      assert is_nil(candidate.acts_at)
      {:ok, _} = IntentQueue.ack(meeting.id, row.id, Ecto.UUID.generate(), :working)
      acked_candidate = Repo.get!(MeetingCandidate, candidate.id)
      refute acked_candidate.state == :closed
      assert is_nil(acked_candidate.acts_at)
      assert CandidateSweeper.sweep(now: DateTime.add(DateTime.utc_now(), 120, :second)) == []
      {:ok, _} = IntentQueue.ack(meeting.id, row.id, Ecto.UUID.generate(), :completed)
      reloaded = Repo.get!(MeetingCandidate, candidate.id)
      assert reloaded.task_id == nil
      assert reloaded.closed_reason == :done
      assert Repo.all(from(t in WorkTask, where: t.project_id == ^project.id)) == []
    end
  end
end
