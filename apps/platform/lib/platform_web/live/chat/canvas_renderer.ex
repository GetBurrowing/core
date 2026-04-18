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

        ~H"""
        <div
          id={"canvas-doc-#{@canvas.id}-#{@id_suffix}"}
          class={["overflow-x-auto", @inline && "cursor-pointer"]}
          phx-click={if(@inline, do: "canvas_open")}
          phx-value-canvas-id={if(@inline, do: @canvas.id)}
        >
          <Renderer.render_node node={@root_node} />
        </div>
        """

      true ->
        render_invalid(assigns)
    end
  end

  defp render_removed(assigns) do
    ~H"""
    <div class="rounded-xl border border-dashed border-base-300 bg-base-200 px-4 py-6 text-sm text-base-content/50 text-center">
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
