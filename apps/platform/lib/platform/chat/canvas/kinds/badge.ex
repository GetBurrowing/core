defmodule Platform.Chat.Canvas.Kinds.Badge do
  @moduledoc "Small rounded label."

  use Platform.Chat.Canvas.Kind

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["value"],
      "properties" => %{
        "value" => %{"type" => "string"},
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  def styling do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "tone" => %{"type" => "string", "enum" => ["neutral", "info", "warning", "critical"]}
      }
    }
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}

    assigns =
      assigns
      |> assign(:value, to_string(props["value"] || ""))
      |> assign(:tone_class, tone_class(props["tone"]))
      |> assign(:class_overrides, props["class_overrides"])

    ~H"""
    <span class={[
      "inline-block rounded-full px-2 py-0.5 text-[11px] uppercase tracking-widest",
      @tone_class,
      @class_overrides
    ]}>
      {@value}
    </span>
    """
  end

  defp tone_class("info"), do: "bg-info/20 text-info"
  defp tone_class("warning"), do: "bg-warning/20 text-warning"
  defp tone_class("critical"), do: "bg-error/20 text-error"
  defp tone_class(_), do: "bg-base-300 text-base-content/60"
end
