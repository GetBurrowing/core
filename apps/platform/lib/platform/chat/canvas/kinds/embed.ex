defmodule Platform.Chat.Canvas.Kinds.Embed do
  @moduledoc """
  Sandboxed inline-HTML mockup leaf.

  Renders an `<iframe srcdoc=...>` with the most-restrictive sandbox
  (`sandbox=""` — no scripts, no same-origin, no forms, no popups, no
  top-level navigation). Intended for design mockups and static HTML
  previews authored by agents; the empty-sandbox attribute is the
  primary defence and `validate_props/1` provides defence-in-depth by
  rejecting `srcdoc` payloads that contain `<script` substrings or
  exceed a hard size cap.

  ## Props

    * `srcdoc` (string, required) — full HTML document to render in the
      sandboxed iframe. Capped at 256 KB and may not contain `<script`
      (case-insensitive).
    * `height` (integer, optional, default 400) — iframe height in
      pixels. Must lie in `100..2000`.
    * `width` (integer, optional, default 1080) — declared design width
      in pixels. Must lie in `320..2400`. Used by the client-side
      auto-scale hook to compute `transform: scale()` when the
      container is narrower than the declared width.
    * `min_scale` (float, optional) — minimum allowed auto-scale ratio
      in `0.0..1.0`. Below this floor the renderer falls back to
      horizontal scroll at natural size instead of scaling the iframe
      down further. Absent means "always scale to fit, no floor".
    * `scripts` (boolean, optional, default false) — see below.
    * `prototype_ref` (map, server-set) — see below.

  ## `scripts: true` (task 01a1316b-677a; ADR 0057)

  With `scripts` false or absent NOTHING changes: same validation (the
  `<script` rejection included) and the same markup, byte for byte
  (`test/support/fixtures/canvas/embed_render_*.html` pins it).

  With `scripts: true` the `srcdoc` may contain `<script` (the 256 KB cap
  still applies) and is NEVER rendered inline. On every write
  `Platform.Chat.Canvas.ScriptedEmbeds` publishes it as a single-file
  prototype owned by this canvas node and stamps `prototype_ref`
  (`%{"prototype_id", "version", "sha256"}`) onto the node; any ref a client
  sends is replaced. Render frames `/proto/<id>/<version>/` with
  `sandbox="allow-scripts"` and nothing else, exactly as the `prototype`
  kind does, so the script runs under the serve route's sealed CSP: opaque
  origin, no network, no Suite cookies, no access to the page around it.

  The scripted wrapper carries `data-scripted-src` and NO `data-srcdoc`: the
  `EmbedCanvasScale` hook writes `srcdoc` into its iframe on update, and
  `srcdoc` wins over `src`, so a script-bearing `data-srcdoc` would run in an
  `allow-scripts` frame under the SUITE page's CSP instead of the sealed one.
  Its wrapper id also differs (`embed-canvas-scripted-...`), so toggling
  `scripts` replaces the element instead of reusing an iframe whose sandbox
  belongs to the other mode. A scripted node with no ref (the stamp has not
  run, or a hand-written document) renders a neutral panel and no iframe;
  it never falls back to `srcdoc`.
  """

  use Platform.Chat.Canvas.Kind

  @max_srcdoc_bytes 256 * 1024
  @default_height 400
  @min_height 100
  @max_height 2000
  @default_width 1080
  @min_width 320
  @max_width 2400

  @impl Platform.Chat.Canvas.Kind
  def children, do: :none

  @impl Platform.Chat.Canvas.Kind
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["srcdoc"],
      "properties" => %{
        "srcdoc" => %{
          "type" => "string",
          "description" =>
            "Full HTML document rendered inside a sandboxed iframe. " <>
              "Maximum 256 KB. May not contain <script tags (case-insensitive) " <>
              "unless `scripts` is true."
        },
        "scripts" => %{
          "type" => "boolean",
          "description" =>
            "Run the srcdoc's JavaScript (default false). Use for interactive mockups and " <>
              "small widgets that need JS. Scripts run sealed: no network, no Suite cookies " <>
              "and no access to the surrounding page. Needs prototypes enabled by an admin " <>
              "(/admin/prototypes); otherwise the write is refused with prototypes_disabled."
        },
        "prototype_ref" => %{
          "type" => "object",
          "description" =>
            "Set by the server for scripts: true embeds (the published version the HTML " <>
              "runs as); any value you send is replaced."
        },
        "height" => %{
          "type" => "integer",
          "minimum" => @min_height,
          "maximum" => @max_height,
          "description" => "Iframe height in pixels (default 400)."
        },
        "width" => %{
          "type" => "integer",
          "minimum" => @min_width,
          "maximum" => @max_width,
          "description" =>
            "Declared design width in pixels (default 1080). " <>
              "Drives client-side auto-scale on narrower viewports."
        },
        "min_scale" => %{
          "type" => "number",
          "minimum" => 0.0,
          "maximum" => 1.0,
          "description" =>
            "Smallest allowed auto-scale ratio (0.0..1.0). " <>
              "Below this floor, fall back to horizontal scroll at natural size. " <>
              "Absent means no floor — always scale to fit."
        }
      }
    }
  end

  @impl true
  def validate_props(props) when is_map(props) do
    with :ok <- validate_scripts(Map.get(props, "scripts")),
         :ok <- validate_srcdoc(Map.get(props, "srcdoc"), Map.get(props, "scripts") == true),
         :ok <- validate_prototype_ref(Map.get(props, "prototype_ref")),
         :ok <- validate_height(Map.get(props, "height")),
         :ok <- validate_width(Map.get(props, "width")),
         :ok <- validate_min_scale(Map.get(props, "min_scale")) do
      :ok
    end
  end

  defp validate_scripts(nil), do: :ok
  defp validate_scripts(b) when is_boolean(b), do: :ok
  defp validate_scripts(_), do: {:error, "scripts must be a boolean"}

  # `scripts?` lifts ONLY the `<script` rejection; the size cap holds either way.
  defp validate_srcdoc(srcdoc, scripts?) when is_binary(srcdoc) do
    cond do
      byte_size(srcdoc) > @max_srcdoc_bytes ->
        {:error, "srcdoc exceeds maximum size of 256KB"}

      not scripts? and String.contains?(String.downcase(srcdoc), "<script") ->
        {:error, "srcdoc may not contain <script tags"}

      true ->
        :ok
    end
  end

  defp validate_srcdoc(_, _), do: :ok

  # Server-set and always replaced or stripped by `ScriptedEmbeds.stamp/2`
  # before it is stored, so the only check is its shape.
  defp validate_prototype_ref(nil), do: :ok
  defp validate_prototype_ref(ref) when is_map(ref), do: :ok
  defp validate_prototype_ref(_), do: {:error, "prototype_ref is set by the server"}

  defp validate_height(nil), do: :ok

  defp validate_height(height) when is_integer(height) do
    if height in @min_height..@max_height do
      :ok
    else
      {:error, "height must be between 100 and 2000 pixels"}
    end
  end

  defp validate_height(_), do: :ok

  defp validate_width(nil), do: :ok

  defp validate_width(width) when is_integer(width) do
    if width in @min_width..@max_width do
      :ok
    else
      {:error, "width must be between 320 and 2400 pixels"}
    end
  end

  defp validate_width(_), do: {:error, "width must be an integer between 320 and 2400 pixels"}

  defp validate_min_scale(nil), do: :ok

  defp validate_min_scale(scale) when is_number(scale) do
    if scale >= 0.0 and scale <= 1.0 do
      :ok
    else
      {:error, "min_scale must be between 0.0 and 1.0"}
    end
  end

  defp validate_min_scale(_),
    do: {:error, "min_scale must be a number between 0.0 and 1.0"}

  attr(:node, :map, required: true)
  attr(:dom_id_scope, :string, default: nil)

  @impl Platform.Chat.Canvas.Kind
  def render(assigns) do
    props = assigns.node["props"] || %{}

    height =
      case props["height"] do
        h when is_integer(h) and h >= @min_height and h <= @max_height -> h
        _ -> @default_height
      end

    width =
      case props["width"] do
        w when is_integer(w) and w >= @min_width and w <= @max_width -> w
        _ -> @default_width
      end

    min_scale =
      case props["min_scale"] do
        s when is_number(s) and s >= 0.0 and s <= 1.0 -> s
        _ -> nil
      end

    node_id = assigns.node["id"] || "embed"

    if props["scripts"] == true do
      render_scripted(assigns, props, node_id, width, height, min_scale)
    else
      render_srcdoc(assigns, props, node_id, width, height, min_scale)
    end
  end

  # The `scripts` false/absent branch: main's markup, byte for byte.
  defp render_srcdoc(assigns, props, node_id, width, height, min_scale) do
    wrapper_id =
      case assigns[:dom_id_scope] do
        scope when is_binary(scope) and scope != "" -> "embed-canvas-#{node_id}-#{scope}"
        _ -> "embed-canvas-#{node_id}"
      end

    assigns =
      assigns
      |> assign(:srcdoc, props["srcdoc"] || "")
      |> assign(:declared_width, width)
      |> assign(:declared_height, height)
      |> assign(:min_scale, min_scale)
      |> assign(:wrapper_id, wrapper_id)
      |> assign(
        :iframe_style,
        "width: #{width}px; height: #{height}px; border: 0; display: block;"
      )
      |> assign(:wrapper_style, "height: #{height}px;")

    ~H"""
    <div
      id={@wrapper_id}
      phx-hook="EmbedCanvasScale"
      phx-update="ignore"
      data-declared-width={@declared_width}
      data-declared-height={@declared_height}
      data-min-scale={@min_scale}
      data-srcdoc={@srcdoc}
      class="group relative overflow-hidden rounded-xl border border-edge"
      style={@wrapper_style}
    >
      <iframe srcdoc={@srcdoc} sandbox="" style={@iframe_style}></iframe>
      <button
        type="button"
        data-embed-expand
        aria-label="Expand canvas to full screen"
        title="Expand"
        class={
          "absolute top-2 right-2 z-10 rounded-md bg-base-100/90 p-1.5 text-base-content/70 shadow-md " <>
            "opacity-50 transition-opacity group-hover:opacity-100 focus-visible:opacity-100 " <>
            "hover:bg-base-100 hover:text-base-content"
        }
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
          stroke-width="1.5"
          stroke="currentColor"
          class="h-4 w-4"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M3.75 3.75v4.5m0-4.5h4.5m-4.5 0L9 9M3.75 20.25v-4.5m0 4.5h4.5m-4.5 0L9 15M20.25 3.75h-4.5m4.5 0v4.5m0-4.5L15 9m5.25 11.25h-4.5m4.5 0v-4.5m0 4.5L15 15"
          />
        </svg>
      </button>
    </div>
    """
  end

  defp render_scripted(assigns, props, node_id, width, height, min_scale) do
    wrapper_id =
      case assigns[:dom_id_scope] do
        scope when is_binary(scope) and scope != "" -> "embed-canvas-scripted-#{node_id}-#{scope}"
        _ -> "embed-canvas-scripted-#{node_id}"
      end

    assigns =
      assigns
      |> assign(:src, scripted_src(props["prototype_ref"]))
      |> assign(:declared_width, width)
      |> assign(:declared_height, height)
      |> assign(:min_scale, min_scale)
      |> assign(:wrapper_id, wrapper_id)
      |> assign(
        :iframe_style,
        "width: #{width}px; height: #{height}px; border: 0; display: block;"
      )
      |> assign(:wrapper_style, "height: #{height}px;")

    ~H"""
    <div
      :if={is_nil(@src)}
      id={@wrapper_id}
      data-role="embed-scripted-unavailable"
      class="rounded-xl border border-edge bg-base-200 px-4 py-6 text-center text-sm text-base-content/60"
    >
      Scripted embed unavailable
    </div>
    <div
      :if={@src}
      id={@wrapper_id}
      phx-hook="EmbedCanvasScale"
      phx-update="ignore"
      data-declared-width={@declared_width}
      data-declared-height={@declared_height}
      data-min-scale={@min_scale}
      data-scripted-src={@src}
      class="group relative overflow-hidden rounded-xl border border-edge"
      style={@wrapper_style}
    >
      <iframe
        src={@src}
        sandbox="allow-scripts"
        referrerpolicy="no-referrer"
        title="Scripted embed"
        style={@iframe_style}
      >
      </iframe>
      <button
        type="button"
        data-embed-expand
        aria-label="Expand canvas to full screen"
        title="Expand"
        class={
          "absolute top-2 right-2 z-10 rounded-md bg-base-100/90 p-1.5 text-base-content/70 shadow-md " <>
            "opacity-50 transition-opacity group-hover:opacity-100 focus-visible:opacity-100 " <>
            "hover:bg-base-100 hover:text-base-content"
        }
      >
        <span class="hero-arrows-pointing-out size-4" aria-hidden="true"></span>
      </button>
    </div>
    """
  end

  # Only a well-formed ref frames anything; the server stamps it, so a
  # malformed one means the document was written around the stamp.
  defp scripted_src(%{"prototype_id" => id, "version" => version})
       when is_integer(version) and version > 0 do
    if Platform.UUID.valid?(id), do: Platform.Prototypes.url(id, version), else: nil
  end

  defp scripted_src(_), do: nil
end
