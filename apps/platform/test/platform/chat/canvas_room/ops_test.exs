defmodule Platform.Chat.CanvasRoom.OpsTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.CanvasRoom.Ops

  @actor %{type: "user", id: "u1", display_name: "U"}

  defp run(state, op), do: Ops.apply(state, op, @actor)

  defp ok!(state, op) do
    {:ok, new_state, diff} = run(state, op)
    {new_state, diff}
  end

  defp seeded do
    {s, _} = ok!(Ops.empty(), %{"type" => "state.set", "key" => "n", "value" => 3})

    {s, %{"result" => id}} =
      ok!(s, %{"type" => "collection.add", "name" => "c", "item" => %{"a" => 1}})

    {s, id}
  end

  describe "state.set" do
    test "sets and replaces a key" do
      {s, diff} = ok!(Ops.empty(), %{"type" => "state.set", "key" => "k", "value" => %{"x" => 1}})
      assert s["keys"] == %{"k" => %{"x" => 1}}

      assert diff == %{
               "kind" => "key",
               "key" => "k",
               "value" => %{"x" => 1},
               "result" => %{"x" => 1}
             }

      {s, _} = ok!(s, %{"type" => "state.set", "key" => "k", "value" => "y"})
      assert s["keys"] == %{"k" => "y"}
    end

    test "a nil value deletes the key" do
      {s, _} = seeded()
      {s, diff} = ok!(s, %{"type" => "state.set", "key" => "n", "value" => nil})
      refute Map.has_key?(s["keys"], "n")
      assert diff["value"] == nil
    end

    test "a missing value is invalid" do
      assert {:error, :invalid_op} = run(Ops.empty(), %{"type" => "state.set", "key" => "k"})
    end
  end

  describe "state.increment" do
    test "a missing key counts as 0 and by defaults to 1" do
      {s, diff} = ok!(Ops.empty(), %{"type" => "state.increment", "key" => "n"})
      assert s["keys"]["n"] == 1
      assert diff["result"] == 1
    end

    test "adds an integer by, negative included" do
      {s, _} = seeded()
      {s, _} = ok!(s, %{"type" => "state.increment", "key" => "n", "by" => 5})
      {s, _} = ok!(s, %{"type" => "state.increment", "key" => "n", "by" => -2})
      assert s["keys"]["n"] == 6
    end

    test "a non-integer current value is :not_a_number" do
      {s, _} = ok!(Ops.empty(), %{"type" => "state.set", "key" => "n", "value" => "x"})
      assert {:error, :not_a_number} = run(s, %{"type" => "state.increment", "key" => "n"})
      {s, _} = ok!(Ops.empty(), %{"type" => "state.set", "key" => "n", "value" => 1.5})
      assert {:error, :not_a_number} = run(s, %{"type" => "state.increment", "key" => "n"})
    end

    test "a non-integer by is invalid" do
      assert {:error, :invalid_op} =
               run(Ops.empty(), %{"type" => "state.increment", "key" => "n", "by" => 1.5})
    end
  end

  describe "collections" do
    test "add assigns a UUIDv7 id and returns it" do
      {s, diff} =
        ok!(Ops.empty(), %{"type" => "collection.add", "name" => "c", "item" => %{"a" => 1}})

      id = diff["result"]
      assert Platform.UUID.valid?(id)
      assert <<_::binary-size(14), "7", _::binary>> = id
      assert s["collections"]["c"] == [%{"a" => 1, "id" => id}]
      assert diff["op"] == "add" and diff["item"]["id"] == id
    end

    test "add keeps insertion order" do
      {s, _} = seeded()
      {s, _} = ok!(s, %{"type" => "collection.add", "name" => "c", "item" => %{"a" => 2}})
      assert Enum.map(s["collections"]["c"], & &1["a"]) == [1, 2]
    end

    test "update shallow-merges and cannot change the id" do
      {s, id} = seeded()

      {s, diff} =
        ok!(s, %{
          "type" => "collection.update",
          "name" => "c",
          "id" => id,
          "patch" => %{"b" => 2, "id" => "forged"}
        })

      assert s["collections"]["c"] == [%{"a" => 1, "b" => 2, "id" => id}]
      assert diff["op"] == "update"
    end

    test "remove deletes the item" do
      {s, id} = seeded()
      {s, diff} = ok!(s, %{"type" => "collection.remove", "name" => "c", "id" => id})
      assert s["collections"]["c"] == []
      assert diff["op"] == "remove" and diff["id"] == id
    end

    test "update and remove of an unknown id are :not_found" do
      {s, _} = seeded()

      assert {:error, :not_found} =
               run(s, %{"type" => "collection.update", "name" => "c", "id" => "x", "patch" => %{}})

      assert {:error, :not_found} =
               run(s, %{"type" => "collection.remove", "name" => "zz", "id" => "x"})
    end

    test "a non-map item or patch is invalid" do
      {s, id} = seeded()

      assert {:error, :invalid_op} =
               run(s, %{"type" => "collection.add", "name" => "c", "item" => 1})

      assert {:error, :invalid_op} =
               run(s, %{"type" => "collection.update", "name" => "c", "id" => id, "patch" => [1]})
    end
  end

  describe "error codes" do
    test "an unknown type is :unknown_op" do
      assert {:error, :unknown_op} = run(Ops.empty(), %{"type" => "state.delete_all"})
      assert {:error, :unknown_op} = run(Ops.empty(), %{"key" => "k"})
    end

    test "a missing or non-string key is :invalid_op" do
      assert {:error, :invalid_op} = run(Ops.empty(), %{"type" => "state.set", "value" => 1})

      assert {:error, :invalid_op} =
               run(Ops.empty(), %{"type" => "state.set", "key" => 1, "value" => 1})

      assert {:error, :invalid_op} =
               run(Ops.empty(), %{"type" => "state.set", "key" => "", "value" => 1})
    end
  end

  describe "caps (state unchanged on every error)" do
    setup do
      {s, id} = seeded()
      %{state: s, id: id, caps: Ops.caps()}
    end

    # Values are immutable, so "state unchanged" means: the refusal is an
    # error tuple carrying NO state, never `{:ok, partially_applied, _}`. The
    # caller (the room) keeps its own state on an error.
    defp assert_refused(state, op, code) do
      before = state
      assert {:error, ^code} = run(state, op)
      assert state == before
    end

    test "a key over max_name_bytes is :too_large; at the cap it is accepted", %{
      state: s,
      caps: caps
    } do
      at_cap = String.duplicate("k", caps.max_name_bytes)
      assert {:ok, _, _} = run(s, %{"type" => "state.set", "key" => at_cap, "value" => 1})

      assert_refused(
        s,
        %{"type" => "state.set", "key" => at_cap <> "k", "value" => 1},
        :too_large
      )
    end

    test "a collection name over max_name_bytes is :too_large", %{state: s, caps: caps} do
      name = String.duplicate("c", caps.max_name_bytes + 1)
      assert_refused(s, %{"type" => "collection.add", "name" => name, "item" => %{}}, :too_large)
    end

    test "a value over max_value_bytes is :too_large", %{state: s, caps: caps} do
      big = String.duplicate("v", caps.max_value_bytes)
      assert_refused(s, %{"type" => "state.set", "key" => "k", "value" => big}, :too_large)

      # Encoded JSON is the measure: the quotes push a cap-2 string to exactly the cap.
      fits = String.duplicate("v", caps.max_value_bytes - 2)
      assert {:ok, _, _} = run(s, %{"type" => "state.set", "key" => "k", "value" => fits})
    end

    test "an item over max_value_bytes is :too_large on add and on update", %{
      state: s,
      id: id,
      caps: caps
    } do
      big = String.duplicate("v", caps.max_value_bytes)

      assert_refused(
        s,
        %{"type" => "collection.add", "name" => "c", "item" => %{"b" => big}},
        :too_large
      )

      assert_refused(
        s,
        %{"type" => "collection.update", "name" => "c", "id" => id, "patch" => %{"b" => big}},
        :too_large
      )
    end

    test "a whole state over max_state_bytes is :too_large", %{caps: caps} do
      chunk = String.duplicate("v", caps.max_value_bytes - 100)
      count = div(caps.max_state_bytes, caps.max_value_bytes - 100)

      s =
        Enum.reduce(1..count, Ops.empty(), fn i, s ->
          {:ok, s, _} = run(s, %{"type" => "state.set", "key" => "k#{i}", "value" => chunk})
          s
        end)

      assert byte_size(Jason.encode!(s)) <= caps.max_state_bytes

      assert_refused(
        s,
        %{"type" => "state.set", "key" => "one_more", "value" => chunk},
        :too_large
      )
    end

    test "the 51st collection is :too_many; adding to an existing one is not", %{caps: caps} do
      s =
        Enum.reduce(1..caps.max_collections, Ops.empty(), fn i, s ->
          {:ok, s, _} = run(s, %{"type" => "collection.add", "name" => "c#{i}", "item" => %{}})
          s
        end)

      assert_refused(s, %{"type" => "collection.add", "name" => "new", "item" => %{}}, :too_many)
      assert {:ok, _, _} = run(s, %{"type" => "collection.add", "name" => "c1", "item" => %{}})
    end

    test "the 1001st item is :too_many", %{caps: caps} do
      s =
        Enum.reduce(1..caps.max_items, Ops.empty(), fn _, s ->
          {:ok, s, _} = run(s, %{"type" => "collection.add", "name" => "c", "item" => %{}})
          s
        end)

      assert length(s["collections"]["c"]) == caps.max_items
      assert_refused(s, %{"type" => "collection.add", "name" => "c", "item" => %{}}, :too_many)
    end

    test "the caps are the spec's numbers", %{caps: caps} do
      assert caps == %{
               max_name_bytes: 128,
               max_value_bytes: 16_384,
               max_state_bytes: 524_288,
               max_collections: 50,
               max_items: 1_000
             }
    end
  end
end
