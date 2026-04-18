defmodule Platform.Chat.Canvas.Kinds.Mermaid do
  @moduledoc "Mermaid diagram; rendered client-side via the MermaidDiagram hook."

  use Platform.Chat.Canvas.Kind

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["source"],
      "properties" => %{
        "source" => %{"type" => "string"},
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}
    assigns = assign(assigns, :props, props) |> assign(:node_id, assigns.node["id"])

    ~H"""
    <div
      id={"mermaid-#{@node_id}"}
      phx-hook="MermaidDiagram"
      phx-update="ignore"
      data-source={@props["source"] || ""}
      class={[
        "rounded-xl border border-base-300 bg-base-100 p-3 overflow-x-auto",
        @props["class_overrides"]
      ]}
    >
      <div class="mermaid-container flex items-center justify-center min-h-[100px]">
        <span class="loading loading-spinner loading-sm text-base-content/30"></span>
      </div>
    </div>
    """
  end
end
