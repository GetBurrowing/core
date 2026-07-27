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
  alias Platform.Responsibilities.Handlers.{DailySummary, Dreaming, ProposeLongTerm}
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

  describe "handler_for/1" do
    # Task 019f9b28 stage 4: this was a private `dispatch_module/1`
    # returning `{:ok, mod} | :error`, which made `memory` the odd one
    # out against Design/Meetings/Tasks. The coverage test
    # (test/platform/responsibilities/provider_coverage_test.exs) walks
    # every provider through this accessor, and a guard with a special
    # case is how the failure class comes back.

    test "resolves each memory.* key to its handler module" do
      assert MemoryProvider.handler_for("memory.daily_summary") == DailySummary
      assert MemoryProvider.handler_for("memory.dreaming") == Dreaming
      assert MemoryProvider.handler_for("memory.propose_long_term") == ProposeLongTerm
    end

    test "resolves the keys the handlers themselves declare" do
      # Via key/0 rather than string literals, so a key rename breaks
      # this test instead of silently re-orphaning the handler.
      assert MemoryProvider.handler_for(DailySummary.key()) == DailySummary
      assert MemoryProvider.handler_for(Dreaming.key()) == Dreaming
      assert MemoryProvider.handler_for(ProposeLongTerm.key()) == ProposeLongTerm
    end

    test "accepts a %Responsibility{} struct" do
      assert MemoryProvider.handler_for(daily_summary_responsibility()) == DailySummary
      assert MemoryProvider.handler_for(dreaming_responsibility()) == Dreaming
    end

    test "accepts a bare map carrying :key" do
      assert MemoryProvider.handler_for(%{key: "memory.dreaming"}) == Dreaming
    end

    test "returns nil for keys owned by another feature and for garbage" do
      assert MemoryProvider.handler_for("design.critique") == nil
      assert MemoryProvider.handler_for("memory.brand_new_thing") == nil
      assert MemoryProvider.handler_for(nil) == nil
      assert MemoryProvider.handler_for(%{}) == nil
      assert MemoryProvider.handler_for(:not_a_key) == nil
    end

    test "covers every key register/0 declares" do
      for spec <- MemoryProvider.register() do
        assert MemoryProvider.handler_for(spec.key) != nil,
               "register/0 declares #{spec.key} but handler_for/1 maps it to nil"
      end
    end
  end

  describe "handle_output/3" do
    test "routes memory.daily_summary to the DailySummary handler" do
      today = Date.utc_today()
      attrs = %{kind: :cron, date: today}

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

      # Task 019f70e9 stage 7: writes flow to today's journal, not the
      # legacy `org/page/memory.md` page. The synthesis body lands
      # alongside an auto-applied maintenance summary in a single
      # atomic write.
      journal_key = Dreaming.journal_file_key(Date.utc_today())
      file = OrgContext.get_file(journal_key)
      assert file
      assert file.content =~ "A curated note"
      assert file.content =~ "Auto-applied maintenance"
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
