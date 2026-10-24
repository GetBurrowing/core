defmodule PlatformWeb.Components.ChatLinkCard do
  @moduledoc """
  The chat card family (redesign rung 13 stage 1; direction canvas 01a16748
  "CARD FAMILY"): one anatomy for canvas, prototype, link and locked cards,
  plus inline images and video for media URLs.

  Anatomy: a `base-200` card on the `base-100` pane, `border-edge` (the repo's
  border token; base-300 is a fill, see border_token_direction_test.exs),
  `rounded-box`; a tile at the left; a 15px semibold title of at most two
  lines; ONE 13px subtle description line. Every card and chip scales down
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
      options · tap to open"), with a border and glow in the type colour.

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
      <.link_card
        :for={{card, idx} <- @shown}
        card={card}
        msg_id={@msg_id}
        index={idx}
        id={"link-card-#{@msg_id}-#{idx}"}
      />
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
        "py-px pl-0.5 pr-2.5 align-[-4px] text-[13px] font-semibold leading-5 text-base-content",
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

  def link_card(%{card: %{kind: :link}} = assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      data-role="link-card"
      data-kind="link"
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
      class="flex w-full items-center gap-3 rounded-box border border-edge bg-base-200 p-2.5 text-left"
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
      "border-[color-mix(in_oklab,var(--ag-purple)_40%,var(--color-edge))]",
      "shadow-[0_10px_24px_-16px_var(--ag-purple)]"
    ]

  defp burrow_card_class(:prototype),
    do: [
      burrow_card_base(),
      "border-[color-mix(in_oklab,var(--ag-orange)_40%,var(--color-edge))]",
      "shadow-[0_10px_24px_-16px_var(--ag-orange)]"
    ]

  defp burrow_card_base,
    do: [
      "flex w-full items-center gap-3 rounded-box border bg-base-200 p-2 text-left",
      press_class(),
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
    ]

  defp card_class,
    do: [
      "flex w-full items-center gap-3 rounded-box border border-edge bg-base-200 p-2.5 text-left",
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
