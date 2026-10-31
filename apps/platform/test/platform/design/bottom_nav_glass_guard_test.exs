defmodule Platform.Design.BottomNavGlassGuardTest do
  @moduledoc """
  Guards the mobile glass tab bar's paint (task
  01a1557a-7a71-7000-8580-75565039bffe, Burrow redesign 4, stage 1): the
  `.bottom-nav*` rules in `app.css` and the `--glass-alpha` / `--glass-blur`
  tokens in all ten variant blocks (Burrow's two daisyUI blocks in app.css,
  the eight preset blocks in theme_presets.css).

  ## What is measured, and on what

  A label on translucent glass has no fixed ground (Saru's rule 1, canvas
  01a15b55-6565-7000-9dc1-0858ad0c7736). The ratios here are read from PAINTED
  pixels, `Platform.Design.PaintedGlass`: the compiled bar painted over pure
  black and pure white, Chrome 151 and Chrome 147, every variant, alpha
  0.50..1.00. Nothing is derived from `PaintedComposite`'s opaque-ground
  formulas, and blur counts for nothing (the panels are uniform, so the blurred
  backdrop is the backdrop).

  For each block the guard takes its DECLARED `--glass-alpha`, looks up the
  painted pixels at exactly that alpha (an unswept alpha raises), and asserts
  the minimum over both builds and both backdrops:

  | pair            | floor          |
  |-----------------|----------------|
  | inactive label  | 4.5 (HC 7)     |
  | inactive icon   | 3              |
  | active label    | 4.5 (HC 7)     |
  | active icon     | 3              |
  | More dot        | 3              |

  A declared alpha may sit ABOVE its measured floor for margin, and must never
  sit below it. Every non-High-contrast alpha is held to its floor exactly (one
  swept step lower fails a pair) unless `@above_floor` records the floor it was
  raised from, and then that recorded floor is checked to still BE the floor.
  Burrow sand light is the one raised block: its floor, 0.92, clears by 4.5002:1,
  one painted byte from failing, so it declares 0.93 (4.5965:1). High contrast
  is opaque by rule (alpha 1, blur 0px), not by its floor.

  ## Why the fixtures cannot drift from the CSS silently

  The pixels are only evidence about the CSS they were painted from. Each
  fixture names those declarations on `# paint-input:` lines, and this file
  asserts app.css still declares exactly them. Change the bar's background, the
  tab ink, the active ink or the dot, and this goes red with "repaint", rather
  than passing on pixels of a rule that no longer ships.

  ## Structure

  Every block declares both glass tokens and `--color-base-200` (the source of
  rung 2's `theme-color`, which this rung must not override); a
  `prefers-reduced-transparency: reduce` rule sets alpha 1 with no blur; no
  `.bottom-nav*` rule body holds a colour literal; no `.bottom-nav` selector is
  qualified by `data-theme`. Each rule is SLICED and counted before its body is
  read, so a missing rule cannot pass a file-wide grep.

  ## High contrast's tab ink (H-HC)

  HC's `--subtle` paints 4.7417:1 (light) and 6.2450:1 (dark) on its opaque
  base-200, under 7:1, so the bar's ink in HC is base-content through
  `[data-preset="high-contrast"] .bottom-nav { --tab-ink }`. A clause holds
  that reason: if HC `--subtle` ever clears 7:1 there, the override is
  unnecessary and should go.

  Named mutations, each shown to turn this file red (stage 1 evidence):
  (a) Burrow light `--glass-alpha` to 0.72; (b) HC dark `--glass-blur` to 18px;
  (c) `background: oklch(8% 0 0 / 0.96)` back on `.bottom-nav`; (d) a
  `[data-theme="light"] .bottom-nav` rule restored; (e) inactive ink to
  `color-mix(in oklab, var(--color-base-content) 45%, transparent)`; (f) a
  fixture row deleted; (g) an unswept alpha declared.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.PaintedGlass, as: G

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @plugin_open ~s(@plugin "../vendor/daisyui-theme" {)
  @canonical ~r/^\[data-preset="([a-z0-9-]+)"\]\[data-theme="(dark|light)"\]:not\(\[data-theme-preview\]\)$/

  @aa_text 4.5
  @aaa_text 7.0
  @non_text 3.0
  @masters_alpha 0.72

  # Blocks declared above their measured floor for margin: variant => floor.
  @above_floor %{"burrow-sand light" => "0.92"}

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

  # {label, layer, floor for an ordinary block, floor for High contrast}
  @pairs [
    {"inactive label", :inactive_label, @aa_text, @aaa_text},
    {"inactive icon", :inactive_icon, @non_text, @non_text},
    {"active label", :active_label, @aa_text, @aaa_text},
    {"active icon", :active_icon, @non_text, @non_text},
    {"More dot", :dot, @non_text, @non_text}
  ]

  # Every `.bottom-nav*` rule app.css declares, by selector and the at-rule
  # it sits in. Stages 2 and 3 add geometry rules; add them here too.
  @hide_selectors [
    ~s{:root:has([phx-hook="ComposeInput"]:focus)},
    ":root:has([data-fullscreen-viewer])",
    ":root:has([data-in-call])"
  ]

  @expected_rules [
    {[], ".bottom-nav"},
    {[], Enum.map_join(@hide_selectors, ", ", &(&1 <> " .bottom-nav"))},
    {[], ":root:has(#more-sheet.sheet-open) .bottom-nav"},
    # Task 01a1557b stage 3: inside the iOS app the native tab bar replaces it.
    {[], ":root[data-native-tab-bar] .bottom-nav"},
    {["@media (prefers-reduced-motion: reduce)"], ".bottom-nav"},
    {[], ~s([data-preset="high-contrast"] .bottom-nav)},
    {["@media (prefers-reduced-transparency: reduce)"], ".bottom-nav"},
    {["@media (min-width: 1024px)"], ".bottom-nav"},
    {[], ".bottom-nav-tab"},
    # Sliding pill (prototype t1): the tinted pill behind the current tab and
    # the whole-cell press scale, set by the TabPill hook.
    {[], ".bottom-nav-pill-layer"},
    {[], ".bottom-nav-pill"},
    {[], ".bottom-nav-tab.is-pressed"},
    {["@media (prefers-reduced-motion: reduce)"], ".bottom-nav-pill"},
    {["@media (prefers-reduced-motion: reduce)"], ".bottom-nav-tab.is-pressed"},
    {["@media (hover: hover)"],
     ".bottom-nav-tab:not(.bottom-nav-tab--active):not([data-nav-pending]):hover"},
    {[], ".bottom-nav-tab:focus-visible"},
    {[], ".bottom-nav-tab:active"},
    {[], ".bottom-nav-tab:not(.bottom-nav-tab--active):active"},
    {[], ".bottom-nav-tab--active"},
    {[], ".bottom-nav-dot"},
    # The native tab bar's ink probes (task 01a174e8 stage 1): token slots
    # with the bar's own inks as fallbacks, read by the NativeTabBar hook.
    {[], ~s(.bottom-nav [data-native-ink="unselected"])},
    {[], ~s(.bottom-nav [data-native-ink="selected"])},
    {[], ".bottom-nav-icon"},
    {[], ".bottom-nav-label"},
    {[], ".bottom-nav-tab--active .bottom-nav-label"},
    # Optimistic navigation (task 01a166be-b5b9 stage 2): the tapped tab takes
    # the active look and the active tab yields it, both set by nav_pending.js.
    {[], ".bottom-nav-tab[data-nav-pending]"},
    {[], ".bottom-nav-tab[data-nav-pending] .bottom-nav-label"},
    {[], ".bottom-nav-tab[data-nav-pending] .bottom-nav-icon"},
    {[], ".bottom-nav-tab--active[data-nav-yielded]"},
    {[], ".bottom-nav-tab--active[data-nav-yielded] .bottom-nav-label"},
    {["@media (prefers-reduced-motion: reduce)"],
     ".bottom-nav-tab[data-nav-pending] .bottom-nav-icon"},
    # The More tab holds its press during the sheet round trip (task
    # 01a166be-b5b9 stage 3, canvas 01a167b0 rule 5).
    {[], ".bottom-nav-tab.press-hold.phx-click-loading:not(.bottom-nav-tab--active)"},
    {[], ".bottom-nav-tab.press-hold.phx-click-loading"},
    {[], ".bottom-nav-tab.press-hold.phx-click-loading .bottom-nav-label"},
    {["@media (prefers-reduced-motion: reduce)"], ".bottom-nav-tab.press-hold.phx-click-loading"}
  ]

  @colour_literal ~r/#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(|\boklch\(|\boklab\(|\blab\(|\blch\(|\bhwb\(/

  setup_all do
    app_css = File.read!(@app_css_path)
    presets = File.read!(@presets_path)

    {:ok,
     app_css: app_css,
     presets: presets,
     blocks: burrow_blocks(app_css) ++ preset_blocks(presets),
     rules: rules(strip_comments(app_css)) ++ rules(strip_comments(presets))}
  end

  # ── the fixtures are what they claim ─────────────────────────────────────

  describe "the painted fixtures" do
    test "each build holds every variant x backdrop x swept alpha, and its controls read true" do
      expected =
        for v <- @variants,
            bd <- G.backdrops(),
            a <- G.alphas(),
            into: MapSet.new(),
            do: {v, bd, a}

      assert MapSet.size(expected) == 10 * 2 * 51

      for build <- G.builds() do
        got = MapSet.new(G.keys(build))

        assert MapSet.difference(expected, got) == MapSet.new(),
               "#{build}: missing rows #{inspect(Enum.take(MapSet.difference(expected, got), 5))}"

        assert MapSet.size(got) == MapSet.size(expected)

        for {v, bd, a} <- expected do
          assert G.pixel(build, v, bd, a, :ctl_white) == "#ffffff"
          assert G.pixel(build, v, bd, a, :ctl_black) == "#000000"
        end
      end

      assert G.build_label(:chrome151) =~ "Chrome/151."
      assert G.build_label(:chrome147) =~ "Chrome/147."
    end

    test "an unswept alpha raises instead of interpolating" do
      for bad <- [0.875, 0.49, 1.01, "0.725", "glass"] do
        assert_raise ArgumentError, fn ->
          G.pixel(:chrome151, "burrow light", :black, bad, :glass)
        end
      end

      assert G.pixel(:chrome151, "burrow light", :black, 0.96, :glass) ==
               G.pixel(:chrome151, "burrow light", :black, "0.96", :glass)
    end

    test "app.css still declares exactly what the sweep painted", %{rules: rules} do
      [inputs | others] = Enum.map(G.builds(), &G.paint_inputs/1)
      assert Enum.all?(others, &(&1 == inputs)), "the two fixtures name different paint inputs"
      assert length(inputs) == 6, inspect(inputs)

      # Every declaration of the property, not the first: a second, later
      # `background` would win the cascade while the first still matched.
      stale =
        for {sel, prop, painted} <- inputs,
            body = top_level_body!(rules, sel),
            declared = Enum.map(declarations(body, prop), &normalise/1),
            declared != [painted] do
          "#{sel} { #{prop} } declares #{inspect(declared)}; the sweep painted #{inspect(painted)}"
        end

      assert stale == [],
             "the painted glass fixtures no longer describe the CSS that ships. Repaint " <>
               "test/support/fixtures/painted_glass/ from the compiled app.css:\n  " <>
               Enum.join(stale, "\n  ")
    end
  end

  # ── tokens ───────────────────────────────────────────────────────────────

  describe "every variant block" do
    test "all ten blocks are found", %{blocks: blocks} do
      assert Enum.map(blocks, & &1.variant) |> Enum.sort() == Enum.sort(@variants)
    end

    test "declares --glass-alpha and --glass-blur", %{blocks: blocks} do
      missing =
        for b <- blocks,
            token <- ["--glass-alpha", "--glass-blur"],
            declaration(b.decls, token) == nil do
          "#{b.variant}: #{token}"
        end

      assert missing == [], Enum.join(missing, "\n")
    end

    test "declares --color-base-200, the theme-color source this rung must not override", %{
      blocks: blocks
    } do
      missing = for b <- blocks, declaration(b.decls, "--color-base-200") == nil, do: b.variant
      assert length(blocks) == 10
      assert missing == [], "blocks with no --color-base-200: #{inspect(missing)}"
    end

    test "High contrast is opaque through its tokens: alpha 1, blur 0px", %{blocks: blocks} do
      hc = Enum.filter(blocks, &String.starts_with?(&1.variant, "high-contrast"))
      assert length(hc) == 2

      for b <- hc do
        assert declaration(b.decls, "--glass-alpha") == "1", "#{b.variant} --glass-alpha"
        assert declaration(b.decls, "--glass-blur") == "0px", "#{b.variant} --glass-blur"
      end
    end

    test "no alpha sits below the masters' #{@masters_alpha}", %{blocks: blocks} do
      low = for b <- blocks, alpha(b) < @masters_alpha, do: {b.variant, alpha(b)}
      assert low == []
    end

    test "every pair clears its floor at the DECLARED alpha, over both backdrops, on both builds",
         %{blocks: blocks} do
      failures =
        for b <- blocks,
            {label, layer, floor, hc_floor} <- @pairs,
            target = if(hc?(b), do: hc_floor, else: floor),
            {r, where} = worst(b.variant, alpha_key(b), layer),
            r < target do
          "#{b.variant} @ #{alpha_key(b)}: #{label} #{fixed4(r)}:1 < #{target} (#{where})"
        end

      assert failures == [], Enum.join(failures, "\n")
    end

    test "every non-HC alpha is its measured floor, or sits above a recorded floor for margin",
         %{blocks: blocks} do
      not_floor =
        for b <- blocks,
            not hc?(b),
            floor = Map.get(@above_floor, b.variant, alpha_key(b)),
            problem = floor_problem(b, floor),
            problem != nil,
            do: problem

      assert length(Enum.reject(blocks, &hc?/1)) == 8
      assert Enum.all?(Map.keys(@above_floor), &(&1 in @variants))
      assert not_floor == [], Enum.join(not_floor, "\n")
    end

    test "the measured table: every variant passes", %{blocks: blocks} do
      lines =
        for v <- @variants do
          b = Enum.find(blocks, &(&1.variant == v))

          cells =
            for {_label, layer, _f, _hf} <- @pairs do
              {r, _} = worst(v, alpha_key(b), layer)
              fixed4(r)
            end

          "| #{v} | #{alpha_key(b)} | #{declaration(b.decls, "--glass-blur")} | " <>
            Enum.join(cells, " | ") <>
            " | #{if hc?(b), do: "7 / 3", else: "4.5 / 3"} | pass |"
        end

      assert length(lines) == 10

      IO.puts(
        "\nGlass tab bar, painted (min over Chrome 151 + 147, over #000 and #fff, at the " <>
          "declared alpha):\n" <>
          "| Variant | alpha | blur | inactive label | inactive icon | active label | " <>
          "active icon | More dot | text / non-text floor | verdict |\n" <>
          "|---|---|---|---|---|---|---|---|---|---|\n" <> Enum.join(lines, "\n")
      )
    end
  end

  test "H-HC: High contrast's --subtle misses 7:1 on its opaque bar, so the ink override is needed" do
    for v <- ["high-contrast light", "high-contrast dark"] do
      {r, _} = worst(v, "1.00", :subtle)

      assert r < @aaa_text,
             "#{v}: --color-subtle now paints #{fixed4(r)}:1 on the opaque bar, clearing 7:1. " <>
               "The [data-preset=\"high-contrast\"] .bottom-nav --tab-ink override is no " <>
               "longer needed; remove it and this clause."
    end
  end

  # ── rules ────────────────────────────────────────────────────────────────

  describe "the .bottom-nav* rules" do
    test "exactly the expected rules exist, each non-empty", %{rules: rules} do
      found = for r <- rules, bottom_nav?(r.selector), do: {r.context, r.selector}

      assert Enum.sort(found) == Enum.sort(@expected_rules),
             "the .bottom-nav* rules changed. Found:\n  " <>
               Enum.map_join(found, "\n  ", &inspect/1)

      for r <- rules, bottom_nav?(r.selector) do
        assert String.trim(r.body) != "", "#{r.selector} has an empty body"
      end
    end

    test "no rule body holds a colour literal", %{rules: rules} do
      bodies = for r <- rules, bottom_nav?(r.selector), do: r
      assert length(bodies) == length(@expected_rules)

      offenders =
        for r <- bodies,
            m = Regex.run(@colour_literal, r.body),
            m != nil,
            do: "#{Enum.join(r.context, " ")} #{r.selector}: #{hd(m)}"

      assert offenders == [],
             "colour literals in .bottom-nav* rules:\n" <> Enum.join(offenders, "\n")
    end

    test "no .bottom-nav selector is qualified by data-theme", %{rules: rules, app_css: app_css} do
      qualified =
        for r <- rules, bottom_nav?(r.selector), r.selector =~ "data-theme", do: r.selector

      assert qualified == []

      # The detector can fire: the selector this stage deleted is caught by it.
      sample = rules(~s([data-theme="light"] .bottom-nav { background: none; }))
      assert [%{selector: sel}] = sample
      assert bottom_nav?(sel) and sel =~ "data-theme"

      refute strip_comments(app_css) =~ ~r/\.bottom-nav-badge\b/,
             ".bottom-nav-badge has no consumer and was deleted"

      refute strip_comments(app_css) =~ ~r/\.bottom-nav-tab--active::before/,
             "the active tab's top bar was retired"
    end

    test "a prefers-reduced-transparency rule renders the bar opaque, with no blur", %{
      rules: rules
    } do
      [r] =
        Enum.filter(
          rules,
          &(&1.selector == ".bottom-nav" and
              &1.context == ["@media (prefers-reduced-transparency: reduce)"])
        )

      assert declaration(r.body, "--glass-alpha") == "1"
      assert declaration(r.body, "--glass-blur") == "0px"
      assert declaration(r.body, "backdrop-filter") == "none"
      assert declaration(r.body, "background") == "var(--color-base-200)"
    end

    test "the bar draws blur and edge from tokens, and no shadow", %{rules: rules} do
      body = top_level_body!(rules, ".bottom-nav")

      assert normalise(declaration(body, "backdrop-filter")) ==
               "blur(var(--glass-blur)) saturate(1.4)"

      # A full hairline since the bar floats (stage 3); stage 1 drew border-top.
      # Its colour is prototype 01a178d2 v4's translucent `--glass-edge`
      # (task 01a18d9f fix round 2): `--tab-bar-edge`, base-content at 8%
      # light and 9% dark, replacing the opaque base-300 hairline.
      assert normalise(declaration(body, "border")) == "1px solid var(--tab-bar-edge)"

      edges =
        for r <- rules, v <- declarations(r.body, "--tab-bar-edge"), do: normalise(v)

      assert "color-mix(in srgb, var(--color-base-content) 8%, transparent)" in edges
      assert "color-mix(in srgb, var(--color-base-content) 9%, transparent)" in edges

      # Prototype 01a178d2 v4 (task 01a18d9f fix round) supersedes task
      # 01a15f2e's no-shadow rule: the bar carries v4's glass shadow, through
      # the `--shadow-tab-bar` token (light 0 10px 30px rgb(40 30 20 / 0.18),
      # dark 0 10px 30px rgb(0 0 0 / 0.45), from v4 theme.js `--glass-shadow`),
      # declared once on the top-level `.bottom-nav` and nowhere else.
      shadowed =
        for r <- rules,
            Enum.any?(split_selectors(r.selector), &String.ends_with?(&1, ".bottom-nav")),
            declarations(r.body, "box-shadow") != [],
            do: {r.context, r.selector, normalise(declaration(r.body, "box-shadow"))}

      assert shadowed == [{[], ".bottom-nav", "var(--shadow-tab-bar)"}]

      tokens =
        for r <- rules,
            v <- declarations(r.body, "--shadow-tab-bar"),
            do: normalise(v)

      assert "0 10px 30px rgb(40 30 20 / 0.18)" in tokens
      assert "0 10px 30px rgb(0 0 0 / 0.45)" in tokens
    end

    # Prototype 01a178d2 v4 `.tab` (task 01a18d9f fix round): 11px at 550,
    # at rest and selected alike; it supersedes the earlier 400/500 pair.
    test "tab type: 11px, 550 at rest and active, no letter-spacing", %{rules: rules} do
      label = top_level_body!(rules, ".bottom-nav-label")
      assert declaration(label, "font-size") == "11px"
      assert declaration(label, "font-weight") == "550"
      assert declaration(label, "letter-spacing") == nil

      active = top_level_body!(rules, ".bottom-nav-tab--active .bottom-nav-label")
      assert declaration(active, "font-weight") == "550"
    end
  end

  # ── geometry and hide rules (stage 3) ───────────────────────────────────

  describe "floating geometry and the three hide rules (task 01a1557a-7a71 stage 3)" do
    test "the bar is fixed, 12px in from the sides, --bottom-nav-offset from the bottom, 64px tall",
         %{rules: rules} do
      body = top_level_body!(rules, ".bottom-nav")
      assert body != ""
      assert declaration(body, "position") == "fixed"
      assert declaration(body, "left") == "12px"
      assert declaration(body, "right") == "12px"
      assert declaration(body, "height") == "64px"

      # Task 01a15f2e stage 1 (Saru's canvas 01a15f2f): the bar's bottom edge
      # is max(inset - 13px, floor) above the viewport bottom, 21px at inset
      # 34, declared once in the top-level :root. The floor is prototype
      # 01a178d2 v4's `.tabbar` bottom: 12px (task 01a18d9f fix round; was 8px).
      assert declarations(body, "bottom") == ["var(--bottom-nav-offset)"]

      [offset] =
        for r <- rules,
            r.selector == ":root" and r.context == [],
            v <- declarations(r.body, "--bottom-nav-offset"),
            do: normalise(v)

      assert offset == "max(env(safe-area-inset-bottom, 0px) - 13px, 12px)"

      tab = top_level_body!(rules, ".bottom-nav-tab")
      assert declaration(tab, "min-width") == "44px"
      assert declaration(tab, "min-height") == "44px"
      assert declaration(tab, "flex") == "1"
    end

    test "clearance tokens: below lg the height is the bar's top edge minus the safe area",
         %{rules: rules} do
      [mobile] =
        Enum.filter(
          rules,
          &(&1.selector == ":root:has([data-bottom-rail])" and
              &1.context == ["@media (max-width: 1023.98px)"])
        )

      # Not the bar's height any more: offset + 64 - inset, so the ~40 inline
      # `env(safe-area-inset-bottom) + var(--bottom-nav-height)` call sites
      # sum to the bar's top edge at every inset (task 01a15f2e stage 1).
      assert normalise(declaration(mobile.body, "--bottom-nav-height")) ==
               "calc(var(--bottom-nav-offset) + 64px - env(safe-area-inset-bottom, 0px))"

      root =
        rules
        |> Enum.filter(&(&1.selector == ":root" and &1.context == []))
        |> Enum.map(& &1.body)
        |> Enum.find(&declaration(&1, "--bottom-nav-clearance"))

      assert root, "no top-level :root declares --bottom-nav-clearance"
      clearance = normalise(declaration(root, "--bottom-nav-clearance"))
      assert clearance =~ "var(--bottom-nav-height)" and clearance =~ "env(safe-area-inset-bottom"
      assert declaration(root, "--bottom-nav-height") == "0px"
    end

    test "exactly the three hide selectors zero the clearance and hide the bar", %{rules: rules} do
      zeroing = Enum.filter(rules, &(declaration(&1.body, "--bottom-nav-height") == "0px"))
      [token_rule] = Enum.filter(zeroing, &(&1.selector =~ ":has(" and &1.context == []))

      assert token_rule.context == []
      assert split_selectors(token_rule.selector) == @hide_selectors
      assert declaration(token_rule.body, "--bottom-nav-gap") == "0px"

      [hidden] =
        Enum.filter(
          rules,
          &(&1.context == [] and &1.selector =~ ":has(" and &1.selector =~ ".bottom-nav" and
              declaration(&1.body, "visibility") == "hidden")
        )

      assert split_selectors(hidden.selector) ==
               Enum.map(@hide_selectors, &(&1 <> " .bottom-nav"))

      assert declaration(hidden.body, "opacity") == "0"
      assert normalise(declaration(hidden.body, "transform")) =~ "translateY("
      assert normalise(declaration(hidden.body, "transition")) =~ "visibility 0s linear 150ms"

      bar = top_level_body!(rules, ".bottom-nav")
      transition = normalise(declaration(bar, "transition"))
      assert transition =~ "transform 150ms" and transition =~ "opacity 150ms"
    end

    # Task 01a1557b stage 3: inside the iOS app the clearance follows
    # --native-tab-bar-height at (0,3,0), which ties or beats the viewer and
    # in-call hide rules above (0,2,0). The same three hide selectors are
    # restated under the native attribute so the clearance still drops to 0.
    test "the native tab bar's clearance and its restated hide rules", %{rules: rules} do
      native = ":root[data-native-tab-bar]:has([data-bottom-rail])"
      phone = ["@media (max-width: 1023.98px)"]

      [clearance] = Enum.filter(rules, &(&1.selector == native and &1.context == phone))

      assert normalise(declaration(clearance.body, "--bottom-nav-height")) =~
               "var(--native-tab-bar-height"

      [restated] =
        Enum.filter(
          rules,
          &(&1.context == phone and &1.selector =~ native and
              declaration(&1.body, "--bottom-nav-height") == "0px")
        )

      assert split_selectors(restated.selector) ==
               Enum.map(@hide_selectors, &String.replace(&1, ":root", native, global: false))

      assert declaration(restated.body, "--bottom-nav-gap") == "0px"
    end

    test "no rule hides the bar or zeroes its clearance on scroll", %{rules: rules} do
      hiders =
        Enum.filter(rules, fn r ->
          declaration(r.body, "--bottom-nav-height") == "0px" or
            (bottom_nav?(r.selector) and declaration(r.body, "visibility") == "hidden")
        end)

      # Anti-vacuity: the two real hide rules (token and bar) are found.
      assert length(hiders) >= 2
      keyed_on_scroll = for r <- hiders, r.selector =~ ~r/scroll/i, do: r.selector
      assert keyed_on_scroll == []
    end

    test "reduced motion removes the transition", %{rules: rules} do
      [r] =
        Enum.filter(
          rules,
          &(&1.selector == ".bottom-nav" and
              &1.context == ["@media (prefers-reduced-motion: reduce)"])
        )

      assert declaration(r.body, "transition") == "none"
    end

    test "the More sheet, and only it, goes under the bar; its panel ends at the bar's top",
         %{rules: rules} do
      [lifted] =
        Enum.filter(rules, &(&1.selector == ":root:has(#more-sheet.sheet-open) .bottom-nav"))

      assert String.to_integer(declaration(lifted.body, "z-index")) > 100

      [panel] = Enum.filter(rules, &(&1.selector == ".more-sheet .sheet-panel"))
      assert declaration(panel.body, "padding-bottom") == "var(--bottom-nav-clearance)"

      assert declaration(top_level_body!(rules, ".bottom-nav"), "z-index") == "30"
    end
  end

  # ── review fixes (stage 5) ───────────────────────────────────────────────

  describe "hover and focus on bar tabs (task 01a1557a-7a71 stage 5)" do
    test "every :hover rule on a bar tab is inside (hover: hover) and excludes the active tab",
         %{rules: rules} do
      hovers = for r <- rules, bottom_nav?(r.selector), r.selector =~ ":hover", do: r

      # Anti-vacuity: the lift rule exists, so an empty list cannot pass.
      assert length(hovers) == 1, inspect(hovers)

      bad =
        for r <- hovers,
            r.context != ["@media (hover: hover)"] or
              not String.contains?(r.selector, ":not(.bottom-nav-tab--active)"),
            do: {r.context, r.selector}

      assert bad == [],
             "a bar :hover rule can repaint the active tab (sticky :hover on touch beat " <>
               ".bottom-nav-tab--active, review finding E4): #{inspect(bad)}"
    end

    test "nothing but the active rule sets a colour that can reach the active tab",
         %{rules: rules} do
      painters =
        for r <- rules,
            r.selector =~ ".bottom-nav-tab",
            declaration(r.body, "color") != nil,
            not String.contains?(r.selector, ":not(.bottom-nav-tab--active)"),
            do: r.selector

      # Plus the two optimistic-navigation states (task 01a166be-b5b9 stage 2),
      # which are JS attributes, never a sticky pointer state: pending paints
      # the active colour itself, and yielded deliberately hands the active
      # tab the rest ink while another tab is pending.
      assert Enum.sort(painters) == [
               ".bottom-nav-tab",
               ".bottom-nav-tab--active",
               ".bottom-nav-tab--active[data-nav-yielded]",
               ".bottom-nav-tab[data-nav-pending]"
             ]

      assert declaration(top_level_body!(rules, ".bottom-nav-tab[data-nav-pending]"), "color") ==
               declaration(top_level_body!(rules, ".bottom-nav-tab--active"), "color")
    end

    test "keyboard focus draws the focus-ring token INSIDE the cell", %{rules: rules} do
      body = top_level_body!(rules, ".bottom-nav-tab:focus-visible")
      assert declaration(body, "outline") == "none"

      shadow = normalise(declaration(body, "box-shadow"))
      [{_, _, painted}] = G.ring_paint_inputs()
      assert shadow == painted, "the ring fixture was painted from #{inspect(painted)}"
      assert shadow =~ ~r/^inset / and shadow =~ "var(--color-focus-ring)"
    end

    test "the focus ring clears 3:1 on the painted glass, all ten variants, both backdrops and builds",
         %{blocks: blocks} do
      rows = G.ring_rows()
      assert length(rows) == 10 * 2 * 2

      for r <- rows,
          do: assert({r.ctl_white, r.ctl_black} == {"#ffffff", "#000000"}, inspect(r))

      failures =
        for b <- blocks, build <- G.builds(), bd <- G.backdrops() do
          case Enum.find(
                 rows,
                 &(&1.build == build and &1.variant == b.variant and &1.backdrop == bd)
               ) do
            nil ->
              "#{b.variant} #{build} #{bd}: not painted"

            row ->
              ring_problem(b, row)
          end
        end
        |> Enum.reject(&is_nil/1)

      assert length(blocks) == 10
      assert failures == [], Enum.join(failures, "\n")
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp hc?(b), do: String.starts_with?(b.variant, "high-contrast")

  defp ring_problem(b, row) do
    cond do
      G.alpha_key!(row.alpha) != alpha_key(b) ->
        "#{b.variant}: ring painted at #{row.alpha}, declared #{alpha_key(b)}; repaint"

      (r = G.ratio(row.ring, row.glass)) < @non_text ->
        "#{b.variant} #{row.build} #{row.backdrop}: ring #{fixed4(r)}:1"

      true ->
        nil
    end
  end

  defp alpha(b), do: String.to_float(alpha_key(b))

  defp alpha_key(b) do
    declared = declaration(b.decls, "--glass-alpha") || flunk("#{b.variant}: no --glass-alpha")
    G.alpha_key!(declared)
  end

  defp step_down(key) do
    lower = :erlang.float_to_binary(String.to_float(key) - 0.01, decimals: 2)
    if lower in G.alphas(), do: lower, else: nil
  end

  # nil when `floor` is the measured floor of `b` and `b` declares at or
  # above it; otherwise the reason.
  defp floor_problem(b, floor) do
    lower = step_down(floor)

    cond do
      String.to_float(alpha_key(b)) < String.to_float(floor) ->
        "#{b.variant}: declares #{alpha_key(b)}, below its recorded floor #{floor}"

      not passes?(b, floor) ->
        "#{b.variant}: the recorded floor #{floor} no longer clears every pair"

      passes?(b, lower) ->
        "#{b.variant}: floor is recorded as #{floor} but #{lower} already clears every pair"

      true ->
        nil
    end
  end

  defp passes?(_b, nil), do: false

  defp passes?(b, alpha) do
    Enum.all?(@pairs, fn {_l, layer, floor, hc_floor} ->
      {r, _} = worst(b.variant, alpha, layer)
      r >= if(hc?(b), do: hc_floor, else: floor)
    end)
  end

  # {min ratio of `layer` against the glass, where it was measured}.
  defp worst(variant, alpha, layer) do
    for build <- G.builds(), bd <- G.backdrops() do
      {G.contrast(build, variant, bd, alpha, layer), "#{build} over #{bd}"}
    end
    |> Enum.min_by(&elem(&1, 0))
  end

  defp fixed4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  defp bottom_nav?(selector), do: selector =~ ~r/\.bottom-nav/

  defp top_level_body!(rules, selector) do
    case Enum.filter(rules, &(&1.selector == selector and &1.context == [])) do
      [r] -> r.body
      other -> flunk("expected one top-level `#{selector}` rule, found #{length(other)}")
    end
  end

  defp split_selectors(selector),
    do: selector |> String.split(",") |> Enum.map(&String.trim/1)

  defp normalise(nil), do: nil

  defp normalise(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\(\s+/, "(")
    |> String.replace(~r/\s+\)/, ")")
    |> String.trim()
  end

  # Burrow's two variants: app.css's daisyUI theme blocks, by name.
  defp burrow_blocks(app_css) do
    plugin = blocks_after(app_css, @plugin_open)

    for mode <- ["light", "dark"] do
      body = Enum.find(plugin, &Regex.match?(~r/^\s*name:\s*"#{mode}";/m, &1))
      body || flunk("no daisyui-theme block named #{mode}")
      %{variant: "burrow #{mode}", decls: strip_comments(body)}
    end
  end

  # As theme_presets_guard_test.exs reads them.
  defp preset_blocks(css) do
    Regex.scan(~r/^(\[data-preset[^\n{]*)\{(.*?)\n\}/ms, css, capture: :all_but_first)
    |> Enum.flat_map(fn [sel, body] ->
      case Regex.run(@canonical, String.trim(sel)) do
        [_, id, mode] -> [%{variant: "#{id} #{mode}", decls: strip_comments(body)}]
        nil -> []
      end
    end)
  end

  defp blocks_after(css, open) do
    css
    |> :binary.matches(open)
    |> Enum.map(fn {at, len} ->
      start = at + len
      rest = binary_part(css, start, byte_size(css) - start)

      case Regex.run(~r/\n\s*\}/, rest, return: :index) do
        [{close, _}] -> binary_part(rest, 0, close)
        nil -> flunk("a block opened by #{inspect(open)} is never closed")
      end
    end)
  end

  defp declaration(block, prop) do
    case Regex.run(~r/(?:^|[;{])\s*#{Regex.escape(prop)}\s*:\s*([^;]+);/m, block) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp declarations(block, prop) do
    ~r/(?:^|[;{])\s*#{Regex.escape(prop)}\s*:\s*([^;]+);/m
    |> Regex.scan(block, capture: :all_but_first)
    |> Enum.map(fn [value] -> String.trim(value) end)
  end

  defp strip_comments(text), do: Regex.replace(~r{/\*.*?\*/}s, text, "")

  # Leaf rules of a comment-free stylesheet: %{context, selector, body}, where
  # context is the list of enclosing at-rule preludes. A block that contains
  # another block is a container (an at-rule), not a rule.
  defp rules(css), do: walk(css, [], "", [], [])

  defp walk("", _stack, _buf, _ctx, acc), do: Enum.reverse(acc)

  defp walk(<<q, rest::binary>>, stack, buf, ctx, acc) when q in [?", ?'] do
    {str, rest} = take_string(rest, q, <<q>>)
    walk(rest, stack, buf <> str, ctx, acc)
  end

  defp walk("{" <> rest, stack, buf, ctx, acc) do
    prelude =
      buf
      |> String.split(~r/[;}]/)
      |> List.last()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    walk(rest, [{prelude, ctx, false} | mark_parent(stack)], "", ctx ++ [prelude], acc)
  end

  defp walk("}" <> rest, [{prelude, ctx, has_child} | stack], buf, _ctx, acc) do
    acc = if has_child, do: acc, else: [%{context: ctx, selector: prelude, body: buf} | acc]
    walk(rest, stack, "", ctx, acc)
  end

  defp walk(<<c::utf8, rest::binary>>, stack, buf, ctx, acc),
    do: walk(rest, stack, buf <> <<c::utf8>>, ctx, acc)

  defp mark_parent([{p, c, _} | rest]), do: [{p, c, true} | rest]
  defp mark_parent([]), do: []

  defp take_string(<<q, rest::binary>>, q, acc), do: {acc <> <<q>>, rest}

  defp take_string(<<"\\", c, rest::binary>>, q, acc),
    do: take_string(rest, q, acc <> <<"\\", c>>)

  defp take_string(<<c, rest::binary>>, q, acc), do: take_string(rest, q, acc <> <<c>>)
  defp take_string("", _q, acc), do: {acc, ""}
end
