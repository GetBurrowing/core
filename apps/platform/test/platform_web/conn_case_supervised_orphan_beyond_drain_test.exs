# QUEUED-BEYOND-DRAIN and LATE: a supervised orphan whose audit write is already
# queued on the sandbox's `DBConnection.Ownership.Proxy` (behind a blocker that
# holds the connection) when the sandbox owner goes away. The write
# arrives as a process EXIT, `Platform.Audit.TelemetryHandler.persist_or_skip/4`
# deliberately does not `catch :exit`, so it escapes `handle_event/4` and
# `:telemetry` DETACHES the handler VM-wide. `HandlerGuardian` then repairs it
# from inside the failure event.
#
# Split out of `conn_case_supervised_orphan_test.exs` by task 01a08b49 stage 4.
# That file's header carries the full characterisation of the three shapes and
# is still where to read it. The LATE shape lives here too because this case's
# body is what spawns its orphans. Since task 01a08d5d LATE no longer sleeps a
# fixed interval: its orphans monitor the BLOCKER and write only after its
# `:DOWN` — the ownership proxy's disconnect — so the case proves "a write
# arriving strictly after the owner's exit has taken effect raises
# OwnershipError" rather than "a write 500 ms later does". Gating on the
# owner's own `:DOWN` was measured and is not sufficient; see `@late_gate_ms`.
#
# ## WHY THIS CASE NEEDS ITS OWN BEAM — AND WHY IT STAYS `async: true`
#
# Task 01a08b49 stage 4. This is the only case in the family that DETACHES
# `platform-audit-telemetry` on purpose, and `:telemetry`'s handler registry is
# VM-GLOBAL. Its orphans also exit ASYNCHRONOUSLY — `Sandbox.stop_owner/1`
# returns before the `{:shutdown, %DBConnection.ConnectionError{}}` exits have
# propagated — so the detach, and the guardian's repair of it, can land after
# this case's own teardown and inside a SIBLING module's window.
#
# MEASURED, CI run 34529749646: QUEUED-DRAINED failed on its very first
# statement, `assert handler_attached?()`, with the guardian logging its repair
# one line later. The exit's own stacktrace named a client parked in
# `Process.sleep/1` directly inside `Platform.Repo.transaction/2` — that is
# `start_blocker/1`'s 3_000 ms hold, which belongs only to this case. A second
# failure ("No reading recorded for :drained_class") was fallout: the aborted
# assert ran before the `put_observation(_, :never_ran)` lines.
#
# So this module is tagged `:isolated_beam`, excluded from the default run by
# `Platform.IsolatedBeamTests`, and run by its OWN `mix test` invocation in
# `.github/workflows/ci.yml` — a separate OS process, therefore a separate BEAM,
# with no other module resident to contaminate or be contaminated.
#
# `async: true` IS LOAD-BEARING AND MUST NOT BE FLIPPED. It was tried and
# measured on 2026-09-10, and `async: false` destroys the construction rather
# than isolating it. `PlatformWeb.ConnCase` derives THREE things from that one
# word (`test/support/conn_case.ex`):
#
#   1. `Sandbox.start_owner!(Repo, shared: not tags[:async])` — non-async means
#      SHARED mode, so ownership resolves through the shared owner and the LATE
#      shape never raises `DBConnection.OwnershipError` at all;
#   2. `shared_mode? = not tags[:async]`, which selects the teardown branch;
#   3. that branch calls `SandboxHelpers.drain_or_warn()`, which takes NO
#      options — so `@tag sandbox_drain_timeout:` is SILENTLY a no-op in a
#      non-async module, while still sitting in the source reading as meaningful.
#
# Measured effect of flipping it: this case's `class` changed from
# `{:exit, "owner #PID<...> exited"}` to `{:raise, DBConnection.ConnectionError,
# "...connections are shared... dropped from queue after 981ms"}`, and LATE's
# from `{:raise, DBConnection.OwnershipError, "cannot find ownership process"}`
# to the same starvation raise. Both are RAISES, which `persist_or_skip/4`
# RESCUES — so nothing detached and the case silently stopped reproducing the
# defect while still passing for a reader's purposes. Isolation must come from
# the BEAM boundary, never from `async:`.
#
# ## THIS CASE IS THE GUARDIAN'S ONLY PROOF — DO NOT DELETE IT TO GET GREEN
#
# `Platform.Telemetry.HandlerGuardian` is stage 1's remedy, and this is the only
# case anywhere that demonstrates it repairing a REAL VM-wide detach: one
# `Class=:exit`, one restore, paired ~558 ms apart, one detach in a 16k-test run,
# repaired. Drop this case and the branch ships two remedies with no test that
# the central one works. If someone proposes deleting it because it will not
# cohabit with its siblings, that is the objection.
#
# The helpers below are duplicated from the sibling file rather than shared,
# including the "is it parked?" predicate (`parked?/3`) and the proxy lookup
# behind it (`held_connection_proxy/0`),
# because each file must be runnable alone — the observation modules flunk with
# "run the whole file" if their producer did not run in the same BEAM — and the
# two blockers have already diverged: this one holds for a fixed span, the
# sibling's releases itself on observing the parked shape. A change to a shared
# helper needs applying in both places; there is no third home that would make
# that automatic without a new support module.

defmodule PlatformWeb.ConnCaseSupervisedOrphanBeyondDrainTest do
  use PlatformWeb.ConnCase, async: true

  # Excluded from the default run by `Platform.IsolatedBeamTests`; run by its own
  # `mix test --only isolated_beam` invocation in ci.yml. See the header.
  @moduletag :isolated_beam

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Audit.TelemetryHandler
  alias Platform.Telemetry.HandlerGuardian

  @event [:platform, :auth, :login]
  @handler_id "platform-audit-telemetry"

  # `[:platform, :auth, :login]` is registered in `TelemetryHandler.@events`
  # and routes to the DEFAULT `handle_event/4` clause — the SYNCHRONOUS persist
  # path. That is required: the historian clauses hand off to another
  # `Task.Supervisor` child, so an exit there never crosses `handle_event/4`
  # and `:telemetry` never sees it. `[:platform, :meetings,
  # :transcription_failed]` is unusable for the same reason in reverse — it
  # carries a narrow `catch :exit` mitigation.
  @audit_attrs %{
    event_type: "platform.auth.login",
    actor_type: "system",
    action: "supervised_orphan_probe"
  }

  # Long enough that the blocker is still holding the connection when the owner
  # is stopped — since task 01a0d0fc-4d92-7001-83a2-94b3316e4603 stage 2
  # (2026-09-24) by the test BODY itself, immediately after the rendezvous — so
  # the queued orphans are parked (killed as exits by the proxy disconnect)
  # rather than served.
  @blocker_hold_ms 3_000

  # The LATE shape no longer sleeps a fixed interval. It used to
  # (`@late_delay_ms 500`), and task 01a08d5d measured that the interval is not
  # under this test's control: in an otherwise-empty BEAM on both GitHub CI
  # (run 34542464395) and test-host, the owner was still alive 500 ms after the body
  # returned, so LATE's write was PARKED behind the blocker like the queued
  # orphan and arrived as the same `{:exit, "owner ... exited"}` — 3 tests,
  # 1 failure on both rigs, 2 detaches instead of 1. The positive control for
  # that diagnosis: at 3_500 ms (past `@blocker_hold_ms`) the same file read
  # `3 tests, 0 failures`, exactly 1 `Class=:exit`. A sleep tunes that race;
  # the orphan now monitors the sandbox owner and emits only after its `:DOWN`,
  # which is the event "strictly after the owner's exit" by definition.
  # Task 01a08d5d then measured that the OWNER's `:DOWN` is not enough either:
  # gated on it, LATE still read `{:exit, "owner ... exited"}` on both rigs.
  # Timeline (test-host): owner-exited disconnect logged at .368, both handler
  # failures at .882 — about 500 ms in which the owner is dead but the
  # `DBConnection.Ownership` proxy still resolves and still holds the blocker's
  # connection, so a write started in that gap parks and dies with the QUEUED
  # shape. LATE's real precondition is the PROXY's disconnect; the observable
  # used for it was the BLOCKER's death, because the proxy kills the blocker's
  # transaction ("Client ... is still using a connection") as it disconnects.
  #
  # SUPERSEDED, 2026-09-24, task 01a0d0fc-4d92-7001-83a2-94b3316e4603 stage 2 —
  # the paragraphs above are the measurements that produced the OLD gates; the
  # measurements stand, the gates did not survive main-push CI. Both gates are
  # replaced:
  #
  #   * CI run 35935904608 — the QUEUED shape read
  #     `{:raise, DBConnection.ConnectionError, "...connection not available and
  #     request was dropped from queue after 125ms..."}` instead of an exit. The
  #     parked orphan's checkout sat in the proxy's wait queue past the
  #     backpressure bound (`@queue_target` 50 → a 100 ms timeout, enforced on
  #     the proxy's 1_000 ms poll: `DBConnection.Ownership.Proxy` drops waiters
  #     older than `queue_target * 2`) while the owner was STILL ALIVE, because
  #     the owner only died when the loaded teardown — the 50 ms drain give-up,
  #     then `Sandbox.stop_owner/1` — got around to it. A queue drop is a RAISE,
  #     `persist_or_skip/4` rescues it, nothing detaches, and the case measures
  #     nothing. Fix (a): the test BODY stops the owner itself, immediately
  #     after the rendezvous that proves the orphans parked — see the body.
  #
  #   * CI run 35931665349 — LATE failed on `assert reading.before == true`
  #     with before == false. The old `{:after_down, blocker}` gate ordered
  #     LATE's write after the owner's exit but NOT after the QUEUED orphan's
  #     own detach → guardian-repair → re-attach cycle, which un-parks at the
  #     same disconnect: LATE sampled while the queued cycle was still in
  #     flight. Fix (b): the LATE EMITTER now awaits the QUEUED emitter's
  #     explicit `{:emitted_done, :queued, _}` completion signal — sent after
  #     that orphan records its reading, i.e. after its re-attach — bounded by
  #     `@emitted_done_gate_ms` and timing out to `{:gate_never_fired, _}`
  #     exactly as the old gate did. The LATE CLASSIFIER keeps
  #     `{:after_down, blocker}`: the blocker's death is still what makes the
  #     proxy resolve no owner.
  #
  # The class assertions are UNCHANGED by both fixes, and both classes are now
  # deterministic rather than timed: with (a) the queued orphan is parked when
  # the owner is killed (EXIT, detach, repair), and with (a)+(b) the late orphan
  # writes into a proxy that has already disconnected
  # (`DBConnection.OwnershipError` raise).
  @late_gate_ms 10_000

  # Added 2026-09-24 (task 01a0d0fc-4d92-7001-83a2-94b3316e4603 stage 2, fixing
  # main-push CI runs 35935904608 and 35931665349): bounds ONLY how long the
  # LATE emitter waits for the QUEUED emitter's explicit
  # `{:emitted_done, :queued, _}` completion signal — the rendezvous that
  # replaces LATE's old `{:after_down, blocker}` gate (superseded; see
  # `@late_gate_ms`). Not a tuned wall-clock race: a timeout here means the
  # queued orphan's cycle itself never completed, which is a finding, and it
  # surfaces as the same `{:gate_never_fired, _}` shape the old gate produced.
  @emitted_done_gate_ms 10_000

  @queue_deadline_ms 2_000
  @report_deadline_ms 10_000

  # Small enough that ConnCase's scoped drain gives up while the blocker is
  # still inside its transaction, which is what keeps the orphans in flight at
  # the owner's death. Not zero: the drain should be seen to RUN and report, not
  # be switched off. Since task 01a0d0fc stage 2 (2026-09-24) the owner's death
  # happens IN THE BODY (see the rendezvous), before this drain runs — but the
  # drain is UNTOUCHED and still gives up at this bound, because the late
  # classifier is still gated on the blocker's `:DOWN`, which lands long after
  # 50 ms. Removing the tag would not make the test stricter, it would
  # dismantle the construction.
  @drain_timeout_ms 50

  # Its OWN namespace, deliberately not shared with the DRAINED file. The two
  # files' observer modules each erase their own keys at `setup_all` exit, and a
  # shared namespace would let one file's cleanup delete a reading the other
  # had not read yet.
  @observation_key {:conn_case_supervised_orphan_beyond_drain, :observation}

  # Forces ConnCase's `async: true` scoped drain to time out — see the header
  # section "Why this file now forces the drain to TIME OUT". Removing this tag
  # does not make the test stricter, it dismantles the construction.
  @tag sandbox_drain_timeout: @drain_timeout_ms
  test "QUEUED-BEYOND-DRAIN: an orphan in flight when the drain gives up detaches the handler",
       %{conn: conn, sandbox_owner: owner} do
    assert %Plug.Conn{} = conn
    # Positive control 0 — the owner LATE's write will fail to find is alive
    # now. (LATE does not gate on this pid; see `@late_gate_ms`.)
    assert is_pid(owner) and Process.alive?(owner)

    # Positive control 1 — if the handler were already detached, every
    # `list_handlers` reading below would be meaningless.
    assert handler_attached?(),
           "#{@handler_id} must be attached before this test can measure anything"

    put_observation(:late, :never_ran)
    put_observation(:late_class, :never_ran)
    put_observation(:queued, :never_ran)
    put_observation(:queued_class, :never_ran)

    # Positive control 2 — a supervised child reaches the sandbox connection
    # through `$callers` while the test is alive. Without this, an orphan that
    # fails for want of ownership it never had would look identical to one
    # whose owner died underneath it. Deliberately a bare `SELECT 1` liveness
    # probe and not an audit-row count.
    parent = self()

    {:ok, _control} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        send(parent, {:control, Platform.Repo.query("SELECT 1")})
      end)

    assert_receive {:control, {:ok, %{rows: [[1]]}}}, 5_000

    # Positive control 4 — warm the orphan write path BEFORE any timed wait
    # starts. One supervised `Platform.Audit.record/1` loads, VM-globally, every
    # module that path needs (`Ecto.Repo.Schema`,
    # `Platform.Audit.TelemetryHandler.persist_or_skip/4`, the Postgrex
    # encoders), so `await_queued/2`'s `@queue_deadline_ms` window below
    # measures queueing, not code loading. MEASURED, CI run 35929466252:
    # without this, the queued orphan was still loading code when its 2_000 ms
    # deadline expired and read `{:gave_up, %{current_function:
    # {:code_server, :call, 1}, queue_length: 0}}`. The audit row this control
    # writes is acceptable test data.
    {:ok, _warmup} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        send(parent, {:warmup, Platform.Audit.record(@audit_attrs)})
      end)

    assert_receive {:warmup, {:ok, _event}}, 5_000

    # ── the blocker, started AFTER positive control 2 (which needs the
    # connection the blocker is about to hold) and BEFORE LATE, whose
    # classifier still gates on its death ──
    # Holds the single sandbox connection for `@blocker_hold_ms`, so the
    # QUEUED orphans below park behind it. It is also what the LATE CLASSIFIER
    # waits for: when the owner is stopped (in the body, after the rendezvous
    # below), the ownership proxy disconnects and kills this transaction, and
    # only from then on does a new write resolve NO owner. Do not remove or
    # move this as "unused by LATE".
    {blocker, proxy} = start_blocker(@blocker_hold_ms)
    assert Process.alive?(blocker)

    # ── LATE shape: writes only after the QUEUED orphan's cycle is complete ──
    # The emitter's gate is the queued emitter's explicit `{:emitted_done,
    # :queued, _}` signal (added 2026-09-24, task 01a0d0fc stage 2, CI run
    # 35931665349): the old `{:after_down, blocker}` gate ordered LATE after
    # the owner's exit but not after the queued orphan's own repair, and LATE
    # sampled `before == false` mid-cycle. No fixed sleep, and not the owner's
    # `:DOWN` either — both were measured and falsified; see `@late_gate_ms`.
    # The reverted 3_500 ms falsifier passed only because it outlasts
    # `@blocker_hold_ms` (3_000), i.e. it waited for the same event by
    # accident. The CLASSIFIER keeps `{:after_down, blocker}`: the blocker's
    # death is still what makes the proxy resolve no owner.
    late_emitter = spawn_emitter(:late, {:emitted_done, :queued}, nil)
    spawn_classifier(:late_class, {:after_down, blocker})

    # ── QUEUED shape: in flight when the owner goes away ──
    # `notify` is a LIST: the test process (for `{:about_to_emit}`, the
    # rendezvous below) and the late emitter (for `{:emitted_done, :queued,
    # _}`, the signal LATE's gate awaits — by then the test process has usually
    # already returned, since the queued cycle completes only after the owner
    # is stopped, which the body does itself below).
    emitter = spawn_emitter(:queued, 0, [self(), late_emitter])
    classifier = spawn_classifier(:queued_class, 0)

    assert_receive {:about_to_emit, ^emitter}, 5_000

    # Positive control 3 — the construction is a construction. What it proves,
    # and nothing wider: while the blocker held the connection, EACH queued
    # orphan was observed (a) blocked in `DBConnection.Holder.checkout_call/5`
    # and (b) present as an entry in the wait queue of the
    # `DBConnection.Ownership.Proxy` the blocker's own checkout came from. The
    # proxy enqueues a checkout only when another client holds the connection
    # (db_connection 2.9.0 `lib/db_connection/ownership/proxy.ex:122-133`), so
    # (b) cannot hold for a write that was simply served; the sibling file's
    # control-3 comment carries the full argument. Readings here (test-host, task
    # 01a08d52-4b42 stage 1), blocker made to hold no connection: RED at
    # `await_holding/1` on the lookup guard; with a proxy supplied anyway, RED
    # on this assertion (`:dead`); with that and `parked?/3` forced `true`,
    # this assertion passes and only the observer's `class` goes red.
    # If this ever degrades to `{:gave_up, _}` or `{:proxy_unreadable, _}` the
    # file has stopped building the defect and is measuring nothing, which is a
    # finding and not something to loosen.
    assert await_queued(emitter, proxy) == :queued
    assert await_queued(classifier, proxy) == :queued

    # ── deterministic owner death (added 2026-09-24, task 01a0d0fc stage 2,
    # fixing main-push CI run 35935904608) ──
    # The rendezvous above has PROVEN both queued orphans are parked on the
    # proxy's wait queue. The owner now dies HERE, within milliseconds of that
    # rendezvous, instead of whenever the loaded teardown — the 50 ms drain
    # give-up, then `Sandbox.stop_owner/1` — gets around to it. The owner's
    # death is what disconnects the proxy (`DBConnection.Ownership.Proxy`'s
    # handler for its owner monitor runs `shutdown("owner ... exited",
    # state)`), and the disconnect is what turns the parked orphans' writes
    # into EXITS. Leave the death to the teardown and the parked checkout can
    # be dropped by queue backpressure first — the proxy drops waiters older
    # than `queue_target * 2` (100 ms) on its 1_000 ms poll — and a drop is a
    # RAISE that `persist_or_skip/4` rescues, so nothing detaches: CI run
    # 35935904608 read exactly `{:raise, DBConnection.ConnectionError,
    # "...request was dropped from queue after 125ms..."}`.
    #
    # CONDITIONAL on the owner still being alive, and this body site is the
    # ONLY place that stops it before teardown. What the read of the sources
    # found (2026-09-24): `Sandbox.stop_owner/1` is `GenServer.stop(pid)`
    # (`deps/ecto_sql/.../sandbox.ex`, `stop_owner/1`), and `GenServer.stop/1`
    # on an already-dead target EXITS `:noproc` — stopping an already-stopped
    # owner is NOT a tolerated no-op. Verified with an isolated ExUnit probe: a
    # test whose body stopped its own owner and whose `on_exit` then called
    # `Sandbox.stop_owner/1` again failed with `** (EXIT) no process: the
    # process is not alive...`. ConnCase's teardown therefore stops the owner
    # conditionally now (`test/support/conn_case.ex`) — without that guard
    # every run of this file fails in `on_exit`. The teardown's own drain is
    # UNTOUCHED and still runs and gives up at `@drain_timeout_ms`: the late
    # classifier is still gated on the blocker's `:DOWN`, which lands long
    # after the drain's 50 ms, so the drain still exercises its timeout branch
    # and the tag stays load-bearing.
    if Process.alive?(owner), do: Sandbox.stop_owner(owner)
  end

  setup_all do
    on_exit(fn ->
      # Runs after this module's per-test teardown, including ConnCase's
      # `stop_owner/1` — so the detach has already happened by the time this
      # runs, unlike a per-test `on_exit`.
      await_report(:queued, @report_deadline_ms)
      await_report(:late, @report_deadline_ms)

      assert :ok = TelemetryHandler.attach()

      assert @event |> :telemetry.list_handlers() |> Enum.any?(&(&1.id == @handler_id)),
             "#{@handler_id} was not restored at the module boundary — every test " <>
               "scheduled after this module would run with audit silently disabled"
    end)

    :ok
  end

  # -- helpers --

  defp handler_attached? do
    @event |> :telemetry.list_handlers() |> Enum.any?(&(&1.id == @handler_id))
  end

  defp put_observation(key, value), do: :persistent_term.put({@observation_key, key}, value)

  defp get_observation(key), do: :persistent_term.get({@observation_key, key}, :ABSENT)

  # Emits the audited event, then records whether `@handler_id` survived it,
  # then restores. `gate` is `0` (emit now), `{:after_down, pid}`, or
  # `{:emitted_done, key}`. `notify` is nil, a pid, or a LIST of pids: every
  # recipient gets `{:about_to_emit, self()}` before the emission and
  # `{:emitted_done, key, self()}` after the reading is recorded. The
  # completion send was added 2026-09-24 (task 01a0d0fc stage 2, CI run
  # 35931665349) and is the explicit rendezvous LATE's gate awaits, replacing
  # the wall-clock ordering the old `{:after_down, blocker}` gate approximated.
  # It deliberately goes out AFTER `put_observation/2` — a recipient un-gated
  # by it must observe a handler that is attached and settled: the detach, the
  # guardian's repair inside `:telemetry.execute/3`, and this orphan's own
  # re-attach have all landed by then. The test-process recipient has usually
  # already returned by then (the queued cycle completes only after the owner
  # is stopped, which the body does itself), so the send to it is routinely
  # dropped; the gate's consumer is passed in `notify` precisely so the signal
  # reaches a LIVE recipient.
  defp spawn_emitter(key, gate, notify) do
    {:ok, pid} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        await_gate(gate)
        Enum.each(List.wrap(notify), &send(&1, {:about_to_emit, self()}))

        # Task 01a08b49 stage 1: since `Platform.Telemetry.HandlerGuardian` is
        # attached at boot, `after_emit` no longer distinguishes "the handler
        # was detached" from "the handler was never detached" — the guardian
        # repairs the detach inside this same `:telemetry.execute/3` call, so
        # both now read `true`. What discriminates instead is `class`, recorded
        # per-case by the classifier below: it is process-local, and it is the
        # only reading here that another module cannot move.
        #
        # The restore counts either side of the emission are still RECORDED, and
        # are deliberately ASSERTED NOWHERE. They were asserted in all three
        # cases and removed from all three: the counter is one BEAM-global
        # `:counters` array in `:persistent_term` keyed by handler id, and
        # `async: true` modules run concurrently, so the delta cannot be
        # attributed to this emission. Each case's comment carries the
        # measurement that showed it. They are kept because they are cheap and
        # they are what an emission-scoped guardian API would be checked against
        # — not because a delta is a check. Do not assert on them.
        restores_before = HandlerGuardian.restore_count(@handler_id)
        before = handler_attached?()
        :telemetry.execute(@event, %{system_time: System.system_time()}, @audit_attrs)
        after_emit = handler_attached?()
        restores_after = HandlerGuardian.restore_count(@handler_id)

        :ok = TelemetryHandler.attach()

        put_observation(key, %{
          before: before,
          after: after_emit,
          restored: handler_attached?(),
          restores_before: restores_before,
          restores_after: restores_after
        })

        # The explicit completion signal, sent LAST so it cannot outrun the
        # reading above. See spawn_emitter's doc.
        Enum.each(List.wrap(notify), &send(&1, {:emitted_done, key, self()}))
      end)

    pid
  end

  # Calls `Platform.Audit.record/1` directly — no telemetry — so the CLASS of
  # the failure arriving at the audit write is named rather than inferred. A
  # raise is rescued by `persist_or_skip/4`; an exit is not, and only an exit
  # can reach `:telemetry` and detach the handler.
  defp spawn_classifier(key, gate, notify \\ nil) do
    {:ok, pid} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        gate_result = await_gate(gate)
        if notify, do: send(notify, {:about_to_emit, self()})

        outcome =
          try do
            # A gate that timed out is its own class: the monitored process
            # never exited within `@late_gate_ms`, so no write was attempted
            # and the reading must not be mistaken for a raise or an exit.
            if gate_result != :ok, do: throw(gate_result)

            case Platform.Audit.record(@audit_attrs) do
              {:ok, _event} -> :inserted
              {:error, changeset} -> {:changeset_error, inspect(changeset.errors)}
            end
          rescue
            error -> {:raise, error.__struct__, Exception.message(error)}
          catch
            :exit, reason -> {:exit, inspect(reason, limit: 8)}
            :throw, {:gate_never_fired, _} = gate_timeout -> gate_timeout
          end

        put_observation(key, outcome)
      end)

    pid
  end

  # `0` emits immediately (the QUEUED shape). `{:after_down, pid}` monitors
  # `pid` and returns only once its `:DOWN` has arrived. The LATE CLASSIFIER
  # passes the BLOCKER: its death is the ownership proxy's disconnect, which is
  # the first moment a new write resolves no owner and raises `OwnershipError`.
  # The sandbox OWNER's `:DOWN` was measured and is NOT sufficient — the proxy
  # outlives the owner while the blocker holds the connection, and a write in
  # that gap parks and exits like the QUEUED shape. Bounded so a process that
  # never exits surfaces as a distinct reading, not a hung orphan.
  #
  # `{:emitted_done, key}` — added 2026-09-24, task
  # 01a0d0fc-4d92-7001-83a2-94b3316e4603 stage 2, fixing main-push CI runs
  # 35935904608 and 35931665349. The LATE EMITTER gates on it: it waits for the
  # QUEUED emitter's explicit `{:emitted_done, :queued, _}` message, which that
  # emitter sends only after recording its reading — i.e. after its detach →
  # guardian-repair → re-attach cycle has fully landed. The old
  # `{:after_down, blocker}` gate ordered LATE after the owner's exit but not
  # after the queued cycle, and CI run 35931665349 caught LATE sampling
  # `before == false` mid-repair. A timeout here is NOT a tuned wall-clock
  # degradation: it means the queued cycle itself never completed, and it
  # surfaces as the same `{:gate_never_fired, _}` shape the `:after_down` gate
  # produces.
  defp await_gate(0), do: :ok

  defp await_gate({:after_down, pid}) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @late_gate_ms -> {:gate_never_fired, pid}
    end
  end

  # The LATE EMITTER's gate: the queued emitter's own completion signal — an
  # explicit rendezvous, not a process death and not a wall-clock span. See the
  # doc above and `@emitted_done_gate_ms`.
  defp await_gate({:emitted_done, key}) when is_atom(key) do
    receive do
      {:emitted_done, ^key, _queued_emitter} -> :ok
    after
      @emitted_done_gate_ms -> {:gate_never_fired, key}
    end
  end

  # Holds the single sandbox connection from a supervised child, so anything
  # else that wants it queues. Rendezvous from INSIDE the transaction, so the
  # connection is provably held before the caller continues. Returns
  # `{blocker, proxy}`: the proxy is the one whose wait queue control 3 polls.
  defp start_blocker(hold_ms) do
    parent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        Platform.Repo.transaction(fn ->
          # Taken from the connection THIS process holds, so the queue
          # `await_queued/2` polls is the one a request for that connection
          # has to wait in.
          send(parent, {:holding, self(), held_connection_proxy()})
          Process.sleep(hold_ms)
        end)
      end)

    await_holding(pid)
  end

  # Rendezvous from INSIDE the transaction, so the connection is provably held
  # before the caller continues. Also where the proxy lookup's guard fails the
  # test: this runs in the TEST process, so a flunk here is the test's failure
  # and not a crashed child the test only notices as a timeout.
  defp await_holding(pid) do
    receive do
      {:holding, ^pid, {:ok, proxy}} ->
        {pid, proxy}

      {:holding, ^pid, {:error, why}} ->
        flunk("""
        The blocker could not name the DBConnection.Ownership.Proxy serving the
        connection it holds, so positive control 3 has nothing to poll.
        Observed: #{inspect(why, limit: 12)}

        `{:no_held_connection, _}` means there was no `%DBConnection{}` in the
        blocker's process dictionary, i.e. it is not inside a checkout at all.
        Any other reason means this file's reading of db_connection's internals
        no longer matches the installed version. Do not fall back to a weaker
        "is it parked?" check; fix the lookup.
        """)
    after
      5_000 -> flunk("blocker never acquired the sandbox connection")
    end
  end

  # The frame a process sits in while it waits for the proxy to hand it a
  # connection: the private `receive` in `DBConnection.Holder.checkout_call/5`
  # (db_connection 2.9.0 `lib/db_connection/holder.ex:288-309`).
  @parked_frame {DBConnection.Holder, :checkout_call, 5}

  # The `DBConnection.Ownership.Proxy` serving the connection the CALLING
  # process holds. Must be called from inside a checkout (here, the blocker's
  # `Platform.Repo.transaction/1`). A private copy of the sibling file's
  # function of the same name, which carries the derivation and the reading
  # logged on test-host (task 01a08d52-4b42 stage 1): the `%DBConnection{}` ecto_sql
  # keeps under `{Ecto.Adapters.SQL, adapter_meta.pid}`, whose `pool_ref`
  # record's `:pool` is the proxy.
  #
  # Every check that can fail returns `{:error, reason}` naming what was
  # observed and the installed db_connection version, and `await_holding/1`
  # flunks on it. There is deliberately no fallback: a lookup that quietly
  # degraded to "not queued" or to the old frame match would make control 3
  # vacuous again after a library upgrade.
  defp held_connection_proxy do
    meta = Ecto.Adapter.lookup_meta(Platform.Repo.get_dynamic_repo())

    with {:conn, %DBConnection{pool_ref: {:pool_ref, proxy, _, _, _, _}}} <-
           {:conn, Process.get({Ecto.Adapters.SQL, meta.pid})},
         true <- is_pid(proxy) and Process.alive?(proxy),
         {DBConnection.Ownership.Proxy, :init, 1} <- :proc_lib.translate_initial_call(proxy),
         {:ok, _waiting} <- proxy_wait_queue(proxy) do
      {:ok, proxy}
    else
      {:conn, other} -> {:error, {:no_held_connection, other, db_connection_vsn()}}
      false -> {:error, {:proxy_not_alive, db_connection_vsn()}}
      {:error, _} = error -> error
      initial_call -> {:error, {:not_an_ownership_proxy, initial_call, db_connection_vsn()}}
    end
  end

  # The proxy's wait queue, oldest first, as `{sent_at, {caller_pid, lock}}`
  # entries. `:sys.get_state/1` is db_connection's internal state, not an API;
  # a shape change is reported, never read as an empty queue.
  defp proxy_wait_queue(proxy) do
    case :sys.get_state(proxy) do
      %{queue: queue} ->
        if :queue.is_queue(queue),
          do: {:ok, :queue.to_list(queue)},
          else: {:error, {:unrecognised_proxy_queue, queue, db_connection_vsn()}}

      other ->
        {:error, {:unrecognised_proxy_state, other, db_connection_vsn()}}
    end
  catch
    :exit, reason -> {:error, {:proxy_unreadable, reason, db_connection_vsn()}}
  end

  defp db_connection_vsn, do: {:db_connection, Application.spec(:db_connection, :vsn)}

  # True only when `pid` is queued on the proxy the blocker holds: blocked in
  # `@parked_frame` AND an entry in that proxy's wait queue. See positive
  # control 3's comment for why each half is needed.
  defp parked?(pid, frame, waiting) do
    frame == @parked_frame and Enum.any?(waiting, &match?({_sent_at, {^pid, _lock}}, &1))
  end

  defp await_queued(pid, proxy, deadline_ms \\ @queue_deadline_ms) do
    do_await_queued(pid, proxy, System.monotonic_time(:millisecond) + deadline_ms)
  end

  defp do_await_queued(pid, proxy, deadline) do
    with {:current_function, frame} <- Process.info(pid, :current_function),
         {:ok, waiting} <- proxy_wait_queue(proxy) do
      cond do
        parked?(pid, frame, waiting) ->
          :queued

        System.monotonic_time(:millisecond) > deadline ->
          {:gave_up, %{current_function: frame, queue_length: length(waiting)}}

        true ->
          # Yield, and this is a correctness fix rather than a margin. The
          # loop used to spin with no sleep at all, as fast as a scheduler
          # would allow — so on a saturated runner it competed with, and
          # therefore DELAYED, the very processes it was waiting to see parked.
          # The instrument was generating the latency it then charged to the
          # residency budget. 1 ms of detection lag against a 100 ms budget is
          # noise; the contention was not.
          Process.sleep(1)
          do_await_queued(pid, proxy, deadline)
      end
    else
      nil -> :dead
      {:error, why} -> {:proxy_unreadable, why}
    end
  end

  defp await_report(key, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_report(key, deadline)
  end

  defp do_await_report(key, deadline) do
    case get_observation(key) do
      :never_ran ->
        if System.monotonic_time(:millisecond) > deadline do
          :timeout
        else
          Process.sleep(5)
          do_await_report(key, deadline)
        end

      other ->
        other
    end
  end
end

defmodule PlatformWeb.ConnCaseSupervisedOrphanBeyondDrainObservationTest do
  @moduledoc """
  Asserts the readings taken by the orphans in
  `PlatformWeb.ConnCaseSupervisedOrphanBeyondDrainTest`.

  `async: false` on purpose: ExUnit runs every asynchronous module before any
  synchronous one, so this module cannot start until the producer's teardown —
  and therefore the detach — has finished. It still polls with a deadline
  rather than resting on that ordering.
  """
  use ExUnit.Case, async: false

  # Same partition as its producer — it reads that producer's readings, so it
  # must run in the same BEAM. See the header.
  @moduletag :isolated_beam

  alias Platform.Audit.TelemetryHandler
  alias Platform.Telemetry.HandlerGuardian

  @event [:platform, :auth, :login]
  @handler_id "platform-audit-telemetry"
  @observation_key {:conn_case_supervised_orphan_beyond_drain, :observation}
  @report_deadline_ms 15_000

  setup do
    on_exit(fn ->
      # The restore, and an assertion that it took. Belt behind the orphan's
      # own re-attach and the producer module's `setup_all` restore.
      assert :ok = TelemetryHandler.attach()

      assert handler_attached?(),
             "#{@handler_id} is not attached after this module — the rest of the run " <>
               "would silently record no audit events"
    end)

    :ok
  end

  setup_all do
    # The readings are read by BOTH tests below, so they can only be discarded
    # once the module is done. Erasing per test would leave whichever test ran
    # second reading `:ABSENT` and reporting "the producer never ran", which is
    # a false accusation rather than a failure.
    on_exit(fn ->
      Enum.each(
        [:late, :late_class, :queued, :queued_class],
        &:persistent_term.erase({@observation_key, &1})
      )
    end)

    :ok
  end

  test "a LATE supervised orphan (writing strictly after the owner's exit) raises OwnershipError and leaves the handler attached" do
    class = await(:late_class)
    reading = await(:late)

    assert {:raise, DBConnection.OwnershipError, message} = class,
           """
           Expected a late orphan's audit write to RAISE DBConnection.OwnershipError.
           Got: #{inspect(class, limit: 8)}

           A raise is what `persist_or_skip/4` rescues. If this became an exit the
           late shape would detach the handler too, and the characterisation in this
           file's header would be wrong.
           """

    assert message =~ "cannot find ownership process"

    assert reading.before == true,
           "the handler was already detached when the late orphan ran — the queued " <>
             "orphan's restore did not land, which is the poisoning failure this " <>
             "file exists to prevent"

    assert reading.after == true,
           """
           A late orphan DETACHED #{@handler_id}. That contradicts the measured
           characterisation: a write that starts after the owner is gone raises
           OwnershipError, which is rescued. Re-derive the header before trusting it.
           """

    # WHY THERE IS NO `restores_after == restores_before` ASSERTION HERE.
    #
    # There was one. It was this file's THIRD attempt to make the guardian's
    # restore counter answer a per-case question, and CI falsified it the same
    # way stage 3 falsified the DRAINED one — see "WHY THERE IS NO
    # `restores_after == restores_before` ASSERTION HERE" in the QUEUED-DRAINED
    # case below, which reached this conclusion first and is the argument this
    # comment is consistent with.
    #
    # `HandlerGuardian.restore_count/1` reads ONE `:counters` array published in
    # `:persistent_term`, one index per handler id, for the whole BEAM (see the
    # guardian's own note on `@counters_key`). It carries no emission scope and
    # no caller scope. This suite runs `async: true` modules CONCURRENTLY, so a
    # delta sampled around one process's `:telemetry.execute/3` can be moved by a
    # detach in a module this test has never heard of. A BEAM-GLOBAL COUNTER
    # CANNOT ANSWER A PER-CASE QUESTION IN A CONCURRENT SUITE. That is a property
    # of the instrument, not of the seed, and no amount of ordering fixes it.
    #
    # MEASURED, in CI, not reasoned: when LATE still slept a fixed
    # `@late_delay_ms` of 500 with `@drain_timeout_ms` 50, the queued orphan's
    # detach was observed arriving 558 ms AFTER the drain gave up — i.e. inside
    # the window this case samples across. The delta LATE read belonged to the QUEUED orphan. The
    # deleted assertion's own failure message therefore made a FALSE ATTRIBUTION:
    # it printed "the handler DID fail and was merely repaired ... never reaching
    # `:telemetry`'s catch at all" while, in the same run and the same test,
    # `class` read `{:raise, DBConnection.OwnershipError, _}`. Both cannot be
    # true — a raise is rescued by `persist_or_skip/4` and never reaches
    # `:telemetry`'s catch, so no detach and no restore can be attributed to this
    # emission at all. `class` is process-local and right; the counter was global
    # and wrong. The header's old claim that a fixed delay puts this emission
    # safely after the beyond-drain detach is what CI refuted. Task 01a08d5d then
    # refuted the delay in the other direction: in an otherwise-empty BEAM (the
    # isolated partition) the owner was still alive at 500 ms, LATE's write was
    # parked behind the blocker, and `class` read the QUEUED shape's
    # `{:exit, "owner ... exited"}` on both GitHub CI and test-host (3 tests,
    # 1 failure, 2 detaches). Positive control: at 3_500 ms the same file read
    # 3 tests, 0 failures, 1 detach — because 3_500 outlasts `@blocker_hold_ms`.
    # Gating on the OWNER's `:DOWN` failed the same way (owner dead at .368,
    # failures at .882: the proxy outlives the owner). The orphan now waits for
    # the BLOCKER's `:DOWN` (`await_gate/1` in the producer), which is the
    # proxy's disconnect — the event, not a guess at it.
    #
    # WHAT REMAINS IS THE INSTRUMENT. The `class` assertion above is process-local
    # and genuinely discriminating: it is what separates "the handler RAISED"
    # (rescued inside `persist_or_skip/4`, nothing detaches) from "the handler
    # EXITED" (`{:shutdown, %DBConnection.ConnectionError{}}`, which escapes the
    # rescue and makes `:telemetry` detach the handler VM-wide — the actual
    # defect). It is the same reading, in its LATE-specific form, that decides the
    # other two cases. Do not weaken it, and do not reintroduce a sleep before the
    # LATE write: that tunes a race instead of fixing a measurement, and two rigs
    # have already shown the timing is not under this test's control.
    #
    # TO RESTORE PER-CASE ATTRIBUTION HONESTLY you need emission-scoped
    # attribution — a guardian API that reports restores of a given handler id
    # CAUSED BY THE CALLING PROCESS'S EMISSION (e.g. a per-`execute/3` token, or a
    # counter keyed by the failing handler's caller). No such API exists, no stage
    # owns building one, and inventing it here is out of scope.
    #
    # This is a deliberate departure from what stage 3 authored — this file's
    # header argued in writing for keeping the delta — and it is NOT stripping a
    # check to make a red test green. The delta was an instrument pointed at
    # another process; removing it removes a false reading, and the reading that
    # decides this case is untouched. Do not re-add it without the API above.
  end

  test "QUEUED-BEYOND-DRAIN: the orphan exits, the handler detaches, the guardian repairs it" do
    class = await(:queued_class)
    reading = await(:queued)

    assert {:exit, reason} = class,
           """
           Expected a queued orphan's in-flight audit write to arrive as a process EXIT.
           Got: #{inspect(class, limit: 8)}

           Only an exit escapes `persist_or_skip/4` — its `rescue` clauses catch every
           raise, and its refusal to `catch :exit` is deliberate and documented. If
           this is no longer an exit, the detach mechanism has changed.
           """

    assert reason =~ "owner", "the exit reason must name the owner: #{reason}"
    assert reason =~ "exited", "the exit reason must name the owner's exit: #{reason}"

    assert reading.before == true,
           "#{@handler_id} was not attached when the queued orphan ran, so its " <>
             "`after` reading measures nothing"

    # THE measurement, and it changed instrument in task 01a08b49 stage 1 without
    # the underlying residual changing.
    #
    # What this pins CHANGED in task 01a08b49 stage 2. It used to pin an open
    # residual — "nothing waits for an `async: true` orphan". Something does
    # now: `SandboxHelpers.await_own_supervised_writes/2`, called from
    # ConnCase's async teardown, waits for this test's own supervised children.
    # So what is pinned here is narrower and still worth pinning: that the
    # defect is exactly what the drain is load-bearing FOR. The producer tags
    # itself `sandbox_drain_timeout: 50` to force the drain's timeout branch, and
    # under that forcing the readings are byte-for-byte what they were before the
    # drain existed. Delete the tag and this assertion goes red, which is the
    # only reason to trust that the drain is doing the work.
    #
    # `drain_or_warn/1` remains shared-mode-only by design; it is the SCOPED
    # drain, not the unconditional one, that covers async. The audit row is still
    # lost in THIS construction, because this construction is the un-drained
    # case on purpose.
    #
    # What changed: `Platform.Telemetry.HandlerGuardian` re-attaches the handler
    # from inside `:telemetry`'s failure event, which fires after the detach and
    # before `execute/3` returns. So `after` now reads `true` — and it reads
    # `true` whether the handler failed or never failed, which is why `after`
    # alone is a LIVENESS guard here and the `class` assertion above is the
    # discriminator: `{:exit, _}` is process-local, and only an exit escapes
    # `persist_or_skip/4` and makes `:telemetry` detach. The pair
    # `class == {:exit, _}` AND `after == true` is what says "detached, and
    # repaired before `execute/3` returned"; neither reading can drift in from
    # another module.
    #
    # This is the update the previous version of this comment asked for, with
    # its premise corrected. It said "if this assertion ever fails, the async
    # hole has CLOSED". The assertion did start failing, and the hole is NOT
    # closed — the write is still destroyed. Only the blast radius shrank.
    assert reading.after == true,
           """
           #{@handler_id} was still DETACHED when `:telemetry.execute/3` returned to
           the queued orphan.

           The guardian is attached at boot and re-attaches from inside the
           `[:telemetry, :handler, :failure]` event, which `:telemetry` emits after
           the detach and before `execute/3` returns. Reading `false` here means the
           guardian did not run, ran too late, or has been driven past its bound
           (#{HandlerGuardian.restore_bound()} restores per handler id) earlier in
           this run.
           """

    # WHY THERE IS NO `restores_after == restores_before + 1` ASSERTION HERE.
    #
    # Same reason as the DRAINED case above and the LATE case above: the delta is
    # read off ONE BEAM-global `:counters` array in `:persistent_term`, keyed by
    # handler id and nothing else, while `async: true` modules run concurrently.
    # A BEAM-global counter cannot answer a per-case question in a concurrent
    # suite — and this direction of the assertion is confounded BOTH ways: an
    # unrelated module's detach inflates it past 1, and this case's own orphans
    # exit ASYNCHRONOUSLY (`Sandbox.stop_owner/1` returns before the
    # `{:shutdown, %DBConnection.ConnectionError{}}` exits propagate), so its own
    # detach can land outside its own sampling window and read 0. The header's
    # old defence — "confound-free because this is the ONLY case in this module
    # that detaches" — was scoped to this MODULE and the suite is not this
    # module.
    #
    # Stage 3 reached this for DRAINED and fixed one of the three sites; CI then
    # falsified LATE's. All three are the same measurement problem, so all three
    # are now decided on the process-local `class` reading. Here that is
    # `{:exit, reason}` above, with `reason` naming the owner's exit: it is the
    # only class that escapes `persist_or_skip/4`, so it is exactly the condition
    # under which `:telemetry` detaches — and `after == true` plus `restored ==
    # true` below then say the repair landed. That chain is entirely
    # process-local.
    #
    # Restoring the count as a check needs emission-scoped attribution from the
    # guardian (restores of a handler id CAUSED BY THIS PROCESS'S emission). That
    # API does not exist and no stage owns it. This removal is the orchestrator's
    # call on task 01a08b49, made against stage 3's authored intent, and it
    # deletes an instrument that was measuring another process — not a check.

    assert reading.restored == true, "the orphan did not restore #{@handler_id}"

    assert handler_attached?(),
           "#{@handler_id} is not attached now — the restore chain failed and every " <>
             "later test would record no audit events"
  end

  defp handler_attached? do
    @event |> :telemetry.list_handlers() |> Enum.any?(&(&1.id == @handler_id))
  end

  defp await(key), do: do_await(key, System.monotonic_time(:millisecond) + @report_deadline_ms)

  defp do_await(key, deadline) do
    case :persistent_term.get({@observation_key, key}, :ABSENT) do
      :ABSENT ->
        flunk("""
        No reading recorded for #{inspect(key)}.

        PlatformWeb.ConnCaseSupervisedOrphanBeyondDrainTest must run in the SAME BEAM as this
        module — it is what produces the readings. Run the whole file, not this
        module alone.
        """)

      :never_ran ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("orphan for #{inspect(key)} never reported within #{@report_deadline_ms}ms")
        else
          Process.sleep(10)
          do_await(key, deadline)
        end

      value ->
        value
    end
  end
end
