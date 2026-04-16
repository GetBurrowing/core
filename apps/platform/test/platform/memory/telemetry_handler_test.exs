defmodule Platform.Memory.TelemetryHandlerTest do
  use Platform.DataCase, async: false

  alias Platform.Memory.TelemetryHandler
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.MemoryEntry
  alias Platform.Repo

  setup do
    Repo.delete_all(MemoryEntry)
    :ok
  end

  describe "handle_event/4 with Null provider" do
    test "does not crash when a memory entry is written" do
      {:ok, entry} =
        OrgContext.append_memory_entry(%{
          content: "Test entry for telemetry",
          memory_type: "daily",
          date: Date.utc_today()
        })

      # The telemetry event fires synchronously in append_memory_entry,
      # so if we get here without a crash the handler worked.
      assert entry.id
      assert Repo.get(MemoryEntry, entry.id)
    end
  end

  describe "handle_event/4 directly" do
    test "handles missing entry gracefully" do
      # Pass an ID that doesn't exist in the DB
      assert :ok =
               TelemetryHandler.handle_event(
                 [:platform, :org, :memory_entry_written],
                 %{system_time: System.system_time()},
                 %{
                   memory_entry_id: Ecto.UUID.generate(),
                   memory_type: "daily",
                   date: Date.utc_today(),
                   workspace_id: nil
                 },
                 %{}
               )
    end

    test "ingests entry to configured provider" do
      {:ok, entry} =
        OrgContext.append_memory_entry(%{
          content: "Entry for direct handler test",
          memory_type: "long_term",
          date: Date.utc_today()
        })

      # Call handler directly — with Null provider this is a no-op
      result =
        TelemetryHandler.handle_event(
          [:platform, :org, :memory_entry_written],
          %{system_time: System.system_time()},
          %{
            memory_entry_id: entry.id,
            memory_type: entry.memory_type,
            date: entry.date,
            workspace_id: entry.workspace_id
          },
          %{}
        )

      assert result == :ok
    end
  end
end
