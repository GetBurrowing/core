defmodule Platform.Chat.CanvasDocument do
  @moduledoc """
  Canonical canvas document model.

  Every canvas that participates in the agent-driven canvas runtime stores a
  `CanvasDocument` in its `state` field instead of an ad-hoc per-type map.

  ## Document shape

      %{
        "version"  => 1,
        "kind"     => "ui",
        "revision" => 1,
        "root"     => %{
          "id"       => "root",
          "type"     => "stack",
          "props"    => %{"gap" => 12},
          "children" => []
        },
        "bindings" => %{},
        "meta"     => %{}
      }

  ## Node types

  The initial supported node types are: `stack`, `row`, `card`, `text`,
  `markdown`, `table`, `code`, `badge`, `heading`.

  Each node is a map with mandatory keys `"id"` and `"type"`, an optional
  `"props"` map, and an optional `"children"` list of child nodes.

  ## Seeded templates

  `seed/2` creates a fully-formed canonical document from common patterns so
  agents can produce real content without manually constructing the node tree.
  """

  @current_version 1
  @valid_kinds ~w(ui)
  @valid_node_types ~w(stack row card text markdown table code badge heading)

  @type document :: map()
  @type node_map :: map()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Create a blank canonical document with a root `stack` node.

      iex> doc = Platform.Chat.CanvasDocument.new()
      iex> doc["version"]
      1
      iex> doc["root"]["type"]
      "stack"
  """
  @spec new(binary()) :: document()
  def new(kind \\ "ui") do
    %{
      "version" => @current_version,
      "kind" => kind,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => []
      },
      "bindings" => %{},
      "meta" => %{}
    }
  end

  @doc """
  Validate a document map.

  Returns `{:ok, document}` when the document is structurally valid, or
  `{:error, reasons}` with a list of human-readable error strings.
  """
  @spec validate(document()) :: {:ok, document()} | {:error, [binary()]}
  def validate(document) when is_map(document) do
    errors =
      []
      |> check_version(document)
      |> check_kind(document)
      |> check_revision(document)
      |> check_root(document)
      |> check_bindings(document)
      |> check_meta(document)

    if errors == [] do
      {:ok, document}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  def validate(_document), do: {:error, ["document must be a map"]}

  @doc """
  Find a node anywhere in the document tree by its ID.

  Returns the node map, or `nil` if not found.
  """
  @spec get_node(document(), binary()) :: node_map() | nil
  def get_node(%{"root" => root}, node_id) when is_map(root) do
    find_node(root, node_id)
  end

  def get_node(_document, _node_id), do: nil

  @doc """
  Return the current revision number of the document.
  """
  @spec revision(document()) :: non_neg_integer()
  def revision(%{"revision" => rev}) when is_integer(rev), do: rev
  def revision(_document), do: 0

  @doc """
  Create a seeded canonical document from a named template and data.

  Supported templates:

  - `"table"` — `%{"columns" => [...], "rows" => [...]}`
  - `"code"`  — `%{"language" => "elixir", "source" => "..."}`
  - `"diagram"` — `%{"source" => "..."}`
  - `"dashboard"` — `%{"metrics" => [%{"label" => ..., "value" => ...}]}`

  Any unknown template type falls back to a blank document with the data
  stored in the root `meta` key.
  """
  @spec seed(binary(), map()) :: document()
  def seed(type, data \\ %{})

  def seed("table", data) when is_map(data) do
    columns = Map.get(data, "columns", [])
    rows = Map.get(data, "rows", [])

    table_node = %{
      "id" => "table-main",
      "type" => "table",
      "props" => %{
        "columns" => columns,
        "rows" => rows
      },
      "children" => []
    }

    doc = new("ui")

    put_in(doc, ["root", "children"], [table_node])
  end

  def seed("code", data) when is_map(data) do
    language = Map.get(data, "language", "text")
    source = Map.get(data, "source", Map.get(data, "content", ""))

    code_node = %{
      "id" => "code-main",
      "type" => "code",
      "props" => %{
        "language" => language,
        "source" => source
      },
      "children" => []
    }

    doc = new("ui")
    put_in(doc, ["root", "children"], [code_node])
  end

  def seed("diagram", data) when is_map(data) do
    source = Map.get(data, "source", "")
    title = Map.get(data, "diagram_title", "Diagram")

    heading_node = %{
      "id" => "diagram-heading",
      "type" => "heading",
      "props" => %{"level" => 3, "value" => title},
      "children" => []
    }

    markdown_node = %{
      "id" => "diagram-source",
      "type" => "markdown",
      "props" => %{"content" => "```mermaid\n#{source}\n```"},
      "children" => []
    }

    doc = new("ui")
    put_in(doc, ["root", "children"], [heading_node, markdown_node])
  end

  def seed("dashboard", data) when is_map(data) do
    metrics = Map.get(data, "metrics", [])

    metric_cards =
      metrics
      |> Enum.with_index()
      |> Enum.map(fn {metric, idx} ->
        label = Map.get(metric, "label", "Metric #{idx + 1}")
        value = to_string(Map.get(metric, "value", "—"))
        trend = Map.get(metric, "trend")

        children =
          [
            %{
              "id" => "metric-#{idx}-label",
              "type" => "badge",
              "props" => %{"value" => label},
              "children" => []
            },
            %{
              "id" => "metric-#{idx}-value",
              "type" => "text",
              "props" => %{"value" => value, "size" => "2xl", "weight" => "bold"},
              "children" => []
            }
          ] ++
            if trend do
              [
                %{
                  "id" => "metric-#{idx}-trend",
                  "type" => "text",
                  "props" => %{"value" => trend, "size" => "xs"},
                  "children" => []
                }
              ]
            else
              []
            end

        %{
          "id" => "metric-card-#{idx}",
          "type" => "card",
          "props" => %{},
          "children" => children
        }
      end)

    row_node = %{
      "id" => "metrics-row",
      "type" => "row",
      "props" => %{"gap" => 12},
      "children" => metric_cards
    }

    doc = new("ui")
    put_in(doc, ["root", "children"], [row_node])
  end

  def seed(_type, data) when is_map(data) do
    # Unknown type: blank document, store raw data in meta
    doc = new("ui")
    put_in(doc, ["meta"], data)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp find_node(%{"id" => id} = node, id), do: node

  defp find_node(%{"children" => children} = _node, target_id) when is_list(children) do
    Enum.find_value(children, &find_node(&1, target_id))
  end

  defp find_node(_node, _target_id), do: nil

  defp check_version(errors, %{"version" => v}) when is_integer(v) and v > 0, do: errors

  defp check_version(errors, _doc),
    do: ["\"version\" must be a positive integer" | errors]

  defp check_kind(errors, %{"kind" => kind}) when kind in @valid_kinds, do: errors

  defp check_kind(errors, _doc),
    do: ["\"kind\" must be one of: #{Enum.join(@valid_kinds, ", ")}" | errors]

  defp check_revision(errors, %{"revision" => rev}) when is_integer(rev) and rev > 0,
    do: errors

  defp check_revision(errors, _doc),
    do: ["\"revision\" must be a positive integer" | errors]

  defp check_root(errors, %{"root" => root}) when is_map(root) do
    errors
    |> check_node(root, "root")
  end

  defp check_root(errors, _doc), do: ["\"root\" must be a node map" | errors]

  defp check_node(errors, node, path) when is_map(node) do
    errors
    |> check_node_id(node, path)
    |> check_node_type(node, path)
    |> check_node_props(node, path)
    |> check_node_children(node, path)
  end

  defp check_node(errors, _node, path), do: ["node at #{path} must be a map" | errors]

  defp check_node_id(errors, %{"id" => id}, _path) when is_binary(id) and id != "",
    do: errors

  defp check_node_id(errors, _node, path),
    do: ["node at #{path} must have a non-empty string \"id\"" | errors]

  defp check_node_type(errors, %{"type" => type}, _path) when type in @valid_node_types,
    do: errors

  defp check_node_type(errors, %{"type" => type}, path),
    do: ["node at #{path} has unknown type \"#{type}\"" | errors]

  defp check_node_type(errors, _node, path),
    do: ["node at #{path} must have a \"type\" key" | errors]

  defp check_node_props(errors, %{"props" => props}, _path) when is_map(props), do: errors
  defp check_node_props(errors, node, _path) when not is_map_key(node, "props"), do: errors

  defp check_node_props(errors, _node, path),
    do: ["node at #{path} \"props\" must be a map" | errors]

  defp check_node_children(errors, %{"children" => children}, path) when is_list(children) do
    children
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {child, idx}, acc ->
      check_node(acc, child, "#{path}.children[#{idx}]")
    end)
  end

  defp check_node_children(errors, node, _path) when not is_map_key(node, "children"),
    do: errors

  defp check_node_children(errors, _node, path),
    do: ["node at #{path} \"children\" must be a list" | errors]

  defp check_bindings(errors, %{"bindings" => b}) when is_map(b), do: errors
  defp check_bindings(errors, _doc), do: ["\"bindings\" must be a map" | errors]

  defp check_meta(errors, %{"meta" => m}) when is_map(m), do: errors
  defp check_meta(errors, _doc), do: ["\"meta\" must be a map" | errors]
end
