defmodule Platform.Meetings.IntentQueue.ServerPersistenceTest do
  @moduledoc """
  The durable candidate mirror (task 01a03fb8 stage 3).

  `server_test.exs` next door proves the ETS queue's own behaviour and
  runs `async: true` against `ExUnit.Case`. These cases need a database
  connection reachable FROM THE QUEUE PROCESS, which is a different
  process than the test — so they run `async: false` under
  `Platform.DataCase` and explicitly `Sandbox.allow/3` the queue owner
  onto the test's connection after starting it.

  The acceptance property under test is that BOTH outcomes land: an
  accepted intent and a rejected one each leave a durable row, with the
  disposition axis recorded separately from the lifecycle axis. A store
  that only ever recorded closures is what produced the all-negative
  corpus this task exists to fix.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.IntentQueue.Supervisor, as: QueueSupervisor

  setup do
    meeting_id = Ecto.UUID.generate()
    on_exit(fn -> IntentQueue.stop(meeting_id) end)
    %{meeting_id: meeting_id, room_id: Ecto.UUID.generate()}
  end

  # Start the queue owner and hand it the test's sandbox connection.
  # Without the allow, every mirror call inside the owner exits — which
  # is exactly what the "Repo unavailable" case below exploits.
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
        confidence: 0.87,
        model_used: "haiku-test",
        transcript_chunk_id: Ecto.UUID.generate(),
        chunk_excerpt: "we should file a task for the billing bug",
        dedupe_key: "dk-#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  defp candidates_for(meeting_id), do: Candidates.list_for_meeting(meeting_id)

  describe "enqueue mirror" do
    test "writes exactly one candidate row carrying the evidence quote", %{
      meeting_id: meeting_id,
      room_id: room_id
    } do
      start_queue!(meeting_id)

      {:ok, row} = IntentQueue.enqueue(meeting_id, attrs(%{room_id: room_id}))

      assert [candidate] = candidates_for(meeting_id)
      assert candidate.intent_id == row.id
      assert candidate.evidence_quote == "we should file a task for the billing bug"
      assert candidate.state == :heard
      assert candidate.queue_status == "queued"
      assert candidate.classified_intent == "create_task"
      assert candidate.target_role == "engineering"
      assert candidate.classifier_confidence == 0.87
      assert candidate.classifier_model == "haiku-test"
      assert candidate.room_id == room_id
      assert candidate.heard_at
      # Populated, not classified — see the Server moduledoc.
      assert candidate.outcome_kind == :task
      # Nothing has happened to it yet; a defaulted disposition here is
      # precisely the bug this store exists to avoid.
      refute candidate.disposition
    end

    test "threads a caller-supplied outcome_kind through", %{meeting_id: meeting_id} do
      start_queue!(meeting_id)

      {:ok, _row} = IntentQueue.enqueue(meeting_id, attrs(%{outcome_kind: :artifact}))

      assert [candidate] = candidates_for(meeting_id)
      assert candidate.outcome_kind == :artifact
    end

    test "a dedupe_key repeat leaves the FIRST row and adds no second", %{
      meeting_id: meeting_id
    } do
      start_queue!(meeting_id)

      shared = attrs(%{dedupe_key: "dk-shared"})
      {:ok, first} = IntentQueue.enqueue(meeting_id, shared)

      assert {:duplicate, ^first} =
               IntentQueue.enqueue(meeting_id, Map.put(shared, :chunk_excerpt, "said again"))

      # Distinguishes "no SECOND row" from "no row at all": the single
      # surviving row must be the first enqueue's, with its excerpt.
      assert [candidate] = candidates_for(meeting_id)
      assert candidate.intent_id == first.id
      assert candidate.evidence_quote == "we should file a task for the billing bug"
    end
  end

  describe "transition mirror" do
    test "queued -> dispatched advances the candidate to :shaping", %{meeting_id: meeting_id} do
      start_queue!(meeting_id)
      {:ok, row} = IntentQueue.enqueue(meeting_id, attrs())

      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)

      candidate = Candidates.get_by_intent_id(row.id)
      assert candidate.state == :shaping
      assert candidate.queue_status == "dispatched"
      assert candidate.dispatched_at
      refute candidate.disposition
    end

    test "queued -> dispatched -> timed_out records :timed_out", %{meeting_id: meeting_id} do
      start_queue!(meeting_id)
      {:ok, row} = IntentQueue.enqueue(meeting_id, attrs())

      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :timed_out)

      candidate = Candidates.get_by_intent_id(row.id)
      assert candidate.disposition == :timed_out
      assert candidate.state == :closed
      assert candidate.closed_reason == :dismissed
      assert [_only_one] = candidates_for(meeting_id)
    end
  end

  describe "ack mirror" do
    test "a full queued -> dispatched -> acked -> completed walk leaves ONE accepted row", %{
      meeting_id: meeting_id
    } do
      start_queue!(meeting_id)
      {:ok, row} = IntentQueue.enqueue(meeting_id, attrs())

      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)
      {:ok, _} = IntentQueue.ack(meeting_id, row.id, "subagent-1", :working)

      acting = Candidates.get_by_intent_id(row.id)
      assert acting.state == :acting
      assert acting.acted_at

      {:ok, _} = IntentQueue.ack(meeting_id, row.id, "subagent-1", :completed)

      assert [candidate] = candidates_for(meeting_id)
      assert candidate.disposition == :accepted
      assert candidate.state == :closed
      assert candidate.closed_reason == :done
    end

    test "a rejected ack records :rejected, NOT :accepted", %{meeting_id: meeting_id} do
      start_queue!(meeting_id)
      {:ok, row} = IntentQueue.enqueue(meeting_id, attrs())

      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)
      {:ok, _} = IntentQueue.ack(meeting_id, row.id, "subagent-1", :rejected, "wrong target")

      candidate = Candidates.get_by_intent_id(row.id)
      # Both outcomes land, and they land distinguishably — the queue
      # row is `:completed` for accepted AND rejected acks alike.
      assert candidate.disposition == :rejected
      assert candidate.state == :closed
      assert candidate.closed_reason == :dismissed
    end

    test "cancel_honored closes :retracted", %{meeting_id: meeting_id} do
      start_queue!(meeting_id)
      {:ok, row} = IntentQueue.enqueue(meeting_id, attrs())

      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)
      {:ok, _} = IntentQueue.ack(meeting_id, row.id, "subagent-1", :cancel_honored)

      candidate = Candidates.get_by_intent_id(row.id)
      assert candidate.closed_reason == :retracted
      assert candidate.state == :closed
    end
  end

  describe "the mirror is non-fatal" do
    test "a failing Repo leaves enqueue/transition/ack returning normally", %{
      meeting_id: meeting_id
    } do
      # Deliberately NO Sandbox.allow, AND shared mode is dropped for
      # the duration: the queue owner is left with no usable connection
      # while the test process keeps its explicit allowance. That is
      # this suite's stand-in for "Postgres is momentarily
      # unavailable". `start_owner!(shared: true)` in DataCase's setup
      # re-establishes shared mode for the next case.
      {:ok, _pid} = QueueSupervisor.ensure_started(meeting_id, [])
      Sandbox.mode(Repo, :manual)

      log =
        capture_log(fn ->
          # Asserted on the QUEUE's own return values. "It didn't
          # crash" would also be satisfied by a mirror that never ran,
          # which is why the log assertion below is not optional.
          assert {:ok, row} = IntentQueue.enqueue(meeting_id, attrs())
          assert row.status == :queued

          assert {:ok, dispatched} = IntentQueue.transition(meeting_id, row.id, :dispatched)
          assert dispatched.status == :dispatched

          assert {:ok, acked} = IntentQueue.ack(meeting_id, row.id, "subagent-1", :working)
          assert acked.status == :acked

          assert {:ok, completed} =
                   IntentQueue.ack(meeting_id, row.id, "subagent-1", :completed)

          assert completed.status == :completed

          # The queue itself is untouched by the failure.
          assert [listed] = IntentQueue.list(meeting_id)
          assert listed.id == row.id
        end)

      # Restore shared mode for DataCase's connection-dependent
      # teardown. The original owner is not reachable from here, so a
      # fresh shared owner stands in; it is stopped before DataCase's
      # own on_exit runs.
      restored = Sandbox.start_owner!(Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(restored) end)

      # Proof the mirror actually RAN and was rescued, rather than
      # having been silently skipped. Without this the case would be
      # satisfied by a mirror that was never wired in at all.
      assert log =~ "candidate mirror failed"
      assert log =~ meeting_id

      # Deliberately NOT asserting the durable row is absent: the
      # restored owner is a different sandbox transaction, so such an
      # assertion would read empty whether or not the mirror wrote.
    end
  end
end
