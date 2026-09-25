defmodule Platform.Memory.TelemetryHandlerTest do
  use Platform.DataCase, async: false

  defmodule CaptureProvider do
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(entries, config) do
      send(Keyword.fetch!(config, :test_pid), {:ingest_config, entries, config})
      {:ok, length(entries)}
    end

    @impl true
    def search(_q, _o, _c), do: {:ok, []}

    @impl true
    def delete(ids, _c), do: {:ok, length(ids)}

    @impl true
    def health(_c), do: :ok
  end

  alias Platform.Memory.TelemetryHandler
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.WikiJournalEntry
  alias Platform.Repo

  setup do
    Repo.delete_all(WikiJournalEntry)
    :ok
  end

  describe "handle_event/4 with Noop provider" do
    test "does not crash when a memory entry is written" do
      {:ok, entry} =
        OrgContext.append_memory_entry(%{
          content: "Test entry for telemetry",
          date: Date.utc_today()
        })

      # The telemetry event fires synchronously in append_memory_entry,
      # so if we get here without a crash the handler worked.
      assert entry.id
      assert Repo.get(WikiJournalEntry, entry.id)
    end
  end

  describe "handle_event/4 directly" do
    test "handles missing entry gracefully" do
      # Pass an ID that doesn't exist in the DB
      TelemetryHandler.handle_event(
        [:platform, :org, :memory_entry_written],
        %{system_time: System.system_time()},
        %{
          memory_entry_id: Ecto.UUID.generate(),
          date: Date.utc_today(),
          workspace_id: nil
        },
        %{}
      )

      # No crash means success — Noop provider skips ingest
    end

    test "skips ingest when memory service is not enabled" do
      {:ok, entry} =
        OrgContext.append_memory_entry(%{
          content: "Entry for direct handler test",
          date: Date.utc_today()
        })

      # Call handler directly — with Noop provider, enabled?() is false
      # so the handler returns nil without attempting ingest
      TelemetryHandler.handle_event(
        [:platform, :org, :memory_entry_written],
        %{system_time: System.system_time()},
        %{
          memory_entry_id: entry.id,
          date: entry.date,
          workspace_id: entry.workspace_id
        },
        %{}
      )

      # No crash means success
    end
  end

  describe "ingest timeout (task 01a0d8c9)" do
    setup do
      # Written while the Noop provider is configured, so no handler or
      # ingest_async call reaches the capture provider for this entry.
      {:ok, entry} =
        OrgContext.append_memory_entry(%{content: "timeout bound", date: Date.utc_today()})

      prev = Application.get_env(:platform, :memory_service, [])
      on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
      %{entry: entry}
    end

    defp fire(entry) do
      TelemetryHandler.handle_event(
        [:platform, :org, :memory_entry_written],
        %{system_time: System.system_time()},
        %{memory_entry_id: entry.id, date: entry.date, workspace_id: entry.workspace_id},
        %{}
      )
    end

    test "the synchronous ingest carries ingest_timeout equal to the short :timeout", %{
      entry: entry
    } do
      Application.put_env(:platform, :memory_service,
        provider: CaptureProvider,
        test_pid: self(),
        timeout: 1_234,
        ingest_timeout: 120_000
      )

      fire(entry)

      entry_id = entry.id
      assert_receive {:ingest_config, [%{id: ^entry_id}], config}
      assert config[:ingest_timeout] == 1_234
    end

    test "with no :timeout configured it uses the 5s default, not the long ingest bound", %{
      entry: entry
    } do
      Application.put_env(:platform, :memory_service, provider: CaptureProvider, test_pid: self())

      fire(entry)

      entry_id = entry.id
      assert_receive {:ingest_config, [%{id: ^entry_id}], config}
      assert config[:ingest_timeout] == 5_000
    end
  end
end
