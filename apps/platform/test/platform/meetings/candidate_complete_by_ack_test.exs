defmodule Platform.Meetings.CandidateCompleteByAckTest do
  @moduledoc "Completed live intents record dispositions; end-of-meeting triage files tasks."

  use Platform.DataCase, async: false

  alias Platform.Chat.Canvas
  alias Platform.Meetings
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo
  alias Platform.Tasks.Task, as: WorkTask

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Complete By Ack Project #{n}",
        org_id: Platform.Tenancy.get_org_by_slug!("acme").id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Complete By Ack Meeting #{n}",
        slug: "complete-by-ack-meeting-#{n}"
      })

    meeting =
      meeting
      |> Meetings.Meeting.status_changeset("live", %{started_at: DateTime.utc_now()})
      |> Repo.update!()

    {project, meeting}
  end

  # A card in the state the live rail leaves one in once the dispatcher
  # has handed it to an agent: classified, routable, `:shaping` (the
  # candidate state a `:dispatched` queue row mirrors to — see
  # `Candidates.queue_status_to_state/1`), and — unless the test says
  # otherwise — ARMED, with `acts_at` 30 seconds
  # out from the utterance. `Candidates.create/1`'s arming arithmetic
  # does that from `last_utterance_at`; an explicit `:acts_at` in the
  # overrides is honoured verbatim (`put_armed_acts_at/1`), which is how
  # the unarmed cases below are built.
  defp candidate!(meeting, overrides \\ %{}) do
    now = DateTime.utc_now()
    chunk_id = Ecto.UUID.generate()

    {:ok, candidate} =
      Candidates.create(
        Map.merge(
          %{
            intent_id: Ecto.UUID.generate(),
            meeting_id: meeting.id,
            transcript_chunk_id: chunk_id,
            transcript_chunk_ids: [chunk_id],
            evidence_quote: "somebody write the CSV export",
            speaker: "alice",
            classified_intent: "action_items",
            target_role: "meeting_scribe",
            state: :shaping,
            queue_status: "dispatched",
            outcome_kind: :task,
            heard_at: now,
            dispatched_at: now,
            last_utterance_at: now
          },
          overrides
        )
      )

    candidate
  end

  defp reload!(%MeetingCandidate{id: id}), do: Repo.get!(MeetingCandidate, id)

  defp tasks_for_candidate(candidate_id) do
    Repo.all(
      from(t in WorkTask,
        where: fragment("?->>'candidate_id' = ?", t.metadata, ^candidate_id)
      )
    )
  end

  defp canvases_in(space_id) do
    Repo.all(from(c in Canvas, where: c.space_id == ^space_id))
  end

  test "completed acknowledgements record dispositions repeatedly, without tasks" do
    {_project, meeting} = meeting!()

    for intent <- ["action_items", "open_question", nil] do
      candidate = candidate!(meeting, %{classified_intent: intent})
      assert is_nil(candidate.acts_at)
      # Simulate a pre-cutover row whose countdown is still armed.
      candidate =
        candidate |> Ecto.Changeset.change(acts_at: DateTime.utc_now()) |> Repo.update!()

      assert :ok = Candidates.complete_by_ack(candidate)
      assert :ok = Candidates.complete_by_ack(candidate)
      assert tasks_for_candidate(candidate.id) == []
      row = reload!(candidate)
      assert row.disposition == :accepted
      assert row.closed_reason == :done
      assert row.queue_status == "completed"
      assert row.state == :closed
      assert is_nil(row.acts_at)
      assert is_nil(row.task_id)
    end
  end

  test "artifact acknowledgement creates neither a canvas nor a task" do
    {_project, meeting} = meeting!()

    candidate =
      candidate!(meeting, %{
        outcome_kind: :artifact,
        classified_intent: "visual_adjust",
        target_role: "designer"
      })

    before = canvases_in(meeting.chat_space_id)
    assert :ok = Candidates.complete_by_ack(candidate)
    assert tasks_for_candidate(candidate.id) == []
    assert canvases_in(meeting.chat_space_id) == before
    assert reload!(candidate).acts_at == nil
  end

  test "real queue completed acknowledgements never file tasks" do
    {project, meeting} = meeting!()
    assert meeting.status == "live"
    {:ok, _} = IntentQueue.ensure_started(meeting.id, ack_timeout_ms: 60_000)
    on_exit(fn -> IntentQueue.stop(meeting.id) end)

    for intent <- ["open_question", "action_items"] do
      {:ok, row} =
        IntentQueue.enqueue(meeting.id, %{
          classified_intent: intent,
          target_role: "meeting_scribe",
          confidence: 0.91,
          transcript_chunk_id: Ecto.UUID.generate(),
          chunk_excerpt: "Priya will write the migration by Thursday",
          dedupe_key: Ecto.UUID.generate()
        })

      {:ok, _} = IntentQueue.claim_next(meeting.id)
      {:ok, _} = IntentQueue.transition(meeting.id, row.id, :dispatched)
      candidate = Candidates.get_by_intent_id(row.id)
      assert candidate.state == :shaping
      assert is_nil(candidate.acts_at)
      {:ok, done} = IntentQueue.ack(meeting.id, row.id, "higgins.test-host", :completed)
      assert done.status == :completed
      assert tasks_for_candidate(candidate.id) == []
      assert reload!(candidate).closed_reason == :done
      assert reload!(candidate).queue_status == "completed"
    end

    assert Repo.all(from(t in WorkTask, where: t.project_id == ^project.id)) == []
  end
end
