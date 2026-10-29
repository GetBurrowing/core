defmodule PlatformWeb.Components.ChatViewer do
  @moduledoc """
  The in-app viewer (redesign rung 13 stage 2; masters viewer, direction
  canvas 01a16748 VIEWER block). One full-window surface on desktop and
  phone. It is not a sheet: no backdrop, no handle.

  Top bar (56px, always visible): back (← "Back to chat"), the centred
  filename with a small meta line ("PDF · 2.1 MB"), Share, and Download only
  where a file exists (never for a prototype or a link).

  Modes, from `PlatformWeb.ChatLive.ViewerHooks`:

    * `image` - on the fixed near-black viewer ground; "2 of 4" and paging
      when the message has several images
    * `video` - the same player as inline, no autoplay
    * `file` - a PDF in a same-origin `/chat/attachments/<id>` frame; any
      other type a file panel (icon, name, size, type, Download), never a
      blank frame
    * `prototype` - the interactive same-host `/proto` frame, sandboxed
      exactly like `PlatformWeb.Components.Canvases.PrototypeFrame`
    * `link` - host, the full URL, and "Open in browser" as the only way out

  The root is always mounted (so the `ChatViewer` hook can record the scroll
  position before an open is pushed and restore it after the close patch);
  closed, it is an empty hidden element with no `data-fullscreen-viewer`.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  attr(:viewer, :map, default: nil)

  def chat_viewer(%{viewer: nil} = assigns) do
    ~H"""
    <div id="chat-viewer" phx-hook="ChatViewer" data-state="closed" hidden></div>
    """
  end

  def chat_viewer(assigns) do
    assigns = assign(assigns, :dark?, assigns.viewer.mode in ["image", "video"])

    ~H"""
    <div
      id="chat-viewer"
      phx-hook="ChatViewer"
      data-state="open"
      data-mode={@viewer.mode}
      data-share-path={@viewer.share_path}
      role="dialog"
      aria-modal="true"
      aria-label="Attachment viewer"
      data-fullscreen-viewer
      class={[
        "fixed inset-0 z-50 flex flex-col",
        if(@dark?, do: "bg-viewer text-on-viewer", else: "bg-base-100 text-base-content")
      ]}
    >
      <div
        data-role="viewer-bar"
        class={[
          "safe-area-top flex h-14 shrink-0 touch-none items-center gap-1 px-2",
          if(@dark?, do: "bg-viewer", else: "border-b border-edge bg-base-100")
        ]}
      >
        <button
          type="button"
          data-role="viewer-back"
          phx-click="viewer_close"
          aria-label="Back to chat"
          class="btn btn-ghost btn-square btn-sm text-current"
        >
          <.icon name="hero-arrow-left" class="size-5" />
        </button>
        <div class="min-w-0 flex-1 text-center">
          <div data-role="viewer-filename" class="truncate text-[15px] font-semibold">
            {@viewer.filename}
          </div>
          <div
            data-role="viewer-meta"
            class={["truncate text-[13px]", if(@dark?, do: "opacity-70", else: "text-subtle")]}
          >
            {@viewer.meta}<span
              :if={@viewer.mode == "image" and length(@viewer[:items] || []) > 1}
              data-role="viewer-count"
            > · {@viewer.index + 1} of {length(@viewer.items)}</span>
          </div>
        </div>
        <button
          type="button"
          data-role="viewer-share"
          aria-label="Share"
          class="btn btn-ghost btn-square btn-sm text-current"
        >
          <.icon name="hero-arrow-up-on-square" class="size-5" />
        </button>
        <a
          :if={@viewer.download_url && @viewer.mode in ["image", "video", "file"]}
          data-role="viewer-download"
          href={@viewer.download_url}
          download={@viewer.filename}
          aria-label="Download"
          class="btn btn-ghost btn-square btn-sm text-current"
        >
          <.icon name="hero-arrow-down-tray" class="size-5" />
        </a>
      </div>

      <%!-- Stage 4: the stage owns its gestures (swipe-down, pinch, pan)
           only where the viewer handles them; a prototype or a PDF frame
           keeps its own. --%>
      <div
        data-role="viewer-stage"
        class={[
          "relative flex min-h-0 flex-1 items-center justify-center overflow-hidden",
          @viewer.mode in ["image", "video"] && "touch-none"
        ]}
      >
        <.stage viewer={@viewer} />
      </div>

      <div
        data-role="viewer-hint"
        class={[
          "pointer-events-none shrink-0 py-3 text-center text-[13px]",
          if(@dark?, do: "opacity-60", else: "text-subtle")
        ]}
      >
        <span class="lg:hidden">swipe down or ← to go back</span>
        <span class="hidden lg:inline">Esc or ← to go back</span>
      </div>
    </div>
    """
  end

  attr(:viewer, :map, required: true)

  defp stage(%{viewer: %{mode: "image"}} = assigns) do
    ~H"""
    <img
      data-role="viewer-image"
      src={@viewer.src}
      alt={@viewer.filename}
      referrerpolicy="no-referrer"
      class="max-h-full max-w-full select-none object-contain will-change-transform"
      draggable="false"
    />
    <button
      :if={length(@viewer[:items] || []) > 1}
      type="button"
      data-role="viewer-prev"
      phx-click="viewer_page"
      phx-value-delta="-1"
      aria-label="Previous image"
      class="btn btn-circle btn-ghost btn-sm absolute left-2 top-1/2 -translate-y-1/2 text-current"
    >
      <.icon name="hero-chevron-left" class="size-5" />
    </button>
    <button
      :if={length(@viewer[:items] || []) > 1}
      type="button"
      data-role="viewer-next"
      phx-click="viewer_page"
      phx-value-delta="1"
      aria-label="Next image"
      class="btn btn-circle btn-ghost btn-sm absolute right-2 top-1/2 -translate-y-1/2 text-current"
    >
      <.icon name="hero-chevron-right" class="size-5" />
    </button>
    """
  end

  defp stage(%{viewer: %{mode: "video"}} = assigns) do
    ~H"""
    <video
      data-role="viewer-video"
      controls
      preload="metadata"
      playsinline
      src={@viewer.src}
      class="max-h-full max-w-full"
    >
    </video>
    """
  end

  defp stage(%{viewer: %{mode: "file", pdf?: true}} = assigns) do
    ~H"""
    <iframe
      data-role="viewer-pdf"
      src={@viewer.src}
      title={@viewer.filename}
      class="size-full border-0 bg-base-100"
    >
    </iframe>
    """
  end

  defp stage(%{viewer: %{mode: "file"}} = assigns) do
    ~H"""
    <div data-role="viewer-file-panel" class="flex flex-col items-center gap-2 p-8 text-center">
      <span class="flex size-20 items-center justify-center rounded-box bg-base-300">
        <.icon name="hero-document" class="size-9 text-base-content" />
      </span>
      <div class="max-w-full break-all text-[15px] font-semibold">{@viewer.filename}</div>
      <div class="text-[13px] text-subtle">{@viewer.meta}</div>
      <a
        data-role="viewer-file-download"
        href={@viewer.download_url}
        download={@viewer.filename}
        class="btn btn-primary mt-2"
      >
        Download
      </a>
    </div>
    """
  end

  defp stage(%{viewer: %{mode: "prototype"}} = assigns) do
    ~H"""
    <iframe
      data-role="viewer-prototype"
      src={@viewer.src}
      sandbox="allow-scripts"
      referrerpolicy="no-referrer"
      title={@viewer.filename}
      class="size-full border-0"
    >
    </iframe>
    """
  end

  defp stage(%{viewer: %{mode: "link"}} = assigns) do
    ~H"""
    <div
      data-role="viewer-link-panel"
      class="flex max-w-xl flex-col items-center gap-2 p-8 text-center"
    >
      <span class="flex size-20 items-center justify-center rounded-box bg-base-300">
        <.icon name="hero-globe-alt" class="size-9 text-base-content" />
      </span>
      <div class="text-[15px] font-semibold">{@viewer.host}</div>
      <div data-role="viewer-link-url" class="break-all font-mono text-[13px] text-subtle">
        {@viewer.url}
      </div>
      <a
        data-role="viewer-open-in-browser"
        href={Platform.Chat.LinkTargets.open_href(@viewer.url)}
        {Platform.Chat.LinkTargets.open_attrs(@viewer.url)}
        class="btn btn-primary mt-2"
      >
        Open in browser
      </a>
    </div>
    """
  end

  defp stage(assigns), do: ~H""
end
