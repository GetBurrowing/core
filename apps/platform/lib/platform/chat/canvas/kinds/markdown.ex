defmodule Platform.Chat.Canvas.Kinds.Markdown do
  @moduledoc "Pre-formatted markdown/text content leaf."

  use Platform.Chat.Canvas.Kind

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["content"],
      "properties" => %{
        "content" => %{"type" => "string"},
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}

    assigns =
      assigns
      |> assign(:content, stringify(props["content"]))
      |> assign(:class_overrides, props["class_overrides"])

    ~H"""
    <div class={["rounded-xl border border-base-300 bg-base-200 p-3", @class_overrides]}>
      <pre class="whitespace-pre-wrap text-xs leading-5 text-base-content/80 font-mono">{@content}</pre>
    </div>
    """
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
