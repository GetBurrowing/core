defmodule Platform.Analytics.PricingTest do
  use ExUnit.Case, async: true

  alias Platform.Analytics.Pricing

  describe "calculate_cost/1" do
    test "calculates cost for claude-sonnet-4-6 with all token types" do
      cost =
        Pricing.calculate_cost(%{
          model: "anthropic/claude-sonnet-4-6",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000,
          cache_read_tokens: 1_000_000,
          cache_write_tokens: 1_000_000
        })

      # input: 3.00 + cached_input: 0.30 + output: 15.00 + cache_write: 0.375 = 18.675
      assert cost == 18.675
    end

    test "calculates cost for claude-opus-4-6" do
      cost =
        Pricing.calculate_cost(%{
          model: "anthropic/claude-opus-4-6",
          input_tokens: 100_000,
          output_tokens: 50_000,
          cache_read_tokens: 200_000,
          cache_write_tokens: 0
        })

      # input: 15.00 * 0.1 = 1.50
      # output: 75.00 * 0.05 = 3.75
      # cached_input: 1.50 * 0.2 = 0.30
      # cache_write: 0
      # total: 5.55
      assert cost == 5.55
    end

    test "calculates cost for gpt-5.4" do
      cost =
        Pricing.calculate_cost(%{
          model: "openai/gpt-5.4",
          input_tokens: 500_000,
          output_tokens: 100_000,
          cache_read_tokens: 0,
          cache_write_tokens: 0
        })

      # input: 2.50 * 0.5 = 1.25
      # output: 15.00 * 0.1 = 1.50
      # total: 2.75
      assert cost == 2.75
    end

    test "calculates cost for gpt-5.4-mini" do
      cost =
        Pricing.calculate_cost(%{
          model: "gpt-5.4-mini",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000,
          cache_read_tokens: 0,
          cache_write_tokens: 0
        })

      # input: 0.75 + output: 4.50 = 5.25
      assert cost == 5.25
    end

    test "calculates cost for gpt-5.4-nano" do
      cost =
        Pricing.calculate_cost(%{
          model: "gpt-5.4-nano",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000,
          cache_read_tokens: 1_000_000,
          cache_write_tokens: 0
        })

      # input: 0.20 + cached_input: 0.02 + output: 1.25 = 1.47
      assert cost == 1.47
    end

    test "strips provider prefix from model name" do
      with_prefix =
        Pricing.calculate_cost(%{
          model: "anthropic/claude-sonnet-4-6",
          input_tokens: 100_000,
          output_tokens: 0,
          cache_read_tokens: 0,
          cache_write_tokens: 0
        })

      without_prefix =
        Pricing.calculate_cost(%{
          model: "claude-sonnet-4-6",
          input_tokens: 100_000,
          output_tokens: 0,
          cache_read_tokens: 0,
          cache_write_tokens: 0
        })

      assert with_prefix == without_prefix
      assert with_prefix == 0.3
    end

    test "returns 0.0 for unknown model" do
      cost =
        Pricing.calculate_cost(%{
          model: "unknown/some-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000,
          cache_read_tokens: 0,
          cache_write_tokens: 0
        })

      assert cost == 0.0
    end

    test "returns 0.0 for nil model" do
      cost =
        Pricing.calculate_cost(%{
          model: nil,
          input_tokens: 1000,
          output_tokens: 500,
          cache_read_tokens: 0,
          cache_write_tokens: 0
        })

      assert cost == 0.0
    end

    test "handles nil token counts as zero" do
      cost =
        Pricing.calculate_cost(%{
          model: "claude-sonnet-4-6",
          input_tokens: nil,
          output_tokens: nil,
          cache_read_tokens: nil,
          cache_write_tokens: nil
        })

      assert cost == 0.0
    end

    test "handles missing token keys as zero" do
      cost = Pricing.calculate_cost(%{model: "claude-sonnet-4-6"})
      assert cost == 0.0
    end

    test "handles string keys in attrs" do
      cost =
        Pricing.calculate_cost(%{
          "model" => "claude-sonnet-4-6",
          "input_tokens" => 100_000,
          "output_tokens" => 50_000,
          "cache_read_tokens" => 0,
          "cache_write_tokens" => 0
        })

      # input: 3.00 * 0.1 = 0.30
      # output: 15.00 * 0.05 = 0.75
      # total: 1.05
      assert cost == 1.05
    end

    test "realistic small request — Sonnet chat turn" do
      cost =
        Pricing.calculate_cost(%{
          model: "anthropic/claude-sonnet-4-6",
          input_tokens: 1500,
          output_tokens: 800,
          cache_read_tokens: 500,
          cache_write_tokens: 100
        })

      # input: 3.00 * 1500/1M = 0.0045
      # output: 15.00 * 800/1M = 0.012
      # cached: 0.30 * 500/1M = 0.00015
      # cache_write: 0.375 * 100/1M = 0.0000375
      # total ≈ 0.016688
      assert_in_delta cost, 0.016688, 0.000002
      assert cost > 0
    end
  end

  describe "pricing_table/0" do
    test "returns all models" do
      table = Pricing.pricing_table()
      assert Map.has_key?(table, "gpt-5.4")
      assert Map.has_key?(table, "gpt-5.4-mini")
      assert Map.has_key?(table, "gpt-5.4-nano")
      assert Map.has_key?(table, "claude-opus-4-6")
      assert Map.has_key?(table, "claude-sonnet-4-6")
    end
  end

  describe "known_models/0" do
    test "lists all known models" do
      models = Pricing.known_models()
      assert "gpt-5.4" in models
      assert "claude-sonnet-4-6" in models
      assert length(models) == 5
    end
  end
end
