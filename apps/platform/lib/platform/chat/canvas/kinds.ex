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
