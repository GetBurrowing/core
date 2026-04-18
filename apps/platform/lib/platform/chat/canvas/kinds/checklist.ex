defmodule Platform.Chat.Canvas.Kinds.Checklist do
  @moduledoc "Ordered list of checklist items. Children must be `checklist_item` nodes."

  use Platform.Chat.Canvas.Kind

  alias Platform.Chat.Canvas.Renderer

  def children, do: ["checklist_item"]

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

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}
    children = assigns.node["children"] || []
    total = length(children)
    complete = Enum.count(children, fn c -> get_in(c, ["props", "state"]) == "complete" end)

    assigns =
      assigns
      |> assign(:props, props)
      |> assign(:total, total)
      |> assign(:complete, complete)

    ~H"""
    <div class={[
      "card-checklist flex flex-col gap-1 rounded-xl border border-base-300 bg-base-200 p-3",
      @props["class_overrides"]
    ]}>
      <div class="flex items-center justify-between mb-1">
        <p
          :if={@props["title"]}
          class="text-xs font-semibold uppercase tracking-widest text-base-content/50"
        >
          {@props["title"]}
        </p>
        <span :if={@total > 0} class="text-xs text-base-content/40">
          {@complete} / {@total} tasks
        </span>
      </div>
      <Renderer.render_node :for={child <- @node["children"] || []} node={child} />
    </div>
    """
  end
end
