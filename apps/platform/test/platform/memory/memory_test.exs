defmodule Platform.MemoryTest do
  use ExUnit.Case, async: false

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
        provider: Platform.Memory.Providers.StartupSuite
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
      struct = %Platform.Org.MemoryEntry{
        id: "01abc",
        content: "decision content",
        memory_type: "decision",
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
                           memory_type: "decision",
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
  end
end
