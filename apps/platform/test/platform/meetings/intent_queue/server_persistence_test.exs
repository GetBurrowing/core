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
  alias Platform.Meetings.CandidateSweeper
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.IntentQueue.Server
  alias Platform.Meetings.IntentQueue.Supervisor, as: QueueSupervisor
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Tasks.Task, as: WorkTask

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

  # ── Every terminal queue status reaches the durable row (task 01a04a36) ───
  #
  # `server_test.exs` next door walks all nine queue statuses through
  # `transition/3` and asserts on the ETS row, which reads like coverage
  # of this mapping. It is not. Its meeting ids were not UUIDs, so every
  # mirror insert raised `Ecto.ChangeError` at dump time and the
  # non-fatal `mirror/1` wrapper logged it away: 74 swallowed raises and
  # zero `meeting_candidates` rows under 49 green tests. Nor could it
  # have covered this even with valid ids — it is `ExUnit.Case`, so the
  # queue owner has no sandbox connection to write through.
  #
  # So the mapping is asserted HERE, in the one module that allows the
  # queue owner onto the test's connection. Before this block only
  # `:completed` (through the ack hook) and `:timed_out` were exercised
  # end to end. `:cancelled`, `:cancelled_late`, `:dispatch_failed` and
  # `:no_ack_spawn_failed` — the four carrying the "rejected" half of the
  # measurement axis this table exists to record — had nothing between
  # `Candidates.queue_status_to_*/1`'s lookup tables, unit-tested in
  # `candidates_test.exs`, and a durable row.
  describe "terminal transition mirror" do
    @terminal_expectations %{
      completed: {:accepted, :done},
      cancelled: {:rejected, :retracted},
      cancelled_late: {:rejected, :retracted},
      timed_out: {:timed_out, :dismissed},
      dispatch_failed: {:rejected, :dismissed},
      no_ack_spawn_failed: {:rejected, :dismissed}
    }

    # Exhaustive by construction. A seventh terminal status added to the
    # queue without an expectation below turns this red rather than
    # arriving uncovered — which is the failure mode this whole task is
    # about.
    test "the expectation table names every terminal status and no other" do
      assert Enum.sort(Map.keys(@terminal_expectations)) ==
               Enum.sort(Server.terminal_statuses())
    end

    for {status, {disposition, closed_reason}} <- @terminal_expectations do
      test "a #{status} transition closes the row #{disposition}/#{closed_reason}", %{
        meeting_id: meeting_id
      } do
        status = unquote(status)
        disposition = unquote(disposition)
        closed_reason = unquote(closed_reason)

        start_queue!(meeting_id)
        {:ok, row} = IntentQueue.enqueue(meeting_id, attrs())
        {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)
        {:ok, _} = IntentQueue.transition(meeting_id, row.id, status)

        candidates = candidates_for(meeting_id)

        assert [candidate] = candidates,
               "expected exactly one meeting_candidates row for meeting #{meeting_id} after a " <>
                 "#{status} transition, got #{inspect(candidates)}. A mirror that never ran " <>
                 "answers [] and fails no other assertion (task 01a04a36)."

        assert candidate.intent_id == row.id

        # The verbatim queue status, the lifecycle axis and the
        # measurement axis are three separate columns and all three have
        # to land. `state == :closed` alone would be satisfied by every
        # one of these six statuses, which is exactly the collapse that
        # produced the all-negative corpus.
        assert candidate.queue_status == to_string(status)
        assert candidate.state == :closed
        assert candidate.disposition == disposition
        assert candidate.closed_reason == closed_reason
        assert candidate.closed_at
        assert candidate.disposition_at
      end
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

  # ── The PRODUCTION posture (task 01a04a36) ───────────────────────────────
  #
  # Everything above runs with `:intent_queue_mirror_fatal` armed, which
  # is what `config/test.exs` does for the whole suite: a mirror that
  # cannot write raises `IntentQueue.MirrorError` rather than logging.
  #
  # This block asserts the opposite posture, the one `:dev` and `:prod`
  # actually run, and so is the ONE place in the tree that disarms the
  # switch. It is not an exemption for a module that was inconvenient to
  # fix — it is the test FOR the branch, and without it the non-fatal
  # path would have no coverage at all in an env that never takes it.
  # `mirror_fatality_test.exs` asserts that this is the only file which
  # touches the key, so the carve-out cannot quietly grow a second
  # member.
  describe "the mirror is non-fatal outside test" do
    setup do
      previous = Application.get_env(:platform, :intent_queue_mirror_fatal)
      Application.put_env(:platform, :intent_queue_mirror_fatal, false)

      on_exit(fn ->
        # Restore rather than hard-set: the key's value is config's to
        # decide, and a test that pins `true` here would keep passing if
        # `config/test.exs` ever stopped arming it.
        case previous do
          nil -> Application.delete_env(:platform, :intent_queue_mirror_fatal)
          value -> Application.put_env(:platform, :intent_queue_mirror_fatal, value)
        end
      end)

      %{fatal_before_disarm: previous}
    end

    test "the switch really is disarmed here, and what it overrode was armed", %{
      fatal_before_disarm: before
    } do
      # Two facts in one case, because either alone is satisfiable by a
      # broken setup. `refute` alone would pass if the key had never
      # been armed; `assert before` alone would pass if the disarm
      # silently no-opped. Together they say: this block runs the
      # production branch, and the rest of the suite does not.
      refute Application.get_env(:platform, :intent_queue_mirror_fatal)
      assert before, "config/test.exs is expected to arm :intent_queue_mirror_fatal"
    end

    test "a failing Repo leaves enqueue/transition/ack returning normally", %{
      meeting_id: meeting_id
    } do
      # Deliberately NO Sandbox.allow, AND shared mode is dropped for
      # the duration: the queue owner is left with no usable connection.
      # That is this suite's stand-in for "Postgres is momentarily
      # unavailable". `start_owner!(shared: true)` in DataCase's setup
      # re-establishes shared mode for the next case.
      #
      # Note that the mode change checks EVERY process in, this one and
      # DataCase's owner included (`DBConnection.Ownership.Manager`,
      # `proxy_checkin_all_except/3` on a `{:mode, _}` call) — nothing
      # below reads the database on purpose. The skeleton case further
      # down needs to, and checks the test process out again as an
      # owner of its own.
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

    # ── The skeleton the swallow leaves behind (task 01a06638 stage 4) ──
    #
    # `IntentClassifier` opens a candidate row at ARRIVAL, before the
    # model answers, and `mirror_enqueue/3` is the only thing that ever
    # fills its classified fields in. When that mirror fails on the
    # production posture, the case above proves the queue carries on —
    # and says nothing about the row. This pair says the rest: the
    # skeleton is left armed and nil (not closed, not filled), and it is
    # the sweeper's reaper, not anything in this module, that closes it.

    @grace_ms 5_000

    test "a task skeleton the mirror could not fill stays disarmed evidence" do
      # Same stand-in for "Postgres is momentarily unavailable" as the
      # case above — the queue owner is started, never allowed, and
      # shared mode is off so it cannot borrow anybody's connection —
      # with one difference forced by the sandbox: dropping shared mode
      # checks every process in and rolls their transactions back, so a
      # skeleton written BEFORE the drop is gone by the time it is
      # read. The test process therefore becomes an owner in its own
      # right first, and everything it writes, reads and sweeps below
      # runs on that one connection. The queue owner is not allowed on
      # it, which is the whole point.
      Sandbox.mode(Repo, :manual)
      :ok = Sandbox.checkout(Repo)

      meeting = meeting!()
      chunk_id = Ecto.UUID.generate()
      skeleton = skeleton!(meeting, chunk_id)
      acts_at = skeleton.acts_at
      assert is_nil(acts_at)

      # Started from a bare process rather than from this one:
      # `QueueSupervisor.ensure_started/2` hands the owner its caller's
      # `$callers`, and the sandbox honours that chain, so a queue
      # started here would reach this test's connection through it.
      test_pid = self()

      spawn(fn ->
        send(test_pid, {:queue_started, QueueSupervisor.ensure_started(meeting.id, [])})
      end)

      assert_receive {:queue_started, {:ok, _pid}}, 1_000

      log =
        capture_log(fn ->
          assert {:ok, row} =
                   IntentQueue.enqueue(meeting.id, attrs(%{transcript_chunk_id: chunk_id}))

          assert row.status == :queued
        end)

      assert log =~ "candidate mirror failed"
      assert log =~ meeting.id

      # Stranded exactly as arrival left it: nobody filled it, nobody
      # closed it, and the deadline it will never be eligible for is
      # still set.
      row = reload!(skeleton)
      assert row.state == :heard
      assert is_nil(row.classified_intent)
      assert row.acts_at == acts_at
      assert is_nil(row.task_id)

      # The reaper, at the grace: closed on the record and nothing minted.
      at = DateTime.add(DateTime.utc_now(), @grace_ms + 60_000, :millisecond)

      assert %{fired: [], reaped: []} = CandidateSweeper.sweep_all(now: at, grace_ms: @grace_ms)
      row = reload!(skeleton)
      assert row.state == :heard
      assert is_nil(row.closed_reason)
      assert is_nil(row.task_id)
      assert tasks_for(meeting.project_id) == []

      # Hand the connection back, then restore shared mode for
      # DataCase's connection-dependent teardown, as the case above does.
      :ok = Sandbox.checkin(Repo)
      restored = Sandbox.start_owner!(Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(restored) end)
    end

    test "with the connection intact the same task skeleton is filled without filing" do
      # Positive control for the case above, on the same posture and the
      # same sequence with only the connection differing. Without it the
      # reap could be read as "the mirror never fills skeletons".
      meeting = meeting!()
      chunk_id = Ecto.UUID.generate()
      skeleton = skeleton!(meeting, chunk_id)
      acts_at = skeleton.acts_at

      start_queue!(meeting.id)

      # A classification that reaches somebody: `reconcile/2` DISARMS a
      # skeleton whose answer names no audience (`routable_attrs?/1`),
      # and this file's default `attrs/1` is not routable.
      routable = %{
        transcript_chunk_id: chunk_id,
        classified_intent: :action_items,
        target_role: :meeting_scribe
      }

      log =
        capture_log(fn ->
          assert {:ok, row} = IntentQueue.enqueue(meeting.id, attrs(routable))
          assert row.status == :queued
        end)

      refute log =~ "candidate mirror failed"

      filled = reload!(skeleton)
      assert filled.state == :heard
      assert filled.classified_intent == "action_items"
      assert filled.acts_at == acts_at

      assert %{fired: [], reaped: []} =
               CandidateSweeper.sweep_all(
                 now: DateTime.add(DateTime.utc_now(), 60, :second),
                 grace_ms: @grace_ms
               )

      row = reload!(skeleton)
      assert row.state == :heard
      assert is_nil(row.closed_reason)
      assert is_nil(row.task_id)
      assert tasks_for(meeting.project_id) == []
    end
  end

  # ── Fixtures for the skeleton route ────────────────────────────────────

  # A real meeting under a real project: firing mints a task, and a task
  # needs a project to land in. The setup's bare `meeting_id` is enough
  # for the queue but not for the mint.
  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Mirror Route Project #{n}",
        org_id: Platform.Tenancy.get_org_by_slug!("acme").id
      })

    {:ok, meeting} =
      Platform.Meetings.create_meeting(%{
        project_id: project.id,
        name: "Mirror Route Meeting #{n}",
        slug: "mirror-route-meeting-#{n}"
      })

    meeting
  end

  # The row `IntentClassifier` opens at arrival: heard 60s ago, so its
  # 30s countdown is already overdue by the time the queue is asked, and
  # a sweep at `acts_at` is a sweep in the past rather than a wait.
  defp skeleton!(meeting, chunk_id) do
    {:ok, skeleton} =
      Candidates.record_heard(%{
        meeting_id: meeting.id,
        transcript_chunk_id: chunk_id,
        evidence_quote: "we should file a task for the billing bug",
        speaker: "alice",
        heard_at: DateTime.add(DateTime.utc_now(), -60, :second),
        outcome_kind: :task
      })

    reload!(skeleton)
  end

  defp reload!(%MeetingCandidate{id: id}), do: Repo.get!(MeetingCandidate, id)

  defp tasks_for(project_id) do
    Repo.all(from(t in WorkTask, where: t.project_id == ^project_id))
  end
end
