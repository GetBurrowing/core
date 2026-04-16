defmodule Platform.Memory.ProviderTest do
  use ExUnit.Case, async: true

  alias Platform.Memory.Providers.Null

  describe "Null provider" do
    test "ingest/1 returns :ok" do
      assert :ok = Null.ingest(%{id: "test", content: "hello", memory_type: "daily"})
    end

    test "search/2 returns empty results" do
      assert {:ok, []} = Null.search("anything", [])
    end

    test "delete/1 returns :ok" do
      assert :ok = Null.delete("some-id")
    end
  end

  describe "Provider.configured/0" do
    test "returns Null provider by default in test" do
      assert Platform.Memory.Provider.configured() == Null
    end
  end
end
