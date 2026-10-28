defmodule Platform.Files.CanvasPreview do
  @moduledoc """
  Bounded, passive document projections for authorized browser cards (rung 17).
  Only native text/image leaves and structural containers are traversed. No
  extension renderer, canvas server, HTML, form or executable node reaches a card.
  """
  import Ecto.Query
  alias Platform.{Chat, Repo}
  alias Platform.Files.Browser
  @limit 200
  @containers ~w(stack row card)

  def batch(viewer, items) do
    ids =
      items
      |> Enum.filter(&(&1.type == :canvas and Platform.UUID.valid?(&1.id)))
      |> Enum.take(@limit)
      |> Enum.map(& &1.id)

    tree = Browser.tree(viewer)
    spaces = Enum.flat_map(tree.orgs, & &1.spaces) ++ tree.other.spaces
    space_ids = Enum.map(spaces, & &1.id)

    query =
      from(c in Chat.Canvas,
        where: c.id in ^ids and c.space_id in ^space_ids and is_nil(c.deleted_at),
        select: {c.id, c.space_id, c.document}
      )

    query =
      case viewer.access_scope do
        %Platform.Access.Scope{} = scope -> Chat.scope_by(query, scope, :canvas)
        _ -> query
      end

    rows = if ids == [], do: [], else: Repo.all(query)
    authorized_ids = Enum.map(rows, &elem(&1, 0))

    editors =
      if authorized_ids == [],
        do: %{},
        else:
          Repo.all(
            from(v in Chat.Canvas.Version,
              where: v.canvas_id in ^authorized_ids,
              distinct: v.canvas_id,
              order_by: [asc: v.canvas_id, desc: v.revision],
              select: {v.canvas_id, v.written_by}
            )
          )
          |> Map.new()

    Map.new(rows, fn {id, space_id, document} ->
      {id,
       %{
         space_id: space_id,
         nodes: project(document),
         editor: get_in(editors, [id, "display_name"])
       }}
    end)
  end

  @doc "Safe leaves in document order; depth, node count and text are bounded."
  def project(%{"root" => root}), do: walk(root, 0) |> Enum.take(24)
  def project(_), do: []

  defp walk(_, depth) when depth > 12, do: []

  defp walk(%{"type" => type, "children" => children}, depth)
       when type in @containers and is_list(children),
       do: children |> Enum.take(24) |> Enum.flat_map(&walk(&1, depth + 1)) |> Enum.take(24)

  defp walk(%{"type" => "image", "props" => %{"src" => src} = props}, _) do
    if Chat.Canvas.Kinds.Image.validate_props(%{"src" => src}) == :ok,
      do: [%{kind: :image, value: src, alt: safe_string(props["alt"])}],
      else: []
  end

  defp walk(%{"type" => type, "props" => props}, _)
       when type in ["text", "heading", "markdown"] do
    value =
      if type == "markdown" do
        props["content"]
        |> safe_string()
        |> Chat.ContentRenderer.sanitized_html()
        |> Floki.parse_fragment!()
        |> Floki.filter_out("script,style,iframe,form,button,input")
        |> Floki.text(sep: " ")
      else
        safe_string(props["value"])
      end

    [
      %{
        kind: if(type == "heading", do: :heading, else: :text),
        value: String.slice(value, 0, 1500)
      }
    ]
  end

  defp walk(%{"type" => "code", "props" => props}, _),
    do: [%{kind: :text, value: props["source"] |> safe_string() |> String.slice(0, 1500)}]

  defp walk(%{"type" => "table", "props" => %{"columns" => columns, "rows" => rows}}, _)
       when is_list(columns) and is_list(rows) do
    columns = columns |> Enum.take(8) |> Enum.filter(&is_binary/1)
    header = %{kind: :heading, value: Enum.join(columns, " · ")}

    body =
      rows
      |> Enum.take(12)
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row ->
        %{
          kind: :text,
          value:
            Enum.map_join(columns, " · ", fn col -> safe_cell(Map.get(row, col)) end)
            |> String.slice(0, 1500)
        }
      end)

    [header | body]
  end

  defp walk(_, _), do: []
  defp safe_cell(s) when is_number(s) or is_boolean(s), do: to_string(s)
  defp safe_cell(s), do: safe_string(s)
  defp safe_string(s) when is_binary(s), do: String.slice(s, 0, 6000)
  defp safe_string(_), do: ""
end
