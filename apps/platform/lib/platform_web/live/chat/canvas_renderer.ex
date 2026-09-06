defmodule PlatformWeb.Chat.CanvasRenderer do
  @moduledoc """
  Outer chrome for rendering a canvas in chat/detail panels. Delegates the
  actual node-tree rendering to `Platform.Chat.Canvas.Renderer.render_node/1`.
  """

  use PlatformWeb, :html

  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Renderer
  alias Platform.Chat.CanvasDocument

  @doc """
  Render a canvas's canonical document.

  Soft-deleted canvases render a removal placeholder. Canvases with a document
  that fails to validate render an error shell instead of raising.
  """
  attr(:canvas, Canvas, required: true)
  attr(:inline, :boolean, default: false)
  attr(:show_header, :boolean, default: true)
  attr(:dom_id_base, :string, default: nil)

  def canvas_document(assigns) do
    canvas = assigns.canvas
    # Mode suffix distinguishes inline (in-chat) vs. expanded (panel/overlay)
    # copies of the same canvas. dom_id_base further disambiguates multiple
    # expanded copies (e.g. desktop panel + mobile overlay render both under
    # lg:hidden / hidden lg:flex; without a unique id, LiveView warns about
    # duplicate ids even though only one is visible at a time).
    #
    # The scope handed to Renderer.render_node MUST also carry canvas.id:
    # call sites pass constant dom_id_base values ("chat-message-inline"),
    # so without it two canvases in different messages mint identical ids
    # for JS-hooked nodes (embed iframes). Colliding ids break morphdom's
    # id-keyed matching on stream re-diffs, which destroys+recreates the
    # node — phx-update="ignore" does not survive a remount, so the iframe
    # reloads and visibly jumps (task 019f51d1).
    mode_suffix = if assigns.inline, do: "inline", else: "expanded"

    base = assigns[:dom_id_base]
    id_suffix = if base, do: "#{base}-#{mode_suffix}", else: mode_suffix

    assigns =
      assigns
      |> assign(:mode_suffix, mode_suffix)
      |> assign(:id_suffix, id_suffix)

    cond do
      canvas.deleted_at ->
        render_removed(assigns)

      valid_document?(canvas.document) ->
        assigns = assign(assigns, :root_node, canvas.document["root"])

        # Bug A guard: LV's phx-click listener is bound at `window` in bubble
        # phase (phoenix_live_view.js:6523, capture arg = false). That means
        # `onclick + stopPropagation()` on this wrapper would kill the
        # button's own click before LV ever sees it. The correct guard is
        # `data-phx-click-loading` semantics via `Phoenix.LiveView.JS.exec`
        # — when a descendant carries `data-role="canvas-action-button"`,
        # LV's `closestPhxBinding` walks up from `event.target` and returns
        # the CLOSEST phx-click ancestor. Since every action_row button now
        # carries its own phx-click="canvas_action_click", the button wins
        # over the wrapper's phx-click="canvas_open" naturally. We do NOT
        # add a stopPropagation onclick here — testing showed it kills the
        # button click before LV's window listener fires (Bug A retested
        # 2026-07-18 during stage 1 verification). If a residual Bug A ever
        # reproduces, swap to a dedicated "open" affordance instead.
        ~H"""
        <div
          id={"canvas-doc-#{@canvas.id}-#{@id_suffix}"}
          class={["overflow-x-auto", @inline && "cursor-pointer"]}
          phx-click={if(@inline, do: "canvas_open")}
          phx-value-canvas-id={if(@inline, do: @canvas.id)}
        >
          <Renderer.render_node
            node={@root_node}
            dom_id_scope={"#{@canvas.id}-#{@id_suffix}"}
            canvas_id={@canvas.id}
          />
        </div>
        """

      true ->
        render_invalid(assigns)
    end
  end

  defp render_removed(assigns) do
    ~H"""
    <div class="rounded-xl border border-dashed border-edge bg-base-200 px-4 py-6 text-sm text-base-content/50 text-center">
      This canvas was removed.
    </div>
    """
  end

  defp render_invalid(assigns) do
    ~H"""
    <div class="rounded-xl border border-error/30 bg-error/10 px-4 py-3 text-xs text-error">
      This canvas has an invalid document and cannot be rendered.
    </div>
    """
  end

  defp valid_document?(doc), do: CanvasDocument.canonical?(doc)
end
