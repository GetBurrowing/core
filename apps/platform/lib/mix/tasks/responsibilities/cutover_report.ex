defmodule Mix.Tasks.Responsibilities.CutoverReport do
  @moduledoc """
  Print the current `Platform.Responsibilities.CutoverMonitor` report
  (ADR-0041 M8 stage 6).

  Operators run this once a day during the cutover-watch window to
  decide when to flip `:responsibility_router_enabled` permanently and
  queue the `Platform.Agents.SystemEventScheduler` deletion follow-up.
  The exit code is non-zero when the monitor's `divergence_count` for
  any tracked key is greater than zero — that way CI/cron wrappers can
  surface the regression without parsing output.

  ## Usage

      mix responsibilities.cutover_report

  ## Example output

      Responsibilities cutover report
      ===============================
      as_of: 2026-06-24

      memory.daily_summary
          router:           1
          legacy:           1
          divergence_count: 0

      memory.dreaming
          router:           1
          legacy:           1
          divergence_count: 0

      OK — no divergence detected for any tracked key.

  ## Cutover checklist (see `Handlers.DailySummary` moduledoc)

    1. `divergence_count: 0` for 7 consecutive days for every tracked key.
    2. Flip `:responsibility_router_enabled` default to `true` in
       `config/prod.exs`.
    3. Open a follow-up task to delete
       `apps/platform/lib/platform/agents/system_event_scheduler.ex`,
       the `Platform.Agents.Agent.@valid_system_events` list, and the
       `system_events` column.
  """
  use Mix.Task

  alias Platform.Responsibilities.CutoverMonitor

  @shortdoc "Print the responsibilities cutover (router vs legacy) report."

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:platform)

    report = CutoverMonitor.report()

    Mix.shell().info(format_report(report))

    if any_divergence?(report) do
      Mix.shell().error("DIVERGENCE detected — do not flip cutover flag yet.")
      exit({:shutdown, 1})
    else
      Mix.shell().info("OK — no divergence detected for any tracked key.")
      :ok
    end
  rescue
    error ->
      Mix.shell().error("[responsibilities.cutover_report] failed: " <> Exception.message(error))

      reraise error, __STACKTRACE__
  end

  @doc false
  # Exposed for tests so we can render arbitrary report shapes without
  # standing up a running monitor.
  @spec format_report(map()) :: String.t()
  def format_report(%{as_of: as_of, keys: keys}) when is_map(keys) do
    header = """

    Responsibilities cutover report
    ===============================
    as_of: #{as_of}
    """

    body =
      keys
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map_join("\n", &format_key/1)

    header <> "\n" <> body <> "\n"
  end

  def format_report(_), do: "(empty report)\n"

  defp format_key({key, %{router: router, legacy: legacy, divergence_count: divergence}}) do
    """
    #{key}
        router:           #{router}
        legacy:           #{legacy}
        divergence_count: #{divergence}
    """
  end

  defp any_divergence?(%{keys: keys}) when is_map(keys) do
    Enum.any?(keys, fn {_key, %{divergence_count: d}} -> d > 0 end)
  end

  defp any_divergence?(_), do: false
end
