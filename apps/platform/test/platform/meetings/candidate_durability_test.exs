defmodule Platform.Meetings.CandidateDurabilityTest do
  @moduledoc """
  The three acceptance criteria of task 01a03fb8, DEMONSTRATED rather
  than assumed (stage 5).

  Every case here is written against a specific way of passing
  vacuously:

    * **Restart durability.** Writing a row and reading it back through
      the live queue proves nothing — the read may never have left ETS.
      So the queue owner is STOPPED first, and the death of its ETS
      table is asserted as a positive control (`running?/1` false AND
      `list/1` empty) before the candidate is read back. A read that
      succeeds while the queue is demonstrably gone came from Postgres
      and nowhere else.

    * **Both dispositions.** Asserting only the rejected row passes an
      implementation that records nothing but failures — which is
      exactly the shape of the existing all-negative correction corpus.
      Both halves are asserted, in the SAME meeting, and the org-scoped
      `:accepted` aggregate the eval harness will run is proven
      non-empty.

    * **Artifact completes with no task.** Asserted through `Repo`, not
      through the struct `graduate/2` returned in memory, and paired
      with a task-count delta so "no task" is a measured zero rather
      than an unqueried assumption.

    * **Close uniformity.** Four rows looking alike would also be
      satisfied by four copy-pasted close functions, so the shape
      assertion is paired with a reflection check that `close/2` is the
      only public function whose name speaks of retracting, dismissing,
      vetoing or de-duplicating.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.IntentQueue.Supervisor, as: QueueSupervisor
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo

  setup do
    meeting = create_meeting!(fabrikam_org_id())
    on_exit(fn -> IntentQueue.stop(meeting.id) end)

    %{
      meeting: meeting,
      org_id: Platform.Meetings.IntentCorrections.org_id_for_meeting(meeting.id)
    }
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp create_meeting!(org_id) do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Durability #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Durability Space #{System.unique_integer([:positive])}",
        slug: "durability-#{System.unique_integer([:positive])}",
        kind: "meeting"
      })

    %Platform.Meetings.Meeting{}
    |> Platform.Meetings.Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "durability-#{System.unique_integer([:positive])}",
      name: "Durability Meeting",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  defp seat!(meeting) do
    {:ok, participant} =
      Platform.Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Durability Host",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  # The queue owner is a DIFFERENT process than the test, so it needs
  # the test's sandbox connection handed to it explicitly or every
  # mirror write inside it exits.
  defp start_queue!(meeting_id) do
    {:ok, pid} = QueueSupervisor.ensure_started(meeting_id, [])
    Sandbox.allow(Repo, self(), pid)
    pid
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        classified_intent: :create_task,
        target_role: :engineering,
        confidence: 0.91,
        model_used: "haiku-test",
        transcript_chunk_id: Ecto.UUID.generate(),
        chunk_excerpt: "we should ship the candidate board this week",
        dedupe_key: "dk-#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  defp candidate_attrs(meeting_id, overrides) do
    Map.merge(
      %{
        meeting_id: meeting_id,
        evidence_quote: "somebody should write up the onboarding funnel changes",
        state: :heard,
        outcome_kind: :task
      },
      overrides
    )
  end

  # ── AC1: the row outlives the queue that wrote it ─────────────────────────

  describe "restart durability" do
    test "the candidate survives the queue owner's death, ETS and all", %{meeting: meeting} do
      start_queue!(meeting.id)

      {:ok, row} = IntentQueue.enqueue(meeting.id, attrs())
      {:ok, _} = IntentQueue.transition(meeting.id, row.id, :dispatched)

      candidate = Candidates.get_by_intent_id(row.id)
      assert candidate.state == :shaping

      {:ok, _} = Candidates.record_disposition(candidate, :rejected)

      {:ok, _} =
        Candidates.close(candidate.id, {:vetoed, "host pulled it after the room disagreed"})

      # Positive control. Everything below is only evidence of
      # DURABILITY if the in-memory copy is provably gone first — so
      # the queue's death is asserted, never assumed.
      :ok = IntentQueue.stop(meeting.id)
      refute IntentQueue.running?(meeting.id)
      assert IntentQueue.list(meeting.id) == []

      # Same id, read with no queue owner alive anywhere. This can only
      # be answered by Postgres.
      reloaded = Candidates.get_by_intent_id(row.id)

      assert reloaded
      assert reloaded.state == :closed
      assert reloaded.closed_reason == :vetoed
      assert reloaded.closed_note == "host pulled it after the room disagreed"
      assert reloaded.closed_at
      assert reloaded.disposition == :rejected
      assert reloaded.evidence_quote == "we should ship the candidate board this week"
      assert reloaded.outcome_kind == :task
      assert reloaded.queue_status == "dispatched"
      assert reloaded.dispatched_at
    end

    test "a fresh queue owner for the same meeting starts with an EMPTY table", %{
      meeting: meeting
    } do
      # Guards the control above against the reading that `stop/1` might
      # somehow leave the rows recoverable in ETS: restarting the owner
      # yields nothing, while the durable row is still there.
      start_queue!(meeting.id)
      {:ok, row} = IntentQueue.enqueue(meeting.id, attrs())
      assert [_] = IntentQueue.list(meeting.id)

      :ok = IntentQueue.stop(meeting.id)
      start_queue!(meeting.id)

      assert IntentQueue.list(meeting.id) == []
      assert Candidates.get_by_intent_id(row.id)
    end
  end

  # ── AC2: both dispositions are recorded, in the same meeting ──────────────

  describe "accepted and rejected both land" do
    test "one accepted row and one rejected row from the same meeting", %{
      meeting: meeting,
      org_id: org_id
    } do
      start_queue!(meeting.id)

      # Accepted: the full walk a healthy intent takes.
      {:ok, accepted_row} = IntentQueue.enqueue(meeting.id, attrs())
      {:ok, _} = IntentQueue.transition(meeting.id, accepted_row.id, :dispatched)
      {:ok, _} = IntentQueue.ack(meeting.id, accepted_row.id, "subagent-accept", :working)
      {:ok, _} = IntentQueue.ack(meeting.id, accepted_row.id, "subagent-accept", :completed)

      # Rejected: the target refuses it.
      {:ok, rejected_row} = IntentQueue.enqueue(meeting.id, attrs())
      {:ok, _} = IntentQueue.transition(meeting.id, rejected_row.id, :dispatched)

      {:ok, _} =
        IntentQueue.ack(meeting.id, rejected_row.id, "subagent-reject", :rejected, "wrong target")

      assert [first, second] = Candidates.list_for_meeting(meeting.id)
      assert Enum.sort([first.disposition, second.disposition]) == [:accepted, :rejected]

      accepted = Candidates.get_by_intent_id(accepted_row.id)
      rejected = Candidates.get_by_intent_id(rejected_row.id)

      # Both halves are load-bearing: without the first, an
      # implementation that records nothing passes; without the second,
      # one that records only failures does.
      assert accepted.disposition == :accepted
      assert accepted.state == :closed
      assert accepted.closed_reason == :done

      assert rejected.disposition == :rejected
      assert rejected.state == :closed
      assert rejected.closed_reason == :dismissed

      # Both terminal rows are `:closed`, so the lifecycle axis alone
      # cannot tell them apart — which is exactly why disposition is a
      # separate column.
      assert accepted.state == rejected.state
      refute accepted.disposition == rejected.disposition

      # The measurement query the eval harness will run, proven
      # non-empty for this org.
      accepted_count =
        MeetingCandidate
        |> where([c], c.org_id == ^org_id and c.disposition == :accepted)
        |> Repo.aggregate(:count)

      assert org_id
      assert accepted_count >= 1
    end
  end

  # ── AC3: an artifact completes with no task ───────────────────────────────

  describe "artifact graduation" do
    test "the durable row has a canvas, a NULL task_id, and no task was created", %{
      meeting: meeting
    } do
      participant = seat!(meeting)

      {:ok, candidate} =
        Candidates.create(candidate_attrs(meeting.id, %{outcome_kind: :artifact}))

      before_tasks = Repo.aggregate(Platform.Tasks.Task, :count)

      assert {:ok, graduated} = Candidates.graduate(candidate, created_by: participant.id)

      # Asserted THROUGH Repo — the struct graduate/2 handed back is an
      # in-memory artefact of the same call under test.
      row =
        MeetingCandidate
        |> where(
          [c],
          c.id == ^graduated.id and c.outcome_kind == :artifact and
            not is_nil(c.canvas_id) and is_nil(c.task_id)
        )
        |> Repo.one()

      assert row
      assert Repo.get(Platform.Chat.Canvas, row.canvas_id)
      assert Repo.aggregate(Platform.Tasks.Task, :count) == before_tasks

      # Control on the delta above: a task IS creatable in this env, so
      # the zero delta means "the artifact branch created none", not
      # "nothing can create a task here".
      {:ok, task_candidate} =
        Candidates.create(candidate_attrs(meeting.id, %{outcome_kind: :task}))

      assert {:ok, task_graduated} = Candidates.graduate(task_candidate)
      assert task_graduated.task_id
      assert Repo.aggregate(Platform.Tasks.Task, :count) == before_tasks + 1
    end
  end

  # ── AC4: one close path, four reasons ─────────────────────────────────────

  describe "close uniformity" do
    test "all four close reasons produce rows identical in shape", %{meeting: meeting} do
      reasons = [:retracted, :duplicate, :vetoed, :dismissed]

      rows =
        for reason <- reasons do
          {:ok, candidate} = Candidates.create(candidate_attrs(meeting.id, %{}))
          {:ok, closed} = Candidates.close(candidate, {reason, "note for #{reason}"})
          Repo.get!(MeetingCandidate, closed.id)
        end

      assert length(rows) == 4

      for {row, reason} <- Enum.zip(rows, reasons) do
        assert row.state == :closed
        assert row.closed_reason == reason
        assert row.closed_note == "note for #{reason}"
        assert row.closed_at
      end

      # Shape equality: same set of non-nil fields on every row, and
      # identical values everywhere except the two columns that are
      # SUPPOSED to differ (plus the per-row identity/timestamps).
      per_row = [:id, :inserted_at, :updated_at, :closed_at, :closed_reason, :closed_note]

      shapes =
        Enum.map(rows, fn row ->
          row
          |> Map.from_struct()
          |> Map.drop([:__meta__ | per_row])
        end)

      assert Enum.uniq(shapes) |> length() == 1

      non_nil_keys =
        Enum.map(rows, fn row ->
          row
          |> Map.from_struct()
          |> Map.drop([:__meta__ | per_row])
          |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()
        end)

      assert Enum.uniq(non_nil_keys) |> length() == 1
    end

    test "close/2 is the ONLY public function that closes a candidate" do
      offenders =
        Candidates.__info__(:functions)
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.filter(&(to_string(&1) =~ ~r/retract|dismiss|veto|duplicate/))

      # Four rows that merely look alike would also be produced by four
      # copy-pasted functions. This is the half that forbids them.
      assert offenders == []
      assert Keyword.has_key?(Candidates.__info__(:functions), :close)
    end
  end
end
