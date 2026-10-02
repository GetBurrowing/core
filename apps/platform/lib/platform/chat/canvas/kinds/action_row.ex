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
  attr :dom_id_scope, :string, default: nil
  attr :canvas_id, :string, default: nil

  # Where the button's `canvas_action_click` is delivered. nil (the default)
  # renders no phx-target, so the click goes to the parent LiveView, which is
  # how ChatLive and MeetingLive handle it. The Tasks page's LiveComponents
  # pass their `@myself`: TasksLive has no clause for this event.
  attr :event_target, :any, default: nil

  # Bug B (task 019f70ff): LV's `extractMeta` (phoenix_live_view.js:5390-5394)
  # reads `element.value` on non-form elements AFTER walking phx-value-*
  # attributes, and unconditionally overwrites `meta.value` with the DOM
  # property. HTMLButtonElement.value defaults to "" — so `phx-value-value`
  # on a <button> was silently clobbered to "" before hitting the server.
  # We publish the action key as `phx-value-action` (no clash with any
  # HTMLElement property) and the handler in canvas_hooks.ex reads
  # `params["action"]` accordingly.
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
        data-role="canvas-action-button"
        class={["btn btn-sm", button_class(action["variant"])]}
        phx-click="canvas_action_click"
        phx-target={@event_target}
        phx-value-canvas-id={@canvas_id}
        phx-value-node-id={@node_id}
        phx-value-action={action["value"]}
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
