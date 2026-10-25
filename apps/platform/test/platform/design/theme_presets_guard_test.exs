defmodule Platform.Design.ThemePresetsGuardTest do
  @moduledoc """
  Guards `apps/platform/assets/css/theme_presets.css` (task 01a1557a, Burrow
  redesign 2, stage 2): the four non-Burrow theme presets, each as a dark and
  a light CSS token block.

  What is held, and why each half exists:

    * REGISTRY. `Platform.Accounts.ThemePreference.presets/0` is the one list of
      preset ids. Every non-Burrow id has both blocks, every block names a
      registered id, and Burrow has none (Burrow is app.css's daisyUI blocks
      plus the install theme, so a user with no `data-preset` is unchanged).
    * SLOTS. Every block declares the full slot list itself. Nothing falls
      through to Burrow's values, so the contrast half below measures exactly
      what each block paints.
    * CONTRAST. Every text pair the Burrow guard checks
      (`burrow_palette_guard_test.exs`), plus muted on all three grounds,
      `--subtle` (text-subtle, base-content at the block's own strength) and
      base-content at 60% (text-base-content/60, daisyUI .label), both painted,
      clears 4.5:1, or 7:1 for High contrast's full-strength text. Placeholders
      on the composers' literal fills are `placeholder_contrast_test.exs`.
    * TWO TEXT LEVELS. The faint tier is retired (task 01a15902 stage 2,
      direction canvas 01a15902-e3b2 Rulings 1): no block declares `--faint`,
      and app.css neither declares nor maps it.
    * PAINTED, UNDER EVERY MEASURED BROWSER. The reduced-strength pairs are
      composited, and Chrome 147 and 151 paint them up to a byte apart per
      channel. Each is measured on the worst pixel any formula in
      `Platform.Design.PaintedComposite.formulas/0` allows, at a strength some
      browser has actually been painted at (55%, 57% and 60%).
    * NO EXEMPTION. Every pair clears its floor; no pair is held lower. Burrow
      sand light, whose raised ground cannot carry black at 55%, raises its
      `--subtle` to 57% instead (stage 5 r2). A test fails if an exemption
      comment or a sub-4.5 floor reappears.
    * DEVIATIONS. Every value that differs from the masters' theme.js names the
      master value in a comment, beside its own recomputed ratio. For
      `--glass-alpha` (task 01a1557a-7a71 stage 1) that ratio is the worst tab
      label on the PAINTED glass (`Platform.Design.PaintedGlass`); the bar's own
      guard is `bottom_nav_glass_guard_test.exs`.
    * SPECIFICITY. Each preset selector beats every selector
      `Platform.Branding.ThemeCss` emits, which comes after app.css, so a named
      preset is a complete palette and install colours style Burrow only.
    * FONT. No `--font-sans` sits inside a daisyUI plugin block (the plugin
      splits comma stacks), body reads `var(--font-sans)`, and Burrow's
      `:root` stack is still Public Sans.

  The last test builds the 12-row AA table (six master presets x two modes;
  the masters' Burrow dark and Burrow light both resolve to app.css's two
  Burrow blocks) and prints it.

  Named mutations, stage 5: (f) drop a formula from
  `PaintedComposite.formulas/0`; (g) revert a moved ground. Stage 5 r2: (h)
  sand light `--subtle` back to 55%; (i) re-add a per-pair floor below 4.5.
  Each turns this file red.

  Named mutations, task 01a15902 stage 2: `--faint` restored in one preset
  block. Named mutations (task 01a1557a stage 2 commit): (b) forest dark `--color-primary-content` to white; (c) delete
  midnight's light block; (d) a selector back to `[data-preset][data-theme]`
  at (0,2,0); (e) body back to the literal "Public Sans". Each turns this file
  red.
  """
  use ExUnit.Case, async: true

  alias Platform.Accounts.ThemePreference
  alias Platform.Branding.InstallBranding
  alias Platform.Branding.ThemeCss
  alias Platform.Design.PaintedComposite
  alias Platform.Design.PaintedGlass
  alias Platform.Design.WcagContrast, as: W
  alias Platform.Theming.ContrastPairs

  import Platform.Design.ThemeBlocks,
    only: [
      preset_blocks: 1,
      burrow_block: 2,
      declaration: 2,
      strip_comments: 1,
      rule_selectors: 1,
      blocks_after: 2
    ]

  import Platform.Design.ThemeBlockAssertions, only: [resolve!: 2]

  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @contrast_pairs_path Path.expand("../../../lib/platform/theming/contrast_pairs.ex", __DIR__)
  @plugin_open ~s(@plugin "../vendor/daisyui-theme" {)

  @modes ["dark", "light"]
  # Floors, pairs and grounds: Platform.Theming.ContrastPairs, the one list
  # (task 01a1557a-fe9b stage 1). No literal copy lives in this file.
  @aa_text ContrastPairs.aa_text()
  @non_text ContrastPairs.non_text()

  @canonical ~r/^\[data-preset="([a-z0-9-]+)"\]\[data-theme="(dark|light)"\]:not\(\[data-theme-preview\]\)$/

  @slots [
    "--color-base-100",
    "--color-base-200",
    "--color-base-300",
    "--edge",
    "--color-base-content",
    "--color-secondary",
    "--color-secondary-content",
    "--subtle",
    "--disabled",
    "--decorative",
    "--color-primary",
    "--color-primary-content",
    "--color-accent",
    "--color-accent-content",
    "--color-interactive",
    "--focus-ring",
    "--color-info",
    "--color-info-content",
    "--info-dim",
    "--color-success",
    "--color-success-content",
    "--success-dim",
    "--color-warning",
    "--color-warning-content",
    "--warning-dim",
    "--color-error",
    "--color-error-content",
    "--radius-box",
    "--radius-field",
    "--font-sans",
    "--density",
    "--glass-alpha",
    "--glass-blur"
  ]

  @grounds ContrastPairs.grounds()

  # --subtle's strength per block: base-content at 55%, the composite the
  # retired 55% utility painted, except where no ink clears 4.5:1 at 55%.
  @subtle_strength_overrides %{{"burrow-sand", "light"} => 57}
  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/

  # text-base-content/60 and daisyUI's .label paint base-content at 60%.
  @sixty ContrastPairs.sixty()

  # Every value that differs from the masters' theme.js, with the master value.
  @deviations %{
    {"burrow-midnight", "dark", "--color-primary-content"} => "#ffffff",
    {"burrow-midnight", "light", "--color-base-content"} => "#15202f",
    {"burrow-sand", "dark", "--color-primary-content"} => "#ffffff",
    {"burrow-sand", "light", "--color-base-content"} => "#2a2219",
    {"burrow-sand", "light", "--color-secondary"} => "#6b5a46",
    {"burrow-forest", "dark", "--color-primary-content"} => "#ffffff",
    {"burrow-forest", "light", "--color-base-content"} => "#1a241e",
    # Glass tab bar (task 01a1557a-7a71 stage 1): each alpha is the painted
    # floor (Platform.Design.PaintedGlass); High contrast is opaque by Saru's
    # rule 2. The ratio is the worst tab label over #000 and #fff, both builds.
    {"burrow-midnight", "dark", "--glass-alpha"} => "0.72",
    {"burrow-midnight", "light", "--glass-alpha"} => "0.72",
    {"burrow-sand", "dark", "--glass-alpha"} => "0.72",
    {"burrow-sand", "light", "--glass-alpha"} => "0.72",
    {"burrow-forest", "dark", "--glass-alpha"} => "0.72",
    {"burrow-forest", "light", "--glass-alpha"} => "0.72",
    {"high-contrast", "dark", "--glass-alpha"} => "0.95",
    {"high-contrast", "light", "--glass-alpha"} => "0.95"
  }

  setup_all do
    css = File.read!(@presets_path)
    {:ok, css: css, app_css: File.read!(@app_css_path), blocks: preset_blocks(css)}
  end

  # ── registry ─────────────────────────────────────────────────────────────

  describe "registry" do
    test "every non-Burrow preset has a dark and a light block, and every block is registered",
         %{blocks: blocks} do
      ids = Enum.map(ThemePreference.presets(), & &1.id)
      assert "burrow" in ids and length(ids) == 5

      expected = for id <- ids, id != "burrow", mode <- @modes, into: MapSet.new(), do: {id, mode}
      declared = blocks |> Enum.map(&{&1.id, &1.mode})

      assert length(declared) == length(Enum.uniq(declared)),
             "a preset block is declared twice: #{inspect(declared -- Enum.uniq(declared))}"

      declared = MapSet.new(declared)

      assert MapSet.difference(expected, declared) == MapSet.new(),
             "registered presets with no block: " <>
               inspect(MapSet.to_list(MapSet.difference(expected, declared)))

      assert MapSet.difference(declared, expected) == MapSet.new(),
             "blocks for no registered preset (or for Burrow, which declares none): " <>
               inspect(MapSet.to_list(MapSet.difference(declared, expected)))
    end

    test "every selector naming data-preset has the canonical shape", %{css: css} do
      selectors = rule_selectors(css)
      refute selectors == []

      odd =
        for sel <- selectors,
            String.contains?(sel, "data-preset"),
            part <- String.split(sel, ","),
            not Regex.match?(@canonical, String.trim(part)),
            do: sel

      assert odd == [],
             "preset selectors must be exactly " <>
               ~s|[data-preset="<id>"][data-theme="<mode>"]:not([data-theme-preview]), got: | <>
               inspect(odd)
    end

    test "app.css imports theme_presets.css", %{app_css: app_css} do
      assert app_css =~ ~s(@import "./theme_presets.css";)
    end
  end

  # ── slots and contrast, per block ────────────────────────────────────────

  describe "every block" do
    test "declares the full slot list itself", %{blocks: blocks} do
      missing =
        for b <- blocks, slot <- @slots, declaration(b.decls, slot) == nil do
          "#{b.id} #{b.mode}: #{slot}"
        end

      assert missing == [], "slots not declared in the block:\n  " <> Enum.join(missing, "\n  ")
    end

    test "every text pair clears 4.5:1 (7:1 for High contrast)", %{blocks: blocks} do
      failures =
        for b <- blocks,
            target = target(b),
            {text, ground} <- text_pairs(),
            r = ratio(b, text, ground),
            r < target do
          "#{b.id} #{b.mode}: #{text} on #{ground} #{fixed4(r)}:1 < #{target}"
        end

      assert failures == [], Enum.join(failures, "\n")
    end

    test "the faint tier is retired: no block declares --faint", %{
      blocks: blocks,
      app_css: app_css
    } do
      app = strip_comments(app_css)

      found =
        for(b <- blocks, declaration(b.decls, "--faint") != nil, do: "#{b.id} #{b.mode}") ++
          for(
            {label, re} <- [
              {"app.css declares --faint", ~r/--faint\s*:/},
              {"app.css maps or reads --color-faint", ~r/--color-faint\b/},
              {"app.css reads var(--faint)", ~r/var\(--faint\)/}
            ],
            Regex.match?(re, app),
            do: label
          )

      assert found == [],
             "--faint is back in #{inspect(found)}. Text has two levels, body and " <>
               "subtle (task 01a15902 stage 2); placeholders paint --subtle."
    end

    test "--subtle is base-content at 55%, or at the block's recorded override", %{
      blocks: blocks
    } do
      got = for b <- blocks, into: %{}, do: {{b.id, b.mode}, subtle_strength(b)}
      want = for b <- blocks, into: %{}, do: {{b.id, b.mode}, expected_subtle(b)}
      assert got == want
    end

    # The two WCAG-exempt text colours (task 01a15902 stage 1): one form in
    # every block, no contrast floor; text_exemption_guard_test.exs holds
    # where each may be used.
    test "--disabled and --decorative are base-content at 40% in every block", %{
      blocks: blocks
    } do
      want = "color-mix(in oklab, var(--color-base-content) 40%, transparent)"

      failures =
        for b <- blocks,
            token <- ["--disabled", "--decorative"],
            declaration(b.decls, token) != want,
            do: "#{b.id} #{b.mode} #{token}: #{inspect(declaration(b.decls, token))}"

      assert failures == [], "not #{want}:\n" <> Enum.join(failures, "\n")
    end

    test "--subtle clears 4.5:1 on all three grounds, painted, with no exemption", %{
      blocks: blocks
    } do
      failures =
        for b <- blocks,
            ground <- @grounds,
            r = subtle(b, ground),
            r < @aa_text do
          "#{b.id} #{b.mode}: --subtle (#{subtle_strength(b)}%) on #{ground} #{fixed4(r)}:1"
        end

      assert failures == [], Enum.join(failures, "\n")
    end

    test "base-content at 60% clears 4.5:1 on all three grounds, painted", %{blocks: blocks} do
      failures =
        for b <- blocks,
            ground <- @grounds,
            r = ink_at(b, ground, @sixty),
            r < @aa_text,
            do: "#{b.id} #{b.mode}: base-content at 60% on #{ground} #{fixed4(r)}:1"

      assert failures == [], Enum.join(failures, "\n")
    end

    test "the focus ring clears #{@non_text}:1 on all three grounds", %{blocks: blocks} do
      failures =
        for b <- blocks,
            ground <- @grounds,
            r = ratio(b, "--focus-ring", ground),
            r < @non_text,
            do: "#{b.id} #{b.mode}: #{ground} #{fixed4(r)}"

      assert failures == [], Enum.join(failures, "\n")
    end
  end

  test "no contrast exemption exists: no comment declares one and no guard floor is below 4.5",
       %{css: css, app_css: app_css} do
    for {name, text} <- [{"theme_presets.css", css}, {"app.css", app_css}] do
      refute text =~ ~r/\bEXEMPT/,
             "#{name} declares a contrast EXEMPTION; the brand rule allows none"
    end

    guards =
      for(
        f <- ["theme_presets_guard_test.exs", "burrow_palette_guard_test.exs"],
        do: {f, File.read!(Path.join(__DIR__, f))}
      ) ++
        [{"contrast_pairs.ex", File.read!(@contrast_pairs_path)}]

    for {f, src} <- guards do
      # A per-pair floor is a map entry or attribute set to a ratio under 4.5.
      low = Regex.scan(~r/(?:=>|@\w+)\s+(4\.[0-4]\d*)\b/, src)

      assert low == [],
             "#{f} holds something to a floor under 4.5:1: #{inspect(low)}. " <>
               "Fix the colour instead."
    end

    # The detector can fire: it finds the stage-5 floor in this very shape.
    # (The sample is assembled so this file's own source does not match.)
    sample = ~s(%{{"burrow-sand", "light", "--color-base-300"} =) <> "> " <> Float.to_string(4.34)
    assert Regex.match?(~r/(?:=>|@\w+)\s+(4\.[0-4]\d*)\b/, sample)
  end

  test "every deviation from theme.js is commented with the master value and its ratio",
       %{blocks: blocks} do
    failures =
      Enum.flat_map(@deviations, fn {{id, mode, token}, master} ->
        b = Enum.find(blocks, &(&1.id == id and &1.mode == mode))
        deviation_problems(b, id, mode, token, master)
      end)

    assert failures == [], Enum.join(failures, "\n")
  end

  # ── specificity ──────────────────────────────────────────────────────────

  test "every preset selector is strictly more specific than every ThemeCss selector",
       %{css: css} do
    theme_css =
      ThemeCss.render(%InstallBranding{light_action: "#336699", dark_action: "#336699"})

    install_selectors =
      Regex.scan(~r/([^{}]+)\{--/, theme_css, capture: :all_but_first)
      |> Enum.flat_map(fn [s] -> String.split(s, ",") end)
      |> Enum.map(&String.trim/1)

    # The guard has to see something to compare against.
    assert length(install_selectors) == 4, inspect(install_selectors)
    strongest = install_selectors |> Enum.map(&specificity/1) |> Enum.max()
    assert strongest == {0, 2, 0}

    preset_selectors =
      for sel <- rule_selectors(css),
          String.contains?(sel, "data-preset"),
          part <- String.split(sel, ","),
          do: String.trim(part)

    assert length(preset_selectors) == 8

    weak = for s <- preset_selectors, specificity(s) <= strongest, do: {s, specificity(s)}

    assert weak == [],
           "these preset selectors lose to an install colour (ThemeCss is #{inspect(strongest)} " <>
             "and comes later): #{inspect(weak)}"

    # A nested swatch carries the same attributes, so the selector must not be
    # tied to the document root.
    for s <- preset_selectors, do: refute(s =~ ~r/:root|\bhtml\b/)
  end

  # ── font ─────────────────────────────────────────────────────────────────

  test "no --font-sans inside a daisyUI plugin block, and body reads var(--font-sans)",
       %{app_css: app_css, css: css} do
    plugin_blocks = blocks_after(app_css, @plugin_open)
    assert length(plugin_blocks) == 2

    for block <- plugin_blocks do
      refute declaration(block, "--font-sans"),
             "a daisyui-theme block declares --font-sans; the plugin splits comma stacks"
    end

    refute strip_comments(css) =~ "@plugin"

    [body] = blocks_after(app_css, "\nbody, .font-suite {")
    assert declaration(strip_comments(body), "font-family") == "var(--font-sans)"

    # With no preset the variable resolves to Burrow's un-layered :root stack.
    root_stacks =
      app_css
      |> blocks_after("\n:root {")
      |> Enum.map(&declaration(strip_comments(&1), "--font-sans"))
      |> Enum.reject(&is_nil/1)

    assert root_stacks == [~s("Public Sans", system-ui, sans-serif)]
  end

  # ── the 12-row AA table ──────────────────────────────────────────────────

  test "the 12-row AA table: every master preset x mode passes", %{
    blocks: blocks,
    app_css: app_css
  } do
    burrow = for mode <- @modes, into: %{}, do: {mode, burrow_block(app_css, mode)}

    rows =
      for master <- ["burrow-dark", "burrow-light"], mode <- @modes do
        {"#{master} #{mode}", Map.fetch!(burrow, mode)}
      end ++
        for id <- ["burrow-midnight", "burrow-sand", "high-contrast", "burrow-forest"],
            mode <- @modes do
          {"#{id} #{mode}", Enum.find(blocks, &(&1.id == id and &1.mode == mode))}
        end

    assert length(rows) == 12

    lines =
      for {label, b} <- rows do
        {subtle_min, subtle_ground} = painted_cell(b, subtle_strength(b))
        {sixty_min, _} = painted_cell(b, @sixty)

        cells = [
          min_over(b, "--color-base-content"),
          min_over(b, "--color-secondary"),
          min_over(b, "--color-interactive"),
          ratio(b, "--color-primary-content", "--color-primary"),
          subtle_min,
          sixty_min
        ]

        "| #{label} | " <>
          Enum.map_join(cells, " | ", &fixed2/1) <>
          " | #{subtle_strength(b)}% (min on #{String.replace_prefix(subtle_ground, "--color-", "")})" <>
          " | #{fixed2(target(b))} | pass |"
      end

    IO.puts(
      "\nTheme preset AA table (min ratio over base-100/200/300 unless noted; " <>
        "subtle and ink@60% are painted, on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | ink | muted | interactive | on-accent | subtle | ink@60% | subtle strength | target | verdict |\n" <>
        "|---|---|---|---|---|---|---|---|---|---|\n" <> Enum.join(lines, "\n")
    )
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp text_pairs, do: ContrastPairs.preset_text_pairs()

  defp target(b), do: ContrastPairs.text_floor(b.id)

  defp min_over(b, token), do: @grounds |> Enum.map(&ratio(b, token, &1)) |> Enum.min()

  # base-content painted at `strength`%, on the worst pixel the measured
  # browser formulas allow.
  defp ink_at(b, ground, strength) do
    {r, _formulas} =
      PaintedComposite.contrast_min(
        resolve!(b, "--color-base-content"),
        resolve!(b, ground),
        strength
      )

    r
  end

  defp subtle(b, ground), do: ink_at(b, ground, subtle_strength(b))

  # The strength --subtle declares, read from the block, in its one allowed form.
  defp subtle_strength(b) do
    value = declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}, not #{inspect(@subtle_form)}")
    end
  end

  defp expected_subtle(b), do: Map.get(@subtle_strength_overrides, {b.id, b.mode}, 55)

  # {min painted ratio over the three grounds, the ground that sets it}.
  defp painted_cell(b, strength) do
    @grounds
    |> Enum.map(&{ink_at(b, &1, strength), &1})
    |> Enum.min_by(&elem(&1, 0))
  end

  defp ratio(b, a, c), do: W.contrast(resolve!(b, a), resolve!(b, c))

  defp deviation_problems(nil, id, mode, _token, _master), do: ["#{id} #{mode}: no block"]

  defp deviation_problems(b, id, mode, token, master) do
    value = declaration(b.decls, token)
    measured = fixed4(measure(b, token))

    [
      (value != nil and String.downcase(value) == master) &&
        "#{id} #{mode} #{token} serves the failing master value #{master}",
      not String.contains?(b.raw, "theme.js #{master}") &&
        "#{id} #{mode} #{token}: no comment naming theme.js #{master}",
      not String.contains?(b.raw, measured <> ":1") &&
        "#{id} #{mode} #{token}: comment does not record the recomputed #{measured}:1"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp measure(b, "--color-primary-content"),
    do: ratio(b, "--color-primary-content", "--color-primary")

  defp measure(b, "--color-base-content"), do: @grounds |> Enum.map(&subtle(b, &1)) |> Enum.min()

  # The worst tab label (inactive or active) on the painted glass at the
  # block's declared alpha, over both backdrops, on both builds.
  defp measure(b, "--glass-alpha") do
    alpha = declaration(b.decls, "--glass-alpha")

    for build <- PaintedGlass.builds(),
        bd <- PaintedGlass.backdrops(),
        layer <- [:inactive_label, :active_label] do
      PaintedGlass.contrast(build, "#{b.id} #{b.mode}", bd, alpha, layer)
    end
    |> Enum.min()
  end

  defp measure(b, token), do: min_over(b, token)

  defp fixed4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)
  defp fixed2(r), do: :erlang.float_to_binary(r / 1, decimals: 2)

  # Block parsing (preset_blocks/1, burrow_block/2, resolve!/2, declaration/2,
  # strip_comments/1, rule_selectors/1, blocks_after/2) lives in
  # Platform.Design.ThemeBlocks, shared with agent_slot_tokens_guard_test.exs.

  # CSS Selectors 4 specificity {ids, classes/attributes/pseudo-classes, types}
  # for the compound selectors this file and ThemeCss use. :not() and :is()
  # count their most specific argument; :where() counts nothing.
  defp specificity(sel), do: spec(String.trim(sel), {0, 0, 0})

  defp spec("", acc), do: acc

  defp spec(sel, acc) do
    cond do
      m = Regex.run(~r/^:(not|is|where)\(/, sel) ->
        [whole, kind] = m
        {inner, rest} = take_parens(String.slice(sel, String.length(whole)..-1//1), 1, "")

        inner_spec =
          if kind == "where",
            do: {0, 0, 0},
            else: inner |> String.split(",") |> Enum.map(&specificity/1) |> Enum.max()

        spec(rest, add(acc, inner_spec))

      m = Regex.run(~r/^\[[^\]]*\]/, sel) ->
        next(sel, m, add(acc, {0, 1, 0}))

      m = Regex.run(~r/^#[\w-]+/, sel) ->
        next(sel, m, add(acc, {1, 0, 0}))

      m = Regex.run(~r/^\.[\w-]+/, sel) ->
        next(sel, m, add(acc, {0, 1, 0}))

      m = Regex.run(~r/^::[\w-]+/, sel) ->
        next(sel, m, add(acc, {0, 0, 1}))

      m = Regex.run(~r/^:[\w-]+/, sel) ->
        next(sel, m, add(acc, {0, 1, 0}))

      m = Regex.run(~r/^[a-zA-Z][\w-]*/, sel) ->
        next(sel, m, add(acc, {0, 0, 1}))

      m = Regex.run(~r/^[\s>+~*]+/, sel) ->
        next(sel, m, acc)

      true ->
        flunk("specificity/1 cannot parse #{inspect(sel)}")
    end
  end

  defp next(sel, [whole | _], acc), do: spec(String.slice(sel, String.length(whole)..-1//1), acc)

  defp add({a, b, c}, {x, y, z}), do: {a + x, b + y, c + z}

  defp take_parens(")" <> rest, 1, acc), do: {acc, rest}
  defp take_parens(")" <> rest, n, acc), do: take_parens(rest, n - 1, acc <> ")")
  defp take_parens("(" <> rest, n, acc), do: take_parens(rest, n + 1, acc <> "(")

  defp take_parens(<<c::utf8, rest::binary>>, n, acc),
    do: take_parens(rest, n, acc <> <<c::utf8>>)

  defp take_parens("", _n, _acc), do: flunk("unbalanced parentheses in a selector")
end
