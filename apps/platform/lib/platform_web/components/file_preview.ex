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

  ## Interactive prototypes (task 01a06a20 stage 3)

  A file flagged via `Platform.Files.mark_interactive/2`
  (`file.interactive_at` set) renders a DIFFERENT `:html` sub-branch.
  The unflagged branch above is untouched by this stage, byte for byte.

  The sandbox gains `allow-scripts` — never `allow-same-origin`, same
  invariant as above — because a flagged file is meant to be clicked
  through, not just looked at. Network access is already cut at the
  response layer by the `Sec-Fetch-Dest: iframe` CSP gate added in
  stage 2 (`PlatformWeb.FileBlobController`), so `allow-scripts` here
  grants code execution inside an origin that still can't phone home.

  What THIS stage adds is the attribution bar above the frame, in
  Burrow's own DOM, never inside the `<iframe>`. That placement is the
  actual mitigation for the one thing the sandbox cannot stop: a framed
  page that imitates Burrow to phish whoever is clicking through it. A
  badge drawn inside the iframe is worthless against that — an
  imitation page simply paints its own copy over it — so the bar has to
  live on a surface the framed document cannot draw into, and it owns a
  full edge rather than a corner. See canvas
  `01a06a22-8607-7001-ba02-8095ab4531ad` for the full design rationale,
  including the two rejected alternatives (a warning banner, a corner
  badge).

  Token discipline on this surface is deliberate: `--color-info` (the
  `Live` pill) and `--color-primary` (the one action) are the only
  saturated colours. No `--color-warning`, no `--color-error`, anywhere
  — the condition is permanent and identical on every prototype, and an
  always-on warning is furniture within a week (the same argument the
  unflagged notice above already makes about "Scripts are off").

  The frame itself drops the fixed-1280px-with-horizontal-scroll
  treatment for a scale-to-fit transform (`phx-hook="FilePreviewScale"`,
  reusing the canvas embed's auto-scale approach — see that hook's
  moduledoc for why it is a separate file rather than a shared one). A
  prototype is meant to be used, not studied at a fixed width; the
  unflagged path keeps the fixed-width treatment because its reasoning
  above (a shrunk desktop mockup's media queries fire wrong) still
  holds for a static picture nobody is clicking through.
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
      |> assign(:interactive?, not is_nil(assigns.file.interactive_at))

    ~H"""
    <div class="relative">
      <%!-- The interactive :html branch renders its own "Full window"
           action inside the attribution bar (task 01a06a20 stage 3) —
           the corner icon would be a second, redundant control for the
           one mode that already has one. --%>
      <.fullscreen_button
        :if={@expandable and @mode != :unknown and not (@mode == :html and @interactive?)}
        scope={@scope}
      />
      <%= case @mode do %>
        <% :image -> %>
          <img
            src={@blob_url}
            alt={@file.original_filename}
            class="mx-auto max-h-[80vh] max-w-full rounded border border-edge object-contain"
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
          <%= if @interactive? do %>
            <div
              class="overflow-hidden rounded-box border border-edge bg-base-100"
              data-role={@scope <> "-html-interactive"}
            >
              <.interactive_attribution_bar file={@file} scope={@scope} />
              <div
                id={@scope <> "-html-scale-" <> @file.id}
                phx-hook="FilePreviewScale"
                phx-update="ignore"
                data-role={@scope <> "-html-scale"}
                data-declared-width={FilesLive.html_preview_width()}
                data-declared-height={FilesLive.html_preview_height()}
                style={"height: #{FilesLive.html_preview_height()}px;"}
              >
                <iframe
                  src={FilesLive.file_preview_frame_url(@file)}
                  sandbox="allow-scripts"
                  referrerpolicy="no-referrer"
                  style={"width: #{FilesLive.html_preview_width()}px; height: #{FilesLive.html_preview_height()}px; border: 0; display: block;"}
                  title={"Preview of " <> (@file.original_filename || "file")}
                  data-role={@scope <> "-html"}
                >
                </iframe>
              </div>
              <div
                class="flex items-center justify-between gap-3 border-t border-edge px-3 py-2 text-sm text-base-content"
                data-role={@scope <> "-html-notice"}
              >
                <span>Interactive prototype. Never enter a password here.</span>
                <a
                  href={@download_url}
                  class="link link-primary"
                  download={@file.original_filename || @file.name || "file"}
                >
                  Download
                </a>
              </div>
            </div>
          <% else %>
            <div class="rounded border border-edge bg-base-100">
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
                class="flex items-center justify-between gap-3 border-t border-edge px-3 py-2 text-sm text-base-content"
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
          <% end %>
        <% :markdown -> %>
          <div
            :if={@text}
            class="prose prose-sm max-w-none rounded border border-edge bg-base-100 p-3"
            data-role={@scope <> "-markdown"}
          >
            {FilesLive.render_markdown_text(@text)}
          </div>
          <.no_text_yet :if={!@text} scope={@scope} />
        <% :text -> %>
          <pre
            :if={@text}
            class="whitespace-pre-wrap break-words rounded border border-edge bg-base-200 p-3 text-xs"
            data-role={@scope <> "-text"}
          >{@text}</pre>
          <.no_text_yet :if={!@text} scope={@scope} />
        <% :document -> %>
          <div
            :if={@text}
            class="prose prose-sm max-w-none whitespace-pre-wrap break-words rounded border border-edge bg-base-100 p-3"
            data-role={@scope <> "-document"}
          >
            {@text}
          </div>
          <.no_text_yet :if={!@text} scope={@scope} />
        <% :unknown -> %>
          <div
            class="rounded border border-edge bg-base-200 p-4 text-sm text-base-content/70"
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
    <p class="text-sm text-subtle" data-role={@scope <> "-no-text"}>
      No extracted text yet. The file may still be ingesting.
    </p>
    """
  end

  # Attribution bar for a flagged (interactive) HTML preview (task
  # 01a06a20 stage 3).
  #
  # Burrow DOM, not iframe content — see the "Interactive prototypes"
  # moduledoc section for why that placement is the mitigation, not
  # decoration. Six token slots, no more: `base-200` ground, `base-300`
  # hairline, `base-content` filename, `neutral` attribution, `info` the
  # `Live` pill, `primary` the one action. No warning/error token
  # appears here.
  #
  # Truncation order (most meaningful last): the pill, size and action
  # carry `shrink-0 whitespace-nowrap` and never truncate. The filename
  # is `flex-1 min-w-0 truncate` — it goes second. The attribution line
  # is pinned to its own full-width row (`w-full`) below the rest, so on
  # a narrow viewport it is the first thing to run out of room.
  attr :file, Files.File, required: true
  attr :scope, :string, required: true

  defp interactive_attribution_bar(assigns) do
    ~H"""
    <div
      class="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-edge bg-base-200 px-3 py-2"
      data-role={@scope <> "-html-attribution-bar"}
    >
      <span
        class="badge badge-info badge-sm shrink-0 whitespace-nowrap"
        data-role={@scope <> "-html-live-pill"}
      >
        Live
      </span>
      <span
        class="min-w-0 flex-1 truncate text-sm font-semibold text-base-content"
        data-role={@scope <> "-html-filename"}
      >
        {@file.original_filename || @file.name || "file"}
      </span>
      <span
        class="shrink-0 whitespace-nowrap font-mono text-xs text-base-content/70"
        data-role={@scope <> "-html-size"}
      >
        {FilesLive.humanize_bytes(@file.byte_size)}
      </span>
      <button
        type="button"
        phx-click="open_preview_fullscreen"
        class="btn btn-primary btn-xs shrink-0 whitespace-nowrap"
        data-role={@scope <> "-html-full-window"}
      >
        Full window
      </button>
      <span
        class="w-full min-w-0 truncate text-xs text-neutral"
        data-role={@scope <> "-html-attribution"}
      >
        {FilesLive.interactive_attribution_text(@file)}
      </span>
    </div>
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
      <div class="relative z-10 flex max-h-[90vh] w-full max-w-6xl flex-col overflow-hidden rounded-2xl border border-edge bg-base-100 shadow-2xl max-sm:h-full max-sm:max-h-none max-sm:rounded-none">
        <div class="flex items-center justify-between border-b border-edge px-4 py-3">
          <div class="min-w-0">
            <div class="truncate text-sm font-semibold">
              {@file.name || @file.original_filename || "File"}
            </div>
            <div class="text-xs text-subtle">{@file.content_type}</div>
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

  @doc """
  The interactive-code flag control (task 01a06a20 stage 3).

  Lives in the FilesLive detail pane beside Download, never in the
  upload dialogue: flipping it is a deliberate second act taken after
  looking at the file, not a checkbox ticked while dragging something
  in. A `join`/`join-item` segmented control — DaisyUI styles a join's
  end buttons with `--radius-field` itself, so no manual radius class is
  needed here — deliberately not a toggle switch: a switch implies a
  personal preference, and this is a decision with consequences for
  whoever opens the file next.

  States are named by CONSEQUENCE rather than by setting, per the same
  descriptive-naming rule the rest of this surface follows. Calls
  `PlatformWeb.FilesLive`'s `"mark_interactive"` / `"unmark_interactive"`
  event clauses, which wrap `Platform.Files.mark_interactive/2` /
  `unmark_interactive/2` from stage 1.

  `id_suffix` disambiguates the desktop pane's control from the mobile
  drawer's — both render in the DOM at once, same reason `scope` exists
  on `file_preview/1`.
  """
  attr :file, Files.File, required: true
  attr :id_suffix, :string, default: ""

  def interactive_toggle(assigns) do
    assigns = assign(assigns, :interactive?, not is_nil(assigns.file.interactive_at))

    ~H"""
    <div
      class="join shrink-0"
      role="group"
      aria-label="Interactive prototype control"
      data-role={"files-detail-interactive-toggle" <> @id_suffix}
    >
      <button
        type="button"
        phx-click="unmark_interactive"
        phx-value-id={@file.id}
        class={["btn btn-sm join-item", if(@interactive?, do: "btn-ghost", else: "btn-primary")]}
        aria-pressed={to_string(!@interactive?)}
        data-role={"files-detail-interactive-off" <> @id_suffix}
      >
        Scripts are off
      </button>
      <button
        type="button"
        phx-click="mark_interactive"
        phx-value-id={@file.id}
        class={["btn btn-sm join-item", if(@interactive?, do: "btn-primary", else: "btn-ghost")]}
        aria-pressed={to_string(@interactive?)}
        data-role={"files-detail-interactive-on" <> @id_suffix}
      >
        Runs as a prototype
      </button>
    </div>
    """
  end
end
