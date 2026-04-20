defmodule Platform.Chat.Canvas.Kinds.Image do
  @moduledoc """
  Image leaf (ADR 0036).

  Per ADR 0039 phase 6, `src` is locked down to path-relative
  `/chat/attachments/<uuid>` URLs. Agents should upload via
  `attachment.upload_inline` / `attachment.upload_start` and set `src` to
  the returned URL. External schemes (http(s), data:, javascript:, file:,
  bare hosts) are rejected with a structured validation error.
  """

  use Platform.Chat.Canvas.Kind

  @attachment_path_re ~r|^/chat/attachments/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$|

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["src"],
      "properties" => %{
        "src" => %{
          "type" => "string",
          "pattern" => "^/chat/attachments/[0-9a-fA-F-]{36}$",
          "description" =>
            "Path-relative /chat/attachments/<uuid>. Upload bytes via attachment.upload_inline or attachment.upload_start and pass the returned `url` here."
        },
        "alt" => %{"type" => "string"},
        "caption" => %{"type" => "string"},
        "border" => %{"type" => "boolean"},
        "rounded" => %{"type" => "boolean"},
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  @impl true
  def validate_props(%{"src" => src}) when is_binary(src) do
    if Regex.match?(@attachment_path_re, src) do
      :ok
    else
      {:error,
       "image src must be a path-relative /chat/attachments/<uuid> URL. " <>
         "Upload bytes via attachment.upload_inline and pass the returned `url`. Got #{inspect(src)}"}
    end
  end

  def validate_props(%{"src" => src}),
    do: {:error, "image src must be a string (got #{inspect(src)})"}

  def validate_props(_props),
    do: {:error, "image requires a \"src\" prop"}

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}
    assigns = assign(assigns, :props, props)

    ~H"""
    <div class={[
      "overflow-hidden",
      @props["rounded"] != false && "rounded-xl",
      @props["class_overrides"]
    ]}>
      <img
        src={@props["src"] || ""}
        alt={@props["alt"] || ""}
        class={[
          "max-w-full h-auto block",
          @props["border"] && "border border-base-300"
        ]}
      />
      <p :if={@props["caption"]} class="text-[11px] text-base-content/50 text-center mt-1">
        {@props["caption"]}
      </p>
    </div>
    """
  end
end
