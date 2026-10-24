defmodule Platform.Design.TasksFiltersContrastGuardTest do
  @moduledoc """
  Holds the Tasks filters' paint (task 01a161fd, rung 15b: the phone header,
  chips and sheets of stage 3 and the desktop title menu and filter popover of
  stage 4) in all ten preset variants (Burrow, Midnight, Sand, Forest, High
  contrast; light and dark). Sources: `PlatformWeb.Tasks.FilterBar`,
  `FilterSheets`, `FilterDesktop` and the list rows in `MyTasksList`.

  ## Pairs and floors

  | pair                                                       | floor |
  |------------------------------------------------------------|-------|
  | title: base-content on base-200 (the phone list ground)    | 4.5   |
  | chip text: base-content on base-100                        | 4.5   |
  | chip ×: --subtle on base-100 (painted)                     | 4.5   |
  | Clear all: base-content on base-200                        | 4.5   |
  | badge: its text slot on its fill slot (base-100 on base-content) | 4.5 |
  | section labels: --subtle on base-100 (painted)             | 4.5   |
  | option text: base-content on base-100 (rest)               | 4.5   |
  | option text: base-content on base-200 (pressed, desktop hover) | 4.5 |
  | toggle-on text and ✓: base-content on base-300             | 4.5   |
  | Show: its text slot on its fill slot (primary-content on primary) | 4.5 |
  | disabled 'No tasks match': its text slot on its fill slot (--subtle on base-300, painted) | 4.5 |
  | search placeholder: --subtle on base-100 (painted; the global `::placeholder` rule) | 4.5 |
  | priority word: base-content on base-200 and on base-100    | 4.5   |
  | sponsor checkbox border: base-content on base-100          | 3.0   |
  | Project row text: its text slot on base-100 (rest)         | 4.5   |
  | Project row text: its text slot on its `active:bg-` slot (pressed; desktop hover is base-200) | 4.5 |
  | Project row chevron: its text slot on base-100 (--subtle, painted) | 3.0 |

  The Project row (task 01a168c2) is found by its data-role. Its classes are
  `@opt` plus `w-full`, so the guard reads `@opt`'s string from the source;
  the chevron is found by `tasks-filter-project-chevron`. The 'Project'
  section label is a section label (above). The chevron is a graphical
  object, so its floor is 1.4.11's 3:1.

  The badge, Show and the disabled footer paint their own fill, so their text
  never meets the sheet or header ground. The guard reads both slots from the
  element's classes in source and measures THAT pair, so a class edit is
  followed, never assumed.

  `--subtle` is `color-mix(in oklab, base-content N%, transparent)`, alpha over
  the ground, so every pair it is in is PAINTED: the worst pixel
  `Platform.Design.PaintedComposite` allows, never a derived colour. Every
  other token is opaque and measured with `WcagContrast.contrast/2`. The table
  prints.

  ## Status dots have no floor (WCAG 1.4.11)

  1.4.11 Non-text Contrast asks 3:1 of graphical objects "required to
  understand the content". The Status toggles' dots are not: each sits beside
  its status word, which this guard holds at 4.5, and the dot is
  `aria-hidden` (asserted below from source). Decorative by construction, so
  no floor. If a dot ever stands without its word, this exemption stops
  holding. The sponsor checkbox's border IS required (it is the control's
  only boundary when unchecked), so it carries the 3:1 non-text floor.

  ## Structure (anti-vacuity first)

  The sources are read and shown to be the filter components (non-empty,
  carrying their data-roles) before anything is refuted in them. Then: no
  `hover:` utility (desktop hover is plain CSS in app.css), no
  `text-base-content/<n>`, no hex literal, no `[data-theme` selector.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @tasks_dir Path.expand("../../../lib/platform_web/live/tasks", __DIR__)

  @sources %{
    bar: "filter_bar.ex",
    sheets: "filter_sheets.ex",
    desktop: "filter_desktop.ex"
  }

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

  # Utility suffixes that are not colours.
  @text_sizes ~w(xs sm base lg xl 2xl 3xl)
  # Alignment suffixes (`text-left` in the Project row's `@opt`), not colours.
  @text_aligns ~w(left center right justify start end)

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

    sources = Map.new(@sources, fn {k, f} -> {k, File.read!(Path.join(@tasks_dir, f))} end)

    {:ok, blocks: blocks, sources: sources}
  end

  # ── source reading ─────────────────────────────────────────────────────

  # The opening tag of the element carrying `data-role="<role>"`.
  defp tag_with_role(source, role) do
    case Regex.scan(~r/<[a-z.]+\b(?:(?!>)[\s\S])*?data-role="#{role}"(?:(?!>)[\s\S])*?>/, source) do
      [[tag]] -> tag
      other -> flunk("expected exactly one element with data-role=#{role}, got #{length(other)}")
    end
  end

  # {fill slot, text slot} named by a class string, e.g. "bg-primary
  # text-primary-content" gives {"primary", "primary-content"}.
  defp slots(classes) do
    classes = String.split(classes, ~r/\s+/, trim: true)
    fills = for "bg-" <> slot <- classes, do: slot

    texts =
      for "text-" <> slot <- classes,
          slot not in @text_sizes,
          not String.starts_with?(slot, "["),
          do: slot

    assert [fill] = fills, "expected exactly one fill slot, got #{inspect(fills)}"
    assert [text] = texts, "expected exactly one text slot, got #{inspect(texts)}"
    {fill, text}
  end

  # The badge's static class (its tag carries `:if={@count > 0}`, so a
  # tag-shaped regex would stop at that `>`).
  defp badge_slots(%{bar: bar}) do
    case Regex.scan(~r/data-role="tasks-filter-badge"\s+class="([^"]+)"/, bar) do
      [[_, classes]] -> slots(classes)
      other -> flunk("expected one tasks-filter-badge class, got #{length(other)}")
    end
  end

  # The Show button's two paints: `if(@count == 0, do: "<disabled>", else:
  # "<enabled>")` right after `data-role="tasks-filter-show"`.
  defp show_slots(%{sheets: sheets}) do
    case Regex.run(
           ~r/data-role="tasks-filter-show"[\s\S]*?do: "([^"]+)",\s*else: "([^"]+)"/,
           sheets
         ) do
      [_, disabled, enabled] -> {slots(enabled), slots(disabled)}
      nil -> flunk("the Show button's paint is not `if(..., do: \"...\", else: \"...\")`")
    end
  end

  # The Project row: {text slot, pressed fill slot, chevron text slot}, read
  # from the row's tag (whose class names `@opt`) and the chevron's tag.
  defp row_slots(%{sheets: sheets}) do
    row = tag_with_role(sheets, "tasks-filter-project-row")

    classes =
      if row =~ "@opt" do
        case Regex.run(~r/@opt "([^"]+)"/, sheets) do
          [_, opt] -> opt
          nil -> flunk("the row's class names @opt, but @opt is not a string")
        end
      else
        case Regex.run(~r/class="([^"]+)"/, row) do
          [_, literal] -> literal
          nil -> flunk("the Project row's class is neither @opt nor a literal")
        end
      end

    list = String.split(classes, ~r/\s+/, trim: true)

    texts =
      for "text-" <> slot <- list,
          slot not in @text_sizes,
          slot not in @text_aligns,
          not String.starts_with?(slot, "["),
          do: slot

    pressed = for "active:bg-" <> slot <- list, do: slot
    assert [text] = texts, "row: expected one text slot, got #{inspect(texts)}"
    assert [press] = pressed, "row: expected one active:bg- slot, got #{inspect(pressed)}"

    chevron = tag_with_role(sheets, "tasks-filter-project-chevron")
    assert chevron =~ "hero-chevron-right"

    [_, chev_classes] = Regex.run(~r/class="([^"]+)"/, chevron)

    chev_texts =
      for "text-" <> slot <- String.split(chev_classes), slot not in @text_sizes, do: slot

    assert [chev] = chev_texts, "chevron: expected one text slot, got #{inspect(chev_texts)}"
    {text, press, chev}
  end

  # ── measurement ────────────────────────────────────────────────────────

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

  # A Tailwind colour slot on a ground slot. `subtle` is painted (alpha over
  # the ground); every other slot is an opaque token.
  defp on(b, "subtle", ground) do
    {r, _} =
      PaintedComposite.contrast_min(
        c(b, "--color-base-content"),
        c(b, "--color-#{ground}"),
        subtle_pct(b)
      )

    r
  end

  defp on(b, ink, ground), do: W.contrast(c(b, "--color-#{ink}"), c(b, "--color-#{ground}"))

  defp pairs(b, sources) do
    {badge_fill, badge_text} = badge_slots(sources)
    {{show_fill, show_text}, {off_fill, off_text}} = show_slots(sources)
    {row_text, row_press, row_chev} = row_slots(sources)

    [
      {"title / base-200", @aa_text, on(b, "base-content", "base-200")},
      {"chip / base-100", @aa_text, on(b, "base-content", "base-100")},
      {"chip x subtle / base-100", @aa_text, on(b, "subtle", "base-100")},
      {"Clear all / base-200", @aa_text, on(b, "base-content", "base-200")},
      {"badge #{badge_text} / #{badge_fill}", @aa_text, on(b, badge_text, badge_fill)},
      {"label subtle / base-100", @aa_text, on(b, "subtle", "base-100")},
      {"option / base-100", @aa_text, on(b, "base-content", "base-100")},
      {"option / base-200 (pressed, hover)", @aa_text, on(b, "base-content", "base-200")},
      {"toggle-on / base-300", @aa_text, on(b, "base-content", "base-300")},
      {"Show #{show_text} / #{show_fill}", @aa_text, on(b, show_text, show_fill)},
      {"disabled #{off_text} / #{off_fill}", @aa_text, on(b, off_text, off_fill)},
      {"placeholder subtle / base-100", @aa_text, on(b, "subtle", "base-100")},
      {"priority / base-200", @aa_text, on(b, "base-content", "base-200")},
      {"priority / base-100", @aa_text, on(b, "base-content", "base-100")},
      {"sponsor box border / base-100", @aa_non_text, on(b, "base-content", "base-100")},
      {"project row #{row_text} / base-100", @aa_text, on(b, row_text, "base-100")},
      {"project row #{row_text} / #{row_press} (pressed, hover)", @aa_text,
       on(b, row_text, row_press)},
      {"project row chevron #{row_chev} / base-100", @aa_non_text, on(b, row_chev, "base-100")}
    ]
  end

  defp f2(r), do: :erlang.float_to_binary(r / 1, decimals: 2)

  # ── contrast ───────────────────────────────────────────────────────────

  test "every pair clears its floor in all ten variants; the table prints",
       %{blocks: blocks, sources: sources} do
    assert length(blocks) == 10

    rows = for b <- blocks, do: {b, pairs(b, sources)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    {tight_label, tight_b, tight_r, tight_floor} =
      for {b, ps} <- rows, {label, floor, r} <- ps do
        {label, b, r, floor}
      end
      |> Enum.min_by(fn {_, _, r, floor} -> r / floor end)

    IO.puts(
      "\nTasks filters AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", fn {_, _, r} -> f2(r) end) <> " |"
        end) <>
        "\nTightest against its floor: #{tight_label} #{f2(tight_r)} (floor #{tight_floor}, " <>
        "#{tight_b.id} #{tight_b.mode})"
    )

    failures =
      for {b, ps} <- rows, {label, floor, r} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f2(r)} < #{floor}"
      end

    assert failures == []
  end

  test "the guard measures the Show, disabled and badge slots the source names",
       %{sources: sources, blocks: [b | _]} do
    assert {{"primary", "primary-content"}, {"base-300", "subtle"}} = show_slots(sources)
    assert {"base-content", "base-100"} = badge_slots(sources)
    labels = b |> pairs(sources) |> Enum.map(&elem(&1, 0))
    assert "Show primary-content / primary" in labels
    assert "disabled subtle / base-300" in labels
    assert "badge base-100 / base-content" in labels

    # The Project row (task 01a168c2): the slots its source names.
    assert {"base-content", "base-200", "subtle"} = row_slots(sources)
    assert "project row base-content / base-100" in labels
    assert "project row base-content / base-200 (pressed, hover)" in labels
    assert "project row chevron subtle / base-100" in labels
  end

  # ── structure ──────────────────────────────────────────────────────────

  test "anti-vacuity: the sources read are the filter components", %{sources: sources} do
    for {_key, source} <- sources, do: assert(byte_size(source) > 0)
    assert sources.bar =~ ~s(data-role="tasks-filter-badge")
    assert sources.sheets =~ ~s(data-role="tasks-filter-show")
    assert sources.desktop =~ ~s(data-role="tasks-filter-popover")
    assert sources.sheets =~ ~s(data-role="tasks-filter-project-row")
    assert sources.sheets =~ ~s(data-role="tasks-filter-project-chevron")
  end

  test "no hover: utility, text-base-content/<n>, hex literal or data-theme selector",
       %{sources: sources} do
    for {key, source} <- sources do
      # Positive controls: each file speaks the vocabulary the refutes scan.
      assert source =~ "class=", "#{key}: no class attribute read"
      assert source =~ "bg-base-100", "#{key}: no bg-base-100 read"

      refute Regex.match?(~r/(^|[\s"'\[])hover:/, source), "#{key}: a hover: utility"
      refute Regex.match?(~r/text-base-content\/\d/, source), "#{key}: text-base-content/<n>"
      refute Regex.match?(~r/#[0-9a-fA-F]{3,8}\b/, source), "#{key}: a hex literal"
      refute source =~ "[data-theme", "#{key}: a [data-theme selector"
    end
  end

  test "the desktop hover is the one plain-CSS block, on named classes" do
    css = File.read!(@app_css_path)

    assert [block] =
             Regex.scan(
               ~r/@media \(hover: hover\) and \(min-width: 1024px\) \{\s*\.tasks-filter-opt:hover,\s*\.tasks-filter-tog:hover \{\s*background-color: var\(--color-base-200\);\s*\}\s*\}/,
               css
             )

    assert block != []
  end

  test "status dots are aria-hidden (decorative; no floor)", %{sources: %{sheets: sheets}} do
    dot = tag_with_role(sheets, "tasks-status-dot")
    assert dot =~ ~s(aria-hidden="true")
  end
end
