defmodule Platform.Chat.Canvas.Kinds.Table do
  @moduledoc "Tabular data. Columns and rows are props; no children."

  use Platform.Chat.Canvas.Kind

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["columns", "rows"],
      "properties" => %{
        "columns" => %{"type" => "array", "items" => %{"type" => "string"}},
        "rows" => %{
          "type" => "array",
          "items" => %{"type" => "object"}
        },
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  def styling do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "density" => %{"type" => "string", "enum" => ["compact", "comfortable", "spacious"]}
      }
    }
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}
    columns = List.wrap(props["columns"])
    rows = List.wrap(props["rows"])

    assigns =
      assigns
      |> assign(:columns, columns)
      |> assign(:rows, rows)
      |> assign(:class_overrides, props["class_overrides"])

    ~H"""
    <div class={["overflow-x-auto", @class_overrides]}>
      <table class="table table-zebra table-sm w-full">
        <thead>
          <tr>
            <th :for={col <- @columns} class="text-xs uppercase tracking-widest">{col}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td :for={col <- @columns} class="align-top text-sm">{cell(row, col)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp cell(row, col) when is_map(row) do
    val = Map.get(row, col, Map.get(row, to_string(col), "—"))
    stringify(val)
  end

  defp cell(_row, _col), do: "—"

  defp stringify(nil), do: "—"
  defp stringify(s) when is_binary(s), do: s
  defp stringify(n) when is_number(n) or is_boolean(n) or is_atom(n), do: to_string(n)
  defp stringify(list) when is_list(list), do: Enum.map_join(list, ", ", &stringify/1)
  defp stringify(other), do: inspect(other)
end
