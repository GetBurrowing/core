defmodule Platform.Chat.Canvas.Kinds.Text do
  @moduledoc "Plain text leaf with size/weight styling."

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
        "size" => %{"type" => "string", "enum" => ["xs", "sm", "base", "lg", "xl", "2xl"]},
        "weight" => %{"type" => "string", "enum" => ["normal", "medium", "semibold", "bold"]}
      }
    }
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}

    assigns =
      assigns
      |> assign(:text_class, classes(props))
      |> assign(:value, stringify(props["value"]))
      |> assign(:class_overrides, props["class_overrides"])

    ~H"""
    <p class={[@text_class, @class_overrides]}>{@value}</p>
    """
  end

  defp classes(props) do
    size_cls =
      case Map.get(props, "size", "sm") do
        "xs" -> "text-xs"
        "base" -> "text-base"
        "lg" -> "text-lg"
        "xl" -> "text-xl"
        "2xl" -> "text-2xl"
        _ -> "text-sm"
      end

    weight_cls =
      case Map.get(props, "weight", "normal") do
        "bold" -> "font-bold"
        "semibold" -> "font-semibold"
        "medium" -> "font-medium"
        _ -> ""
      end

    "#{size_cls} #{weight_cls} text-base-content leading-6"
  end

  defp stringify(nil), do: ""
  defp stringify(s) when is_binary(s), do: s
  defp stringify(n) when is_number(n) or is_boolean(n) or is_atom(n), do: to_string(n)
  defp stringify(list) when is_list(list), do: list |> Enum.map(&stringify/1) |> Enum.join("\n")
  defp stringify(%{"type" => "text", "text" => t}) when is_binary(t), do: t
  defp stringify(%{"text" => t}) when is_binary(t), do: t
  defp stringify(%{"content" => c}), do: stringify(c)
  defp stringify(other), do: inspect(other)
end
