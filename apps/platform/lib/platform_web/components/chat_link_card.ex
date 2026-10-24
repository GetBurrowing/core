defmodule PlatformWeb.Components.ChatLinkCard do
  @moduledoc """
  The chat card family (redesign rung 13 stage 1; direction canvas 01a16748
  "CARD FAMILY"): one anatomy for canvas, prototype, link and locked cards,
  plus inline images and video for media URLs.

  Anatomy: a `base-200` card on the `base-100` pane, `border-edge` (the repo's
  border token; base-300 is a fill, see border_token_direction_test.exs),
  `rounded-box`; a `base-300` type tile at the left with a `base-content`
  hero icon; a 15px semibold title of at most two lines; a 13px subtle second
  line. Images and video render inline as media, not as cards; video uses the
  shared `PlatformWeb.Components.ChatClipPlayer`.

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

  attr(:msg_id, :string, required: true)
  attr(:cards, :list, required: true)

  def link_cards(assigns) do
    ~H"""
    <div
      id={"link-cards-#{@msg_id}"}
      data-role="link-cards"
      class="mt-2 flex max-w-md flex-col gap-2"
    >
      <.link_card
        :for={{card, idx} <- Enum.with_index(@cards)}
        card={card}
        msg_id={@msg_id}
        index={idx}
        id={"link-card-#{@msg_id}-#{idx}"}
      />
    </div>
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
      class={card_class()}
    >
      <.type_tile icon="hero-squares-2x2" />
      <span class="min-w-0 flex-1">
        <span data-role="link-card-title" class={title_class()}>{@card.title}</span>
        <span data-role="link-card-meta" class={meta_class()}>
          {canvas_meta(@card.space_name)}
        </span>
      </span>
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
      class={card_class()}
    >
      <.type_tile icon="hero-cursor-arrow-rays" />
      <span class="min-w-0 flex-1">
        <span class="flex min-w-0 items-start gap-2">
          <span data-role="link-card-title" class={[title_class(), "min-w-0 flex-1"]}>
            {@card.name}
          </span>
          <span
            data-role="link-card-badge"
            class="badge badge-outline badge-sm shrink-0 text-base-content"
          >
            Clickable
          </span>
        </span>
        <span data-role="link-card-meta" class={meta_class()}>
          {prototype_meta(@card.version)}
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
      data-viewer-open
      phx-click="viewer_open"
      phx-value-message_id={@msg_id}
      phx-value-card={@index}
      class={card_class()}
    >
      <.type_tile icon="hero-globe-alt" />
      <span class="min-w-0 flex-1">
        <span data-role="link-card-title" class={[title_class(), "break-all"]}>
          {@card.host <> @card.path}
        </span>
        <span data-role="link-card-meta" class="flex min-w-0 text-[13px] leading-[18px] text-subtle">
          <span class="shrink-0">{@card.host}</span>
        </span>
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

  defp card_class,
    do: [
      "flex w-full items-center gap-3 rounded-box border border-edge bg-base-200 p-2.5 text-left",
      "transition-colors hover:border-primary hover:no-underline",
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
    ]

  defp title_class,
    do: "line-clamp-2 text-[15px] font-semibold leading-5 text-base-content break-words"

  defp meta_class, do: "block truncate text-[13px] leading-[18px] text-subtle"

  @doc false
  def canvas_meta(name) when is_binary(name) and name != "", do: "Canvas · #" <> name
  def canvas_meta(_name), do: "Canvas"

  @doc false
  def prototype_meta(version) when is_integer(version) and version > 0,
    do: "Prototype · v#{version}"

  def prototype_meta(_version), do: "Prototype"

  @doc false
  def locked_meta(:prototype), do: "Prototype · You don't have access"
  def locked_meta(_type), do: "Canvas · You don't have access"
end
