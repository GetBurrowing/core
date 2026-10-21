defmodule PlatformWeb.Chat.CanvasRenderer do
  @moduledoc """
  Outer chrome for rendering a canvas in chat/detail panels. Delegates the
  actual node-tree rendering to `Platform.Chat.Canvas.Renderer.render_node/1`.
  """

  use PlatformWeb, :html

  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Kinds
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

  # Where the inline wrapper's `canvas_open` click is delivered. nil (the
  # default) leaves it untargeted, so it goes to the parent LiveView —
  # ChatLive and MeetingLive handle it there. A LiveComponent that renders an
  # inline canvas under a LiveView WITHOUT a `canvas_open` clause (the Tasks
  # page's SteeringComponent) passes `open_target={@myself}` and handles the
  # event itself; untargeted, it crashed TasksLive with a FunctionClauseError.
  attr(:open_target, :any, default: nil)

  # Where the document's interactive nodes deliver their events: action_row's
  # `canvas_action_click` and form's `canvas_form_submit`. nil (the default)
  # leaves them untargeted, so they reach the parent LiveView — ChatLive and
  # MeetingLive handle them there. The Tasks page's LiveComponents pass
  # `event_target={@myself}`: TasksLive has no clause for either event, so
  # untargeted they crashed it with a FunctionClauseError. A sibling of
  # `open_target`, not a reuse of it, so a caller can send the two apart.
  attr(:event_target, :any, default: nil)

  # The actor for kinds whose own controls write the document (the prototype
  # kind's "Pin this version"). nil hides those controls. See
  # `Platform.Chat.Canvas.Renderer.render_node/1`.
  attr(:viewer, :any, default: nil)

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
        root_node = canvas.document["root"]

        assigns =
          assigns
          |> assign(:root_node, root_node)
          |> assign(:opens_on_click, assigns.inline and opens_on_click?(root_node))

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
        #
        # A kind can opt its documents out of the click-to-open wrapper
        # (task 01a0ee4f): `opens_on_click?/1` walks the tree, and when any
        # node's kind says `inline_opens_canvas?/0 == false` the wrapper gets
        # neither the binding nor the cursor-pointer affordance. Every other
        # document opens exactly as before.
        ~H"""
        <div
          id={"canvas-doc-#{@canvas.id}-#{@id_suffix}"}
          class={["overflow-x-auto", @opens_on_click && "cursor-pointer"]}
          phx-click={if(@opens_on_click, do: "canvas_open")}
          phx-value-canvas-id={if(@opens_on_click, do: @canvas.id)}
          phx-target={if(@opens_on_click, do: @open_target)}
        >
          <Renderer.render_node
            node={@root_node}
            dom_id_scope={"#{@canvas.id}-#{@id_suffix}"}
            canvas_id={@canvas.id}
            event_target={@event_target}
            viewer={@viewer}
          />
        </div>
        """

      true ->
        render_invalid(assigns)
    end
  end

  defp render_removed(assigns) do
    ~H"""
    <div class="rounded-xl border border-dashed border-edge bg-base-200 px-4 py-6 text-sm text-subtle text-center">
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

  # True unless SOME node in the tree has a kind that opts out through the
  # `inline_opens_canvas?/0` convention function (task 01a0ee4f). An
  # extension kind's node can sit below a stack root, so reading only the
  # root kind would miss it. This is a convention function, not a `Kind`
  # callback: a kind that does not export it opens on click, as every kind
  # did before. The registry is read per call and never cached, because an
  # extension's kinds can come and go at runtime (see `Kinds.all/0`).
  defp opens_on_click?(root_node) do
    by_name = Kinds.by_name()
    not Enum.any?(nodes(root_node), &opts_out?(Map.get(by_name, &1["type"])))
  end

  defp nodes(%{} = node) do
    children = if is_list(node["children"]), do: node["children"], else: []
    [node | Enum.flat_map(children, &nodes/1)]
  end

  defp nodes(_), do: []

  defp opts_out?(nil), do: false

  defp opts_out?(mod) do
    match?({:module, _}, :code.ensure_loaded(mod)) and
      function_exported?(mod, :inline_opens_canvas?, 0) and
      mod.inline_opens_canvas?() == false
  end
end
