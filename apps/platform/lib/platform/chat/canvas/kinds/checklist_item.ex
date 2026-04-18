defmodule Platform.Chat.Canvas.Kinds.ChecklistItem do
  @moduledoc "Single checklist row."

  use Platform.Chat.Canvas.Kind

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["label"],
      "properties" => %{
        "label" => %{"type" => "string"},
        "note" => %{"type" => "string"},
        "state" => %{"type" => "string", "enum" => ["pending", "active", "complete"]},
        "checked" => %{"type" => "boolean"},
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  def events do
    [
      %{
        "name" => "toggled",
        "payload_schema" => %{
          "type" => "object",
          "properties" => %{
            "node_id" => %{"type" => "string"},
            "checked" => %{"type" => "boolean"}
          }
        }
      }
    ]
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}
    state = props["state"] || if props["checked"], do: "complete", else: "pending"

    assigns =
      assigns
      |> assign(:props, props)
      |> assign(:state, state)
      |> assign(:node_id, assigns.node["id"])

    ~H"""
    <div
      class={[
        "flex items-start gap-2 py-0.5",
        @props["class_overrides"]
      ]}
      data-state={@state}
      data-node-id={@node_id}
    >
      <span class={[
        "mt-0.5 size-4 shrink-0",
        @state == "complete" && "hero-check-circle text-success",
        @state == "active" && "hero-bolt text-primary",
        @state not in ["complete", "active"] && "hero-stop-circle text-base-content/25"
      ]}>
      </span>
      <div class="min-w-0">
        <p class={[
          "text-sm leading-5",
          @state == "complete" && "line-through text-base-content/40",
          @state != "complete" && "text-base-content"
        ]}>
          {@props["label"] || ""}
        </p>
        <p :if={@props["note"]} class="text-xs text-base-content/50 leading-4 mt-0.5">
          {@props["note"]}
        </p>
      </div>
    </div>
    """
  end
end
