defmodule Platform.Federation.ListContract do
  @moduledoc """
  The classification half of the list-envelope contract (task 01a04a7a).

  Every tool whose NAME says it returns a list — `*_list`, `*.list`, a
  `_list_` infix, `*_search`, `*_get_messages` — must appear in exactly one of
  `ToolSurface.list_envelope_tools/0` (its responses carry `total` and
  `has_more`) or `ToolSurface.list_envelope_exempt/0` (with a reason).

  `unclassified/1` is pure over a definitions list so a test can inject a
  fake name and prove the guard fires, rather than only observing it pass.
  """

  alias Platform.Federation.ToolSurface

  @list_shaped ~r/(^|[._])list([._]|$)|_search$|_get_messages$/

  @doc "The regex a tool name must match to be treated as list-shaped."
  def list_shaped_pattern, do: @list_shaped

  @doc "Is `name` list-shaped by the naming rule?"
  def list_shaped?(name) when is_binary(name), do: Regex.match?(@list_shaped, name)

  @doc """
  Names of list-shaped tools in `defs` that are in neither registry, sorted
  and deduplicated. `[]` means every list-shaped tool is classified.
  """
  def unclassified(
        defs,
        registered \\ ToolSurface.list_envelope_tools(),
        exempt \\ ToolSurface.list_envelope_exempt()
      ) do
    defs
    |> Enum.map(&tool_name/1)
    |> Enum.filter(&(is_binary(&1) and list_shaped?(&1)))
    |> Enum.reject(&(Map.has_key?(registered, &1) or Map.has_key?(exempt, &1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp tool_name(%{name: name}), do: name
  defp tool_name(%{"name" => name}), do: name
  defp tool_name(_), do: nil
end
