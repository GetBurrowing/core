defmodule PlatformWeb.Components.ChatClipPlayer do
  @moduledoc """
  The one inline video player in chat: attachments, linked attachments and
  video URLs in message text all render through `clip_player/1`, so they
  match (redesign rung 13 stage 1, extracted from the task 01a120be / 01a1655c
  attachment player in `PlatformWeb.Components.ChatMessage`).

  Plays in place with no autoplay; `preload="metadata"` fetches only the
  header, and Play/seek ride Range requests. Poster frame = the attachment's
  metadata `poster_url`, else a `#t=0.1` media fragment so iOS Safari paints
  the first frame. The box keeps the clip's own aspect ratio (stored dims,
  else the natural ratio once metadata loads, 16:9 reserved before that) and
  is capped at 60vh so a vertical clip is not cropped.

  No border; a base-300 frame clipped to --radius-box, 480px wide from sm up
  and full bubble width on a phone. The ChatClip hook resets the frame to the
  clip's own videoWidth/videoHeight on loadedmetadata, fills the duration when
  none is stored, and on error swaps the frame for the "Can't play this video"
  card. `phx-update="ignore"` keeps what the hook did across re-renders.
  """

  use Phoenix.Component

  import PlatformWeb.Components.ChatHelpers

  attr(:id, :string, required: true)
  attr(:src, :string, required: true)
  attr(:download_url, :string, required: true)
  attr(:filename, :string, required: true)
  attr(:poster, :string, default: nil)
  attr(:byte_size, :integer, default: nil)
  attr(:duration, :string, default: nil)
  attr(:aspect_style, :string, default: nil)
  attr(:role, :string, default: "video-attachment")

  def clip_player(assigns) do
    assigns = assign(assigns, :name_parts, clip_name_parts(assigns.filename))

    ~H"""
    <div
      id={@id}
      phx-hook="ChatClip"
      phx-update="ignore"
      data-role={@role}
      class="w-full sm:max-w-[480px]"
    >
      <div
        data-role="clip-frame"
        class="aspect-video max-h-[60vh] w-full overflow-hidden rounded-box bg-base-300"
        style={@aspect_style}
      >
        <video
          controls
          preload="metadata"
          playsinline
          src={@src}
          poster={@poster}
          class="block size-full"
        >
        </video>
      </div>
      <div
        data-role="clip-fallback"
        class="hidden items-center gap-2 rounded-box bg-base-200 px-3 py-4 text-sm"
      >
        <span class="hero-exclamation-triangle size-4 shrink-0 text-error"></span>
        <span class="flex-1">Can't play this video</span>
        <a href={@download_url} download={@filename} class="btn btn-ghost btn-xs shrink-0">
          Download
        </a>
      </div>
      <div
        data-role="clip-file-line"
        class="mt-1 flex min-w-0 items-center gap-1 text-[13px] text-subtle"
        title={@filename}
      >
        <span class="flex min-w-0">
          <span class="truncate">{elem(@name_parts, 0)}</span><span class="shrink-0">{elem(
            @name_parts,
            1
          )}</span>
        </span>
        <span :if={@byte_size} class="shrink-0 tabular-nums text-subtle">
          · {Platform.Chat.UploadLimits.format_bytes(@byte_size)}
        </span>
        <span
          data-role="clip-duration"
          class={["shrink-0 tabular-nums", is_nil(@duration) && "hidden"]}
        >
          {@duration && "· #{@duration}"}
        </span>
        <%!-- Task 01a1655c stage 5: main's download affordance; iOS
             Safari's native controls have none. --%>
        <span class="shrink-0" aria-hidden="true">·</span>
        <a
          data-role="clip-download"
          href={@download_url}
          download={@filename}
          class="shrink-0 text-subtle hover:underline"
        >
          Download
        </a>
      </div>
    </div>
    """
  end
end
