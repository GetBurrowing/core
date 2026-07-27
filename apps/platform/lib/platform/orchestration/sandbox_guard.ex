defmodule Platform.Orchestration.SandboxGuard do
  @moduledoc """
  One reusable primitive for "this process may not own the Ecto sandbox
  connection the caller is on".

  ## The shape this exists to fix

  Globally-supervised singletons (`Platform.Orchestration.TaskRouterWatcher`,
  the audit telemetry handler, the lease sweeper) do work on behalf of *some
  other* process. In production that is unremarkable. Under
  `Ecto.Adapters.SQL.Sandbox` it is a correctness hazard in two directions:

    1. **The Repo call raises.** Under `async: true` — manual mode, since
       `Platform.DataCase` calls `Sandbox.start_owner!(Repo, shared: not
       tags[:async])` — the singleton is not in the sandbox owner chain of the
       test that triggered it unless something explicitly allowed it, so any
       `Repo` call raises
       `DBConnection.OwnershipError` — or, if the allowing test exited while
       the query was mid-flight, fails as a `DBConnection.ConnectionError`
       delivered as an `:exit` ("owner #PID<...> exited") which a `rescue`
       does not catch. Unguarded, the singleton crashes, its supervisor
       restarts it, and three restarts inside the intensity window take
       sibling `Platform.Repo` down with it — cascading "could not lookup
       Ecto repo Platform.Repo" across every subsequent `DataCase` setup.
       See `notes/2026-07-06-datacase-cascade-rootcause.md`.

    2. **The work succeeds and perturbs global state.** Worse, and quieter,
       and the case that makes hazard 1's mode qualifier load-bearing rather
       than pedantry: under `async: false` the sandbox is in shared mode, the
       singleton inherits the owner's connection, and nothing raises at all.
       `Platform.DataCase` allow-lists the watcher into *every* test, and
       `Sandbox.allow/3` binds it to whichever test won the race. So a
       broadcast from async test A can be evaluated by a singleton sitting on
       async test B's connection. Nothing raises; the singleton simply acts on
       a row it cannot see, writing ETS rows (`:orchestration_lease_manager`
       is `:named_table, :public`) and starting/stopping processes. ETS is not
       transactional — the sandbox rollback at end-of-test does not undo any
       of it.

  `DBConnection.OwnershipError` and "owner exited" are **sandbox-only**
  conditions: production uses a real pool, has no sandbox owner, and never
  produces either. Every degradation in this module therefore only ever fires
  under test, and production behaviour is unchanged.

  ## Why a module and not another inline rescue

  On `origin/main` @ b19eee64 `task_router_watcher.ex` already carried five
  hand-rolled copies of the same `rescue DBConnection.OwnershipError` +
  `catch :exit, _` pair — `boot_reconcile/0`, `resolve_runtime_for_task/1`,
  two inline blocks in the `:reconcile` handler, `redispatch_for_runtime/1`,
  and `safe_reconcile/0`. Each was added reactively after a different crash,
  and the gap this task fixes is exactly the one nobody thought to add a
  sixth copy for. A shared primitive makes the safe path the thing you reach
  for by default instead of something each future handler author has to
  rediscover.

  ## Telemetry is load-bearing, not decoration

  Every guarded degradation emits:

      :telemetry.execute(
        [:platform, :orchestration, :sandbox_guard, :dropped],
        %{count: 1},
        %{reason: :ownership_error | :owner_exited, caller: module, exit_reason: term | nil}
      )

  A test for a guard can otherwise only assert that *nothing happened*, which
  passes vacuously when the trigger never arrived — the precise failure mode
  that let this defect survive behind the "known TaskRouter flake" label. The
  telemetry event lets a test assert **positively** that the guard fired.

  ## API

    * `guarded/2,3` — run a fun, degrade to a fallback on either sandbox error
      shape, emit telemetry.
    * `connection_owned?/0` — can this process reach the Repo at all?
    * `sandbox_pool?/0` — is the Repo configured with the sandbox pool?
    * `row_visible?/2` — is the row this event is about visible on the
      connection *this* process can see?
    * `record_drop/3` — emit the same drop telemetry from a call site that
      checked a precondition itself and is declining to proceed.
  """

  require Logger

  alias Platform.Repo

  @dropped_event [:platform, :orchestration, :sandbox_guard, :dropped]

  @doc """
  The telemetry event emitted whenever a guarded call degrades.

  Exposed so callers and tests attach to a constant rather than
  copy-pasting the list literal.
  """
  @spec dropped_event() :: [atom()]
  def dropped_event, do: @dropped_event

  @doc """
  Emit the drop telemetry for a caller that decided, on its own, not to do
  work for a sandbox-ownership reason.

  `guarded/3` emits automatically when it *catches* an error. This is the
  other half: a call site that asked `connection_owned?/0` or `row_visible?/2`
  first and is declining to proceed has nothing to catch, so it records the
  drop itself. Without this the "checked the precondition and refused" path
  would be invisible, and a test for it could only assert that nothing
  happened — vacuous whenever the trigger never arrived.

  `extra` is merged UNDER the canonical `:reason` / `:caller` / `:exit_reason`
  keys, so a call site can attach the identifier of whatever it dropped (a
  task id, a runtime id) without being able to overwrite the fields every
  handler matches on. Attaching that identifier is what lets a test filter its
  own drops out of a shared, globally-attached telemetry stream.
  """
  @spec record_drop(atom(), module(), map()) :: :ok
  def record_drop(reason, caller, extra \\ %{})
      when is_atom(reason) and is_atom(caller) and is_map(extra) do
    emit_dropped(reason, caller, nil, extra)
  end

  @doc """
  Run `fun`, returning `on_unowned` if it fails with either sandbox-ownership
  error shape.

  Two shapes, two clauses, both required:

    * `DBConnection.OwnershipError` (a `raise`) — this process is not in the
      sandbox owner chain. Reachable under `async: true` (manual mode) only:
      in shared mode (`async: false`) the connection is inherited and the call
      succeeds instead, which is the quieter hazard the moduledoc describes.
    * `:exit` — the owning test exited while the query was in flight, so the
      connection was torn down under us and the failure arrives as an EXIT
      that `rescue` cannot see.

  Nothing else is caught. A `Postgrex.Error`, an `Ecto.Query.CastError`, or a
  `MatchError` inside `fun` still propagates — this is a sandbox guard, not a
  blanket `try`.

  ## Options

    * `:caller` — module recorded in the telemetry metadata. Defaults to the
      module in which `fun` was defined (`Function.info(fun, :module)`), so
      the attribution is correct without every call site having to remember
      to pass it.

  ## Note on the `:exit` clause

  `catch :exit, _` is deliberately broad, matching the five inline guards it
  replaces: the "owner exited" reason is not a stable, matchable term across
  DBConnection versions, and narrowing it risks silently reintroducing the
  crash cascade. The cost is that a non-sandbox exit (a `GenServer.call`
  timeout inside `fun`, say) would also degrade — so the raw reason is
  carried in the telemetry metadata as `:exit_reason` and logged at
  `:warning` when it does not look like a sandbox teardown. A swallowed exit
  is therefore still observable rather than silent.
  """
  @spec guarded((-> result), fallback, keyword()) :: result | fallback
        when result: term(), fallback: term()
  def guarded(fun, on_unowned, opts \\ []) when is_function(fun, 0) do
    fun.()
  rescue
    DBConnection.OwnershipError ->
      emit_dropped(:ownership_error, caller(fun, opts), nil)
      on_unowned
  catch
    :exit, reason ->
      unless sandbox_teardown_exit?(reason) do
        Logger.warning(
          "[SandboxGuard] degraded on a non-sandbox exit from " <>
            "#{inspect(caller(fun, opts))}: #{inspect(reason)}"
        )
      end

      emit_dropped(:owner_exited, caller(fun, opts), reason)
      on_unowned
  end

  @doc """
  True when this process can check a connection out of the Repo.

  Issues **no SQL** — `Repo.checkout/1` only resolves ownership and hands
  back a connection, so this is cheap enough to sit in front of every
  broadcast handler.

  Returns `true` immediately when the Repo is not on the sandbox pool. That
  short-circuit is what makes this genuinely inert in production rather than
  inert-by-argument: with a real pool the only way `checkout/1` can fail is
  pool exhaustion, and treating a transient pool timeout as "not owned" would
  silently drop live work. The condition this predicate exists to detect
  cannot occur off the sandbox pool, so we do not go looking for it there.
  """
  @spec connection_owned?() :: boolean()
  def connection_owned? do
    if sandbox_pool?() do
      guarded(fn -> Repo.checkout(fn -> true end) end, false, caller: __MODULE__)
    else
      true
    end
  end

  @doc """
  True when `Platform.Repo` is configured with the `Ecto.Adapters.SQL.Sandbox`
  pool — i.e. we are running under the test sandbox.

  Call sites use this to gate the test-only half of a precondition so it is
  structurally impossible for that half to alter production behaviour, rather
  than relying on an audit of every call site to prove it never fires.
  """
  @spec sandbox_pool?() :: boolean()
  def sandbox_pool? do
    Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox
  rescue
    # `Repo.config/0` raises if the Repo is not started (the tail end of the
    # cascade described above). "Cannot tell" resolves to "not the sandbox",
    # which keeps the sandbox-gated half of any precondition off.
    _ -> false
  end

  @doc """
  True when the row `id` of `queryable` is visible on the connection this
  process can currently see.

  This is the discriminator for "the event I am handling belongs to somebody
  else's sandbox connection". Each sandboxed test runs inside its own
  uncommitted transaction, so a row written by test A is invisible from test
  B's connection. A `false` from a handler processing a broadcast about that
  row therefore means: this event came from a connection I am not on, and
  acting on it would mutate global state on behalf of a test I cannot see.

  Degrades to `false` — "not visible" — via `guarded/3` when the Repo itself
  is unreachable, since a handler that cannot read the row is in no position
  to act on it either.
  """
  @spec row_visible?(module() | Ecto.Queryable.t(), term()) :: boolean()
  def row_visible?(_queryable, nil), do: false

  def row_visible?(queryable, id) do
    guarded(
      fn -> Repo.exists?(from_id(queryable, id)) end,
      false,
      caller: __MODULE__
    )
  end

  # ── Internals ──────────────────────────────────────────────────────────

  defp from_id(queryable, id) do
    import Ecto.Query, only: [where: 3]
    where(queryable, [r], r.id == ^id)
  end

  defp emit_dropped(reason, caller, exit_reason, extra \\ %{}) do
    :telemetry.execute(
      @dropped_event,
      %{count: 1},
      Map.merge(extra, %{reason: reason, caller: caller, exit_reason: exit_reason})
    )
  end

  # The caller module is derived from the closure itself: an anonymous
  # function carries the module it was defined in. That makes attribution
  # automatic — a call site cannot forget to pass it and get it wrong.
  defp caller(fun, opts) do
    case Keyword.fetch(opts, :caller) do
      {:ok, module} ->
        module

      :error ->
        case Function.info(fun, :module) do
          {:module, module} -> module
          _ -> :unknown
        end
    end
  end

  # Best-effort classification for the log line only; the guard degrades
  # either way. Covers the two shapes seen in practice: a DBConnection
  # error struct delivered as an exit reason, and the `{:shutdown, _}` /
  # `:noproc` shapes from a torn-down sandbox connection process.
  defp sandbox_teardown_exit?(%DBConnection.ConnectionError{}), do: true
  defp sandbox_teardown_exit?(:noproc), do: true
  defp sandbox_teardown_exit?(:shutdown), do: true
  defp sandbox_teardown_exit?({:shutdown, _}), do: true
  defp sandbox_teardown_exit?({reason, {_m, _f, _a}}), do: sandbox_teardown_exit?(reason)
  defp sandbox_teardown_exit?(_), do: false
end
