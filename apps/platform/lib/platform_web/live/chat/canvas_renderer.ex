defmodule PlatformWeb.Chat.CanvasRenderer do
  @moduledoc """
  Phoenix component module that renders a canonical `CanvasDocument` node tree
  recursively.

  Use `canvas_document/1` as the top-level entry point. It inspects the canvas
  state, and if it contains a version 1 canonical document (detected via the
  presence of `"version"` and `"root"` keys), renders through this renderer.
  Falls back gracefully when a node type is unknown.

  ## Supported node types

  - `stack`    — vertical flex container with optional `gap` prop
  - `row`      — horizontal flex container with optional `gap` prop
  - `card`     — bordered card with optional `title` prop
  - `text`     — plain text with optional `size`/`weight` props
  - `markdown` — renders `content` prop as pre-formatted text
  - `mermaid`  — renders `source` prop as an interactive Mermaid diagram via client-side JS
  - `table`    — renders `columns` + `rows` props as an HTML table
  - `code`     — renders `source` prop inside `<pre><code>`
  - `badge`    — small rounded label from `value` prop
  - `heading`  — h1–h4 heading from `value` + `level` props
  """

  use PlatformWeb, :html

  alias Platform.Chat.Canvas

  # ---------------------------------------------------------------------------
  # Top-level entry point
  # ---------------------------------------------------------------------------

  @doc """
  Render a canvas using the canonical document renderer if the canvas state
  contains a canonical document, otherwise fall back to `CanvasComponents`.

  This is the single public entry point used by `ChatLive`.
  """
  attr(:canvas, Canvas, required: true)
  attr(:inline, :boolean, default: false)

  def canvas_document(assigns) do
    state = assigns.canvas.state || %{}

    cond do
      url_canvas?(state) ->
        ~H"""
        <div
          id={"canvas-url-#{@canvas.id}"}
          class={[
            "rounded-2xl border border-base-300 bg-base-100 shadow-sm overflow-hidden",
            @inline && "cursor-pointer"
          ]}
          phx-click={if(@inline, do: "open_canvas")}
          phx-value-canvas-id={if(@inline, do: @canvas.id)}
        >
          <header class="flex items-center justify-between border-b border-base-300 bg-base-200 px-4 py-2">
            <div class="min-w-0">
              <p class="text-sm font-semibold text-base-content truncate">
                {@canvas.title || "Web Canvas"}
              </p>
              <p class="text-[11px] uppercase tracking-widest text-base-content/50 truncate">
                {URI.parse(@canvas.state["url"]).host || "canvas"}
              </p>
            </div>
            <span class="hero-arrow-top-right-on-square size-4 text-base-content/40 flex-shrink-0"></span>
          </header>
          <div class={[
            "w-full bg-white relative",
            if(@inline, do: "h-48 sm:h-56", else: "h-[60vh] min-h-[300px]")
          ]}>
            <iframe
              src={@canvas.state["url"]}
              class="h-full w-full border-0"
              sandbox="allow-scripts allow-same-origin allow-popups allow-forms"
              loading="lazy"
              title={@canvas.title || "Canvas"}
            />
            <div
              :if={@inline}
              class="absolute inset-0 cursor-pointer"
              aria-hidden="true"
            />
          </div>
        </div>
        """

      a2ui_canvas?(state) ->
        assigns = assign(assigns, :a2ui_nodes, parse_a2ui(state["a2ui_content"]))

        ~H"""
        <div
          id={"canvas-a2ui-#{@canvas.id}"}
          class={[
            "rounded-2xl border border-base-300 bg-base-100 shadow-sm overflow-hidden",
            @inline && "cursor-pointer"
          ]}
          phx-click={if(@inline, do: "open_canvas")}
          phx-value-canvas-id={if(@inline, do: @canvas.id)}
        >
          <div class="p-4 flex flex-col gap-3">
            <.render_node :for={node <- @a2ui_nodes} node={node} />
          </div>
        </div>
        """

      canonical_document?(state) ->
        ~H"""
        <div
          id={"canvas-doc-#{@canvas.id}"}
          class={[
            "overflow-x-auto",
            @inline && "cursor-pointer"
          ]}
          phx-click={if(@inline, do: "open_canvas")}
          phx-value-canvas-id={if(@inline, do: @canvas.id)}
        >
          <.render_node node={@canvas.state["root"]} />
        </div>
        """

      true ->
        ~H"""
        <PlatformWeb.Chat.CanvasComponents.canvas canvas={@canvas} />
        """
    end
  end

  # ---------------------------------------------------------------------------
  # Node renderer (recursive)
  # ---------------------------------------------------------------------------

  @doc false
  attr(:node, :map, required: true)

  def render_node(%{node: %{"type" => "stack"} = node} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <div
      class="flex flex-col"
      style={"gap: #{@node["props"]["gap"] || 8}px"}
    >
      <.render_node :for={child <- @node["children"] || []} node={child} />
    </div>
    """
  end

  def render_node(%{node: %{"type" => "row"} = node} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <div
      class="flex flex-row flex-wrap"
      style={"gap: #{@node["props"]["gap"] || 8}px"}
    >
      <.render_node :for={child <- @node["children"] || []} node={child} />
    </div>
    """
  end

  def render_node(%{node: %{"type" => "card"} = node} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-200 p-3 flex flex-col gap-2">
      <p
        :if={@node["props"]["title"]}
        class="text-xs font-semibold uppercase tracking-widest text-base-content/50"
      >
        {@node["props"]["title"]}
      </p>
      <.render_node :for={child <- @node["children"] || []} node={child} />
    </div>
    """
  end

  def render_node(%{node: %{"type" => "text"} = node} = assigns) do
    assigns =
      assigns
      |> assign(:node, node)
      |> assign(:text_class, text_size_class(node))

    ~H"""
    <p class={@text_class}>
      {@node["props"]["value"] || ""}
    </p>
    """
  end

  def render_node(%{node: %{"type" => "markdown"} = node} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-200 p-3">
      <pre class="whitespace-pre-wrap text-xs leading-5 text-base-content/80 font-mono">{@node["props"]["content"] || ""}</pre>
    </div>
    """
  end

  def render_node(%{node: %{"type" => "mermaid"} = node} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <div
      id={"mermaid-#{@node["id"]}"}
      phx-hook="MermaidDiagram"
      data-source={@node["props"]["source"] || ""}
      class="rounded-xl border border-base-300 bg-base-100 p-3 overflow-x-auto"
    >
      <div class="mermaid-container flex items-center justify-center min-h-[100px]">
        <span class="loading loading-spinner loading-sm text-base-content/30"></span>
      </div>
    </div>
    """
  end

  def render_node(%{node: %{"type" => "table"} = node} = assigns) do
    props = node["props"] || %{}
    columns = List.wrap(props["columns"])
    rows = List.wrap(props["rows"])

    assigns =
      assigns
      |> assign(:node, node)
      |> assign(:columns, columns)
      |> assign(:rows, rows)

    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-zebra table-sm w-full">
        <thead>
          <tr>
            <th :for={col <- @columns} class="text-xs uppercase tracking-widest">
              {col}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td :for={col <- @columns} class="align-top text-sm">
              {cell_value(row, col)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def render_node(%{node: %{"type" => "code"} = node} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-900 overflow-x-auto">
      <div class="flex items-center justify-between border-b border-base-300 bg-base-200 px-3 py-1">
        <span class="text-[11px] uppercase tracking-widest text-base-content/50">
          {@node["props"]["language"] || "code"}
        </span>
      </div>
      <pre class="p-3 text-xs leading-5 text-base-content overflow-x-auto"><code>{@node["props"]["source"] || ""}</code></pre>
    </div>
    """
  end

  def render_node(%{node: %{"type" => "badge"} = node} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <span class="inline-block rounded-full bg-base-300 px-2 py-0.5 text-[11px] text-base-content/60 uppercase tracking-widest">
      {@node["props"]["value"] || ""}
    </span>
    """
  end

  def render_node(%{node: %{"type" => "heading"} = node} = assigns) do
    level = get_in(node, ["props", "level"]) || 2
    assigns = assigns |> assign(:node, node) |> assign(:level, level)

    ~H"""
    <%= case @level do %>
      <% 1 -> %>
        <h1 class="text-2xl font-bold text-base-content">{@node["props"]["value"] || ""}</h1>
      <% 2 -> %>
        <h2 class="text-xl font-bold text-base-content">{@node["props"]["value"] || ""}</h2>
      <% 3 -> %>
        <h3 class="text-lg font-semibold text-base-content">{@node["props"]["value"] || ""}</h3>
      <% _ -> %>
        <h4 class="text-base font-semibold text-base-content">{@node["props"]["value"] || ""}</h4>
    <% end %>
    """
  end

  # Fallback for unknown / nil node types
  def render_node(%{node: node} = assigns) when is_map(node) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <div class="rounded border border-dashed border-base-300 bg-base-200 px-3 py-2 text-xs text-base-content/40">
      [unknown node type: {@node["type"] || "?"}]
    </div>
    """
  end

  def render_node(assigns) do
    ~H"""
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns true if the canvas state map contains a URL for iframe rendering.
  """
  @spec url_canvas?(map()) :: boolean()
  def url_canvas?(%{"url" => url}) when is_binary(url) and url != "", do: true
  def url_canvas?(_), do: false

  @doc """
  Returns true if the canvas state map contains A2UI JSONL content.
  """
  @spec a2ui_canvas?(map()) :: boolean()
  def a2ui_canvas?(%{"a2ui_content" => content}) when is_binary(content) and content != "",
    do: true

  def a2ui_canvas?(_), do: false

  @doc """
  Parses A2UI JSONL content into a list of node maps for rendering.
  Each line is a JSON object representing a renderable node tree.
  """
  @spec parse_a2ui(String.t() | nil) :: [map()]
  def parse_a2ui(nil), do: []
  def parse_a2ui(""), do: []

  def parse_a2ui(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, node} when is_map(node) -> [node]
        _ -> []
      end
    end)
  end

  @doc """
  Returns true if the canvas state map contains a canonical document (v1).
  """
  @spec canonical_document?(map()) :: boolean()
  def canonical_document?(%{"version" => v, "root" => root})
      when is_integer(v) and is_map(root),
      do: true

  def canonical_document?(_), do: false

  defp text_size_class(%{"props" => props}) when is_map(props) do
    size = Map.get(props, "size", "sm")
    weight = Map.get(props, "weight", "normal")

    size_cls =
      case size do
        "xs" -> "text-xs"
        "sm" -> "text-sm"
        "base" -> "text-base"
        "lg" -> "text-lg"
        "xl" -> "text-xl"
        "2xl" -> "text-2xl"
        _ -> "text-sm"
      end

    weight_cls =
      case weight do
        "bold" -> "font-bold"
        "semibold" -> "font-semibold"
        "medium" -> "font-medium"
        _ -> ""
      end

    "#{size_cls} #{weight_cls} text-base-content leading-6"
  end

  defp text_size_class(_), do: "text-sm text-base-content leading-6"

  defp cell_value(row, col) when is_map(row) do
    Map.get(row, col, Map.get(row, to_string(col), "—"))
  end

  defp cell_value(_row, _col), do: "—"
end
