defmodule Platform.Federation.DeadLetterReplay do
  @moduledoc """
  Delivers eligible dead-lettered fires when a runtime reconnects (task
  019fa56b-ca2d stage 3).

  Stage 1 made the loss durable and stage 2 made it rulable; this is the layer
  that actually stops it. A drain reads one runtime's `pending` ledger rows
  oldest-first, asks `DeadLetterPolicy.classify/1` about each, and either
  broadcasts it to `runtime:<runtime_id>` or moves it to a terminal
  disposition that records WHY it was declined. Nothing leaves this module
  uncounted.

  ## The loop guard is the load-bearing rule

  **This module never calls `DeadLetters.record/1`, and must never be changed
  to.** A failed replay that re-dead-lettered would mint a fresh row on every
  attempt and the queue would grow without bound — the delivery layer would
  become a generator of the exact loss it exists to drain. A failure instead
  reverts the row to `pending` and bumps `attempts`; after `max_attempts/0`
  delivery attempts the row is `abandoned`. This is also why the replay
  broadcast is written here rather than routed back through
  `AgentResponder.broadcast_system_event/3`: that function's offline branch
  records, so reusing it would reintroduce the loop through the back door.

  ## Claim, then deliver

  Each row is marked `replaying` BEFORE the presence re-check and the
  broadcast. The claim is what makes a concurrent drain (or a crash mid-flight)
  legible afterwards: a row stuck in `replaying` is a delivery that was
  started, which is a different fact from one never attempted.

  The re-check itself matters more than it looks. Presence is read at drain
  start, but a runtime that joined and immediately dropped is a real shape —
  the reconnect that triggered the drain is exactly when a flapping runtime is
  most likely to vanish. On an offline re-check the whole drain ABORTS rather
  than continuing: a runtime that just disappeared will not take the other 33
  either, and burning an attempt on each of them would abandon a queue that was
  never delivered.

  ## Thundering herd

  `@max_per_reconnect` deliveries per drain, `@spacing_ms` apart. The measured
  production case is 34 pending fires for one runtime in a single day; waking
  an agent 34 times in one instant is a self-inflicted outage. The overflow
  stays `pending` and drains on the next reconnect — bounded latency, never
  loss. Policy drops do NOT consume the delivery budget: they wake nobody, and
  spending the cap on rows that were never going to be sent would starve the
  ones that were.

  ## Deviation from the plan: no duplicate-collapse pass

  The plan specifies a step that collapses pending rows sharing a
  `{responsibility_key, subject_id}`, marking the losers `superseded_duplicate`.
  That step is unreachable as specified, and reaching it would be harmful:

    * For a NON-NULL `subject_id`, stage 1's partial unique index —
      `(runtime_id, responsibility_key, subject_id) WHERE disposition =
      'pending' AND subject_id IS NOT NULL` — already guarantees at most one
      pending row per key. The drain reads only pending rows, so it can never
      observe two. `DeadLetterReplayTest` pins this invariant directly, and
      `DeadLetters.record/1`'s `conflict_target` names the index by predicate,
      so dropping the index would fail loudly at the next write rather than
      silently re-enabling duplicates.
    * For a NULL `subject_id`, the rows the collapse WOULD reach are precisely
      the ones stage 1 deliberately excluded from that index so that "cron rows
      (no subject) must not collide with each other". Collapsing them would
      replace an informative `dropped_policy` / `stale_by_wall_clock` with a
      `superseded_duplicate` and lose one of the two facts.

  `superseded_duplicate` therefore stays in the closed vocabulary unwritten by
  this stage. If the partial index is ever relaxed, the collapse becomes both
  reachable and necessary — add it there, keyed on non-null subjects only.

  ## Deviation from the plan: no in-flight MapSet

  The plan calls for a `MapSet` of in-flight runtime_ids so two joins cannot
  double-drain. Drains run INLINE in this GenServer, so its serial mailbox
  already provides that mutual exclusion: the second cast cannot begin until
  the first returns, by which point the rows it would have drained are no
  longer `pending`. A MapSet on top would be state that is provably always
  empty at the moment it is read. `"a repeated schedule for the same runtime
  does not double-deliver"` pins the property the MapSet was meant to buy.

  Running inline also keeps every Repo call in one process, which is what lets
  a drain participate in a test's sandbox connection at all — a `Task`-spawned
  drain would have no ownership.

  ## Housekeeping timers

  Two, and separate on purpose. `:prune` runs every 6h and discharges the
  cleanup obligation stage 1's Ecto choice created. `:rollup` runs every 24h
  and logs `DeadLetters.rollup_line/0` — the standing operator surface that
  makes a drop visible without opening the admin page. Folding the rollup into
  the prune timer would put four copies of the same cumulative figures in
  journald every day, and a grep-based audit that double-counts is the class of
  mistake this whole task exists to correct.
  """
  use GenServer

  require Logger

  alias Platform.Federation.DeadLetterPolicy
  alias Platform.Federation.DeadLetters
  alias Platform.Federation.RuntimePresence

  # Deliveries per drain. Overflow stays pending for the next reconnect.
  @max_per_reconnect 25

  # Gap between deliveries within one drain.
  @spacing_ms 250

  # Delivery attempts before a row is abandoned. Only real DELIVERY failures
  # count; a policy drop is terminal on the first look and never retried.
  @max_attempts 3

  @prune_interval_ms :timer.hours(6)
  @prune_days 30

  # The standing operator surface (stage 4). A SEPARATE timer from the 6h
  # prune, deliberately: the line reports cumulative totals, and emitting it
  # four times a day would put four copies of the same figures in journald.
  # That is how a grep-based audit double-counts — which is the class of
  # mistake that produced this ticket.
  @rollup_interval_ms :timer.hours(24)

  # A full drain is 25 deliveries × 250ms, so the default 5s call timeout would
  # expire mid-drain and leave the caller believing it failed.
  @call_timeout :timer.minutes(2)

  @type summary :: %{
          delivered: non_neg_integer(),
          dropped: non_neg_integer(),
          abandoned: non_neg_integer(),
          remaining: non_neg_integer(),
          aborted: boolean()
        }

  # ── API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ask for a drain of one runtime's queue. Asynchronous ON PURPOSE.

  Called from `RuntimeChannel.join/3`, which must never block on a Repo read —
  a slow ledger query would delay every runtime's connect, and a failing one
  would fail the join outright for a runtime that has nothing wrong with it.
  """
  @spec schedule(String.t()) :: :ok
  def schedule(runtime_id) when is_binary(runtime_id) do
    GenServer.cast(__MODULE__, {:drain, runtime_id})
  end

  @doc """
  Drain synchronously and return the summary. Test seam.

  Options: `:spacing_ms` and `:max_per_reconnect` override the defaults so a
  test can exercise the cap without sleeping through it.
  """
  @spec replay_now(String.t(), keyword()) ::
          {:ok, summary() | %{skipped: :offline}} | {:error, term()}
  def replay_now(runtime_id, opts \\ []) when is_binary(runtime_id) do
    GenServer.call(__MODULE__, {:drain, runtime_id, opts}, @call_timeout)
  end

  @doc """
  How many drain REQUESTS this server has processed for a runtime.

  Counts requests, not deliveries, and counts them even when the drain
  short-circuits on an offline runtime — the question it answers is "did
  something call `schedule/1`?", which is what the retrack guard needs to rule
  on.
  """
  @spec drain_count(String.t()) :: non_neg_integer()
  def drain_count(runtime_id) when is_binary(runtime_id) do
    GenServer.call(__MODULE__, {:drain_count, runtime_id})
  end

  @doc "The default inter-delivery gap, in milliseconds."
  @spec spacing_ms() :: pos_integer()
  def spacing_ms, do: @spacing_ms

  @doc "The delivery cap for a single drain."
  @spec max_per_reconnect() :: pos_integer()
  def max_per_reconnect, do: @max_per_reconnect

  @doc "Delivery attempts allowed before a row is abandoned."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  # ── Server ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_prune()
    schedule_rollup()
    {:ok, %{drains: %{}}}
  end

  @impl true
  def handle_cast({:drain, runtime_id}, state) do
    {_result, state} = safe_drain(runtime_id, [], state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:drain, runtime_id, opts}, _from, state) do
    {result, state} = safe_drain(runtime_id, opts, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:drain_count, runtime_id}, _from, state) do
    {:reply, Map.get(state.drains, runtime_id, 0), state}
  end

  @impl true
  def handle_info(:prune, state) do
    case safely(fn -> DeadLetters.prune(days: @prune_days) end) do
      {:ok, {:ok, 0}} ->
        :ok

      {:ok, {:ok, count}} ->
        Logger.info(
          "[DeadLetterReplay] pruned #{count} terminal dead letters older than #{@prune_days}d"
        )

      {:error, reason} ->
        Logger.error("[DeadLetterReplay] prune failed: #{inspect(reason)}")
    end

    schedule_prune()
    {:noreply, state}
  end

  def handle_info(:rollup, state) do
    case safely(fn -> DeadLetters.rollup_line() end) do
      {:ok, line} -> Logger.info(line)
      {:error, reason} -> Logger.error("[DeadLetterReplay] rollup failed: #{inspect(reason)}")
    end

    schedule_rollup()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_interval_ms)

  defp schedule_rollup, do: Process.send_after(self(), :rollup, @rollup_interval_ms)

  # ── Drain ───────────────────────────────────────────────────────────

  # One runtime's failure must not take the replay server down for every other
  # runtime, so the drain is wrapped rather than allowed to crash the
  # GenServer. The error is logged and the request is still counted.
  defp safe_drain(runtime_id, opts, state) do
    state = update_in(state.drains, &Map.update(&1, runtime_id, 1, fn n -> n + 1 end))

    case safely(fn -> drain(runtime_id, opts) end) do
      {:ok, result} ->
        {{:ok, result}, state}

      {:error, reason} ->
        Logger.error("[DeadLetterReplay] drain failed for #{runtime_id}: #{inspect(reason)}")
        {{:error, reason}, state}
    end
  end

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp drain(runtime_id, opts) do
    # Presence first, and BEFORE any Repo work. Draining a runtime that is not
    # there cannot deliver anything, and doing it anyway would burn an attempt
    # on every queued row — two joins for a flapping runtime would abandon a
    # queue that was never sent.
    if RuntimePresence.online?(runtime_id) do
      spacing = Keyword.get(opts, :spacing_ms, @spacing_ms)
      cap = Keyword.get(opts, :max_per_reconnect, @max_per_reconnect)

      acc =
        runtime_id
        |> DeadLetters.pending_for_runtime()
        |> Enum.reduce_while(new_acc(), fn row, acc ->
          if acc.delivered >= cap do
            {:halt, acc}
          else
            process_row(row, runtime_id, spacing, acc)
          end
        end)

      remaining = length(DeadLetters.pending_for_runtime(runtime_id))
      summary = Map.put(acc, :remaining, remaining)

      :telemetry.execute(
        [:platform, :federation, :dead_letter, :drain],
        %{
          delivered: summary.delivered,
          dropped: summary.dropped,
          abandoned: summary.abandoned,
          remaining: remaining
        },
        %{runtime_id: runtime_id, aborted: summary.aborted}
      )

      if summary.delivered > 0 or summary.dropped > 0 or summary.abandoned > 0 do
        Logger.info(
          "[DeadLetterReplay] drained #{runtime_id}: delivered=#{summary.delivered} " <>
            "dropped=#{summary.dropped} abandoned=#{summary.abandoned} " <>
            "remaining=#{remaining} aborted=#{summary.aborted}"
        )
      end

      summary
    else
      %{skipped: :offline}
    end
  end

  defp new_acc, do: %{delivered: 0, dropped: 0, abandoned: 0, aborted: false}

  defp process_row(row, runtime_id, spacing, acc) do
    if (row.attempts || 0) >= @max_attempts do
      mark(row, "abandoned", reason: :max_attempts_exceeded)
      emit_disposition(row, "abandoned", :max_attempts_exceeded)
      {:cont, %{acc | abandoned: acc.abandoned + 1}}
    else
      case DeadLetterPolicy.classify(row) do
        {:drop, reason} ->
          # `disposition_for/1` owns the dropped_policy / dropped_stale split.
          # Re-deriving it here would put a closed list in two places, which is
          # how the two facts drift back into one.
          disposition = DeadLetterPolicy.disposition_for(reason)
          mark(row, disposition, reason: reason)
          emit_disposition(row, disposition, reason)
          {:cont, %{acc | dropped: acc.dropped + 1}}

        :replay ->
          deliver(row, runtime_id, spacing, acc)
      end
    end
  end

  defp deliver(row, runtime_id, spacing, acc) do
    if acc.delivered > 0 and spacing > 0, do: Process.sleep(spacing)

    claimed = claim(row)

    cond do
      not RuntimePresence.online?(runtime_id) ->
        revert(claimed, "runtime left presence before delivery")
        {:halt, %{acc | aborted: true}}

      envelope = DeadLetters.to_envelope(claimed) ->
        broadcast(claimed, runtime_id, envelope, acc)

      true ->
        # `classify/1` already refuses an unrebuildable payload; this is the
        # belt on those braces, because broadcasting `nil` would hand a runtime
        # a frame it cannot parse.
        mark(claimed, "dropped_policy", reason: :no_replayable_payload)
        emit_disposition(claimed, "dropped_policy", :no_replayable_payload)
        {:cont, %{acc | dropped: acc.dropped + 1}}
    end
  end

  defp broadcast(row, runtime_id, envelope, acc) do
    case PlatformWeb.Endpoint.broadcast("runtime:#{runtime_id}", "attention", envelope) do
      :ok ->
        # `reason` is deliberately NOT overwritten here. It records why the row
        # exists (`runtime_offline`), which stays true after a successful
        # replay; `disposition` already says what happened to it. Drops
        # overwrite it because their reason is the more specific fact and the
        # capture reason is invariant across every system_event row.
        mark(row, "replayed", bump_attempts: true)

        :telemetry.execute(
          [:platform, :federation, :dead_letter, :replayed],
          %{system_time: System.system_time()},
          %{
            runtime_id: runtime_id,
            responsibility_key: row.responsibility_key,
            trigger_kind: row.trigger_kind,
            subject_id: row.subject_id
          }
        )

        {:cont, %{acc | delivered: acc.delivered + 1}}

      {:error, reason} ->
        revert(row, "broadcast failed: #{inspect(reason)}")
        {:halt, %{acc | aborted: true}}
    end
  end

  defp claim(row) do
    case DeadLetters.mark(row, "replaying") do
      {:ok, claimed} -> claimed
      {:error, _changeset} -> row
    end
  end

  # NOT `DeadLetters.record/1`. See the moduledoc: re-recording on failure is
  # the unbounded-growth bug this whole stage is guarding against.
  defp revert(row, error) do
    mark(row, "pending", last_error: error, bump_attempts: true)

    Logger.warning(
      "[DeadLetterReplay] replay aborted for #{row.runtime_id} " <>
        "(#{row.responsibility_key}): #{error} — row returned to the queue"
    )
  end

  defp mark(row, disposition, opts) do
    case DeadLetters.mark(row, disposition, opts) do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.error(
          "[DeadLetterReplay] could not mark #{row.id} as #{disposition}: #{inspect(changeset.errors)}"
        )

        row
    end
  end

  defp emit_disposition(row, disposition, reason) do
    :telemetry.execute(
      [:platform, :federation, :dead_letter, :dropped],
      %{system_time: System.system_time()},
      %{
        runtime_id: row.runtime_id,
        responsibility_key: row.responsibility_key,
        trigger_kind: row.trigger_kind,
        disposition: disposition,
        reason: reason
      }
    )
  end
end
