defmodule PlatformWeb.Components.FilePreview do
  @moduledoc """
  The Files detail-pane preview body, shared by the desktop aside, the
  mobile drawer and the full-screen overlay (task 019ff1ab stage 2).

  One component rather than three copies of the same `case`: the three
  surfaces must agree about what a preview IS, and the previous
  duplication is what let the desktop pane and the mobile drawer drift.
  `scope` prefixes every `data-role` so the surfaces stay separately
  addressable in tests even though all three are in the DOM at once.

  ## The HTML branch

  Uploaded markup renders in an `<iframe sandbox="">` — no
  `allow-scripts`, no `allow-same-origin`. Granting BOTH is equivalent to
  no sandbox at all, since the document can then reach out and remove the
  attribute itself; they are therefore never to be added together, and
  `allow-scripts` alone is the delivery mechanism for stored XSS this
  branch exists to prevent. The frame's source carries `?preview=1`, the
  only mode in which the blob route answers markup inline, and that
  response is `Content-Security-Policy: sandbox` regardless.

  Two consequences are designed for, not worked around:

    * **Scripts off looks like a broken file.** Tabs do not switch,
      accordions stay shut, a JS-mounted body never appears. So a muted
      strip below the render says `Scripts are off in preview.` with
      Download beside it — the route to the working file. It is BELOW
      because a mockup's first 80px are its own header, and the sentence
      needs to be findable at the moment of confusion, not read before
      it. Not `warning`, not `error`: the condition is permanent and
      identical on every HTML file, and a warning that is always on is
      furniture within a week.

    * **A frame sized to the pane misrepresents the artefact.** At 100%
      width a desktop mockup's own media queries fire and the reviewer
      studies the mobile layout believing it is the desktop one. The
      frame gets a declared design width and the pane scrolls
      horizontally. Shrink-to-fit was rejected: 1280px squeezed into a
      600px pane is unreadable, and reading the mockup is the use case.
  """

  use Phoenix.Component

  alias Platform.Files
  alias PlatformWeb.FilesLive

  @doc """
  Renders the preview body for one file.

  `expandable` adds the full-screen control — on every previewable type,
  and never on `:unknown`: full-screening a "cannot preview this file"
  message is a control that does nothing, which is worse than no control.
  """
  attr :file, Files.File, required: true
  attr :text, :string, default: nil
  attr :scope, :string, required: true
  attr :expandable, :boolean, default: false

  def file_preview(assigns) do
    assigns =
      assigns
      |> assign(:mode, FilesLive.preview_mode(assigns.file))
      |> assign(:download_url, FilesLive.file_download_url(assigns.file))
      |> assign(:blob_url, FilesLive.file_attachment_url(assigns.file))

    ~H"""
    <div class="relative">
      <.fullscreen_button :if={@expandable and @mode != :unknown} scope={@scope} />
      <%= case @mode do %>
        <% :image -> %>
          <img
            src={@blob_url}
            alt={@file.original_filename}
            class="mx-auto max-h-[80vh] max-w-full rounded border border-base-300 object-contain"
            data-role={@scope <> "-image"}
          />
        <% :pdf -> %>
          <iframe
            src={@blob_url}
            class="h-[80vh] w-full rounded border-0"
            title={"Preview of " <> (@file.original_filename || "file")}
            data-role={@scope <> "-pdf"}
          >
          </iframe>
        <% :html -> %>
          <div class="rounded border border-base-300 bg-base-100">
            <div class="overflow-x-auto">
              <iframe
                src={FilesLive.file_preview_frame_url(@file)}
                sandbox=""
                referrerpolicy="no-referrer"
                style={"width: #{FilesLive.html_preview_width()}px; height: 70vh; border: 0; display: block;"}
                title={"Preview of " <> (@file.original_filename || "file")}
                data-role={@scope <> "-html"}
              >
              </iframe>
            </div>
            <div
              class="flex items-center justify-between gap-3 border-t border-base-300 px-3 py-2 text-sm text-base-content"
              data-role={@scope <> "-html-notice"}
            >
              <span>Scripts are off in preview.</span>
              <a
                href={@download_url}
                class="link link-primary"
                download={@file.original_filename || @file.name || "file"}
              >
                Download
              </a>
            </div>
          </div>
        <% :markdown -> %>
          <div
            :if={@text}
            class="prose prose-sm max-w-none rounded border border-base-300 bg-base-100 p-3"
            data-role={@scope <> "-markdown"}
          >
            {FilesLive.render_markdown_text(@text)}
          </div>
          <.no_text_yet :if={!@text} scope={@scope} />
        <% :text -> %>
          <pre
            :if={@text}
            class="whitespace-pre-wrap break-words rounded border border-base-300 bg-base-200 p-3 text-xs"
            data-role={@scope <> "-text"}
          >{@text}</pre>
          <.no_text_yet :if={!@text} scope={@scope} />
        <% :document -> %>
          <div
            :if={@text}
            class="prose prose-sm max-w-none whitespace-pre-wrap break-words rounded border border-base-300 bg-base-100 p-3"
            data-role={@scope <> "-document"}
          >
            {@text}
          </div>
          <.no_text_yet :if={!@text} scope={@scope} />
        <% :unknown -> %>
          <div
            class="rounded border border-base-300 bg-base-200 p-4 text-sm text-base-content/70"
            data-role={@scope <> "-unknown"}
          >
            <p>Cannot preview this file type ({@file.content_type}) in the browser.</p>
            <p class="mt-2">
              <a
                href={@download_url}
                class="link link-primary"
                download={@file.original_filename || @file.name || "file"}
              >
                Download the file
              </a>
              to open it in a native application.
            </p>
          </div>
      <% end %>
    </div>
    """
  end

  attr :scope, :string, required: true

  defp no_text_yet(assigns) do
    ~H"""
    <p class="text-sm text-base-content/60" data-role={@scope <> "-no-text"}>
      No extracted text yet. The file may still be ingesting.
    </p>
    """
  end

  attr :scope, :string, required: true

  defp fullscreen_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open_preview_fullscreen"
      class="btn btn-ghost btn-sm btn-square absolute right-2 top-2 z-10 bg-base-100/90 max-sm:min-h-[44px] max-sm:min-w-[44px]"
      aria-label="Full screen preview"
      title="Full screen"
      data-role={@scope <> "-fullscreen-open"}
    >
      <span class="hero-arrows-pointing-out size-4"></span>
    </button>
    """
  end

  @doc """
  Full-screen preview overlay.

  Mirrors the `active_review_canvas` modal on the Tasks panel — the
  affordance "full screen much like we do for canvases" names — rather
  than the stack dep-graph expand, which is itself a copy of that modal.

  Z-INDEX: `z-[45]`, not `z-50`. `z-50` is reserved for the per-canvas
  review overlay; a second surface at the same level only misbehaves when
  both are open, which is the state nobody screenshots. 45 still clears
  the Files mobile drawer at `z-40`.
  """
  attr :file, Files.File, required: true
  attr :text, :string, default: nil

  def preview_fullscreen(assigns) do
    ~H"""
    <div
      id="files-preview-fullscreen"
      class="fixed inset-0 z-[45] flex items-center justify-center px-4 py-6 max-sm:p-0"
      phx-window-keydown="close_preview_fullscreen"
      phx-key="Escape"
      data-role="files-preview-fullscreen"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="close_preview_fullscreen" />
      <div class="relative z-10 flex max-h-[90vh] w-full max-w-6xl flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl max-sm:h-full max-sm:max-h-none max-sm:rounded-none">
        <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
          <div class="min-w-0">
            <div class="truncate text-sm font-semibold">
              {@file.name || @file.original_filename || "File"}
            </div>
            <div class="text-xs text-base-content/60">{@file.content_type}</div>
          </div>
          <button
            class="btn btn-ghost btn-sm btn-square max-sm:min-h-[44px] max-sm:min-w-[44px]"
            phx-click="close_preview_fullscreen"
            aria-label="Close full screen preview"
            data-role="files-preview-fullscreen-close"
          >
            <span class="hero-x-mark size-4"></span>
          </button>
        </div>
        <div class="overflow-auto p-4">
          <.file_preview file={@file} text={@text} scope="files-fullscreen" />
        </div>
      </div>
    </div>
    """
  end
end
