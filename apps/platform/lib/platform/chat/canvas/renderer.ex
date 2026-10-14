defmodule Platform.Chat.Canvas.Renderer do
  @moduledoc """
  Recursive dispatcher that renders a canonical canvas document node tree.

  Lives in the `Platform.Chat.Canvas` namespace so kind modules can reference
  `render_node/1` for recursion without creating a circular dependency between
  platform and web layers. `PlatformWeb.Chat.CanvasRenderer` is a thin outer
  wrapper that calls into this module.
  """

  use Phoenix.Component

  alias Platform.Chat.Canvas.Kinds

  @doc """
  Render a single canvas node. Looks up the kind module from the registry and
  delegates; kind modules recurse back through this function for their children.

  `dom_id_scope` is an optional string used by kinds that need to attach JS
  hooks via a unique DOM id. The same node is sometimes rendered into two
  places at once (e.g. the chat-panel and mobile-overlay copies of the active
  canvas), so kinds that mint ids from the node id must namespace them by the
  outer render scope to avoid duplicate-id warnings and broken hook bindings.

  `event_target` is an optional `phx-target` for the events interactive kinds
  emit (`canvas_action_click`, `canvas_form_submit`). nil leaves them
  untargeted, so they reach the parent LiveView. Container kinds pass it down
  to their children.

  `viewer` is an optional `t:Platform.Chat.CanvasAccess.actor/0` (`{:user,
  id}`) for kinds whose own controls write the document. Only the `prototype`
  kind reads it (its "Pin this version" goes through `Chat.patch_canvas/3`,
  which re-checks membership). nil hides such controls. Container kinds pass
  it down like `event_target`.
  """
  attr :node, :map, required: true
  attr :dom_id_scope, :string, default: nil
  attr :canvas_id, :string, default: nil
  attr :event_target, :any, default: nil
  attr :viewer, :any, default: nil

  def render_node(assigns) do
    node = assigns.node

    cond do
      not is_map(node) ->
        render_fallback(assigns)

      not is_binary(Map.get(node, "type")) ->
        render_fallback(assigns)

      mod = Kinds.get(node["type"]) ->
        mod.render(assigns)

      true ->
        render_fallback(assigns)
    end
  end

  defp render_fallback(assigns) do
    node = if is_map(assigns.node), do: assigns.node, else: %{}
    assigns = assign(assigns, :kind_name, Map.get(node, "type", "?"))

    ~H"""
    <div class="rounded border border-dashed border-edge bg-base-200 px-3 py-2 text-xs text-base-content/40">
      [unknown node type: {@kind_name}]
    </div>
    """
  end
end
