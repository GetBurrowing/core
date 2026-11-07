defmodule Platform.Chat.Canvas.Kinds.Image do
  @moduledoc """
  Image leaf (ADR 0036).

  Per ADR 0039 phase 6, `src` is locked down to path-relative
  `/chat/attachments/<uuid>` URLs. Agents should upload via
  `attachment_upload_inline` / `attachment_upload_start` and set `src` to
  the returned URL. External schemes (http(s), data:, javascript:, file:,
  bare hosts) are rejected with a structured validation error.
  """

  use Platform.Chat.Canvas.Kind

  @attachment_path_re ~r|^/chat/attachments/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$|

  @impl Platform.Chat.Canvas.Kind
  def children, do: :none

  @impl Platform.Chat.Canvas.Kind
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
            "Path-relative /chat/attachments/<uuid>. Upload bytes via attachment_upload_inline or attachment_upload_start and pass the returned `url` here."
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
         "Upload bytes via attachment_upload_inline and pass the returned `url`. Got #{inspect(src)}"}
    end
  end

  def validate_props(%{"src" => src}),
    do: {:error, "image src must be a string (got #{inspect(src)})"}

  def validate_props(_props),
    do: {:error, "image requires a \"src\" prop"}

  attr :node, :map, required: true

  @impl Platform.Chat.Canvas.Kind
  def render(assigns) do
    props = assigns.node["props"] || %{}
    assigns = assign(assigns, :props, props)

    ~H"""
    <div class={[
      "overflow-hidden",
      @props["rounded"] != false && "rounded-xl",
      @props["class_overrides"]
    ]}>
      <%!-- Wrapped in a link to the full-size blob. A design screenshot is
           usually captured at 1280-1440px and rendered into a much narrower
           canvas column, so `max-w-full` scales it down to the point of being
           unreadable. Tapping it opens the full-size image in the in-app
           image layer (assets/js/lib/image_layer.js, on the shared
           dismissable-overlay module), which closes with the X, Escape,
           swipe-down or the phone's back, on the standalone canvas page and
           inside chat alike.

           `data-image-viewer` is what routes the tap there: in_app_links.js
           never navigates the app to a raw /chat/attachments URL (a
           same-window load of a bare image document has no way back inside
           the iOS shell). The href stays as the no-JS fallback. --%>
      <a
        href={Platform.Chat.LinkTargets.open_href(@props["src"] || "")}
        {Platform.Chat.LinkTargets.open_attrs(@props["src"] || "")}
        data-image-viewer
        title="Open full size"
        class="block cursor-zoom-in"
      >
        <img
          src={@props["src"] || ""}
          alt={@props["alt"] || ""}
          class={[
            "max-w-full h-auto block",
            @props["border"] && "border border-edge"
          ]}
        />
      </a>
      <p :if={@props["caption"]} class="text-[11px] text-subtle text-center mt-1">
        {@props["caption"]}
      </p>
    </div>
    """
  end
end
