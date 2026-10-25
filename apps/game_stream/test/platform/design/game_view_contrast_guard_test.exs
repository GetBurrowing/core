defmodule Platform.Design.GameViewContrastGuardTest do
  @moduledoc """
  Holds the Game view (Burrow redesign rung 21, task 01a1557a-efdd stage 2,
  `PlatformWeb.GameViewLive`) in all ten preset variants (Burrow, Midnight,
  Sand, Forest, High contrast; light and dark). Reads core's
  `apps/platform/assets/css/app.css` and `theme_presets.css` with
  `Platform.Design.ThemeBlocks`, and Play's `assets/css/game_stream.css`.

  ## Pairs and floors

  | pair                                                                   | floor |
  |------------------------------------------------------------------------|-------|
  | top bar title, glyphs: on-viewer on stage                              | 4.5   |
  | sub line, status line: on-viewer/70 painted on stage                   | 4.5   |
  | caption: on-viewer/70 on shade painted over stage                      | 4.5   |
  | build pill: on-viewer on on-viewer/10 painted over stage               | 4.5   |
  | tab label (selected): base-content on base-300                         | 4.5   |
  | tab label (unselected): subtle on base-100                             | 4.5   |
  | Settings segment (pressed): base-content on base-300 (stage 3)         | 4.5   |
  | Settings segment (unpressed): subtle on base-100 (stage 3)             | 4.5   |
  | Insights tile value: base-content on base-200 (stage 3)                | 4.5   |
  | Insights tile label: subtle on base-200 (stage 3)                      | 4.5   |
  | sparkline strokes: success, warning on base-200 (stage 3)              | 3     |
  | Review vote pressed border: primary on base-200 (stage 4)              | 3     |
  | Review send label: primary-content on primary (stage 4)                | 4.5   |
  | Review note input text: base-content on base-200 (stage 4)             | 4.5   |
  | Review note placeholder: subtle on base-200 (stage 4)                  | 4.5   |

  The node in stage chrome re-points its own subtle text at on-viewer 70%
  over the stage (game_stream.css), so the sub-line row also holds it.

  Translucent paints go through `Platform.Design.PaintedComposite.envelope/3`,
  the worst pixel any measured formula paints. Its corpus was measured at
  55/57/60%; 70% (the /70 text) and 10% (the pill) and the shade's 50/70% are
  unmeasured strengths, so this guard calls `envelope/3` directly, as the
  stage-1 game card guard does.

  ## Structure (anti-vacuity first)

  The Game view's rules in game_stream.css are SLICED with
  `Platform.Design.CssRules`, the expected selector set is asserted and their
  bodies are checked for no colour literal before any ratio is read; the
  LiveView source is checked to paint with the slots measured here.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules
  alias Platform.Design.PaintedComposite, as: P
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.WcagContrast, as: W

  @core_css Path.expand("../../../../platform/assets/css", __DIR__)
  @play_css Path.expand("../../../assets/css/game_stream.css", __DIR__)
  @live_view Path.expand("../../../lib/platform_web/live/game_view_live.ex", __DIR__)

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

  @landscape "@media (orientation: landscape) and (max-height: 500px)"

  @expected_selectors MapSet.new([
                        {[], ".game-view"},
                        {[], ~s(.game-stream-frame[data-gs-chrome="stage"])},
                        {[],
                         ~s|.game-stream-frame[data-gs-chrome="stage"] :is([data-gs-overflow-menu], [data-gs-sheet])|},
                        {[], ".game-stage.game-stage--fill"},
                        {[], ".game-stage.game-stage--fill .game-stream-frame"},
                        {[], ".game-stage.game-stage--fill [data-gs-well]"},
                        {[@landscape], ".game-view [data-game-landscape-hide]"},
                        {[@landscape], ".game-view .game-stage-column"},
                        {[@landscape], ".game-view .game-stage-box"},
                        {[@landscape], ".game-view .game-stage"},
                        {[@landscape], ".game-view .game-stage .game-stream-frame"},
                        {[@landscape], ".game-view .game-stage [data-gs-well]"}
                      ])

  @colour_literal ~r/#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(|\boklch\(|\boklab\(|\blab\(|\blch\(|\bhwb\(/

  setup_all do
    app_css = File.read!(Path.join(@core_css, "app.css"))
    presets = File.read!(Path.join(@core_css, "theme_presets.css"))

    by_key =
      Map.new(Blocks.preset_blocks(presets), &{{&1.id, &1.mode}, &1})
      |> Map.put({"burrow", "light"}, Blocks.burrow_block(app_css, "light"))
      |> Map.put({"burrow", "dark"}, Blocks.burrow_block(app_css, "dark"))

    blocks =
      for {id, mode} = key <- @variants do
        Map.get(by_key, key) || flunk("no #{id} #{mode} block")
      end

    rules =
      @play_css
      |> File.read!()
      |> CssRules.rules()
      |> Enum.filter(&(&1.selector =~ ~r/game-view|game-stage|data-gs-chrome/))

    {:ok, blocks: blocks, rules: rules, source: File.read!(@live_view)}
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: Blocks.resolve!(b, token)
  defp bytes(color), do: P.bytes(color)
  defp color(bytes), do: P.from_bytes(bytes)

  defp shade_alpha_pct(b) do
    value = Blocks.declaration(b.decls, "--shade") || flunk("#{b.id} #{b.mode}: no --shade")

    case Regex.run(~r/^rgba\(\s*0,\s*0,\s*0,\s*([\d.]+)\s*\)$/, value) do
      [_, a] -> round(String.to_float(a) * 100)
      nil -> flunk("#{b.id} #{b.mode}: --shade is #{inspect(value)}; teach the guard to paint it")
    end
  end

  # `ink` at `pct`% painted over the opaque `ground` bytes: the worst pixel.
  defp paint(ink, ground, pct), do: P.envelope(bytes(ink), ground, pct)

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/

  # --subtle is base-content at N% over the ground: painted, worst pixel.
  defp subtle_on_base_100(b), do: subtle_on(b, "--color-base-100")

  defp subtle_on(b, ground_token) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    pct =
      case Regex.run(@subtle_form, value) do
        [_, n] ->
          String.to_integer(n)

        nil ->
          flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
      end

    ground = bytes(c(b, ground_token))
    W.contrast(color(paint(c(b, "--color-base-content"), ground, pct)), color(ground))
  end

  defp pairs(b) do
    stage = bytes(c(b, "--stage"))
    on_viewer = c(b, "--on-viewer")
    shade_ground = P.envelope({0, 0, 0}, stage, shade_alpha_pct(b))
    pill_ground = paint(on_viewer, stage, 10)

    [
      {"on-viewer / stage", W.contrast(on_viewer, color(stage)), @aa_text},
      {"on-viewer/70 / stage", W.contrast(color(paint(on_viewer, stage, 70)), color(stage)),
       @aa_text},
      {"caption on-viewer/70 / shade over stage",
       W.contrast(color(paint(on_viewer, shade_ground, 70)), color(shade_ground)), @aa_text},
      {"pill on-viewer / on-viewer/10 over stage", W.contrast(on_viewer, color(pill_ground)),
       @aa_text},
      {"tab base-content / base-300",
       W.contrast(c(b, "--color-base-content"), c(b, "--color-base-300")), @aa_text},
      {"tab subtle / base-100 (painted)", subtle_on_base_100(b), @aa_text},
      {"segment pressed base-content / base-300",
       W.contrast(c(b, "--color-base-content"), c(b, "--color-base-300")), @aa_text},
      {"segment unpressed subtle / base-100 (painted)", subtle_on_base_100(b), @aa_text},
      {"tile value base-content / base-200",
       W.contrast(c(b, "--color-base-content"), c(b, "--color-base-200")), @aa_text},
      {"tile label subtle / base-200 (painted)", subtle_on(b, "--color-base-200"), @aa_text},
      {"spark success / base-200", W.contrast(c(b, "--color-success"), c(b, "--color-base-200")),
       @non_text},
      {"spark warning / base-200", W.contrast(c(b, "--color-warning"), c(b, "--color-base-200")),
       @non_text},
      {"vote pressed border primary / base-200",
       W.contrast(c(b, "--color-primary"), c(b, "--color-base-200")), @non_text},
      {"send primary-content / primary",
       W.contrast(c(b, "--color-primary-content"), c(b, "--color-primary")), @aa_text},
      {"note input base-content / base-200",
       W.contrast(c(b, "--color-base-content"), c(b, "--color-base-200")), @aa_text},
      {"note placeholder subtle / base-200 (painted)", subtle_on(b, "--color-base-200"), @aa_text}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  # ── structure (anti-vacuity first) ─────────────────────────────────────

  test "the Game view's rules are exactly the expected set", %{rules: rules} do
    assert MapSet.new(rules, &{&1.at, &1.selector}) == @expected_selectors
    assert Enum.all?(rules, &(String.trim(&1.body) != ""))
  end

  test "their bodies hold no colour literal; the stage chrome re-points at on-viewer",
       %{rules: rules} do
    offenders =
      for r <- rules, Regex.match?(@colour_literal, r.body), do: {r.selector, String.trim(r.body)}

    assert offenders == []

    stage = Enum.find(rules, &(&1.selector == ~s(.game-stream-frame[data-gs-chrome="stage"])))
    flat = stage.body |> String.split() |> Enum.join(" ")
    assert flat =~ "--color-base-content: var(--on-viewer);"
    assert flat =~ "--subtle: color-mix(in oklab, var(--on-viewer) 70%, transparent);"
  end

  # The class tokens of the ONE element whose data-role is `role` (stage 3:
  # anchored per element, so a check cannot pass on a sibling's identical
  # class run, which is how stage 2's R23 survived).
  defp classes_of(src, role) do
    matches = Regex.scan(~r/data-role="#{Regex.escape(role)}"[^>]*?\bclass="([^"]*)"/s, src)

    assert [[_, classes]] = matches,
           "expected one element data-role=#{role}, got #{length(matches)}"

    classes |> String.split() |> MapSet.new()
  end

  defp assert_paints(src, role, expected, forbidden) do
    have = classes_of(src, role)

    for cls <- expected,
        do: assert(MapSet.member?(have, cls), "#{role} lacks #{cls}: #{inspect(have)}")

    for cls <- forbidden,
        do: refute(MapSet.member?(have, cls), "#{role} carries #{cls}")
  end

  @off_slot ~w(text-subtle text-base-content text-base-content/70)

  test "the markup paints with the measured slots", %{source: src} do
    assert src =~ "bg-stage text-on-viewer"
    assert_paints(src, "game-sub", ~w(text-xs text-on-viewer/70), @off_slot)
    assert_paints(src, "game-status", ~w(text-sm text-on-viewer/70), @off_slot)
    assert_paints(src, "game-caption", ~w(bg-shade text-xs text-on-viewer/70), @off_slot)
    assert_paints(src, "game-caption-desktop", ~w(bg-shade text-xs text-on-viewer/70), @off_slot)
    assert_paints(src, "game-build", ~w(bg-on-viewer/10 text-on-viewer), @off_slot)
    assert src =~ ~s(do: "border-base-300 bg-base-300 text-base-content")
    assert src =~ ~s(else: "border-edge text-subtle")
    assert src =~ "bg-base-100 text-base-content"
  end

  test "Settings and Insights paint with the measured slots (stage 3)", %{source: src} do
    assert src =~ ~s(@seg_pressed "border-base-300 bg-base-300 text-base-content")
    assert src =~ ~s(@seg_unpressed "border-edge text-subtle")
    assert src =~ ~s(defp tile_class, do: "rounded-sm border border-edge bg-base-200 px-2.5 py-2")

    assert src =~
             ~s(defp tile_value_class, do: "block text-[17px] font-semibold text-base-content")

    assert length(Regex.scan(~r/<span class="text-xs text-subtle">/, src)) == 3
    assert src =~ ~s(stroke="stroke-success")
    assert src =~ ~s(stroke="stroke-warning")
    assert src =~ ~s(<polyline points={@points} fill="none" class={@stroke})
    assert src =~ "border border-edge bg-base-200 lg:h-[60px]"
  end

  test "Review paints with the measured slots (stage 4)", %{source: src} do
    assert src =~ ~s(@vote_pressed "border-primary bg-primary/15")
    assert src =~ ~s(@vote_unpressed "border-edge")
    assert src =~ ~s(rounded-field border bg-base-200 text-lg)

    assert_paints(
      src,
      "game-note-input",
      ~w(border-edge bg-base-200 text-base-content placeholder:text-subtle),
      ~w(text-subtle)
    )

    assert_paints(
      src,
      "game-note-send",
      ~w(bg-primary text-primary-content),
      ~w(text-base-content text-subtle)
    )

    assert_paints(src, "game-notes-empty", ~w(text-subtle text-sm), ~w(text-base-content))
    assert_paints(src, "game-note", ~w(text-base-content border-edge), ~w(text-subtle))
    assert_paints(src, "game-note-small", ~w(text-xs text-subtle), ~w(text-base-content))
  end

  # ── contrast ───────────────────────────────────────────────────────────

  test "every pair clears its floor in all ten variants; the table prints", %{blocks: blocks} do
    assert length(blocks) == 10

    rows = for b <- blocks, do: {b, pairs(b)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    IO.puts(
      "\nGame view AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | stage | shade a | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|---|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | #{W.to_hex(c(b, "--stage"))} | #{shade_alpha_pct(b)}% | " <>
            Enum.map_join(ps, " | ", fn {_, r, _} -> f4(r) end) <> " |"
        end)
    )

    minima =
      for label <- labels do
        min =
          rows
          |> Enum.map(fn {_, ps} -> ps |> List.keyfind(label, 0) |> elem(1) end)
          |> Enum.min()

        "#{label}: #{f4(min)}"
      end

    IO.puts("Minima: " <> Enum.join(minima, "; "))

    failures =
      for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end
end
