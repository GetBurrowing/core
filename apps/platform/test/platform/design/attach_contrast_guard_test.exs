defmodule Platform.Design.AttachContrastGuardTest do
  @moduledoc """
  Holds the composer attach surfaces' paint (redesign rung 11, task
  01a1557a-9de3: the staged tray, the phone ＋ sheet, the desktop popover and
  the drop target) in all ten preset variants (Burrow, Midnight, Sand,
  Forest, High contrast; light and dark). Same method as the rung 14 / 15b
  guards: tokens from app.css and theme_presets.css, `--subtle` painted on
  the worst pixel `PaintedComposite` allows, every other token opaque.
  Sources: `Partials.Attach`, `hooks/attach_sheet.js`,
  `hooks/drag_drop_upload.js` and `attach_stage.js`.

  ## Pairs and floors

  | pair                                                           | floor |
  |----------------------------------------------------------------|-------|
  | file chip name: base-content on base-300                       | 4.5   |
  | file chip size and type: --subtle on base-300 (painted)         | 4.5   |
  | tray refusal line (TOO LARGE, validation): base-content on base-200 | 4.5 |
  | sheet rows: base-content on base-200; pressed on base-100      | 4.5   |
  | 'Recent canvases' and 'Edited …': --subtle on base-200 (painted) | 4.5 |
  | tile labels (Camera, Library): --subtle on base-100 (painted)  | 4.5   |
  | popover rows: base-content on base-200; desktop hover on base-300 | 4.5 |
  | selection badge: its text slot on its fill slot (from source)  | 4.5   |
  | 'Attach N items': its text slot on its fill slot (from source) | 4.5   |
  | drop label: base-content on base-200; sub-line --subtle (painted) | 4.5 |
  | toast: base-100 on base-content                                | 4.5   |
  | failed outline: error on base-200 and on base-300 (non-text)   | 3.0   |

  The badge and 'Attach N items' paint their own fill, so the guard reads
  both slots from their classes in source and measures THAT pair.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.PaintedComposite
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.WcagContrast, as: W

  @root Path.expand("../../..", __DIR__)
  @app_css_path Path.join(@root, "assets/css/app.css")
  @presets_path Path.join(@root, "assets/css/theme_presets.css")

  @sources %{
    attach: "lib/platform_web/live/chat/partials/attach.ex",
    sheet_js: "assets/js/hooks/attach_sheet.js",
    drop_js: "assets/js/hooks/drag_drop_upload.js",
    stage_js: "assets/js/attach_stage.js"
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
    {"high-contrast", "dark"},
    {"sage", "light"},
    {"sage", "dark"}
  ]

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/
  @text_sizes ~w(xs sm base lg xl 2xl 3xl)

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

    sources = Map.new(@sources, fn {k, f} -> {k, File.read!(Path.join(@root, f))} end)
    {:ok, blocks: blocks, sources: sources}
  end

  # {fill slot, text slot} named by a class string.
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

  defp badge_slots(%{sheet_js: js}) do
    case Regex.run(~r/const BADGE_ON =\s*"([^"]+)"/, js) do
      [_, classes] -> slots(classes)
      nil -> flunk("attach_sheet.js has no BADGE_ON class string")
    end
  end

  defp attach_go_slots(%{attach: src}) do
    case Regex.run(~r/id="attach-go"\s+class="([^"]+)"/, src) do
      [_, classes] -> slots(classes)
      nil -> flunk("attach.ex has no #attach-go class")
    end
  end

  defp c(b, token), do: ThemeBlockAssertions.resolve!(b, token)

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

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
    {go_fill, go_text} = attach_go_slots(sources)

    [
      {"chip name / base-300", @aa_text, on(b, "base-content", "base-300")},
      {"chip meta subtle / base-300", @aa_text, on(b, "subtle", "base-300")},
      {"tray refusal / base-200", @aa_text, on(b, "base-content", "base-200")},
      {"sheet row / base-200", @aa_text, on(b, "base-content", "base-200")},
      {"sheet row pressed / base-100", @aa_text, on(b, "base-content", "base-100")},
      {"Recent canvases subtle / base-200", @aa_text, on(b, "subtle", "base-200")},
      {"tile label subtle / base-100", @aa_text, on(b, "subtle", "base-100")},
      {"popover row / base-200", @aa_text, on(b, "base-content", "base-200")},
      {"popover hover / base-300", @aa_text, on(b, "base-content", "base-300")},
      {"badge #{badge_text} / #{badge_fill}", @aa_text, on(b, badge_text, badge_fill)},
      {"Attach #{go_text} / #{go_fill}", @aa_text, on(b, go_text, go_fill)},
      {"drop label / base-200", @aa_text, on(b, "base-content", "base-200")},
      {"drop sub subtle / base-200", @aa_text, on(b, "subtle", "base-200")},
      {"toast base-100 / base-content", @aa_text, on(b, "base-100", "base-content")},
      {"error outline / base-200", @aa_non_text, on(b, "error", "base-200")},
      {"error outline / base-300", @aa_non_text, on(b, "error", "base-300")}
    ]
  end

  defp f2(r), do: :erlang.float_to_binary(r / 1, decimals: 2)

  test "every pair clears its floor in all ten variants; the table prints",
       %{blocks: blocks, sources: sources} do
    assert length(blocks) == 12

    rows = for b <- blocks, do: {b, pairs(b, sources)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    {tight_label, tight_b, tight_r, tight_floor} =
      for {b, ps} <- rows, {label, floor, r} <- ps do
        {label, b, r, floor}
      end
      |> Enum.min_by(fn {_, _, r, floor} -> r / floor end)

    IO.puts(
      "\nAttach surfaces AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
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

  test "the guard measures the badge and Attach slots the source names", %{sources: sources} do
    assert {"base-content", "base-100"} = badge_slots(sources)
    assert {"primary", "primary-content"} = attach_go_slots(sources)
  end

  test "anti-vacuity: the sources read are the attach surfaces", %{sources: s} do
    assert s.attach =~ ~s(data-role="staged-tray")
    assert s.attach =~ ~s(id="attach-sheet")
    assert s.attach =~ ~s(id="attach-popover")
    assert s.attach =~ "Drop to attach"
    assert s.drop_js =~ "drop-target"
    assert s.stage_js =~ "bg-base-content"
  end

  test "the surfaces paint the slots this guard measures", %{sources: s} do
    # The drop card, the file chip, the sheet panel and the popover.
    assert s.attach =~ "border-dashed border-edge bg-base-200"
    assert s.attach =~ "font-semibold text-base-content"
    assert s.attach =~ ~s(text-[13px] text-subtle">lands in the composer)
    assert s.attach =~ "bg-base-300"
    assert s.attach =~ "bg-base-200"
    assert s.attach =~ "outline-error"

    assert File.read!(@app_css_path) =~
             ~r/\.attach-sheet \.sheet-panel \{\s*background: var\(--color-base-200\);/
  end

  test "no phone hover:, text-base-content/<n>, text-error text or hex literal", %{sources: s} do
    for {key, source} <- s do
      assert source =~ ~r/class=|className|classList/, "#{key}: no class read (positive control)"
      refute Regex.match?(~r/(^|[\s"'\[])hover:/, source), "#{key}: a phone hover: utility"
      refute Regex.match?(~r/text-base-content\/\d/, source), "#{key}: text-base-content/<n>"
      refute Regex.match?(~r/#[0-9a-fA-F]{3,8}\b/, source), "#{key}: a hex literal"
    end

    # The error hue only ever paints an icon or an outline, never words: each
    # `text-error` sits on an icon element.
    # (A backquoted `text-error` is prose in a comment.)
    for line <- String.split(s.attach, "\n"),
        line =~ "text-error" and not (line =~ "`text-error`") do
      assert line =~ ~r/icon|<span class="flex size-8/, "text-error on non-icon: #{line}"
    end
  end
end
