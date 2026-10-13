defmodule Platform.Chat.CanvasRoom.Ops do
  @moduledoc """
  The fixed op set of a canvas room, as a PURE function over the room's
  state (task 01a1316b-84fa stage 1). No process, no Repo, no PubSub: the
  room (`Platform.Chat.CanvasRoom`) serialises calls to `apply/3` and owns
  everything with a side effect.

  ## State

      %{"keys" => %{key => value}, "collections" => %{name => [item]}}

  Every item carries an `"id"` (a UUIDv7 the room assigns on add). A
  collection keeps insertion order.

  ## Ops (string-keyed maps, the wire format)

    * `%{"type" => "state.set", "key" => k, "value" => v}` — a `nil` value
      deletes the key.
    * `%{"type" => "state.increment", "key" => k, "by" => n}` — `by` is an
      integer, default 1. A missing key counts as 0; a non-integer current
      value is `:not_a_number`.
    * `%{"type" => "collection.add", "name" => n, "item" => map}` — the id is
      assigned here and returned as the result.
    * `%{"type" => "collection.update", "name" => n, "id" => id, "patch" => map}`
      — shallow merge; the patch cannot change `"id"`.
    * `%{"type" => "collection.remove", "name" => n, "id" => id}`

  Any other `"type"` is `:unknown_op`. A known type with a malformed
  argument (a missing or non-string key, a non-integer `by`, a non-map item
  or patch) is `:invalid_op`. An update or remove of an id the collection
  does not hold is `:not_found`.

  ## Caps

  Over a cap is `:too_large` (bytes) or `:too_many` (counts), and the state
  is returned unchanged — `apply/3` never returns a partially applied state,
  on any error. The caps are module attributes, readable through `caps/0`.

  ## Result

  `{:ok, new_state, diff}`. `diff` is what the room broadcasts; its
  `"result"` entry is what the caller's promise resolves with (the new value
  for a key op, the item id for a collection op).
  """

  import Kernel, except: [apply: 3]

  @max_name_bytes 128
  @max_value_bytes 16_384
  @max_state_bytes 524_288
  @max_collections 50
  @max_items 1_000

  @op_types ~w(state.set state.increment collection.add collection.update collection.remove)

  @type state :: %{required(String.t()) => map()}
  @type code ::
          :unknown_op | :invalid_op | :not_a_number | :not_found | :too_large | :too_many

  @doc "The caps, for tests and docs."
  @spec caps() :: map()
  def caps do
    %{
      max_name_bytes: @max_name_bytes,
      max_value_bytes: @max_value_bytes,
      max_state_bytes: @max_state_bytes,
      max_collections: @max_collections,
      max_items: @max_items
    }
  end

  @doc "The op types this module accepts."
  @spec op_types() :: [String.t()]
  def op_types, do: @op_types

  @doc "An empty room state."
  @spec empty() :: state()
  def empty, do: %{"keys" => %{}, "collections" => %{}}

  @doc """
  Apply one op. `actor` is accepted for the handler seam's sake (a future
  engine hook sees who wrote) and is not read by the fixed op set.

  Returns `{:ok, new_state, diff}` or `{:error, code}`. `diff["result"]` is
  the value the caller resolves with.
  """
  @spec apply(state(), map(), map()) :: {:ok, state(), map()} | {:error, code()}
  def apply(state, op, _actor) when is_map(state) and is_map(op) do
    state = normalize(state)

    with {:ok, new_state, diff} <- do_apply(state, op),
         :ok <- check_state_size(new_state) do
      {:ok, new_state, diff}
    end
  end

  def apply(_state, _op, _actor), do: {:error, :invalid_op}

  # ── ops ─────────────────────────────────────────────────────────────────

  defp do_apply(state, %{"type" => "state.set"} = op) do
    with {:ok, key} <- name(op, "key"),
         {:ok, value} <- fetch(op, "value"),
         :ok <- check_value(value) do
      keys =
        if is_nil(value),
          do: Map.delete(state["keys"], key),
          else: Map.put(state["keys"], key, value)

      {:ok, %{state | "keys" => keys},
       %{"kind" => "key", "key" => key, "value" => value, "result" => value}}
    end
  end

  defp do_apply(state, %{"type" => "state.increment"} = op) do
    with {:ok, key} <- name(op, "key"),
         {:ok, by} <- increment_by(op),
         {:ok, current} <- current_integer(state["keys"], key) do
      value = current + by

      {:ok, %{state | "keys" => Map.put(state["keys"], key, value)},
       %{"kind" => "key", "key" => key, "value" => value, "result" => value}}
    end
  end

  defp do_apply(state, %{"type" => "collection.add"} = op) do
    with {:ok, name} <- name(op, "name"),
         {:ok, item} <- map_arg(op, "item"),
         items = Map.get(state["collections"], name),
         :ok <- check_collection_count(state["collections"], items),
         :ok <- check_item_count(items || []) do
      id = Platform.Types.UUIDv7.generate()
      item = Map.put(item, "id", id)

      with :ok <- check_value(item) do
        items = (items || []) ++ [item]

        {:ok, put_collection(state, name, items),
         %{
           "kind" => "collection",
           "name" => name,
           "op" => "add",
           "id" => id,
           "item" => item,
           "result" => id
         }}
      end
    end
  end

  defp do_apply(state, %{"type" => "collection.update"} = op) do
    with {:ok, name} <- name(op, "name"),
         {:ok, id} <- id_arg(op),
         {:ok, patch} <- map_arg(op, "patch"),
         {:ok, items, index} <- find_item(state, name, id) do
      item = items |> Enum.at(index) |> Map.merge(Map.delete(patch, "id"))

      with :ok <- check_value(item) do
        {:ok, put_collection(state, name, List.replace_at(items, index, item)),
         %{
           "kind" => "collection",
           "name" => name,
           "op" => "update",
           "id" => id,
           "item" => item,
           "result" => id
         }}
      end
    end
  end

  defp do_apply(state, %{"type" => "collection.remove"} = op) do
    with {:ok, name} <- name(op, "name"),
         {:ok, id} <- id_arg(op),
         {:ok, items, index} <- find_item(state, name, id) do
      {:ok, put_collection(state, name, List.delete_at(items, index)),
       %{
         "kind" => "collection",
         "name" => name,
         "op" => "remove",
         "id" => id,
         "item" => nil,
         "result" => id
       }}
    end
  end

  defp do_apply(_state, %{"type" => type}) when type in @op_types, do: {:error, :invalid_op}
  defp do_apply(_state, _op), do: {:error, :unknown_op}

  # ── arguments ───────────────────────────────────────────────────────────

  defp name(op, field) do
    case Map.get(op, field) do
      n when is_binary(n) and byte_size(n) > @max_name_bytes -> {:error, :too_large}
      n when is_binary(n) and n != "" -> {:ok, n}
      _ -> {:error, :invalid_op}
    end
  end

  defp fetch(op, field) do
    case Map.fetch(op, field) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, :invalid_op}
    end
  end

  defp increment_by(op) do
    case Map.get(op, "by", 1) do
      by when is_integer(by) -> {:ok, by}
      _ -> {:error, :invalid_op}
    end
  end

  defp current_integer(keys, key) do
    case Map.get(keys, key) do
      nil -> {:ok, 0}
      n when is_integer(n) -> {:ok, n}
      _ -> {:error, :not_a_number}
    end
  end

  defp map_arg(op, field) do
    case Map.get(op, field) do
      m when is_map(m) -> {:ok, m}
      _ -> {:error, :invalid_op}
    end
  end

  defp id_arg(op) do
    case Map.get(op, "id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :invalid_op}
    end
  end

  defp find_item(state, name, id) do
    items = Map.get(state["collections"], name, [])

    case Enum.find_index(items, &(&1["id"] == id)) do
      nil -> {:error, :not_found}
      index -> {:ok, items, index}
    end
  end

  defp put_collection(state, name, items),
    do: %{state | "collections" => Map.put(state["collections"], name, items)}

  # ── caps ────────────────────────────────────────────────────────────────

  defp check_value(value) do
    case encoded_size(value) do
      {:ok, size} when size <= @max_value_bytes -> :ok
      {:ok, _} -> {:error, :too_large}
      :error -> {:error, :invalid_op}
    end
  end

  defp check_state_size(state) do
    case encoded_size(state) do
      {:ok, size} when size <= @max_state_bytes -> :ok
      {:ok, _} -> {:error, :too_large}
      :error -> {:error, :invalid_op}
    end
  end

  # A new collection is the 51st only when the name is not already there.
  defp check_collection_count(collections, nil) when map_size(collections) >= @max_collections,
    do: {:error, :too_many}

  defp check_collection_count(_collections, _items), do: :ok

  defp check_item_count(items) when length(items) >= @max_items, do: {:error, :too_many}
  defp check_item_count(_items), do: :ok

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, byte_size(json)}
      {:error, _} -> :error
    end
  end

  defp normalize(state) do
    %{
      "keys" => Map.get(state, "keys") || %{},
      "collections" => Map.get(state, "collections") || %{}
    }
  end
end
