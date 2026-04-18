defmodule Platform.Chat.Canvas.Kinds.Heading do
  @moduledoc "H1–H4 heading."

  use Platform.Chat.Canvas.Kind

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["value"],
      "properties" => %{
        "value" => %{"type" => "string"},
        "level" => %{"type" => "integer", "minimum" => 1, "maximum" => 4},
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}

    assigns =
      assigns
      |> assign(:value, to_string(props["value"] || ""))
      |> assign(:level, props["level"] || 2)
      |> assign(:class_overrides, props["class_overrides"])

    ~H"""
    <%= case @level do %>
      <% 1 -> %>
        <h1 class={["text-2xl font-bold text-base-content", @class_overrides]}>{@value}</h1>
      <% 2 -> %>
        <h2 class={["text-xl font-bold text-base-content", @class_overrides]}>{@value}</h2>
      <% 3 -> %>
        <h3 class={["text-lg font-semibold text-base-content", @class_overrides]}>{@value}</h3>
      <% _ -> %>
        <h4 class={["text-base font-semibold text-base-content", @class_overrides]}>{@value}</h4>
    <% end %>
    """
  end
end
