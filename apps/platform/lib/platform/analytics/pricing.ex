defmodule Platform.Analytics.Pricing do
  @moduledoc """
  Server-side pricing lookup for LLM usage cost calculation.

  Rates are per 1M tokens. The pricing table is a module attribute for easy
  updates — no config or database dependency.
  """

  # Rates per 1,000,000 tokens (USD)
  # Key: model name (without provider prefix — matched after stripping "provider/")
  @pricing_table %{
    # OpenAI
    "gpt-5.4" => %{
      input: 2.50,
      cached_input: 0.25,
      output: 15.00,
      cache_write: 0.0
    },
    "gpt-5.4-mini" => %{
      input: 0.75,
      cached_input: 0.075,
      output: 4.50,
      cache_write: 0.0
    },
    "gpt-5.4-nano" => %{
      input: 0.20,
      cached_input: 0.02,
      output: 1.25,
      cache_write: 0.0
    },
    # Anthropic
    "claude-opus-4-6" => %{
      input: 15.00,
      cached_input: 1.50,
      output: 75.00,
      cache_write: 3.75
    },
    "claude-sonnet-4-6" => %{
      input: 3.00,
      cached_input: 0.30,
      output: 15.00,
      cache_write: 0.375
    }
  }

  @doc """
  Calculate cost in USD for a usage event.

  Accepts a map with keys: `model`, `input_tokens`, `output_tokens`,
  `cache_read_tokens`, `cache_write_tokens`. All token counts default to 0.

  Returns `0.0` for unknown models.
  """
  @spec calculate_cost(map()) :: float()
  def calculate_cost(attrs) when is_map(attrs) do
    model = normalize_model(attrs[:model] || attrs["model"])

    case Map.get(@pricing_table, model) do
      nil ->
        0.0

      rates ->
        input = to_int(attrs[:input_tokens] || attrs["input_tokens"])
        output = to_int(attrs[:output_tokens] || attrs["output_tokens"])
        cache_read = to_int(attrs[:cache_read_tokens] || attrs["cache_read_tokens"])
        cache_write = to_int(attrs[:cache_write_tokens] || attrs["cache_write_tokens"])

        cost =
          input * rates.input / 1_000_000 +
            cache_read * rates.cached_input / 1_000_000 +
            output * rates.output / 1_000_000 +
            cache_write * rates.cache_write / 1_000_000

        Float.round(cost, 6)
    end
  end

  @doc """
  Returns the pricing table for inspection (e.g. backfill scripts, admin UI).
  """
  @spec pricing_table() :: map()
  def pricing_table, do: @pricing_table

  @doc """
  Returns the list of known model names.
  """
  @spec known_models() :: [String.t()]
  def known_models, do: Map.keys(@pricing_table)

  # Strip provider prefix: "anthropic/claude-sonnet-4-6" → "claude-sonnet-4-6"
  defp normalize_model(nil), do: nil

  defp normalize_model(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [_provider, name] -> name
      [name] -> name
    end
  end

  defp to_int(nil), do: 0
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: round(n)
  defp to_int(n) when is_binary(n), do: String.to_integer(n)
end
