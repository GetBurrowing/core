defmodule Platform.Design.FilesBrowserContrastGuardTest do
  @moduledoc """
  Holds the Files & Canvases browser's paint (Burrow redesign rung 16, task
  01a1557a-b5f9 stage 4; `PlatformWeb.FilesLive` and
  `PlatformWeb.Files.BrowserComponents`) in all ten preset variants (Burrow,
  Midnight, Sand, Forest, High contrast; light and dark). Mirrors
  `inbox_list_contrast_guard_test.exs` (rung 14).

  ## Pairs and floors

  | pair                                                                       | floor |
  |----------------------------------------------------------------------------|-------|
  | title, h1, last crumb, chip labels, sheet items: body on the list ground   | 4.5   |
  | the same on the pressed ground, base-100 (tiles, tree, New menu/sheet)     | 4.5   |
  | the same on the selected chip's fill                                       | 4.5   |
  | location line, author, age, counts, empty/capped copy: the location slot  | 4.5   |
  |   on the list, pressed and base-100 grounds (PAINTED when it is --subtle)  |       |
  | type glyphs (body) on their thumb tile and on base-100                     | 3     |
  | the + New control: primary-content on primary                             | 4.5   |
  | the selected chip's border against the list ground (painted when --subtle) | 3     |

  Saru's direction canvas 01a161fc (`pal`) sets the grounds: the list is
  base-200, a pressed row base-100, tiles, the desktop tree and the New
  sheet/menu base-100, and a selected chip is neutral (base-content on
  base-300). The guard does NOT assume them: it reads every ground and slot
  from the rendered classes, below, and measures what it read.

  ## A measured slot change (stage 4)

  The plan named the selected chip's border `border-edge`. Measured, edge on
  the base-200 list is 1.34 to 1.68:1 in eight of the ten variants (only
  high-contrast clears 3:1), so the selected chip's border moved to `--subtle`
  (painted, at least 4.59:1 there); unselected chips keep `border-edge`. The
  selected FILL alone is 1.07 to 1.29:1 against the list; the selected state
  also rides on the bold weight and `aria-current`, so no fill floor is held.

  The failed-ingest "Failed" badge (`badge-error`, a failed action) kept its
  pre-rung classes, so it is not asserted here.

  ## Desktop hover is CSS, never a utility

  `assets/css/app.css` carries the browser's hover paint under
  `@media (hover: hover) and (min-width: 1024px)` beside the sheet X's rule
  (task 01a161c4). The last tests pin the rule inside that media query and
  find no browser selector's `:hover` outside it, and no `hover:` utility in
  the browser's markup.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.PaintedComposite
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @heex_path Path.expand("../../../lib/platform_web/live/files_live.html.heex", __DIR__)
  @components_path Path.expand(
                     "../../../lib/platform_web/live/files/browser_components.ex",
                     __DIR__
                   )

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

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/
  @hover_media "@media (hover: hover) and (min-width: 1024px)"

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

    heex = File.read!(@heex_path)
    components = File.read!(@components_path)

    # The code below the moduledoc: prose may NAME what the code forbids.
    code =
      case String.split(components, "use Phoenix.Component", parts: 2) do
        [_doc, code] -> code
        _ -> flunk("browser_components.ex: no `use Phoenix.Component`; the split point moved")
      end

    {:ok, blocks: blocks, heex: heex, code: code, app_css: app_css}
  end

  # ── source reading ─────────────────────────────────────────────────────

  # The one opening tag containing `marker` (an attribute or class run that
  # names the element). Component tags (`<.link`) count.
  defp tags_with(source, marker) do
    # `<-` (a :for generator) and `->` may sit inside a tag's expressions.
    ~r/<[a-zA-Z.](?:[^<>]|<-|->)*?>/s
    |> Regex.scan(source)
    |> Enum.map(&hd/1)
    |> Enum.filter(&String.contains?(&1, marker))
  end

  defp tag_with(source, marker) do
    case tags_with(source, marker) do
      [tag] -> tag
      other -> flunk("expected one tag containing #{inspect(marker)}, got #{length(other)}")
    end
  end

  defp classes(tag) do
    case Regex.run(~r/\bclass="([^"]+)"/, tag) do
      [_, classes] -> String.split(classes, ~r/\s+/, trim: true)
      nil -> flunk("no static class attribute in #{tag}")
    end
  end

  defp one(list, what) do
    assert length(list) == 1, "expected exactly one #{what}, got #{inspect(list)}"
    hd(list)
  end

  defp prefixed(classes, prefix),
    do:
      for(c <- classes, String.starts_with?(c, prefix), do: String.replace_prefix(c, prefix, ""))

  # The selected and unselected chip class strings, from `chip/1`'s branch.
  defp chip_branches(code) do
    case Regex.run(~r/if\(@selected,\s*do: "([^"]+)",\s*else: "([^"]+)"\s*\)/s, code) do
      [_, sel, unsel] -> {String.split(sel), String.split(unsel)}
      nil -> flunk("chip/1's selected branch not found")
    end
  end

  # Every ground and slot the browser paints, read from its own classes.
  defp slots(heex, code) do
    root = heex |> tag_with(~s(data-role="files-browser")) |> classes()
    menu = heex |> tag_with(~s(data-role="files-new-menu")) |> classes()
    row = code |> tag_with("data-file-id={if item.kind == :file") |> classes()
    tile = code |> tag_with(~s(data-role="browser-tile")) |> classes()
    tree = code |> tag_with(~s(data-role="files-tree")) |> classes()

    thumb =
      code
      |> tag_with("size-11 shrink-0 items-center justify-center overflow-hidden")
      |> classes()

    # Item rows and node rows share the title span's ink; every copy must
    # agree on it (placement classes may differ: stage 5's row grid).
    titles =
      code |> tags_with("min-w-0 flex-1 truncate text-sm font-medium") |> Enum.map(&classes/1)

    assert length(titles) == 2, "expected the item-row and node-row title spans"

    title_inks =
      titles |> Enum.map(&(prefixed(&1, "text-") -- ["sm", "xs"])) |> Enum.uniq()

    location = code |> tag_with(~s(class={["flex min-w-0 items-baseline gap-1)) |> raw_classes()
    new = code |> tag_with(~s(data-role="files-new")) |> classes()
    {selected, _unselected} = chip_branches(code)

    %{
      list: one(prefixed(root, "bg-"), "list ground"),
      pressed: one(prefixed(row, "active:bg-"), "pressed ground"),
      tile: one(prefixed(tile, "bg-"), "tile fill"),
      tree: one(prefixed(tree, "bg-"), "tree fill"),
      menu: one(prefixed(menu, "bg-"), "New menu fill"),
      thumb: one(prefixed(thumb, "bg-"), "thumb tile fill"),
      glyph: one(prefixed(thumb, "text-") -- ["xs", "sm"], "glyph ink"),
      title: title_inks |> one("title ink list") |> one("title ink"),
      location: one(prefixed(location, "text-") -- ["xs", "sm"], "location ink"),
      new_fill: if("btn-primary" in new, do: "primary", else: flunk("+ New is not btn-primary")),
      chip_fill: one(prefixed(selected, "bg-"), "selected chip fill"),
      chip_border: one(prefixed(selected, "border-"), "selected chip border")
    }
  end

  # The location line's class is a list literal; take its static string.
  defp raw_classes(tag) do
    case Regex.run(~r/class=\{\["([^"]+)"/, tag) do
      [_, classes] -> String.split(classes)
      nil -> flunk("no class list in #{tag}")
    end
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: Blocks.resolve!(b, token)

  # A slot name as a token: `subtle` is painted, `edge` reads `--edge`.
  defp tok("edge"), do: "--edge"
  defp tok(slot), do: "--color-#{slot}"

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

  # Ink on ground: painted on the worst pixel when the ink is --subtle.
  defp on(b, "subtle", ground) do
    {r, _} =
      PaintedComposite.contrast_min(
        c(b, "--color-base-content"),
        c(b, tok(ground)),
        subtle_pct(b)
      )

    r
  end

  defp on(b, ink, ground), do: W.contrast(c(b, tok(ink)), c(b, tok(ground)))

  defp pairs(b, s) do
    [
      {"title #{s.title} / #{s.list} (list)", on(b, s.title, s.list), @aa_text},
      {"title #{s.title} / #{s.pressed} (pressed)", on(b, s.title, s.pressed), @aa_text},
      {"body / #{s.tile} (tile)", on(b, "base-content", s.tile), @aa_text},
      {"body / #{s.tree} (tree)", on(b, "base-content", s.tree), @aa_text},
      {"body / #{s.menu} (New menu)", on(b, "base-content", s.menu), @aa_text},
      {"chip label / #{s.chip_fill} (selected)", on(b, "base-content", s.chip_fill), @aa_text},
      {"location #{s.location} / #{s.list}", on(b, s.location, s.list), @aa_text},
      {"location #{s.location} / #{s.pressed}", on(b, s.location, s.pressed), @aa_text},
      {"location #{s.location} / #{s.tile}", on(b, s.location, s.tile), @aa_text},
      {"glyph #{s.glyph} / #{s.thumb} (thumb)", on(b, s.glyph, s.thumb), @aa_non_text},
      {"glyph #{s.glyph} / #{s.tile}", on(b, s.glyph, s.tile), @aa_non_text},
      {"+ New primary-content / #{s.new_fill}", on(b, "primary-content", s.new_fill), @aa_text},
      {"chip border #{s.chip_border} / #{s.list}", on(b, s.chip_border, s.list), @aa_non_text}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  # ── contrast ───────────────────────────────────────────────────────────

  test "every pair clears its floor in all ten variants; the table prints", ctx do
    assert length(ctx.blocks) == 10
    s = slots(ctx.heex, ctx.code)

    rows = for b <- ctx.blocks, do: {b, pairs(b, s)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))
    floors = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 2))

    IO.puts(
      "\nFiles browser AA table (WCAG 2.x; --subtle rows painted on the worst pixel):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n| floor | " <>
        Enum.map_join(floors, " | ", &f4/1) <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", fn {_, r, _} -> f4(r) end) <> " |"
        end)
    )

    failures =
      for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  test "the slots the guard read are the ruling's (Saru pal)", ctx do
    s = slots(ctx.heex, ctx.code)

    assert s.list == "base-200"
    assert s.pressed == "base-100"
    assert s.tile == "base-100"
    assert s.tree == "base-100"
    assert s.menu == "base-100"
    assert s.title == "base-content"
    assert s.location == "subtle"
    assert s.glyph == "base-content"
  end

  test "the selected chip is neutral: base-300 fill, never primary or a status colour", ctx do
    {selected, unselected} = chip_branches(ctx.code)

    assert "bg-base-300" in selected
    assert "border-subtle" in selected
    assert "border-edge" in unselected

    for token <- selected ++ unselected do
      refute token =~
               ~r/(^|:)(bg|border|text)-(primary|secondary|accent|error|warning|success|info)\b/,
             "chip paints #{token}"
    end
  end

  test "+ New is the browser chrome's only primary control", ctx do
    primaries =
      for source <- [ctx.heex, ctx.code],
          tag <- tags_with(source, "btn-primary"),
          do: tag

    # The New button, plus the detail pane's two Download buttons (desktop
    # pane and mobile drawer; pre-rung, unchanged in behaviour). Nothing in
    # the browser chrome itself.
    assert length(primaries) == 3
    assert ctx.code |> tag_with(~s(data-role="files-new")) =~ "btn-primary"
    assert ctx.heex |> tag_with(~s(data-role="files-detail-download")) =~ "btn-primary"

    downloads = Enum.count(primaries, &(&1 =~ "download="))
    assert downloads == 2
  end

  # ── structure ──────────────────────────────────────────────────────────

  test "no hover:, text-base-content/<n>, hex, data-theme selector or sub-12px text", ctx do
    for {name, source} <- [{"files_live.html.heex", ctx.heex}, {"browser_components", ctx.code}] do
      # Anti-vacuity: each source is the browser's markup.
      assert byte_size(source) > 2000, name
      assert source =~ "text-base-content", name

      refute source =~ "hover:", name
      refute source =~ "text-base-content/", name
      refute source =~ "[data-theme", name
      refute Regex.match?(~r/class="[^"]*#[0-9a-fA-F]{3,8}\b/, source), name

      small =
        for [_, n] <- Regex.scan(~r/text-\[(\d+)px\]/, source), String.to_integer(n) < 12, do: n

      assert small == [], name
    end
  end

  # ── desktop hover CSS ──────────────────────────────────────────────────

  # One selector per line in the rule; count selector LINES, not blocks.
  @browser_hover ~r/^\s*\[data-role="(files-browser|files-tree|files-new-menu|files-chips)"\][^\n{]*:hover/m

  # The bodies of every `@hover_media` block (brace-matched).
  defp hover_media_blocks(css) do
    css
    |> String.split(@hover_media)
    |> tl()
    |> Enum.map(&brace_body/1)
  end

  defp brace_body(rest) do
    [_, after_open] = String.split(rest, "{", parts: 2)

    {body, _} =
      after_open
      |> String.graphemes()
      |> Enum.reduce_while({"", 1}, fn ch, {acc, depth} ->
        depth = depth + if(ch == "{", do: 1, else: 0) - if(ch == "}", do: 1, else: 0)
        if depth == 0, do: {:halt, {acc, 0}}, else: {:cont, {acc <> ch, depth}}
      end)

    body
  end

  test "the browser's hover lives in app.css, inside the desktop hover media query", ctx do
    inside = ctx.app_css |> hover_media_blocks() |> Enum.join("\n")
    in_count = length(Regex.scan(@browser_hover, inside))
    all_count = length(Regex.scan(@browser_hover, ctx.app_css))

    # Positive control: the rule exists and names rows, tiles, tree and chips.
    assert in_count >= 8
    assert inside =~ ~s([data-role="browser-row"]:hover)
    assert inside =~ ~s([data-role="browser-tile"]:hover)
    assert inside =~ ~s([data-role="files-tree-project"])
    assert inside =~ ~s([data-role="files-chips"] [aria-current="false"]:hover)
    # Rows hover to the pressed slot; base-100 surfaces to base-200.
    assert inside =~ "background: var(--color-base-100)"
    assert inside =~ "background: var(--color-base-200)"

    # No browser :hover selector outside that media query.
    assert all_count == in_count
  end
end
