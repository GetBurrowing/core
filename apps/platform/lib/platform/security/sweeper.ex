defmodule Platform.Security.Sweeper do
  @moduledoc """
  Periodic sweep GenServer for the `security_guard` responsibility
  bundle (task `019f3e8e-4406` stage 2, ADR-0043).

  Every `check_interval_ms` the Sweeper walks the four `security.*`
  responsibility keys and, for each one, decides whether to fire the
  matching scanner module. The load-bearing shape is:

    1. Look up the `%Responsibility{}` row for the key. If it's
       missing (registry not seeded, DB out of sync), log warn +
       skip that key.
    2. **Progressive-enhancement gate** — call
       `Platform.Roles.assignee_for(key)`. If the resolver returns
       `nil`, emit `[:platform, :responsibility, :unfilled]`
       telemetry (mirroring the Router's own unfilled-key event) and
       return. **NO scanner runs. NO tasks are filed. NO DB writes.**
       This is the ADR-0043 progressive-enhancement contract — the
       runtime shell exists but stays dormant until an operator
       pins an agent to `security_guard` in Control Center → Roles.
    3. If the resolver returns an `%Agent{}`, spawn a supervised
       task under `Platform.TaskSupervisor` (via
       `Task.Supervisor.async_nolink/2` so a raising scanner never
       kills the sweeper) that invokes `run_scan/2` on the mapped
       scanner module for that key. Emit
       `[:platform, :security, :sweep_tick]` telemetry with the key,
       the assigned? flag, and the findings count.

  Router is deliberately NOT in the picture — the four security
  responsibilities registered a null `event_topic` in stage 1 (see
  ADR-0043 §Rationale) precisely so the Router's LLM-dispatch path
  never fires for them; this GenServer is the actual runtime.

  ## Cadence gate

  The stub `run_scan/2` bodies in stage 2 always return `{:ok, 0}`,
  so the tick body doesn't need cadence gating to stay quiet — but
  stages 3+ will hit real filesystems and OSV.dev. The Sweeper reads
  `metadata["cadence"]` (5-field cron) from each responsibility row
  and gates real scanner invocations on whether the cron next-fire
  time is in the past. Stage 2 lands the gate machinery even
  though the stubs are cheap so stages 3+ don't need to touch the
  tick loop.

  ## Test seam

  `start_link/1` opts forward to `init/1` so tests can pass
  `check_interval_ms: 100` to make the tick loop cheap. `:name` is
  extracted from opts so per-case DataCase tests can start multiple
  sweepers side-by-side without stepping on `__MODULE__`. The
  `:scanner_modules` opt / config key overrides the default
  `key → module` map so a test can inject a stub that records
  invocations or deliberately raises.

  ## Configuration

  ```elixir
  config :platform, Platform.Security.Sweeper,
    check_interval_ms: :timer.hours(1),
    scanner_modules: %{
      "security.cve_scan" => Platform.Security.Scanners.CveScan,
      "security.code_audit" => Platform.Security.Scanners.CodeAudit,
      "security.deploy_audit" => Platform.Security.Scanners.DeployAudit,
      "security.secret_leak" => Platform.Security.Scanners.SecretLeak
    }
  ```

  Boot gated on `:start_security_sweeper` (default `true`; disabled
  in `config/test.exs` — tests spin up per-case instances with
  their own `:name`).
  """

  use GenServer

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Cron
  alias Platform.Roles
  alias Platform.Security
  alias Platform.Security.Scanners

  @default_check_interval_ms :timer.hours(1)

  @default_scanner_modules %{
    "security.cve_scan" => Scanners.CveScan,
    "security.code_audit" => Scanners.CodeAudit,
    "security.deploy_audit" => Scanners.DeployAudit,
    "security.secret_leak" => Scanners.SecretLeak
  }

  @unfilled_event [:platform, :responsibility, :unfilled]
  @sweep_tick_event [:platform, :security, :sweep_tick]

  # ── public API ────────────────────────────────────────────────────────

  @doc """
  Start the Sweeper GenServer. Options forward to `init/1`; the
  supported keys are:

    * `:name` — registered name (default `__MODULE__`)
    * `:check_interval_ms` — tick cadence in milliseconds (default
      `#{@default_check_interval_ms}`)
    * `:scanner_modules` — map of `responsibility_key → module`
      overriding the default four
    * `:respect_cadence` — when `true` (default), a scanner is only
      invoked when its `metadata["cadence"]` cron next-fire time is
      already in the past. Tests pass `false` so `sweep_now/1`
      always fires all four scanners.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Force a sweep to run now. Blocking — the caller waits for the
  synchronous walk of the four keys and gets back a list of
  per-key result maps (`%{key, assigned?, findings_filed,
  fired?}`).

  When `server` isn't running, returns
  `{:error, :sweeper_not_started}` so IEx callers get a legible
  message instead of a `:noproc` exit.
  """
  @spec sweep_now(GenServer.server()) :: {:ok, [map()]} | {:error, :sweeper_not_started}
  def sweep_now(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> {:error, :sweeper_not_started}
      _ -> GenServer.call(server, :sweep_now)
    end
  end

  @doc "Telemetry event fired when a key has no assigned agent."
  @spec unfilled_telemetry_event() :: [atom()]
  def unfilled_telemetry_event, do: @unfilled_event

  @doc "Telemetry event fired once per scanner key per tick."
  @spec tick_telemetry_event() :: [atom()]
  def tick_telemetry_event, do: @sweep_tick_event

  @doc """
  The default `responsibility_key → scanner module` dispatch table.

  Public because this table *is* the reason `security.*` has no
  `Platform.Responsibilities.Providers` entry: the Sweeper owns those
  keys, so the Router deliberately never resolves a provider for them
  (see `Platform.Responsibilities.Providers.retired/0`).

  `test/platform/responsibilities/provider_coverage_test.exs` asserts the
  exemption against this map rather than against a hardcoded skip list,
  so retiring a key from *here* turns the coverage test red instead of
  silently re-creating the black hole that task 019f9b28 exists to kill.

  Note this is the *default* — a Sweeper started with `:scanner_modules`
  overrides it for that instance only.
  """
  @spec default_scanner_modules() :: %{optional(String.t()) => module()}
  def default_scanner_modules, do: @default_scanner_modules

  # ── GenServer callbacks ───────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    config = Application.get_env(:platform, __MODULE__, [])

    check_interval_ms =
      Keyword.get(opts, :check_interval_ms) ||
        Keyword.get(config, :check_interval_ms, @default_check_interval_ms)

    scanner_modules =
      Keyword.get(opts, :scanner_modules) ||
        Keyword.get(config, :scanner_modules, @default_scanner_modules)

    respect_cadence = Keyword.get(opts, :respect_cadence, true)

    state = %{
      check_interval_ms: check_interval_ms,
      scanner_modules: scanner_modules,
      respect_cadence: respect_cadence
    }

    Logger.info(
      "[SecuritySweeper] started check_interval_ms=#{check_interval_ms} " <>
        "respect_cadence=#{respect_cadence}"
    )

    schedule_tick(check_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:sweep_now, _from, state) do
    # Force-fire ignores the cadence gate — tests + IEx handlers
    # exercising `sweep_now/0` expect every key to be walked.
    results = sweep(%{state | respect_cadence: false})
    {:reply, {:ok, results}, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    _results = sweep(state)
    schedule_tick(state.check_interval_ms)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # A supervised scanner task completed successfully. `async_nolink`
    # sends `{ref, result}` on completion and a `{:DOWN, ...}` on
    # crash; we demonitor + flush to avoid the paired {:DOWN, ...}
    # landing after the fact.
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    # A scanner task crashed under Platform.TaskSupervisor. The
    # supervisor's own logging picks up the raise; we log at warn so
    # operators grepping for `[SecuritySweeper]` see the isolation
    # actually kick in.
    Logger.warning(
      "[SecuritySweeper] scanner task crashed reason=#{inspect(reason)} — sweeper survives"
    )

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_other, state), do: {:noreply, state}

  # ── internals ────────────────────────────────────────────────────────

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  # Walk the four security.* keys in ADR-0043 roster order and
  # return one result map per key so callers can assert against the
  # walk shape (tests + IEx handlers).
  defp sweep(state) do
    Enum.map(Security.list_responsibility_keys(), fn key -> sweep_key(key, state) end)
  end

  defp sweep_key(key, state) do
    scanner_modules = state.scanner_modules

    case Responsibilities.get_by_key(key) do
      nil ->
        Logger.warning(
          "[SecuritySweeper] responsibility row missing for key=#{key} — skipping " <>
            "(has the stage-1 seed migration run?)"
        )

        %{key: key, assigned?: false, findings_filed: 0, fired?: false, reason: :no_row}

      responsibility ->
        cond do
          state.respect_cadence and not cadence_due?(responsibility) ->
            %{key: key, assigned?: nil, findings_filed: 0, fired?: false, reason: :not_due}

          true ->
            drive_key(key, responsibility, scanner_modules)
        end
    end
  end

  # Progressive-enhancement gate — the load-bearing contract for
  # stage 2. When `assignee_for/1` returns nil, we emit unfilled
  # telemetry + log + return WITHOUT invoking the scanner module.
  defp drive_key(key, responsibility, scanner_modules) do
    case safe_assignee_for(key) do
      %Agent{} = agent ->
        fire_scanner(key, responsibility, agent, scanner_modules)

      nil ->
        :telemetry.execute(
          @unfilled_event,
          %{count: 1},
          %{key: key, responsibility_id: responsibility.id}
        )

        Logger.info("[SecuritySweeper] unfilled responsibility=#{key}")

        %{key: key, assigned?: false, findings_filed: 0, fired?: false, reason: :unfilled}
    end
  end

  defp fire_scanner(key, responsibility, agent, scanner_modules) do
    module = Map.get(scanner_modules, key)

    if is_nil(module) do
      Logger.warning("[SecuritySweeper] no scanner module mapped for key=#{key} — skipping")

      %{key: key, assigned?: true, findings_filed: 0, fired?: false, reason: :no_scanner_module}
    else
      trigger_meta = %{
        scanned_at: DateTime.utc_now(),
        agent_slug: Map.get(agent, :slug),
        agent_id: Map.get(agent, :id)
      }

      findings_filed = run_supervised(module, responsibility, trigger_meta, key)

      :telemetry.execute(
        @sweep_tick_event,
        %{findings_filed: findings_filed},
        %{
          key: key,
          responsibility_id: responsibility.id,
          scanner: module,
          assigned?: true
        }
      )

      %{key: key, assigned?: true, findings_filed: findings_filed, fired?: true, reason: :fired}
    end
  end

  # Invoke `run_scan/2` under `Task.Supervisor` and wait synchronously
  # for the result. `async_nolink/2` sends the outcome message back
  # to the sweeper — but we also want the per-key findings count
  # inline for the `sweep/1` return map, so we `Task.yield/2` for a
  # short window and fall back to counting 0 (+ warn) on timeout.
  #
  # Crash isolation: `async_nolink` means an exception in the
  # scanner arrives here as an exit tuple via `Task.yield/2`. We
  # rescue + log so a bad scanner doesn't propagate up into the
  # Sweeper's tick handler. `Process.demonitor/2` flushes both the
  # completion `{ref, _}` and the paired `{:DOWN, ref, ...}` out of
  # the sweeper's mailbox so `handle_info/2` doesn't see stale
  # messages after the yield returns.
  defp run_supervised(module, responsibility, trigger_meta, key) do
    task =
      Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
        module.run_scan(responsibility, trigger_meta)
      end)

    outcome = Task.yield(task, scanner_timeout_ms()) || Task.shutdown(task, :brutal_kill)
    Process.demonitor(task.ref, [:flush])

    case outcome do
      {:ok, {:ok, count}} when is_integer(count) ->
        count

      {:ok, other} ->
        Logger.warning(
          "[SecuritySweeper] scanner #{inspect(module)} for key=#{key} returned " <>
            "unexpected shape #{inspect(other)} — counting 0 findings"
        )

        0

      {:exit, reason} ->
        Logger.error(
          "[SecuritySweeper] scanner #{inspect(module)} for key=#{key} exited " <>
            "reason=#{inspect(reason)} — sweeper survives"
        )

        0

      nil ->
        Logger.error(
          "[SecuritySweeper] scanner #{inspect(module)} for key=#{key} timed out " <>
            "after #{scanner_timeout_ms()}ms — killed"
        )

        0
    end
  rescue
    error ->
      Logger.error(
        "[SecuritySweeper] scanner supervision raised for key=#{key}: " <>
          Exception.message(error)
      )

      0
  end

  # Cadence gate — only fire when the row's `metadata["cadence"]`
  # cron expression's next-fire time is in the past. Missing cadence
  # falls through to "always fire" so a misseeded row is legible in
  # telemetry rather than silently blocked. Bad cadence parses log
  # warn + fire (same conservative bias).
  defp cadence_due?(responsibility) do
    case get_meta(responsibility, "cadence") do
      cadence when is_binary(cadence) and cadence != "" ->
        case Cron.parse(cadence) do
          {:ok, spec} ->
            # A responsibility whose cron is "next fire after
            # (now - 1 hour) is in the past" is due — cheap heuristic
            # that avoids threading the last-fire timestamp through
            # state for stage 2. Stage 3+ swaps this for a proper
            # "next_fire_after(last_fired_at, spec)" check once we
            # have somewhere to persist last_fired_at.
            reference_point = DateTime.utc_now() |> DateTime.add(-3600, :second)

            case Cron.next_fire_after(reference_point, spec) do
              {:ok, next} -> DateTime.compare(next, DateTime.utc_now()) != :gt
              _ -> true
            end

          {:error, reason} ->
            Logger.warning(
              "[SecuritySweeper] cadence parse failed for responsibility=#{responsibility.key} " <>
                "reason=#{inspect(reason)} — firing anyway"
            )

            true
        end

      _ ->
        true
    end
  end

  defp get_meta(%{metadata: meta}, key) when is_map(meta), do: Map.get(meta, key)
  defp get_meta(_, _), do: nil

  defp safe_assignee_for(key) do
    Roles.assignee_for(key)
  rescue
    error ->
      Logger.error(
        "[SecuritySweeper] assignee_for/1 raised for key=#{key}: " <>
          Exception.message(error)
      )

      nil
  end

  defp scanner_timeout_ms do
    Application.get_env(:platform, __MODULE__, [])
    |> Keyword.get(:scanner_timeout_ms, :timer.seconds(60))
  end
end
