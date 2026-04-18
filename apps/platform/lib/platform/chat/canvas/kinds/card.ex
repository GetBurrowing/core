defmodule Platform.Chat.Canvas.Kinds.Card do
  @moduledoc "Bordered card with optional title. Accepts any children."

  use Platform.Chat.Canvas.Kind

  alias Platform.Chat.Canvas.Renderer

  def children, do: :any

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "title" => %{"type" => "string"},
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  def styling do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "variant" => %{"type" => "string", "enum" => ["default", "elevated", "outlined"]},
        "tone" => %{"type" => "string", "enum" => ["neutral", "info", "warning", "critical"]}
      }
    }
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}
    assigns = assign(assigns, :props, props)

    ~H"""
    <div class={[
      "rounded-xl border border-base-300 bg-base-200 p-3 flex flex-col gap-2",
      @props["class_overrides"]
    ]}>
      <p
        :if={@props["title"]}
        class="text-xs font-semibold uppercase tracking-widest text-base-content/50"
      >
        {@props["title"]}
      </p>
      <Renderer.render_node :for={child <- @node["children"] || []} node={child} />
    </div>
    """
  end
end
