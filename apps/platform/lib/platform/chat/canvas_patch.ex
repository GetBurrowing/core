defmodule Platform.Chat.CanvasPatch do
  @moduledoc """
  Deterministic patch operations for `CanvasDocument` mutation.

  Each patch operation is an Elixir tuple describing a single structural change.
  After a patch is applied, the document `revision` is incremented by 1.

  ## Operations

  - `{:set_props, node_id, props}` — deep-merge `props` into a node's existing props
  - `{:replace_children, node_id, children}` — replace all children of a node
  - `{:append_child, node_id, child}` — append a single child node
  - `{:delete_node, node_id}` — remove a node from the tree (cannot delete root)
  - `{:replace_document, document}` — wholesale replace the document (e.g. initial creation)

  ## Usage

      {:ok, updated} = CanvasPatch.apply(document, {:set_props, "title-node", %{"value" => "Hello"}})
      {:ok, final}   = CanvasPatch.apply_many(document, [op1, op2, op3])
  """

  alias Platform.Chat.CanvasDocument

  @type operation ::
          {:set_props, binary(), map()}
          | {:replace_children, binary(), [map()]}
          | {:append_child, binary(), map()}
          | {:delete_node, binary()}
          | {:replace_document, map()}

  @doc """
  Apply a single patch operation to a document.

  Returns `{:ok, new_document}` on success, or `{:error, reason}` on failure.
  The revision is incremented after a successful patch.
  """
  @spec apply(CanvasDocument.document(), operation()) ::
          {:ok, CanvasDocument.document()} | {:error, binary()}
  def apply(document, operation)

  def apply(document, {:replace_document, new_document}) when is_map(new_document) do
    case CanvasDocument.validate(new_document) do
      {:ok, _} ->
        # Preserve current revision + 1
        next_rev = CanvasDocument.revision(document) + 1
        {:ok, Map.put(new_document, "revision", next_rev)}

      {:error, reasons} ->
        {:error, "replace_document: invalid document — #{Enum.join(reasons, "; ")}"}
    end
  end

  def apply(document, {:set_props, node_id, props}) when is_binary(node_id) and is_map(props) do
    with {:ok, root} <- get_root(document),
         {:found, _node} <- find_node_check(root, node_id) do
      new_root =
        update_node(root, node_id, fn node ->
          existing_props = Map.get(node, "props", %{})
          Map.put(node, "props", Map.merge(existing_props, props))
        end)

      {:ok, bump_revision(put_in(document["root"], new_root))}
    else
      {:error, reason} -> {:error, "set_props: #{reason}"}
      {:not_found, _} -> {:error, "set_props: node \"#{node_id}\" not found"}
    end
  end

  def apply(document, {:replace_children, node_id, children})
      when is_binary(node_id) and is_list(children) do
    with {:ok, root} <- get_root(document),
         {:found, _node} <- find_node_check(root, node_id),
         :ok <- validate_children(children) do
      new_root = update_node(root, node_id, &Map.put(&1, "children", children))
      {:ok, bump_revision(put_in(document["root"], new_root))}
    else
      {:error, reason} -> {:error, "replace_children: #{reason}"}
      {:not_found, _} -> {:error, "replace_children: node \"#{node_id}\" not found"}
    end
  end

  def apply(document, {:append_child, node_id, child})
      when is_binary(node_id) and is_map(child) do
    with {:ok, root} <- get_root(document),
         {:found, _node} <- find_node_check(root, node_id),
         :ok <- validate_node(child) do
      new_root =
        update_node(root, node_id, fn node ->
          existing = Map.get(node, "children", [])
          Map.put(node, "children", existing ++ [child])
        end)

      {:ok, bump_revision(put_in(document["root"], new_root))}
    else
      {:error, reason} -> {:error, "append_child: #{reason}"}
      {:not_found, _} -> {:error, "append_child: parent node \"#{node_id}\" not found"}
    end
  end

  def apply(_document, {:delete_node, "root"}) do
    {:error, "delete_node: cannot delete the root node"}
  end

  def apply(document, {:delete_node, node_id}) when is_binary(node_id) do
    with {:ok, root} <- get_root(document) do
      case delete_node_from_tree(root, node_id) do
        {:ok, new_root} ->
          {:ok, bump_revision(put_in(document["root"], new_root))}

        {:not_found} ->
          {:error, "delete_node: node \"#{node_id}\" not found"}
      end
    end
  end

  def apply(_document, operation) do
    {:error, "unsupported operation: #{inspect(operation)}"}
  end

  @doc """
  Apply a list of patch operations in order.

  Stops and returns `{:error, reason}` on the first failure. On success,
  returns `{:ok, final_document}`.
  """
  @spec apply_many(CanvasDocument.document(), [operation()]) ::
          {:ok, CanvasDocument.document()} | {:error, binary()}
  def apply_many(document, operations) when is_list(operations) do
    Enum.reduce_while(operations, {:ok, document}, fn op, {:ok, doc} ->
      case __MODULE__.apply(doc, op) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_root(%{"root" => root}) when is_map(root), do: {:ok, root}
  defp get_root(_document), do: {:error, "document has no root node"}

  defp find_node_check(root, node_id) do
    case find_node(root, node_id) do
      nil -> {:not_found, node_id}
      node -> {:found, node}
    end
  end

  defp find_node(%{"id" => id} = node, id), do: node

  defp find_node(%{"children" => children}, target_id) when is_list(children) do
    Enum.find_value(children, &find_node(&1, target_id))
  end

  defp find_node(_node, _id), do: nil

  defp update_node(%{"id" => id} = node, id, fun), do: fun.(node)

  defp update_node(%{"children" => children} = node, target_id, fun) when is_list(children) do
    new_children = Enum.map(children, &update_node(&1, target_id, fun))
    %{node | "children" => new_children}
  end

  defp update_node(node, _target_id, _fun), do: node

  defp delete_node_from_tree(root, node_id) do
    # We cannot delete the root itself (handled above), so we walk the tree
    # looking for a parent whose children contain the target node.
    case delete_from_children(root, node_id) do
      {:ok, new_root} -> {:ok, new_root}
      :not_found -> {:not_found}
    end
  end

  defp delete_from_children(%{"children" => children} = node, node_id) when is_list(children) do
    if Enum.any?(children, &(Map.get(&1, "id") == node_id)) do
      new_children = Enum.reject(children, &(Map.get(&1, "id") == node_id))
      {:ok, Map.put(node, "children", new_children)}
    else
      case Enum.reduce_while(children, {:not_found, []}, fn child, {_status, acc} ->
             case delete_from_children(child, node_id) do
               {:ok, updated_child} -> {:halt, {:found, acc ++ [updated_child]}}
               :not_found -> {:cont, {:not_found, acc ++ [child]}}
             end
           end) do
        {:found, new_children} -> {:ok, Map.put(node, "children", new_children)}
        {:not_found, _} -> :not_found
      end
    end
  end

  defp delete_from_children(_node, _node_id), do: :not_found

  defp bump_revision(%{"revision" => rev} = doc), do: %{doc | "revision" => rev + 1}
  defp bump_revision(doc), do: Map.put(doc, "revision", 1)

  defp validate_node(node) when is_map(node) do
    # Light validation — just ensure required keys are present
    cond do
      not is_binary(Map.get(node, "id")) or Map.get(node, "id") == "" ->
        {:error, "child node must have a non-empty string \"id\""}

      not is_binary(Map.get(node, "type")) ->
        {:error, "child node must have a string \"type\""}

      true ->
        :ok
    end
  end

  defp validate_node(_node), do: {:error, "child node must be a map"}

  defp validate_children([]), do: :ok

  defp validate_children(children) when is_list(children) do
    Enum.reduce_while(children, :ok, fn child, :ok ->
      case validate_node(child) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
