defmodule Platform.Chat.Canvas.MarkdownExporter do
  @moduledoc """
  Pure, side-effect-free renderer that walks a canonical
  `Platform.Chat.CanvasDocument` node tree and produces GitHub-flavored
  Markdown.

  Used by the `project_files` deploy strategy (see `Platform.Deploy.ProjectFiles`)
  to serialise a canvas to a `.md` attachment. Does not touch the repo, the
  filesystem, or telemetry — the caller decides where the bytes go.

  Kind coverage mirrors `Platform.Chat.Canvas.Kinds.@modules` (20 kinds).
  Interactive-only kinds (`form`, `action_row`, `embed`, `image`, `mermaid`,
  `prototype`)
  render as an HTML comment marker so the export is round-trippable and diffable
  across redeploys. Unknown kinds render as `<!-- unknown-kind: <type> -->`
  rather than crashing — the exporter is a deploy-time helper and must never
  block a deploy on a novel kind name.
  """

  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Kinds
  alias Platform.Chat.Canvas.Kinds.{NeedsYou, ProductionRail, RunSheet}

  @skipped_kinds ~w(form action_row embed image mermaid prototype)

  @doc """
  Render a canvas, a canonical document map, or a bare root-node map to
  Markdown.

  Returns `{:ok, string}` on success, `{:error, reason}` when the input
  isn't recognisable.
  """
  @spec export_markdown(Canvas.t() | map()) :: {:ok, String.t()} | {:error, term()}
  def export_markdown(%Canvas{document: doc}), do: export_markdown(doc)

  def export_markdown(%{"root" => root}) when is_map(root) do
    {:ok, root |> render_node() |> IO.iodata_to_binary() |> String.trim_trailing()}
  end

  def export_markdown(%{"type" => type} = node) when is_binary(type) do
    {:ok, node |> render_node() |> IO.iodata_to_binary() |> String.trim_trailing()}
  end

  def export_markdown(_), do: {:error, :invalid_document}

  # ── Structural containers ─────────────────────────────────────────────

  defp render_node(%{"type" => "stack"} = node) do
    render_children(node, "\n\n")
  end

  defp render_node(%{"type" => "row"} = node) do
    render_children(node, " ")
  end

  defp render_node(%{"type" => "card"} = node) do
    props = props(node)
    body = render_children(node, "\n\n")

    case props["title"] do
      title when is_binary(title) and title != "" ->
        heading = ["### ", title]

        case IO.iodata_to_binary(body) do
          "" -> [heading]
          _ -> [heading, "\n\n", body]
        end

      _ ->
        body
    end
  end

  # ── Text-ish leaves ───────────────────────────────────────────────────

  defp render_node(%{"type" => "heading"} = node) do
    props = props(node)
    level = props["level"] |> normalise_level()
    value = stringify(props["value"])
    [String.duplicate("#", level), " ", value]
  end

  defp render_node(%{"type" => "text"} = node) do
    props = props(node)
    value = stringify(props["value"])

    if bold_weight?(props["weight"]) do
      ["**", value, "**"]
    else
      value
    end
  end

  defp render_node(%{"type" => "markdown"} = node) do
    props = props(node)
    stringify(props["content"])
  end

  defp render_node(%{"type" => "badge"} = node) do
    props = props(node)
    value = stringify(props["value"])
    ["_", value, "_"]
  end

  # ── Lists ─────────────────────────────────────────────────────────────

  defp render_node(%{"type" => "checklist"} = node) do
    props = props(node)
    title = props["title"]

    items =
      node
      |> children()
      |> Enum.map(&render_checklist_item/1)
      |> intersperse_iodata("\n")

    case title do
      title when is_binary(title) and title != "" ->
        header = ["**", title, "**"]

        case items do
          [] -> header
          _ -> [header, "\n", items]
        end

      _ ->
        items
    end
  end

  defp render_node(%{"type" => "checklist_item"} = node) do
    render_checklist_item(node)
  end

  # ── Data ──────────────────────────────────────────────────────────────

  defp render_node(%{"type" => "table"} = node) do
    props = props(node)
    columns = List.wrap(props["columns"])
    rows = List.wrap(props["rows"])
    render_table(columns, rows)
  end

  defp render_node(%{"type" => "code"} = node) do
    props = props(node)
    source = stringify(props["source"])
    language = props["language"] |> stringify()
    fence = "```"
    [fence, language, "\n", source, "\n", fence]
  end

  # ── Episode board (task 01a1eaf6 stage 2) ─────────────────────────────

  defp render_node(%{"type" => "production_rail"} = node) do
    props = props(node)

    title =
      case props["number"] do
        n when is_integer(n) -> ["## Ep ", Integer.to_string(n), " · ", stringify(props["title"])]
        _ -> ["## ", stringify(props["title"])]
      end

    records =
      [
        is_binary(props["records_at"]) && ["Records ", props["records_at"]],
        is_binary(props["room_status"]) && props["room_status"]
      ]
      |> Enum.filter(& &1)
      |> Enum.intersperse(" · ")

    rail =
      props["stages"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn stage ->
        label = ProductionRail.label(stringify(stage["stage"]))
        label = if stage["stage"] == props["stage"], do: ["**", label, "**"], else: label
        [label, " (", String.replace(stringify(stage["state"]), "_", " "), ")"]
      end)
      |> Enum.intersperse(" → ")

    [title, "\n\n"]
    |> then(fn acc -> if records == [], do: acc, else: [acc, records, "\n\n"] end)
    |> then(fn acc -> [acc, rail] end)
  end

  defp render_node(%{"type" => "needs_you"} = node) do
    case props(node)["items"] |> List.wrap() |> Enum.filter(&is_map/1) do
      [] ->
        NeedsYou.empty_copy()

      items ->
        lines =
          Enum.map(items, fn item ->
            options = item["options"] |> List.wrap() |> Enum.map(&stringify/1)
            ["- ", stringify(item["question"]), " (", Enum.intersperse(options, " / "), ")"]
          end)

        [
          "**Needs you (",
          Integer.to_string(length(items)),
          ")**\n\n",
          Enum.intersperse(lines, "\n")
        ]
    end
  end

  defp render_node(%{"type" => "run_sheet"} = node) do
    segments =
      props(node)["segments"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&render_segment/1)

    ["**Run sheet**", Enum.map(segments, &["\n", &1])]
  end

  # ── Skipped / unknown ─────────────────────────────────────────────────

  defp render_node(%{"type" => type} = node) when is_binary(type) do
    id = Map.get(node, "id", "?")

    cond do
      type in @skipped_kinds ->
        ["<!-- skipped: ", type, " id=", to_string(id), " -->"]

      Kinds.kind?(type) ->
        # Registered kind we somehow forgot to handle — shouldn't happen but
        # never crash a deploy for it.
        ["<!-- skipped: ", type, " id=", to_string(id), " -->"]

      true ->
        ["<!-- unknown-kind: ", type, " -->"]
    end
  end

  defp render_node(_), do: []

  # ── Helpers ───────────────────────────────────────────────────────────

  defp children(node), do: List.wrap(Map.get(node, "children", []))

  defp props(node), do: Map.get(node, "props") || %{}

  defp render_children(node, separator) do
    node
    |> children()
    |> Enum.map(&render_node/1)
    |> Enum.reject(&empty_iodata?/1)
    |> intersperse_iodata(separator)
  end

  defp intersperse_iodata([], _sep), do: []
  defp intersperse_iodata([single], _sep), do: [single]

  defp intersperse_iodata([head | tail], sep) do
    Enum.reduce(tail, [head], fn item, acc -> [acc, sep, item] end)
  end

  defp empty_iodata?(iodata) do
    iodata |> IO.iodata_to_binary() |> String.trim() == ""
  end

  defp render_segment(segment) do
    points =
      case segment["talking_points"] do
        points when is_map(points) ->
          points
          |> Enum.sort()
          |> Enum.map(fn {host, text} -> [" ", stringify(host), ": ", stringify(text)] end)

        _ ->
          []
      end

    callback =
      case segment["callback_episode"] do
        n when is_integer(n) -> [" ↩ callback Ep ", Integer.to_string(n)]
        _ -> []
      end

    stats =
      segment["stat_cards"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn card ->
        ["\n  - ", stringify(card["text"]), " (source: ", stringify(card["source_url"]), ")"]
      end)

    [
      "- `",
      RunSheet.clock(segment["starts_at_s"]),
      "–",
      RunSheet.clock(segment["ends_at_s"]),
      "` ",
      stringify(segment["name"]),
      points,
      callback,
      stats
    ]
  end

  defp render_checklist_item(%{"type" => "checklist_item"} = node) do
    props = props(node)
    label = stringify(props["label"])
    marker = if item_done?(props), do: "- [x] ", else: "- [ ] "

    case stringify(props["note"]) do
      "" -> [marker, label]
      note -> [marker, label, " — ", note]
    end
  end

  defp render_checklist_item(other) do
    # Not a checklist_item — best-effort render so nothing crashes.
    render_node(other)
  end

  defp item_done?(props) do
    case props["state"] do
      "complete" -> true
      _ -> props["checked"] == true
    end
  end

  defp bold_weight?(w) when w in ["medium", "semibold", "bold"], do: true
  defp bold_weight?(_), do: false

  defp normalise_level(lvl) when is_integer(lvl) and lvl in 1..4, do: lvl
  defp normalise_level(_), do: 2

  defp render_table([], _rows), do: []

  defp render_table(columns, rows) do
    header = table_row(columns)
    separator = table_row(Enum.map(columns, fn _ -> "---" end))

    body =
      case rows do
        [] ->
          []

        _ ->
          rows
          |> Enum.map(fn row ->
            columns
            |> Enum.map(&cell_value(row, &1))
            |> table_row()
          end)
          |> intersperse_iodata("\n")
      end

    case body do
      [] -> [header, "\n", separator]
      _ -> [header, "\n", separator, "\n", body]
    end
  end

  defp table_row(cells) do
    escaped = Enum.map(cells, &escape_cell/1)
    ["| ", intersperse_iodata(escaped, " | "), " |"]
  end

  defp escape_cell(value) do
    value
    |> stringify()
    |> String.replace("|", "\\|")
    |> String.replace("\n", " ")
  end

  defp cell_value(row, col) when is_map(row) do
    Map.get(row, col, Map.get(row, to_string(col)))
  end

  defp cell_value(_row, _col), do: nil

  defp stringify(nil), do: ""
  defp stringify(s) when is_binary(s), do: s
  defp stringify(n) when is_number(n) or is_boolean(n) or is_atom(n), do: to_string(n)

  defp stringify(list) when is_list(list),
    do: list |> Enum.map(&stringify/1) |> Enum.join(", ")

  defp stringify(%{"type" => "text", "text" => t}) when is_binary(t), do: t
  defp stringify(%{"text" => t}) when is_binary(t), do: t
  defp stringify(%{"content" => c}), do: stringify(c)
  defp stringify(other), do: inspect(other)
end
