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
      (`burrow_palette_guard_test.exs`), plus muted and faint on all three
      grounds, faint on the thread composer's literal `#252c3d` fill in dark,
      `--subtle` (text-subtle, base-content at the block's own strength) and
      base-content at 60% (text-base-content/60, daisyUI .label), both painted,
      clears 4.5:1, or 7:1 for High contrast's full-strength text. Faint stays
      more than 0.5:1 dimmer than muted on each of the three grounds.
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
      master value in a comment, beside its own recomputed ratio.
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

  Named mutations (task 01a1557a stage 2 commit): (a) sand dark `--faint` back
  to `#7f7462`; (b) forest dark `--color-primary-content` to white; (c) delete
  midnight's light block; (d) a selector back to `[data-preset][data-theme]`
  at (0,2,0); (e) body back to the literal "Public Sans". Each turns this file
  red.
  """
  use ExUnit.Case, async: true

  alias Platform.Accounts.ThemePreference
  alias Platform.Branding.InstallBranding
  alias Platform.Branding.ThemeCss
  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W

  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @plugin_open ~s(@plugin "../vendor/daisyui-theme" {)

  @modes ["dark", "light"]
  @aa_text 4.5
  @aaa_text 7.0
  @non_text 3.0
  @tier_gap 0.5

  # The thread composer's background (app.css `.thread-input`) is a literal,
  # not a token, so it paints under every preset. Rung 1 raised Burrow's dark
  # faint to clear it; the presets' dark faints do the same.
  @composer_fill "#252c3d"

  @canonical ~r/^\[data-preset="([a-z0-9-]+)"\]\[data-theme="(dark|light)"\]:not\(\[data-theme-preview\]\)$/

  @slots [
    "--color-base-100",
    "--color-base-200",
    "--color-base-300",
    "--edge",
    "--color-base-content",
    "--color-secondary",
    "--color-secondary-content",
    "--faint",
    "--subtle",
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

  # Same list as burrow_palette_guard_test.exs.
  @text_pairs [
    {"--color-base-content", "--color-base-100"},
    {"--color-base-content", "--color-base-200"},
    {"--color-base-content", "--color-base-300"},
    {"--color-primary-content", "--color-primary"},
    {"--color-accent-content", "--color-accent"},
    {"--color-secondary-content", "--color-secondary"},
    {"--color-info-content", "--color-info"},
    {"--color-success-content", "--color-success"},
    {"--color-warning-content", "--color-warning"},
    {"--color-error-content", "--color-error"},
    {"--color-interactive", "--color-base-100"},
    {"--color-interactive", "--color-base-200"},
    {"--color-interactive", "--color-base-300"}
  ]

  @grounds ["--color-base-100", "--color-base-200", "--color-base-300"]

  # --subtle's strength per block: base-content at 55%, the composite the
  # retired 55% utility painted, except where no ink clears 4.5:1 at 55%.
  @subtle_strength_overrides %{{"burrow-sand", "light"} => 57}
  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/

  # text-base-content/60 and daisyUI's .label paint base-content at 60%.
  @sixty 60

  # Every value that differs from the masters' theme.js, with the master value.
  @deviations %{
    {"burrow-midnight", "dark", "--faint"} => "#687a99",
    {"burrow-midnight", "dark", "--color-primary-content"} => "#ffffff",
    {"burrow-midnight", "light", "--color-base-content"} => "#15202f",
    {"burrow-midnight", "light", "--faint"} => "#8794a8",
    {"burrow-sand", "dark", "--faint"} => "#7f7462",
    {"burrow-sand", "dark", "--color-primary-content"} => "#ffffff",
    {"burrow-sand", "light", "--color-base-content"} => "#2a2219",
    {"burrow-sand", "light", "--color-secondary"} => "#6b5a46",
    {"burrow-sand", "light", "--faint"} => "#a08f78",
    {"burrow-forest", "dark", "--faint"} => "#6b7c72",
    {"burrow-forest", "dark", "--color-primary-content"} => "#ffffff",
    {"burrow-forest", "light", "--color-base-content"} => "#1a241e",
    {"burrow-forest", "light", "--faint"} => "#88978e",
    {"high-contrast", "dark", "--faint"} => "#9a9a9a",
    {"high-contrast", "light", "--faint"} => "#555555"
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

    test "dark faint clears 4.5:1 on the thread composer fill #{@composer_fill}", %{
      blocks: blocks
    } do
      failures =
        for b <- blocks,
            b.mode == "dark",
            r = W.contrast(resolve!(b, "--faint"), W.hex(@composer_fill)),
            r < @aa_text,
            do: "#{b.id}: #{fixed4(r)}:1"

      assert failures == [], Enum.join(failures, "\n")
    end

    test "faint is dimmer than muted by more than #{@tier_gap}:1 on each ground", %{
      blocks: blocks
    } do
      failures =
        for b <- blocks,
            ground <- @grounds,
            gap = ratio(b, "--color-secondary", ground) - ratio(b, "--faint", ground),
            gap <= @tier_gap,
            do: "#{b.id} #{b.mode} on #{ground}: #{fixed4(gap)}"

      assert failures == [], "faint and muted merge:\n" <> Enum.join(failures, "\n")
    end

    test "--subtle is base-content at 55%, or at the block's recorded override", %{
      blocks: blocks
    } do
      got = for b <- blocks, into: %{}, do: {{b.id, b.mode}, subtle_strength(b)}
      want = for b <- blocks, into: %{}, do: {{b.id, b.mode}, expected_subtle(b)}
      assert got == want
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
      for f <- ["theme_presets_guard_test.exs", "burrow_palette_guard_test.exs"],
          do: {f, File.read!(Path.join(__DIR__, f))}

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
          min_over(b, "--faint"),
          min_over(b, "--color-interactive"),
          ratio(b, "--color-primary-content", "--color-primary"),
          subtle_min,
          sixty_min
        ]

        composer =
          if b.mode == "dark",
            do: fixed2(W.contrast(resolve!(b, "--faint"), W.hex(@composer_fill))),
            else: "n/a"

        "| #{label} | " <>
          Enum.map_join(cells, " | ", &fixed2/1) <>
          " | #{subtle_strength(b)}% (min on #{String.replace_prefix(subtle_ground, "--color-", "")})" <>
          " | #{composer} | #{fixed2(target(b))} | pass |"
      end

    IO.puts(
      "\nTheme preset AA table (min ratio over base-100/200/300 unless noted; " <>
        "subtle and ink@60% are painted, on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | ink | muted | faint | interactive | on-accent | subtle | ink@60% | subtle strength | faint on #252c3d | target | verdict |\n" <>
        "|---|---|---|---|---|---|---|---|---|---|---|---|\n" <> Enum.join(lines, "\n")
    )
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp text_pairs do
    @text_pairs ++
      for(g <- @grounds, do: {"--color-secondary", g}) ++ for(g <- @grounds, do: {"--faint", g})
  end

  defp target(%{id: "high-contrast"}), do: @aaa_text
  defp target(_), do: @aa_text

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
  defp measure(b, token), do: min_over(b, token)

  defp fixed4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)
  defp fixed2(r), do: :erlang.float_to_binary(r / 1, decimals: 2)

  # Blocks in theme_presets.css, keyed by the canonical selector.
  defp preset_blocks(css) do
    Regex.scan(~r/^(\[data-preset[^\n{]*)\{(.*?)\n\}/ms, css, capture: :all_but_first)
    |> Enum.flat_map(fn [sel, body] ->
      case Regex.run(@canonical, String.trim(sel)) do
        [_, id, mode] -> [%{id: id, mode: mode, raw: body, decls: strip_comments(body)}]
        nil -> []
      end
    end)
  end

  # Burrow's two variants, built from app.css the way the Burrow guard resolves
  # them: the daisyUI theme block, then the theme-scoped selectors, then :root.
  defp burrow_block(app_css, mode) do
    theme =
      app_css
      |> blocks_after(@plugin_open)
      |> Enum.find(&Regex.match?(~r/^\s*name:\s*"#{mode}";/m, &1))

    scoped =
      if mode == "dark", do: blocks_after(app_css, ~s(\n[data-theme="dark"] {)), else: []

    decls =
      Enum.map_join(
        [theme | scoped] ++ blocks_after(app_css, "\n:root {"),
        "\n",
        &strip_comments/1
      )

    %{id: "burrow", mode: mode, raw: "", decls: decls}
  end

  defp resolve!(b, var, depth \\ 0)
  defp resolve!(b, var, depth) when depth > 8, do: flunk("#{b.id} #{b.mode}: #{var} loops")

  defp resolve!(b, var, depth) do
    value = declaration(b.decls, var) || flunk("#{b.id} #{b.mode}: no #{var} declared")

    case Regex.run(~r/^var\(\s*(--[A-Za-z0-9_-]+)\s*\)$/, value) do
      [_, next] -> resolve!(b, next, depth + 1)
      nil -> W.parse!(value)
    end
  end

  defp strip_comments(text), do: Regex.replace(~r{/\*.*?\*/}s, text, "")

  defp rule_selectors(css) do
    css
    |> strip_comments()
    |> then(&Regex.scan(~r/^([^\s{}][^{}]*)\{/m, &1, capture: :all_but_first))
    |> Enum.map(fn [s] -> String.trim(s) end)
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

  # First match wins, as the Burrow guard reads it.
  defp declaration(block, var) do
    case Regex.run(~r/^\s*#{Regex.escape(var)}\s*:\s*([^;]+);/m, block) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

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
