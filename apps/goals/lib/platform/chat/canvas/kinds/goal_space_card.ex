defmodule Platform.Goals.CanvasKinds.GoalSpaceCard do
  @moduledoc "A shared goal card; document props never authorize a read or click."
  use Platform.Chat.Canvas.Kind
  @impl true
  def describe,
    do: "A shared goal shown in a space. Placed by Goals only; its only prop is a goal id."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["goal_id"],
      "properties" => %{"goal_id" => %{"type" => "string"}}
    }

  @impl true
  def validate_props(props) when is_map(props) do
    if Map.keys(props) == ["goal_id"] and match?({:ok, _}, Ecto.UUID.cast(props["goal_id"])),
      do: :ok,
      else: {:error, "goal_space_card takes only a UUID goal_id"}
  end

  def validate_props(_), do: {:error, "goal_space_card takes only a UUID goal_id"}
  def inline_opens_canvas?, do: false
  attr(:node, :map, required: true)
  attr(:dom_id_scope, :string, default: nil)
  attr(:canvas_id, :string, default: nil)
  attr(:viewer, :any, default: nil)
  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :component_id,
        "goal-card-#{assigns[:dom_id_scope] || assigns[:canvas_id] || "x"}"
      )

    ~H"""
    <.live_component module={PlatformWeb.GoalsSpaceCardComponent} id={@component_id} canvas_id={@canvas_id} viewer={@viewer} />
    """
  end
end
