defmodule Platform.Responsibilities.Handlers.DailySummaryTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.DailySummary` — the
  M8 stage 2 provider that owns the `memory.daily_summary`
  responsibility row and writes parsed LLM output to the org journal.
  """
  use Platform.DataCase, async: false

  alias Platform.Org.Context, as: OrgContext
  alias Platform.Responsibilities.Handlers.DailySummary
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: DailySummary.key(),
      feature: "memory",
      trigger_kind: "cron",
      trigger_config: %{"expression" => "0 23 * * *"},
      scope: "per_org",
      context_provided: ["recent_journal", "org_identity"],
      enabled: true
    }
  end

  describe "register/0" do
    test "declares one spec with the canonical key + cron expression" do
      [spec] = DailySummary.register()

      assert spec.key == "memory.daily_summary"
      assert spec.feature == "memory"
      assert spec.trigger_kind == "cron"
      assert spec.trigger_config == %{"expression" => "0 23 * * *"}
      assert spec.scope == "per_org"
      assert spec.context_provided == ["recent_journal", "org_identity"]
      assert spec.cost_profile == "low_freq_capable"
    end
  end

  describe "handle_output/3" do
    test "accepts %{\"summary\" => string} and appends a memory entry" do
      attrs = %{kind: :cron, date: ~D[2026-06-24]}

      assert :ok =
               DailySummary.handle_output(
                 responsibility(),
                 %{"summary" => "Today we shipped X and decided Y."},
                 attrs
               )

      [entry | _] = OrgContext.recent_memory(1)
      {_date, entries} = entry
      [%{content: content, metadata: metadata, date: date}] = entries

      assert content =~ "Today we shipped X and decided Y."
      assert date == ~D[2026-06-24]
      assert metadata["source"] == "responsibility:memory.daily_summary"
      assert metadata["responsibility_key"] == "memory.daily_summary"
      assert metadata["trigger_kind"] == "cron"
    end

    test "accepts atom-keyed map (%{summary: ...})" do
      assert :ok =
               DailySummary.handle_output(
                 responsibility(),
                 %{summary: "Atom-keyed payload."},
                 %{kind: :cron}
               )
    end

    test "accepts a bare string payload" do
      assert :ok =
               DailySummary.handle_output(
                 responsibility(),
                 "Bare-string payload.",
                 %{kind: :cron}
               )
    end

    test "rejects malformed output without raising" do
      assert {:error, :invalid_output_shape} =
               DailySummary.handle_output(responsibility(), %{}, %{kind: :cron})

      assert {:error, :invalid_output_shape} =
               DailySummary.handle_output(responsibility(), %{"summary" => ""}, %{kind: :cron})

      assert {:error, :invalid_output_shape} =
               DailySummary.handle_output(responsibility(), :not_a_map, %{kind: :cron})
    end

    test "default date is today when trigger_meta omits :date" do
      today = Date.utc_today()

      assert :ok =
               DailySummary.handle_output(
                 responsibility(),
                 %{"summary" => "Defaulted-date payload."},
                 %{kind: :cron}
               )

      [{date, _entries}] = OrgContext.recent_memory(1)
      assert date == today
    end
  end

  describe "gather_context/2" do
    test "merges :recent_journal and :org_identity slots" do
      assert {:ok, ctx} = DailySummary.gather_context(responsibility(), %{})
      assert Map.has_key?(ctx, :recent_journal)
      assert Map.has_key?(ctx, :org_identity)
    end
  end
end
