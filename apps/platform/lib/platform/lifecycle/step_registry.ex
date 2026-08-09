defmodule Platform.Lifecycle.StepRegistry do
  @moduledoc """
  Registry of lifecycle hook steps that a per-project pipeline may name
  in configuration (ADR-0046, task 019fe1b6 stage 1).

  This module holds *declarations only*. It maps a configured step name
  onto the `{module, function, 1}` that a later member of this stack will
  invoke. Nothing here runs a step.

  ## Why `Platform.Lifecycle` and not `Platform.Hooks`

  The namespace was chosen deliberately, not defaulted into. `Hooks`
  already means something else in this codebase, in three separate
  senses: the nine LiveView `on_mount` hook modules under
  `platform_web/live/chat/*_hooks.ex`, the `install_hooks` mix task
  (git hooks), and `webhook_router.ex`. A `Platform.Hooks.Registry`
  would also sit one letter away from the existing
  `Platform.Responsibilities.Registry`, which is a different thing with
  a different contract. `Lifecycle` collides with none of that and says
  what the concept is: configuration attached to phase boundaries.

  `Platform.Lifecycle` is distinct from its two neighbours:

    * `Platform.Orchestration` — task routing. Decides what happens next.
    * `Platform.Execution` — stage execution. Runs the work.
    * `Platform.Lifecycle` — *declared* phase-boundary configuration.
      Owns nothing that runs.

  ## Security: a step name is data, never code

  A step name arriving from project configuration is resolved by looking
  it up **in this registry and nowhere else**. `fetch/2` returns
  `{:error, :unknown_step}` for any name that was not registered, and
  there is no fallback branch — no "try it as a module", no default
  step, no passthrough.

  Specifically, callers must never `String.to_existing_atom/1` a module
  or function name out of configuration or task data, and must never
  `apply/3` a module/function derived from task data. Task descriptions
  and plan payloads in this system are agent-authored, so treating a
  name in them as a callable would be a direct arbitrary-code-execution
  path. The registry exists precisely so that the set of callable
  functions is fixed in source at compile time.

  ## Built-in steps

  `@built_in_steps` is the single source of truth for the shipped
  allowlist. It is seeded in `init/1`, and `built_in_steps/0` exposes it
  so a test can assert that `all/0` on a freshly started registry equals
  it. There is deliberately no second registration call at boot
  re-listing the same steps: this repo has a recorded failure where a
  built-ins list and a separate registration site drifted, leaving a
  step that was present in one and absent from the other silently dead.
  Boot only starts the process.

  The shipped list is kept small on purpose. Every entry is a function
  that the execution member of this stack must be able to call;
  speculative entries here are scope creep into that member.

  ## Webhook host allowlist

  `@allowed_webhook_hosts` ships **empty**. That is a deliberate choice,
  not an oversight: this repository is public, so no hostname belonging
  to a real deployment may appear in source. Hosts are supplied at
  runtime through `:lifecycle_allowed_webhook_hosts` application config,
  and tests inject their own with `Application.put_env/3`. The
  attribute-wrapped-in-`Application.get_env/3` shape mirrors
  `Platform.Orchestration.TaskRouter.design_step_timeout_ms/0`.

  With the default empty list, `webhook_host_allowed?/1` denies every
  host — fail-closed.

  ## Test seam

  `start_link/1` accepts a `:name` so tests can start a per-case
  instance and keep registry state isolated. The default singleton
  registers as `__MODULE__` and is boot-gated on
  `:start_lifecycle_step_registry` (defaults to `true`; disabled in
  `config/test.exs`).
  """

  use GenServer

  @type step_name :: binary()
  @type kind :: :deterministic
  @type entry :: %{name: step_name(), mfa: {module(), atom(), 1}, kind: kind()}

  # Shipped allowlist. Single source of truth — seeded in `init/1` and
  # exposed via `built_in_steps/0`. Keep this small; see moduledoc.
  @built_in_steps [
    %{name: "notify", mfa: {Platform.Lifecycle.Steps, :notify, 1}, kind: :deterministic}
  ]

  # Empty on purpose — public repo, no real hostnames in source. Runtime
  # config supplies the real list. See moduledoc.
  @allowed_webhook_hosts []

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
  Register a step entry. Idempotent on `:name` — registering the same
  name twice leaves one entry (the later registration wins), so a
  re-registration in dev doesn't pile up ghosts.
  """
  @spec register(entry(), GenServer.server()) :: :ok
  def register(entry, server \\ __MODULE__)

  def register(%{name: name, mfa: {mod, fun, 1}, kind: kind} = entry, server)
      when is_binary(name) and is_atom(mod) and is_atom(fun) and kind in [:deterministic] do
    GenServer.call(server, {:register, entry})
  end

  @doc """
  Look up a step by its configured name.

  Returns `{:error, :unknown_step}` for anything not registered. There
  is no fallback branch — see the security note in the moduledoc.
  """
  @spec fetch(step_name(), GenServer.server()) :: {:ok, entry()} | {:error, :unknown_step}
  def fetch(name, server \\ __MODULE__) when is_binary(name) do
    GenServer.call(server, {:fetch, name})
  end

  @doc "Return every registered entry, sorted by name."
  @spec all(GenServer.server()) :: [entry()]
  def all(server \\ __MODULE__), do: GenServer.call(server, :all)

  @doc "The compile-time shipped allowlist, sorted by name."
  @spec built_in_steps() :: [entry()]
  def built_in_steps, do: Enum.sort_by(@built_in_steps, & &1.name)

  @doc """
  Hosts a lifecycle webhook step may target. Runtime config wins;
  the compiled-in default is empty (fail-closed).
  """
  @spec allowed_webhook_hosts() :: [binary()]
  def allowed_webhook_hosts do
    Application.get_env(:platform, :lifecycle_allowed_webhook_hosts, @allowed_webhook_hosts)
  end

  @doc "The compiled-in default host allowlist, ignoring runtime config."
  @spec default_allowed_webhook_hosts() :: [binary()]
  def default_allowed_webhook_hosts, do: @allowed_webhook_hosts

  @doc "Whether `host` is in the allowlist. Denies anything not listed."
  @spec webhook_host_allowed?(term()) :: boolean()
  def webhook_host_allowed?(host) when is_binary(host) do
    host in allowed_webhook_hosts()
  end

  def webhook_host_allowed?(_host), do: false

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    steps = Map.new(@built_in_steps, &{&1.name, &1})
    {:ok, %{steps: steps}}
  end

  @impl GenServer
  def handle_call({:register, %{name: name} = entry}, _from, %{steps: steps} = state) do
    {:reply, :ok, %{state | steps: Map.put(steps, name, entry)}}
  end

  @impl GenServer
  def handle_call({:fetch, name}, _from, %{steps: steps} = state) do
    case Map.fetch(steps, name) do
      {:ok, entry} -> {:reply, {:ok, entry}, state}
      :error -> {:reply, {:error, :unknown_step}, state}
    end
  end

  @impl GenServer
  def handle_call(:all, _from, %{steps: steps} = state) do
    {:reply, steps |> Map.values() |> Enum.sort_by(& &1.name), state}
  end
end
