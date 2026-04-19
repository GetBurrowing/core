defmodule Platform.Chat.Canvas.Kinds do
  @moduledoc """
  Registry of canvas node kinds (ADR 0036).

  Single source of truth. Tool schemas, patch validation, and renderer dispatch
  all read from here. Adding a new kind is a two-step operation: create the
  module under `Platform.Chat.Canvas.Kinds.*` and list it in `@modules`.
  """

  alias Platform.Chat.Canvas.Kind

  alias Platform.Chat.Canvas.Kinds.{
    Stack,
    Row,
    Card,
    Text,
    Markdown,
    Heading,
    Badge,
    Image,
    Code,
    Mermaid,
    Form,
    ActionRow,
    Checklist,
    ChecklistItem,
    Table
  }

  @modules [
    Stack,
    Row,
    Card,
    Text,
    Markdown,
    Heading,
    Badge,
    Image,
    Code,
    Mermaid,
    Form,
    ActionRow,
    Checklist,
    ChecklistItem,
    Table
  ]

  @doc "Returns all registered kind modules."
  @spec all() :: [module()]
  def all, do: @modules

  @doc "Returns a map from kind name to kind module."
  @spec by_name() :: %{String.t() => module()}
  def by_name do
    Map.new(@modules, fn mod -> {mod.name(), mod} end)
  end

  @doc "Returns the module that implements `name`, or `nil` if unknown."
  @spec get(String.t()) :: module() | nil
  def get(name) when is_binary(name), do: Map.get(by_name(), name)
  def get(_), do: nil

  @doc "Returns true when `name` is a known kind."
  @spec kind?(String.t()) :: boolean()
  def kind?(name), do: Map.has_key?(by_name(), name)

  @doc "Returns the list of known kind names."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@modules, & &1.name())

  @doc """
  Ergonomic kind summaries for agent-facing discovery tools.

  Each entry bundles the essentials an agent needs to emit a valid node of
  this kind without parsing the recursive JSON Schema: a one-line
  description, the child rule, a props-summary map ({name => brief}), and
  an example node. Intended for `canvas.list_kinds` and prescriptive
  validation error payloads.
  """
  @spec summaries() :: [map()]
  def summaries do
    Enum.map(@modules, fn mod ->
      name = mod.name()

      %{
        kind: name,
        description: describe(name),
        accepts_children: children_rule(mod.children()),
        props: props_summary(mod.schema(), mod.styling()),
        example: example_node(mod, name)
      }
    end)
  end

  defp describe("stack"), do: "Vertical flex container. Accepts any children."
  defp describe("row"), do: "Horizontal flex container. Accepts any children."
  defp describe("card"), do: "Bordered card with optional title. Accepts any children."
  defp describe("text"), do: "Plain text leaf with size/weight styling."
  defp describe("markdown"), do: "Pre-formatted text/markdown content leaf."
  defp describe("heading"), do: "H1–H4 heading."
  defp describe("badge"), do: "Small rounded label."
  defp describe("image"), do: "Image leaf. Requires `src`."
  defp describe("code"), do: "Syntax-highlighted code block. Requires `source`."
  defp describe("mermaid"), do: "Mermaid diagram (client-side rendered)."
  defp describe("table"), do: "Tabular data. `columns` + `rows` as props; no children."
  defp describe("form"), do: "Form with inline fields. Emits a `submitted` event on send."

  defp describe("action_row"),
    do: "Horizontal row of action buttons, each emitting an `action` event."

  defp describe("checklist"), do: "Titled checklist. Children must be `checklist_item` nodes."
  defp describe("checklist_item"), do: "Single checklist row."
  defp describe(_), do: ""

  defp children_rule(:none), do: "none"
  defp children_rule(:any), do: "any"
  defp children_rule(list) when is_list(list), do: Enum.join(list, ", ")

  defp props_summary(schema, styling) do
    required =
      Map.get(schema, "required", []) ++ Map.get(styling, "required", [])

    props_map =
      Map.merge(
        Map.get(schema, "properties", %{}),
        Map.get(styling, "properties", %{})
      )

    Map.new(props_map, fn {k, p} -> {k, brief(p, k in required)} end)
  end

  defp brief(%{"type" => "integer"} = p, required?) do
    range =
      case {p["minimum"], p["maximum"]} do
        {nil, nil} -> ""
        {lo, nil} -> " (>= #{lo})"
        {nil, hi} -> " (<= #{hi})"
        {lo, hi} -> " (#{lo}–#{hi})"
      end

    marker(required?) <> "integer" <> range
  end

  defp brief(%{"type" => "string", "enum" => values}, required?) do
    marker(required?) <> "string: " <> Enum.join(values, " | ")
  end

  defp brief(%{"type" => "string"}, required?), do: marker(required?) <> "string"
  defp brief(%{"type" => "boolean"}, required?), do: marker(required?) <> "boolean"

  defp brief(%{"type" => "array", "items" => items}, required?) do
    item_type = Map.get(items, "type", "object")
    marker(required?) <> "array of " <> item_type
  end

  defp brief(%{"type" => "object"}, required?), do: marker(required?) <> "object"
  defp brief(%{"type" => type}, required?), do: marker(required?) <> to_string(type)
  defp brief(_, required?), do: marker(required?) <> "any"

  defp marker(true), do: "required, "
  defp marker(false), do: ""

  defp example_node(mod, name) do
    node = %{
      "id" => "example-#{name}",
      "type" => name,
      "props" => mod.defaults(),
      "children" => example_children(mod.children())
    }

    case mod.children() do
      :none -> Map.delete(node, "children")
      _ -> node
    end
    |> fill_required_props(mod.schema())
  end

  defp example_children(:none), do: []
  defp example_children(:any), do: []

  defp example_children(whitelist) when is_list(whitelist) do
    Enum.map(whitelist, fn child_kind ->
      case get(child_kind) do
        nil ->
          %{"id" => "child", "type" => child_kind, "props" => %{}, "children" => []}

        mod ->
          example_node(mod, child_kind)
      end
    end)
  end

  defp fill_required_props(node, schema) do
    required = Map.get(schema, "required", [])
    props = node["props"] || %{}

    filled =
      Enum.reduce(required, props, fn key, acc ->
        Map.put_new(acc, key, placeholder_for(schema, key))
      end)

    Map.put(node, "props", filled)
  end

  defp placeholder_for(schema, key) do
    prop = get_in(schema, ["properties", key]) || %{}

    case prop do
      %{"enum" => [first | _]} -> first
      %{"type" => "integer"} -> 1
      %{"type" => "boolean"} -> false
      %{"type" => "array"} -> []
      %{"type" => "object"} -> %{}
      %{"type" => "string"} -> "example-#{key}"
      _ -> "example-#{key}"
    end
  end

  @doc """
  Build JSON Schema definitions for every kind. Keyed by kind name, each entry
  is a JSON Schema `object` describing that kind's node shape (id, type, props,
  children).
  """
  @spec tool_schemas() :: %{String.t() => map()}
  def tool_schemas do
    Map.new(@modules, fn mod ->
      {mod.name(), node_schema(mod)}
    end)
  end

  defp node_schema(mod) do
    name = mod.name()
    props_schema = mod.schema()
    styling_schema = mod.styling()

    merged_props =
      deep_merge_schemas(props_schema, styling_schema)

    children_schema = children_schema(mod)

    base = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["id", "type"],
      "properties" =>
        %{
          "id" => %{"type" => "string", "minLength" => 1},
          "type" => %{"const" => name},
          "props" => merged_props
        }
        |> then(fn props ->
          if children_schema, do: Map.put(props, "children", children_schema), else: props
        end)
    }

    base
  end

  defp children_schema(mod) do
    case mod.children() do
      :none ->
        nil

      :any ->
        %{
          "type" => "array",
          "items" => %{"$ref" => "#/definitions/node"}
        }

      whitelist when is_list(whitelist) ->
        %{
          "type" => "array",
          "items" => %{
            "oneOf" =>
              Enum.map(whitelist, fn kind_name ->
                %{"$ref" => "#/definitions/kind_#{kind_name}"}
              end)
          }
        }
    end
  end

  defp deep_merge_schemas(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn
      "properties", av, bv when is_map(av) and is_map(bv) -> Map.merge(av, bv)
      "required", av, bv when is_list(av) and is_list(bv) -> Enum.uniq(av ++ bv)
      _k, _av, bv -> bv
    end)
  end

  @doc """
  Validate a node map against its kind.

  Returns `:ok` or `{:error, [reason]}`.
  """
  @spec validate_node(map(), String.t() | nil) :: :ok | {:error, [String.t()]}
  def validate_node(node, path \\ "root")

  def validate_node(node, path) when is_map(node) do
    with :ok <- validate_id(node, path),
         {:ok, mod} <- validate_type(node, path),
         :ok <- validate_props(mod, node, path),
         :ok <- validate_children(mod, node, path) do
      :ok
    end
  end

  def validate_node(_node, path), do: {:error, ["node at #{path} must be a map"]}

  defp validate_id(%{"id" => id}, _path) when is_binary(id) and id != "", do: :ok

  defp validate_id(_node, path),
    do: {:error, ["node at #{path} must have a non-empty string \"id\""]}

  defp validate_type(%{"type" => type}, path) do
    case get(type) do
      nil -> {:error, ["node at #{path} has unknown kind \"#{type}\""]}
      mod -> {:ok, mod}
    end
  end

  defp validate_type(_node, path),
    do: {:error, ["node at #{path} must have a \"type\" key"]}

  defp validate_props(_mod, %{} = node, _path) when not is_map_key(node, "props"), do: :ok
  defp validate_props(_mod, %{"props" => props}, _path) when is_map(props), do: :ok

  defp validate_props(_mod, _node, path),
    do: {:error, ["node at #{path} \"props\" must be a map"]}

  defp validate_children(mod, node, path) do
    case {mod.children(), Map.get(node, "children")} do
      {_rule, nil} ->
        :ok

      {_rule, []} ->
        :ok

      {:none, children} when is_list(children) and children != [] ->
        {:error, ["node at #{path} (kind \"#{mod.name()}\") does not accept children"]}

      {_rule, children} when not is_list(children) ->
        {:error, ["node at #{path} \"children\" must be a list"]}

      {:any, children} ->
        validate_child_list(children, path, fn _ -> :ok end)

      {whitelist, children} when is_list(whitelist) ->
        validate_child_list(children, path, fn %{"type" => t} = _child ->
          if t in whitelist,
            do: :ok,
            else: {:error, ["kind \"#{t}\" not allowed as child of \"#{mod.name()}\""]}
        end)
    end
  end

  defp validate_child_list(children, path, per_child_rule) do
    children
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {child, idx}, :ok ->
      child_path = "#{path}.children[#{idx}]"

      with :ok <- run_rule(per_child_rule, child, child_path),
           :ok <- validate_node(child, child_path) do
        {:cont, :ok}
      else
        {:error, reasons} -> {:halt, {:error, reasons}}
      end
    end)
  end

  defp run_rule(rule, child, _path) when is_map(child) do
    case rule.(child) do
      :ok -> :ok
      {:error, reasons} -> {:error, reasons}
    end
  end

  defp run_rule(_rule, _child, path),
    do: {:error, ["child at #{path} must be a map"]}

  @doc """
  Ensure a kind module conforms to the Kind behaviour at compile time.
  Used by tests.
  """
  @spec behaviour_ok?(module()) :: boolean()
  def behaviour_ok?(mod) do
    Kind.behaviour_info(:callbacks)
    |> Enum.all?(fn {fun, arity} -> function_exported?(mod, fun, arity) end)
  end
end
