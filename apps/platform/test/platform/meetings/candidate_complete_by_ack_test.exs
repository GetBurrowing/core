defmodule Platform.Meetings.CandidateCompleteByAckTest do
  @moduledoc """
  A `:completed` ack that beats the 30-second countdown still mints the
  task, already `done` (task 01a06638-e7c7 stage 1).

  Every assertion here is a `Repo` read. The thing that was wrong before
  this stage — an ack that recorded `:accepted` / `:done` on the
  candidate and minted NOTHING — passes any assertion on the candidate
  row alone, so the fact asserted is the `tasks` row, and its status.

  `async: false` for the one case that drives the real
  `Platform.Meetings.IntentQueue.Server`: the mirror runs inside that
  GenServer, which needs the shared sandbox to reach the Repo.
  """

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
        org_id: Platform.Tenancy.get_org_by_slug!("fabrikam").id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Complete By Ack Meeting #{n}",
        slug: "complete-by-ack-meeting-#{n}"
      })

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

  # ── (a) armed task candidate ──────────────────────────────────────────────

  describe "an armed task candidate" do
    test "is minted as a task at `done` with the ack in its provenance" do
      {project, meeting} = meeting!()
      candidate = candidate!(meeting)

      # The precondition the whole file is about: it IS counting down.
      assert %DateTime{} = candidate.acts_at
      assert DateTime.compare(candidate.acts_at, DateTime.utc_now()) == :gt
      assert candidate.state == :shaping

      assert :ok = Candidates.complete_by_ack(candidate)

      # THE assertion: exactly one row in `tasks` points back at this
      # candidate.
      assert [task] = tasks_for_candidate(candidate.id)
      assert task.project_id == project.id
      assert task.status == "done"
      assert task.metadata["completed_via"] == "meeting_intent_ack"
      assert task.metadata["intent_id"] == candidate.intent_id
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(task.metadata["acked_at"])
      # The provenance keys `graduate/2` writes survived the merge —
      # `Platform.Meetings.Triage` reads `"source"`.
      assert task.metadata["source"] == "meetings.candidate"
      assert task.metadata["meeting_id"] == meeting.id
      assert task.metadata["candidate_id"] == candidate.id

      reloaded = reload!(candidate)
      assert reloaded.task_id == task.id
      assert reloaded.disposition == :accepted
      assert reloaded.state == :closed
      assert reloaded.closed_reason == :done
      assert reloaded.queue_status == "completed"
      assert is_nil(reloaded.acts_at)

      # The stop button now tells the truth it always told after a
      # sweeper fire: too late, the task exists — and it does.
      assert {:error, :already_fired} = Candidates.stop(candidate.id, Ecto.UUID.generate())
      assert Repo.get(WorkTask, task.id)
    end
  end

  # ── (b) sweeper got there first ───────────────────────────────────────────

  describe "a candidate the sweeper has already claimed" do
    test "is not minted a second time" do
      {project, meeting} = meeting!()
      candidate = candidate!(meeting)

      # A REAL sweeper claim, past the deadline: `acts_at` nil, state
      # `:acting`, nothing minted yet. This is the window between
      # `claim_due/2` and `fire/1` in which the ack can land.
      assert [claimed] = Candidates.claim_due(DateTime.add(candidate.acts_at, 1, :second))
      assert claimed.id == candidate.id
      assert is_nil(claimed.acts_at)
      assert claimed.state == :acting
      assert is_nil(claimed.task_id)

      before = Repo.aggregate(WorkTask, :count)

      assert :ok = Candidates.complete_by_ack(reload!(candidate))

      # Nothing minted by the ack — the sweeper owns this row's mint.
      assert Repo.aggregate(WorkTask, :count) == before
      assert tasks_for_candidate(candidate.id) == []
      assert Repo.all(from(t in WorkTask, where: t.project_id == ^project.id)) == []

      # What the ack still records: what the agent said.
      reloaded = reload!(candidate)
      assert reloaded.state == :closed
      assert reloaded.closed_reason == :done
      assert reloaded.disposition == :accepted
      assert is_nil(reloaded.task_id)
    end
  end

  # ── (c) never armed ───────────────────────────────────────────────────────

  describe "an unarmed dispatched candidate" do
    test "closes `done` and mints nothing" do
      {_project, meeting} = meeting!()
      candidate = candidate!(meeting, %{acts_at: nil})

      assert is_nil(candidate.acts_at)
      assert candidate.state == :shaping

      before = Repo.aggregate(WorkTask, :count)
      assert :ok = Candidates.complete_by_ack(candidate)

      assert Repo.aggregate(WorkTask, :count) == before
      assert tasks_for_candidate(candidate.id) == []

      reloaded = reload!(candidate)
      assert reloaded.state == :closed
      assert reloaded.closed_reason == :done
      assert reloaded.disposition == :accepted
      assert is_nil(reloaded.task_id)
    end
  end

  # ── (d) artifact rail ─────────────────────────────────────────────────────

  describe "an armed artifact candidate" do
    test "closes `done` with neither a task nor a canvas" do
      {_project, meeting} = meeting!()

      candidate =
        candidate!(meeting, %{
          outcome_kind: :artifact,
          classified_intent: "visual_adjust",
          target_role: "designer"
        })

      assert %DateTime{} = candidate.acts_at
      assert candidate.outcome_kind == :artifact

      tasks_before = Repo.aggregate(WorkTask, :count)
      canvases_before = canvases_in(meeting.chat_space_id)

      assert :ok = Candidates.complete_by_ack(candidate)

      assert Repo.aggregate(WorkTask, :count) == tasks_before
      assert tasks_for_candidate(candidate.id) == []
      assert canvases_in(meeting.chat_space_id) == canvases_before

      reloaded = reload!(candidate)
      assert reloaded.state == :closed
      assert reloaded.closed_reason == :done
      assert reloaded.disposition == :accepted
      assert is_nil(reloaded.task_id)
      assert is_nil(reloaded.canvas_id)
    end
  end

  # ── (e) through the mirror ────────────────────────────────────────────────

  describe "through IntentQueue.ack/5" do
    test "a :completed ack on an armed task candidate mints the task at `done`" do
      {project, meeting} = meeting!()

      {:ok, _} = IntentQueue.ensure_started(meeting.id, ack_timeout_ms: 60_000)
      on_exit(fn -> IntentQueue.stop(meeting.id) end)

      # The queue's own front door. `enqueue/2` mirrors a candidate row
      # (armed, because the meeting is automated and `action_items` is
      # routable); `claim_next/1` + `:dispatched` is what
      # `IntentDispatcher` does to it; the ack is what the recipient
      # agent does over MCP.
      {:ok, row} =
        IntentQueue.enqueue(meeting.id, %{
          classified_intent: "action_items",
          target_role: "meeting_scribe",
          confidence: 0.91,
          transcript_chunk_id: Ecto.UUID.generate(),
          chunk_excerpt: "Priya is going to write the migration by Thursday",
          dedupe_key: "complete-by-ack-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = IntentQueue.claim_next(meeting.id)
      {:ok, _} = IntentQueue.transition(meeting.id, row.id, :dispatched)

      candidate = Candidates.get_by_intent_id(row.id)
      assert candidate, "the enqueue mirrored no meeting_candidates row"
      assert candidate.acts_at, "the mirrored candidate was never armed"
      assert candidate.state == :shaping

      {:ok, done} = IntentQueue.ack(meeting.id, row.id, "higgins.moon", :completed)
      assert done.status == :completed

      assert [task] = tasks_for_candidate(candidate.id)
      assert task.status == "done"
      assert task.project_id == project.id
      assert task.metadata["completed_via"] == "meeting_intent_ack"
      assert task.metadata["intent_id"] == row.id
      assert task.metadata["source"] == "meetings.candidate"

      reloaded = reload!(candidate)
      assert reloaded.task_id == task.id
      assert reloaded.state == :closed
      assert reloaded.closed_reason == :done
      assert reloaded.disposition == :accepted
      assert is_nil(reloaded.acts_at)
    end
  end

  # ── (f) the mint fails ────────────────────────────────────────────────────

  describe "when the project is archived" do
    test "the candidate is closed rather than left disarmed and open" do
      {project, meeting} = meeting!()
      candidate = candidate!(meeting)
      assert %DateTime{} = candidate.acts_at

      # `Platform.Tenancy.Lifecycle.project_writable?/1` reads exactly
      # one thing: `projects.archived_at`. Set it and `create_task/2`
      # answers `{:error, :project_archived}`.
      project
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:error, :project_archived} =
               Platform.Tasks.create_task(%{title: "control", project_id: project.id})

      before = Repo.aggregate(WorkTask, :count)
      assert :ok = Candidates.complete_by_ack(candidate)

      assert Repo.aggregate(WorkTask, :count) == before
      assert tasks_for_candidate(candidate.id) == []

      reloaded = reload!(candidate)
      # Disarmed by the claim...
      assert is_nil(reloaded.acts_at)
      # ...and NOT left there: closed, as the ack said.
      assert reloaded.state == :closed
      assert reloaded.closed_reason == :done
      assert reloaded.disposition == :accepted
      assert is_nil(reloaded.task_id)
    end
  end
end
