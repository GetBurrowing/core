defmodule Mix.Tasks.Platform.BackfillUsageCosts do
  @moduledoc """
  Recalculates cost_usd and total_tokens for all usage events using
  the server-side pricing table.

  Idempotent — safe to run multiple times.

  ## Usage

      mix platform.backfill_usage_costs
      mix platform.backfill_usage_costs --dry-run

  """
  use Mix.Task

  import Ecto.Query

  alias Platform.Analytics.Pricing
  alias Platform.Repo

  @shortdoc "Backfill cost_usd for all usage events from pricing table"

  @impl Mix.Task
  def run(args) do
    dry_run = "--dry-run" in args

    Mix.Task.run("app.start")

    events =
      Repo.all(
        from(e in "agent_usage_events",
          select: %{
            id: e.id,
            model: e.model,
            cost_usd: e.cost_usd,
            input_tokens: e.input_tokens,
            output_tokens: e.output_tokens,
            cache_read_tokens: e.cache_read_tokens,
            cache_write_tokens: e.cache_write_tokens,
            total_tokens: e.total_tokens
          }
        )
      )

    Mix.shell().info("Found #{length(events)} usage events to process")

    updated_count =
      events
      |> Enum.reduce(0, fn event, count ->
        new_cost =
          Pricing.calculate_cost(%{
            model: event.model,
            input_tokens: event.input_tokens,
            output_tokens: event.output_tokens,
            cache_read_tokens: event.cache_read_tokens,
            cache_write_tokens: event.cache_write_tokens
          })

        input = event.input_tokens || 0
        output = event.output_tokens || 0
        cache_read = event.cache_read_tokens || 0
        cache_write = event.cache_write_tokens || 0
        new_total = input + output + cache_read + cache_write

        changed = event.cost_usd != new_cost || event.total_tokens != new_total

        if changed do
          if dry_run do
            Mix.shell().info(
              "  [DRY RUN] #{event.model}: cost #{event.cost_usd} → #{new_cost}, " <>
                "tokens #{event.total_tokens} → #{new_total}"
            )
          else
            Repo.query!(
              "UPDATE agent_usage_events SET cost_usd = $1, total_tokens = $2 WHERE id = $3",
              [new_cost, new_total, event.id]
            )
          end

          count + 1
        else
          count
        end
      end)

    if dry_run do
      Mix.shell().info("Would update #{updated_count} events (dry run)")
    else
      Mix.shell().info("Updated #{updated_count} events")
    end
  end
end
