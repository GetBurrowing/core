defmodule PlatformWeb.Components.LinkSiteGlyphs do
  @moduledoc """
  The site tile at the left of an outside-link card or chip (link previews
  stage 1; mockup canvas 01a16ed5, the "Known-site badges" legend).

  This is the ONE module that names brand colours. They are fixed
  (theme-independent) and reach the page only as the CSS variables
  `--site-bg` and `--site-fg` in a `style` attribute, painted by the
  `bg-[var(--site-bg)]` / `text-[var(--site-fg)]` utilities, so no class name
  anywhere carries a hex. `link_site_tile_guard_test.exs` holds both halves:
  every glyph clears 3:1 on its tile, and no other link-card source names a
  hex.

  The glyphs are simplified marks drawn here (a few strokes or a letter), not
  the sites' trademarked logos. A host no site matches gets a monogram: its
  first letter on a rung-3 agent slot chosen by
  `Platform.Chat.LinkSites.slot_for/1`, in the slot's `-text` step with the
  letter in `base-100` (the `-text` step is tuned to clear 4.5:1 on the slot's
  tint over base-100; the guard measures base-100 on it directly, in all ten
  theme variants). Never the globe.
  """

  use Phoenix.Component

  # {background, glyph colour}. Where white would not clear 3:1 on the brand
  # colour the glyph is near-black instead.
  @palette %{
    github: {"#24292f", "#ffffff"},
    gitlab: {"#c73a1f", "#ffffff"},
    youtube: {"#e62117", "#ffffff"},
    vimeo: {"#1ab7ea", "#0b1d26"},
    loom: {"#625df5", "#ffffff"},
    gdocs: {"#1a73e8", "#ffffff"},
    gsheets: {"#188038", "#ffffff"},
    gslides: {"#f4b400", "#2a1f00"},
    figma: {"#1e1e1e", "#ffffff"},
    linear: {"#5e6ad2", "#ffffff"},
    notion: {"#ffffff", "#111111"},
    x: {"#000000", "#ffffff"},
    slack: {"#4a154b", "#ffffff"},
    jira: {"#0052cc", "#ffffff"},
    stackoverflow: {"#f48024", "#1f1300"},
    wikipedia: {"#3a3a3a", "#ffffff"},
    dropbox: {"#0061ff", "#ffffff"},
    zoom: {"#0b5cff", "#ffffff"}
  }

  # Figma's five dots are the one multi-colour mark.
  @figma_dots [
    {"9.5", "6.5", "#f24e1e"},
    {"14.5", "6.5", "#ff7262"},
    {"9.5", "12", "#a259ff"},
    {"14.5", "12", "#1abcfe"},
    {"9.5", "17.5", "#0acf83"}
  ]

  # Simplified marks on a 24-unit grid. `currentColor` is the glyph colour;
  # a cut-out paints `var(--site-bg)`.
  @glyphs %{
    github:
      ~s|<path fill="currentColor" d="M5.6 9.3L6.4 4.6l3.3 2.6h4.6l3.3-2.6.8 4.7c.8 1 1.2 2.1 1.2 3.4 0 4-3.4 6.6-7.6 6.6S4.4 16.7 4.4 12.7c0-1.3.4-2.4 1.2-3.4z"/><circle cx="9.6" cy="12.6" r="1.1" style="fill:var(--site-bg)"/><circle cx="14.4" cy="12.6" r="1.1" style="fill:var(--site-bg)"/>|,
    youtube:
      ~s|<rect x="3.5" y="6" width="17" height="12" rx="3.5" fill="currentColor"/><path d="M10.3 9.3v5.4l4.6-2.7z" style="fill:var(--site-bg)"/>|,
    gdocs:
      ~s|<path fill="currentColor" d="M7 3.5h7l4 4v13H7z"/><path d="M9.3 12h6.4M9.3 14.6h6.4M9.3 17.2h4" style="stroke:var(--site-bg)" stroke-width="1.4"/>|,
    gsheets:
      ~s|<path fill="currentColor" d="M7 3.5h7l4 4v13H7z"/><path d="M9.2 11h6.6v6.6H9.2zM12.5 11v6.6M9.2 14.3h6.6" style="stroke:var(--site-bg)" stroke-width="1.3" fill="none"/>|,
    gslides:
      ~s|<path fill="currentColor" d="M7 3.5h7l4 4v13H7z"/><rect x="9" y="11" width="7" height="5" rx=".6" fill="none" style="stroke:var(--site-bg)" stroke-width="1.3"/>|,
    linear:
      ~s|<circle cx="12" cy="12" r="7.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M6.4 14.6l3-3M7.8 17.2l7.5-7.5M11 18.4l6-6" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>|,
    notion:
      ~s|<rect x="4.5" y="4" width="15" height="16" rx="2" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M9 16.5v-9l6 9v-9" stroke="currentColor" stroke-width="1.8" fill="none" stroke-linejoin="round"/>|,
    x:
      ~s|<path d="M5.5 5h3.4l9.6 14h-3.4z" fill="currentColor"/><path d="M17.8 5L6.2 19" stroke="currentColor" stroke-width="1.5"/>|,
    loom:
      ~s|<path d="M12 3.5v17M3.5 12h17M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="12" r="3.2" style="fill:var(--site-bg)"/>|,
    vimeo:
      ~s|<path d="M4 9.2l1.3 1.4c1.4-1 2-.9 2.6 1l1.8 6.2c.7 2.1 1.5 2.2 2.9.6 2.4-2.6 5.2-7 5.6-9.5.4-2.4-1.3-3.4-4.6-1.4.9.3 1.8 1.2.6 3.3-1.2 2-1.9 2.5-2.5.6l-1.3-5c-.6-2.1-2.4-2.3-6.4 1.8z" fill="currentColor"/>|,
    dropbox:
      ~s|<path d="M8 4.5l-4.5 3 4.5 3 4-3zM16 4.5l4.5 3-4.5 3-4-3zM3.5 13.5l4.5 3 4-3-4.5-3zM20.5 13.5l-4.5 3-4-3 4.5-3zM8 17.6l4 2.6 4-2.6-4-2.7z" fill="currentColor"/>|,
    zoom:
      ~s|<rect x="3.5" y="7.5" width="12" height="9" rx="2.2" fill="currentColor"/><path d="M16.5 11l4-2.6v7.2l-4-2.6z" fill="currentColor"/>|,
    stackoverflow:
      ~s|<path d="M6 14v5.5h11V14" stroke="currentColor" stroke-width="1.8" fill="none"/><path d="M8.5 16.8h6M8.7 13.8l6 .8M9.4 10.7l5.7 2M10.8 7.8l5 3.2M13 5.2l3.7 4.6" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>|
  }

  # Sites with no drawn mark show their initials.
  @letters %{gitlab: "GL", slack: "S", jira: "J", wikipedia: "W"}

  @doc "The {background, glyph} hex pair of every known site (the palette)."
  @spec palette() :: %{atom() => {String.t(), String.t()}}
  def palette, do: @palette

  @doc "Figma's dot colours, each painted on Figma's tile."
  def figma_dots, do: Enum.map(@figma_dots, &elem(&1, 2))

  @doc "The sites that draw a mark (the rest show letters)."
  def drawn, do: Map.keys(@glyphs) ++ [:figma]

  @doc "The sites shown as letters."
  def lettered, do: @letters

  # A literal class per slot, so Tailwind sees every one.
  @slot_classes %{
    "teal" => "bg-[var(--ag-teal-text)]",
    "green" => "bg-[var(--ag-green-text)]",
    "amber" => "bg-[var(--ag-amber-text)]",
    "blue" => "bg-[var(--ag-blue-text)]",
    "purple" => "bg-[var(--ag-purple-text)]",
    "brick" => "bg-[var(--ag-brick-text)]",
    "rose" => "bg-[var(--ag-rose-text)]",
    "indigo" => "bg-[var(--ag-indigo-text)]",
    "lime" => "bg-[var(--ag-lime-text)]"
  }

  @doc "The fill class of a monogram slot."
  def slot_class(slot), do: Map.fetch!(@slot_classes, slot)

  attr(:preview, :map, required: true, doc: "a `Platform.Chat.LinkSites.describe/1` result")
  attr(:size, :atom, default: :card, values: [:card, :chip])

  @doc "The site tile: a brand mark on its colour, or a monogram."
  def site_tile(%{preview: %{site: site}} = assigns) when is_map_key(@palette, site) do
    {bg, fg} = Map.fetch!(@palette, site)

    assigns =
      assigns
      |> assign(:style, "--site-bg:#{bg};--site-fg:#{fg}")
      |> assign(:glyph, glyph(site))
      |> assign(:letters, Map.get(@letters, site))

    ~H"""
    <span
      data-role="link-site-tile"
      data-site={@preview.site}
      aria-hidden="true"
      style={@style}
      class={[
        "flex shrink-0 items-center justify-center overflow-hidden bg-[var(--site-bg)] text-[var(--site-fg)]",
        tile_box(@size),
        @preview.site == :notion && "ring-1 ring-inset ring-edge"
      ]}
    >
      <svg :if={@glyph} viewBox="0 0 24 24" class={glyph_box(@size)}>{Phoenix.HTML.raw(@glyph)}</svg>
      <span :if={@letters} class={["font-bold tracking-tight", letter_size(@size)]}>{@letters}</span>
    </span>
    """
  end

  def site_tile(assigns) do
    assigns = assign(assigns, :slot_class, slot_class(assigns.preview.slot || "teal"))

    ~H"""
    <span
      data-role="link-site-tile"
      data-monogram-slot={@preview.slot}
      aria-hidden="true"
      class={[
        "flex shrink-0 items-center justify-center overflow-hidden text-base-100",
        @slot_class,
        tile_box(@size)
      ]}
    >
      <span class={["font-bold tracking-tight", letter_size(@size)]}>{@preview.monogram}</span>
    </span>
    """
  end

  defp glyph(:figma) do
    Enum.map_join(@figma_dots, fn {cx, cy, c} ->
      ~s(<circle cx="#{cx}" cy="#{cy}" r="3" fill="#{c}"/>)
    end)
  end

  defp glyph(site), do: Map.get(@glyphs, site)

  defp tile_box(:card), do: "size-10 rounded-field"
  defp tile_box(:chip), do: "size-[18px] rounded-full"

  defp glyph_box(:card), do: "size-[22px]"
  defp glyph_box(:chip), do: "size-3"

  defp letter_size(:card), do: "text-[16px] leading-none"
  defp letter_size(:chip), do: "text-[10px] leading-none"
end
