defmodule Platform.Design.LinkCardContrastGuardTest do
  @moduledoc """
  Holds the chat link cards' paint (link previews stage 1, mockup canvas
  01a16ed5) in all ten preset variants (Burrow, Midnight, Sand, Forest, High
  contrast; light and dark), the same method as the attach and inbox guards:
  tokens from app.css and theme_presets.css, `--subtle` painted on the worst
  pixel `PaintedComposite` allows, the agent tint through `PaintedMix`.
  Sources: `ChatLinkCard` and `LinkSiteGlyphs`.

  ## Pairs and floors

  | pair                                                            | floor |
  |-----------------------------------------------------------------|-------|
  | card title: base-content on base-200                            | 4.5   |
  | type line, meta and hint: --subtle on base-200 (painted)        | 4.5   |
  | chip label: base-content on base-300                            | 4.5   |
  | monogram letter: base-100 on each slot's --ag-<id>-text         | 4.5   |
  | type tile icon: --ag-<id>-text on --ag-<id>-tint (painted mix)  | 3.0   |
  | site glyph on its brand tile (theme-independent)                | 3.0   |

  The monogram letter is a glyph, but it is a letter, so it is held at the
  text floor. Brand colours are fixed, so their pair is measured once, from
  `LinkSiteGlyphs.palette/0` itself.

  Hygiene: the brand hexes live in `LinkSiteGlyphs`'s palette and nowhere
  else; no link-card source names a hex, a phone `hover:`, a
  `text-base-content/<n>`, or the globe.
  """
  use ExUnit.Case, async: true

  alias Platform.Chat.LinkSites
  alias Platform.Design.PaintedComposite
  alias Platform.Design.PaintedMix
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.WcagContrast, as: W
  alias PlatformWeb.Components.LinkSiteGlyphs

  @root Path.expand("../../..", __DIR__)
  @app_css_path Path.join(@root, "assets/css/app.css")
  @presets_path Path.join(@root, "assets/css/theme_presets.css")

  @card_path Path.join(@root, "lib/platform_web/components/chat_link_card.ex")
  @glyphs_path Path.join(@root, "lib/platform_web/components/link_site_glyphs.ex")

  @aa_text 4.5
  @aa_non_text 3.0

  @variants [
    {"burrow", "light"},
    {"burrow", "dark"},
    {"burrow-midnight", "light"},
    {"burrow-midnight", "dark"},
    {"burrow-sand", "light"},
    {"burrow-sand", "dark"},
    {"burrow-forest", "light"},
    {"burrow-forest", "dark"},
    {"high-contrast", "light"},
    {"high-contrast", "dark"}
  ]

  # The type colours ChatLinkCard paints (canvas, prototype).
  @type_slots ["purple", "orange"]

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/

  setup_all do
    app_css = File.read!(@app_css_path)
    presets = File.read!(@presets_path)

    by_key =
      Map.new(Blocks.preset_blocks(presets), &{{&1.id, &1.mode}, &1})
      |> Map.put({"burrow", "light"}, Blocks.burrow_block(app_css, "light"))
      |> Map.put({"burrow", "dark"}, Blocks.burrow_block(app_css, "dark"))

    blocks =
      for {id, mode} = key <- @variants do
        Map.get(by_key, key) || flunk("no #{id} #{mode} block")
      end

    {:ok,
     blocks: blocks,
     app_css: app_css,
     card: File.read!(@card_path),
     glyphs: File.read!(@glyphs_path)}
  end

  defp c(b, token), do: Blocks.resolve!(b, token)

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

  defp tint_pct(b, app_css) do
    value =
      Blocks.declaration(b.decls, "--ag-tint-pct") ||
        Blocks.declaration(Blocks.burrow_block(app_css, b.mode).decls, "--ag-tint-pct") ||
        flunk("#{b.id} #{b.mode}: no --ag-tint-pct")

    case Regex.run(~r/^(\d+)%$/, value) do
      [_, pct] -> String.to_integer(pct)
      nil -> flunk("#{b.id} #{b.mode}: --ag-tint-pct is #{inspect(value)}")
    end
  end

  defp subtle_on(b, ground) do
    {r, _} =
      PaintedComposite.contrast_min(
        c(b, "--color-base-content"),
        c(b, "--color-#{ground}"),
        subtle_pct(b)
      )

    r
  end

  defp pairs(b, app_css) do
    pct = tint_pct(b, app_css)

    [
      {"title / base-200", @aa_text,
       W.contrast(c(b, "--color-base-content"), c(b, "--color-base-200"))},
      {"subtle / base-200", @aa_text, subtle_on(b, "base-200")},
      {"chip label / base-300", @aa_text,
       W.contrast(c(b, "--color-base-content"), c(b, "--color-base-300"))}
    ] ++
      for slot <- LinkSites.slots() do
        {"monogram base-100 / ag-#{slot}-text", @aa_text,
         W.contrast(c(b, "--color-base-100"), c(b, "--ag-#{slot}-text"))}
      end ++
      for slot <- @type_slots do
        {"tile icon ag-#{slot}-text / tint", @aa_non_text,
         PaintedMix.text_min(
           c(b, "--ag-#{slot}-text"),
           c(b, "--ag-#{slot}"),
           c(b, "--color-base-100"),
           pct
         )}
      end
  end

  defp f2(r), do: :erlang.float_to_binary(r / 1, decimals: 2)

  test "every pair clears its floor in all ten variants; the table prints",
       %{blocks: blocks, app_css: app_css} do
    assert length(blocks) == 10
    rows = for b <- blocks, do: {b, pairs(b, app_css)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    IO.puts(
      "\nLink card AA table:\n| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", fn {_, _, r} -> f2(r) end) <> " |"
        end)
    )

    failures =
      for {b, ps} <- rows, {label, floor, r} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f2(r)} < #{floor}"
      end

    assert failures == []
  end

  test "every site glyph clears 3:1 on its brand tile" do
    palette = LinkSiteGlyphs.palette()

    assert palette |> Map.keys() |> Enum.sort() ==
             LinkSites.sites() |> Keyword.keys() |> Enum.sort()

    figma_bg = W.hex(elem(palette.figma, 0))

    failures =
      for(
        {site, {bg, fg}} <- palette,
        site != :figma,
        do: {site, W.contrast(W.hex(fg), W.hex(bg))}
      ) ++
        for(
          dot <- LinkSiteGlyphs.figma_dots(),
          do: {{:figma, dot}, W.contrast(W.hex(dot), figma_bg)}
        )

    assert Enum.reject(failures, fn {_, r} -> r >= @aa_non_text end) == []
  end

  test "the card paints the slots this guard measures", %{card: card, glyphs: glyphs} do
    assert card =~ "bg-base-200"
    assert card =~ "border border-edge bg-base-300"
    assert card =~ "text-base-content"
    assert card =~ "text-subtle"

    for slot <- @type_slots do
      assert card =~ "bg-[var(--ag-#{slot}-tint)] text-[var(--ag-#{slot}-text)]"
    end

    assert glyphs =~ "text-base-100"

    for slot <- LinkSites.slots(),
        do: assert(glyphs =~ ~s|"#{slot}" => "bg-[var(--ag-#{slot}-text)]"|)
  end

  test "hex only in the glyph palette; no phone hover:, faded body text or globe",
       %{card: card, glyphs: glyphs} do
    glyphs_outside_palette =
      glyphs
      |> String.replace(~r/@palette %\{.*?\n  \}/s, "")
      |> String.replace(~r/@figma_dots \[.*?\n  \]/s, "")

    # Positive control: the palette really is where the hexes are.
    assert glyphs =~ ~r/github: \{"#[0-9a-f]{6}"/

    for {name, src} <- [card: card, glyphs: glyphs_outside_palette] do
      refute Regex.match?(~r/#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b/, src), "#{name}: a hex literal"
      refute Regex.match?(~r/(^|[\s"'\[])hover:/, src), "#{name}: a phone hover: utility"
      refute Regex.match?(~r/text-base-content\/\d/, src), "#{name}: text-base-content/<n>"
      refute src =~ "hero-globe", "#{name}: the globe"
    end
  end
end
