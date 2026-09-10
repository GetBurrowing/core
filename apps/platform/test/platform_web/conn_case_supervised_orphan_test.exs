# Constructs — deliberately, not by observation — the timing-dependent half of
# the defect behind task 01a089ee, and measures it at the layer where the
# property actually lives: `:telemetry.list_handlers/1`.
#
# ## What is being built
#
# An `async: true` `PlatformWeb.ConnCase` test spawns work under
# `Platform.TaskSupervisor`. `Task.Supervisor.start_child/2` seeds the child's
# `:"$callers"` process-dictionary entry, and `DBConnection.Ownership.Manager`
# resolves an owner by walking that chain (`proxy_for/2`,
# `deps/db_connection/lib/db_connection/ownership/manager.ex:24-27`). That is
# why a properly supervised child reaches the sandbox connection at all, and it
# is the exact INVERSE of the bare-`spawn` family fixed by task 01a06638 /
# PR #965, which sets no `$callers`, never resolves an owner, and is invisible
# to `Platform.SandboxHelpers`' drain. The two must not be conflated.
#
# When such a child's synchronous `Platform.Audit` write is still in flight as
# the sandbox owner goes away, `DBConnection` delivers `{:shutdown,
# %DBConnection.ConnectionError{message: "owner #PID<...> exited"}}` as a
# process **exit**. `Platform.Audit.TelemetryHandler.persist_or_skip/4` rescues
# raises but deliberately refuses to `catch :exit` (its closing comment records
# why, and that refusal stands). The exit therefore escapes `handle_event/4`,
# and `:telemetry` responds to an exiting handler by DETACHING it — for the
# whole VM, permanently, for the rest of the run.
#
# ## The two shapes, and why both are here
#
# Measured on this branch. The parameterisation matters, so both are recorded
# rather than only the one that detonates:
#
#   * LATE (`@late_delay_ms` sleep, then write) — the child sleeps past the end
#     of the test and only then touches the Repo. By that point the owner is
#     gone and the ownership table no longer resolves the caller, so the write
#     raises `DBConnection.OwnershipError`, `persist_or_skip/4` RESCUES it, and
#     the handler stays attached. **This shape does not reproduce the defect**,
#     on either the pre-migration `Sandbox.checkout/1` tree or the
#     post-migration `Sandbox.start_owner!/2` one. Recorded because "a late
#     orphan detaches the handler" is the intuitive theory and it is false.
#
#   * QUEUED (write entered before the test ends, still parked in
#     `DBConnection.Holder.checkout` when the owner goes away) — this is the
#     shape that detonates, deterministically. It is also the shape the repo
#     already documents as the real one: `Platform.SandboxHelpers`' moduledoc
#     measures **10 011 supervised children still alive and queued for the
#     single sandbox connection** at the instant a test body returns. A
#     blocker child holds the connection so the orphan is PROVABLY queued at
#     teardown (`await_queued/2` waits for it to be parked inside
#     `DBConnection`), which is what turns a race into a construction.
#
# ## Measured at the defect, not the amplifier
#
# The pass/fail decision rests on `:telemetry.list_handlers/1` and the class of
# the failure that reaches the audit write. There is deliberately NO assertion
# anywhere in this file that counts audit rows or downstream test failures.
# Counting those measures the VM-wide detach CASCADE — one step removed — and
# reads as N defects rather than one: a single detach in this repo reddened
# seven unrelated audit tests and looked like seven bugs
# (`lib/platform/audit/telemetry_handler.ex`, the `transcription_failed`
# clause). `list_handlers` measures the defect; counting failures measures the
# amplifier. The one `{:exit, _}` / `{:raise, _}` classification below is not a
# count — it is the mechanism check that stops the right outcome being reached
# for the wrong reason.
#
# ## Why this file now forces the drain to TIME OUT
#
# Task 01a08b49 stage 2 added `Platform.SandboxHelpers.await_own_supervised_writes/2`
# and wired it into `PlatformWeb.ConnCase`'s `async: true` teardown, so the
# default behaviour of an async ConnCase test is now that its own supervised
# children are waited for before `Sandbox.stop_owner/1`. That REMOVES the orphan
# this file constructs, which is the fix — and it means the construction can no
# longer be built by default.
#
# `@tag sandbox_drain_timeout: 50` forces the drain's timeout
# branch, so the children are still in flight when the owner goes away and the
# defect is reproduced exactly as before stage 2. Two things follow, and both are
# measurements rather than assumptions:
#
#   * The readings below are UNCHANGED from the pre-drain tree — same `{:exit,
#     _}` class for QUEUED, same rescued `OwnershipError` for LATE, same detach
#     and same repair. That is the point: this file characterises the defect, and
#     the defect is still there when nothing waits.
#   * Without the tag, the QUEUED orphan's class changes to `{:raise,
#     DBConnection.ConnectionError, "…request was dropped from queue after
#     ~500ms…"}` — measured. The drain keeps the owner alive, but this file's
#     `@blocker_hold_ms` blocker monopolises the single sandbox connection for
#     3 s, which is longer than DBConnection's default queue budget
#     (`:queue_target` 50 ms / `:queue_interval` 1000 ms), so the orphan is
#     dropped from the queue before it is ever served. NOTE FOR ANY LATER
#     "DRAINED" CASE: it must not reuse a multi-second blocker, or the write it
#     expects to SUCCEED will be starved by the construction rather than served
#     by the drain, and the test will read as "the drain does not work".
#
# ## The two queued cases, and what separates them
#
# Task 01a08b49 stage 3 splits the queued shape in two. They are the SAME
# construction — a supervised orphan provably parked inside `DBConnection` at
# the moment the test body returns — and they differ in exactly one variable,
# whether the drain is given long enough to wait for it. That is what makes the
# pair a measurement of stage 2's drain rather than of two unrelated
# situations:
#
#   * QUEUED-BEYOND-DRAIN (`sandbox_drain_timeout: 50`) — the
#     drain gives up while the blocker still holds the connection, the owner
#     goes away under the in-flight write, and the readings are the pre-stage-2
#     ones. The audit row is LOST here, on purpose. The `Class=:exit` line IS
#     emitted in this case and is not a fault.
#   * QUEUED-DRAINED (`sandbox_drain_timeout: 2_000`) —
#     the drain waits, the write is served, the row is written, and
#     `:telemetry` never detaches anything.
#
# ### `after` cannot tell the cases apart, and neither can one instrument
#
# This is the whole reason the pair is worth having, and it is easy to get
# wrong. Since stage 1's `HandlerGuardian` repairs a detach from INSIDE
# `:telemetry.execute/3`, the `after` reading is `true` in ALL THREE cases:
# `true` because the handler never failed (drained, late), and `true` because it
# failed and was repaired within the same call (beyond-drain). A version of the
# drained case that asserted only `after == true` would therefore stay green
# with stage 2's ConnCase drain call DELETED, i.e. it would measure nothing.
# `after` is kept as a liveness guard and is nowhere the discriminator.
#
# Each case is decided by the reading that is LOCAL to it:
#
#     case                 discriminator                        what it proves
#     QUEUED-DRAINED       class `:inserted`                    the row survived
#     QUEUED-BEYOND-DRAIN  class `{:exit, "owner ... exited"}`  the detach was earned,
#                          + `after`/`restored` true            and was repaired
#     LATE                 class `{:raise, OwnershipError, _}`  rescued, never reached
#                                                               `:telemetry` at all
#
# Every discriminator is a PROCESS-LOCAL reading taken by the emitting orphan
# itself, and each can only hold for its own case: `:inserted` requires a live
# owner at the moment the queued write is served, `{:exit, _}` naming the owner
# is the only class that escapes `persist_or_skip/4` (and so the only one under
# which `:telemetry` detaches), and a rescued `OwnershipError` requires the
# ownership table to have already forgotten the caller.
#
# ### The restore-count delta is not usable in ANY of the three cases
#
# It was tried in all three and it is gone from all three. `HandlerGuardian`'s
# counter is ONE BEAM-global `:counters` array in `:persistent_term`, keyed by
# handler id and nothing else, and this suite runs `async: true` modules
# CONCURRENTLY — so a delta sampled around one emission can be moved by a detach
# in an unrelated module. A BEAM-GLOBAL COUNTER CANNOT ANSWER A PER-CASE QUESTION
# IN A CONCURRENT SUITE.
#
# The evidence, in the order it arrived:
#
#   * DRAINED — task 01a08b49 stage 3 asserted the delta, measured 10 seeds, and
#     removed it: green 4 of 10 and red 6 of 10, each red run reporting delta 1
#     while the SAME run's `class` read `:inserted`. With the beyond-drain
#     sibling skipped it was 10 of 10. The delta was measuring the sibling.
#   * LATE — CI then refuted the header's old excuse for LATE ("`@late_delay_ms`
#     puts its emission after the beyond-drain detach has been repaired"). With
#     `@late_delay_ms` 500 and `@drain_timeout_ms` 50, the queued orphan's detach
#     was observed 558 ms after the drain gave up, i.e. INSIDE LATE's sampling
#     window. LATE's delta belonged to the queued orphan, and the assertion's
#     message contradicted the same test's own `class` reading.
#   * BEYOND-DRAIN — removed with them, because its old defence ("the ONLY case
#     in this module that detaches") is scoped to this MODULE and the suite is
#     not this module; and its own orphans exit asynchronously, so its own detach
#     can also land outside its own window and read 0.
#
# So the same defect bit three sites in one file. The full argument is at each
# site. Re-adding any of them requires emission-scoped attribution from the
# guardian — restores of a handler id caused by the CALLING PROCESS'S emission.
# That API does not exist; do not substitute a wider timing margin for it.
#
# ### No assertion here reads the log
#
# The obvious extra check on the drained case is "no `Handler ... has failed
# and has been detached. Class=:exit` line". It is deliberately NOT asserted.
# Both cases run in one module and one BEAM, beyond-drain must emit that line
# by design, and a file-wide log grep cannot attribute a line to a case — so
# the check would either be false or would force the two halves of one
# measurement into two files. The `class` reading is strictly stronger and is
# process-local: `:telemetry` cannot have logged that line for an emission whose
# own write was `:inserted` or was rescued as a raise. (An earlier version of
# this paragraph made the same argument for the restore-count delta. The delta
# is NOT process-local, which is exactly why it is gone — see above.)
#
# ## Restoration is load-bearing
#
# Absent a repair the detach is VM-global and lasts the rest of the run, so this
# file would poison every test after it — precisely the failure it exists to
# characterise. Four restores, in order of who gets there first:
#
#   0. `Platform.Telemetry.HandlerGuardian`, attached at boot since task
#      01a08b49 stage 1, re-attaches the handler from inside `:telemetry`'s own
#      failure event — i.e. BEFORE `:telemetry.execute/3` returns to the orphan,
#      and before `:telemetry` logs the `Class=:exit` line. This is why the
#      `after` reading below is now `true` for both shapes, and why `after` is a
#      liveness guard rather than the discriminator — the per-case `class`
#      reading is (the restore-count delta was tried for this and is BEAM-global,
#      see above). The guardian does NOT save the write: the audit row is still
#      lost and the async hole this file characterises is still open;
#   1. the orphan re-attaches immediately after `:telemetry.execute/3` returns
#      (`TelemetryHandler.attach/0` is idempotent by contract, see its
#      `@doc`). Now redundant with 0 in the ordinary case, and kept because it
#      is the only restore that survives the guardian itself being detached or
#      driven past its bound;
#   2. this module's `setup_all` `on_exit` waits for the orphan's report and
#      re-attaches, which closes the window at the MODULE boundary — a
#      per-test `on_exit` cannot, because ConnCase's own `on_exit` (registered
#      first, therefore run last) is what kills the owner, so the detach has
#      not happened yet when a per-test `on_exit` runs;
#   3. the observation module below asserts the handler is attached LIVE and
#      re-attaches in its own `on_exit`.
#
# RESIDUAL, stated rather than hidden: between `:telemetry`'s internal detach
# and step 0 there is a window in which a concurrently scheduled async test
# could emit an audited event and find no listener. The guardian narrows that
# window from "the rest of the run" to the duration of one synchronous
# `execute/3` on the failure event; it does not remove it, and it cannot cover
# a process `:kill`ed between the detach and the failure event. The window is
# inherent to measuring the real handler id rather than a stand-in, and it is
# the same window the actual defect opens.
#
# ## Why the observation lives in a separate `async: false` module
#
# The detach happens during ConnCase's `on_exit`, after the test process is
# dead — there is no point inside the test body at which it can be observed.
# ExUnit runs every `async: true` module before it runs the synchronous ones,
# so an `async: false` module is guaranteed to see the finished record. It
# still polls with a deadline rather than assuming that ordering.

defmodule PlatformWeb.ConnCaseSupervisedOrphanTest do
  use PlatformWeb.ConnCase, async: true

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

  # Long enough that the blocker is still holding the connection when ConnCase
  # tears the owner down (teardown lands within milliseconds of the body
  # returning), so the orphan is queued rather than served.
  @blocker_hold_ms 3_000

  # Past the queued orphan's detach-and-restore, so the LATE shape's own `before`
  # reading (the handler is attached when it runs) is a clean measurement. It is
  # NOT a race guard for the restore counter: CI observed the queued orphan's
  # detach 558 ms after the drain gave up, i.e. inside this window, which is one
  # of the reasons the counter is no longer asserted anywhere in this file. Do
  # not widen this to chase a delta — see the LATE case's comment.
  @late_delay_ms 500

  @queue_deadline_ms 2_000
  @report_deadline_ms 10_000

  # THE RESIDENCY BUDGET, and it is the constant stage 3's DRAINED case was
  # built against the wrong side of. Read from the source, not inferred:
  # `DBConnection.Ownership.Proxy` — the SANDBOX checkout path, not
  # `ConnectionPool` — sets `timeout = queue_target * 2` and `interval =
  # queue_interval`, defaulting to `@queue_target` 50 and `@queue_interval`
  # 1_000 (`deps/db_connection/lib/db_connection/ownership/proxy.ex:10-11` and
  # `:32-33`). This repo overrides neither. Its `timeout/2` drops every queued
  # entry whose `sent + timeout < now` — so:
  #
  #   * a QUEUED request is droppable once it has been in the queue for 100 ms;
  #   * that is enforced from a poll scheduled every 1_000 ms (`start_poll/2`),
  #     so a request over budget survives only until the next sweep.
  #
  # Both halves matter, and together they explain why this case looked random.
  # The GUARANTEED-safe residency is 100 ms. Past 100 ms survival depends on
  # where the sweep phase happens to fall, which is not observable from a test.
  # That is why CI reported "dropped from queue after 980ms": 980 ms is when the
  # sweep noticed, NOT the budget that was blown. Reading the 980 as the budget
  # is what makes a 2_000 ms confirmation deadline look defensible.
  #
  # So: any confirmation that a request is PARKED must complete within 100 ms of
  # it entering the queue, or the confirmation outlives its own subject.
  # `@queue_deadline_ms` 2_000 is twenty times that — not a margin that wants
  # widening, but the wrong side of the relation. On an idle box the whole
  # confirm-and-release costs a few ms and passes; on a saturated runner it does
  # not, and CI run 34526135694 measured exactly that (two failures, one cause:
  # the observer's `class` read the starvation raise, and the producer's
  # `await_queued` read `:dead`).
  #
  # This bounds the ONLY interval that spends the budget: how long the FIRST
  # orphan to park waits for the LAST one. See `await_all_parked/1`.
  @parked_window_ms 100

  # How long the orphans may take to ENTER the queue after reporting themselves
  # one call away from the Repo. Deliberately generous, and deliberately NOT a
  # race margin: a request that has not entered the queue has no residency and
  # cannot be dropped, so nothing is at risk while this runs. Separating it from
  # `@parked_window_ms` is the point — the old shape had one 2_000 ms deadline
  # covering both, which is what let an unbounded arrival wait be charged
  # against a 100 ms residency budget.
  @arrival_deadline_ms 2_000

  # Small enough that ConnCase's scoped drain gives up while the blocker is
  # still holding the connection, which is what keeps the orphans in flight at
  # `stop_owner/1`. Not zero: the drain should be seen to RUN and report, not be
  # switched off.
  @drain_timeout_ms 50

  # QUEUED-DRAINED's deadline, comfortably above the time its blocker holds the
  # connection (which is milliseconds — it is released by message as soon as the
  # orphans are parked, not after a sleep). Deliberately a real number rather
  # than omitting the tag and inheriting the helper's 5_000 default: the two
  # cases should differ by a value that is visible in both of them.
  @drained_drain_timeout_ms 2_000

  # A releasable blocker must not be able to hang the suite if the test body
  # fails before releasing it. On expiry the drain simply times out and the
  # drained case goes RED, which is the correct reading for a construction that
  # broke.
  @blocker_safety_ms 10_000

  @observation_key {:conn_case_supervised_orphan, :observation}

  # Forces ConnCase's `async: true` scoped drain to time out — see the header
  # section "Why this file now forces the drain to TIME OUT". Removing this tag
  # does not make the test stricter, it dismantles the construction.
  @tag sandbox_drain_timeout: @drain_timeout_ms
  test "QUEUED-BEYOND-DRAIN: an orphan in flight when the drain gives up detaches the handler",
       %{conn: conn} do
    assert %Plug.Conn{} = conn

    # Positive control 1 — if the handler were already detached, every
    # `list_handlers` reading below would be meaningless.
    assert handler_attached?(),
           "#{@handler_id} must be attached before this test can measure anything"

    put_observation(:late, :never_ran)
    put_observation(:late_class, :never_ran)
    put_observation(:queued, :never_ran)
    put_observation(:queued_class, :never_ran)

    # ── LATE shape: sleeps past the end of the test, then writes ──
    spawn_emitter(:late, @late_delay_ms, nil)
    spawn_classifier(:late_class, @late_delay_ms)

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

    # ── QUEUED shape: in flight when the owner goes away ──
    blocker = start_blocker(@blocker_hold_ms)
    assert Process.alive?(blocker)

    emitter = spawn_emitter(:queued, 0, self())
    classifier = spawn_classifier(:queued_class, 0)

    assert_receive {:about_to_emit, ^emitter}, 5_000

    # Positive control 3 — the construction is a construction. Both orphans
    # are PARKED inside DBConnection, waiting for the connection the blocker
    # holds, at the moment this body returns. If this ever degrades to
    # `{:gave_up, _}` the file has stopped building the defect and is
    # measuring nothing, which is a finding and not something to loosen.
    assert await_queued(emitter) == :queued
    assert await_queued(classifier) == :queued
  end

  # The same construction as above with ONE variable changed: the drain is given
  # longer than the blocker holds the connection, so
  # `SandboxHelpers.await_own_supervised_writes/2` waits for this test's own
  # orphans instead of giving up on them. See the header section "The two queued
  # cases, and what separates them".
  @tag sandbox_drain_timeout: @drained_drain_timeout_ms
  test "QUEUED-DRAINED: an orphan the drain waits for completes its write",
       %{conn: conn} do
    assert %Plug.Conn{} = conn

    # Positive control 1, as above.
    assert handler_attached?(),
           "#{@handler_id} must be attached before this test can measure anything"

    put_observation(:drained, :never_ran)
    put_observation(:drained_class, :never_ran)

    # The blocker holds the connection AND owns the release, because confirming
    # the shape and releasing must not be two steps with two deadlines.
    #
    # Stage 2 MEASURED that a fixed multi-second hold starves the orphan on the
    # proxy's residency budget — the write is dropped from the queue and never
    # served, arriving as `{:raise, DBConnection.ConnectionError, "...dropped
    # from queue..."}` — so a "drained" case built on one fails for a reason
    # that has nothing to do with the drain. Stage 3 fixed that by releasing the
    # blocker on a MESSAGE instead of a sleep, and that part stands.
    #
    # What stage 3 did NOT fix, and CI run 34526135694 then found, is that the
    # TEST process was doing the confirming: `await_queued(emitter)`, then
    # `await_queued(classifier)`, then release. Three sequential steps under one
    # 2_000 ms deadline, against a 100 ms residency budget (`@parked_window_ms`)
    # — and the second confirmation could not even begin until the classifier
    # had been scheduled for the very first time, which is unbounded under load.
    # The emitter's residency was counting throughout. Under a saturated runner
    # the emitter was dropped before the release ever happened.
    #
    # So the confirmation now runs INSIDE the blocker, in the same process that
    # holds the connection, with the transaction's return being the release.
    # There is no message hop, no scheduling gap and no second deadline between
    # "provably parked" and "connection available".
    blocker = start_parked_watching_blocker()
    assert Process.alive?(blocker)

    emitter = spawn_emitter(:drained, 0, self())
    classifier = spawn_classifier(:drained_class, 0, self())

    # Both orphans are RUNNING and one call away from the Repo, and NEITHER has
    # entered the queue yet — so no residency is counting during this wait and
    # it may be as slow as the runner likes. Waiting here is what makes the
    # bounded window below start when the subjects are ready rather than when
    # this process got around to asking. The classifier reports too now; before,
    # only the emitter did, which is precisely why waiting on the classifier
    # happened inside the window instead of before it.
    assert_receive {:about_to_emit, ^emitter}, 5_000
    assert_receive {:about_to_emit, ^classifier}, 5_000

    # Hand both pids to the blocker. It confirms them parked and releases in the
    # same breath.
    send(blocker, {:watch, self(), [emitter, classifier]})

    # Positive control 3, UNCHANGED in what it proves: both orphans were seen
    # inside DBConnection while the connection was still held, so this is the
    # queued shape and not a write that simply had time to finish. Only the
    # observer moved — the blocker takes the reading instead of this process, so
    # that the reading and the release cannot drift apart. `{:gave_up, _}` or
    # `:dead` still mean the case has stopped constructing the shape and is
    # measuring nothing, which is a finding and not something to loosen.
    #
    # KNOWN LIMIT OF THIS CONTROL, measured rather than suspected, and NOT
    # introduced by the restructure — it is equally true of the version this
    # replaced, verified by running the mutation against both:
    #
    #   Mutation: make the blocker hold NO connection at all (swap its
    #   `Platform.Repo.transaction/1` for a plain function call). The
    #   construction then has no blocker, both orphans get the connection
    #   immediately and their writes simply succeed. Expected: this control goes
    #   red, because nothing was ever parked. Actual: the whole file stays GREEN
    #   (`5 tests, 0 failures`) on both this version and the stage-3 one.
    #
    # The reason is `do_await_queued/2`'s predicate: it asks whether the process
    # is anywhere inside `DBConnection`, which is true of a process actively
    # USING a connection as well as one parked waiting for one. So this control
    # proves "reached DBConnection while the blocker was nominally holding",
    # not "was blocked on a connection it could not get".
    #
    # That means DRAINED does not currently distinguish "the drain saved the
    # write" from "the write happened to land" as strongly as the header claims.
    # It is recorded here rather than fixed because narrowing the predicate (to
    # a parked `DBConnection.Holder.checkout` frame, say) changes what BOTH
    # queued cases assert and is a decision about what this file proves, not a
    # cleanup. Do not credit this control with more than the line above.
    #
    # Positive control 2 (a supervised child reaching the connection through
    # `$callers`) is NOT repeated here: this case's own `:inserted` outcome is a
    # strictly stronger version of it.
    assert_receive {:parked_verdict, ^blocker, verdict}, 10_000

    assert match?({:queued, _}, verdict),
           """
           The DRAINED construction did not put both orphans in the queued shape.
           Verdict: #{inspect(verdict, limit: 8)}

           `{:not_parked, pid, :dead}` means the orphan died before it could be
           seen parked — on a loaded runner that is the residency budget having
           already dropped its request, i.e. the construction destroyed itself.
           `{:not_parked, pid, {:gave_up, _}}` means it never reached
           DBConnection at all. Neither is grounds for widening a deadline;
           both mean this case measured nothing.
           """

    {:queued, spread_ms} = verdict

    # The one quantity that spends the residency budget: how long the first
    # orphan sat parked waiting for the second. Asserted separately from the
    # verdict because it fails for a DIFFERENT reason and wants a different
    # message — and because it fires BEFORE the observer's `class` assertion
    # would, turning "expected :inserted, got a starvation raise" into a named
    # construction failure instead of a confusing one.
    assert spread_ms <= @parked_window_ms,
           """
           Both orphans parked, but #{spread_ms} ms apart, which exceeds the
           #{@parked_window_ms} ms the proxy guarantees a queued request
           (`@parked_window_ms`). The first one to park has therefore already
           blown its residency budget and is droppable, so this run is measuring
           the construction and not the drain.

           Do NOT raise `@parked_window_ms` — it is read off
           `DBConnection.Ownership.Proxy`, not chosen. This means the two
           orphans are no longer entering the queue together; check that BOTH
           still report `:about_to_emit` before the window opens.
           """
  end

  setup_all do
    on_exit(fn ->
      # Runs after EVERY per-test teardown in this module, including
      # ConnCase's `stop_owner/1` — so the detach has already happened by the
      # time this runs, unlike a per-test `on_exit`.
      await_report(:queued, @report_deadline_ms)
      await_report(:drained, @report_deadline_ms)
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
  # then restores.
  defp spawn_emitter(key, delay_ms, notify) do
    {:ok, pid} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        if delay_ms > 0, do: Process.sleep(delay_ms)
        if notify, do: send(notify, {:about_to_emit, self()})

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
      end)

    pid
  end

  # Calls `Platform.Audit.record/1` directly — no telemetry — so the CLASS of
  # the failure arriving at the audit write is named rather than inferred. A
  # raise is rescued by `persist_or_skip/4`; an exit is not, and only an exit
  # can reach `:telemetry` and detach the handler.
  defp spawn_classifier(key, delay_ms, notify \\ nil) do
    {:ok, pid} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        if delay_ms > 0, do: Process.sleep(delay_ms)
        if notify, do: send(notify, {:about_to_emit, self()})

        outcome =
          try do
            case Platform.Audit.record(@audit_attrs) do
              {:ok, _event} -> :inserted
              {:error, changeset} -> {:changeset_error, inspect(changeset.errors)}
            end
          rescue
            error -> {:raise, error.__struct__, Exception.message(error)}
          catch
            :exit, reason -> {:exit, inspect(reason, limit: 8)}
          end

        put_observation(key, outcome)
      end)

    pid
  end

  # Holds the single sandbox connection from a supervised child, so anything
  # else that wants it queues. Rendezvous from INSIDE the transaction, so the
  # connection is provably held before the caller continues.
  defp start_blocker(hold_ms) do
    parent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        Platform.Repo.transaction(fn ->
          send(parent, {:holding, self()})
          Process.sleep(hold_ms)
        end)
      end)

    await_holding(pid)
  end

  # As `start_blocker/1`, but it holds the connection until it has SEEN the pids
  # it was given parked inside DBConnection, and then lets go — detection and
  # release being the same event in one process.
  #
  # Why not a blocker the test process releases (which is what this replaced):
  # QUEUED-DRAINED needs the hold to outlast the parked-ness confirmation, so
  # the shape is provably queued, AND to be over inside the proxy's 100 ms
  # residency budget, so the write is served rather than dropped. When the test
  # process does the confirming those are two steps with a message hop and an
  # independent deadline between them, and the budget is counting for the whole
  # of it. Moving the confirmation in here makes the interval structural: the
  # poll loop runs inside the transaction, and the transaction RETURNING is the
  # release, so nothing can be scheduled in between.
  #
  # `@blocker_safety_ms` exists only so a failure before the watch request
  # cannot wedge the run.
  defp start_parked_watching_blocker do
    parent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        {:ok, verdict} =
          Platform.Repo.transaction(fn ->
            send(parent, {:holding, self()})

            receive do
              {:watch, ^parent, pids} -> await_all_parked(pids)
            after
              @blocker_safety_ms -> {:never_asked_to_watch, @blocker_safety_ms}
            end
          end)

        # Reported AFTER the transaction returned, i.e. after the release, so
        # the cost of reporting is outside the window. The verdict is still a
        # reading taken while the connection was held — that is what makes it
        # the "provably parked" control and not a guess after the fact.
        send(parent, {:parked_verdict, self(), verdict})
      end)

    await_holding(pid)
  end

  # Every pid parked inside DBConnection, plus the SPREAD between the first and
  # last to get there. Two bounds, measuring two different things:
  #
  #   * `@arrival_deadline_ms` — how long they may take to enter the queue at
  #     all. Nothing is at risk during this; an unqueued request has no
  #     residency. Generous on purpose.
  #   * the returned spread, checked by the caller against `@parked_window_ms` —
  #     how long the first one to park waits for the last. This is the ONLY
  #     interval that spends the residency budget, and the old shape left it
  #     unbounded.
  #
  # Returning the spread rather than asserting it here keeps the mechanism in
  # the helper and the judgement at the call site, where the failure message can
  # say which of the two things went wrong.
  defp await_all_parked(pids) do
    deadline = System.monotonic_time(:millisecond) + @arrival_deadline_ms

    Enum.reduce_while(pids, [], fn pid, stamps ->
      case do_await_queued(pid, deadline) do
        :queued -> {:cont, [System.monotonic_time(:millisecond) | stamps]}
        other -> {:halt, {:not_parked, pid, other}}
      end
    end)
    |> case do
      {:not_parked, _pid, _why} = failure -> failure
      stamps when is_list(stamps) -> {:queued, Enum.max(stamps) - Enum.min(stamps)}
    end
  end

  # Rendezvous from INSIDE the transaction, so the connection is provably held
  # before the caller continues.
  defp await_holding(pid) do
    receive do
      {:holding, ^pid} -> :ok
    after
      5_000 -> flunk("blocker never acquired the sandbox connection")
    end

    pid
  end

  defp await_queued(pid, deadline_ms \\ @queue_deadline_ms) do
    do_await_queued(pid, System.monotonic_time(:millisecond) + deadline_ms)
  end

  defp do_await_queued(pid, deadline) do
    case Process.info(pid, :current_stacktrace) do
      nil ->
        :dead

      {:current_stacktrace, stacktrace} ->
        rendered = inspect(stacktrace)

        cond do
          String.contains?(rendered, "DBConnection") ->
            :queued

          System.monotonic_time(:millisecond) > deadline ->
            {:gave_up, rendered}

          true ->
            # Yield, and this is a correctness fix rather than a margin. The
            # loop used to spin with no sleep at all, calling `Process.info/2`,
            # `inspect/1` and `String.contains?/2` as fast as a scheduler would
            # allow — so on a saturated runner it competed with, and therefore
            # DELAYED, the very processes it was waiting to see parked. The
            # instrument was generating the latency it then charged to the
            # residency budget. 1 ms of detection lag against a 100 ms budget is
            # noise; the contention was not.
            Process.sleep(1)
            do_await_queued(pid, deadline)
        end
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

defmodule PlatformWeb.ConnCaseSupervisedOrphanObservationTest do
  @moduledoc """
  Asserts the readings taken by the orphans in
  `PlatformWeb.ConnCaseSupervisedOrphanTest`.

  `async: false` on purpose: ExUnit runs every asynchronous module before any
  synchronous one, so this module cannot start until the producer's teardown —
  and therefore the detach — has finished. It still polls with a deadline
  rather than resting on that ordering.
  """
  use ExUnit.Case, async: false

  alias Platform.Audit.TelemetryHandler
  alias Platform.Telemetry.HandlerGuardian

  @event [:platform, :auth, :login]
  @handler_id "platform-audit-telemetry"
  @observation_key {:conn_case_supervised_orphan, :observation}
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
        [:late, :late_class, :queued, :queued_class, :drained, :drained_class],
        &:persistent_term.erase({@observation_key, &1})
      )
    end)

    :ok
  end

  test "a LATE supervised orphan raises OwnershipError and leaves the handler attached" do
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
    # MEASURED, in CI, not reasoned: `@late_delay_ms` is 500 and
    # `@drain_timeout_ms` is 50, and the queued orphan's detach was observed
    # arriving 558 ms AFTER the drain gave up — i.e. inside the window this case
    # samples across. The delta LATE read belonged to the QUEUED orphan. The
    # deleted assertion's own failure message therefore made a FALSE ATTRIBUTION:
    # it printed "the handler DID fail and was merely repaired ... never reaching
    # `:telemetry`'s catch at all" while, in the same run and the same test,
    # `class` read `{:raise, DBConnection.OwnershipError, _}`. Both cannot be
    # true — a raise is rescued by `persist_or_skip/4` and never reaches
    # `:telemetry`'s catch, so no detach and no restore can be attributed to this
    # emission at all. `class` is process-local and right; the counter was global
    # and wrong. The header's old claim that `@late_delay_ms` puts this emission
    # safely after the beyond-drain detach is what CI refuted; the 500 ms is kept
    # for the `before` reading, and is NOT a race guard.
    #
    # WHAT REMAINS IS THE INSTRUMENT. The `class` assertion above is process-local
    # and genuinely discriminating: it is what separates "the handler RAISED"
    # (rescued inside `persist_or_skip/4`, nothing detaches) from "the handler
    # EXITED" (`{:shutdown, %DBConnection.ConnectionError{}}`, which escapes the
    # rescue and makes `:telemetry` detach the handler VM-wide — the actual
    # defect). It is the same reading, in its LATE-specific form, that decides the
    # other two cases. Do not weaken it, and do not widen `@late_delay_ms` to dodge
    # the confound: that tunes a race instead of fixing a measurement, and CI has
    # already shown the timing is not under this test's control.
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

  test "QUEUED-DRAINED: the write completes and the handler never fails at all" do
    class = await(:drained_class)
    reading = await(:drained)

    assert class == :inserted,
           """
           Expected the queued orphan's audit write to COMPLETE once ConnCase's
           scoped drain waited for it.
           Got: #{inspect(class, limit: 8)}

           `{:exit, _}` means the owner still went away underneath the write:
           stage 2's `await_own_supervised_writes/2` did not wait, or is no longer
           called from ConnCase's async teardown. A `{:raise,
           DBConnection.ConnectionError, "...dropped from queue after ...ms..."}`
           is the OPPOSITE problem — the write was starved on DBConnection's queue
           budget rather than served, so the case is measuring its own blocker and
           not the drain; shorten the hold, do not relax this assertion. Neither
           reading is grounds for editing the expectation to match what was
           observed.
           """

    assert reading.before == true,
           "#{@handler_id} was not attached when the drained orphan ran, so its " <>
             "readings measure nothing"

    # `after == true` is a LIVENESS guard, not the discriminator: since stage 1
    # the guardian re-attaches from inside `[:telemetry, :handler, :failure]`, so
    # `after` reads `true` whether the handler never failed (this case) or failed
    # and was repaired inside the same `execute/3` (the beyond-drain case). It
    # would catch both remedies being down at once, and nothing finer.
    assert reading.after == true,
           "#{@handler_id} was detached and NOT repaired across the drained " <>
             "orphan's emission — with the write itself reported as #{inspect(class)}, " <>
             "the guardian is failing too, so both remedies are down at once"

    # WHY THERE IS NO `restores_after == restores_before` ASSERTION HERE, and it
    # is not an oversight — task 01a08b49 stage 3 wrote one, measured it, and
    # removed it.
    #
    # `HandlerGuardian`'s restore counter is BEAM-GLOBAL per handler id, and it
    # cannot attribute a detach to a particular emission. The BEYOND-DRAIN case
    # in this same module detaches the handler on purpose, and its orphans exit
    # ASYNCHRONOUSLY — `Sandbox.stop_owner/1` returns before the `{:shutdown,
    # %DBConnection.ConnectionError{}}` exits have propagated to them, so that
    # detach and its repair can land after that test's teardown has finished,
    # i.e. inside the window this test samples across. ExUnit shuffles test order
    # within a module by seed, so it depends on the seed.
    #
    # MEASURED, on this file, 10 seeds each: with the delta asserted here the
    # file was green 4 of 10 (seeds 1, 2, 5, 7) and red 6 of 10 with this test
    # reporting a delta of 1 while `class` read `:inserted` in the SAME run —
    # internally contradictory for a genuine drain failure, since both orphans
    # queue on one connection and die together. With the beyond-drain sibling
    # skipped, the delta assertion was green 10 of 10. The delta was measuring
    # the sibling, not this case.
    #
    # `class == :inserted` above is the discriminator instead, and it is strictly
    # better than the delta would have been even if attribution worked: it is
    # process-local, it names the outcome stage 2's drain exists to produce (the
    # row survives), and it goes red under mutation M1. The delta remains the
    # right instrument for the BEYOND-DRAIN case below, where the detach IS this
    # module's own and no sibling contributes one.

    assert reading.restored == true, "the orphan did not restore #{@handler_id}"

    assert handler_attached?(),
           "#{@handler_id} is not attached now — the restore chain failed and every " <>
             "later test would record no audit events"
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

        PlatformWeb.ConnCaseSupervisedOrphanTest must run in the SAME BEAM as this
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
