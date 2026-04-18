defmodule Platform.Chat.Canvas.Kinds.ActionRow do
  @moduledoc """
  Horizontal row of action buttons. Buttons are declared in `props.actions`
  rather than as children (each action is a {label, value, variant} triple).
  A click emits an `action` event on the canvas topic.
  """

  use Platform.Chat.Canvas.Kind

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["actions"],
      "properties" => %{
        "label" => %{"type" => "string"},
        "actions" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["label", "value"],
            "properties" => %{
              "label" => %{"type" => "string"},
              "value" => %{"type" => "string"},
              "variant" => %{
                "type" => "string",
                "enum" => ["primary", "secondary", "ghost", "outline", "danger"]
              }
            }
          }
        },
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  def events do
    [
      %{
        "name" => "action",
        "payload_schema" => %{
          "type" => "object",
          "properties" => %{
            "node_id" => %{"type" => "string"},
            "value" => %{"type" => "string"}
          }
        }
      }
    ]
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}
    actions = List.wrap(props["actions"])

    assigns =
      assigns
      |> assign(:props, props)
      |> assign(:actions, actions)
      |> assign(:node_id, assigns.node["id"])

    ~H"""
    <div class={[
      "flex flex-row flex-wrap gap-2 mt-1",
      @props["class_overrides"]
    ]}>
      <p
        :if={@props["label"]}
        class="w-full text-xs font-semibold uppercase tracking-widest text-base-content/50 mb-0.5"
      >
        {@props["label"]}
      </p>
      <button
        :for={action <- @actions}
        type="button"
        class={["btn btn-sm", button_class(action["variant"])]}
        phx-click="canvas_action_click"
        phx-value-node-id={@node_id}
        phx-value-value={action["value"]}
      >
        {action["label"]}
      </button>
    </div>
    """
  end

  defp button_class("primary"), do: "btn-primary"
  defp button_class("secondary"), do: "btn-secondary"
  defp button_class("danger"), do: "btn-error"
  defp button_class("ghost"), do: "btn-ghost"
  defp button_class("outline"), do: "btn-outline"
  defp button_class(_), do: "btn-outline"
end
