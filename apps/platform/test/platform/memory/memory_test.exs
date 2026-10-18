defmodule Platform.MemoryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Platform.Memory
  alias Platform.Memory.Providers.Noop

  setup do
    original = Application.get_env(:platform, :memory_service, [])
    on_exit(fn -> Application.put_env(:platform, :memory_service, original) end)
    :ok
  end

  describe "enabled?/0" do
    test "is false when no provider configured (falls back to Noop)" do
      Application.put_env(:platform, :memory_service, [])
      refute Memory.enabled?()
    end

    test "is false when provider explicitly set to Noop" do
      Application.put_env(:platform, :memory_service, provider: Noop)
      refute Memory.enabled?()
    end

    test "is true for a real provider module" do
      Application.put_env(:platform, :memory_service,
        provider: Platform.Memory.Providers.MemoryService
      )

      assert Memory.enabled?()
    end
  end

  describe "with Noop provider" do
    setup do
      Application.put_env(:platform, :memory_service, provider: Noop)
      :ok
    end

    test "ingest returns {:ok, 0}" do
      assert {:ok, 0} = Memory.ingest([%{id: "x", content: "y", date: "2026-04-16"}])
    end

    test "search returns empty" do
      assert {:ok, []} = Memory.search("anything")
    end

    test "delete returns {:ok, 0}" do
      assert {:ok, 0} = Memory.delete(["x"])
    end

    test "health returns {:error, :not_configured}" do
      assert {:error, :not_configured} = Memory.health()
    end
  end

  describe "entry normalization" do
    defmodule CaptureProvider do
      @behaviour Platform.Memory.Provider
      @impl true
      def ingest(entries, _config) do
        send(self(), {:captured, entries})
        {:ok, length(entries)}
      end

      @impl true
      def search(_q, _o, _c), do: {:ok, []}
      @impl true
      def delete(_ids, _c), do: {:ok, 0}
      @impl true
      def health(_c), do: :ok
    end

    setup do
      Application.put_env(:platform, :memory_service, provider: CaptureProvider)
      :ok
    end

    test "accepts Ecto structs and flattens Date to ISO8601" do
      struct = %Platform.Org.WikiJournalEntry{
        id: "01abc",
        content: "decision content",
        date: ~D[2026-04-16],
        workspace_id: nil,
        metadata: %{"tag" => "infra"}
      }

      {:ok, 1} = Memory.ingest([struct])

      assert_received {:captured,
                       [
                         %{
                           id: "01abc",
                           content: "decision content",
                           memory_type: "daily",
                           date: "2026-04-16",
                           workspace_id: nil,
                           metadata: %{"tag" => "infra"}
                         }
                       ]}
    end

    test "accepts plain maps with string or atom keys" do
      {:ok, 2} =
        Memory.ingest([
          %{id: "a", content: "x", date: "2026-04-16"},
          %{"id" => "b", "content" => "y", "date" => "2026-04-16", "memory_type" => "daily"}
        ])

      assert_received {:captured, [%{id: "a"}, %{id: "b", memory_type: "daily"}]}
    end

    test "preserves arbitrary memory_type strings (e.g. T3 \"page\" / \"journal\")" do
      # The normalize/1 path defaults memory_type to "daily" only when
      # absent; explicit values must survive. T3 (ADR-0041) ingests
      # wiki pages with memory_type "page" and journal entries with
      # "journal". Regression-guard: this test fails if anyone changes
      # normalize/1 to coerce/whitelist memory_type.
      {:ok, 2} =
        Memory.ingest([
          %{id: "p", content: "page", memory_type: "page", date: "2026-05-19"},
          %{id: "j", content: "journal", memory_type: "journal", date: "2026-05-19"}
        ])

      assert_received {:captured,
                       [
                         %{id: "p", memory_type: "page"},
                         %{id: "j", memory_type: "journal"}
                       ]}
    end

    test "forwards project_id and org_id from the entry into the provider payload" do
      {:ok, 1} =
        Memory.ingest([
          %{
            id: "f1",
            content: "doc",
            memory_type: "document",
            date: "2026-06-18",
            project_id: "proj-123",
            org_id: "org-456"
          }
        ])

      assert_received {:captured,
                       [
                         %{
                           id: "f1",
                           project_id: "proj-123",
                           org_id: "org-456",
                           memory_type: "document"
                         }
                       ]}
    end
  end

  describe "ADR-0042 soft-deprecation of :workspace_id" do
    defmodule QuietProvider do
      @behaviour Platform.Memory.Provider
      @impl true
      def ingest(_entries, _config), do: {:ok, 1}
      @impl true
      def search(_q, _o, _c), do: {:ok, []}
      @impl true
      def delete(_ids, _c), do: {:ok, 0}
      @impl true
      def health(_c), do: :ok
    end

    setup do
      Application.put_env(:platform, :memory_service, provider: QuietProvider)
      :ok
    end

    test "warns when an entry carries workspace_id without project_id" do
      log =
        capture_log(fn ->
          {:ok, 1} =
            Memory.ingest([
              %{
                id: "legacy-1",
                content: "body",
                date: "2026-06-18",
                workspace_id: "ws-abc"
              }
            ])
        end)

      assert log =~ "deprecated :workspace_id"
      assert log =~ "legacy-1"
    end

    test "does NOT warn when project_id accompanies workspace_id" do
      log =
        capture_log(fn ->
          {:ok, 1} =
            Memory.ingest([
              %{
                id: "modern-1",
                content: "body",
                date: "2026-06-18",
                workspace_id: "ws-abc",
                project_id: "proj-xyz"
              }
            ])
        end)

      refute log =~ "deprecated :workspace_id"
    end

    test "does NOT warn when no scoping key is provided at all" do
      log =
        capture_log(fn ->
          {:ok, 1} =
            Memory.ingest([
              %{id: "rootless", content: "body", date: "2026-06-18"}
            ])
        end)

      refute log =~ "deprecated :workspace_id"
    end
  end
end
