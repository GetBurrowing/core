defmodule Platform.Chat.Canvas.Kinds.Code do
  @moduledoc "Syntax-highlighted code block."

  use Platform.Chat.Canvas.Kind

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["source"],
      "properties" => %{
        "source" => %{"type" => "string"},
        "language" => %{"type" => "string"},
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}
    assigns = assign(assigns, :props, props)

    ~H"""
    <div class={[
      "rounded-xl border border-base-300 bg-base-900 overflow-x-auto",
      @props["class_overrides"]
    ]}>
      <div class="flex items-center justify-between border-b border-base-300 bg-base-200 px-3 py-1">
        <span class="text-[11px] uppercase tracking-widest text-base-content/50">
          {@props["language"] || "code"}
        </span>
      </div>
      <pre class="p-3 text-xs leading-5 text-base-content overflow-x-auto"><code>{@props["source"] || ""}</code></pre>
    </div>
    """
  end
end
