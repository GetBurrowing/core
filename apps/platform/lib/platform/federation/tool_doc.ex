defmodule Platform.Federation.ToolDoc do
  @moduledoc """
  Renders a tool definition's authored prose into the single `description`
  string an MCP client actually reads.

  Every entry in `Platform.Federation.ToolSurface.tool_definitions/0` follows a
  6-component rubric, three parts of which are prose written FOR THE CALLING
  AGENT: `:returns`, `:limitations` and `:when_to_use`. The WebSocket runtime
  channel pushes the definition map whole, so a runtime on that transport sees
  all four. `PlatformWeb.MCPController.to_mcp_tool/1` projects onto the MCP tool
  object, and that object is a CLOSED schema — `name`, `title`, `description`,
  `inputSchema`, `outputSchema`, `annotations`, `_meta`. There is no key on it
  for "limitations".

  That is why this module folds rather than adds. Emitting the three as sibling
  JSON keys would be the change most likely to look fixed in a diff and ship a
  no-op: a client is free to ignore keys it does not know, and would render
  exactly what it renders today. Appending them to `description` under stable
  headings puts the prose somewhere every client already displays.

  Two properties the callers depend on, both pinned by tests:

    * the ORIGINAL `description` comes first and is not modified, so anything
      that reads only the first line or matches on the old text keeps working;
      and
    * a blank, nil or whitespace-only field emits NOTHING — no heading, no
      separator. Today all 104 tools carry all three fields, so the degenerate
      case has no example in the tree and is constructed in
      `test/platform/federation/tool_doc_test.exs`. A renderer that emits a
      heading above nothing turns this fix into noise the day a tool ships
      without one of the fields.

  Public on purpose: `to_mcp_tool/1` is private, and a public renderer is what
  makes that negative control constructible without a transport.
  """

  # Fixed order, fixed headings. Both are part of what the wire tests assert,
  # so a reordering is a deliberate edit rather than a silent reshuffle.
  @sections [
    {:returns, "Returns:"},
    {:limitations, "Limitations:"},
    {:when_to_use, "When to use:"}
  ]

  @doc """
  Builds the served `description` for a tool definition map.

  Takes any map carrying `:description` and, optionally, `:returns`,
  `:limitations` and `:when_to_use`. Returns a string.
  """
  def render_description(tool) when is_map(tool) do
    blocks =
      Enum.flat_map(@sections, fn {key, heading} ->
        case present(Map.get(tool, key)) do
          nil -> []
          text -> [heading <> " " <> text]
        end
      end)

    # `Enum.reject(&is_nil/1)` before the join is what keeps a blank field from
    # leaving a `\n\n` separator behind. The separator and the heading are two
    # different expressions, and dropping the heading while keeping the
    # separator is the likelier of the two bugs — hence the byte-identity
    # assertions in `tool_doc_test.exs` rather than "no heading appears".
    [present(Map.get(tool, :description)) | blocks]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_), do: nil

  @doc "The heading strings this module emits, in the order it emits them."
  def headings, do: Enum.map(@sections, fn {_key, heading} -> heading end)
end
