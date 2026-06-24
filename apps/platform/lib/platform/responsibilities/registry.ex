defmodule Platform.Responsibilities.Registry do
  @moduledoc """
  Boot-time owner of responsibility-provider registration (ADR-0041 M1
  stage 4).

  At startup the supervisor places this GenServer between
  `Platform.Repo` (which must be up so we can `upsert_by_key/1`) and the
  feature schedulers that will eventually read the table at runtime
  (`Platform.Agents.SystemEventScheduler`, the M6 router). On `init/1`
  the Registry reads the configured provider module list, asks
  `Platform.Responsibilities.register_all/1` to upsert every declared
  row, and stashes the result so operators can introspect it via
  `status/0`.

  ## Boot safety

  A misbehaving provider must **never** crash the supervisor. The
  underlying `register_all/1` already collects per-provider failures into
  its `:errors` bucket rather than raising; the Registry surfaces that
  list verbatim via `status/0` and logs one `Logger.error/1` per failed
  provider so operators see the problem in journald even when nobody is
  watching `status/0`. Successful providers log a single `Logger.info/1`
  with the row count.

  ## Configuration

      config :platform, Platform.Responsibilities,
        providers: [Some.Provider.Module, ...]

  The configured list defaults to `[]` — until M6 wires real providers
  in, the Registry boots clean against an empty table. The supervisor
  reads the boot flag `:start_responsibilities_registry` to decide
  whether to start this process at all; tests disable it and start
  per-case instances with their own registered name.

  ## Public API

  All three runtime helpers (`reload/0`, `providers/0`, `status/0`)
  `GenServer.call` into the named process. They are convenience
  forwarders only — there is no caching layer between them and the
  GenServer state. `reload/0` re-runs `register_all/1` against the
  currently configured provider list, refreshes `:last_results`, and
  returns the new result map so an operator running a `rpc` from
  `iex --remsh` can see what changed.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Responsibilities

  @typedoc "Aggregated result of the last `register_all/1` invocation."
  @type results :: %{
          ok: [Responsibilities.Responsibility.t()],
          errors: [{module(), term()}]
        }

  @typedoc "Internal state."
  @type state :: %{providers: [module()], last_results: results()}

  # ── start_link / init ──────────────────────────────────────────────────────

  @doc """
  Start the Registry under a supervisor.

  Accepts the standard child-spec opts map. Recognised keys:

    * `:name` — override the registered name (defaults to `__MODULE__`).
      Tests use this to spin up per-case instances without colliding
      with any app-supervisor copy.
    * `:providers` — explicit provider module list. When omitted the
      Registry falls back to
      `Application.get_env(:platform, Platform.Responsibilities, [])[:providers]`,
      itself defaulting to `[]`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    providers =
      Keyword.get_lazy(opts, :providers, fn ->
        Application.get_env(:platform, Platform.Responsibilities, [])
        |> Keyword.get(:providers, [])
      end)

    results = do_register(providers)

    {:ok, %{providers: providers, last_results: results}}
  end

  # ── public convenience ────────────────────────────────────────────────────

  @doc """
  Re-run `register_all/1` against the currently configured provider list,
  refresh internal state, and return the new result map.
  """
  @spec reload(GenServer.server()) :: results()
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload)

  @doc "Return the provider module list this Registry was started with."
  @spec providers(GenServer.server()) :: [module()]
  def providers(server \\ __MODULE__), do: GenServer.call(server, :providers)

  @doc "Return the last `register_all/1` result map."
  @spec status(GenServer.server()) :: results()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Stamp `last_successful_fire_at` on an agent after a responsibility
  fired through that agent (ADR-0041 M6 stage 2).

  Direct `Repo.update_all` keyed on agent id so we bypass the
  `Agent.changeset/2` `validate_required([:slug, :name, :status])`
  guard for per-row observability updates (mirrors the pattern
  documented in `Platform.Agents.Agent` moduledoc).

  Returns the input agent (with its in-memory `last_successful_fire_at`
  patched) so callers can pipe.
  """
  @spec stamp_last_successful_fire(Agent.t(), DateTime.t()) :: Agent.t()
  def stamp_last_successful_fire(%Agent{id: id} = agent, %DateTime{} = fired_at)
      when not is_nil(id) do
    {1, _} =
      from(a in Agent, where: a.id == ^id)
      |> Repo.update_all(set: [last_successful_fire_at: fired_at, updated_at: DateTime.utc_now()])

    %{agent | last_successful_fire_at: fired_at}
  end

  # ── handle_call ───────────────────────────────────────────────────────────

  @impl true
  def handle_call(:reload, _from, state) do
    results = do_register(state.providers)
    {:reply, results, %{state | last_results: results}}
  end

  @impl true
  def handle_call(:providers, _from, state) do
    {:reply, state.providers, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.last_results, state}
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # Run register_all and log one line per provider. We rely on
  # register_all/1 being boot-safe (collects errors, never raises), so
  # there is no defensive try/rescue around it here.
  @spec do_register([module()]) :: results()
  defp do_register(providers) do
    {:ok, %{ok: oks, errors: errors} = results} =
      Responsibilities.register_all(providers)

    log_successes(providers, oks, errors)
    log_failures(errors)

    results
  end

  # Group successful rows by provider so each module gets exactly one
  # info log with its row count. Providers that ended up entirely in
  # :errors are skipped here and surfaced by log_failures/1 instead.
  defp log_successes(providers, oks, errors) do
    failed_mods = errors |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    # Bucket OK rows by which provider declared them. We can't read the
    # provider back off a %Responsibility{}, but feature+key form a
    # 1:1 link to the declaring module's register/0 output, so the
    # simplest accurate accounting is: ask each non-failing provider how
    # many keys it declared and use that count.
    Enum.each(providers, fn mod ->
      cond do
        MapSet.member?(failed_mods, mod) ->
          :ok

        true ->
          count = count_rows_for(mod, oks)

          if count > 0 do
            Logger.info("registered #{count} responsibilities for #{inspect(mod)}")
          end
      end
    end)
  end

  defp count_rows_for(mod, oks) do
    declared_keys =
      try do
        mod.register() |> Enum.map(&(&1[:key] || &1["key"])) |> MapSet.new()
      rescue
        _ -> MapSet.new()
      catch
        _, _ -> MapSet.new()
      end

    Enum.count(oks, &MapSet.member?(declared_keys, &1.key))
  end

  defp log_failures(errors) do
    Enum.each(errors, fn {mod, reason} ->
      Logger.error("register failed for #{inspect(mod)}: #{inspect(reason)}")
    end)
  end
end
