defmodule Platform.Telemetry.HandlerGuardian do
  @moduledoc """
  Re-attaches a boot-attached `:telemetry` handler that `:telemetry` has just
  detached because it failed, before `:telemetry.execute/3` returns to the
  emitter.

  ## The condition this exists for

  `:telemetry` responds to a handler that raises **or exits** by detaching it
  for the whole VM. In `deps/telemetry/src/telemetry.erl` (1.4.1),
  `do_execute/4` wraps the handler call in `try/catch` with no class filter, so
  an `exit` is caught exactly like a `raise`, and the catch body does three
  things in this order:

    1. `detach(HandlerId)`
    2. `execute([telemetry, handler, failure], Measurements, Metadata)` where
       the metadata carries `event_name`, `handler_id`, `handler_config`,
       `kind`, `reason` and `stacktrace`
    3. `?LOG_ERROR("Handler ~p has failed and has been detached. Class=~p ...")`

  Because step 1 precedes step 2, and step 2 is an ordinary synchronous
  `execute/3` running on the emitter's own stack, a handler attached to
  `[:telemetry, :handler, :failure]` can put the casualty back before control
  returns to whatever emitted the original event. That is the whole mechanism
  here. It is not a retry, a supervisor, or a queue.

  The shape that motivated it: an `async: true` test's **supervised** write is
  already enqueued inside `DBConnection` when the sandbox owner exits, so the
  connection is torn down under it and the insert arrives as a process exit
  carrying `{:shutdown, %DBConnection.ConnectionError{message: "owner #PID<..>
  exited"}}`. No `rescue` catches an exit, so it escapes
  `Platform.Audit.TelemetryHandler.handle_event/4` and `:telemetry` detaches
  `"platform-audit-telemetry"` — for the rest of the run. One destroyed write
  disables audit recording for every test that follows, which presents as many
  independent "expected an audit row, got none" defects rather than as one.

  Measured on task 01a089ee stages 3-4: the queued shape detached the handler
  10 times out of 10 attempts. The *late* shape — a child that reaches the
  connection after the owner is gone — is a different population: it raises
  `DBConnection.OwnershipError`, which `persist_or_skip/4` already rescues, so
  the handler survives (12 attempts, 0 detaches). "Handler raised" and "handler
  failed" are not the same set, and a remedy that only guards raises does not
  cover this one.

  ## What this does NOT do

  It does **not** save the write. The audit row is still lost. The
  `Class=:exit` line `:telemetry` logs in step 3 above is still printed — and
  because step 3 runs *after* step 2, that line appears while the handler is
  already re-attached, so its presence is not evidence the guardian failed.

  What it stops is one destroyed write disarming a boot handler for the
  remainder of the VM's life.

  ### Residual, stated rather than papered over

  It cannot cover a process `:kill`ed between the detach and the failure event:
  an untrappable exit at that instant means step 2 never runs and there is
  nothing to react to. It also cannot cover a handler detached by something
  other than a failure — see "Only failures" below, which is deliberate.

  "Permanently detached" was never a property of `:telemetry`; the detach is
  observable and repairable in-process. It was a property of this application,
  which had nothing listening on the failure event. This module is that
  listener.

  ## Only failures, and only known ids

  This handler fires on `[:telemetry, :handler, :failure]` only, so a test that
  deliberately calls a handler's `detach/0` is completely unaffected — no
  failure event is emitted for a voluntary detach.

  The id is looked up in `@boot_handlers`, an explicit compile-time map of the
  seven ids `Platform.Application.start/2` attaches to their modules. An id
  that is not in that map is left alone and `:ok` is returned. A guardian that
  restored *anything* that failed would resurrect test-owned handlers and
  third-party handlers whose owners detached them on purpose, and would make
  "this handler failed" unobservable.

  Restoring by calling the module's own `attach/0` is what makes the restore
  safe: that function is the single definition of the handler's id, event list
  and config, so the handler cannot come back under a drifted configuration.
  Every one of the seven is idempotent (`{:error, :already_exists}` normalised
  to `:ok`), verified individually, so restoring one that is somehow already
  attached is a no-op.

  ## Bounded

  Restores are counted per handler id and stop at `@restore_bound`. Past the
  bound the handler is left detached and that decision is logged once at
  `:error`. Unbounded self-healing would convert a handler that fails on every
  event — a genuine, permanent bug — into a hot loop that also hides itself,
  which is strictly worse than the detach it is repairing.

  The counters are an `:counters` array published in `:persistent_term` at
  `attach/0`, not process state: the failure event runs in whatever process
  emitted the original event, so the bound has to be shared across all of them
  and cannot live in a GenServer this handler would have to call into (a call
  can time out, and this handler must not fail — see below).

  ## This handler must never fail

  If the guardian itself raises or exits, `:telemetry` detaches *the guardian*,
  and from then on every detach goes unrepaired with no signal at all — a
  strictly worse state than not having it. So the body is wrapped in
  `try/rescue/catch`, logs, and returns `:ok` no matter what.
  """

  require Logger

  @handler_id "platform-telemetry-handler-guardian"
  @failure_event [:telemetry, :handler, :failure]

  # The seven handlers `Platform.Application.start/2` attaches at boot, keyed
  # by the `@handler_id` each one declares. Deliberately explicit: an id not
  # listed here is not restored.
  @boot_handlers %{
    "platform-audit-telemetry" => Platform.Audit.TelemetryHandler,
    "platform-vault-telemetry" => Platform.Vault.TelemetryHandler,
    "platform-chat-telemetry" => Platform.Chat.TelemetryHandler,
    "platform-meetings-telemetry" => Platform.Meetings.TelemetryHandler,
    "platform-meetings-intent-corrections" =>
      Platform.Meetings.IntentCorrections.TelemetryHandler,
    "platform-memory-telemetry" => Platform.Memory.TelemetryHandler,
    "external-admission-notifier" => Platform.Accounts.ExternalAdmissionNotifier
  }

  @handler_ids @boot_handlers |> Map.keys() |> Enum.sort()
  @counter_index @handler_ids |> Enum.with_index(1) |> Map.new()
  @restore_bound 5
  @counters_key {__MODULE__, :restore_counters}

  @doc """
  Attach the guardian to `[:telemetry, :handler, :failure]`.

  Idempotent, matching the contract every boot handler satisfies: a duplicate
  attach reports `{:error, :already_exists}`, which is normalised to `:ok`.

  Called FIRST in `Platform.Application.start/2`, ahead of the seven handlers
  it guards. The reason is a window argument, not a dispatch-order one:
  `:telemetry` only orders handlers against each other within a single event
  name, and no boot handler subscribes to the failure event, so relative
  position is irrelevant to dispatch. Going first simply means there is no
  interval during boot in which a handler is attached and unguarded. That
  interval is microseconds wide today and nothing emits inside it, so the cost
  of closing it is zero and the invariant becomes true by construction instead
  of by argument.
  """
  @spec attach() :: :ok
  def attach do
    _ = counters()

    case :telemetry.attach(@handler_id, @failure_event, &__MODULE__.handle_event/4, %{}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the guardian. Present for symmetry with the handlers it guards."
  @spec detach() :: :ok
  def detach, do: :telemetry.detach(@handler_id)

  @doc "This handler's `:telemetry` id."
  @spec handler_id() :: String.t()
  def handler_id, do: @handler_id

  @doc "The compile-time map of guarded boot handler ids to their modules."
  @spec boot_handlers() :: %{optional(String.t()) => module()}
  def boot_handlers, do: @boot_handlers

  @doc "Maximum restores per handler id before it is left detached."
  @spec restore_bound() :: pos_integer()
  def restore_bound, do: @restore_bound

  @doc """
  Restores recorded so far for `handler_id`.

  Reads the shared counter. An unguarded id always reads `0`.
  """
  @spec restore_count(String.t()) :: non_neg_integer()
  def restore_count(handler_id) do
    case Map.fetch(@counter_index, handler_id) do
      {:ok, index} -> :counters.get(counters(), index)
      :error -> 0
    end
  end

  @doc """
  Zero every restore counter.

  For tests, which drive the bound deliberately and must not inherit a
  neighbour's count, and for an operator who has fixed the underlying handler
  bug and wants the guard armed again without a restart.
  """
  @spec reset_restore_counts() :: :ok
  def reset_restore_counts do
    ref = counters()
    Enum.each(Map.values(@counter_index), &:counters.put(ref, &1, 0))
  end

  @doc """
  React to `:telemetry` having detached a handler that failed.

  Runs in whatever process emitted the event whose handler failed, on that
  process's stack, inside `:telemetry`'s own `catch`. Always returns `:ok`.
  """
  @spec handle_event(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          :telemetry.handler_config()
        ) :: :ok
  def handle_event(@failure_event, _measurements, metadata, _config) do
    restore(metadata)
  rescue
    error ->
      # Deliberately swallowed. Letting this escape would have :telemetry
      # detach the guardian, after which no later detach is repaired and
      # nothing says so.
      Logger.error(
        "[HandlerGuardian] restore attempt RAISED and was swallowed to keep the " <>
          "guardian attached: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "[HandlerGuardian] restore attempt threw #{inspect(kind)} and was swallowed " <>
          "to keep the guardian attached. Reason: #{inspect(reason)}"
      )

      :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp restore(metadata) do
    handler_id = Map.get(metadata, :handler_id)

    case Map.fetch(@boot_handlers, handler_id) do
      :error ->
        # Not one of ours. Someone else's handler failed, or a test's did.
        # Leaving it detached is the correct outcome.
        :ok

      {:ok, module} ->
        # `:counters.add/3` returns `:ok`, so the attempt number is a separate
        # read. Not atomic with the increment: two handlers failing genuinely
        # concurrently could read the same attempt number and both log. The
        # bound is still enforced (the counter itself only moves forward), and
        # a duplicated log line at `:error` is a far better failure than
        # serialising this path through a process that could time out.
        :ok = :counters.add(counters(), Map.fetch!(@counter_index, handler_id), 1)
        maybe_restore(handler_id, module, restore_count(handler_id), metadata)
    end
  end

  defp maybe_restore(handler_id, module, attempt, metadata) when attempt <= @restore_bound do
    Logger.error(
      "[HandlerGuardian] boot telemetry handler #{inspect(handler_id)} FAILED on " <>
        "#{inspect(Map.get(metadata, :event_name))} and was detached by :telemetry — " <>
        "kind=#{inspect(Map.get(metadata, :kind))} " <>
        "reason=#{inspect(Map.get(metadata, :reason))}. " <>
        "The write that failed is LOST and is not retried. Re-attaching via " <>
        "#{inspect(module)}.attach/0 so later events are still recorded " <>
        "(restore #{attempt} of #{@restore_bound})."
    )

    case module.attach() do
      :ok ->
        :ok

      other ->
        Logger.error(
          "[HandlerGuardian] #{inspect(module)}.attach/0 returned #{inspect(other)} — " <>
            "#{inspect(handler_id)} may still be detached."
        )

        :ok
    end
  end

  defp maybe_restore(handler_id, module, attempt, metadata)
       when attempt == @restore_bound + 1 do
    Logger.error(
      "[HandlerGuardian] boot telemetry handler #{inspect(handler_id)} has now failed " <>
        "#{attempt} times (bound #{@restore_bound}); latest on " <>
        "#{inspect(Map.get(metadata, :event_name))} " <>
        "kind=#{inspect(Map.get(metadata, :kind))} " <>
        "reason=#{inspect(Map.get(metadata, :reason))}. " <>
        "It is being LEFT DETACHED and #{inspect(module)} will record nothing further. " <>
        "Restoring past this bound would turn a handler that fails on every event into " <>
        "a hot loop that also hides itself. Fix the handler, then call " <>
        "#{inspect(__MODULE__)}.reset_restore_counts/0 and #{inspect(module)}.attach/0."
    )

    :ok
  end

  defp maybe_restore(_handler_id, _module, _attempt, _metadata), do: :ok

  # One `:counters` array, index per guarded handler id, published in
  # `:persistent_term`. Created in `attach/0` at boot; the lazy branch exists
  # only so `handle_event/4` can never crash on a missing term.
  defp counters do
    case :persistent_term.get(@counters_key, nil) do
      nil ->
        ref = :counters.new(map_size(@boot_handlers), [:write_concurrency])
        :persistent_term.put(@counters_key, ref)
        ref

      ref ->
        ref
    end
  end
end
