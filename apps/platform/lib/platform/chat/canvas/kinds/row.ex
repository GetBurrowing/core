defmodule Platform.Chat.Canvas.Kinds.Row do
  @moduledoc "Horizontal flex container. Accepts any children."

  use Platform.Chat.Canvas.Kind

  alias Platform.Chat.Canvas.Renderer

  def children, do: :any

  def defaults, do: %{"gap" => 8}

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "gap" => %{"type" => "integer", "minimum" => 0, "maximum" => 64},
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}
    assigns = assign(assigns, :props, props)

    ~H"""
    <div
      class={["flex flex-row flex-wrap", @props["class_overrides"]]}
      style={"gap: #{@props["gap"] || 8}px"}
    >
      <Renderer.render_node :for={child <- @node["children"] || []} node={child} />
    </div>
    """
  end
end
