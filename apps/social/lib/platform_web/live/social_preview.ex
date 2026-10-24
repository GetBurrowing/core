defmodule PlatformWeb.SocialPreview do
  @moduledoc """
  True-to-life post previews, one per platform (task 01a16c4f, Social
  authoring 3/11): LinkedIn, an X thread, Instagram, YouTube Shorts and
  TikTok. Built once here so the needs-you queue, the composer and the idea
  detail can all drop in `<.preview>`.

  Each preview shows what the platform will actually render: the name and
  handle header, the body cut at the platform's fold with its own "…more"
  (which expands in place, client side), the media in the platform's frame
  ratio, and the platform's action row. The numbers come from
  `Platform.Social.PlatformLimits`, and so do the flags under the preview:
  plain-word chips, each with `data-flag=<key>`, never a score.

  ## Attributes

    * `platform` - `"linkedin" | "x" | "instagram" | "youtube" | "tiktok"`
    * `account` - a map (or `Platform.Social.Account`) with `handle`,
      `approval_mode`, `status`, and optionally `name`, `avatar_url`,
      `owner_name`, `platform_account_type`
    * `body`, `link_url`, `title` (YouTube's title)
    * `media` - a list of maps: `src` (a signed or `/files/blob/<id>` URL),
      `content_type`, and optionally `alt`, `width`, `height`, `poster`,
      `duration_s`, `byte_size`
    * `cover` - the cover image URL (from the post's `cover_file_id`), used
      as the video's poster
    * `viewer_owner?` - the viewer is the account's owner ("Posts as you")

  Styling uses the theme's semantic slots only. Inside a 9:16 video frame
  the chrome is white on black, as on the phone, whatever the page theme.
  """
  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Social.PlatformLimits

  @segment_re ~r/(https?:\/\/[^\s]+|(?<![\p{L}\p{N}_])#[\p{L}\p{N}_]+)/u

  attr :id, :string, default: nil
  attr :platform, :string, required: true
  attr :account, :map, required: true
  attr :body, :string, default: ""
  attr :media, :list, default: []
  attr :link_url, :string, default: nil
  attr :cover, :string, default: nil
  attr :title, :string, default: nil
  attr :viewer_owner?, :boolean, default: false
  attr :flags, :list, default: nil, doc: "overrides the computed flags"
  attr :class, :any, default: nil

  @doc "A post preview for `platform`, with its approval badge, owner line and flags."
  def preview(assigns) do
    assigns =
      assigns
      |> assign_new(:computed_id, fn -> assigns.id || default_id(assigns) end)
      |> assign(:body, assigns.body || "")
      |> assign(:label, PlatformLimits.label(assigns.platform))
      |> assign(:limits, PlatformLimits.get(assigns.platform) || %{})
      |> then(fn a ->
        assign(a, :flags, a.flags || PlatformLimits.flags(a.platform, flag_input(a)))
      end)

    ~H"""
    <section
      id={@computed_id}
      data-role="social-preview"
      data-platform={@platform}
      class={["w-full min-w-0 space-y-2", frame_width(@platform), @class]}
    >
      <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
        <span class="inline-flex items-center gap-1.5 font-semibold text-base-content">
          <.glyph platform={@platform} class="size-4" />
          {@label}
        </span>
        <span data-role="approval-mode" class="badge badge-ghost badge-sm font-medium">
          {approval_label(field(@account, :approval_mode))}
        </span>
        <span
          :if={@viewer_owner? or field(@account, :owner_name)}
          data-role="owner-line"
          class="text-base-content/70"
        >
          Posts as {if @viewer_owner?, do: "you", else: field(@account, :owner_name)}
        </span>
        <span
          :if={@limits[:max_body] && @platform != "x"}
          data-role="char-count"
          class="ml-auto font-mono text-xs text-base-content/70"
        >
          {number(PlatformLimits.count(@platform, @body))} / {number(@limits.max_body)}
        </span>
      </div>

      <.linkedin :if={@platform == "linkedin"} {frame_assigns(assigns)} />
      <.x_thread :if={@platform == "x"} {frame_assigns(assigns)} />
      <.instagram :if={@platform == "instagram"} {frame_assigns(assigns)} />
      <.youtube :if={@platform == "youtube"} {frame_assigns(assigns)} />
      <.tiktok :if={@platform == "tiktok"} {frame_assigns(assigns)} />

      <ul :if={@flags != []} data-role="preview-flags" class="flex flex-wrap gap-1.5">
        <li
          :for={flag <- @flags}
          data-flag={flag.key}
          class="inline-flex max-w-full items-center gap-1 rounded-full border border-warning bg-base-100 px-2 py-0.5 text-xs font-medium text-base-content"
        >
          <.icon name="hero-exclamation-triangle-mini" class="size-3.5 shrink-0 text-warning" />
          <span class="min-w-0 break-words">{flag.text}</span>
        </li>
      </ul>
    </section>
    """
  end

  # ── LinkedIn ─────────────────────────────────────────────────────────

  defp linkedin(assigns) do
    ~H"""
    <article
      data-preview-frame="linkedin"
      class="w-full max-w-[555px] overflow-hidden rounded-lg border border-edge bg-base-100 text-base-content"
    >
      <header class="flex items-start gap-2 px-4 pt-3">
        <.avatar account={@account} class="size-12 text-lg" />
        <div class="min-w-0 flex-1 leading-tight">
          <p class="truncate text-sm font-semibold">{display_name(@account)}</p>
          <p class="truncate text-xs text-base-content/70">{field(@account, :handle)}</p>
          <p class="flex items-center gap-1 text-xs text-base-content/70">
            Now · <.icon name="hero-globe-americas-mini" class="size-3" />
          </p>
        </div>
        <.icon name="hero-ellipsis-horizontal" class="size-5 shrink-0 text-base-content/70" />
      </header>

      <div class="px-4 pt-2 text-sm leading-5">
        <.folded id={@id} platform="linkedin" body={@body} clickable?={true} />
      </div>

      <.linkedin_media :if={@media != []} media={@media} cover={@cover} />

      <a
        :if={@media == [] and present?(@link_url)}
        data-role="link-card"
        href={@link_url}
        target="_blank"
        rel="noopener noreferrer nofollow"
        class="mt-3 block border-y border-edge bg-base-200"
      >
        <div class="flex aspect-[1.91/1] w-full items-center justify-center bg-base-300">
          <.icon name="hero-link" class="size-8 text-base-content/50" />
        </div>
        <div class="px-3 py-2">
          <p class="truncate text-sm font-semibold">{link_path(@link_url)}</p>
          <p class="truncate text-xs text-base-content/70">{link_host(@link_url)}</p>
        </div>
      </a>

      <div class="mx-3 mt-2 grid grid-cols-4 border-t border-edge py-1 text-xs font-semibold text-base-content/70">
        <span class="flex flex-col items-center justify-center gap-0.5 py-1.5 text-[11px] sm:flex-row sm:gap-1 sm:py-2 sm:text-xs">
          <.icon name="hero-hand-thumb-up" class="size-5" /><span>Like</span>
        </span>
        <span class="flex flex-col items-center justify-center gap-0.5 py-1.5 text-[11px] sm:flex-row sm:gap-1 sm:py-2 sm:text-xs">
          <.icon name="hero-chat-bubble-oval-left-ellipsis" class="size-5" /><span>Comment</span>
        </span>
        <span class="flex flex-col items-center justify-center gap-0.5 py-1.5 text-[11px] sm:flex-row sm:gap-1 sm:py-2 sm:text-xs">
          <.icon name="hero-arrow-path-rounded-square" class="size-5" /><span>Repost</span>
        </span>
        <span class="flex flex-col items-center justify-center gap-0.5 py-1.5 text-[11px] sm:flex-row sm:gap-1 sm:py-2 sm:text-xs">
          <.icon name="hero-paper-airplane" class="size-5" /><span>Send</span>
        </span>
      </div>
    </article>
    """
  end

  defp linkedin_media(assigns) do
    ~H"""
    <div data-role="preview-media" class="mt-3 w-full">
      <%= case @media do %>
        <% [one] -> %>
          <.media_el item={one} cover={@cover} class="block max-h-[640px] w-full object-cover" />
        <% many -> %>
          <div class="grid grid-cols-2 gap-0.5">
            <.media_el
              :for={m <- Enum.take(many, 4)}
              item={m}
              cover={@cover}
              class="block aspect-square w-full object-cover"
            />
          </div>
      <% end %>
    </div>
    """
  end

  # ── X ────────────────────────────────────────────────────────────────

  defp x_thread(assigns) do
    assigns = assign(assigns, :posts, PlatformLimits.thread(assigns.body))

    ~H"""
    <div
      data-preview-frame="x"
      class="w-full max-w-[598px] overflow-hidden rounded-2xl border border-edge bg-base-100 text-base-content"
    >
      <article
        :for={post <- @posts}
        data-role="x-post"
        data-index={post.index}
        class="flex gap-3 px-4 pt-3"
      >
        <div class="flex shrink-0 flex-col items-center">
          <.avatar account={@account} class="size-10" />
          <span :if={post.index < post.total} aria-hidden="true" class="mt-1 w-0.5 grow bg-edge">
          </span>
        </div>
        <div class="min-w-0 flex-1 pb-3">
          <header class="flex items-center gap-1 text-[15px] leading-5">
            <span class="max-w-[60%] shrink-0 truncate font-bold">{display_name(@account)}</span>
            <span class="min-w-0 truncate text-base-content/70">
              @{field(@account, :handle)} · now
            </span>
            <.icon
              name="hero-ellipsis-horizontal"
              class="ml-auto size-5 shrink-0 text-base-content/70"
            />
          </header>
          <p class="break-words text-[15px] leading-5">
            <.segments text={post.text} clickable?={true} />
          </p>
          <.x_media :if={post.index == 1 and @media != []} media={@media} cover={@cover} />
          <a
            :if={post.index == 1 and @media == [] and present?(@link_url)}
            data-role="link-card"
            href={@link_url}
            target="_blank"
            rel="noopener noreferrer nofollow"
            class="mt-3 block overflow-hidden rounded-2xl border border-edge"
          >
            <div class="relative flex aspect-[1.91/1] w-full items-center justify-center bg-base-300">
              <.icon name="hero-link" class="size-8 text-base-content/50" />
              <span class="absolute bottom-2 left-2 max-w-[90%] truncate rounded bg-base-100 px-1.5 text-xs">
                {link_host(@link_url)}
              </span>
            </div>
          </a>
          <div class="mt-3 flex max-w-[425px] items-center justify-between text-base-content/70">
            <.icon name="hero-chat-bubble-oval-left" class="size-[18px]" />
            <.icon name="hero-arrow-path-rounded-square" class="size-[18px]" />
            <.icon name="hero-heart" class="size-[18px]" />
            <.icon name="hero-chart-bar" class="size-[18px]" />
            <span class="flex items-center gap-3">
              <.icon name="hero-bookmark" class="size-[18px]" />
              <.icon name="hero-arrow-up-tray" class="size-[18px]" />
            </span>
          </div>
          <p
            data-role="x-post-count"
            class={[
              "mt-2 font-mono text-xs",
              if(post.count > post.limit,
                do: "font-semibold text-base-content",
                else: "text-base-content/70"
              )
            ]}
          >
            {if post.total > 1, do: "Post #{post.index} of #{post.total} · "}{post.count}/{post.limit}
          </p>
        </div>
      </article>
    </div>
    """
  end

  defp x_media(assigns) do
    ~H"""
    <div data-role="preview-media" class="mt-3 overflow-hidden rounded-2xl border border-edge">
      <%= case @media do %>
        <% [one] -> %>
          <.media_el item={one} cover={@cover} class="block aspect-video w-full object-cover" />
        <% many -> %>
          <div class="grid aspect-video grid-cols-2 gap-0.5">
            <.media_el
              :for={m <- Enum.take(many, 4)}
              item={m}
              cover={@cover}
              class="block h-full min-h-0 w-full object-cover"
            />
          </div>
      <% end %>
    </div>
    """
  end

  # ── Instagram ────────────────────────────────────────────────────────

  defp instagram(assigns) do
    first = List.first(assigns.media)
    reel? = first != nil and PlatformLimits.video?(first)
    assigns = assign(assigns, first: first, reel?: reel?)

    ~H"""
    <article
      data-preview-frame="instagram"
      class="w-full max-w-[470px] overflow-hidden rounded-lg border border-edge bg-base-100 text-base-content"
    >
      <header class="flex items-center gap-3 px-3 py-2.5">
        <.avatar account={@account} class="size-8 text-sm" />
        <span class="min-w-0 truncate text-sm font-semibold">{field(@account, :handle)}</span>
        <.icon name="hero-ellipsis-horizontal" class="ml-auto size-5 shrink-0" />
      </header>

      <div
        data-role="media-frame"
        data-ratio={if @reel?, do: "9:16", else: "4:5"}
        class={[
          "relative w-full overflow-hidden bg-base-300",
          if(@reel?, do: "aspect-[9/16]", else: "aspect-[4/5]")
        ]}
      >
        <.media_el
          :if={@first}
          item={@first}
          cover={@cover}
          class="absolute inset-0 size-full object-cover"
        />
        <div
          :if={!@first}
          class="absolute inset-0 flex flex-col items-center justify-center gap-2 text-base-content/70"
        >
          <.icon name="hero-photo" class="size-10" />
          <span class="text-sm">Instagram needs an image or video</span>
        </div>
        <span
          :if={length(@media) > 1}
          class="absolute right-3 top-3 rounded-full bg-base-100/90 px-2 py-0.5 text-xs font-semibold"
        >
          1/{length(@media)}
        </span>
        <.icon
          :if={@reel?}
          name="hero-film"
          class="absolute right-3 top-3 size-5 text-white drop-shadow"
        />
      </div>

      <div class="flex items-center gap-4 px-3 pt-2.5">
        <.icon name="hero-heart" class="size-6" />
        <.icon name="hero-chat-bubble-oval-left" class="size-6" />
        <.icon name="hero-paper-airplane" class="size-6" />
        <.icon name="hero-bookmark" class="ml-auto size-6" />
      </div>

      <div class="px-3 pb-3 pt-2 text-sm leading-[18px]">
        <.folded
          id={@id}
          platform="instagram"
          body={@body}
          clickable?={false}
          lead={field(@account, :handle)}
        />
        <p :if={present?(@link_url)} data-role="plain-link" class="mt-1 break-all">
          {@link_url}
        </p>
      </div>
    </article>
    """
  end

  # ── YouTube Shorts ───────────────────────────────────────────────────

  defp youtube(assigns) do
    assigns = assign(assigns, :video, Enum.find(assigns.media, &PlatformLimits.video?/1))

    ~H"""
    <article data-preview-frame="youtube" class="w-full max-w-[360px] text-base-content">
      <div
        data-role="media-frame"
        data-ratio="9:16"
        class="relative aspect-[9/16] w-full overflow-hidden rounded-xl bg-black text-white"
      >
        <.media_el
          :if={@video}
          item={@video}
          cover={@cover}
          class="absolute inset-0 size-full object-cover"
        />
        <.no_video :if={!@video} text="YouTube Shorts needs a video" />

        <span class="absolute left-3 top-3 flex items-center gap-1 text-sm font-semibold drop-shadow">
          <.glyph platform="youtube" class="size-5" /> Shorts
        </span>

        <div class="absolute bottom-24 right-2 flex flex-col items-center gap-4 text-xs font-medium drop-shadow">
          <.rail icon="hero-hand-thumb-up-solid" label="Like" />
          <.rail icon="hero-hand-thumb-down-solid" label="Dislike" />
          <.rail icon="hero-chat-bubble-oval-left-ellipsis-solid" label="0" />
          <.rail icon="hero-share-solid" label="Share" />
        </div>

        <div class="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/80 to-transparent p-3 pr-16 pt-10">
          <div class="flex items-center gap-2">
            <.avatar account={@account} class="size-8 text-sm" />
            <span class="min-w-0 truncate text-sm font-semibold">@{field(@account, :handle)}</span>
            <span class="shrink-0 rounded-full bg-white px-3 py-1 text-xs font-semibold text-black">
              Subscribe
            </span>
          </div>
          <p
            data-role="youtube-title"
            class={["mt-2 line-clamp-2 text-sm", !present?(@title) && "italic text-white/80"]}
          >
            {if present?(@title), do: @title, else: "No title yet"}
          </p>
        </div>
      </div>

      <div class="mt-3 rounded-xl bg-base-200 p-3 text-sm">
        <p class="font-semibold">{if present?(@title), do: @title, else: "No title yet"}</p>
        <div class="mt-1 leading-5">
          <.folded id={@id} platform="youtube" body={@body} clickable?={false} />
        </div>
      </div>
    </article>
    """
  end

  # ── TikTok ───────────────────────────────────────────────────────────

  defp tiktok(assigns) do
    assigns = assign(assigns, :first, List.first(assigns.media))

    ~H"""
    <article data-preview-frame="tiktok" class="w-full max-w-[360px]">
      <div
        data-role="media-frame"
        data-ratio="9:16"
        class="relative aspect-[9/16] w-full overflow-hidden rounded-xl bg-black text-white"
      >
        <.media_el
          :if={@first}
          item={@first}
          cover={@cover}
          class="absolute inset-0 size-full object-cover"
        />
        <.no_video :if={!@first} text="TikTok needs a video or images" />

        <div class="absolute inset-x-0 top-3 flex justify-center gap-4 text-sm font-semibold drop-shadow">
          <span class="text-white/80">Following</span>
          <span class="border-b-2 border-white pb-0.5">For You</span>
        </div>

        <div class="absolute bottom-20 right-2 flex flex-col items-center gap-4 text-xs font-semibold drop-shadow">
          <span class="relative mb-2">
            <.avatar account={@account} class="size-11 text-base ring-2 ring-white" />
            <span class="absolute -bottom-2 left-1/2 flex size-5 -translate-x-1/2 items-center justify-center rounded-full bg-white text-black">
              <.icon name="hero-plus-mini" class="size-3.5" />
            </span>
          </span>
          <.rail icon="hero-heart-solid" label="0" />
          <.rail icon="hero-chat-bubble-oval-left-ellipsis-solid" label="0" />
          <.rail icon="hero-bookmark-solid" label="0" />
          <.rail icon="hero-share-solid" label="Share" />
        </div>

        <div
          data-role="caption-overlay"
          class="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/80 to-transparent p-3 pr-16 pt-10 text-sm leading-5"
        >
          <p class="font-semibold">@{field(@account, :handle)}</p>
          <div class="mt-1">
            <.folded id={@id} platform="tiktok" body={@body} clickable?={false} on_media?={true} />
          </div>
          <p class="mt-2 flex items-center gap-1.5 text-xs">
            <.icon name="hero-musical-note-solid" class="size-3.5 shrink-0" />
            <span class="truncate">{"original sound - #{field(@account, :handle)}"}</span>
          </p>
        </div>
      </div>
    </article>
    """
  end

  # ── Shared pieces ────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :platform, :string, required: true
  attr :body, :string, required: true
  attr :clickable?, :boolean, required: true
  attr :lead, :string, default: nil
  attr :on_media?, :boolean, default: false

  # The body cut at the platform's fold. "…more" swaps the short text for
  # the full one in place, on the client (no server round trip).
  defp folded(assigns) do
    {visible, truncated?} = PlatformLimits.fold(assigns.platform, assigns.body)
    limits = PlatformLimits.get(assigns.platform)

    assigns =
      assign(assigns,
        visible: visible,
        truncated?: truncated?,
        fold_label: limits.fold_label,
        short_id: "#{assigns.id}-short",
        full_id: "#{assigns.id}-full"
      )

    ~H"""
    <p data-role="preview-body" class="break-words">
      <span :if={@lead} class="font-semibold">{@lead}</span>
      <span id={@short_id} data-role="fold-short">
        <.segments text={@visible} clickable?={@clickable?} on_media?={@on_media?} />
        <button
          :if={@truncated?}
          type="button"
          data-role="fold-more"
          phx-click={JS.hide(to: "##{@short_id}") |> JS.show(to: "##{@full_id}", display: "inline")}
          class={[
            "cursor-pointer whitespace-nowrap font-semibold hover:underline",
            if(@on_media?, do: "text-white", else: "text-base-content/70")
          ]}
        >
          {if String.starts_with?(@fold_label, "…"), do: @fold_label, else: "… " <> @fold_label}
        </button>
      </span>
      <span :if={@truncated?} id={@full_id} data-role="fold-full" class="hidden">
        <.segments text={@body} clickable?={@clickable?} on_media?={@on_media?} />
      </span>
    </p>
    """
  end

  attr :text, :string, required: true
  attr :clickable?, :boolean, required: true
  attr :on_media?, :boolean, default: false

  # Plain text with URLs and hashtags picked out. On a platform that does not
  # make links clickable, a URL stays plain text (`data-role="plain-link"`).
  defp segments(assigns) do
    assigns = assign(assigns, :parts, segment(assigns.text))

    ~H"""
    <span class="whitespace-pre-line" phx-no-format><%= for {kind, text} <- @parts do %><%= case kind do %><% :url when @clickable? -> %><a href={text} target="_blank" rel="noopener noreferrer nofollow" class="break-all font-semibold text-info hover:underline">{text}</a><% :url -> %><span data-role="plain-link" class="break-all">{text}</span><% :tag -> %><span class={["font-semibold", !@on_media? && "text-info"]}>{text}</span><% :text -> %>{text}<% end %><% end %></span>
    """
  end

  attr :item, :map, required: true
  attr :cover, :string, default: nil
  attr :class, :any, default: nil

  defp media_el(assigns) do
    assigns =
      assign(assigns,
        video?: PlatformLimits.video?(assigns.item),
        alt: field(assigns.item, :alt) || "",
        poster: field(assigns.item, :poster) || assigns.cover
      )

    ~H"""
    <video
      :if={@video?}
      src={field(@item, :src)}
      poster={@poster}
      aria-label={@alt}
      muted
      playsinline
      preload="metadata"
      class={["max-w-full bg-black", @class]}
    >
    </video>
    <img :if={!@video?} src={field(@item, :src)} alt={@alt} class={["max-w-full", @class]} />
    """
  end

  attr :text, :string, required: true

  defp no_video(assigns) do
    ~H"""
    <div class="absolute inset-0 flex flex-col items-center justify-center gap-2 text-white/80">
      <.icon name="hero-film" class="size-10" />
      <span class="text-sm">{@text}</span>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp rail(assigns) do
    ~H"""
    <span class="flex flex-col items-center gap-1">
      <span class="flex size-11 items-center justify-center rounded-full bg-white/15">
        <.icon name={@icon} class="size-6" />
      </span>
      {@label}
    </span>
    """
  end

  attr :account, :map, required: true
  attr :class, :any, default: nil

  defp avatar(assigns) do
    assigns = assign(assigns, :url, field(assigns.account, :avatar_url))

    ~H"""
    <img
      :if={present?(@url)}
      src={@url}
      alt=""
      class={["shrink-0 rounded-full object-cover", @class]}
    />
    <span
      :if={!present?(@url)}
      aria-hidden="true"
      class={[
        "flex shrink-0 items-center justify-center rounded-full bg-base-300 font-semibold text-base-content",
        @class
      ]}
    >
      {initial(@account)}
    </span>
    """
  end

  attr :platform, :string, required: true
  attr :class, :any, default: "size-4"

  @doc "A small monochrome platform mark in `currentColor`."
  def glyph(%{platform: "x"} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" aria-hidden="true" class={@class} fill="currentColor">
      <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
    </svg>
    """
  end

  def glyph(%{platform: "linkedin"} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" aria-hidden="true" class={@class} fill="currentColor">
      <path d="M20.45 20.45h-3.56v-5.57c0-1.33-.02-3.04-1.85-3.04-1.85 0-2.14 1.45-2.14 2.94v5.67H9.35V9h3.41v1.56h.05c.48-.9 1.64-1.85 3.37-1.85 3.6 0 4.27 2.37 4.27 5.46v6.28zM5.34 7.43a2.06 2.06 0 1 1 0-4.13 2.06 2.06 0 0 1 0 4.13zM7.12 20.45H3.56V9h3.56v11.45z" />
    </svg>
    """
  end

  def glyph(%{platform: "instagram"} = assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      aria-hidden="true"
      class={@class}
      fill="none"
      stroke="currentColor"
      stroke-width="2"
    >
      <rect x="3" y="3" width="18" height="18" rx="5" />
      <circle cx="12" cy="12" r="4" />
      <circle cx="17.5" cy="6.5" r="1" fill="currentColor" stroke="none" />
    </svg>
    """
  end

  def glyph(%{platform: "youtube"} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" aria-hidden="true" class={@class} fill="currentColor">
      <path d="M23.5 6.2a3 3 0 0 0-2.1-2.1C19.5 3.6 12 3.6 12 3.6s-7.5 0-9.4.5A3 3 0 0 0 .5 6.2 31 31 0 0 0 0 12a31 31 0 0 0 .5 5.8 3 3 0 0 0 2.1 2.1c1.9.5 9.4.5 9.4.5s7.5 0 9.4-.5a3 3 0 0 0 2.1-2.1A31 31 0 0 0 24 12a31 31 0 0 0-.5-5.8zM9.6 15.6V8.4l6.3 3.6-6.3 3.6z" />
    </svg>
    """
  end

  def glyph(%{platform: "tiktok"} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" aria-hidden="true" class={@class} fill="currentColor">
      <path d="M16.6 5.82A4.28 4.28 0 0 1 15.54 3h-3.09v12.4a2.59 2.59 0 0 1-2.59 2.5 2.6 2.6 0 0 1-2.6-2.6 2.6 2.6 0 0 1 3.37-2.48V9.66a5.73 5.73 0 0 0-.77-.05A5.69 5.69 0 0 0 4.17 15.3 5.69 5.69 0 0 0 9.86 21a5.69 5.69 0 0 0 5.68-5.69V9.01a7.33 7.33 0 0 0 4.3 1.38V7.3a4.3 4.3 0 0 1-3.24-1.48z" />
    </svg>
    """
  end

  def glyph(assigns) do
    ~H"""
    <.icon name="hero-globe-alt" class={@class} />
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp frame_assigns(assigns) do
    Map.take(assigns, [:account, :body, :media, :link_url, :cover, :title])
    |> Map.put(:id, assigns.computed_id)
  end

  defp flag_input(a) do
    %{
      body: a.body,
      title: a.title,
      link_url: a.link_url,
      media: a.media,
      account: a.account
    }
  end

  defp default_id(assigns) do
    hash = :erlang.phash2({field(assigns.account, :handle), assigns.body, assigns.media})
    "social-preview-#{assigns.platform}-#{hash}"
  end

  @doc false
  def segment(nil), do: []

  def segment(text) do
    @segment_re
    |> Regex.split(text, include_captures: true)
    |> Enum.with_index()
    |> Enum.reject(fn {part, _} -> part == "" end)
    |> Enum.map(fn
      {"#" <> _ = tag, i} when rem(i, 2) == 1 -> {:tag, tag}
      {url, i} when rem(i, 2) == 1 -> {:url, url}
      {plain, _} -> {:text, plain}
    end)
  end

  defp frame_width("linkedin"), do: "max-w-[555px]"
  defp frame_width("x"), do: "max-w-[598px]"
  defp frame_width("instagram"), do: "max-w-[470px]"
  defp frame_width(_short_video), do: "max-w-[360px]"

  defp number(n) when is_integer(n) and n >= 1000,
    do: "#{div(n, 1000)},#{n |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0")}"

  defp number(n), do: to_string(n)

  defp approval_label("draft_only"), do: "Draft only"
  defp approval_label(_), do: "Approve first"

  defp display_name(account), do: field(account, :name) || field(account, :handle) || "Account"

  defp initial(account) do
    account
    |> display_name()
    |> String.trim_leading("@")
    |> String.first()
    |> Kernel.||("?")
    |> String.upcase()
  end

  defp link_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "www.", "")
      _ -> url
    end
  end

  defp link_path(url) do
    case URI.parse(url) do
      %URI{host: host, path: path}
      when is_binary(host) and is_binary(path) and path not in ["", "/"] ->
        path
        |> String.trim("/")
        |> String.split("/")
        |> List.last()
        |> String.replace(["-", "_"], " ")

      _ ->
        link_host(url)
    end
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  defp field(nil, _key), do: nil

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
