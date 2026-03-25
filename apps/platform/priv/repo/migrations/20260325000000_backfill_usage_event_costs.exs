defmodule Platform.Repo.Migrations.BackfillUsageEventCosts do
  @moduledoc """
  Recalculates cost_usd and total_tokens for all existing usage events using
  the server-side pricing table. Idempotent — safe to run multiple times.
  """
  use Ecto.Migration

  import Ecto.Query

  def up do
    # Fetch the pricing table at migration time
    pricing = Platform.Analytics.Pricing.pricing_table()

    # Process in batches of 500 to avoid memory issues
    stream_all_events()
    |> Stream.chunk_every(500)
    |> Enum.each(fn batch ->
      updates =
        Enum.map(batch, fn event ->
          model = normalize_model(event.model)
          rates = Map.get(pricing, model)

          input = event.input_tokens || 0
          output = event.output_tokens || 0
          cache_read = event.cache_read_tokens || 0
          cache_write = event.cache_write_tokens || 0

          total_tokens = input + output + cache_read + cache_write

          cost_usd =
            if rates do
              Float.round(
                input * rates.input / 1_000_000 +
                  cache_read * rates.cached_input / 1_000_000 +
                  output * rates.output / 1_000_000 +
                  cache_write * rates.cache_write / 1_000_000,
                6
              )
            else
              0.0
            end

          {event.id, cost_usd, total_tokens}
        end)

      Enum.each(updates, fn {id, cost, total} ->
        # id is raw binary UUID — must be formatted as hex string for SQL
        id_hex = Base.encode16(id, case: :lower)

        formatted_id =
          "#{String.slice(id_hex, 0, 8)}-#{String.slice(id_hex, 8, 4)}-#{String.slice(id_hex, 12, 4)}-#{String.slice(id_hex, 16, 4)}-#{String.slice(id_hex, 20, 12)}"

        execute("""
        UPDATE agent_usage_events
        SET cost_usd = #{cost}, total_tokens = #{total}
        WHERE id = '#{formatted_id}'
        """)
      end)
    end)
  end

  def down do
    # No-op: we can't restore original caller-provided costs
    :ok
  end

  defp stream_all_events do
    repo().all(
      from(e in "agent_usage_events",
        select: %{
          id: e.id,
          model: e.model,
          input_tokens: e.input_tokens,
          output_tokens: e.output_tokens,
          cache_read_tokens: e.cache_read_tokens,
          cache_write_tokens: e.cache_write_tokens
        }
      )
    )
  end

  defp normalize_model(nil), do: nil

  defp normalize_model(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [_provider, name] -> name
      [name] -> name
    end
  end
end
