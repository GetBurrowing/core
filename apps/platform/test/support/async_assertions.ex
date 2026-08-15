defmodule Platform.AsyncAssertions do
  @moduledoc """
  Synchronisation primitives for tests that observe state owned by *another*
  process: the tier-1 mailbox barrier `sync_router/2`, and the tier-3 polling
  assertions `assert_eventually/3` / `eventually/3`.

  ## Why this exists

  A `Process.sleep/1` used as a synchronisation barrier is a guess in both
  directions. Too short and the assertion races the process it is waiting on —
  which is how a suite acquires failures whose identity changes run to run.
  Too long and it hides a real regression behind wall-clock padding, while
  taxing every future run for the privilege.

  Prefer, in this order:

    1. **A synchronous call to the process under test.** A pure
       `GenServer.call/3` is answered strictly after every message already in
       that process's mailbox has been handled, so it is a *complete* mailbox
       barrier — a happens-before proof, not a probability.
       `Platform.Orchestration.TaskRouterWatcher.sync/0` and
       `Platform.Orchestration.TaskRouter.current_status/1` are both this.
       `sync_router/2` — this module — is the named form of the latter, for
       the call sites that want the barrier and not the reply.
    2. **`assert_receive/2`** when the effect you want is a message.
    3. **`assert_eventually/3`** — this module — when neither is available
       because a *third* process owns the effect, or because the observable is
       derived bookkeeping (a `Registry` entry, an ETS row, a DB row written by
       someone else) that is updated independently of the event you can
       observe.

  Reach for (3) last. It is genuinely weaker evidence than (1) or (2), and a
  poll with a generous timeout that is never observed to bite is the same class
  of false confidence as the sleep it replaced.

  ## The case polling is actually *required* for

  A `{:DOWN, ...}` message means the process died. It does **not** mean every
  registry, ETS table or supervisor bookkeeping keyed on that pid has caught
  up. `Registry` unregisters off its own independent monitor, so a registry
  entry routinely outlives the `:DOWN` you received by a scheduler hop.
  Asserting on derived state immediately after a death is itself a race — that
  one needs a poll, and no barrier substitutes for it.

  ## The failure message reports the last observed value

  On timeout this reports what the function actually returned on its final
  attempt, plus the elapsed time and poll count. A timeout that says only
  "expected truthy" tells the next debugger nothing: they cannot distinguish
  "the condition never became true" from "the condition was never *evaluated*
  correctly" without re-instrumenting the test by hand.

  There is a real limit to that, and it is worth stating rather than pretending
  otherwise: a function that returns a **bare boolean** can only ever report
  `false`, which is no more informative than the sleep it replaced. The fix is
  a call-site idiom, not more machinery — **poll for the observation, assert on
  its shape**:

      # Weak: the timeout can only say `false`.
      assert_eventually(fn ->
        lease = LeaseManager.get(task_id)
        lease != nil and lease.status == :active
      end)

      # Strong: the timeout says "the row never appeared", and if it appears in
      # the wrong shape ExUnit's own assertion diffs it for you.
      lease = assert_eventually(fn -> LeaseManager.get(task_id) end)
      assert lease.status == :active

  Returning the truthy value is what makes that split possible, so it is part
  of the contract, not an incidental convenience.

  When even that is not enough — when the useful diagnosis is *domain* state
  this module cannot know about — use `eventually/3` and write the message
  yourself. `await_drop!/3` in
  `test/platform/orchestration/task_router_watcher_sandbox_isolation_test.exs`
  is the reference for that shape: it dumps the `Registry` entry and the lease
  row it can see into its own timeout message, so a regression names the damage
  instead of saying only "it didn't happen". `eventually/3` exists so that
  helper shape does not have to re-implement the polling loop.

  ## Exceptions are not swallowed

  If `fun` raises or exits, that propagates immediately rather than being
  retried until the deadline. Masking it would turn a real error into a
  timeout, and the timeout message would name a value the function never
  returned. Callers who genuinely expect a transient raise (e.g. polling a
  `GenServer.call/2` at a name that is not registered *yet*) should say so
  explicitly in the function body.

  ## Usage

      import Platform.AsyncAssertions   # already imported by Platform.DataCase

      assert_eventually(fn -> Repo.get(Task, id).status == "done" end)

      # The truthy value is returned, so it can be bound and asserted on:
      lease = assert_eventually(fn -> LeaseManager.get(task_id) end)
      assert lease.status == :active

      # `eventually/3` is the non-raising core, for helpers that want to
      # phrase their own failure message:
      case eventually(fn -> not router_running?(id) end, 5_000) do
        {:ok, _}          -> :ok
        {:timeout, last}  -> flunk("registry entry never cleared (last: \#{inspect(last)})")
      end
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @default_timeout 2_000
  @default_interval 10
  @default_barrier_timeout 5_000
  @dispatch_drain_interval 5

  @typedoc "Result of a non-raising poll: the truthy value, or the last falsy one."
  @type poll_result :: {:ok, term()} | {:timeout, term()}

  @doc """
  Block until the `Platform.Orchestration.TaskRouter` for `task_id` has drained
  every message the caller has already sent it. Returns `:ok`.

  This is the tier-1 primitive from the module doc, named so that intent
  survives review. **It is not redundant with the status assertions around it**
  and must not be "optimised away" — deleting it reinstates exactly the race a
  `Process.sleep/1` was papering over.

  ## Why a pure call is a complete barrier

  Three facts, verified against the tree this helper ships in, make
  `effect -> sync_router -> assert` a happens-before *proof* rather than a
  probability:

    1. **`Phoenix.PubSub.broadcast/4` dispatches to local subscribers in the
       calling process** (`deps/phoenix_pubsub/lib/phoenix/pubsub.ex`:
       `with :ok <- adapter.broadcast(...) do dispatch(...) end`). So by the
       time `Platform.Tasks.broadcast_board/1` returns *in the test process*,
       the message is already sitting in the router's mailbox — ahead of the
       `:current_status` call this helper sends next. Erlang guarantees message
       order between a given sender/receiver pair, so the router cannot answer
       the call before it has handled the broadcast.
    2. **`TaskRouter` spawns nothing.** The only `spawn`/`Task.start`/
       `Task.async` occurrence in `task_router.ex` is a string literal. Every
       side effect of a `handle_info/2` — the DB writes, the execution-space
       posts, the outbound broadcasts — completes *before* the process picks up
       the next message, and therefore before the call is answered.
    3. **`LeaseManager` mutators are synchronous `GenServer.call`s** and `get/1`
       is a direct `:ets.lookup`. An ETS row asserted after the barrier is
       already written.

  Fact 2 also covers the mailbox assertions. When the router broadcasts during
  a handler, the resulting message is sent router -> test *before* the call
  reply is sent router -> test. Same pair, so it is ahead of the reply in the
  test's mailbox, and `GenServer.call/3`'s selective receive takes the reply
  out from behind it. That is what makes a non-blocking `assert_received` /
  `refute_received` sound after this barrier — and a `refute_received` is
  precisely the assertion a too-short sleep turns silently vacuous.

  ## When this is NOT enough

  If the effect you are asserting on is owned by a *third* process — something
  the router only nudges, and which does its own bookkeeping off its own
  monitor — this barrier proves nothing about it. Use `assert_eventually/3`
  there, and name the other process in a comment at the call site. If you
  cannot name it, you wanted this.

  ## Failure reporting

  A barrier that dies uninformatively is as bad as a poll that does. This
  reports whether the router was ever registered, and what the exit was, rather
  than surfacing a bare `** (exit) ... :current_status` from deep inside
  `GenServer.call/3`.
  """
  @spec sync_router(String.t(), non_neg_integer()) :: :ok
  def sync_router(task_id, timeout \\ @default_barrier_timeout)
      when is_binary(task_id) and is_integer(timeout) and timeout > 0 do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] ->
        # `:current_status` is the pure query behind
        # `Platform.Orchestration.TaskRouter.current_status/1`; it reads state
        # and nothing else, so using it as a barrier has no side effect of its
        # own. Called against the pid directly rather than through the public
        # wrapper only so `timeout` is honourable.
        try do
          _ = GenServer.call(pid, :current_status, timeout)
          drain_dispatch(pid, task_id, System.monotonic_time(:millisecond) + timeout)
        catch
          :exit, reason ->
            flunk("""
            sync_router/2 could not reach the TaskRouter for task #{task_id}.

            The router was registered as #{inspect(pid)} when the barrier
            started, so it either stopped while handling the messages this
            barrier was waiting on, or it blocked past #{timeout}ms.

            Exit reason: #{inspect(reason, pretty: true, limit: 20)}
            """)
        end

      [] ->
        flunk("""
        sync_router/2 found no TaskRouter registered for task #{task_id}.

        Either the router was never started, or it has already stopped — in
        which case there is no mailbox left to drain and the barrier cannot
        establish the ordering the assertion after it depends on. Assert on the
        router's absence explicitly instead of syncing against it.
        """)
    end
  end

  # Task 01a00587. `:dispatch` no longer DOES anything: it arms a ~50ms
  # `:dispatch_now` timer and returns, so a plain mailbox barrier proves only
  # that the router has SCHEDULED the reconcile, not that it has run. That is a
  # strictly weaker claim than every call site here was written against.
  #
  # The timer ref in `state.dispatch_timer` is the observable for "a reconcile
  # is still owed": the router sets it when it arms the timer and clears it as
  # the FIRST thing `:dispatch_now` does, so `nil` observed through
  # `:sys.get_state/1` — itself a call, hence itself a complete mailbox barrier
  # — means no dispatch is pending AND the last one ran to completion (fact 2 of
  # the module doc: the router spawns nothing).
  #
  # The ordering that makes this sound is the same one the barrier above rests
  # on: whatever the caller did to provoke a dispatch is already in the router's
  # mailbox ahead of our call, so by the time we look, the timer is armed. We
  # then wait on the TIMER, not on the clock — a fixed sleep of the debounce
  # window would be a guess in both directions and is exactly what this file
  # exists to refuse.
  defp drain_dispatch(pid, task_id, deadline) do
    # `Map.get/3`, not `.dispatch_timer`: `sync_router/2` is also used against
    # stand-in routers (see this module's own test) whose state carries no such
    # key. A state with no dispatch timer owes no dispatch.
    if Map.get(:sys.get_state(pid), :dispatch_timer) == nil do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("""
        sync_router/2 waited past its timeout for task #{task_id} with a
        debounced dispatch still armed.

        `state.dispatch_timer` never returned to `nil`, so either the router is
        re-arming `:dispatch` faster than it drains it (the endpoint-not-ready
        retry inside `do_dispatch/2` is the usual suspect), or a `:dispatch_now`
        handler is blocked.
        """)
      else
        Process.sleep(@dispatch_drain_interval)
        drain_dispatch(pid, task_id, deadline)
      end
    end
  end

  @doc """
  Poll `fun` until it returns a truthy value, or fail the test.

  Returns the truthy value so it can be bound and asserted on further. Polls
  every `interval` ms (default #{@default_interval}) until `timeout` ms
  (default #{@default_timeout}) have elapsed.

  `fun` is always evaluated at least once, and immediately — a condition that
  is already true costs no wall clock at all.

  Fails with a message naming the last observed value, the elapsed time and the
  number of attempts.
  """
  @spec assert_eventually((-> term()), non_neg_integer(), pos_integer()) :: term()
  def assert_eventually(fun, timeout \\ @default_timeout, interval \\ @default_interval)
      when is_function(fun, 0) and is_integer(timeout) and timeout >= 0 and
             is_integer(interval) and interval > 0 do
    started = System.monotonic_time(:millisecond)

    case poll(fun, started + timeout, interval, 1) do
      {:ok, value} ->
        value

      {:timeout, last, attempts} ->
        elapsed = System.monotonic_time(:millisecond) - started

        flunk("""
        assert_eventually/3 timed out after #{elapsed}ms \
        (#{attempts} attempt(s), polling every #{interval}ms).

        Last observed value: #{inspect(last, pretty: true, limit: 20)}\
        #{bare_boolean_hint(last)}\
        """)
    end
  end

  # A predicate that collapses its observation to a bare boolean cannot report
  # WHY it was false, so the timeout above degenerates to "expected truthy" —
  # the same non-information as the sleep it replaced. Say so at the moment it
  # bites, when the person reading has the call site in front of them.
  defp bare_boolean_hint(last) when last in [false, nil] do
    """


    That value carries no diagnosis. Consider polling for the observation and
    asserting on its shape separately, so the timeout names what never arrived
    and ExUnit diffs the shape when it arrives wrong:

        row = assert_eventually(fn -> Repo.get(Thing, id) end)
        assert row.status == "done"\
    """
  end

  defp bare_boolean_hint(_last), do: ""

  @doc """
  Like `assert_eventually/3`, but returns `{:ok, value}` / `{:timeout, last}`
  instead of failing the test.

  For helpers that want to poll on the same terms but phrase their own failure
  message with domain context the generic one cannot carry.
  """
  @spec eventually((-> term()), non_neg_integer(), pos_integer()) :: poll_result()
  def eventually(fun, timeout \\ @default_timeout, interval \\ @default_interval)
      when is_function(fun, 0) and is_integer(timeout) and timeout >= 0 and
             is_integer(interval) and interval > 0 do
    case poll(fun, System.monotonic_time(:millisecond) + timeout, interval, 1) do
      {:ok, value} -> {:ok, value}
      {:timeout, last, _attempts} -> {:timeout, last}
    end
  end

  defp poll(fun, deadline, interval, attempts) do
    value = fun.()

    cond do
      value ->
        {:ok, value}

      System.monotonic_time(:millisecond) + interval > deadline ->
        {:timeout, value, attempts}

      true ->
        Process.sleep(interval)
        poll(fun, deadline, interval, attempts + 1)
    end
  end
end
