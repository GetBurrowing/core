defmodule Platform.Vault.RefreshWorker do
  @moduledoc """
  Periodic GenServer that proactively refreshes expiring OAuth2 credentials.

  ## Strategy

  The worker runs a check on startup and every `@check_interval_ms` thereafter.
  Each sweep gathers credentials that are candidates for refresh and calls
  `Platform.Vault.OAuth.refresh/1` for each one.

  ### Candidate selection

  Two sets of credentials are considered:

  1. **Expiring soon** — any credential with `expires_at` within `@refresh_horizon`
     (24 hours by default), filtered to `oauth2` credential type.

  2. **Short-lived without expires_at** — `oauth2` credentials where the
     `expires_at` database column is `nil` but the credential was last rotated
     (or created) more than `@short_lived_threshold_minutes` minutes ago.
     Anthropic's access tokens expire in 1 hour; this catches them before
     the token exchange in `Platform.Vault.OAuth` records an `expires_at`.

  After `Vault.OAuth.refresh/1` succeeds, the credential's `rotated_at`
  timestamp is updated by `Vault.rotate/3`, so the short-lived sweep uses
  that field as its clock.

  ## Configuration

  All tunables can be overridden in `config.exs`:

      config :platform, Platform.Vault.RefreshWorker,
        check_interval_ms: :timer.minutes(30),
        refresh_horizon_hours: 24,
        short_lived_threshold_minutes: 50

  ## Telemetry

  The worker itself does not emit telemetry — it relies on
  `Platform.Vault.OAuth.refresh/1` emitting
  `[:platform, :vault, :oauth_refreshed]` or
  `[:platform, :vault, :oauth_refresh_failed]`, which `Platform.Vault.TelemetryHandler`
  forwards to the audit log.

  ## Public API

      # Force an immediate sweep (useful in tests / admin tasks):
      Platform.Vault.RefreshWorker.refresh_now()
  """

  use GenServer

  require Logger

  alias Platform.Vault
  alias Platform.Vault.OAuth

  # ── Defaults ─────────────────────────────────────────────────────────────────

  # How often to run the sweep.
  @default_check_interval_ms :timer.minutes(30)

  # Refresh credentials expiring within this window (as a {amount, unit} tuple).
  @default_refresh_horizon_hours 24

  # Refresh short-lived credentials (no expires_at) that were last rotated (or
  # created) more than this many minutes ago.
  @default_short_lived_threshold_minutes 50

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc "Start the worker under a supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger an immediate refresh sweep, bypassing the scheduled timer.

  Returns `{:ok, refreshed_count}` where `refreshed_count` is the number of
  credentials successfully refreshed.
  """
  @spec refresh_now() :: {:ok, non_neg_integer()}
  def refresh_now do
    GenServer.call(__MODULE__, :refresh_now, :timer.minutes(5))
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    state = build_state(opts)
    schedule_check(state)
    Logger.info("Platform.Vault.RefreshWorker started (interval=#{state.check_interval_ms}ms)")
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:check, state) do
    run_sweep(state)
    schedule_check(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:refresh_now, _from, state) do
    count = run_sweep(state)
    {:reply, {:ok, count}, state}
  end

  # ── Private: sweep ────────────────────────────────────────────────────────────

  defp run_sweep(state) do
    candidates = gather_candidates(state)

    Logger.debug("Platform.Vault.RefreshWorker: #{length(candidates)} candidate(s) to refresh")

    Enum.reduce(candidates, 0, fn cred, count ->
      case OAuth.refresh(cred.slug) do
        {:ok, _updated} ->
          Logger.info("Platform.Vault.RefreshWorker: refreshed credential slug=#{cred.slug}")
          count + 1

        {:error, reason} ->
          Logger.warning(
            "Platform.Vault.RefreshWorker: failed to refresh slug=#{cred.slug} reason=#{inspect(reason)}"
          )

          count
      end
    end)
  end

  # ── Private: candidate selection ──────────────────────────────────────────────

  defp gather_candidates(state) do
    expiring = expiring_soon_oauth2(state)
    short_lived = short_lived_stale_oauth2(state)

    # Deduplicate by slug in case a credential appears in both sets.
    (expiring ++ short_lived)
    |> Enum.uniq_by(& &1.slug)
  end

  # Credentials with expires_at set and within the horizon.
  defp expiring_soon_oauth2(state) do
    Vault.expiring_soon(within: {state.refresh_horizon_hours, :hours})
    |> Enum.filter(fn cred -> cred.credential_type == "oauth2" end)
  end

  # OAuth2 credentials without an expires_at in the DB that haven't been rotated
  # recently — used to catch short-lived tokens (e.g. Anthropic 1-hour tokens).
  defp short_lived_stale_oauth2(state) do
    threshold_seconds = state.short_lived_threshold_minutes * 60
    cutoff = DateTime.add(DateTime.utc_now(), -threshold_seconds, :second)

    Vault.list(credential_type: :oauth2)
    |> Enum.filter(fn cred ->
      # Only consider credentials without an explicit expires_at on the record.
      cred.expires_at == nil and stale_since?(cred, cutoff)
    end)
  end

  # Returns true if the credential was last refreshed (or first created) before `cutoff`.
  defp stale_since?(cred, cutoff) do
    last_touched = cred.rotated_at || cred.inserted_at
    last_touched != nil and DateTime.before?(last_touched, cutoff)
  end

  # ── Private: scheduling ───────────────────────────────────────────────────────

  defp schedule_check(%{check_interval_ms: ms}) do
    Process.send_after(self(), :check, ms)
  end

  # ── Private: config ───────────────────────────────────────────────────────────

  defp build_state(opts) do
    app_cfg = Application.get_env(:platform, __MODULE__, [])

    %{
      check_interval_ms:
        Keyword.get(
          opts,
          :check_interval_ms,
          Keyword.get(app_cfg, :check_interval_ms, @default_check_interval_ms)
        ),
      refresh_horizon_hours:
        Keyword.get(
          opts,
          :refresh_horizon_hours,
          Keyword.get(app_cfg, :refresh_horizon_hours, @default_refresh_horizon_hours)
        ),
      short_lived_threshold_minutes:
        Keyword.get(
          opts,
          :short_lived_threshold_minutes,
          Keyword.get(
            app_cfg,
            :short_lived_threshold_minutes,
            @default_short_lived_threshold_minutes
          )
        )
    }
  end
end
