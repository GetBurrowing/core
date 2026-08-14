defmodule PlatformWeb.Components.Meeting.CanvasTile do
  @moduledoc """
  A single meeting canvas rendered as a stage tile.

  Sibling of `<.video_tile>` and `<.agent_tile>`: same footprint, same radius,
  same `id_prefix`-derived dom id and `data-role` test hooks. What differs is
  the interior — this is a DOCUMENT surface, not a video pane.

  ## Decision 1 — a LiveView-rendered tile, NOT a published LiveKit track

  The canvas reaches the tile over the RENDER path, not the MEDIA path.

    * The live-update substrate already exists. `Platform.Chat.publish_canvas_updated/1`
      broadcasts `{:canvas_updated, canvas}` on the space topic; `MeetingLive`
      already subscribes to that topic in its `connected?` mount branch and
      already has a matching `handle_info/2`. A tile therefore costs one render
      path and zero media plumbing.
    * A real track would mean rasterising the document and publishing video.
      Canvas content would then travel as pixels, and pixels cannot carry text —
      no selection, no accessibility, no crisp glyphs.
    * Text must survive as text. Even scaled down to a preview the document
      stays real DOM, which is what lets `{:canvas_updated, canvas}` repaint
      the tile with a plain LiveView diff — and what keeps the updated content
      present in the markup for assertions and assistive tech.

  ## Prohibition — the tile is a UI slot, not a roster entry

  Rendering this tile must NOT insert a `chat_participants` row, mint a
  synthetic agent, or create a LiveKit participant identity for the canvas. The
  platform already carries scars from synthetic participant rows that every
  roster query then has to filter back out. The tile is sourced purely from
  LiveView assigns and must never appear in `gallery_participants/1`,
  `strip_humans/1`, or `strip_agents/1`.

  ## Design constraints

    * Interior is a document surface: `bg-base-100`, text in `base-content`. No
      dark fill, no letterboxing.

    * It is a PREVIEW, not a readable document. Rowan, rejecting the
      crop-at-true-type-size build: *"I want it to be basically a preview, so
      constrained to the same sizing dimensions as the other participants
      tiles. It's not necessarily to see at a fine level what the content is,
      just that THERE IS content, so they can click the canvas"*. The body is
      therefore scaled to roughly a third of type size — texture that reads as
      "a document lives here", not prose. The title and timestamp are NOT
      scaled: they are the identifying affordance and must stay legible.

    * Content may never influence the tile's size, in either axis. Two
      mechanisms enforce that, and both are needed:

      1. The document is rendered inside `[data-role="canvas-tile-preview"]`,
         which is ABSOLUTELY POSITIONED inside an `overflow-hidden` box. Out of
         flow means an arbitrarily tall document contributes exactly zero to
         the tile's height, and the transform is clipped to the tile box.
      2. `.meeting-canvas-tile` carries an UNLAYERED clamp in
         `assets/css/app.css` (`min-height: 0; min-width: 0; max-*: 100%`).
         Unlayered rules beat Tailwind's `@layer utilities`, so a call site
         cannot undo the clamp by adding a utility class. Grid items default
         to `min-height: auto`, which is what previously let a tall document
         push this tile over a neighbouring face tile.

      The scale is expressed as `w-[300%] … scale-[0.3333]` rather than a fixed
      pixel width so the preview always fills the tile exactly, whatever the
      tile's measured size — the ratio is what is fixed, not a design width.

    * Same box as a face tile. `:layout` mirrors `<.video_tile>`'s attr of the
      same name and resolves to the SAME sizing classes, and app.css applies
      the `[data-gallery-cell] >` container-query rules to
      `.meeting-canvas-tile` alongside `.meeting-video-tile`. The canvas cell
      and a face cell are then the same geometry by construction rather than by
      two hand-kept-in-sync class strings.

    * A soft `base-300` fade at the BOTTOM edge signals the document continues
      past the frame.
    * Name plate: title `text-xs` in `--color-neutral` with `min-w-0 truncate`;
      relative timestamp `text-xs` in `--color-neutral` with
      `shrink-0 whitespace-nowrap`. A marker must never win space from the name
      it annotates.
    * The just-changed highlight uses `--color-primary`, applied once and then
      still. No looping pulse, no glow: perpetual motion here would compete with
      the speaking indicators on the human tiles, which must win. It is
      deliberately not `--color-warning`/`--color-error` — a canvas being
      written to is activity, not a problem.
    * No edit-count badge. The design cut it: the question in the room is what
      it said, not how many edits it took.

  ## Props

    * `:canvas` — the `Platform.Chat.Canvas` to render. Required.
    * `:id_prefix` — prefix for the tile's dom id (`<id_prefix>-<canvas id>`).
      Call sites pass DISTINCT prefixes per surface (e.g. `gallery-canvas-tile`
      vs `strip-canvas-tile`) for the same reason `<.video_tile>` does.
    * `:changed?` — when true, applies the one-shot primary highlight.
    * `:layout` — `:strip` or `:gallery`, exactly as `<.video_tile>`.
    * `:class` — extra classes for the outer tile element. It cannot widen the
      tile: the clamp is unlayered CSS. See "Design constraints".
  """

  use PlatformWeb, :html

  import PlatformWeb.Components.ChatHelpers, only: [relative_time: 1]

  alias Platform.Chat.Canvas
  alias PlatformWeb.Chat.CanvasRenderer

  attr(:canvas, Canvas, required: true, doc: "the canvas whose document the tile displays")

  attr(:id_prefix, :string,
    default: "canvas-tile",
    doc: "prefix for the tile's dom id; pass a distinct value per surface"
  )

  attr(:changed?, :boolean,
    default: false,
    doc: "applies the one-shot primary highlight; never animated"
  )

  attr(:layout, :atom,
    default: :strip,
    values: [:strip, :gallery],
    doc:
      "sizing strategy, identical to `<.video_tile>`'s. `:strip` is `aspect-video h-full shrink-0` for the fixed-height bottom strip; `:gallery` emits no sizing classes and lets the `[data-gallery-cell]` container query in app.css pick the binding axis."
  )

  attr(:class, :any, default: nil, doc: "extra classes for the outer tile element")
  attr(:rest, :global)

  def canvas_tile(assigns) do
    assigns = assign(assigns, :title, canvas_title(assigns.canvas))

    ~H"""
    <div
      id={"#{@id_prefix}-#{@canvas.id}"}
      data-role="canvas-tile"
      data-canvas-id={@canvas.id}
      data-changed={to_string(@changed?)}
      class={
        [
          "meeting-canvas-tile relative flex flex-col overflow-hidden rounded-lg",
          # Document surface, not a video pane: light base, readable body text.
          "bg-base-100 text-base-content",
          # Same sizing contract as `<.video_tile>` for the same layout — see
          # `tile_layout_classes/1`. The hard clamp lives unlayered in app.css
          # so no call-site class can widen or lengthen the tile.
          tile_layout_classes(@layout),
          # One-shot highlight. Deliberately a static ring — no animate-* class,
          # because a looping marker would out-shout the speaking indicators.
          if(@changed?,
            do: "ring-2 ring-primary",
            else: "ring-1 ring-base-300"
          ),
          @class
        ]
      }
      {@rest}
    >
      <%!-- Preview window. `min-h-0` matters on a flex child for the same
         reason it matters on a grid item: the default `auto` minimum lets a
         tall child win against `flex-1` and grow the box. `overflow-hidden`
         is what clips the scaled transform to the tile. --%>
      <div
        data-role="canvas-tile-content"
        class="relative min-h-0 min-w-0 flex-1 overflow-hidden bg-base-100 text-base-content"
      >
        <%!-- The document, out of flow and scaled to a third of type size.
           ABSOLUTE is the load-bearing part: content length cannot reach the
           tile's height at all, so a 200-block canvas and a one-line canvas
           produce the same box. `w-[300%]` + `scale-[0.3333]` + origin at the
           top-left means the scaled result lands exactly on the tile's width
           whatever that width measures. `pointer-events-none` keeps the whole
           tile a single click target for opening the canvas — a preview is an
           affordance, not an interactive document. --%>
        <div
          data-role="canvas-tile-preview"
          class="pointer-events-none absolute left-0 top-0 w-[300%] origin-top-left scale-[0.3333] px-4 py-3"
        >
          <CanvasRenderer.canvas_document
            canvas={@canvas}
            show_header={false}
            dom_id_base={"meeting-tile-#{@id_prefix}"}
          />
        </div>
        <%!-- Soft fade at the BOTTOM edge: the signal that the document
           continues past the frame. --%>
        <div
          data-role="canvas-tile-fade"
          class="pointer-events-none absolute inset-x-0 bottom-0 h-6 bg-gradient-to-t from-base-300 to-transparent"
          aria-hidden="true"
        >
        </div>
      </div>

      <%!-- Name plate. The title yields space; the timestamp never does. --%>
      <div class="flex shrink-0 items-center gap-1.5 border-t border-base-300 px-2 py-1">
        <span data-role="canvas-tile-title" class="min-w-0 truncate text-xs text-neutral">
          {@title}
        </span>
        <span
          data-role="canvas-tile-timestamp"
          class="ml-auto shrink-0 whitespace-nowrap text-xs text-neutral"
        >
          {relative_time(@canvas.updated_at)}
        </span>
      </div>
    </div>
    """
  end

  @doc """
  Sizing classes for a tile layout.

  Public and shared on purpose: `<.video_tile>` has a private clause pair with
  the same bodies, and the canvas tile's whole sizing requirement is "the same
  box as a face tile". A test asserts the two agree, so a future divergence in
  either component fails rather than silently producing a canvas tile of a
  different size from its neighbours.

  `:gallery` deliberately emits NOTHING — the `[data-gallery-cell] >
  .meeting-canvas-tile` container query in `assets/css/app.css` owns gallery
  sizing, and a class string here would only compete with it.
  """
  @spec tile_layout_classes(:strip | :gallery) :: String.t()
  def tile_layout_classes(:gallery), do: ""
  def tile_layout_classes(_), do: "aspect-video h-full shrink-0"

  defp canvas_title(%{title: title}) when is_binary(title) do
    case String.trim(title) do
      "" -> "Untitled canvas"
      trimmed -> trimmed
    end
  end

  defp canvas_title(_), do: "Untitled canvas"
end
