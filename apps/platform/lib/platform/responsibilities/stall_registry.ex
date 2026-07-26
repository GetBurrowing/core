defmodule Platform.Responsibilities.StallRegistry do
  @moduledoc """
  Registry of stall-sweep callbacks invoked by `Platform.Meetings.SummarizerSweeper`
  on each periodic tick (task 019f2566 stage 6).

  ## Why this exists

  Stage 2 shipped `SummarizerSweeper` as the single owner of the
  meetings.summarize stall-guard sweep. The follow-up ticket for the
  IntentClassify runtime (task `019f2452`) needs the same shape — a
  periodic walk over its own queue — but its queue is separate, its
  fallback path is different, and it has its own window.

  (Task 019f70b8 stage 3 narrowed what the intent runtime's callback
  does: its queue became per-meeting, and each queue arms its own ack
  timer, so stall DETECTION no longer lives in a periodic scan.
  `IntentDispatcher.sweep_stalled/0` is now a liveness re-drive for
  meetings whose enqueue notify was dropped. It still plugs in here,
  because "give me a tick" is exactly what the registry provides.)

  Rather than re-implement a second GenServer with the same periodic
  scaffolding, or wedge intent-classify-specific code into the
  summarizer sweeper, this registry lets any runtime plug its own
  `{module, function/0}` sweep callback into the same tick. The
  sweeper's `handle_info(:tick, ...)` walks
  `Platform.Responsibilities.StallRegistry.all/0` and calls each
  callback inside a `try/rescue`, so one raising callback doesn't take
  the sweep — or its siblings — down with it.

  ## Registration

  Callbacks are registered at boot from `Platform.Application.start/2`
  after the sweeper's child spec, and follow-up runtimes register from
  their own boot path. The registry deduplicates on `{module, function}`
  so a re-registration is idempotent — the sweeper is a singleton and
  we want the ability to hot-swap a callback in dev without piling up
  ghost entries.

  ## Contract for callbacks

    * Zero-arity — `{MyRuntime, :sweep_meetings_intent_classify}`
    * Return value is ignored — the sweeper does not care whether the
      callback found stalled work, only that it ran
    * Callbacks MAY raise; the sweeper logs + continues
    * Callbacks SHOULD complete inside the sweeper's tick interval —
      long-running work should spawn under `Platform.TaskSupervisor`,
      not block the sweep

  ## Test seam

  Tests can start their own registered instance under a per-case
  `:name` and pass that to `SummarizerSweeper` via `Application.put_env`
  or the sweeper's test-only opts. The default singleton is registered
  as `__MODULE__` and boot-gated on `:start_stall_registry` (defaults
  to `true`; disabled in `config/test.exs`).
  """

  use GenServer

  @type callback :: {module(), atom()}

  # ── public API ────────────────────────────────────────────────────────────

  @doc """
  Start the registry. Registers as `__MODULE__` unless `:name` is
  passed; tests pass per-case names to keep isolation.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a sweep callback. Idempotent — the same `{mod, fun}` pair
  registered twice appears once in `all/0`.
  """
  @spec register(callback(), GenServer.server()) :: :ok
  def register(callback, server \\ __MODULE__)

  def register({mod, fun} = callback, server) when is_atom(mod) and is_atom(fun) do
    GenServer.call(server, {:register, callback})
  end

  @doc "Return the current list of registered `{module, function}` callbacks."
  @spec all(GenServer.server()) :: [callback()]
  def all(server \\ __MODULE__), do: GenServer.call(server, :all)

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    {:ok, %{callbacks: MapSet.new()}}
  end

  @impl GenServer
  def handle_call({:register, callback}, _from, %{callbacks: callbacks} = state) do
    {:reply, :ok, %{state | callbacks: MapSet.put(callbacks, callback)}}
  end

  @impl GenServer
  def handle_call(:all, _from, %{callbacks: callbacks} = state) do
    {:reply, MapSet.to_list(callbacks), state}
  end
end
