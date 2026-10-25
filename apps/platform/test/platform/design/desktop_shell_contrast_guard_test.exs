defmodule Platform.Design.DesktopShellContrastGuardTest do
  @moduledoc """
  Holds the desktop shell's paint (Burrow redesign 22, master-desktop.html)
  in all ten preset variants (Burrow, Midnight, Sand, Forest, High contrast;
  light and dark). Stage 1 is the sidebar; later stages of the rung add the
  list pane, the details panel and the main header to this file.

  ## Pairs and floors (stage 1, the sidebar)

  | pair                                              | floor    |
  |---------------------------------------------------|----------|
  | row label: base-content on base-200               | 4.5      |
  | hover/current label: base-content on base-300     | 4.5      |
  | rest label: --subtle on base-200 (painted)        | 4.5      |
  | current bar: primary on base-300                  | 3        |
  | badge text: primary-content on primary            | 4.5      |
  | badge against the sidebar: primary on base-200    | 3        |
  | live-call dot: success on base-200                | 3        |
  | border-edge on base-200, and on base-100          | recorded |

  ## Pairs and floors (stage 2, the Chat list pane and its popover)

  | pair                                                   | floor |
  |--------------------------------------------------------|-------|
  | row text on the hover/current fill: base-content / base-300 | 4.5 |
  | read excerpt on that fill: --subtle / base-300 (painted)    | 4.5 |
  | unread dot on that fill: primary / base-300                 | 3   |
  | popover text: base-content on base-100                      | 4.5 |
  | popover meta: --subtle on base-100 (painted)                | 4.5 |

  ## Pairs and floors (stage 3, the details panel)

  | pair                                                   | floor    |
  |--------------------------------------------------------|----------|
  | row label: base-content on base-200                    | 4.5      |
  | row label on hover: base-content on base-300           | 4.5      |
  | row meta: --subtle on base-200 (painted)               | 4.5      |
  | selected segment: base-content on base-300             | 4.5      |
  | unselected segment label: --subtle on base-200 (painted) | 4.5    |
  | close icon: --subtle on base-200 (painted)             | 3        |
  | unselected segment border: --edge on base-200          | recorded |

  ## Pairs and floors (stage 4, the main-pane header)

  | pair                                                   | floor    |
  |--------------------------------------------------------|----------|
  | title: base-content on base-100                        | 4.5      |
  | title on hover: base-content on base-300               | 4.5      |
  | subtitle: --subtle on base-100 (painted)               | 4.5      |
  | ghost label (Search, Call): --subtle on base-100 (painted) | 4.5  |
  | pressed Details glyph: primary on base-300             | 3        |
  | ghost border: --edge on base-100                       | recorded |

  `--subtle` is `color-mix(in oklab, base-content N%, transparent)`, alpha
  over the ground, so its pair is PAINTED: the worst pixel
  `Platform.Design.PaintedComposite` allows at the block's declared strength.
  Every other token is opaque and measured with `WcagContrast.contrast/2`.
  `--edge` is a hairline: its ratios print in the table and are NOT claimed
  at 3:1. If a claimed pair fails, change the token, never the floor. The
  table prints.

  ## Structure (anti-vacuity first)

  Every `.sidebar-row*` rule is sliced with `Platform.Design.CssRules` and
  the expected selector set is asserted before any body is read; no body
  carries a colour literal; `--sidebar-width` is 220px, 200px at or below
  1100px.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @sidebar_path Path.expand("../../../lib/platform_web/components/sidebar.ex", __DIR__)
  @chat_list_path Path.expand(
                    "../../../lib/platform_web/live/chat/partials/chat_list.ex",
                    __DIR__
                  )
  @details_panel_path Path.expand(
                        "../../../lib/platform_web/live/chat/partials/details_panel.ex",
                        __DIR__
                      )
  @conversation_path Path.expand(
                       "../../../lib/platform_web/live/chat/partials/conversation.ex",
                       __DIR__
                     )
  @space_sheet_path Path.expand(
                      "../../../lib/platform_web/live/chat/partials/space_sheet.ex",
                      __DIR__
                    )
  @list_popover_path Path.expand(
                       "../../../lib/platform_web/live/chat/partials/list_popover.ex",
                       __DIR__
                     )

  @aa_text 4.5
  @non_text 3.0

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

  @expected_selectors MapSet.new([
                        {[], ".sidebar-row"},
                        {[], ".sidebar-row--current::before"},
                        {[], ".sidebar-row[data-nav-pending]"},
                        {[], ".sidebar-row[data-nav-pending]::before"},
                        {[], ".sidebar-row--current[data-nav-yielded]"},
                        {[], ".sidebar-row--current[data-nav-yielded]::before"},
                        {["@media (prefers-reduced-motion: reduce)"],
                         ".sidebar-row[data-nav-pending]::before"}
                      ])

  @colour_literal ~r/#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(|\boklch\(|\boklab\(|\blab\(|\blch\(|\bhwb\(/

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

    all = CssRules.rules(app_css)
    rules = Enum.filter(all, &String.contains?(&1.selector, "sidebar-row"))

    {:ok, blocks: blocks, rules: rules, all_rules: all, app_css: app_css}
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: Blocks.resolve!(b, token)
  defp ratio(b, ink, ground), do: W.contrast(c(b, ink), c(b, ground))

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

  defp subtle_on(b, ground) do
    {r, _} =
      PaintedComposite.contrast_min(c(b, "--color-base-content"), c(b, ground), subtle_pct(b))

    r
  end

  defp pairs(b) do
    [
      {"row label / base-200", ratio(b, "--color-base-content", "--color-base-200"), @aa_text},
      {"hover+current label / base-300", ratio(b, "--color-base-content", "--color-base-300"),
       @aa_text},
      {"rest label (subtle) / base-200 (painted)", subtle_on(b, "--color-base-200"), @aa_text},
      {"current bar primary / base-300", ratio(b, "--color-primary", "--color-base-300"),
       @non_text},
      {"badge text / primary", ratio(b, "--color-primary-content", "--color-primary"), @aa_text},
      {"badge primary / base-200", ratio(b, "--color-primary", "--color-base-200"), @non_text},
      {"live dot success / base-200", ratio(b, "--color-success", "--color-base-200"), @non_text}
    ]
  end

  defp recorded(b) do
    [
      {"edge / base-200 (recorded)", ratio(b, "--edge", "--color-base-200")},
      {"edge / base-100 (recorded)", ratio(b, "--edge", "--color-base-100")}
    ]
  end

  defp list_pairs(b) do
    [
      {"list row text / base-300", ratio(b, "--color-base-content", "--color-base-300"),
       @aa_text},
      {"list excerpt (subtle) / base-300 (painted)", subtle_on(b, "--color-base-300"), @aa_text},
      {"unread dot primary / base-300", ratio(b, "--color-primary", "--color-base-300"),
       @non_text},
      {"popover text / base-100", ratio(b, "--color-base-content", "--color-base-100"), @aa_text},
      {"popover meta (subtle) / base-100 (painted)", subtle_on(b, "--color-base-100"), @aa_text}
    ]
  end

  defp details_pairs(b) do
    [
      {"panel label / base-200", ratio(b, "--color-base-content", "--color-base-200"), @aa_text},
      {"panel label / base-300 (hover)", ratio(b, "--color-base-content", "--color-base-300"),
       @aa_text},
      {"panel meta (subtle) / base-200 (painted)", subtle_on(b, "--color-base-200"), @aa_text},
      {"selected seg / base-300", ratio(b, "--color-base-content", "--color-base-300"), @aa_text},
      {"unselected seg (subtle) / base-200 (painted)", subtle_on(b, "--color-base-200"),
       @aa_text},
      {"close icon (subtle) / base-200 (painted)", subtle_on(b, "--color-base-200"), @non_text}
    ]
  end

  defp head_pairs(b) do
    [
      {"title / base-100", ratio(b, "--color-base-content", "--color-base-100"), @aa_text},
      {"title / base-300 (hover)", ratio(b, "--color-base-content", "--color-base-300"),
       @aa_text},
      {"subtitle (subtle) / base-100 (painted)", subtle_on(b, "--color-base-100"), @aa_text},
      {"ghost label (subtle) / base-100 (painted)", subtle_on(b, "--color-base-100"), @aa_text},
      {"pressed Details glyph primary / base-300",
       ratio(b, "--color-primary", "--color-base-300"), @non_text}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  defp print_and_check(title, rows) do
    {_, first} = hd(rows)
    labels = Enum.map(first, &elem(&1, 0))

    IO.puts(
      "\n#{title}:\n| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", fn {_, r, _} -> f4(r) end) <> " |"
        end)
    )

    minima =
      for {label, _, floor} <- first do
        min =
          rows
          |> Enum.map(fn {_, ps} -> ps |> Enum.find(&(elem(&1, 0) == label)) |> elem(1) end)
          |> Enum.min()

        "#{label}: min #{f4(min)} (floor #{floor})"
      end

    IO.puts("Minima across the ten variants:\n" <> Enum.join(minima, "\n"))

    for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
      "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
    end
  end

  # ── contrast ───────────────────────────────────────────────────────────

  test "every claimed pair clears its floor in all ten variants; the table prints",
       %{blocks: blocks} do
    assert length(blocks) == 10

    rows = for b <- blocks, do: {b, pairs(b), recorded(b)}
    {_, first, first_rec} = hd(rows)
    labels = Enum.map(first, &elem(&1, 0)) ++ Enum.map(first_rec, &elem(&1, 0))

    IO.puts(
      "\nDesktop shell (sidebar) AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps, rec} ->
          "| #{b.id} #{b.mode} | " <>
            Enum.map_join(ps, " | ", fn {_, r, _} -> f4(r) end) <>
            " | " <> Enum.map_join(rec, " | ", fn {_, r} -> f4(r) end) <> " |"
        end)
    )

    minima =
      for {label, _, floor} <- first do
        min =
          rows
          |> Enum.map(fn {_, ps, _} -> ps |> Enum.find(&(elem(&1, 0) == label)) |> elem(1) end)
          |> Enum.min()

        "#{label}: min #{f4(min)} (floor #{floor})"
      end

    IO.puts("Minima across the ten variants:\n" <> Enum.join(minima, "\n"))

    failures =
      for {b, ps, _} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  test "stage 2: the list pane and popover pairs clear their floors in all ten variants",
       %{blocks: blocks} do
    assert length(blocks) == 10
    rows = for b <- blocks, do: {b, list_pairs(b)}

    assert print_and_check(
             "Desktop shell (Chat list pane + popover) AA table (WCAG 2.x; painted rows on the worst pixel)",
             rows
           ) == []
  end

  test "stage 2: the list pane paints what the table measures, at the masters widths" do
    list = File.read!(@chat_list_path)
    pop = File.read!(@list_popover_path)

    # Anti-vacuity: the classes the pairs above stand for are really painted.
    for token <- ~w(lg:hover:bg-base-300 bg-base-300 bg-primary text-subtle text-base-content) do
      assert list =~ token, "chat_list.ex does not paint #{token} (stale pair?)"
    end

    for token <- ~w(bg-base-100 border-edge text-base-content text-subtle) do
      assert pop =~ token, "list_popover.ex does not paint #{token} (stale pair?)"
    end

    # master-desktop.html L46 + L563: 280px, 240px at or below 1100px, with
    # the right hairline.
    assert list =~
             "lg:w-[280px] lg:max-[1100px]:w-[240px] lg:flex-none lg:border-r lg:border-edge"

    # Hover is desktop only: every hover in the popover is `lg:hover:`.
    refute pop =~ ~r/(?<!lg:)hover:/

    text_classes =
      Regex.scan(~r/(?<![\w-])text-(?!xs\b|sm\b|left\b|base(?!-)|\[)[a-z][\w-]*/, pop)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    assert text_classes == ["text-base-content", "text-subtle"]
    refute pop =~ @colour_literal
    refute list =~ @colour_literal
  end

  test "stage 3: the details panel pairs clear their floors in all ten variants; edge recorded",
       %{blocks: blocks} do
    assert length(blocks) == 10
    rows = for b <- blocks, do: {b, details_pairs(b)}

    assert print_and_check(
             "Desktop shell (details panel) AA table (WCAG 2.x; painted rows on the worst pixel)",
             rows
           ) == []

    IO.puts(
      "Details panel unselected segment border (recorded, not claimed):\n" <>
        Enum.map_join(blocks, "\n", fn b ->
          "| #{b.id} #{b.mode} | edge / base-200 #{f4(ratio(b, "--edge", "--color-base-200"))} |"
        end)
    )
  end

  test "stage 3: the details panel paints what the table measures, at the masters widths" do
    panel = File.read!(@details_panel_path)
    sheet = File.read!(@space_sheet_path)

    # Anti-vacuity: the classes the pairs above stand for are really painted.
    for token <-
          ~w(bg-base-200 lg:hover:bg-base-300 text-base-content text-subtle border-edge border-b) do
      assert panel =~ token, "details_panel.ex does not paint #{token} (stale pair?)"
    end

    # The panel's segment paint (in the shared sections, space_sheet.ex):
    # selected base-300 (transparent border), rest on the --edge hairline.
    assert sheet =~ ~s(do: "border-transparent bg-base-300 text-base-content")
    assert sheet =~ "DetailsPanel.paint(:seg_rest)"

    assert panel =~
             ~s|def paint(:seg_rest), do: "border-edge text-subtle lg:hover:text-base-content"|

    # master-desktop.html L59 + L30 + L563: 320px, 280px at or below 1100px,
    # base-200 with the left hairline.
    assert panel =~
             "bg-base-200 lg:flex lg:w-[320px] lg:max-[1100px]:w-[280px] lg:flex-none lg:border-l lg:border-edge"

    # Hover is desktop only: every hover in the panel is `lg:hover:`, and
    # the shared sections file (the phone sheet's) carries none.
    refute panel =~ ~r/(?<!lg:)hover:/
    refute sheet =~ "hover:"

    text_classes =
      Regex.scan(~r/(?<![\w-])text-(?!xs\b|sm\b|left\b|base(?!-)|\[)[a-z][\w-]*/, panel)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    assert text_classes == ["text-base-content", "text-subtle"]
    refute panel =~ @colour_literal
  end

  test "stage 4: the main-pane header pairs clear their floors in all ten variants; edge recorded",
       %{blocks: blocks} do
    assert length(blocks) == 10
    rows = for b <- blocks, do: {b, head_pairs(b)}

    assert print_and_check(
             "Desktop shell (main-pane header) AA table (WCAG 2.x; painted rows on the worst pixel)",
             rows
           ) == []

    IO.puts(
      "Main-pane header ghost border (recorded, not claimed):\n" <>
        Enum.map_join(blocks, "\n", fn b ->
          "| #{b.id} #{b.mode} | edge / base-100 #{f4(ratio(b, "--edge", "--color-base-100"))} |"
        end)
    )
  end

  test "stage 4: the main-pane header paints what the table measures" do
    source = File.read!(@conversation_path)

    # Only `space_header/1` (sliced before read, so a match elsewhere in the
    # file cannot stand in for it), and inside it the desktop branch.
    [_, header] = String.split(source, "  def space_header(assigns) do", parts: 2)
    [header | _] = String.split(header, "\n  attr(", parts: 2)
    [_, desktop] = String.split(header, ~s(data-role="main-head"), parts: 2)
    [desktop | _] = String.split(desktop, "<%!-- Phone Call", parts: 2)

    [_, ghost] = String.split(source, "defp ghost_class,", parts: 2)
    [ghost | _] = String.split(ghost, "\n\n", parts: 2)

    # Anti-vacuity: the classes the pairs above stand for are really painted.
    for token <- ~w(text-base-content lg:hover:bg-base-300 text-subtle bg-base-300 text-primary) do
      assert desktop =~ token, "the desktop header does not paint #{token} (stale pair?)"
    end

    for token <-
          ~w(border-edge text-subtle lg:hover:bg-base-300 lg:hover:text-base-content h-[30px]) do
      assert ghost =~ token, "the ghost button does not paint #{token}"
    end

    # The bar itself: 52px, base-100, the --edge hairline (masters .mhead).
    assert header =~ "lg:h-[52px] lg:gap-2 lg:border-edge lg:bg-base-100 lg:px-4"

    # Hover is desktop only, and text is base-content or subtle; primary only
    # on the pressed Details glyph (and the phone Call icon, unchanged).
    refute desktop <> ghost =~ ~r/(?<!lg:)hover:/

    text_classes =
      Regex.scan(
        ~r/(?<![\w-])text-(?!xs\b|sm\b|left\b|base(?!-)|\[)[a-z][\w-]*/,
        desktop <> ghost
      )
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    assert text_classes == ["text-base-content", "text-primary", "text-subtle"]
    assert desktop =~ ~s(do: "bg-base-300 text-primary")
    refute desktop <> ghost =~ @colour_literal
  end

  # ── structure ──────────────────────────────────────────────────────────

  test "the sidebar row's rules are exactly the expected set (sliced before read)",
       %{rules: rules} do
    got = MapSet.new(rules, &{&1.at, &1.selector})
    assert got == @expected_selectors
    assert Enum.all?(rules, &(String.trim(&1.body) != ""))
  end

  test "no sidebar rule body holds a colour literal", %{rules: rules} do
    assert length(rules) >= MapSet.size(@expected_selectors)

    offenders =
      for r <- rules, Regex.match?(@colour_literal, r.body), do: {r.selector, String.trim(r.body)}

    assert offenders == []
  end

  test "--sidebar-width is 220px, and 200px at or below 1100px", %{all_rules: all} do
    root = Enum.filter(all, &(&1.selector == ":root" and &1.body =~ "--sidebar-width"))
    assert [%{at: []} = wide] = Enum.filter(root, &(&1.at == []))
    assert wide.body =~ ~r/--sidebar-width:\s*220px;/

    assert [narrow] = Enum.filter(root, &(&1.at == ["@media (max-width: 1100px)"]))
    assert narrow.body =~ ~r/--sidebar-width:\s*200px;/
  end

  test "the component paints only the measured tokens, text in base-content or subtle",
       %{} do
    src = File.read!(@sidebar_path)

    # The pairs above measure exactly these; a new paint needs a new pair.
    for token <-
          ~w(bg-base-200 bg-base-300 text-base-content text-subtle bg-primary text-primary-content bg-success border-edge) do
      assert src =~ token, "#{token} not painted (stale pair?)"
    end

    text_classes =
      Regex.scan(~r/(?<![\w-])text-(?!xs\b|sm\b|left\b|base(?!-)|\[)[a-z][\w-]*/, src)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    assert text_classes == ["text-base-content", "text-primary-content", "text-subtle"]
  end
end
