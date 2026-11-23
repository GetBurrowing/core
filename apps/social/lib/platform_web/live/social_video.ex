defmodule PlatformWeb.SocialVideo do
  @moduledoc "An explicit, demand-loaded player for Social post media. File URLs keep their existing authorization."
  use Phoenix.Component

  attr :id, :string, required: true
  attr :src, :string, required: true
  attr :poster, :string, default: nil
  attr :alt, :string, default: "Video preview"
  attr :muted, :boolean, default: false
  attr :class, :any, default: nil
  attr :video_class, :any, default: "block size-full max-w-full object-cover"

  def player(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="SocialVideo"
      phx-update="ignore"
      data-src={@src}
      data-poster={@poster}
      data-role="social-video"
      class={["relative", @class]}
    >
      <video
        controls
        playsinline
        preload="none"
        poster={@poster}
        muted={@muted}
        aria-label={@alt}
        class={@video_class}
      >
      </video>
      <div class="pointer-events-none absolute inset-0 z-20 flex items-center justify-center">
        <button
          type="button"
          data-role="video-play"
          class="pointer-events-auto min-h-11 min-w-11 rounded-lg bg-black/80 px-4 py-3 font-semibold text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
        >
          Play video
        </button>
      </div>
      <p
        data-role="video-status"
        role="status"
        aria-live="polite"
        hidden
        class="pointer-events-none absolute inset-x-2 top-2 z-20 rounded bg-black/80 p-2 text-sm text-white"
      >
      </p>
      <noscript><a href={@src} target="_blank" rel="noopener noreferrer">Open video</a></noscript>
    </div>
    """
  end
end
