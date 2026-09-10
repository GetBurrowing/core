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
# ## Restoration is load-bearing
#
# The detach is VM-global and permanent for the rest of the run, so this file
# would poison every test after it — precisely the failure it exists to
# characterise. Three restores, in order of who gets there first:
#
#   1. the orphan re-attaches immediately after `:telemetry.execute/3` returns
#      (`TelemetryHandler.attach/0` is idempotent by contract, see its
#      `@doc`), which bounds the window to the time `:telemetry` spends
#      logging the detach;
#   2. this module's `setup_all` `on_exit` waits for the orphan's report and
#      re-attaches, which closes the window at the MODULE boundary — a
#      per-test `on_exit` cannot, because ConnCase's own `on_exit` (registered
#      first, therefore run last) is what kills the owner, so the detach has
#      not happened yet when a per-test `on_exit` runs;
#   3. the observation module below asserts the handler is attached LIVE and
#      re-attaches in its own `on_exit`.
#
# RESIDUAL, stated rather than hidden: between `:telemetry`'s internal detach
# and step 1 there is a sub-millisecond window in which a concurrently
# scheduled async test could emit an audited event and find no listener. That
# window is inherent to measuring the real handler id rather than a stand-in,
# and it is the same window the actual defect opens.
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

  # Comfortably past the queued orphan's detach-and-restore, so the LATE
  # shape's own `before` reading is a clean measurement.
  @late_delay_ms 500

  @queue_deadline_ms 2_000
  @report_deadline_ms 10_000

  @observation_key {:conn_case_supervised_orphan, :observation}

  test "a supervised orphan's in-flight audit write detaches the audit telemetry handler",
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

  setup_all do
    on_exit(fn ->
      # Runs after EVERY per-test teardown in this module, including
      # ConnCase's `stop_owner/1` — so the detach has already happened by the
      # time this runs, unlike a per-test `on_exit`.
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
  # then restores.
  defp spawn_emitter(key, delay_ms, notify) do
    {:ok, pid} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        if delay_ms > 0, do: Process.sleep(delay_ms)
        if notify, do: send(notify, {:about_to_emit, self()})

        before = handler_attached?()
        :telemetry.execute(@event, %{system_time: System.system_time()}, @audit_attrs)
        after_emit = handler_attached?()

        :ok = TelemetryHandler.attach()

        put_observation(key, %{
          before: before,
          after: after_emit,
          restored: handler_attached?()
        })
      end)

    pid
  end

  # Calls `Platform.Audit.record/1` directly — no telemetry — so the CLASS of
  # the failure arriving at the audit write is named rather than inferred. A
  # raise is rescued by `persist_or_skip/4`; an exit is not, and only an exit
  # can reach `:telemetry` and detach the handler.
  defp spawn_classifier(key, delay_ms) do
    {:ok, pid} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        if delay_ms > 0, do: Process.sleep(delay_ms)

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
          String.contains?(rendered, "DBConnection") -> :queued
          System.monotonic_time(:millisecond) > deadline -> {:gave_up, rendered}
          true -> do_await_queued(pid, deadline)
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
        [:late, :late_class, :queued, :queued_class],
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
  end

  test "a QUEUED supervised orphan exits and detaches the audit telemetry handler" do
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

    # THE measurement. This pins an OPEN residual, not a fixed property: the
    # ConnCase migration in stage 2 of task 01a089ee moved ownership to an
    # agent that outlives the test process and the whole on_exit chain, which
    # LENGTHENS the window before the connection dies but does not remove the
    # tear-down. `SandboxHelpers.drain_or_warn/1` is shared-mode-only by
    # design, so nothing waits for an `async: true` orphan before or after.
    # Measured identically on both trees.
    #
    # If this assertion ever fails, the async hole has CLOSED. That is good
    # news and this test is then the thing to update — not the fix.
    assert reading.after == false,
           """
           #{@handler_id} survived a queued supervised orphan's in-flight audit write.

           Either the async hole has been closed (in which case update this test and
           the notes, and delete the residual from them), or the construction stopped
           constructing — check the `await_queued/2` controls in the producer module,
           which assert both orphans were parked inside DBConnection at teardown.
           """

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
