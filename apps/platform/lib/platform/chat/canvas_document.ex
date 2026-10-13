defmodule Platform.Chat.CanvasDocument do
  @moduledoc """
  Canonical canvas document (ADR 0036).

  A document is a node tree with a monotonic revision counter:

      %{
        "version"  => 1,
        "revision" => 1,
        "root"     => %{
          "id"       => "root",
          "type"     => "stack",
          "props"    => %{"gap" => 12},
          "children" => []
        },
        "theme"    => %{},
        "bindings" => %{},
        "meta"     => %{}
      }

  Node-kind knowledge (what kinds exist, what props/children they accept) is
  delegated to `Platform.Chat.Canvas.Kinds`. This module owns only structural
  framing (version, revision, root, theme, bindings, meta).
  """

  alias Platform.Chat.Canvas.Kinds

  @current_version 1

  @type document :: map()
  @type node_map :: map()

  @doc "Create a blank canonical document with a root `stack` node."
  @spec new() :: document()
  def new do
    %{
      "version" => @current_version,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => []
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  @doc """
  Validate a document map.

  Returns `{:ok, document}` or `{:error, reasons}` with a list of human-readable
  error strings. Node validation is delegated to `Kinds.validate_node/2`.
  """
  @spec validate(document()) :: {:ok, document()} | {:error, [binary()]}
  def validate(document) when is_map(document) do
    errors =
      []
      |> check_version(document)
      |> check_revision(document)
      |> check_root(document)
      |> check_theme(document)
      |> check_bindings(document)
      |> check_meta(document)

    case errors do
      [] -> {:ok, document}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(_), do: {:error, ["document must be a map"]}

  @doc "Find a node by id. Returns `nil` if not found."
  @spec get_node(document(), binary()) :: node_map() | nil
  def get_node(%{"root" => root}, node_id) when is_map(root), do: find_node(root, node_id)
  def get_node(_, _), do: nil

  @doc "Return the current revision."
  @spec revision(document()) :: non_neg_integer()
  def revision(%{"revision" => r}) when is_integer(r), do: r
  def revision(_), do: 0

  @doc "Return the kind name of the document's root node, or nil."
  @spec root_kind(document()) :: String.t() | nil
  def root_kind(%{"root" => %{"type" => t}}) when is_binary(t), do: t
  def root_kind(_), do: nil

  @doc """
  Return true when `doc` looks like a canonical document (presence of `version`
  and a map `root` with a known kind).
  """
  @spec canonical?(any()) :: boolean()
  def canonical?(%{"version" => v, "root" => %{"type" => t}}) when is_integer(v) and is_binary(t),
    do: Kinds.kind?(t)

  def canonical?(_), do: false

  # ── Private ──

  defp find_node(%{"id" => id} = node, id), do: node

  defp find_node(%{"children" => children}, target) when is_list(children),
    do: Enum.find_value(children, &find_node(&1, target))

  defp find_node(_, _), do: nil

  defp check_version(errors, %{"version" => v}) when is_integer(v) and v > 0, do: errors
  defp check_version(errors, _), do: ["\"version\" must be a positive integer" | errors]

  defp check_revision(errors, %{"revision" => r}) when is_integer(r) and r > 0, do: errors
  defp check_revision(errors, _), do: ["\"revision\" must be a positive integer" | errors]

  defp check_root(errors, %{"root" => root}) when is_map(root) do
    case Kinds.validate_node(root, "root") do
      :ok -> errors
      {:error, reasons} -> Enum.reverse(reasons) ++ errors
    end
  end

  defp check_root(errors, _), do: ["\"root\" must be a node map" | errors]

  defp check_theme(errors, %{"theme" => t}) when is_map(t), do: errors
  defp check_theme(errors, %{} = doc) when not is_map_key(doc, "theme"), do: errors
  defp check_theme(errors, _), do: ["\"theme\" must be a map" | errors]

  defp check_bindings(errors, %{"bindings" => b}) when is_map(b),
    do: Enum.reverse(binding_errors(b)) ++ errors

  defp check_bindings(errors, %{} = doc) when not is_map_key(doc, "bindings"), do: errors
  defp check_bindings(errors, _), do: ["\"bindings\" must be a map" | errors]

  # ── Handler bindings (task 01a1316b-aab0 stage 2) ──

  @max_handlers 32
  @max_handler_source_bytes 65_536

  @doc """
  The caps on handler bindings: an entry of `"bindings"` whose `"kind"` is
  `"handler"` (`%{"kind" => "handler", "engine" => "js", "source" => src}`).
  Its name matches `^[a-z][a-z0-9_.-]{0,63}$`, its engine is a registered
  `Platform.Canvas.ScriptEngine` tag, its source is a non-empty string of at
  most 64 KB, and a document holds at most 32 of them. Other entries of
  `"bindings"` are left as they were (validated only as a map).
  """
  def handler_caps,
    do: %{max_handlers: @max_handlers, max_source_bytes: @max_handler_source_bytes}

  @doc "Does `name` match the handler binding name pattern?"
  @spec binding_name?(term()) :: boolean()
  def binding_name?(name) when is_binary(name),
    do: Regex.match?(~r/\A[a-z][a-z0-9_.-]{0,63}\z/, name)

  def binding_name?(_name), do: false

  @doc """
  The handler binding `name` in `document`, or nil. Only an entry whose
  `"kind"` is `"handler"` counts.
  """
  @spec handler(document(), String.t()) :: map() | nil
  def handler(%{"bindings" => %{} = bindings}, name) when is_binary(name) do
    case Map.get(bindings, name) do
      %{"kind" => "handler"} = binding -> binding
      _ -> nil
    end
  end

  def handler(_document, _name), do: nil

  @doc "The errors in a bindings map's handler entries; `[]` when valid."
  @spec binding_errors(map()) :: [binary()]
  def binding_errors(bindings) when is_map(bindings) do
    handlers = Enum.filter(bindings, fn {_name, b} -> handler_binding?(b) end)

    count_errors =
      if length(handlers) > @max_handlers,
        do: ["bindings: at most #{@max_handlers} handlers per canvas"],
        else: []

    count_errors ++
      Enum.flat_map(Enum.sort_by(handlers, &elem(&1, 0)), fn {name, b} ->
        handler_errors(name, b)
      end)
  end

  defp handler_binding?(%{"kind" => "handler"}), do: true
  defp handler_binding?(_binding), do: false

  defp handler_errors(name, binding) do
    engine = Map.get(binding, "engine", "js")
    source = Map.get(binding, "source")

    [
      {binding_name?(name),
       "bindings: handler name #{inspect(name)} must match ^[a-z][a-z0-9_.-]{0,63}$"},
      {match?({:ok, _}, Platform.Canvas.ScriptEngine.engine_for(engine)),
       "bindings.#{name}: unknown engine #{inspect(engine)}"},
      {is_binary(source) and source != "", "bindings.#{name}: source must be a non-empty string"},
      {not is_binary(source) or byte_size(source) <= @max_handler_source_bytes,
       "bindings.#{name}: source may be at most #{@max_handler_source_bytes} bytes"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp check_meta(errors, %{"meta" => m}) when is_map(m), do: errors
  defp check_meta(errors, %{} = doc) when not is_map_key(doc, "meta"), do: errors
  defp check_meta(errors, _), do: ["\"meta\" must be a map" | errors]
end
