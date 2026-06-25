defmodule Platform.Responsibilities.Providers.MemoryTest do
  @moduledoc """
  Tests for the M8 stage 6 shim
  `Platform.Responsibilities.Providers.Memory` — the seam that lets the
  M6 Router's `provider_module_for("memory")` lookup find a handler for
  both `memory.daily_summary` and `memory.dreaming` even though the
  per-key handlers live at `Handlers.DailySummary` /
  `Handlers.Dreaming`.
  """
  use Platform.DataCase, async: false

  alias Platform.Org.Context, as: OrgContext
  alias Platform.Responsibilities.Handlers.{DailySummary, Dreaming}
  alias Platform.Responsibilities.Providers.Memory, as: MemoryProvider
  alias Platform.Responsibilities.Responsibility

  defp daily_summary_responsibility do
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

  defp dreaming_responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: Dreaming.key(),
      feature: "memory",
      trigger_kind: "cron",
      trigger_config: %{"expression" => "0 3 * * *"},
      scope: "per_org",
      context_provided: ["recent_journal", "org_identity"],
      enabled: true
    }
  end

  describe "register/0" do
    test "aggregates the per-handler register specs" do
      specs = MemoryProvider.register()
      keys = Enum.map(specs, & &1.key)

      assert "memory.daily_summary" in keys
      assert "memory.dreaming" in keys
    end
  end

  describe "handle_output/3" do
    test "routes memory.daily_summary to the DailySummary handler" do
      attrs = %{kind: :cron, date: ~D[2026-06-24]}

      assert :ok =
               MemoryProvider.handle_output(
                 daily_summary_responsibility(),
                 %{"summary" => "Day-summary text via the shim."},
                 attrs
               )

      [entry | _] = OrgContext.recent_memory(1)
      {_date, entries} = entry
      [%{content: content, metadata: metadata}] = entries

      assert content =~ "Day-summary text via the shim"
      assert metadata["source"] == "responsibility:memory.daily_summary"
    end

    test "routes memory.dreaming to the Dreaming handler" do
      assert :ok =
               MemoryProvider.handle_output(
                 dreaming_responsibility(),
                 %{"memory_body" => "## Memory\n- A curated note."},
                 %{kind: :cron}
               )

      file = OrgContext.get_file(Dreaming.memory_file_key())
      assert file
      assert file.content =~ "A curated note"
    end

    test "tolerates unknown keys without crashing" do
      bogus = %Responsibility{
        id: Ecto.UUID.generate(),
        key: "memory.brand_new_thing",
        feature: "memory",
        trigger_kind: "cron",
        trigger_config: %{"expression" => "0 1 * * *"},
        scope: "per_org",
        enabled: true
      }

      # No matching handler → no-op :ok. The Router itself logs
      # "no output handler" via its own probe; this just proves the
      # shim doesn't blow up before that happens.
      assert :ok =
               MemoryProvider.handle_output(
                 bogus,
                 %{"summary" => "ignored"},
                 %{kind: :cron}
               )
    end
  end

  describe "handle_output/2" do
    test "delegates the arity-2 form for memory.daily_summary" do
      assert :ok =
               MemoryProvider.handle_output(
                 daily_summary_responsibility(),
                 %{"summary" => "Arity-2 path."}
               )
    end
  end
end
