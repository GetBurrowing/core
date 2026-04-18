defmodule Platform.Chat.CanvasPatch do
  @moduledoc """
  Deterministic patch operations on `CanvasDocument` (ADR 0036).

  Each operation describes a single structural change. Successful application
  returns `{:ok, new_document}` with `revision` bumped by 1. Validation uses
  `Platform.Chat.Canvas.Kinds`, so patches that introduce malformed nodes or
  violate child-kind rules fail at this layer rather than at render time.

  ## Operations

      {:set_props, node_id, props}
      {:replace_children, node_id, children}
      {:append_child, node_id, child}
      {:delete_node, node_id}
      {:replace_document, document}

  Rebase-or-reject concurrency is implemented in `Platform.Chat.Canvas.Server`,
  not here. This module is pure document transformation.
  """

  alias Platform.Chat.CanvasDocument
  alias Platform.Chat.Canvas.Kinds

  @type operation ::
          {:set_props, binary(), map()}
          | {:replace_children, binary(), [map()]}
          | {:append_child, binary(), map()}
          | {:delete_node, binary()}
          | {:replace_document, map()}

  @doc "Apply a single operation to a document."
  @spec apply(CanvasDocument.document(), operation()) ::
          {:ok, CanvasDocument.document()} | {:error, binary()}
  def apply(document, operation)

  def apply(document, {:replace_document, new_doc}) when is_map(new_doc) do
    case CanvasDocument.validate(new_doc) do
      {:ok, _} ->
        next = CanvasDocument.revision(document) + 1
        {:ok, Map.put(new_doc, "revision", next)}

      {:error, reasons} ->
        {:error, "replace_document: #{Enum.join(reasons, "; ")}"}
    end
  end

  def apply(document, {:set_props, node_id, props})
      when is_binary(node_id) and is_map(props) do
    with {:ok, root} <- get_root(document),
         {:ok, _target} <- find_node(root, node_id) do
      new_root =
        update_node(root, node_id, fn node ->
          existing = Map.get(node, "props", %{})
          Map.put(node, "props", Map.merge(existing, props))
        end)

      case revalidate_node(new_root, node_id) do
        :ok -> {:ok, bump(put_in(document["root"], new_root))}
        {:error, reasons} -> {:error, "set_props: #{Enum.join(reasons, "; ")}"}
      end
    else
      {:error, reason} -> {:error, "set_props: #{reason}"}
    end
  end

  def apply(document, {:replace_children, node_id, children})
      when is_binary(node_id) and is_list(children) do
    with {:ok, root} <- get_root(document),
         {:ok, parent} <- find_node(root, node_id),
         :ok <- validate_children_list(parent, children) do
      new_root = update_node(root, node_id, &Map.put(&1, "children", children))
      {:ok, bump(put_in(document["root"], new_root))}
    else
      {:error, reason} -> {:error, "replace_children: #{reason}"}
    end
  end

  def apply(document, {:append_child, node_id, child})
      when is_binary(node_id) and is_map(child) do
    with {:ok, root} <- get_root(document),
         {:ok, parent} <- find_node(root, node_id),
         :ok <- validate_children_list(parent, [child]) do
      new_root =
        update_node(root, node_id, fn node ->
          existing = Map.get(node, "children", [])
          Map.put(node, "children", existing ++ [child])
        end)

      {:ok, bump(put_in(document["root"], new_root))}
    else
      {:error, reason} -> {:error, "append_child: #{reason}"}
    end
  end

  def apply(_document, {:delete_node, "root"}),
    do: {:error, "delete_node: cannot delete the root node"}

  def apply(document, {:delete_node, node_id}) when is_binary(node_id) do
    with {:ok, root} <- get_root(document) do
      case delete_from_tree(root, node_id) do
        {:ok, new_root} -> {:ok, bump(put_in(document["root"], new_root))}
        :not_found -> {:error, "delete_node: node \"#{node_id}\" not found"}
      end
    end
  end

  def apply(_document, op), do: {:error, "unsupported operation: #{inspect(op)}"}

  @doc "Apply a list of operations. Stops on first error."
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

  # ── Private ──

  defp get_root(%{"root" => root}) when is_map(root), do: {:ok, root}
  defp get_root(_), do: {:error, "document has no root"}

  defp find_node(root, node_id) do
    case do_find(root, node_id) do
      nil -> {:error, "node \"#{node_id}\" not found"}
      node -> {:ok, node}
    end
  end

  defp do_find(%{"id" => id} = node, id), do: node

  defp do_find(%{"children" => children}, target) when is_list(children),
    do: Enum.find_value(children, &do_find(&1, target))

  defp do_find(_, _), do: nil

  defp update_node(%{"id" => id} = node, id, fun), do: fun.(node)

  defp update_node(%{"children" => children} = node, target, fun) when is_list(children) do
    new_children = Enum.map(children, &update_node(&1, target, fun))
    %{node | "children" => new_children}
  end

  defp update_node(node, _target, _fun), do: node

  defp delete_from_tree(%{"children" => children} = node, node_id) when is_list(children) do
    cond do
      Enum.any?(children, &(Map.get(&1, "id") == node_id)) ->
        {:ok, Map.put(node, "children", Enum.reject(children, &(Map.get(&1, "id") == node_id)))}

      true ->
        walk_into_children(node, children, node_id)
    end
  end

  defp delete_from_tree(_, _), do: :not_found

  defp walk_into_children(node, children, node_id) do
    {result, new_children} =
      Enum.reduce(children, {:not_found, []}, fn child, {status, acc} ->
        case {status, delete_from_tree(child, node_id)} do
          {:not_found, {:ok, updated}} -> {:found, acc ++ [updated]}
          {_, _} -> {status, acc ++ [child]}
        end
      end)

    case result do
      :found -> {:ok, Map.put(node, "children", new_children)}
      :not_found -> :not_found
    end
  end

  defp bump(%{"revision" => r} = doc), do: %{doc | "revision" => r + 1}
  defp bump(doc), do: Map.put(doc, "revision", 1)

  defp revalidate_node(root, node_id) do
    case do_find(root, node_id) do
      nil -> :ok
      node -> Kinds.validate_node(node, node_id)
    end
  end

  defp validate_children_list(parent, children) do
    temp_parent = Map.put(parent, "children", children)

    case Kinds.validate_node(temp_parent, Map.get(parent, "id", "?")) do
      :ok -> :ok
      {:error, reasons} -> {:error, Enum.join(reasons, "; ")}
    end
  end
end
