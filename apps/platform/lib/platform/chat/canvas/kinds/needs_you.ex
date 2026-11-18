defmodule Platform.Chat.Canvas.Kinds.NeedsYou do
  @moduledoc """
  "Needs you": the human decisions on an episode board, and only those
  (task 01a1eaf6 stage 2).

  Shows "Needs you (N)" with each question and its options as quiet,
  secondary-weight buttons. A click emits the same `canvas_action_click` an
  `action_row` does, with the action value `"<item id>:<option>"`. With no
  items it collapses to "Nothing needs you this week."

  Props are exactly the `needs_you` node `Platform.Showrunner.Episode.to_document/1`
  writes; `validate_props/1` delegates to `Episode.validate_needs_you_props/1`.
  """

  use Platform.Chat.Canvas.Kind

  alias Platform.Showrunner.Episode

  @empty_copy "Nothing needs you this week."

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["items"],
      "properties" => %{
        "items" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["id", "question", "options"],
            "properties" => %{
              "id" => %{"type" => "string"},
              "question" => %{"type" => "string"},
              "options" => %{"type" => "array", "items" => %{"type" => "string"}}
            }
          }
        },
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  def defaults, do: %{"items" => []}

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

  def validate_props(props) do
    case Episode.validate_needs_you_props(props) do
      :ok -> :ok
      {:error, reason} -> {:error, "(needs_you) " <> Episode.error_message(reason)}
    end
  end

  @doc "The empty-state copy."
  @spec empty_copy() :: String.t()
  def empty_copy, do: @empty_copy

  attr :node, :map, required: true
  attr :dom_id_scope, :string, default: nil
  attr :canvas_id, :string, default: nil
  attr :event_target, :any, default: nil
  attr :viewer, :any, default: nil

  def render(assigns) do
    props = assigns.node["props"] || %{}
    items = props["items"] |> List.wrap() |> Enum.filter(&is_map/1)

    assigns =
      assigns
      |> assign(:props, props)
      |> assign(:items, items)
      |> assign(:node_id, assigns.node["id"])
      |> assign(:empty_copy, @empty_copy)

    ~H"""
    <section
      data-role="needs-you"
      class={[
        "flex flex-col gap-2 rounded-xl border border-edge bg-base-200 p-3",
        @props["class_overrides"]
      ]}
    >
      <p :if={@items == []} data-role="needs-you-empty" class="text-sm text-subtle">
        {@empty_copy}
      </p>
      <h3
        :if={@items != []}
        data-role="needs-you-count"
        class="text-sm font-semibold text-base-content"
      >
        Needs you ({length(@items)})
      </h3>
      <div
        :for={item <- @items}
        data-role="needs-you-item"
        data-item-id={item["id"]}
        class="flex flex-wrap items-center justify-between gap-2"
      >
        <p class="min-w-0 text-sm text-base-content">{item["question"]}</p>
        <div class="flex flex-wrap gap-2">
          <button
            :for={option <- List.wrap(item["options"])}
            type="button"
            data-role="needs-you-option"
            class="btn btn-sm btn-outline btn-secondary"
            phx-click="canvas_action_click"
            phx-target={@event_target}
            phx-value-canvas-id={@canvas_id}
            phx-value-node-id={@node_id}
            phx-value-action={"#{item["id"]}:#{option}"}
          >
            {option}
          </button>
        </div>
      </div>
    </section>
    """
  end
end
