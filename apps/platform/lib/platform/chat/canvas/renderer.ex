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
  """
  attr :node, :map, required: true

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
    <div class="rounded border border-dashed border-base-300 bg-base-200 px-3 py-2 text-xs text-base-content/40">
      [unknown node type: {@kind_name}]
    </div>
    """
  end
end
