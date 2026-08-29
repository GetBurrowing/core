defmodule Platform.Meetings.IntentQueue.MirrorFatalityTest do
  @moduledoc """
  The switch itself (task 01a04a36).

  `server_persistence_test.exs` asserts what the mirror WRITES. This
  file asserts what happens when it cannot — that the failure is loud,
  that it is loud for both of the mirror's two mouths, and that the
  ownership grant which made the rest of the suite survive fatality
  grants no more than it was supposed to.

  ## What was wrong, in one sentence

  A recording act that degrades silently is indistinguishable, from
  outside, from one that works. Two suites were found green while
  writing zero `meeting_candidates` rows (tasks 01a049f9 and
  01a04a36-643d) and neither failed an assertion while doing it.

  ## Why the audits at the bottom are tests and not a review note

  Both regressions are re-introducible in one line — a new
  `use ExUnit.Case` module that drives the queue, or a second file
  putting the fatality key to `false` in app env. Neither would fail
  anything.

  This paragraph deliberately describes that second line rather than
  writing it out: the audit below scans for the form with no exclusion
  list, including in its own source, and prose containing the form
  would be a hit. `regression/adr_citation_audit_test.exs` names the
  same constraint on itself. They are checked here, statically, for
  the same reason `regression/adr_citation_audit_test.exs` exists: the
  property is greppable, so a reviewer is the wrong mechanism.
  """

  use Platform.DataCase, async: true

  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.IntentQueue.MirrorError
  alias Platform.Meetings.IntentQueue.Supervisor, as: QueueSupervisor

  @test_root "test"

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        classified_intent: :create_task,
        target_role: :engineering,
        confidence: 0.91,
        transcript_chunk_id: Ecto.UUID.generate(),
        chunk_excerpt: "we should file a task for the billing bug",
        dedupe_key: "dk-#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  setup do
    meeting_id = Ecto.UUID.generate()
    on_exit(fn -> IntentQueue.stop(meeting_id) end)
    %{meeting_id: meeting_id}
  end

  describe "the switch is armed" do
    test "config/test.exs arms :intent_queue_mirror_fatal" do
      # `fetch_env!`, not `get_env/3`. A default would make this pass
      # against a key that config never set, which is the exact state
      # this task exists to leave behind.
      assert Application.fetch_env!(:platform, :intent_queue_mirror_fatal) == true
    end
  end

  describe "a queue owner that CAN reach the sandbox" do
    # The positive control for the ownership fix, and the reason the
    # other 99 cases across four files are not vacuously green: the row
    # is read back, so "the mirror ran" is separated from "the mirror
    # did not raise".
    test "writes the durable row, without any explicit Sandbox.allow", %{
      meeting_id: meeting_id
    } do
      {:ok, row} = IntentQueue.enqueue(meeting_id, attrs())

      assert [candidate] = Candidates.list_for_meeting(meeting_id),
             "the queue owner inherited this test's connection through $callers " <>
               "(IntentQueue.Supervisor.ensure_started/2), so the mirror insert should " <>
               "have landed. An empty list here means the grant did not happen and " <>
               "fatality is the only thing standing between this suite and silence."

      assert candidate.intent_id == row.id
      assert candidate.evidence_quote == "we should file a task for the billing bug"
    end
  end

  describe "a queue owner that CANNOT reach the sandbox" do
    # The other half of the control the ticket asked for: the grant must
    # not have been a blanket one. A queue started from a bare process
    # inherits a caller chain that reaches no connection, and must still
    # be unable to write — loudly, now, rather than into a log line.
    test "raises MirrorError instead of logging, and writes nothing", %{
      meeting_id: meeting_id
    } do
      start_owner_from_unconnected_process!(meeting_id)

      exit_reason = catch_exit(IntentQueue.enqueue(meeting_id, attrs()))

      # `GenServer.call` wraps a crashed server's exit reason, which is
      # itself `{exception, stacktrace}` — hence two layers.
      assert {{%MirrorError{message: message}, _stack}, _call} = exit_reason
      assert message =~ "candidate mirror failed"
      assert message =~ meeting_id
      assert message =~ "ownership"

      # Not merely "it raised": nothing reached the table either. A
      # raise AFTER a successful insert would be a different bug with
      # the same signature.
      assert Candidates.list_for_meeting(meeting_id) == []
    end

    test "the raised message reports the underlying error exactly once", %{
      meeting_id: meeting_id
    } do
      # Guards the scoping of `run_mirror/1`'s rescue. If the reporter
      # were moved back inside a body carrying that rescue, the raise
      # would be caught by it and re-reported wrapped in itself. The run
      # would still fail, so a bare `assert_raise` cannot see the
      # difference — only the message can.
      start_owner_from_unconnected_process!(meeting_id)

      assert {{%MirrorError{message: message}, _stack}, _call} =
               catch_exit(IntentQueue.enqueue(meeting_id, attrs()))

      assert length(String.split(message, "candidate mirror failed")) == 2,
             "expected exactly one report sentence, got: #{message}"
    end
  end

  describe "the error-RETURN mouth, not just the raise" do
    # `Candidates.create/1` answers `{:error, changeset}` rather than
    # raising, and before PR #841 the wrapper was `fun.(); :ok` — that
    # return was discarded without even a log. Fatality has to cover it
    # too, or the quieter of the two mouths stays open.
    #
    # `outcome_kind` is an `Ecto.Enum` and `validate_required`, and the
    # queue passes `attrs[:outcome_kind]` through untouched (it is
    # "POPULATED, not classified" — see the Server moduledoc), so an
    # out-of-set value is a changeset error reachable from the public
    # API with no mocking.
    test "an invalid enum reaches the caller as MirrorError", %{meeting_id: meeting_id} do
      assert {{%MirrorError{message: message}, _stack}, _call} =
               catch_exit(IntentQueue.enqueue(meeting_id, attrs(%{outcome_kind: :not_a_kind})))

      assert message =~ "outcome_kind"
      assert message =~ "is invalid"

      # The same one-report-sentence check as the ownership case, and
      # the one that actually bites: this path returns through
      # `run_mirror/1`'s `case` body, which the rescue DOES span, so a
      # reporter moved back inside that scope would rescue its own raise
      # and re-report it wrapped in itself. The ownership path arrives
      # in the `catch :exit` clause, which no rescue covers, and so
      # cannot see that mistake.
      assert length(String.split(message, "candidate mirror failed")) == 2,
             "expected exactly one report sentence, got: #{message}"

      # And this path too writes nothing — the changeset never inserted.
      assert Candidates.list_for_meeting(meeting_id) == []
    end

    test "a valid enum on the same path still writes", %{meeting_id: meeting_id} do
      # The discriminating half. Without it the case above would be
      # satisfied by an `enqueue/2` that rejects every `outcome_kind`,
      # or by one that had stopped mirroring altogether.
      {:ok, _row} = IntentQueue.enqueue(meeting_id, attrs(%{outcome_kind: :artifact}))

      assert [candidate] = Candidates.list_for_meeting(meeting_id)
      assert candidate.outcome_kind == :artifact
    end
  end

  # ── Static audits ─────────────────────────────────────────────────────────

  describe "the carve-out cannot grow" do
    test "server_persistence_test.exs is the only file that turns the key off" do
      # The WRITE, not the mention. Several files name the key in a
      # comment explaining why they moved to `DataCase`; naming it is
      # documentation, and only `put_env`/`delete_env` can actually take
      # the guard off.
      disarming =
        files_matching(~r/Application\.(put|delete)_env\([^)]*:intent_queue_mirror_fatal/)

      assert disarming == ["test/platform/meetings/intent_queue/server_persistence_test.exs"],
             "the production-posture case in server_persistence_test.exs is the only " <>
               "legitimate reason to turn this key off; a second one is an exemption " <>
               "list forming. Got: #{inspect(Enum.sort(disarming))}"
    end

    test "the grep that audit uses finds things when they are there" do
      # Positive control for the two file scans in this describe block.
      # An empty result from `files_matching/1` is otherwise
      # indistinguishable between "the property holds" and "the scan is
      # looking in the wrong place / the regex never matches anything".
      hits = files_matching(~r/Application\.(put|delete)_env\([^)]*:platform/)

      assert length(hits) > 20,
             "expected the scanner to find the many files that put_env a :platform key " <>
               "under #{@test_root}, found #{length(hits)} — the scan itself is broken, " <>
               "so every negative result it produces is unproven."

      assert "test/platform/meetings/intent_queue/server_persistence_test.exs" in hits
    end
  end

  describe "no test module drives the queue without a connection" do
    # The regression that made fatality unlandable for a month: a module
    # that uses the queue but never checks out a sandbox connection. Its
    # mirror writes could only ever fail, and the non-fatal wrapper made
    # that look like 49 passing tests.
    test "every file that enqueues or starts a queue has a database case" do
      offenders =
        ~r/IntentQueue\.(enqueue|ensure_started)\(|QueueSupervisor\.ensure_started\(/
        |> files_matching()
        |> Enum.filter(&String.match?(File.read!(&1), ~r/^\s*use ExUnit\.Case/m))

      assert offenders == [],
             "these modules drive the intent queue from `ExUnit.Case`, so the queue " <>
               "owner has no sandbox connection to inherit and every candidate mirror " <>
               "write they trigger fails. Use `Platform.DataCase` (async is preserved) " <>
               "or `PlatformWeb.ConnCase`: #{inspect(offenders)}"
    end

    test "the ExUnit.Case detector fires on a module that really is one" do
      # Positive control for the filter above, whose negative result is
      # otherwise worthless. Scanned the same way, against the same
      # tree: plain `ExUnit.Case` modules are common here, so a detector
      # finding none of them is broken rather than vindicated.
      plain = files_matching(~r/^\s*use ExUnit\.Case/m)

      assert length(plain) > 20,
             "expected many plain ExUnit.Case modules under #{@test_root}, found " <>
               "#{length(plain)}"

      # And none of them is one of the four this task converted or fixed.
      refute "test/platform/meetings/intent_queue/server_test.exs" in plain
      refute "test/platform/meetings/intent_queue/ack_window_margin_test.exs" in plain
    end
  end

  # Start the meeting's queue owner from a process holding no sandbox
  # connection and naming no connected caller, then wait for it to be
  # registered. The owner survives the spawned process — it is
  # supervised — so what the test is left with is a live queue whose
  # inherited caller chain reaches nothing.
  defp start_owner_from_unconnected_process!(meeting_id) do
    parent = self()

    {:ok, _task} =
      Task.start(fn ->
        # `Task.start/1` DOES propagate `$callers`, so it is cleared
        # here on purpose: inheriting this test's chain is precisely
        # what the case is arranging not to happen.
        Process.delete(:"$callers")
        {:ok, pid} = QueueSupervisor.ensure_started(meeting_id, [])
        send(parent, {:queue_started, pid})
      end)

    assert_receive {:queue_started, pid}, 1_000
    pid
  end

  defp files_matching(regex) do
    @test_root
    |> Path.join("**/*.exs")
    |> Path.wildcard()
    |> Enum.filter(&String.match?(File.read!(&1), regex))
    |> Enum.sort()
  end
end
