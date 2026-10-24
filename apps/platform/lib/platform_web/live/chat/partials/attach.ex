defmodule PlatformWeb.ChatLive.Partials.Attach do
  @moduledoc """
  The composer's staged tray (redesign rung 11, task 01a1557a-9de3): what
  you pasted, picked or dropped sits INSIDE the message box, above the
  caption line, so the message you are building looks like the message that
  will post. Spec: masters canvas 01a1382f (master-mobile `#attach-preview`,
  master-desktop `#preview`) and direction canvas 01a16558 (m2 layout, m3
  rules).

  Function components only (ADR 0035). State lives in `AttachHooks` (tray
  events and the send guard) and `LargeUploadHooks` (files over the inline
  cap); `@uploads.attachments` is LiveView's own upload state.

  The tray is ABSENT from the DOM when nothing is staged, so the composer
  keeps no empty band. Everything the tray shows is a list item: image
  thumbs, file chips (non-images and every large file) and, below the list,
  one line per refusal ("TOO LARGE" and LiveView's validation errors).
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]
  import PlatformWeb.ChatLive.Partials, only: [upload_error_to_string: 1]
  import PlatformWeb.Components.ChatHelpers, only: [relative_time: 1]
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Chat.UploadLimits
  alias PlatformWeb.ChatLive.AttachHooks
  alias PlatformWeb.ChatLive.CanvasHooks
  alias PlatformWeb.ChatLive.Partials.Composer

  attr(:uploads, :any, required: true)
  attr(:large_staged, :list, default: [])
  attr(:limits, :map, default: nil)
  attr(:canvas, :any, default: nil)
  attr(:failed, :list, default: [])

  @doc """
  The staged tray. `order-first basis-full` puts it on its own line at the
  top of `.compose-pill-bar`'s flex-wrap row at every width, including the
  narrow container query that moves the textarea to `order: -1`.
  """
  def staged_tray(assigns) do
    upload = assigns.uploads.attachments
    assigns = assign(assigns, :upload, upload)

    ~H"""
    <div
      :if={@upload.entries != [] or @large_staged != [] or @failed != [] or @canvas}
      data-role="staged-area"
      class="order-first flex min-w-0 basis-full flex-col gap-1"
    >
      <ul
        data-role="staged-tray"
        aria-label="Attachments"
        class="flex min-w-0 gap-2 overflow-x-auto pt-1"
      >
        <.failed_item :for={file <- @failed} file={file} />
        <.entry_item :for={entry <- @upload.entries} entry={entry} upload={@upload} />
        <.large_chip :for={file <- @large_staged} file={file} />
        <.canvas_chip :if={@canvas} canvas={@canvas} />
        <%!-- Desktop add-more tile (master-desktop / image-paste `.pv.add`):
             the any-type picker, appending to the tray. A phone adds more
             through ＋. --%>
        <li class="shrink-0 max-lg:hidden">
          <button
            type="button"
            data-attach-pick="file"
            data-role="attach-add-more"
            aria-label="Add another"
            class="flex h-[92px] w-16 items-center justify-center rounded-md border border-dashed border-edge text-subtle lg:hover:text-base-content focus-visible-ring"
          >
            <.icon name="hero-plus" class="size-6" />
          </button>
        </li>
      </ul>

      <p
        :for={error <- upload_errors(@upload)}
        data-role="staged-error"
        class="flex items-center gap-1 text-xs text-base-content"
      >
        <.icon name="hero-exclamation-circle" class="size-4 shrink-0 text-error" />
        {upload_error_to_string(error)}
      </p>
      <%= for entry <- @upload.entries, error <- upload_errors(@upload, entry) do %>
        <p data-role="staged-error" class="flex items-center gap-1 text-xs text-base-content">
          <.icon name="hero-exclamation-circle" class="size-4 shrink-0 text-error" />
          <span class="min-w-0 truncate">{entry.client_name}: {upload_error_to_string(error)}</span>
        </p>
      <% end %>
      <%!-- TOO LARGE (design canvas 01a120be-f336): the existing copy,
           verbatim, in base-content with the error hue on the icon only
           (`text-error` fails 4.5:1 as text in five of the ten variants). --%>
      <p
        :for={file <- Enum.filter(@large_staged, & &1.too_large?)}
        data-role="staged-too-large"
        class="flex items-center gap-1 text-xs text-base-content"
      >
        <.icon name="hero-exclamation-circle" class="size-4 shrink-0 text-error" />
        <span class="min-w-0">
          <span title={file.name}>{Composer.middle_truncate(file.name)}</span>
          is {UploadLimits.format_bytes(max(file.size, 0))}. This Burrow install accepts files up to {@limits &&
            @limits.label}.
        </span>
      </p>
    </div>
    """
  end

  attr(:entry, :any, required: true)
  attr(:upload, :any, required: true)

  # One LiveView entry: an image thumb (live_img_preview, a client blob URL,
  # so it shows before a byte has moved) or a file chip.
  defp entry_item(assigns) do
    entry = assigns.entry

    assigns =
      assigns
      |> assign(:image?, String.starts_with?(entry.client_type || "", "image/"))
      |> assign(:failed?, AttachHooks.failed?(assigns.upload, entry))
      |> assign(:retry?, AttachHooks.retryable?(assigns.upload, entry))

    ~H"""
    <li
      id={"staged-#{@entry.ref}"}
      data-ref={@entry.ref}
      data-state={state(@entry, @failed?)}
      class="relative shrink-0"
    >
      <div
        :if={@image?}
        class={[
          "relative size-[72px] overflow-hidden rounded-md border border-edge bg-base-300 lg:h-[92px] lg:w-auto lg:min-w-16 lg:max-w-[200px]",
          @failed? && "outline outline-2 -outline-offset-2 outline-error"
        ]}
      >
        <%!-- `live_img_preview/1`'s markup, written out because its `:rest`
             is `:global` and does not take `alt` (the file name). --%>
        <img
          id={"phx-preview-#{@entry.ref}"}
          data-phx-upload-ref={@entry.upload_ref}
          data-phx-entry-ref={@entry.ref}
          data-phx-hook="Phoenix.LiveImgPreview"
          data-phx-update="ignore"
          alt={@entry.client_name}
          class="block size-full object-cover lg:h-[92px] lg:w-auto lg:max-w-[200px]"
        />
        <%!-- Desktop name strip (master-desktop `.pv .nm`). `max-lg:hidden`,
             not `hidden lg:block`: app.css turns any `.hidden` inside
             `.compose-pill-bar` into an sr-only box with `!important`. --%>
        <span
          aria-hidden="true"
          class="absolute inset-x-0 bottom-0 block truncate bg-gradient-to-t from-black/70 to-transparent px-2 pb-0.5 pt-3 text-xs text-white max-lg:hidden"
        >
          {@entry.client_name}
        </span>
      </div>
      <.file_chip
        :if={!@image?}
        name={@entry.client_name}
        size={@entry.client_size}
        type={@entry.client_type}
        failed?={@failed?}
      />
      <.upload_ring :if={!@failed? and @entry.progress < 100} progress={@entry.progress} />
      <.retry_button :if={@retry?} ref={@entry.ref} name={@entry.client_name} />
      <.remove_button
        label={"Remove #{@entry.client_name}"}
        event="attach_remove"
        ref={@entry.ref}
      />
    </li>
    """
  end

  attr(:file, :map, required: true)

  # A file whose upload a socket drop interrupted (`AttachHooks`
  # `:attach_failed`): the LiveView entry died with the old process, so the
  # thumbnail is rebuilt from what the client kept. Same frame, outline and
  # retry glyph as a failed entry; the image comes from the client's File
  # (`AttachFailedPreview`), retry stages that File again.
  defp failed_item(assigns) do
    assigns = assign(assigns, :image?, String.starts_with?(assigns.file.type || "", "image/"))

    ~H"""
    <li
      id={"staged-failed-#{@file.id}"}
      data-failed-id={@file.id}
      data-state="failed"
      class="relative shrink-0"
    >
      <div
        :if={@image?}
        class="relative size-[72px] overflow-hidden rounded-md border border-edge bg-base-300 outline outline-2 -outline-offset-2 outline-error lg:h-[92px] lg:w-auto lg:min-w-16 lg:max-w-[200px]"
      >
        <img
          id={"attach-failed-preview-#{@file.id}"}
          phx-hook="AttachFailedPreview"
          phx-update="ignore"
          data-failed-id={@file.id}
          alt={@file.name}
          class="block size-full object-cover lg:h-[92px] lg:w-auto lg:max-w-[200px]"
        />
        <span
          aria-hidden="true"
          class="absolute inset-x-0 bottom-0 block truncate bg-gradient-to-t from-black/70 to-transparent px-2 pb-0.5 pt-3 text-xs text-white max-lg:hidden"
        >
          {@file.name}
        </span>
      </div>
      <.file_chip :if={!@image?} name={@file.name} size={@file.size} type={@file.type} failed?={true} />
      <.retry_button ref={@file.id} name={@file.name} />
      <.remove_button label={"Remove #{@file.name}"} event="attach_failed_remove" ref={@file.id} />
    </li>
    """
  end

  attr(:ref, :string, required: true)
  attr(:name, :string, required: true)

  # The retry glyph (direction m3 rule 4), centred on a failed thumbnail.
  # `assets/js/attach_stage.js` handles the click: it drops the failed item
  # and stages the same File again.
  defp retry_button(assigns) do
    ~H"""
    <button
      type="button"
      data-attach-retry={@ref}
      aria-label={"Retry #{@name}"}
      class="absolute inset-0 m-auto flex size-11 items-center justify-center"
    >
      <span class="flex size-8 items-center justify-center rounded-full bg-black/60 text-error">
        <.icon name="hero-arrow-path" class="size-5" />
      </span>
    </button>
    """
  end

  attr(:file, :map, required: true)

  # A staged large file (over the inline cap). It uploads after Send through
  # the chunked path, so its chip has no ring; one over the install's limit
  # gets the error outline and never uploads.
  defp large_chip(assigns) do
    ~H"""
    <li
      id={"large-staged-#{@file.ref}"}
      data-ref={@file.ref}
      data-state={if @file.too_large?, do: "too-large", else: "staged"}
      data-too-large={to_string(@file.too_large?)}
      class="relative shrink-0"
    >
      <.file_chip name={@file.name} size={@file.size} type={@file.type} failed?={@file.too_large?} />
      <.remove_button label={"Remove #{@file.name}"} event="large_upload_unstage" ref={@file.ref} />
    </li>
    """
  end

  attr(:canvas, :map, required: true)

  # The one staged canvas (picked from Recent canvases). It posts as the
  # message's `canvas_id`.
  defp canvas_chip(assigns) do
    ~H"""
    <li id={"staged-canvas-#{@canvas.id}"} data-role="canvas-chip" class="relative shrink-0">
      <div
        title={canvas_title(@canvas)}
        class="flex h-[72px] w-44 items-center gap-2 rounded-md border border-edge bg-base-300 pl-3 pr-8 lg:h-[92px] lg:w-52"
      >
        <.icon name="hero-squares-2x2" class="size-6 shrink-0 text-subtle" />
        <span class="flex min-w-0 flex-col">
          <span class="truncate text-sm text-base-content">{canvas_title(@canvas)}</span>
          <span class="truncate text-xs text-subtle">Canvas</span>
        </span>
      </div>
      <.remove_button
        label={"Remove #{canvas_title(@canvas)}"}
        event="attach_canvas_remove"
        ref={@canvas.id}
      />
    </li>
    """
  end

  attr(:name, :string, required: true)
  attr(:size, :integer, required: true)
  attr(:type, :string, default: "")
  attr(:failed?, :boolean, default: false)

  # Direction rule 7: the stem truncates, the extension never does, and the
  # '<size> · <TYPE>' line is the first thing to go on a narrow chip.
  defp file_chip(assigns) do
    {stem, ext} = split_name(assigns.name)

    assigns =
      assigns
      |> assign(:stem, stem)
      |> assign(:ext, ext)
      |> assign(
        :meta,
        "#{UploadLimits.format_bytes(max(assigns.size || 0, 0))} · #{type_label(assigns.name, assigns.type)}"
      )

    ~H"""
    <div
      data-role="file-chip"
      title={@name}
      class={[
        "flex h-[72px] w-44 items-center gap-2 rounded-md border border-edge bg-base-300 pl-3 pr-8 lg:h-[92px] lg:w-52",
        @failed? && "outline outline-2 -outline-offset-2 outline-error"
      ]}
    >
      <.icon name="hero-document" class="size-6 shrink-0 text-subtle" />
      <span class="flex min-w-0 flex-col">
        <span class="flex min-w-0 text-sm text-base-content">
          <span class="truncate">{@stem}</span><span class="shrink-0">{@ext}</span>
        </span>
        <span class="truncate text-xs tabular-nums text-subtle">{@meta}</span>
      </span>
    </div>
    """
  end

  attr(:progress, :integer, required: true)

  # The upload ring (direction m3 rule 1): a primary arc for the entry's
  # progress over a shade, centred on the item. Decorative; Send's
  # accessible name ('Uploading') carries the state for assistive tech.
  defp upload_ring(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      data-role="upload-ring"
      class="pointer-events-none absolute inset-0 m-auto flex size-9 items-center justify-center rounded-full bg-black/60"
    >
      <svg viewBox="0 0 36 36" class="size-7 -rotate-90 text-primary">
        <circle
          cx="18"
          cy="18"
          r="15"
          fill="none"
          stroke="currentColor"
          stroke-opacity="0.3"
          stroke-width="3"
        />
        <circle
          cx="18"
          cy="18"
          r="15"
          fill="none"
          stroke="currentColor"
          stroke-width="3"
          stroke-linecap="round"
          stroke-dasharray="94.25"
          stroke-dashoffset={Float.round(94.25 * (1 - @progress / 100), 2)}
        />
      </svg>
    </span>
    """
  end

  attr(:label, :string, required: true)
  attr(:event, :string, required: true)
  attr(:ref, :string, required: true)

  # Direction rule 2: a 20px × on a dark shade, inside a 44px hit area on a
  # phone (32px on desktop), top-right.
  defp remove_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      phx-value-ref={@ref}
      aria-label={@label}
      class="absolute right-0 top-1 flex size-11 items-start justify-end p-0.5 lg:size-8"
    >
      <span class="flex size-5 items-center justify-center rounded-full bg-black/60 text-white">
        <.icon name="hero-x-mark" class="size-3.5" />
      </span>
    </button>
    """
  end

  # ── The ＋ menu: a bottom sheet on a phone, a popover on desktop ─────────

  attr(:open, :boolean, required: true)
  attr(:canvases, :list, default: [])

  @doc """
  The phone ＋ sheet (master-mobile `#attach-sheet`): camera tile and a
  library strip with numbered selection, record rows, Upload a file, Recent
  canvases (this space's, newest two) and a pinned 'Attach N items'.

  A browser cannot enumerate the camera roll, so the strip starts with the
  camera tile and a Library tile; files picked through it appear in the
  strip pre-selected and numbered in pick order. The selection is
  CLIENT-ONLY (the `AttachSheet` hook, in `phx-update="ignore"` containers):
  nothing uploads until 'Attach N items', which hands the files to the one
  staging function in pick order. Rendered outside the composer's glass
  dock so the fixed sheet stacks above the tab bar.
  """
  def attach_sheet(assigns) do
    assigns = assign(assigns, :recent, recent(assigns.canvases, 2))

    ~H"""
    <.sheet
      id="attach-sheet"
      open={@open}
      placement={:bottom}
      on_close="attach_menu_close"
      class="attach-sheet lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>Attach</:title>
      <div class="flex flex-col pb-2" data-role="attach-sheet-body">
        <div class="flex items-center justify-between px-4 pb-2">
          <p class="text-base font-semibold text-base-content" aria-hidden="true">
            Photos &amp; Videos
          </p>
          <button
            type="button"
            data-attach-pick="library"
            class="min-h-11 px-1 text-sm font-medium text-base-content underline underline-offset-2 focus-visible-ring"
          >
            View Library
          </button>
        </div>

        <div
          id="attach-strip"
          phx-hook="AttachSheet"
          phx-update="ignore"
          role="group"
          aria-label="Photos"
          data-role="attach-strip"
          class="flex gap-2 overflow-x-auto px-4 pb-3"
        >
          <button
            type="button"
            data-attach-pick="camera"
            data-role="attach-camera"
            class="flex size-24 shrink-0 flex-col items-center justify-center gap-1 rounded-box border border-edge bg-base-100 text-base-content active:bg-base-200 focus-visible-ring"
          >
            <.icon name="hero-camera" class="size-7" />
            <span class="text-xs text-subtle">Camera</span>
          </button>
          <button
            type="button"
            data-attach-pick="library"
            data-role="attach-library"
            class="flex size-24 shrink-0 flex-col items-center justify-center gap-1 rounded-box border border-edge bg-base-100 text-base-content active:bg-base-200 focus-visible-ring"
          >
            <.icon name="hero-photo" class="size-7" />
            <span class="text-xs text-subtle">Library</span>
          </button>
          <input
            :for={{kind, accept, capture, multiple} <- pickers()}
            type="file"
            id={"attach-input-#{kind}"}
            data-attach-input={kind}
            accept={accept}
            capture={capture}
            multiple={multiple}
            class="sr-only"
            tabindex="-1"
            aria-hidden="true"
          />
        </div>

        <.menu_row pick="audio" icon="hero-microphone" label="Record an audio clip" />
        <.menu_row pick="video" icon="hero-video-camera" label="Record a video clip" />
        <.menu_row pick="file" icon="hero-arrow-up-tray" label="Upload a file" />

        <%= if @recent != [] do %>
          <p class="px-4 pb-1 pt-3 text-xs font-medium text-subtle">Recent canvases</p>
          <.canvas_row :for={canvas <- @recent} canvas={canvas} />
        <% end %>

        <%!-- Pinned 'Attach N items' (master-mobile `#attach-go`): hidden at
             0 picks, the only primary on the sheet. Its count and visibility
             are the AttachSheet hook's, so the server leaves it alone. --%>
        <div
          id="attach-go-wrap"
          phx-update="ignore"
          class="sticky bottom-0 mt-2 border-t border-edge bg-base-200 px-4 pt-3 pb-[max(0.5rem,env(safe-area-inset-bottom))]"
          hidden
        >
          <button
            type="button"
            id="attach-go"
            class="flex h-12 w-full items-center justify-center rounded-box bg-primary text-[15px] font-semibold tabular-nums text-primary-content focus-visible-ring"
          >
            Attach 0 items
          </button>
        </div>
      </div>
    </.sheet>
    """
  end

  attr(:canvases, :list, default: [])

  @doc """
  The desktop ＋ popover (master-desktop `.pop`): anchored above ＋, no photo
  strip and no 'Attach N items' (desktop has no camera roll; direction rule
  8). The pickers open the OS picker and stage straight into the tray.
  Rendered only while open; Esc and a click outside close it.
  """
  def attach_popover(assigns) do
    assigns = assign(assigns, :recent, recent(assigns.canvases, 3))

    ~H"""
    <div class="relative max-lg:hidden" data-role="attach-popover-anchor">
      <button
        type="button"
        class="fixed inset-0 z-40 cursor-default"
        tabindex="-1"
        aria-hidden="true"
        data-role="attach-popover-scrim"
        phx-click="attach_menu_close"
      >
      </button>
      <div
        id="attach-popover"
        role="dialog"
        aria-label="Attach"
        phx-window-keydown="attach_menu_close"
        phx-key="Escape"
        phx-mounted={JS.focus_first()}
        class="absolute bottom-0 left-0 z-50 flex min-w-60 max-w-80 flex-col rounded-box border border-edge bg-base-200 p-1.5 shadow-lg"
      >
        <p class="px-2 pb-1 pt-1.5 text-xs text-subtle">Attach</p>
        <button
          type="button"
          data-attach-pick="media"
          class="flex w-full items-center gap-2 rounded-field px-2 py-1.5 text-left lg:hover:bg-base-300 focus-visible-ring"
        >
          <.icon name="hero-photo" class="size-5 shrink-0 text-subtle" />
          <span class="flex min-w-0 flex-col">
            <span class="text-sm text-base-content">Photos &amp; files from this computer</span>
            <span class="text-xs text-subtle">or paste / drop into the composer</span>
          </span>
        </button>
        <button
          type="button"
          data-attach-pick="file"
          class="flex w-full items-center gap-2 rounded-field px-2 py-1.5 text-left text-sm text-base-content lg:hover:bg-base-300 focus-visible-ring"
        >
          <.icon name="hero-arrow-up-tray" class="size-5 shrink-0 text-subtle" />
          <span>Upload a file</span>
        </button>
        <%= if @recent != [] do %>
          <p class="px-2 pb-1 pt-2 text-xs text-subtle">Recent canvases</p>
          <button
            :for={canvas <- @recent}
            type="button"
            phx-click="attach_canvas"
            phx-value-id={canvas.id}
            data-role="attach-canvas-row"
            class="flex w-full items-center gap-2 rounded-field px-2 py-1.5 text-left lg:hover:bg-base-300 focus-visible-ring"
          >
            <.icon name="hero-squares-2x2" class="size-5 shrink-0 text-subtle" />
            <span class="flex min-w-0 flex-col">
              <span class="truncate text-sm text-base-content">{canvas_title(canvas)}</span>
              <span class="text-xs text-subtle">Edited {relative_time(canvas.updated_at)}</span>
            </span>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  The desktop drop target over the conversation (master-desktop `#drop`):
  'Drop to attach' on a base-200 card with a dashed outline. Shown and
  hidden by the DragDropUpload hook (counter-based, Files only), which owns
  its classes, hence `phx-update="ignore"`. Desktop only: `hidden` below lg
  whatever the hook does, and a phone has no drag.
  """
  def drop_target(assigns) do
    ~H"""
    <div id="chat-drop-target" phx-update="ignore" class="contents">
      <div
        data-role="drop-target"
        aria-hidden="true"
        class="pointer-events-none fixed z-40 hidden items-center justify-center bg-black/40 p-6"
      >
        <div class="rounded-box border-2 border-dashed border-edge bg-base-200 px-10 py-7 text-center">
          <p class="font-semibold text-base-content">Drop to attach</p>
          <p class="mt-1 text-[13px] text-subtle">lands in the composer, no panel</p>
        </div>
      </div>
    </div>
    """
  end

  attr(:pick, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)

  defp menu_row(assigns) do
    ~H"""
    <button
      type="button"
      data-attach-pick={@pick}
      class="mx-2 flex min-h-12 items-center gap-3 rounded-box px-2 text-left text-[15px] text-base-content active:bg-base-100 focus-visible-ring"
    >
      <.icon name={@icon} class="size-5 shrink-0 text-subtle" />
      <span>{@label}</span>
    </button>
    """
  end

  attr(:canvas, :map, required: true)

  defp canvas_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="attach_canvas"
      phx-value-id={@canvas.id}
      data-role="attach-canvas-row"
      class="mx-2 flex min-h-12 items-center gap-3 rounded-box px-2 text-left active:bg-base-100 focus-visible-ring"
    >
      <.icon name="hero-squares-2x2" class="size-5 shrink-0 text-subtle" />
      <span class="min-w-0 flex-1 truncate text-[15px] text-base-content">
        {canvas_title(@canvas)}
      </span>
      <span class="shrink-0 text-[13px] text-subtle">
        Edited {relative_time(@canvas.updated_at)}
      </span>
    </button>
    """
  end

  # Every picker the sheet and popover open, as hidden inputs the AttachSheet
  # hook clicks inside the tap (so iOS keeps the user gesture):
  # {kind, accept, capture, multiple}.
  defp pickers do
    [
      {"library", "image/*,video/*", nil, true},
      {"media", "image/*,video/*", nil, true},
      {"camera", "image/*", "environment", false},
      {"audio", "audio/*", "user", false},
      {"video", "video/*", "environment", false},
      {"file", nil, nil, true}
    ]
  end

  defp recent(canvases, n) do
    canvases
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.take(n)
  end

  defp canvas_title(canvas), do: canvas.title || CanvasHooks.humanize_kind(canvas)

  defp state(_entry, true), do: "failed"
  defp state(%{progress: p}, false) when p < 100, do: "uploading"
  defp state(_entry, false), do: "done"

  defp split_name(name) do
    case Path.extname(name || "") do
      "" -> {name || "", ""}
      ext -> {String.slice(name, 0, String.length(name) - String.length(ext)), ext}
    end
  end

  defp type_label(name, type) do
    case Path.extname(name || "") do
      "." <> ext when ext != "" ->
        String.upcase(ext)

      _ ->
        case String.split(type || "", "/") do
          [_, sub] when sub != "" -> String.upcase(sub)
          _ -> "FILE"
        end
    end
  end
end
