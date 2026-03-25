defmodule Platform.AnalyticsTest do
  use Platform.DataCase, async: true

  alias Platform.Analytics

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @valid_attrs %{
    model: "anthropic/claude-sonnet-4-6",
    provider: "anthropic",
    session_key: "sess-test-001",
    input_tokens: 1500,
    output_tokens: 800,
    cache_read_tokens: 500,
    cache_write_tokens: 100,
    cost_usd: 0.023,
    latency_ms: 3200,
    tool_calls: ["read", "exec"],
    metadata: %{"source" => "test"}
  }

  defp create_event(overrides \\ %{}) do
    {:ok, event} = Analytics.record_usage_event(Map.merge(@valid_attrs, overrides))
    event
  end

  describe "record_usage_event/1" do
    test "inserts a valid event and computes total_tokens" do
      assert {:ok, event} = Analytics.record_usage_event(@valid_attrs)
      assert event.id != nil
      assert event.model == "anthropic/claude-sonnet-4-6"
      assert event.total_tokens == 1500 + 800 + 500 + 100
      assert event.inserted_at != nil
    end

    test "always recomputes total_tokens from components (ignores caller value)" do
      attrs = Map.put(@valid_attrs, :total_tokens, 42)
      assert {:ok, event} = Analytics.record_usage_event(attrs)
      # Should be recomputed, not the caller's 42
      assert event.total_tokens == 1500 + 800 + 500 + 100
    end

    test "computes cost_usd server-side (ignores caller-provided cost)" do
      # @valid_attrs has cost_usd: 999.99 — should be overridden
      assert {:ok, event} = Analytics.record_usage_event(@valid_attrs)
      assert event.cost_usd != 999.99
      assert event.cost_usd > 0
      # Verify it matches the pricing module calculation
      expected =
        Platform.Analytics.Pricing.calculate_cost(%{
          model: "anthropic/claude-sonnet-4-6",
          input_tokens: 1500,
          output_tokens: 800,
          cache_read_tokens: 500,
          cache_write_tokens: 100
        })

      assert event.cost_usd == expected
    end

    test "returns 0.0 cost for unknown models" do
      attrs = Map.merge(@valid_attrs, %{model: "unknown/model", provider: "unknown"})
      assert {:ok, event} = Analytics.record_usage_event(attrs)
      assert event.cost_usd == 0.0
    end

    test "returns error for missing required fields" do
      assert {:error, changeset} = Analytics.record_usage_event(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.model
      assert "can't be blank" in errors.provider
      assert "can't be blank" in errors.session_key
    end
  end

  describe "usage_summary/1" do
    test "returns zeroes when no events exist" do
      summary = Analytics.usage_summary()
      assert summary.total_requests == 0
      assert summary.total_tokens == 0
      assert summary.total_cost == 0.0
      assert summary.avg_latency_ms == 0.0
    end

    test "aggregates across multiple events" do
      create_event(%{latency_ms: 1000, input_tokens: 100, output_tokens: 50})
      create_event(%{latency_ms: 2000, input_tokens: 200, output_tokens: 100})

      summary = Analytics.usage_summary()
      assert summary.total_requests == 2
      # Cost is now server-computed; both events use claude-sonnet-4-6 pricing
      assert summary.total_cost > 0
    end

    test "filters by agent_id" do
      agent_a = Ecto.UUID.generate()
      agent_b = Ecto.UUID.generate()

      create_event(%{agent_id: agent_a})
      create_event(%{agent_id: agent_b})
      create_event(%{agent_id: agent_a})

      summary = Analytics.usage_summary(%{agent_id: agent_a})
      assert summary.total_requests == 2
    end

    test "filters by date range" do
      old_time = DateTime.utc_now() |> DateTime.add(-10, :day)

      create_event()
      # Insert an old event via repo directly
      {:ok, _} =
        %Platform.Analytics.UsageEvent{}
        |> Platform.Analytics.UsageEvent.changeset(@valid_attrs)
        |> Ecto.Changeset.put_change(:inserted_at, old_time)
        |> Repo.insert()

      from_dt = DateTime.utc_now() |> DateTime.add(-1, :day)
      summary = Analytics.usage_summary(%{from: from_dt})
      assert summary.total_requests == 1
    end
  end

  describe "usage_time_series/2" do
    test "returns empty list when no events" do
      assert Analytics.usage_time_series() == []
    end

    test "buckets events by day" do
      create_event()
      create_event()

      series = Analytics.usage_time_series()
      assert length(series) == 1
      [day] = series
      assert day.requests == 2
      assert day.tokens > 0
    end
  end

  describe "recent_events/2" do
    test "returns events ordered by most recent first" do
      _e1 = create_event(%{session_key: "first"})
      e2 = create_event(%{session_key: "second"})

      [most_recent | _] = Analytics.recent_events()
      assert most_recent.id == e2.id
    end

    test "respects limit" do
      for i <- 1..5, do: create_event(%{session_key: "sess-#{i}"})

      events = Analytics.recent_events(%{}, 3)
      assert length(events) == 3
    end

    test "filters by agent_id" do
      agent_id = Ecto.UUID.generate()
      create_event(%{agent_id: agent_id})
      create_event(%{agent_id: Ecto.UUID.generate()})

      events = Analytics.recent_events(%{agent_id: agent_id})
      assert length(events) == 1
      assert hd(events).agent_id == agent_id
    end
  end
end
