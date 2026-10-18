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
#     teardown, which is what turns a race into a construction. "Parked" here
#     means exactly one thing, checked by `parked?/3`: the orphan is blocked in
#     `DBConnection.Holder.checkout_call/5` AND is an entry in the wait queue
#     of the `DBConnection.Ownership.Proxy` whose connection the blocker holds.
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
# ## WHERE QUEUED-BEYOND-DRAIN AND LATE WENT
#
# Task 01a08b49 stage 4 moved both to
# `test/platform_web/conn_case_supervised_orphan_beyond_drain_test.exs`, tagged
# `:isolated_beam` and run by their own `mix test` invocation in ci.yml — a
# separate BEAM. BEYOND-DRAIN detaches the VM-global audit handler on purpose and
# its orphans exit asynchronously after its own teardown, so its detach was
# landing inside THIS file's `handler_attached?()` positive control (CI run
# 34529749646). The sections below still describe all three shapes, because the
# characterisation is one piece of work; only the two cases moved. That file's
# header records why `async: false` is NOT an alternative.
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
# construction — a supervised orphan provably parked (`parked?/3`: waiting in
# the queue of the proxy the blocker holds) at the moment the test body returns — and they differ in exactly one variable,
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

  # QUEUED-DRAINED's deadline, comfortably above the time its blocker holds the
  # connection (which is milliseconds — it is released by message as soon as the
  # orphans are parked, not after a sleep). Deliberately a real number rather
  # than omitting the tag and inheriting the helper's 5_000 default: the two
  # cases should differ by a value that is visible in both of them.
  #
  # What this case detects is the drain CALL being present, not this deadline
  # being long. Measured on test-host (task 01a08d52-4b42 stage 1), on both this
  # branch and the origin/main it was cut from: with this constant set to 50
  # the file stays GREEN (branch 3 of 3, main 2 of 2), because the blocker
  # releases within milliseconds of the orphans parking and the writes finish
  # inside 50 ms anyway. With ConnCase's `drain_own_or_warn/2` call deleted it
  # goes RED on `class == :inserted` (2 of 2 on each). Do not cite a short
  # value here as a mutant this case kills.
  @drained_drain_timeout_ms 2_000

  # A releasable blocker must not be able to hang the suite if the test body
  # fails before releasing it. On expiry the drain simply times out and the
  # drained case goes RED, which is the correct reading for a construction that
  # broke.
  @blocker_safety_ms 10_000

  @observation_key {:conn_case_supervised_orphan, :observation}

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

    # Positive control 3. What it proves, and nothing wider: while the blocker
    # held the connection, EACH orphan was observed (a) blocked in
    # `DBConnection.Holder.checkout_call/5` and (b) present as an entry in the
    # wait queue of the `DBConnection.Ownership.Proxy` the blocker's own
    # checkout came from. That is the queued shape, and not a write that simply
    # had time to finish. The blocker takes the reading instead of this
    # process, so that the reading and the release cannot drift apart.
    # `{:gave_up, _}` or `:dead` mean the case has stopped constructing the
    # shape and is measuring nothing, which is a finding and not something to
    # loosen.
    #
    # Where it rests (db_connection 2.9.0, pinned in mix.lock): the proxy
    # serves a checkout at once when it has no client and enqueues it ONLY in
    # the `handle_info({:db_connection, from, {:checkout, ...}}, state)` clause
    # reached when some other client holds the connection (`:queue.in({now,
    # from}, queue)`, `lib/db_connection/ownership/proxy.ex:129-133`, after the
    # `client: nil` clause at :122-127). So (b) cannot hold for an uncontended
    # checkout, whatever the timing. (a) alone can — `checkout_call/5`
    # (`lib/db_connection/holder.ex:288-309`) is also the frame for the moment
    # between an uncontended request's `send` and the proxy's reply — which is
    # why it is a conjunction and (a) only rules out a stale queue entry.
    #
    # The mutation this control used to survive, and the readings on the
    # narrowed predicate (task 01a08d52-4b42 stage 1, test-host): make the blocker
    # hold NO connection (swap its `Platform.Repo.transaction/1` for a plain
    # call).
    #
    #   * Old predicate — "any frame containing `DBConnection`", which a
    #     process mid-query matches as readily as one waiting: whole file
    #     GREEN, `2 tests, 0 failures`.
    #   * Now: RED 5 of 5 at `await_holding/1`, on the lookup guard —
    #     `{:no_held_connection, nil, _}`, the blocker has no `%DBConnection{}`
    #     to take a proxy from.
    #   * With a proxy supplied anyway (a `Platform.Repo.checkout/1` released
    #     before the plain call, so the guard passes and the proxy has no
    #     client): RED 3 of 3 on THIS assertion, `{:not_parked, pid, :dead}` —
    #     the first orphan polled was served without queueing and had finished
    #     before (b) ever held. The same run with `parked?/3` forced to `true`
    #     is GREEN (2 of 2), so it is the predicate that fails it.
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
           `{:not_parked, pid, {:gave_up, %{current_function: _, queue_length: _}}}`
           means it was never seen both blocked in
           `DBConnection.Holder.checkout_call/5` and queued on the blocker's
           proxy — with `queue_length: 0` the blocker was not making anyone
           wait. `{:not_parked, pid, {:proxy_unreadable, _}}` means the proxy's
           state could not be read in the shape this file expects. None of
           these is grounds for widening a deadline; all mean this case
           measured nothing.
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
      await_report(:drained, @report_deadline_ms)

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
  defp spawn_classifier(key, delay_ms, notify) do
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

  # As `start_blocker/1`, but it holds the connection until it has SEEN the pids
  # it was given parked (`parked?/3`) on the proxy serving that connection, and
  # then lets go — detection and release being the same event in one process.
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
            # Taken from the connection THIS process holds, so the queue polled
            # below is the one a request for that connection has to wait in.
            lookup = held_connection_proxy()
            send(parent, {:holding, self(), lookup})

            case lookup do
              {:ok, proxy} ->
                receive do
                  {:watch, ^parent, pids} -> await_all_parked(pids, proxy)
                after
                  @blocker_safety_ms -> {:never_asked_to_watch, @blocker_safety_ms}
                end

              {:error, why} ->
                # `await_holding/1` has already flunked the test on this.
                {:proxy_lookup_failed, why}
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

  # Every pid parked (`parked?/3`) on `proxy`, plus the SPREAD between the first
  # and last to get there. Two bounds, measuring two different things:
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
  defp await_all_parked(pids, proxy) do
    deadline = System.monotonic_time(:millisecond) + @arrival_deadline_ms

    Enum.reduce_while(pids, [], fn pid, stamps ->
      case do_await_queued(pid, proxy, deadline) do
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
  # before the caller continues. Also where the proxy lookup's guard fails the
  # test: this runs in the TEST process, so a flunk here is the test's failure
  # and not a crashed child the test only notices as a timeout.
  defp await_holding(pid) do
    receive do
      {:holding, ^pid, {:ok, _proxy}} ->
        :ok

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

    pid
  end

  # The frame a process sits in while it waits for the proxy to hand it a
  # connection: the private `receive` in `DBConnection.Holder.checkout_call/5`
  # (db_connection 2.9.0 `lib/db_connection/holder.ex:288-309`).
  @parked_frame {DBConnection.Holder, :checkout_call, 5}

  # The `DBConnection.Ownership.Proxy` serving the connection the CALLING
  # process holds. Must be called from inside a checkout (here, the blocker's
  # `Platform.Repo.transaction/1`).
  #
  # Derivation, logged once on test-host before this was relied on (task
  # 01a08d52-4b42 stage 1): ecto_sql 3.13.5 keeps the checked-out
  # `%DBConnection{}` in the process dictionary under `{Ecto.Adapters.SQL,
  # adapter_meta.pid}` (`put_conn/2`, `lib/ecto/adapters/sql.ex:1499-1501`), and
  # its `pool_ref` record (`Record.defrecord(:pool_ref, [:pool, ...])`,
  # `lib/db_connection/holder.ex:12`) carries in `:pool` the process that handed
  # the connection over — under the sandbox, the proxy. Observed: `pool_ref`'s
  # pool alive, initial call `{DBConnection.Ownership.Proxy, :init, 1}`, its
  # state's `client` the blocker, and a queued orphan present in its `queue`.
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
  # entries (`:queue.in({now, from}, queue)` with `from = {self(), lock}` from
  # `checkout_call/5`). `:sys.get_state/1` is db_connection's internal state,
  # not an API; a shape change is reported, never read as an empty queue.
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
        [:drained, :drained_class],
        &:persistent_term.erase({@observation_key, &1})
      )
    end)

    :ok
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
