defmodule Platform.Context.CacheTest do
  @moduledoc """
  Tests for Platform.Context.Cache: ETS-backed hot cache, delta fanout,
  ack tracking, and eviction.
  """
  use ExUnit.Case, async: false

  alias Platform.Context.{Cache, Delta, Item, Session}

  # We need the Cache GenServer running. In tests we start it directly
  # unless the full application is booted (which it is via test_helper).

  # Generate unique scope keys per test to avoid collision between async tests
  defp unique_scope(prefix \\ "test") do
    "#{prefix}/#{System.unique_integer([:positive, :monotonic])}"
  end

  defp make_scope_from_key(key) do
    # Build a minimal scope that yields the given key
    # key format: "task_id" for single-part scopes
    %Session.Scope{task_id: key}
  end

  defp create_session!(scope_or_key) when is_binary(scope_or_key) do
    scope = make_scope_from_key(scope_or_key)
    {:ok, session} = Cache.create_session(scope)
    session
  end

  defp create_session!(%Session.Scope{} = scope) do
    {:ok, session} = Cache.create_session(scope)
    session
  end

  # ---------------------------------------------------------------------------
  # Session creation
  # ---------------------------------------------------------------------------

  describe "create_session/1" do
    test "creates a new session at version 0" do
      scope = %Session.Scope{task_id: unique_scope("create")}
      {:ok, session} = Cache.create_session(scope)

      assert session.version == 0
      assert session.required_version == 0
      assert %Session.Scope{} = session.scope
    end

    test "is idempotent — returns same session on repeated calls" do
      scope = %Session.Scope{task_id: unique_scope("idem")}
      {:ok, s1} = Cache.create_session(scope)
      {:ok, s2} = Cache.create_session(scope)

      assert s1.inserted_at == s2.inserted_at
    end

    test "scoped to full hierarchy" do
      scope = %Session.Scope{
        project_id: "proj-1",
        epic_id: "epic-1",
        task_id: unique_scope("hier"),
        run_id: "run-1"
      }

      {:ok, session} = Cache.create_session(scope)
      assert session.scope.project_id == "proj-1"
      assert session.scope.run_id == "run-1"
    end
  end

  # ---------------------------------------------------------------------------
  # Item operations
  # ---------------------------------------------------------------------------

  describe "put_item/4 and get_item/2" do
    test "puts an item and retrieves it" do
      key = unique_scope("item")
      _session = create_session!(key)

      {:ok, version} = Cache.put_item(key, "greeting", "hello")

      assert version == 1
      item = Cache.get_item(key, "greeting")
      assert %Item{key: "greeting", value: "hello", version: 1} = item
    end

    test "upserts — second put overwrites value and bumps version" do
      key = unique_scope("upsert")
      _session = create_session!(key)

      {:ok, v1} = Cache.put_item(key, "x", "first")
      {:ok, v2} = Cache.put_item(key, "x", "second")

      assert v1 == 1
      assert v2 == 2

      item = Cache.get_item(key, "x")
      assert item.value == "second"
      assert item.version == 2
    end

    test "returns error for unknown scope" do
      assert {:error, :not_found} = Cache.put_item("nonexistent/scope/key", "k", "v")
    end
  end

  describe "delete_item/2" do
    test "deletes an existing item and bumps version" do
      key = unique_scope("del")
      _session = create_session!(key)

      {:ok, _v1} = Cache.put_item(key, "to_delete", "gone")
      {:ok, v2} = Cache.delete_item(key, "to_delete")

      assert v2 == 2
      assert Cache.get_item(key, "to_delete") == nil
    end

    test "delete on missing key still bumps version" do
      key = unique_scope("delmiss")
      _session = create_session!(key)

      {:ok, v1} = Cache.delete_item(key, "never_existed")
      assert v1 == 1
    end
  end

  describe "all_items/1" do
    test "returns all items sorted by key" do
      key = unique_scope("all")
      _session = create_session!(key)

      Cache.put_item(key, "c", 3)
      Cache.put_item(key, "a", 1)
      Cache.put_item(key, "b", 2)

      items = Cache.all_items(key)
      assert Enum.map(items, & &1.key) == ["a", "b", "c"]
    end

    test "returns empty list for session with no items" do
      key = unique_scope("empty_items")
      _session = create_session!(key)
      assert Cache.all_items(key) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Delta operations
  # ---------------------------------------------------------------------------

  describe "apply_delta/2" do
    test "applies puts and deletes atomically, bumps version" do
      key = unique_scope("delta")
      _session = create_session!(key)

      # Seed an item to delete
      Cache.put_item(key, "old", "value")

      delta = %Delta{
        scope_key: key,
        version: 0,
        puts: %{"new_key" => {"new_value", []}},
        deletes: ["old"]
      }

      {:ok, version} = Cache.apply_delta(key, delta)
      assert version == 2

      assert Cache.get_item(key, "new_key").value == "new_value"
      assert Cache.get_item(key, "old") == nil
    end

    test "returns error for unknown scope" do
      delta = %Delta{scope_key: "bad/scope", version: 0, puts: %{}, deletes: []}
      assert {:error, :not_found} = Cache.apply_delta("bad/scope", delta)
    end
  end

  describe "deltas_since/2" do
    test "returns only deltas with version > since" do
      key = unique_scope("dsince")
      _session = create_session!(key)

      # version 1
      Cache.put_item(key, "a", 1)
      # version 2
      Cache.put_item(key, "b", 2)
      # version 3
      Cache.put_item(key, "c", 3)

      deltas = Cache.deltas_since(key, 1)
      assert length(deltas) == 2
      assert Enum.all?(deltas, fn d -> d.version > 1 end)
    end

    test "returns all deltas when since=0" do
      key = unique_scope("dall")
      _session = create_session!(key)

      Cache.put_item(key, "a", 1)
      Cache.put_item(key, "b", 2)

      deltas = Cache.deltas_since(key, 0)
      assert length(deltas) == 2
    end

    test "returns empty list for unknown scope" do
      assert Cache.deltas_since("gone/scope", 0) == []
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub fanout
  # ---------------------------------------------------------------------------

  describe "PubSub fanout" do
    test "broadcasts :context_delta on put_item" do
      key = unique_scope("pubsub_put")
      _session = create_session!(key)

      Phoenix.PubSub.subscribe(Platform.PubSub, "ctx:#{key}")

      Cache.put_item(key, "x", "y")

      assert_receive {:context_delta, %Delta{version: 1, puts: puts}}
      assert Map.has_key?(puts, "x")
    end

    test "broadcasts :context_delta on apply_delta" do
      key = unique_scope("pubsub_delta")
      _session = create_session!(key)

      Phoenix.PubSub.subscribe(Platform.PubSub, "ctx:#{key}")

      delta = %Delta{
        scope_key: key,
        version: 0,
        puts: %{"foo" => {"bar", []}},
        deletes: []
      }

      Cache.apply_delta(key, delta)

      assert_receive {:context_delta, %Delta{version: 1}}
    end

    test "broadcasts :context_delta on delete_item" do
      key = unique_scope("pubsub_del")
      _session = create_session!(key)
      Cache.put_item(key, "x", "y")

      Phoenix.PubSub.subscribe(Platform.PubSub, "ctx:#{key}")

      Cache.delete_item(key, "x")

      assert_receive {:context_delta, %Delta{deletes: ["x"]}}
    end
  end

  # ---------------------------------------------------------------------------
  # Acknowledgement tracking
  # ---------------------------------------------------------------------------

  describe "record_ack/3 and get_ack/2" do
    test "records and retrieves ack version" do
      key = unique_scope("ack")
      _session = create_session!(key)

      :ok = Cache.record_ack(key, "run-abc", 5)
      assert Cache.get_ack(key, "run-abc") == 5
    end

    test "updates ack for same run_id" do
      key = unique_scope("ack_update")
      _session = create_session!(key)

      Cache.record_ack(key, "run-1", 3)
      Cache.record_ack(key, "run-1", 7)

      assert Cache.get_ack(key, "run-1") == 7
    end

    test "returns nil for unacked run" do
      key = unique_scope("ack_nil")
      _session = create_session!(key)

      assert Cache.get_ack(key, "run-unknown") == nil
    end

    test "returns error for unknown scope" do
      assert {:error, :not_found} = Cache.record_ack("nope/scope", "run-1", 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Eviction
  # ---------------------------------------------------------------------------

  describe "evict/1" do
    test "removes session, items, deltas, and acks" do
      key = unique_scope("evict")
      _session = create_session!(key)

      Cache.put_item(key, "k", "v")
      Cache.record_ack(key, "run-1", 1)

      :ok = Cache.evict(key)

      assert {:error, :not_found} = Cache.get_session(key)
      assert Cache.all_items(key) == []
      assert Cache.deltas_since(key, 0) == []
      assert Cache.get_ack(key, "run-1") == nil
    end

    test "evicting unknown scope is a no-op" do
      :ok = Cache.evict("totally/unknown/scope/xyz")
    end
  end

  # ---------------------------------------------------------------------------
  # Session version tracking
  # ---------------------------------------------------------------------------

  describe "session version" do
    test "version increments on each write" do
      key = unique_scope("version")
      _session = create_session!(key)

      {:ok, v1} = Cache.put_item(key, "a", 1)
      {:ok, v2} = Cache.put_item(key, "b", 2)
      {:ok, v3} = Cache.delete_item(key, "a")

      assert [v1, v2, v3] == [1, 2, 3]

      {:ok, session} = Cache.get_session(key)
      assert session.version == 3
    end
  end
end
