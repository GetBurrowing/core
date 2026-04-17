defmodule PlatformWeb.ChatLive.Partials do
  @moduledoc """
  Function components for self-contained render regions of ChatLive.

  See ADR 0035. These aren't LiveComponents (no state), they're just
  render splits — each takes a small set of attrs and produces markup.
  They keep `chat_live.html.heex` at a tractable size.

  Extracted here:
    * `notification_banner/1` — notification opt-in bar
    * `upload_dialog/1` — staging modal for attachments
    * `canvas_overlay/1` — active-canvas side panel + mobile full-screen
    * `meeting_panel/1` — in-meeting UI (desktop sidebar + mobile overlay)
    * `image_lightbox/1` — full-screen image viewer
  """

  use Phoenix.Component

  import PlatformWeb.Chat.CanvasRenderer, only: [canvas_document: 1]

  alias PlatformWeb.ChatLive.CanvasHooks

  @doc "Notification opt-in banner (when push permission is 'prompt')."
  attr :push_permission, :string, required: true

  def notification_banner(assigns) do
    ~H"""
    <div
      :if={@push_permission == "prompt"}
      class="flex items-center justify-between gap-3 border-b border-info/20 bg-info/10 px-4 py-2"
    >
      <p class="text-sm text-info">
        <span class="hero-bell-alert mr-1 inline-block h-4 w-4 align-text-bottom" />
        Enable notifications to get alerts when agents respond or you're mentioned.
      </p>
      <button
        type="button"
        phx-click="enable_notifications"
        class="btn btn-info btn-sm flex-shrink-0"
      >
        Enable
      </button>
    </div>
    """
  end

  @doc "Upload staging dialog — drop zone, thumb grid, agent tag chips, caption, send."
  attr :open, :boolean, required: true
  attr :active_space, :any, default: nil
  attr :uploads, :any, required: true
  attr :caption, :string, default: ""
  attr :tagged_agents, :any, required: true

  def upload_dialog(assigns) do
    ~H"""
    <div :if={@open} class="upload-backdrop" phx-click="upload_dialog_close">
      <div class="upload-panel" phx-click="noop">
        <div class="upload-header">
          <div class="upload-header-icon">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="3" y="3" width="18" height="18" rx="2" /><circle cx="8.5" cy="8.5" r="1.5" /><path d="M21 15l-5-5L5 21" />
            </svg>
          </div>
          <div class="upload-header-text">
            <div class="upload-title">Share Images</div>
            <div class="upload-subtitle">
              Upload images to <strong>{"##{(@active_space && @active_space.name) || ""}"}</strong>
            </div>
          </div>
          <button type="button" class="upload-close" phx-click="upload_dialog_close">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        </div>

        <div
          :if={@uploads.attachments.entries == []}
          class="upload-dropzone"
          phx-click={Phoenix.LiveView.JS.dispatch("click", to: "#upload-file-trigger")}
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
            <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4" /><polyline points="17 8 12 3 7 8" /><line
              x1="12"
              y1="3"
              x2="12"
              y2="15"
            />
          </svg>
          <div class="upload-dropzone-title">Drag & drop images here</div>
          <div class="upload-dropzone-or">or</div>
          <button
            type="button"
            class="upload-browse-btn"
            phx-click={Phoenix.LiveView.JS.dispatch("click", to: "#upload-file-trigger")}
          >
            Browse files
          </button>
          <div class="upload-dropzone-sub">You can also paste images with ⌘V</div>
          <div class="upload-dropzone-formats">
            PNG · JPG · GIF · WebP · SVG — max 15 MB each
          </div>
        </div>

        <div :if={@uploads.attachments.entries != []} class="upload-grid-area">
          <div class="upload-grid">
            <div :for={entry <- @uploads.attachments.entries} class="upload-thumb">
              <%= if String.starts_with?(entry.client_type, "image/") do %>
                <.live_img_preview
                  entry={entry}
                  class="upload-thumb-inner"
                  style="width:100%;height:100%;object-fit:cover"
                />
              <% else %>
                <div class="upload-thumb-inner">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                    <rect x="3" y="3" width="18" height="18" rx="2" /><circle
                      cx="8.5"
                      cy="8.5"
                      r="1.5"
                    /><path d="M21 15l-5-5L5 21" />
                  </svg>
                </div>
              <% end %>
              <span class="upload-thumb-name">{entry.client_name}</span>
              <button
                type="button"
                class="upload-thumb-remove"
                phx-click="upload_entry_cancel"
                phx-value-ref={entry.ref}
              >
                ×
              </button>
              <div
                :if={entry.progress > 0 and entry.progress < 100}
                style="position:absolute;bottom:0;left:0;right:0;height:3px;background:rgba(0,0,0,0.3)"
              >
                <div style={"height:100%;background:var(--cyan);width:#{entry.progress}%;transition:width 300ms ease"}>
                </div>
              </div>
            </div>
            <button
              type="button"
              class="upload-add-tile"
              phx-click={Phoenix.LiveView.JS.dispatch("click", to: "#upload-file-trigger")}
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
              </svg>
              Add more
            </button>
          </div>
        </div>

        <div :if={upload_errors(@uploads.attachments) != []} style="padding:0 20px">
          <p
            :for={error <- upload_errors(@uploads.attachments)}
            class="text-xs"
            style="color:var(--danger);margin-bottom:4px"
          >
            {upload_error_to_string(error)}
          </p>
        </div>
        <div :for={entry <- @uploads.attachments.entries} style="padding:0 20px">
          <p
            :for={error <- upload_errors(@uploads.attachments, entry)}
            class="text-xs"
            style="color:var(--danger);margin-bottom:4px"
          >
            {entry.client_name}: {upload_error_to_string(error)}
          </p>
        </div>

        <div :if={@uploads.attachments.entries != []} class="upload-agent-section">
          <div class="upload-agent-label">Tag an agent</div>
          <div class="upload-agent-chips">
            <button
              :for={
                {slug, label} <- [
                  {"beacon", "Beacon"},
                  {"pixel", "Pixel"},
                  {"builder", "Builder"},
                  {"higgins", "Higgins"}
                ]
              }
              type="button"
              class={"agent-chip #{slug}#{if MapSet.member?(@tagged_agents, slug), do: " selected", else: ""}"}
              phx-click="upload_toggle_agent"
              phx-value-agent={slug}
            >
              <span class="chip-dot"></span> {label}
            </button>
          </div>
        </div>

        <div :if={@uploads.attachments.entries != []} class="upload-comment">
          <form phx-change="upload_caption_change" phx-submit="upload_send">
            <textarea
              name="caption"
              class="upload-comment-input"
              placeholder="Add a comment about these images..."
              phx-debounce="200"
            >{@caption}</textarea>
          </form>
        </div>

        <div :if={@uploads.attachments.entries != []} class="upload-footer">
          <div class="upload-count">
            <strong>{length(@uploads.attachments.entries)}</strong>
            {if length(@uploads.attachments.entries) == 1, do: "image", else: "images"} selected
          </div>
          <div class="upload-footer-actions">
            <button type="button" class="upload-btn-cancel" phx-click="upload_dialog_close">
              Cancel
            </button>
            <button
              type="button"
              class="upload-btn-send"
              phx-click="upload_send"
              disabled={@uploads.attachments.entries == []}
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                <line x1="22" y1="2" x2="11" y2="13" /><polygon points="22 2 15 22 11 13 2 9 22 2" />
              </svg>
              Send to {"##{(@active_space && @active_space.name) || ""}"}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc "Active-canvas side panel (desktop) and full-screen overlay (mobile)."
  attr :canvas, :any, default: nil

  def canvas_overlay(assigns) do
    ~H"""
    <div
      :if={@canvas}
      class="hidden lg:flex w-96 flex-shrink-0 flex-col border-l border-base-300 bg-base-100"
    >
      <div class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4">
        <div class="min-w-0">
          <p class="text-sm font-semibold">Live Canvas</p>
          <p class="truncate text-xs text-base-content/50">
            {@canvas.title || CanvasHooks.humanize_type(@canvas.canvas_type)}
          </p>
        </div>
        <button phx-click="canvas_close" class="btn btn-ghost btn-xs" title="Close canvas">
          <span class="hero-x-mark size-4"></span>
        </button>
      </div>
      <div class="flex-1 overflow-y-auto px-4 py-4">
        <.canvas_document canvas={@canvas} dom_id_base="chat-live-canvas-panel" />
      </div>
    </div>

    <div :if={@canvas} class="fixed inset-0 z-50 flex flex-col bg-base-100 lg:hidden">
      <header class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4 safe-area-top">
        <div class="min-w-0">
          <p class="text-sm font-semibold">Live Canvas</p>
          <p class="truncate text-xs text-base-content/50">
            {@canvas.title || CanvasHooks.humanize_type(@canvas.canvas_type)}
          </p>
        </div>
        <button phx-click="canvas_close" class="btn btn-ghost btn-xs" title="Close canvas">
          <span class="hero-x-mark size-4"></span>
        </button>
      </header>
      <div class="flex-1 overflow-y-auto px-4 py-4">
        <.canvas_document canvas={@canvas} dom_id_base="chat-live-canvas-overlay" />
      </div>
    </div>
    """
  end

  @doc "In-meeting UI — desktop side panel + mobile full-screen overlay."
  attr :in_meeting, :boolean, required: true
  attr :active_space, :any, default: nil
  attr :mic_enabled, :boolean, required: true
  attr :camera_enabled, :boolean, required: true
  attr :screen_share_enabled, :boolean, required: true

  def meeting_panel(assigns) do
    ~H"""
    <div
      :if={@in_meeting}
      id="meeting-panel"
      class="hidden lg:flex w-96 flex-shrink-0 flex-col border-l border-base-300 bg-base-100"
    >
      <div class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4">
        <div class="flex items-center gap-2 min-w-0">
          <span class="bg-success rounded-full w-2 h-2 animate-pulse flex-shrink-0"></span>
          <p class="text-sm font-semibold truncate">
            {(@active_space && @active_space.name) || "Meeting"}
          </p>
          <span id="meeting-duration" class="text-xs text-base-content/50 tabular-nums">0:00</span>
        </div>
        <button
          phx-click="meeting_leave"
          class="btn btn-ghost btn-xs text-error"
          title="Leave meeting"
        >
          <span class="hero-x-mark size-4"></span>
        </button>
      </div>

      <div class="flex-1 overflow-y-auto p-3">
        <%!-- JS owns the children (meeting_client.js injects tiles); ignore on re-render --%>
        <div
          id="meeting-participants"
          phx-update="ignore"
          class="meeting-participant-grid gap-2"
        >
        </div>
        <div
          id="meeting-captions"
          phx-hook="MeetingCaptions"
          class="mt-2 rounded-lg bg-base-300/80 px-3 py-2 text-sm opacity-0 pointer-events-none transition-opacity duration-300"
        >
        </div>
      </div>

      <div class="flex items-center justify-center gap-2 border-t border-base-300 px-4 py-3">
        <button
          phx-click="meeting_toggle_mic"
          class={[
            "meeting-control-btn rounded-full p-2.5 transition-colors",
            if(@mic_enabled,
              do: "bg-base-200 hover:bg-base-300 text-base-content",
              else: "bg-error/20 text-error hover:bg-error/30"
            )
          ]}
          title={if @mic_enabled, do: "Mute microphone", else: "Unmute microphone"}
        >
          <span class={[
            "size-5",
            if(@mic_enabled, do: "hero-microphone", else: "hero-microphone-slash")
          ]}>
          </span>
        </button>
        <button
          phx-click="meeting_toggle_camera"
          class={[
            "meeting-control-btn rounded-full p-2.5 transition-colors",
            if(@camera_enabled,
              do: "bg-base-200 hover:bg-base-300 text-base-content",
              else: "bg-error/20 text-error hover:bg-error/30"
            )
          ]}
          title={if @camera_enabled, do: "Turn off camera", else: "Turn on camera"}
        >
          <span class={[
            "size-5",
            if(@camera_enabled, do: "hero-video-camera", else: "hero-video-camera-slash")
          ]}>
          </span>
        </button>
        <button
          phx-click="meeting_toggle_screen_share"
          class={[
            "meeting-control-btn rounded-full p-2.5 transition-colors",
            if(@screen_share_enabled,
              do: "bg-primary/20 text-primary hover:bg-primary/30",
              else: "bg-base-200 hover:bg-base-300 text-base-content"
            )
          ]}
          title={if @screen_share_enabled, do: "Stop sharing screen", else: "Share screen"}
        >
          <span class="hero-computer-desktop size-5"></span>
        </button>
        <button
          phx-click="meeting_leave"
          class="meeting-control-btn rounded-full p-2.5 bg-error text-error-content hover:bg-error/80 transition-colors"
          title="Leave meeting"
        >
          <span class="hero-phone-x-mark size-5"></span>
        </button>
      </div>

      <%!-- JS owns the children (track.attach outputs); ignore on re-render
           so toggling mic/camera doesn't wipe the <audio> elements. --%>
      <div id="meeting-media" class="hidden" phx-update="ignore"></div>
    </div>

    <div
      :if={@in_meeting}
      class="fixed inset-0 z-50 flex flex-col bg-base-100 lg:hidden"
    >
      <header class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4 safe-area-top">
        <div class="flex items-center gap-2 min-w-0">
          <span class="bg-success rounded-full w-2 h-2 animate-pulse flex-shrink-0"></span>
          <p class="text-sm font-semibold truncate">
            {(@active_space && @active_space.name) || "Meeting"}
          </p>
          <span id="meeting-duration-mobile" class="text-xs text-base-content/50 tabular-nums">
            0:00
          </span>
        </div>
        <button phx-click="meeting_leave" class="btn btn-ghost btn-xs" title="Back to chat">
          <span class="hero-arrow-left size-4"></span>
          <span class="text-xs">Chat</span>
        </button>
      </header>

      <div class="flex-1 overflow-y-auto p-4">
        <%!-- JS owns the children (meeting_client.js injects tiles); ignore on re-render --%>
        <div
          id="meeting-participants-mobile"
          phx-update="ignore"
          class="meeting-participant-grid gap-2"
        >
        </div>
        <div
          id="meeting-captions-mobile"
          phx-hook="MeetingCaptions"
          class="mt-2 rounded-lg bg-base-300/80 px-3 py-2 text-sm opacity-0 pointer-events-none transition-opacity duration-300"
        >
        </div>
      </div>

      <div class="flex items-center justify-center gap-3 border-t border-base-300 px-4 py-4 safe-area-bottom">
        <button
          phx-click="meeting_toggle_mic"
          class={[
            "meeting-control-btn rounded-full p-3 transition-colors",
            if(@mic_enabled,
              do: "bg-base-200 text-base-content",
              else: "bg-error/20 text-error"
            )
          ]}
        >
          <span class={[
            "size-6",
            if(@mic_enabled, do: "hero-microphone", else: "hero-microphone-slash")
          ]}>
          </span>
        </button>
        <button
          phx-click="meeting_toggle_camera"
          class={[
            "meeting-control-btn rounded-full p-3 transition-colors",
            if(@camera_enabled,
              do: "bg-base-200 text-base-content",
              else: "bg-error/20 text-error"
            )
          ]}
        >
          <span class={[
            "size-6",
            if(@camera_enabled, do: "hero-video-camera", else: "hero-video-camera-slash")
          ]}>
          </span>
        </button>
        <button
          phx-click="meeting_toggle_screen_share"
          class={[
            "meeting-control-btn rounded-full p-3 transition-colors",
            if(@screen_share_enabled,
              do: "bg-primary/20 text-primary",
              else: "bg-base-200 text-base-content"
            )
          ]}
        >
          <span class="hero-computer-desktop size-6"></span>
        </button>
        <button
          phx-click="meeting_leave"
          class="meeting-control-btn rounded-full p-3 bg-error text-error-content hover:bg-error/80 transition-colors"
        >
          <span class="hero-phone-x-mark size-6"></span>
        </button>
      </div>
    </div>
    """
  end

  @doc "Full-screen image lightbox (click to dismiss)."
  attr :url, :string, default: nil

  def image_lightbox(assigns) do
    ~H"""
    <div
      :if={@url}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-sm"
      phx-click="close_lightbox"
    >
      <button
        class="absolute top-4 right-4 z-10 rounded-full bg-black/50 p-2 text-white hover:bg-black/70 transition-colors safe-area-top"
        phx-click="close_lightbox"
        aria-label="Close"
      >
        <span class="hero-x-mark size-6"></span>
      </button>
      <img
        src={@url}
        class="max-h-[90vh] max-w-[95vw] rounded-lg object-contain shadow-2xl"
        phx-click="close_lightbox"
      />
    </div>
    """
  end

  @doc "Format an upload error atom for display (shared by the dialog and inline compose errors)."
  def upload_error_to_string(:too_large), do: "File is too large"
  def upload_error_to_string(:too_many_files), do: "Too many files selected"
  def upload_error_to_string(:not_accepted), do: "File type is not accepted"
  def upload_error_to_string(error), do: inspect(error)
end
