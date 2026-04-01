defmodule PlatformWeb.Chat.CanvasRenderer do
  @moduledoc """
  Phoenix component module that renders a canonical `CanvasDocument` node tree
  recursively.

  Use `canvas_document/1` as the top-level entry point. It inspects the canvas
  state, and if it contains a version 1 canonical document (detected via the
  presence of `"version"` and `"root"` keys), renders through this renderer.
  Falls back gracefully when a node type is unknown.

  ## Supported node types

  - `stack`          — vertical flex container with optional `gap` prop
  - `row`            — horizontal flex container with optional `gap` prop
  - `card`           — bordered card with optional `title` prop
  - `text`           — plain text with optional `size`/`weight` props
  - `markdown`       — renders `content` prop as pre-formatted text
  - `mermaid`        — renders `source` prop as an interactive Mermaid diagram via client-side JS
  - `table`          — renders `columns` + `rows` props as an HTML table
  - `code`           — renders `source` prop inside `<pre><code>`
  - `badge`          — small rounded label from `value` prop
  - `heading`        — h1–h4 heading from `value` + `level` props
  - `image`          — renders `src` prop as an `<img>` tag with optional `alt`, `caption`, `border`, `rounded` props
  - `checklist`      — ordered list of checklist items with optional `title` prop; children must be `checklist_item` nodes
  - `checklist_item` — single checklist row with `label` prop and optional `checked` (boolean) and `note` props
  - `action_row`     — horizontal strip of labelled action buttons; each child button has `label`, `event`, and optional `payload` + `variant` props
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
  attr(:show_header, :boolean, default: true)

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
            <.render_node :for={node <- @a2ui_nodes} node={node} canvas_id={@canvas.id} />
          </div>
        </div>
        """

      review_evidence_manifest?(state) ->
        artifacts = review_artifacts(state)

        assigns =
          assigns
          |> assign(:summary, review_summary(state))
          |> assign(:checks, review_checks(state))
          |> assign(:image_artifacts, Enum.filter(artifacts, &image_artifact?/1))
          |> assign(:supporting_artifacts, Enum.reject(artifacts, &image_artifact?/1))

        ~H"""
        <div id={"canvas-review-evidence-#{@canvas.id}"} class="space-y-4 p-4">
          <div :if={@summary} class="rounded-xl border border-base-300 bg-base-100 p-4">
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Summary
            </p>
            <p class="mt-2 text-sm leading-6 text-base-content/80">{@summary}</p>
          </div>

          <div :if={@checks != []} class="rounded-xl border border-base-300 bg-base-100 p-4">
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Checks
            </p>
            <ul class="mt-2 space-y-2">
              <li :for={check <- @checks} class="flex items-start gap-2 text-sm text-base-content/80">
                <span class="hero-check-circle size-4 shrink-0 text-success mt-0.5"></span>
                <span>{check}</span>
              </li>
            </ul>
          </div>

          <div :if={@image_artifacts != []} class="space-y-2">
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Preview
            </p>
            <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
              <a
                :for={artifact <- @image_artifacts}
                href={artifact_preview_url(artifact["path"])}
                target="_blank"
                rel="noreferrer"
                class="overflow-hidden rounded-xl border border-base-300 bg-base-100 transition hover:border-primary/40 hover:shadow-sm"
              >
                <img
                  src={artifact_preview_url(artifact["path"])}
                  alt={artifact_label(artifact)}
                  class="block h-48 w-full object-cover bg-base-200"
                  loading="lazy"
                />
                <div class="space-y-1 p-3">
                  <div class="text-sm font-medium text-base-content">{artifact_label(artifact)}</div>
                  <div class="text-xs text-base-content/50">{Path.basename(artifact["path"] || "")}</div>
                </div>
              </a>
            </div>
          </div>

          <div :if={@supporting_artifacts != []} class="rounded-xl border border-base-300 bg-base-100 p-4">
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Supporting files
            </p>
            <div class="mt-2 space-y-2">
              <a
                :for={artifact <- @supporting_artifacts}
                href={artifact_preview_url(artifact["path"])}
                target="_blank"
                rel="noreferrer"
                class="flex items-center justify-between gap-3 rounded-lg border border-base-300 bg-base-200/40 px-3 py-2 text-sm hover:border-primary/40 hover:bg-base-200"
              >
                <div class="min-w-0">
                  <div class="truncate font-medium text-base-content">{artifact_label(artifact)}</div>
                  <div class="truncate text-xs text-base-content/50">{artifact["path"]}</div>
                </div>
                <span class="hero-arrow-top-right-on-square size-4 shrink-0 text-base-content/40"></span>
              </a>
            </div>
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
          <.render_node node={@canvas.state["root"]} canvas_id={@canvas.id} />
        </div>
        """

      flat_nodes_array?(state) ->
        assigns = assign(assigns, :synthetic_root, normalize_flat_nodes(state))

        ~H"""
        <div
          id={"canvas-flat-#{@canvas.id}"}
          class={[
            "overflow-x-auto",
            @inline && "cursor-pointer"
          ]}
          phx-click={if(@inline, do: "open_canvas")}
          phx-value-canvas-id={if(@inline, do: @canvas.id)}
        >
          <.render_node node={@synthetic_root} canvas_id={@canvas.id} />
        </div>
        """

      bare_node?(state) ->
        ~H"""
        <div
          id={"canvas-bare-#{@canvas.id}"}
          class={[
            "overflow-x-auto",
            @inline && "cursor-pointer"
          ]}
          phx-click={if(@inline, do: "open_canvas")}
          phx-value-canvas-id={if(@inline, do: @canvas.id)}
        >
          <.render_node node={@canvas.state} canvas_id={@canvas.id} />
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
  attr(:canvas_id, :string, default: nil)

  def render_node(%{node: %{"type" => "stack"} = node} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <div
      class="flex flex-col"
      style={"gap: #{@node["props"]["gap"] || 8}px"}
    >
      <.render_node :for={child <- @node["children"] || []} node={child} canvas_id={@canvas_id} />
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
      <.render_node :for={child <- @node["children"] || []} node={child} canvas_id={@canvas_id} />
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
      <.render_node :for={child <- @node["children"] || []} node={child} canvas_id={@canvas_id} />
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

  def render_node(%{node: %{"type" => "image"} = node} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <div class={[
      "overflow-hidden",
      @node["props"]["rounded"] != false && "rounded-xl"
    ]}>
      <img
        src={@node["props"]["src"] || ""}
        alt={@node["props"]["alt"] || ""}
        class={[
          "max-w-full h-auto block",
          @node["props"]["border"] && "border border-base-300"
        ]}
        style={if caption = @node["props"]["caption"], do: "", else: ""}
      />
      <p
        :if={@node["props"]["caption"]}
        class="text-[11px] text-base-content/50 text-center mt-1"
      >
        {@node["props"]["caption"]}
      </p>
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

  def render_node(%{node: %{"type" => "checklist"} = node} = assigns) do
    children = node["children"] || []
    total = length(children)
    complete = Enum.count(children, fn c -> get_in(c, ["props", "state"]) == "complete" end)

    assigns =
      assigns
      |> assign(:node, node)
      |> assign(:total, total)
      |> assign(:complete, complete)

    ~H"""
    <div class="card-checklist flex flex-col gap-1 rounded-xl border border-base-300 bg-base-200 p-3">
      <div class="flex items-center justify-between mb-1">
        <p
          :if={@node["props"]["title"]}
          class="text-xs font-semibold uppercase tracking-widest text-base-content/50"
        >
          {@node["props"]["title"]}
        </p>
        <span :if={@total > 0} class="text-xs text-base-content/40">
          {@complete} / {@total} tasks
        </span>
      </div>
      <.render_node :for={child <- @node["children"] || []} node={child} canvas_id={@canvas_id} />
    </div>
    """
  end

  def render_node(%{node: %{"type" => "checklist_item"} = node} = assigns) do
    state = get_in(node, ["props", "state"]) || "pending"

    assigns =
      assigns
      |> assign(:node, node)
      |> assign(:state, state)

    ~H"""
    <div class="flex items-start gap-2 py-0.5" data-state={@state}>
      <span class={[
        "mt-0.5 size-4 shrink-0",
        @state == "complete" && "hero-check-circle text-success",
        @state == "active" && "hero-bolt text-primary",
        @state not in ["complete", "active"] && "hero-stop-circle text-base-content/25"
      ]}>
      </span>
      <div class="min-w-0">
        <p class={[
          "text-sm leading-5",
          @state == "complete" && "line-through text-base-content/40",
          @state != "complete" && "text-base-content"
        ]}>
          {@node["props"]["label"] || ""}
        </p>
        <p
          :if={@node["props"]["note"]}
          class="text-xs text-base-content/50 leading-4 mt-0.5"
        >
          {@node["props"]["note"]}
        </p>
      </div>
    </div>
    """
  end

  def render_node(%{node: %{"type" => "action_row"} = node} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <div class="flex flex-row flex-wrap gap-2 mt-1">
      <p
        :if={@node["props"]["label"]}
        class="w-full text-xs font-semibold uppercase tracking-widest text-base-content/50 mb-0.5"
      >
        {@node["props"]["label"]}
      </p>
      <.render_node :for={child <- @node["children"] || []} node={child} canvas_id={@canvas_id} />
    </div>
    """
  end

  def render_node(%{node: %{"type" => "action_button"} = node} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <button
      class={[
        "btn btn-sm",
        action_button_class(@node["props"]["variant"])
      ]}
      phx-click="canvas_action"
      phx-value-value={@node["props"]["value"] || ""}
      phx-value-canvas-id={@node["props"]["canvas_id"] || @canvas_id || ""}
    >
      {@node["props"]["label"] || "Action"}
    </button>
    """
  end

  def render_node(%{node: %{"type" => "key_value"} = node} = assigns) do
    rows = node["props"]["rows"] || node["children"] || []
    assigns = assign(assigns, :node, node) |> assign(:rows, rows)

    ~H"""
    <div class="rounded-lg border border-base-300 overflow-hidden text-sm">
      <div
        :for={row <- @rows}
        class="flex border-b border-base-300 last:border-b-0"
      >
        <div class="w-2/5 px-3 py-1.5 bg-base-200 font-medium text-base-content/70 shrink-0">
          {row_key(row)}
        </div>
        <div class="flex-1 px-3 py-1.5 text-base-content">
          {row_value(row)}
        </div>
      </div>
    </div>
    """
  end

  def render_node(%{node: %{"type" => "status"} = node} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <div class="flex items-center gap-2">
      <span
        :if={@node["props"]["label"]}
        class={[
          "inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-semibold",
          status_color(@node["props"]["color"] || @node["props"]["variant"])
        ]}
      >
        <span :if={@node["props"]["icon"]} class="size-3">{@node["props"]["icon"]}</span>
        {@node["props"]["label"]}
      </span>
    </div>
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

  @doc """
  Returns true if the canvas state contains a flat `nodes` array without canonical
  document wrapping. This is a backward-compatible fallback for agents that emit
  the simpler `%{"nodes" => [...]}` format instead of `%{"version" => 1, "root" => ...}`.
  """
  @spec flat_nodes_array?(map()) :: boolean()
  def flat_nodes_array?(%{"nodes" => nodes}) when is_list(nodes) and nodes != [], do: true
  def flat_nodes_array?(_), do: false

  @doc """
  Returns true if the canvas state is itself a bare renderable node — a map with
  a `"type"` key. This catches agent-emitted canvases where the node tree was set
  directly as the state without a canonical or flat-nodes wrapper.
  """
  @spec bare_node?(map()) :: boolean()
  def bare_node?(%{"type" => type}) when is_binary(type), do: true
  def bare_node?(_), do: false

  @doc """
  Converts a flat `%{"nodes" => [...]}` state into a canonical document root node.
  Each node in the array is normalized: if props are inlined at the top level
  (e.g. `%{"type" => "text", "value" => "hi"}`), they are moved under a `"props"` key.
  The result is a `stack` node wrapping all normalized children.
  """
  @spec normalize_flat_nodes(map()) :: map()
  def normalize_flat_nodes(%{"nodes" => nodes}) when is_list(nodes) do
    children = Enum.map(nodes, &normalize_flat_node/1)
    %{"type" => "stack", "props" => %{"gap" => 8}, "children" => children}
  end

  def normalize_flat_nodes(_), do: %{"type" => "stack", "children" => []}

  defp normalize_flat_node(%{"type" => type, "props" => props} = node) when is_map(props) do
    children = normalize_flat_children(node)
    %{"type" => type, "props" => props, "children" => children}
  end

  defp normalize_flat_node(%{"type" => type} = node) do
    reserved = ~w(type children)
    props = Map.drop(node, reserved)
    children = normalize_flat_children(node)
    %{"type" => type, "props" => props, "children" => children}
  end

  defp normalize_flat_node(node), do: node

  defp normalize_flat_children(%{"children" => children}) when is_list(children) do
    Enum.map(children, &normalize_flat_node/1)
  end

  defp normalize_flat_children(_), do: []

  defp review_evidence_manifest?(%{"summary" => summary, "artifacts" => artifacts})
       when is_binary(summary) and is_list(artifacts),
       do: true

  defp review_evidence_manifest?(%{"checks" => checks, "artifacts" => artifacts})
       when is_list(checks) and is_list(artifacts),
       do: true

  defp review_evidence_manifest?(_), do: false

  defp review_summary(%{"summary" => summary}) when is_binary(summary) and summary != "",
    do: summary

  defp review_summary(_), do: nil

  defp review_checks(%{"checks" => checks}) when is_list(checks) do
    checks
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp review_checks(_), do: []

  defp review_artifacts(%{"artifacts" => artifacts}) when is_list(artifacts) do
    Enum.filter(artifacts, fn
      %{"path" => path} when is_binary(path) and path != "" -> true
      _ -> false
    end)
  end

  defp review_artifacts(_), do: []

  defp artifact_label(%{"label" => label}) when is_binary(label) and label != "", do: label
  defp artifact_label(%{"path" => path}) when is_binary(path), do: Path.basename(path)
  defp artifact_label(_), do: "Artifact"

  defp image_artifact?(%{"path" => path}) when is_binary(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"]))
  end

  defp image_artifact?(_), do: false

  defp artifact_preview_url(path) when is_binary(path) and path != "" do
    "/artifacts/preview?path=" <> URI.encode_www_form(path)
  end

  defp artifact_preview_url(_), do: "#"

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

  defp action_button_class("primary"), do: "btn-primary"
  defp action_button_class("danger"), do: "btn-error"
  defp action_button_class("ghost"), do: "btn-ghost"
  defp action_button_class("outline"), do: "btn-outline"
  defp action_button_class(_), do: "btn-outline"

  # key_value row helpers — supports both list-of-pairs and map-children formats
  defp row_key([k, _v]), do: k
  defp row_key(%{"key" => k}), do: k
  defp row_key(%{"label" => l}), do: l
  defp row_key(%{"props" => %{"key" => k}}), do: k
  defp row_key(%{"props" => %{"label" => l}}), do: l
  defp row_key(_), do: ""

  defp row_value([_k, v]), do: v
  defp row_value(%{"value" => v}), do: v
  defp row_value(%{"props" => %{"value" => v}}), do: v
  defp row_value(_), do: ""

  # status node color helpers
  defp status_color("success"), do: "bg-success/20 text-success"
  defp status_color("green"), do: "bg-success/20 text-success"
  defp status_color("warning"), do: "bg-warning/20 text-warning"
  defp status_color("yellow"), do: "bg-warning/20 text-warning"
  defp status_color("amber"), do: "bg-warning/20 text-warning"
  defp status_color("error"), do: "bg-error/20 text-error"
  defp status_color("red"), do: "bg-error/20 text-error"
  defp status_color("info"), do: "bg-info/20 text-info"
  defp status_color("blue"), do: "bg-info/20 text-info"
  defp status_color("cyan"), do: "bg-info/20 text-info"
  defp status_color(_), do: "bg-base-300 text-base-content/70"
end
