defmodule PlatformWeb.Components.ChatLinkCard do
  @moduledoc """
  The chat card family (redesign rung 13 stage 1; direction canvas 01a16748
  "CARD FAMILY"): one anatomy for canvas, prototype, link and locked cards,
  plus inline images and video for media URLs.

  Anatomy (link unfurls stage 1, direction canvas 01a1a945): a `base-100`
  card on the `base-100` pane, told apart by its `border-edge` border, not
  its fill (the repo's border token; base-300 is a fill, see
  border_token_direction_test.exs), `rounded-box`, a 12px inset and gap
  (`p-3 gap-3`) to match the message row; a tile at the left; a 15px
  semibold title of at most two lines; ONE 13px subtle description line.
  No card carries a shadow or an accent bar; `primary` appears only on
  hover (desktop, the outside-link card) and in the focus ring.

  Text roles: the direction canvas calls the site name, description and
  author `neutral`. That maps to `text-subtle`, the repo's measured
  secondary-text token, NOT to `text-neutral`: in the dark theme
  `--color-neutral` is a dark grey (app.css), which is dark on dark there. Every card and chip scales down
  on press (none under reduced motion). Images and video render inline as
  media, not as cards; video uses the shared
  `PlatformWeb.Components.ChatClipPlayer`.

  Link previews stage 1 (mockup canvas 01a16ed5, options 2, 3, 8 and 9):

    * An outside link's tile is its site mark or a host monogram
      (`PlatformWeb.Components.LinkSiteGlyphs`), its title the smart title
      `Platform.Chat.LinkSites` parsed from the URL. Never the globe.
    * An outside link inside the sender's prose is a one-line chip in the
      text (`chips/2`, swapped in by `ContentRenderer`), not a card.
    * A canvas or prototype card leads with its cover (the canvas's first
      readable image) or a type-coloured tile, then the type line ("Canvas ·
      #space", "Mockup", "Prototype · v3"), the title, and the hint ("6
      options · tap to open"), with a border in the type colour, no shadow.
      Same anatomy as every other card in the family.

  Rich unfurls (task 01a1a944 stage 4, direction canvas 01a1a945): a
  `:link` card carrying `:unfurl` (a stored `ok` preview, see
  `Platform.Chat.LinkUnfurls`) shows what the reader will get. A WIDE image
  (a video, an image at least 1.5:1, or one of unknown size on a page that
  declared `twitter:card` `summary_large_image`) leads the card at full
  width, at most 180px tall and cropped; under it sit the 16px site mark,
  the host without `www.` (and the author, a video's channel, when there is
  one), the title and one line of description. A square or small image
  becomes the 40px tile in today's anatomy instead, and so does every X
  post and GitHub page whatever its image (stage 5): X shows its image
  square-cropped, GitHub its site mark. A duration chip appears
  only when the provider stated one. Without `:unfurl` (pending, failed,
  refused, no metadata) the card is today's URL-derived card, unchanged:
  no skeleton, so the swap when the preview lands is calm. `data-unfurled`
  says which. The author (`own?`) gets a 24px "Remove preview" control,
  outside the card's button: shown on hover or focus on desktop, always
  below `lg` (touch); it pushes `link_unfurl_hide`, and the server
  (`Platform.Chat.hide_link_unfurls/2`) decides. Nobody else gets it in
  the DOM at all.

  Cards come from `Platform.Chat.LinkCards` (already access-checked for the
  viewer). A locked card renders only its type and "You don't have access":
  no title, space, version, thumbnail or URL. Nothing here fetches; an image
  `src` is the URL the sender posted, loaded lazily with no referrer.

  Opening: a canvas card pushes `link_card_open_canvas` (in-chat full-screen
  canvas for the open space, else its canonical page, same tab). Prototype,
  link, image and video cards and file attachments push `viewer_open`
  (`PlatformWeb.ChatLive.ViewerHooks`) with the message id and the card
  index or attachment id; the server resolves the item. Nothing opens a new
  tab; a link leaves only through the viewer's "Open in browser".
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]
  import PlatformWeb.Components.ChatClipPlayer, only: [clip_player: 1]
  import PlatformWeb.Components.LinkSiteGlyphs, only: [site_tile: 1]

  attr(:msg_id, :string, required: true)
  attr(:cards, :list, required: true)
  attr(:own?, :boolean, default: false, doc: "the viewer posted the message")

  def link_cards(assigns) do
    assigns =
      assign(
        assigns,
        :shown,
        for({card, idx} <- Enum.with_index(assigns.cards), not chip?(card), do: {card, idx})
      )

    ~H"""
    <div
      :if={@shown != []}
      id={"link-cards-#{@msg_id}"}
      data-role="link-cards"
      class="mt-2 flex max-w-md flex-col gap-2"
    >
      <%= for {card, idx} <- @shown do %>
        <div :if={card.kind == :link} class="group/card relative">
          <.link_card card={card} msg_id={@msg_id} index={idx} id={"link-card-#{@msg_id}-#{idx}"} />
          <button
            :if={@own?}
            type="button"
            id={"link-card-remove-#{@msg_id}-#{idx}"}
            data-role="link-card-remove"
            aria-label="Remove preview"
            phx-click="link_unfurl_hide"
            phx-value-message_id={@msg_id}
            class={[
              "absolute right-1.5 top-1.5 flex size-6 items-center justify-center rounded-full bg-base-100 text-subtle",
              "lg:opacity-0 lg:group-hover/card:opacity-100 lg:group-focus-within/card:opacity-100",
              "lg:hover:text-base-content focus-visible:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
            ]}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <.link_card
          :if={card.kind != :link}
          card={card}
          msg_id={@msg_id}
          index={idx}
          id={"link-card-#{@msg_id}-#{idx}"}
        />
      <% end %>
    </div>
    """
  end

  @doc """
  The chips for `ContentRenderer.render_message/2`'s `:chips` option: for
  each outside link the sender put inside a sentence (`display: :chip`), its
  `LinkTargets.key/2` mapped to a function that renders the chip given the
  sender's own link text (nil when the text was the bare URL). The chip
  keeps the card's index, so it opens the viewer exactly as the card would.
  """
  @spec chips(String.t(), [map()] | nil) :: %{term() => (String.t() | nil -> String.t())}
  def chips(msg_id, cards) when is_list(cards) do
    for {card, idx} <- Enum.with_index(cards), chip?(card), into: %{} do
      {Platform.Chat.LinkTargets.key(card.url),
       fn label ->
         %{__changed__: nil, card: card, msg_id: msg_id, index: idx, label: label}
         |> link_chip()
         |> Phoenix.HTML.Safe.to_iodata()
         |> IO.iodata_to_binary()
       end}
    end
  end

  def chips(_msg_id, _cards), do: %{}

  defp chip?(%{kind: :link, display: :chip}), do: true
  defp chip?(_card), do: false

  attr(:card, :map, required: true)
  attr(:msg_id, :string, required: true)
  attr(:index, :integer, required: true)
  attr(:label, :string, default: nil)

  @doc "An outside link inside prose as a one-line chip: site glyph + smart title."
  def link_chip(assigns) do
    assigns = assign(assigns, :text, assigns.label || assigns.card.preview.title)

    ~H"""
    <button
      type="button"
      id={"link-chip-#{@msg_id}-#{@index}"}
      data-role="link-chip"
      data-site={@card.preview.site || "other"}
      data-viewer-open
      phx-click="viewer_open"
      phx-value-message_id={@msg_id}
      phx-value-card={@index}
      aria-label={@text <> " · " <> @card.preview.meta}
      class={[
        "inline-flex max-w-full items-center gap-1.5 rounded-full border border-edge bg-base-300",
        "py-0.5 pl-1 pr-3 align-[-4px] text-[13px] font-semibold leading-5 text-base-content",
        press_class(),
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
      ]}
    >
      <.site_tile preview={@card.preview} size={:chip} />
      <span
        data-role="link-chip-label"
        class="max-w-[200px] truncate"
      >
        {@text}
      </span>
    </button>
    """
  end

  attr(:card, :map, required: true)
  attr(:id, :string, required: true)
  attr(:msg_id, :string, default: nil)
  attr(:index, :integer, default: 0)

  def link_card(%{card: %{kind: :canvas}} = assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      data-role="link-card"
      data-kind="canvas"
      data-viewer-open
      phx-click="link_card_open_canvas"
      phx-value-canvas-id={@card.canvas_id}
      class={burrow_card_class(:canvas)}
    >
      <.burrow_body card={@card} type={:canvas} meta={canvas_meta(@card.badge, @card.space_name)}>
        {@card.title}
      </.burrow_body>
    </button>
    """
  end

  def link_card(%{card: %{kind: :prototype}} = assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      data-role="link-card"
      data-kind="prototype"
      data-viewer-open
      phx-click="viewer_open"
      phx-value-message_id={@msg_id}
      phx-value-card={@index}
      class={burrow_card_class(:prototype)}
    >
      <.burrow_body card={@card} type={:prototype} meta={@card.badge}>
        {@card.name}
      </.burrow_body>
    </button>
    """
  end

  def link_card(%{card: %{kind: :link, unfurl: %{} = unfurl}} = assigns) do
    assigns =
      assigns
      |> assign(:u, unfurl)
      |> assign(:wide?, not tile_host?(assigns.card.host) and wide?(unfurl))
      |> assign(
        :tile_image,
        if(github_host?(assigns.card.host), do: nil, else: unfurl[:image_url])
      )
      |> assign(:video?, unfurl[:media_kind] == "video")
      |> assign(:title, unfurl[:title] || assigns.card.preview.title)
      |> assign(:site_name, display_host(assigns.card.host))
      |> assign(:duration, format_duration(unfurl[:duration_seconds]))

    ~H"""
    <button
      :if={@wide?}
      type="button"
      id={@id}
      data-role="link-card"
      data-kind="link"
      data-unfurled="true"
      data-layout="wide"
      data-site={@card.preview.site || "other"}
      data-viewer-open
      phx-click="viewer_open"
      phx-value-message_id={@msg_id}
      phx-value-card={@index}
      class={wide_card_class()}
    >
      <span
        data-role="link-card-media"
        class={[
          "relative block w-full overflow-hidden rounded-t-box bg-base-200",
          @video? && "aspect-video max-h-[180px]"
        ]}
      >
        <img
          data-role="link-card-image"
          src={@u.image_url}
          alt=""
          loading="lazy"
          referrerpolicy="no-referrer"
          class={["block max-h-[180px] w-full object-cover", @video? && "h-full"]}
        />
        <span
          :if={@duration}
          data-role="link-card-duration"
          class="absolute bottom-2 right-2 rounded-[4px] bg-base-content/80 px-1 font-mono text-[11px] leading-4 text-base-100"
        >
          {@duration}
        </span>
      </span>
      <span class="flex min-w-0 flex-col gap-0.5 p-3" data-role="link-card-body">
        <.site_line card={@card} site_name={@site_name} author={@u[:author]} />
        <span data-role="link-card-title" class={title_class()}>{@title}</span>
        <span :if={@u[:description]} data-role="link-card-meta" class={meta_class()}>
          {@u.description}
        </span>
      </span>
    </button>
    <button
      :if={!@wide?}
      type="button"
      id={@id}
      data-role="link-card"
      data-kind="link"
      data-unfurled="true"
      data-layout="tile"
      data-site={@card.preview.site || "other"}
      data-viewer-open
      phx-click="viewer_open"
      phx-value-message_id={@msg_id}
      phx-value-card={@index}
      class={card_class()}
    >
      <span
        :if={@tile_image}
        data-role="link-card-tile-image"
        aria-hidden="true"
        class="block size-10 shrink-0 overflow-hidden rounded-field bg-base-200"
      >
        <img
          src={@tile_image}
          alt=""
          loading="lazy"
          referrerpolicy="no-referrer"
          class="block size-full object-cover"
        />
      </span>
      <.site_tile :if={!@tile_image} preview={@card.preview} />
      <span class="min-w-0 flex-1">
        <.site_line card={@card} site_name={@site_name} author={@u[:author]} />
        <span data-role="link-card-title" class={title_class()}>{@title}</span>
        <span :if={@u[:description]} data-role="link-card-meta" class={meta_class()}>
          {@u.description}
        </span>
      </span>
    </button>
    """
  end

  def link_card(%{card: %{kind: :link}} = assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      data-role="link-card"
      data-kind="link"
      data-unfurled="false"
      data-site={@card.preview.site || "other"}
      data-viewer-open
      phx-click="viewer_open"
      phx-value-message_id={@msg_id}
      phx-value-card={@index}
      class={card_class()}
    >
      <.site_tile preview={@card.preview} />
      <span class="min-w-0 flex-1">
        <span
          :if={@card.preview.video?}
          data-role="link-card-kind"
          class="flex items-center gap-1 text-[12px] font-semibold leading-4 text-subtle"
        >
          <.icon name="hero-play-circle" class="size-3.5" /> Video
        </span>
        <span data-role="link-card-title" class={title_class()}>{@card.preview.title}</span>
        <span data-role="link-card-meta" class={meta_class()}>{@card.preview.meta}</span>
      </span>
    </button>
    """
  end

  def link_card(%{card: %{kind: :locked}} = assigns) do
    ~H"""
    <div
      id={@id}
      data-role="link-card"
      data-kind="locked"
      data-locked-type={@card.type}
      aria-disabled="true"
      class="flex w-full items-center gap-3 rounded-box border border-edge bg-base-100 p-3 text-left"
    >
      <span class="flex size-10 shrink-0 items-center justify-center rounded-field bg-base-300">
        <.icon name="hero-lock-closed" class="size-5 text-subtle" />
      </span>
      <span data-role="link-card-meta" class={meta_class()}>
        {locked_meta(@card.type)}
      </span>
    </div>
    """
  end

  def link_card(%{card: %{kind: :image}} = assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      data-role="link-media"
      data-kind="image"
      data-viewer-open
      phx-click="viewer_open"
      phx-value-message_id={@msg_id}
      phx-value-card={@index}
      aria-label={"Open " <> (@card.filename || "image")}
      class="block w-fit max-w-full cursor-zoom-in rounded-box focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
    >
      <img
        src={@card.url}
        alt={@card.filename}
        loading="lazy"
        referrerpolicy="no-referrer"
        class="block max-h-80 w-auto max-w-full rounded-box border border-edge bg-base-200"
      />
    </button>
    """
  end

  def link_card(%{card: %{kind: :video}} = assigns) do
    ~H"""
    <div class="relative w-full sm:max-w-[480px]">
      <.clip_player
        id={@id}
        role="link-video"
        src={@card.url}
        download_url={@card.url}
        filename={@card.filename}
      />
      <button
        type="button"
        id={@id <> "-expand"}
        data-role="link-video-expand"
        data-viewer-open
        phx-click="viewer_open"
        phx-value-message_id={@msg_id}
        phx-value-card={@index}
        aria-label="Open video in viewer"
        class="btn btn-circle btn-ghost btn-xs absolute right-1 top-1 bg-base-100/80 text-base-content"
      >
        <.icon name="hero-arrows-pointing-out" class="size-4" />
      </button>
    </div>
    """
  end

  def link_card(assigns), do: ~H""

  @doc """
  An attachment that is neither image nor video, as a file card (stage 3,
  coverage row 101): the stem truncates and the extension never does;
  second line "PDF · 2.1 MB". Opens the viewer in file mode; never a new tab.
  """
  attr(:attachment, :map, required: true)
  attr(:msg_id, :string, required: true)

  def file_card(assigns) do
    {stem, ext} = split_name(assigns.attachment.filename)

    assigns =
      assigns
      |> assign(:stem, stem)
      |> assign(:ext, ext)
      |> assign(
        :meta,
        PlatformWeb.ChatLive.ViewerHooks.type_label(
          assigns.attachment.filename,
          assigns.attachment.content_type
        ) <>
          " · " <> Platform.Chat.UploadLimits.format_bytes(assigns.attachment.byte_size || 0)
      )

    ~H"""
    <button
      type="button"
      id={"file-card-#{@msg_id}-#{@attachment.id}"}
      data-role="file-card"
      data-kind="file"
      data-viewer-open
      phx-click="viewer_open"
      phx-value-message_id={@msg_id}
      phx-value-attachment_id={@attachment.id}
      class={[card_class(), "max-w-md"]}
      title={@attachment.filename}
    >
      <.type_tile icon="hero-document" />
      <span class="min-w-0 flex-1">
        <span
          data-role="link-card-title"
          class="flex min-w-0 text-[15px] font-semibold leading-5 text-base-content"
        >
          <span class="truncate">{@stem}</span><span class="shrink-0">{@ext}</span>
        </span>
        <span data-role="link-card-meta" class={meta_class()}>{@meta}</span>
      </span>
    </button>
    """
  end

  @doc false
  def split_name(name) when is_binary(name) do
    case Path.extname(name) do
      "" -> {name, ""}
      ext -> {String.slice(name, 0, String.length(name) - String.length(ext)), ext}
    end
  end

  def split_name(_name), do: {"file", ""}

  attr(:icon, :string, required: true)

  defp type_tile(assigns) do
    ~H"""
    <span
      data-role="link-card-tile"
      class="flex size-10 shrink-0 items-center justify-center rounded-field bg-base-300 text-base-content"
    >
      <.icon name={@icon} class="size-5" />
    </span>
    """
  end

  attr(:card, :map, required: true)
  attr(:site_name, :any, required: true)
  attr(:author, :any, default: nil)

  # The unfurled card's site line: the 16px mark, the host without `www.`
  # (youtube.com, github.com, x.com) and, when there is one, " · " and the
  # author (a video's channel). The stored site_name is not shown here.
  # 12/16 medium, text-subtle.
  defp site_line(assigns) do
    ~H"""
    <span
      data-role="link-card-site"
      class="flex min-w-0 items-center gap-1.5 text-[12px] font-medium leading-4 text-subtle"
    >
      <.site_tile preview={@card.preview} size={:mark} />
      <span class="truncate">
        {@site_name}<span :if={is_binary(@author)} data-role="link-card-author"> · {@author}</span>
      </span>
    </span>
    """
  end

  # Posts and pull requests always take the 40px tile, whatever their
  # og:image: an X post's image is the author's media, and GitHub's social
  # card is a text banner that is illegible cropped, so GitHub shows its site
  # mark instead of the image. Checked ahead of the ratio rule.
  @tile_hosts ~w(github.com www.github.com x.com www.x.com mobile.x.com twitter.com www.twitter.com mobile.twitter.com)

  @doc false
  def tile_host?(host) when is_binary(host), do: String.downcase(host) in @tile_hosts
  def tile_host?(_host), do: false

  defp github_host?(host) when is_binary(host),
    do: String.downcase(host) in ~w(github.com www.github.com)

  defp github_host?(_host), do: false

  @doc false
  def display_host(host) when is_binary(host),
    do: host |> String.downcase() |> String.replace_prefix("www.", "")

  def display_host(_host), do: nil

  # Wide: a video, an image of at least 1.5:1, or an image of unknown size on
  # a page that declared summary_large_image. Never without an image.
  @doc false
  def wide?(%{image_url: url} = u) when is_binary(url) do
    case {u[:media_kind], u[:image_width], u[:image_height]} do
      {"video", _, _} -> true
      {_, w, h} when is_integer(w) and is_integer(h) and h > 0 -> w / h >= 1.5
      _ -> u[:twitter_card] == "summary_large_image"
    end
  end

  def wide?(_unfurl), do: false

  @doc false
  def format_duration(s) when is_integer(s) and s > 0 do
    {h, r} = {div(s, 3600), rem(s, 3600)}
    {m, sec} = {div(r, 60), rem(r, 60)}
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")

    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(sec)}", else: "#{m}:#{pad.(sec)}"
  end

  def format_duration(_s), do: nil

  attr(:card, :map, required: true)
  attr(:type, :atom, required: true, values: [:canvas, :prototype])
  attr(:meta, :string, required: true)
  slot(:inner_block, required: true)

  # A Burrow card (mockup options 8 and 9): the cover or a type-coloured
  # tile, the type line, the title and ONE description line (the stage-2
  # tagline when there is one, else the "what you'll get" hint).
  defp burrow_body(assigns) do
    ~H"""
    <span
      :if={@card[:cover]}
      data-role="link-card-cover"
      data-tier={@card.cover.tier}
      class="block h-14 w-[76px] shrink-0 overflow-hidden rounded-field border border-edge bg-base-300"
    >
      <img
        src={@card.cover.src}
        alt=""
        loading="lazy"
        referrerpolicy="no-referrer"
        class="block size-full object-cover"
      />
    </span>
    <span
      :if={!@card[:cover]}
      data-role="link-card-tile"
      data-type={@type}
      aria-hidden="true"
      class={[
        "flex h-14 w-[76px] shrink-0 items-center justify-center rounded-field",
        type_tile_class(@type)
      ]}
    >
      <.icon name={type_icon(@type)} class="size-6" />
    </span>
    <span class="min-w-0 flex-1">
      <span
        data-role="link-card-meta"
        class="flex min-w-0 items-center gap-1.5 text-[12px] font-semibold leading-4 text-subtle"
      >
        <span aria-hidden="true" class={["size-1.5 shrink-0 rounded-full", type_dot_class(@type)]}>
        </span>
        <span class="truncate">{@meta}</span>
      </span>
      <span data-role="link-card-title" class={title_class()}>{render_slot(@inner_block)}</span>
      <span data-role="link-card-hint" class={meta_class()}>
        {@card[:tagline] || @card[:hint] || "Tap to open"}
      </span>
    </span>
    """
  end

  # The type colours, as literal classes so Tailwind emits each one. Canvas
  # is the purple agent slot, prototype the orange one; the tile is the
  # slot's tint with its icon in the slot's -text step (4.5:1 on that tint by
  # construction, measured in link_card_contrast_guard_test.exs).
  defp type_tile_class(:canvas), do: "bg-[var(--ag-purple-tint)] text-[var(--ag-purple-text)]"
  defp type_tile_class(:prototype), do: "bg-[var(--ag-orange-tint)] text-[var(--ag-orange-text)]"

  defp type_dot_class(:canvas), do: "bg-[var(--ag-purple)]"
  defp type_dot_class(:prototype), do: "bg-[var(--ag-orange)]"

  defp type_icon(:canvas), do: "hero-squares-2x2"
  defp type_icon(:prototype), do: "hero-cursor-arrow-rays"

  defp burrow_card_class(:canvas),
    do: [
      burrow_card_base(),
      "border-[color-mix(in_oklab,var(--ag-purple)_40%,var(--color-edge))]"
    ]

  defp burrow_card_class(:prototype),
    do: [
      burrow_card_base(),
      "border-[color-mix(in_oklab,var(--ag-orange)_40%,var(--color-edge))]"
    ]

  defp burrow_card_base,
    do: [
      "flex w-full items-center gap-3 rounded-box border bg-base-100 p-3 text-left",
      press_class(),
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
    ]

  defp card_class,
    do: [
      "flex w-full items-center gap-3 rounded-box border border-edge bg-base-100 p-3 text-left",
      "lg:hover:border-primary",
      press_class(),
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
    ]

  # The wide unfurled card: the image leads at full width, the text block
  # under it carries the p-3 inset (the image has none).
  defp wide_card_class,
    do: [
      "flex w-full flex-col overflow-hidden rounded-box border border-edge bg-base-100 text-left",
      "lg:hover:border-primary",
      press_class(),
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
    ]

  # Press: a quick scale-down, removed under reduced motion.
  defp press_class,
    do:
      "transition-transform duration-150 active:scale-[0.97] motion-reduce:transition-none motion-reduce:active:scale-100"

  defp title_class,
    do: "line-clamp-2 text-[15px] font-semibold leading-5 text-base-content break-words"

  defp meta_class, do: "block truncate text-[13px] leading-[18px] text-subtle"

  @doc false
  def canvas_meta(badge, name) when is_binary(name) and name != "", do: badge <> " · #" <> name
  def canvas_meta(badge, _name), do: badge

  @doc false
  def prototype_meta(version), do: Platform.Chat.LinkCards.prototype_badge(version)

  @doc false
  def locked_meta(:prototype), do: "Prototype · You don't have access"
  def locked_meta(_type), do: "Canvas · You don't have access"
end
