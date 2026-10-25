defmodule Platform.Design.UnderGlassContrastGuardTest do
  @moduledoc """
  The phone chrome's own ink, on glass, over whatever scrolls under it (task
  01a15f2e-80cd-7000-8990-3b721f8bd938 stage 4; Saru's canvas
  01a15f2f-5a5f-7000-8d85-1e9717443a8b, rules "Glass contrast" and
  "Under-glass text").

  Since stage 3 the chat timeline runs under the glass composer and the glass
  tab bar, so message text, images and accent bubbles sit behind them. Rung
  4's bar guard (`bottom_nav_glass_guard_test.exs`) measured the bar over
  #000 and #fff only. This guard measures the bar, the phone composer pill
  and the glass typing band over EVERY underlay the sweep painted: #000,
  #fff, the variant's base-content (body text), base-100 (the timeline
  ground), primary (accent bubbles) and its ten agent accents
  (`--ag-teal` .. `--ag-lime`). Each is a full-width FLAT patch, which is
  stricter than glyphs or an image behind an 18px blur: blur only averages a
  patterned underlay toward its mean.

  Read through `Platform.Design.PaintedGlass.under_*` from
  `test/support/fixtures/painted_glass/underlay_chrome{151,147}.csv`. Every
  ratio is between two PAINTED bytes; nothing is derived, and blur counts for
  nothing. Each variant is checked at its DECLARED `--glass-alpha`, read from
  the theme blocks (`Platform.Design.ThemeBlocks`), on both builds.

  Floors (Saru: measure on the WORST underlay; if the alpha cannot reach the
  floor, raise the alpha and never drop the requirement):

  | layer                      | ground     | floor |
  |----------------------------|------------|-------|
  | inactive / active label    | bar glass  | 4.5   |
  | placeholder (`--subtle`)   | pill glass | 4.5   |
  | typed text (base-content)  | pill glass | 4.5   |
  | typing indicator text      | band glass | 4.5   |
  | inactive / active tab icon | bar glass  | 3     |
  | More dot                   | bar glass  | 3     |
  | attach icon                | pill glass | 3     |
  | chip text (base-content)   | chip fill (base-300, opaque) | 4.5 |
  | mention list name / subtle | list glass (= pill glass) | 4.5 |
  | mention list name / subtle | highlight (base-100, opaque) | 4.5 |

  The rich composer field (redesign rung 10) paints its placeholder and the
  resting Send icon with the placeholder's own ink, asserted below, so the
  placeholder row covers both.

  High contrast's 7:1 for the TAB LABELS stays in the bar guard (binding).
  Its 7:1 for the placeholder, and the enabled send button's fill against the
  pill glass (rung 10's cyan literal), are printed as advisory only.

  Message text passing UNDER the glass has no floor here (Saru's
  "Under-glass text": it scrolls into clear view).
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules
  alias Platform.Design.PaintedComposite, as: PC
  alias Platform.Design.PaintedGlass, as: G
  alias Platform.Design.ThemeBlocks, as: TB
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)

  @variants [
    "burrow light",
    "burrow dark",
    "burrow-midnight light",
    "burrow-midnight dark",
    "burrow-sand light",
    "burrow-sand dark",
    "burrow-forest light",
    "burrow-forest dark",
    "high-contrast light",
    "high-contrast dark"
  ]

  @underlays ~w(black white base_content base_100 primary ag_teal ag_blue ag_purple ag_rose ag_amber ag_green ag_orange ag_indigo ag_brick ag_lime)

  # {label, ink layer, ground layer, floor}
  @pairs [
    {"inactive label", :inactive_label, :bar_glass, 4.5},
    {"active label", :active_label, :bar_glass, 4.5},
    {"placeholder", :placeholder, :pill_glass, 4.5},
    {"typed text", :typed, :pill_glass, 4.5},
    {"typing text", :typing, :band_glass, 4.5},
    {"inactive icon", :inactive_icon, :bar_glass, 3.0},
    {"active icon", :active_icon, :bar_glass, 3.0},
    {"More dot", :dot, :bar_glass, 3.0},
    {"attach icon", :attach, :pill_glass, 3.0}
  ]

  setup_all do
    app_css = File.read!(@app_css_path)
    presets = File.read!(@presets_path)

    blocks =
      [TB.burrow_block(app_css, "light"), TB.burrow_block(app_css, "dark")] ++
        TB.preset_blocks(presets)

    blocks = Map.new(blocks, &{"#{&1.id} #{&1.mode}", &1})
    {:ok, blocks: blocks, rules: CssRules.rules(app_css)}
  end

  # ── the fixtures are what they claim ─────────────────────────────────────

  test "anti-vacuity: both builds hold all 10 variants x every underlay x every alpha" do
    assert G.underlays() == @underlays

    expected =
      for v <- @variants,
          u <- @underlays,
          a <- G.under_alphas(),
          into: MapSet.new(),
          do: {v, u, a}

    assert MapSet.size(expected) == 10 * 15 * 21

    for build <- G.under_builds() do
      got = MapSet.new(G.under_keys(build))

      assert got == expected,
             "#{build}: missing #{inspect(Enum.take(MapSet.difference(expected, got), 5))}"

      for {v, u, a} <- expected do
        assert G.under_pixel(build, v, u, a, :ctl_white) == "#ffffff"
        assert G.under_pixel(build, v, u, a, :ctl_black) == "#000000"

        for l <- G.under_layers(),
            do: assert(G.under_pixel(build, v, u, a, l) =~ ~r/^#[0-9a-f]{6}$/)
      end
    end

    assert G.under_build_label(:chrome151) =~ "Chrome/151."
    assert G.under_build_label(:chrome147) =~ "Chrome/147."
  end

  test "an unswept alpha or an unknown underlay raises" do
    assert_raise ArgumentError, fn ->
      G.under_pixel(:chrome151, "burrow dark", "black", 0.79, :typed)
    end

    assert_raise ArgumentError, fn ->
      G.under_pixel(:chrome151, "burrow dark", "black", 0.875, :typed)
    end

    assert_raise ArgumentError, fn ->
      G.under_pixel(:chrome151, "burrow dark", "magenta", 0.87, :typed)
    end
  end

  test "app.css still declares exactly what the under-glass sweep painted", %{rules: rules} do
    [inputs | others] = Enum.map(G.under_builds(), &G.under_paint_inputs/1)
    assert Enum.all?(others, &(&1 == inputs)), "the two fixtures name different paint inputs"
    assert length(inputs) == 10, inspect(inputs)

    # Every declaration of the property on that selector, outside the
    # prefers-reduced-transparency fallback (which is opaque by design and
    # checked separately below).
    stale =
      inputs
      |> Enum.map(fn {sel, prop, painted} -> {sel, prop, painted, declared(rules, sel, prop)} end)
      |> Enum.reject(fn {_, _, painted, declared} -> declared == [painted] end)
      |> Enum.map(fn {sel, prop, painted, declared} ->
        "#{sel} { #{prop} } declares #{inspect(declared)}; the sweep painted #{inspect(painted)}"
      end)

    assert stale == [],
           "the under-glass fixtures no longer describe the CSS that ships. Repaint " <>
             "test/support/fixtures/painted_glass/underlay_*.csv from the compiled app.css:\n  " <>
             Enum.join(stale, "\n  ")
  end

  # ── the floors ───────────────────────────────────────────────────────────

  test "every chrome ink clears its floor at the DECLARED alpha over EVERY underlay, both builds",
       %{blocks: blocks} do
    rows =
      for v <- @variants do
        alpha = declared_alpha!(blocks, v)

        cells =
          for {label, ink, ground, floor} <- @pairs do
            {ratio, underlay, build} = worst(v, alpha, ink, ground)
            {label, ratio, underlay, build, floor}
          end

        {v, alpha, cells}
      end

    IO.puts(table(rows))

    failures =
      for {v, a, cells} <- rows,
          {label, ratio, u, b, floor} <- cells,
          ratio < floor,
          do: "#{v} @ #{a}: #{label} #{fixed4(ratio)} over #{u} (#{b}) < #{floor}"

    assert failures == [], "raise that block's --glass-alpha:\n  " <> Enum.join(failures, "\n  ")
  end

  test "advisory: High contrast placeholder at 7:1, and the enabled send fill", %{blocks: blocks} do
    for v <- @variants do
      a = declared_alpha!(blocks, v)
      {ph, u, b} = worst(v, a, :placeholder, :pill_glass)
      {send, su, sb} = worst(v, a, :send, :pill_glass)

      hc =
        if String.starts_with?(v, "high-contrast"),
          do:
            " placeholder #{fixed4(ph)} vs 7:1 (#{if ph >= 7, do: "meets", else: "advisory miss"}, #{u}, #{b})",
          else: ""

      IO.puts(
        "ADVISORY #{v} @ #{a}: send fill vs pill glass #{fixed4(send)} (#{su}, #{sb})" <> hc
      )
    end
  end

  test "the opaque reduced-transparency fallback: --subtle on opaque base-200 clears 4.5",
       %{blocks: blocks, rules: rules} do
    # Each glass surface's fallback paints opaque base-200 (rung 4's opaque
    # composite path, not the glass sweep).
    for sel <- [
          ".bottom-nav",
          ":root .compose-input-area .compose-pill-bar",
          ~s(.chat-dock--glass > [data-role="typing-indicator"])
        ] do
      fb =
        Enum.filter(
          rules,
          &(&1.selector == sel and
              Enum.any?(&1.at, fn a -> a =~ "prefers-reduced-transparency" end))
        )

      assert length(fb) == 1, "#{sel} has no single reduced-transparency fallback"
      assert normalise(hd(declarations(hd(fb).body, "background"))) == "var(--color-base-200)"
    end

    for v <- @variants do
      b = Map.fetch!(blocks, v)
      p = subtle_strength!(b)

      {ratio, _} =
        PC.contrast_min(
          ThemeBlockAssertions.resolve!(b, "--color-base-content"),
          ThemeBlockAssertions.resolve!(b, "--color-base-200"),
          p
        )

      assert ratio >= 4.5, "#{v}: --subtle (#{p}%) on opaque base-200 paints #{fixed4(ratio)}"
    end
  end

  # ── the rich composer field (redesign rung 10, task 01a1557a-997a stage 2) ─

  test "the chip field's placeholder and resting Send paint the placeholder ink the sweep measured",
       %{rules: rules} do
    # The rich field's placeholder is `:empty::before`, not `::placeholder`,
    # so it only inherits the painted "placeholder" row (4.5 over the pill
    # glass, every underlay, both builds) if it declares the SAME ink.
    [painted] =
      for {sel, "color", painted} <- G.under_paint_inputs(hd(G.under_builds())),
          sel == ".compose-pill-bar textarea::placeholder",
          do: painted

    assert declared(rules, ".compose-field:empty::before", "color") == [painted]

    # Send at rest is that same ink on the same glass (no fill, no fade).
    assert declared(rules, ".compose-pill-send:disabled", "color") == [painted <> " !important"]
    assert declared(rules, ".compose-pill-send:disabled", "opacity") == ["1"]

    assert declared(rules, ".compose-pill-send:disabled", "background") == [
             "transparent !important"
           ]
  end

  test "chip text (base-content) on the chip fill (base-300) clears 4.5 in every variant",
       %{blocks: blocks, rules: rules} do
    assert declared(rules, ".compose-chip", "background") == ["var(--color-base-300)"]
    assert declared(rules, ".compose-chip", "color") == ["var(--color-base-content)"]

    rows =
      for v <- @variants do
        b = Map.fetch!(blocks, v)

        ratio =
          W.contrast(
            PC.from_bytes(PC.bytes(ThemeBlockAssertions.resolve!(b, "--color-base-content"))),
            PC.from_bytes(PC.bytes(ThemeBlockAssertions.resolve!(b, "--color-base-300")))
          )

        {v, ratio}
      end

    IO.puts(Enum.map_join(rows, "\n", fn {v, r} -> "chip #{v}: #{fixed4(r)}" end))
    failures = for {v, r} <- rows, r < 4.5, do: "#{v}: #{fixed4(r)}"

    assert failures == [], "chip text under 4.5:1 on its fill:\n  " <> Enum.join(failures, "\n  ")
  end

  # ── the in-flow @mention list (redesign rung 10, task 01a1557a-997a stage 3) ─

  test "the mention list sits on the painted pill glass, in the painted inks", %{rules: rules} do
    painted = Map.new(G.under_paint_inputs(hd(G.under_builds())), fn {s, p, v} -> {{s, p}, v} end)

    pill_glass =
      Map.fetch!(painted, {":root .compose-input-area .compose-pill-bar", "background"})

    subtle = Map.fetch!(painted, {".compose-pill-bar textarea::placeholder", "color"})

    # Same glass as the pill, so the sweep's "typed text" and "placeholder"
    # rows (4.5 over every underlay, both builds, every variant) are the
    # list's name and subtle inks on its own surface.
    assert declared(rules, ".mention-list-panel", "background") == [pill_glass]
    assert declared(rules, ".mention-list-panel", "box-shadow") == []
    assert declared(rules, ".mention-list-row", "color") == ["var(--color-base-content)"]
    assert declared(rules, ".mention-list-name", "color") == ["var(--color-base-content)"]

    for sel <- [".mention-list-kind", ".mention-list-note", ".mention-list-empty"] do
      assert declared(rules, sel, "color") == [subtle], "#{sel} is not the painted subtle ink"
    end

    # The highlight (keys, press, desktop hover) is opaque base-100.
    assert declared(rules, ~s(.mention-list-row[aria-selected="true"]), "background") ==
             ["var(--color-base-100)"]

    assert declared(rules, ".mention-list-row:hover", "background") == ["var(--color-base-100)"]

    # Its reduced-transparency fallback is the pill's opaque base-200.
    [fb] =
      Enum.filter(
        rules,
        &(&1.selector == ".mention-list-panel" and
            Enum.any?(&1.at, fn a -> a =~ "prefers-reduced-transparency" end))
      )

    assert normalise(hd(declarations(fb.body, "background"))) == "var(--color-base-200)"
  end

  test "mention list inks clear 4.5 on the base-100 highlight in every variant",
       %{blocks: blocks} do
    rows =
      for v <- @variants do
        b = Map.fetch!(blocks, v)
        content = ThemeBlockAssertions.resolve!(b, "--color-base-content")
        base100 = ThemeBlockAssertions.resolve!(b, "--color-base-100")

        name =
          W.contrast(PC.from_bytes(PC.bytes(content)), PC.from_bytes(PC.bytes(base100)))

        {subtle, _} = PC.contrast_min(content, base100, subtle_strength!(b))
        {v, name, subtle}
      end

    IO.puts(
      Enum.map_join(rows, "\n", fn {v, n, s} ->
        "mention highlight #{v}: name #{fixed4(n)}, subtle #{fixed4(s)}"
      end)
    )

    failures =
      for {v, n, s} <- rows,
          {label, r} <- [{"name", n}, {"subtle", s}],
          r < 4.5,
          do: "#{v}: #{label} #{fixed4(r)}"

    assert failures == [],
           "mention list ink under 4.5:1 on base-100:\n  " <> Enum.join(failures, "\n  ")
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp declared(rules, sel, prop) do
    for r <- rules,
        r.selector == sel,
        not Enum.any?(r.at, &(&1 =~ "prefers-reduced-transparency")),
        v <- declarations(r.body, prop),
        do: normalise(v)
  end

  defp worst(variant, alpha, ink, ground) do
    for build <- G.under_builds(), u <- @underlays do
      {G.under_contrast(build, variant, u, alpha, ink, ground), u, build}
    end
    |> Enum.min_by(&elem(&1, 0))
  end

  defp declared_alpha!(blocks, variant) do
    b = Map.fetch!(blocks, variant)

    raw =
      TB.declaration(b.decls, "--glass-alpha") || flunk("#{variant} declares no --glass-alpha")

    G.alpha_key!(raw)
  end

  defp subtle_strength!(b) do
    value = TB.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(~r/var\(--color-base-content\)\s+(\d+)%/, value) do
      [_, p] -> String.to_integer(p)
      nil -> flunk("#{b.id} #{b.mode}: --subtle is not a base-content mix: #{value}")
    end
  end

  defp table(rows) do
    head =
      "| variant | alpha | " <>
        Enum.map_join(@pairs, " | ", fn {l, _, _, f} -> "#{l} (#{f})" end) <> " |"

    body =
      for {v, a, cells} <- rows do
        "| #{v} | #{a} | " <>
          Enum.map_join(cells, " | ", fn {_, r, u, _b, f} ->
            "#{fixed4(r)}#{if r < f, do: " FAIL", else: ""} #{u}"
          end) <> " |"
      end

    Enum.join(
      ["", "Under-glass chrome ink, worst over every underlay and both builds:", head | body],
      "\n"
    )
  end

  defp fixed4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  defp declarations(body, prop) do
    ~r/(?:^|[;{])\s*#{Regex.escape(prop)}\s*:\s*([^;]+);/m
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [v] -> String.trim(v) end)
  end

  defp normalise(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\(\s+/, "(")
    |> String.replace(~r/\s+\)/, ")")
    |> String.trim()
  end
end
