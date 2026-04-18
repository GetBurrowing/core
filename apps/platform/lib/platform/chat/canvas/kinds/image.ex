defmodule Platform.Chat.Canvas.Kinds.Image do
  @moduledoc "Image leaf."

  use Platform.Chat.Canvas.Kind

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["src"],
      "properties" => %{
        "src" => %{"type" => "string"},
        "alt" => %{"type" => "string"},
        "caption" => %{"type" => "string"},
        "border" => %{"type" => "boolean"},
        "rounded" => %{"type" => "boolean"},
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}
    assigns = assign(assigns, :props, props)

    ~H"""
    <div class={[
      "overflow-hidden",
      @props["rounded"] != false && "rounded-xl",
      @props["class_overrides"]
    ]}>
      <img
        src={@props["src"] || ""}
        alt={@props["alt"] || ""}
        class={[
          "max-w-full h-auto block",
          @props["border"] && "border border-base-300"
        ]}
      />
      <p :if={@props["caption"]} class="text-[11px] text-base-content/50 text-center mt-1">
        {@props["caption"]}
      </p>
    </div>
    """
  end
end
