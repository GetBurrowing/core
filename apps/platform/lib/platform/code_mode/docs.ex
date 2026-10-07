defmodule Platform.CodeMode.Docs do
  @moduledoc """
  TypeScript-style declarations of what a `suite_run` script can call
  (task 01a114a8 stage 3), served by the `suite_run_describe` tool.

  ## Built from the caller's EFFECTIVE tools, never the catalogue

  The input is `ToolAuthorization.effective_tools/1` minus `suite_run` — the
  same set `Platform.CodeMode.Bindings` binds on `suite` — so a runtime is
  never told about a tool it cannot call. A requested name outside that set
  is reported under `not_available` without saying whether it exists: the
  answer for "not granted" and "no such tool" is the same.

  ## Progressive discovery

    * no `tools` / `bundle`: an INDEX, one line per callable tool (its call
      path and the first sentence of its description), grouped by bundle;
    * `tools: [names]` and/or `bundle: name`: full declarations for those
      tools only — input type from `parameters` (a declared `:schema` is used
      verbatim), return type from `returns_schema` (or `unknown` plus the
      prose `returns`), and the description, limitations and when_to_use as
      TSDoc.

  An agent reads the index once, then fetches types for the handful of
  tools its script will use, instead of all of them.
  """

  alias Platform.Federation.ToolAuthorization

  @self_tools ~w(suite_run)
  @identifier ~r/^[A-Za-z_$][A-Za-z0-9_$]*$/

  @doc "The `suite_run_describe` tool handler (`ToolSurface.execute/3`)."
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
       error: "suite_run_describe needs a calling runtime",
       code: "unknown_runtime",
       recoverable: false
     }}
  end

  @doc """
  The `suite_run_describe` handler body: `{:ok, %{docs, tools, not_available,
  bundles}}` or a recoverable refusal for malformed arguments.
  """
  @spec describe(struct(), map()) :: {:ok, map()} | {:error, map()}
  def describe(runtime, args) when is_map(args) do
    with {:ok, tools} <- string_list(args, "tools"),
         {:ok, bundle} <- optional_string(args, "bundle") do
      available = callable(runtime)
      {selected, not_available} = select(available, tools, bundle)

      docs =
        if is_nil(tools) and is_nil(bundle),
          do: render_index(available),
          else: render_declarations(selected)

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
  The declaration text for `runtime`. Options: `:tools` (names) and
  `:bundle`; with neither, the index.
  """
  @spec render(struct(), keyword()) :: String.t()
  def render(runtime, opts \\ []) do
    available = callable(runtime)
    tools = Keyword.get(opts, :tools)
    bundle = Keyword.get(opts, :bundle)

    if is_nil(tools) and is_nil(bundle) do
      render_index(available)
    else
      {selected, _not_available} = select(available, tools, bundle)
      render_declarations(selected)
    end
  end

  # The script's surface: exactly what Bindings binds.
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
      "// #{length(available)} tools are bound on `suite` for this runtime.",
      "// Call suite_run_describe({tools: [\"name\", ...]}) for their argument and return types."
    ]

    groups =
      available
      |> Enum.group_by(& &1.bundle)
      |> Enum.sort_by(fn {bundle, _} -> bundle end)
      |> Enum.flat_map(fn {bundle, tools} ->
        ["", "// #{bundle}"] ++
          Enum.map(tools, fn tool ->
            "suite.#{tool.name}(args)  // #{first_sentence(tool[:description])}"
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

  defp render_declarations(selected) do
    tree = Enum.reduce(selected, %{}, &put_path(&2, String.split(&1.name, "."), &1))

    members =
      tree
      |> render_members(1)
      |> Kernel.++([
        "  /** Call any tool you may call by name; same result or SuiteError as the direct binding. */",
        "  call(name: string, args?: Record<string, unknown>): unknown;"
      ])

    Enum.join(
      [
        "/** Thrown by a binding; `kind`: forbidden | tool_error | result_too_large | invalid_args | call_limit | store_error. */",
        "interface SuiteError extends Error { kind: string; code: string | null; message: string }",
        "",
        "declare const inputs: unknown;",
        "declare const store: {",
        "  get(key: string): unknown;",
        "  set(key: string, value: unknown, opts?: { ttl?: number }): true;",
        "  delete(key: string): true;",
        "};",
        "",
        "declare const suite: {"
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

  defp render_members(tree, depth) do
    pad = String.duplicate("  ", depth)

    tree
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.flat_map(fn
      {key, {:tool, tool}} ->
        tsdoc(tool, pad) ++
          ["#{pad}#{prop_name(key)}(#{args_decl(tool, pad)}): #{return_decl(tool, pad)};"]

      {key, %{} = sub} ->
        ["#{pad}#{prop_name(key)}: {"] ++ render_members(sub, depth + 1) ++ ["#{pad}};"]
    end)
  end

  defp tsdoc(tool, pad) do
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

  defp args_decl(tool, pad) do
    params = Map.get(tool, :parameters) || %{}

    if map_size(params) == 0 do
      "args?: {}"
    else
      required? = Enum.any?(params, fn {_k, meta} -> is_map(meta) and meta[:required] == true end)

      props =
        params
        |> Enum.sort_by(fn {key, _} -> to_string(key) end)
        |> Enum.flat_map(fn {key, meta} -> param_lines(to_string(key), meta, pad <> "  ") end)

      "args#{if required?, do: "", else: "?"}: {\n" <> Enum.join(props, "\n") <> "\n#{pad}}"
    end
  end

  defp param_lines(key, meta, pad) when is_map(meta) do
    schema =
      case meta[:schema] do
        %{} = schema -> stringify(schema)
        _ -> %{"type" => meta[:type] || "string"}
      end

    optional = if meta[:required] == true, do: "", else: "?"

    doc_comment(meta[:description], pad) ++
      ["#{pad}#{prop_name(key)}#{optional}: #{ts_type(schema, pad)};"]
  end

  defp param_lines(key, _meta, pad), do: ["#{pad}#{prop_name(key)}?: unknown;"]

  defp return_decl(tool, pad) do
    case tool[:returns_schema] do
      %{} = schema -> ts_type(stringify(schema), pad)
      _ -> "unknown"
    end
  end

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

  defp invalid(key, expected) do
    {:error,
     %{
       error: "suite_run_describe: `#{key}` must be #{expected}",
       code: "invalid_#{key}",
       recoverable: true,
       suggestion:
         "Call with no arguments for the index, then with tools: [\"task_get\", ...] for full types."
     }}
  end
end
