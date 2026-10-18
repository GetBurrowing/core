defmodule Platform.CodeMode.Docs do
  @moduledoc """
  TypeScript-style declarations of what a `burrow_run` script can call
  (task 01a114a8 stage 3), served by the `burrow_run_describe` tool.

  ## Built from the caller's EFFECTIVE tools, never the catalogue

  The input is `ToolAuthorization.effective_tools/1` minus `burrow_run` (and
  its legacy name) — the set `Platform.CodeMode.Bindings` binds on `burrow`,
  less the hidden legacy aliases it also binds (task 01a14a7f stage 3, task
  01a14b9e-50a4 stage 1), which are never described. The declarations name
  only `burrow` and `BurrowError`; the legacy global `suite` (the same object)
  is never listed — so a runtime is never told about a tool it cannot call. A requested name outside that set
  is reported under `not_available` without saying whether it exists: the
  answer for "not granted" and "no such tool" is the same.

  ## Progressive discovery

    * no `tools` / `bundle`: an INDEX, one line per callable tool (its call
      path and the first sentence of its description), grouped by bundle;
    * `tools: [names]` and/or `bundle: name`: declarations for those tools
      only — input type from `parameters` (a declared `:schema` is used
      verbatim) and return type from `returns_schema` (or `unknown` plus the
      prose `returns`).

  ## Detail (task 01a115b5 stage 2)

  Declarations come in two details, selected by the `detail` argument:

    * `"summary"` (the default): the types, plus ONE TSDoc line per tool —
      the first sentence of its description. No limitations, no when_to_use,
      no parameter or return-property description comments. A tool without
      a `returns_schema` keeps its prose `Returns:`, because its type is
      `unknown` and the prose is its only return documentation.
    * `"full"`: the description, limitations and when_to_use as TSDoc, and
      every parameter and property description.

  The types are identical in both. Measured on the 01a114a8 rig, three tools
  (task_list, stage_list, execution_lease_list) cost 12,208 B in full; most
  of it was prose that restates what the types already say.

  An agent reads the index once, then fetches types for the handful of
  tools its script will use, instead of all of them.
  """

  alias Platform.Federation.ToolAuthorization

  @self_tools ~w(burrow_run suite_run)
  @identifier ~r/^[A-Za-z_$][A-Za-z0-9_$]*$/

  @doc "The `burrow_run_describe` tool handler (`ToolSurface.execute/3`)."
  @spec run_tool(map(), map()) :: {:ok, map()} | {:error, map()}
  def run_tool(args, %{runtime_id: runtime_id}) when is_binary(runtime_id) do
    case Platform.Federation.get_runtime_by_runtime_id(runtime_id) do
      nil -> unknown_runtime()
      runtime -> describe(runtime, args)
    end
  end

  def run_tool(_args, _context), do: unknown_runtime()

  defp unknown_runtime do
    {:error,
     %{
       error: "burrow_run_describe needs a calling runtime",
       code: "unknown_runtime",
       recoverable: false
     }}
  end

  @doc """
  The `burrow_run_describe` handler body: `{:ok, %{docs, tools, not_available,
  bundles}}` or a recoverable refusal for malformed arguments.
  """
  @spec describe(struct(), map()) :: {:ok, map()} | {:error, map()}
  def describe(runtime, args) when is_map(args) do
    with {:ok, tools} <- string_list(args, "tools"),
         {:ok, bundle} <- optional_string(args, "bundle"),
         {:ok, detail} <- detail(Map.get(args, "detail")) do
      available = callable(runtime)
      {selected, not_available} = select(available, tools, bundle)

      docs =
        if is_nil(tools) and is_nil(bundle),
          do: render_index(available),
          else: render_declarations(selected, detail)

      {:ok,
       %{
         docs: docs,
         tools: Enum.map(selected_or_index(selected, available, tools, bundle), & &1.name),
         not_available: not_available,
         bundles: available |> Enum.map(& &1.bundle) |> Enum.uniq() |> Enum.sort()
       }}
    end
  end

  @doc """
  The declaration text for `runtime`. Options: `:tools` (names),
  `:bundle` and `:detail` (`"summary"`, the default, or `"full"`; atoms are
  accepted); with neither `:tools` nor `:bundle`, the index.
  """
  @spec render(struct(), keyword()) :: String.t()
  def render(runtime, opts \\ []) do
    available = callable(runtime)
    tools = Keyword.get(opts, :tools)
    bundle = Keyword.get(opts, :bundle)

    detail =
      case opts |> Keyword.get(:detail) |> atom_to_string() |> detail() do
        {:ok, detail} -> detail
        {:error, %{error: message}} -> raise ArgumentError, message
      end

    if is_nil(tools) and is_nil(bundle) do
      render_index(available)
    else
      {selected, _not_available} = select(available, tools, bundle)
      render_declarations(selected, detail)
    end
  end

  # The script's surface: what Bindings binds, without the hidden aliases.
  defp callable(runtime) do
    runtime
    |> ToolAuthorization.effective_tools()
    |> Enum.reject(&(&1.name in @self_tools))
  end

  defp select(available, tools, bundle) do
    by_name = Map.new(available, &{&1.name, &1})
    requested = tools || []

    named = requested |> Enum.uniq() |> Enum.flat_map(&List.wrap(Map.get(by_name, &1)))
    in_bundle = if bundle, do: Enum.filter(available, &(&1.bundle == bundle)), else: []

    selected = Enum.uniq_by(named ++ in_bundle, & &1.name)
    not_available = requested |> Enum.uniq() |> Enum.reject(&Map.has_key?(by_name, &1))
    {selected, not_available}
  end

  defp selected_or_index(_selected, available, nil, nil), do: available
  defp selected_or_index(selected, _available, _tools, _bundle), do: selected

  # ── Index ───────────────────────────────────────────────────────────────

  defp render_index(available) do
    header = [
      "// #{length(available)} tools are bound on `burrow` for this runtime.",
      "// Call burrow_run_describe({tools: [\"name\", ...]}) for their argument and return types."
    ]

    groups =
      available
      |> Enum.group_by(& &1.bundle)
      |> Enum.sort_by(fn {bundle, _} -> bundle end)
      |> Enum.flat_map(fn {bundle, tools} ->
        ["", "// #{bundle}"] ++
          Enum.map(tools, fn tool ->
            "burrow.#{tool.name}(args)  // #{first_sentence(tool[:description])}"
          end)
      end)

    Enum.join(header ++ groups, "\n")
  end

  defp first_sentence(text) when is_binary(text) do
    text
    |> String.split(~r/(?<=\.)\s/, parts: 2)
    |> hd()
    |> String.replace("\n", " ")
    |> String.slice(0, 160)
  end

  defp first_sentence(_), do: ""

  # ── Declarations ────────────────────────────────────────────────────────

  defp render_declarations(selected, detail) do
    tree = Enum.reduce(selected, %{}, &put_path(&2, String.split(&1.name, "."), &1))

    members =
      tree
      |> render_members(1, detail)
      |> Kernel.++([
        "  /** Call any tool you may call by name; same result or BurrowError as the direct binding. */",
        "  call(name: string, args?: Record<string, unknown>): unknown;"
      ])

    Enum.join(
      [
        "/** Thrown by a binding; `kind`: forbidden | tool_error | result_too_large | invalid_args | call_limit | store_error. */",
        "interface BurrowError extends Error { kind: string; code: string | null; message: string }",
        "",
        "declare const inputs: unknown;",
        "declare const store: {",
        "  get(key: string): unknown;",
        "  set(key: string, value: unknown, opts?: { ttl?: number }): true;",
        "  delete(key: string): true;",
        "};",
        "",
        "declare const burrow: {"
      ] ++ members ++ ["};"],
      "\n"
    )
  end

  defp put_path(tree, [leaf], tool), do: Map.put(tree, leaf, {:tool, tool})

  defp put_path(tree, [head | rest], tool) do
    sub =
      case Map.get(tree, head) do
        %{} = existing -> existing
        _ -> %{}
      end

    Map.put(tree, head, put_path(sub, rest, tool))
  end

  defp render_members(tree, depth, detail) do
    pad = String.duplicate("  ", depth)

    tree
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.flat_map(fn
      {key, {:tool, tool}} ->
        tsdoc(tool, pad, detail) ++
          [
            "#{pad}#{prop_name(key)}(#{args_decl(tool, pad, detail)}): #{return_decl(tool, pad, detail)};"
          ]

      {key, %{} = sub} ->
        ["#{pad}#{prop_name(key)}: {"] ++ render_members(sub, depth + 1, detail) ++ ["#{pad}};"]
    end)
  end

  # summary: one line, the first sentence; an untyped tool keeps its prose
  # `Returns:` (its type is `unknown`, so the prose is its only return doc).
  defp tsdoc(tool, pad, "summary") do
    returns = if tool[:returns_schema], do: nil, else: labelled("Returns", tool[:returns])

    [first_sentence(tool[:description]), returns]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> []
      parts -> ["#{pad}/** #{parts |> Enum.join(" ") |> one_line() |> escape_comment()} */"]
    end
  end

  defp tsdoc(tool, pad, "full") do
    sections =
      [
        tool[:description],
        labelled("Limitations", tool[:limitations]),
        labelled("When to use", tool[:when_to_use]),
        if(tool[:returns_schema], do: nil, else: labelled("Returns", tool[:returns]))
      ]
      |> Enum.reject(&blank?/1)

    lines =
      sections
      |> Enum.intersperse("")
      |> Enum.flat_map(&String.split(&1, "\n"))
      |> Enum.map(&String.trim_trailing("#{pad} * " <> escape_comment(&1)))

    ["#{pad}/**"] ++ lines ++ ["#{pad} */"]
  end

  defp labelled(_label, text) when not is_binary(text), do: nil
  defp labelled(label, text), do: "#{label}: #{text}"

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""

  defp escape_comment(text), do: String.replace(text, "*/", "*\\/")

  defp one_line(text), do: String.replace(text, "\n", " ")

  defp args_decl(tool, pad, detail) do
    params = Map.get(tool, :parameters) || %{}

    if map_size(params) == 0 do
      "args?: {}"
    else
      required? = Enum.any?(params, fn {_k, meta} -> is_map(meta) and meta[:required] == true end)

      props =
        params
        |> Enum.sort_by(fn {key, _} -> to_string(key) end)
        |> Enum.flat_map(fn {key, meta} ->
          param_lines(to_string(key), meta, pad <> "  ", detail)
        end)

      "args#{if required?, do: "", else: "?"}: {\n" <> Enum.join(props, "\n") <> "\n#{pad}}"
    end
  end

  defp param_lines(key, meta, pad, detail) when is_map(meta) do
    schema =
      case meta[:schema] do
        %{} = schema -> schema |> stringify() |> for_detail(detail)
        _ -> %{"type" => meta[:type] || "string"}
      end

    optional = if meta[:required] == true, do: "", else: "?"

    param_doc(meta[:description], pad, detail) ++
      ["#{pad}#{prop_name(key)}#{optional}: #{ts_type(schema, pad)};"]
  end

  defp param_lines(key, _meta, pad, _detail), do: ["#{pad}#{prop_name(key)}?: unknown;"]

  defp param_doc(_text, _pad, "summary"), do: []
  defp param_doc(text, pad, "full"), do: doc_comment(text, pad)

  defp return_decl(tool, pad, detail) do
    case tool[:returns_schema] do
      %{} = schema -> schema |> stringify() |> for_detail(detail) |> ts_type(pad)
      _ -> "unknown"
    end
  end

  # summary drops every schema-level `description` (the `/** ... */` property
  # comments `ts_type/2` renders) and nothing else. It walks the schema
  # STRUCTURE, so a property NAMED "description" (task.description) keeps its
  # declaration: only the keyword is removed, never a key of `properties`.
  defp for_detail(schema, "full"), do: schema
  defp for_detail(schema, "summary"), do: strip_descriptions(schema)

  defp strip_descriptions(%{} = schema) do
    schema
    |> Map.delete("description")
    |> Map.new(fn
      {"properties", %{} = props} ->
        {"properties", Map.new(props, fn {k, sub} -> {k, strip_descriptions(sub)} end)}

      {key, %{} = sub} when key in ["items", "additionalProperties"] ->
        {key, strip_descriptions(sub)}

      {key, options} when key in ["oneOf", "anyOf"] and is_list(options) ->
        {key, Enum.map(options, &strip_descriptions/1)}

      other ->
        other
    end)
  end

  defp strip_descriptions(other), do: other

  defp doc_comment(text, pad) when is_binary(text) do
    if String.trim(text) == "",
      do: [],
      else: ["#{pad}/** #{text |> String.replace("\n", " ") |> escape_comment()} */"]
  end

  defp doc_comment(_text, _pad), do: []

  # ── JSON Schema -> TypeScript ───────────────────────────────────────────

  @doc false
  # Public for the docs test. Covers the subset `ReturnSchemas` and tool
  # `:schema` parameters use; anything else renders as `unknown`.
  def ts_type(schema, pad \\ "")

  def ts_type(%{"oneOf" => options}, pad), do: union(options, pad)
  def ts_type(%{"anyOf" => options}, pad), do: union(options, pad)

  def ts_type(%{"enum" => values} = schema, _pad) do
    literals = Enum.map(values, &Jason.encode!/1)
    nullable = if "null" in List.wrap(schema["type"]), do: ["null"], else: []
    Enum.join(literals ++ nullable, " | ")
  end

  def ts_type(%{"type" => types} = schema, pad) when is_list(types) do
    types
    |> Enum.map(&ts_type(Map.put(schema, "type", &1), pad))
    |> Enum.uniq()
    |> Enum.join(" | ")
  end

  def ts_type(%{"type" => "string"}, _pad), do: "string"
  def ts_type(%{"type" => "integer"}, _pad), do: "number"
  def ts_type(%{"type" => "number"}, _pad), do: "number"
  def ts_type(%{"type" => "boolean"}, _pad), do: "boolean"
  def ts_type(%{"type" => "null"}, _pad), do: "null"

  def ts_type(%{"type" => "array"} = schema, pad),
    do: "Array<#{ts_type(Map.get(schema, "items", %{}), pad)}>"

  def ts_type(%{"type" => "object", "properties" => props} = schema, pad)
      when map_size(props) > 0 do
    inner = pad <> "  "
    required = Map.get(schema, "required", [])

    lines =
      props
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.flat_map(fn {key, sub} ->
        optional = if key in required, do: "", else: "?"

        doc_comment(sub["description"], inner) ++
          ["#{inner}#{prop_name(key)}#{optional}: #{ts_type(sub, inner)};"]
      end)

    extra =
      case schema["additionalProperties"] do
        %{} = sub when map_size(sub) > 0 -> ["#{inner}[key: string]: #{ts_type(sub, inner)};"]
        false -> []
        _ -> ["#{inner}[key: string]: unknown;"]
      end

    "{\n" <> Enum.join(lines ++ extra, "\n") <> "\n#{pad}}"
  end

  def ts_type(%{"type" => "object"} = schema, pad) do
    case schema["additionalProperties"] do
      %{} = sub when map_size(sub) > 0 -> "Record<string, #{ts_type(sub, pad)}>"
      _ -> "Record<string, unknown>"
    end
  end

  def ts_type(_schema, _pad), do: "unknown"

  defp union(options, pad), do: options |> Enum.map(&ts_type(&1, pad)) |> Enum.join(" | ")

  defp prop_name(key) do
    if Regex.match?(@identifier, key), do: key, else: Jason.encode!(key)
  end

  # Tool `:schema` maps are atom-keyed; JSON round trip makes every key a string.
  defp stringify(schema), do: schema |> Jason.encode!() |> Jason.decode!()

  # ── Arguments ───────────────────────────────────────────────────────────

  defp string_list(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: invalid(key, "a list of names")

      _ ->
        invalid(key, "a list of names")
    end
  end

  defp optional_string(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> invalid(key, "a bundle name")
    end
  end

  @details ~w(summary full)

  defp atom_to_string(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp atom_to_string(value), do: value

  defp detail(nil), do: {:ok, "summary"}
  defp detail(value) when value in @details, do: {:ok, value}
  defp detail(_), do: invalid("detail", ~s("summary" or "full"))

  defp invalid(key, expected) do
    {:error,
     %{
       error: "burrow_run_describe: `#{key}` must be #{expected}",
       code: "invalid_#{key}",
       recoverable: true,
       suggestion:
         "Call with no arguments for the index, then with tools: [\"task_get\", ...] for full types."
     }}
  end
end
