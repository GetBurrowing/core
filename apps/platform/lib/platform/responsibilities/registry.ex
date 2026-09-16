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

  ## Provider-coverage drift (task 019f9b28 stage 3)

  After registration the Registry checks every declared `feature` against
  `Platform.Responsibilities.Providers.feature_provider/1` and emits one
  `Logger.error/1` plus a `[:platform, :responsibility, :provider_missing]`
  telemetry event per feature that resolves to `:error`. Those
  responsibilities register and fire normally — the Router just has nowhere
  to send their output, so it is silently dropped. Retired features
  (`{:retired, _}`) emit nothing, and a feature bound through the
  `:responsibility_provider_overrides` seam counts as covered. The check is
  observability only: it cannot change `status/0` and cannot raise.

  ## Prompt-template orphans (task 01a0a74d stage 3)

  After registration the Registry resolves every registered
  responsibility's `default_prompt_template` against the
  `prompt_templates` table via `Responsibilities.prompt_template_audit/1`
  and emits one `Logger.error/1` plus a
  `[:platform, :responsibilities, :prompt_template_orphan]` telemetry event
  per key whose slug is missing or blank. The orphan list is carried into
  state and returned by `status/0` under `:prompt_template_orphans`.

  Like the provider-coverage check above, this **never raises** — see the
  comment on `audit_prompt_templates/1`. A responsibility naming no
  template at all is `:none` and is not an orphan.

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
  alias Platform.Responsibilities.Providers

  @typedoc "Aggregated result of the last `register_all/1` invocation."
  @type results :: %{
          ok: [Responsibilities.Responsibility.t()],
          errors: [{module(), term()}],
          prompt_template_orphans: [Responsibilities.prompt_template_audit_entry()]
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
    log_provider_coverage(providers)

    Map.put(results, :prompt_template_orphans, audit_prompt_templates(oks))
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

  # ── provider-coverage drift (task 019f9b28 stage 3) ───────────────────────

  # A responsibility whose feature has no provider still registers, still
  # fires, and still dispatches — the Router simply has nowhere to send the
  # answer, so it drops it. `architecture.*` sat in that state for months.
  # The CI coverage test catches this for anything in `BuiltIns.providers/0`,
  # but the Registry's provider list is *configurable*
  # (`config :platform, Platform.Responsibilities, providers: [...]`), so an
  # out-of-tree provider never passes under CI's nose. This check closes that
  # gap where the real list is known: at boot.
  #
  # Resolution goes through `Providers.feature_provider/1`, NOT
  # `Providers.all/0`. That matters: `feature_provider/1` consults the
  # `:responsibility_provider_overrides` seam first, so an operator who ships
  # a provider through the config extension point *and binds it* is silent
  # here — which is correct, because that binding is exactly what makes the
  # Router able to resolve them. An extension provider with no override
  # registered is flagged on every boot, also correct: without the binding
  # its output really is discarded. Nagging every boot about a legitimate
  # override would be the alarm-fatigue rot this check exists to prevent.
  #
  # Walking each provider's own `register/0` output rather than a `Repo.all`
  # over the table keeps boot free of a DB round-trip, avoids a sandbox
  # ownership problem when a per-case Registry starts inside a test, and
  # reasons about the same list that drives dispatch resolution.
  #
  # This is observability only: it never touches the results map and must
  # never raise, hence the `count_rows_for/2`-shaped try/rescue/catch around
  # every provider callback and a rescue around the telemetry emit.
  @spec log_provider_coverage([module()]) :: :ok
  defp log_provider_coverage(providers) do
    providers
    |> Enum.flat_map(&declared_feature_keys/1)
    |> Enum.reduce(%{}, fn {feature, key}, acc ->
      Map.update(acc, feature, [key], &[key | &1])
    end)
    |> Enum.each(fn {feature, keys} ->
      case Providers.feature_provider(feature) do
        # {:ok, _} — resolvable, compiled or overridden. {:retired, _} — a
        # stated decision with a named owner; saying anything would train
        # operators to skim past this line.
        :error -> report_missing_provider(feature, Enum.sort(keys))
        _ -> :ok
      end
    end)
  end

  # Non-binary / empty features are skipped rather than reported: they cannot
  # resolve to a provider under any registry, and `register_all/1` has already
  # rejected them into `:errors` where `log_failures/1` names the module.
  defp declared_feature_keys(mod) do
    try do
      mod.register()
      |> Enum.map(fn spec -> {spec[:feature] || spec["feature"], spec[:key] || spec["key"]} end)
      |> Enum.filter(fn {feature, _key} -> is_binary(feature) and feature != "" end)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp report_missing_provider(feature, keys) do
    Logger.error(
      "[ResponsibilityRegistry] provider_missing feature=#{feature} " <>
        "keys=#{Enum.join(keys, ",")} — these responsibilities register and fire, but the " <>
        "Router cannot resolve a provider, so every answer they produce is discarded. Fix: add " <>
        ~s("#{feature}" => YourProvider) <>
        " to @feature_providers in Platform.Responsibilities.Providers (platform built-in), or " <>
        "bind it at runtime with config :platform, responsibility_provider_overrides: " <>
        ~s(%{"#{feature}" => YourProvider}) <> " (out-of-tree provider)."
    )

    emit_provider_missing_telemetry(feature, keys)
  end

  defp emit_provider_missing_telemetry(feature, keys) do
    :telemetry.execute(
      [:platform, :responsibility, :provider_missing],
      %{count: length(keys)},
      %{feature: feature, keys: keys}
    )
  rescue
    _ -> :ok
  end

  # ── prompt-template orphans (task 01a0a74d stage 3) ───────────────────────

  # WHY THIS IS HERE RATHER THAN IN THE ROUTER. `router.ex` already
  # distinguishes `{:template_missing, slug}` from `{:template_blank, slug}`
  # from `:legacy`, already logs a warning naming the slug, and already
  # stamps `prompt_status: :render_gap` on the native envelope. None of that
  # is duplicated here and none of it should be. The gap is that all of it is
  # per-FIRE and after the fact: `memory.daily_summary` fires once a day at
  # 23:00 UTC, so a missing row announced itself once a day, in a container
  # log, AFTER the Historian had already been handed an empty prompt. The
  # slug is declared in source, so the same fact is knowable at registration
  # time with zero fires. That is the only thing this adds.
  #
  # MUST NOT RAISE, AND MUST NOT BE "FIXED" INTO A RAISE. `do_register/1`
  # relies on `register_all/1` being boot-safe and there is deliberately no
  # try/rescue around it; a raise here would take the application down on
  # every environment whose `prompt_templates` rows are not seeded yet —
  # which is every fresh test database before `seed_defaults/0`, and any
  # install mid-migration. Loud means `Logger.error` + telemetry + an
  # inspectable `status/0` key. It does not mean a boot crash.
  #
  # Audits the rows just registered (`oks`) rather than re-reading the table,
  # so the verdict is about what this Registry actually put there.
  @spec audit_prompt_templates([Responsibilities.Responsibility.t()]) :: [map()]
  defp audit_prompt_templates(oks) do
    orphans =
      oks
      |> Responsibilities.prompt_template_audit()
      |> Responsibilities.prompt_template_orphans()

    Enum.each(orphans, &report_prompt_template_orphan/1)

    orphans
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp report_prompt_template_orphan(%{key: key, status: status} = entry) do
    {verdict, slug} =
      case status do
        {:missing, slug} -> {"missing", slug}
        {:blank, slug} -> {"blank", slug}
      end

    Logger.error(
      "[ResponsibilityRegistry] prompt_template_#{verdict} key=#{key} " <>
        "slug=#{slug} trigger=#{entry.trigger_kind} — this responsibility registers and " <>
        "fires, but the template it names is #{verdict}, so every dispatch renders with an " <>
        "empty body and nothing errors. Fix: add a descriptor to " <>
        "Platform.Orchestration.PromptTemplates.do_default_templates/0 AND a seeding " <>
        "migration — seed_defaults/0 is INSERT-only and skips an already-migrated " <>
        "environment, so editing the hardcoded default list alone does NOT put the row on " <>
        "a live install."
    )

    emit_prompt_template_orphan_telemetry(entry, verdict, slug)
  end

  defp emit_prompt_template_orphan_telemetry(entry, verdict, slug) do
    :telemetry.execute(
      [:platform, :responsibilities, :prompt_template_orphan],
      %{count: 1},
      %{key: entry.key, slug: slug, verdict: verdict, trigger_kind: entry.trigger_kind}
    )
  rescue
    _ -> :ok
  end
end
