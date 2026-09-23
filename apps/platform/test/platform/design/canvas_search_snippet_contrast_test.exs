defmodule Platform.Design.CanvasSearchSnippetContrastTest do
  @moduledoc """
  Contrast for the canvases drawer, BOTH THEMES. Two elements, two tickets:
  the search snippet (task `01a077e6` stage 1) and the partial-index line
  (task `01a0792c` stage 2). One file because they share the drawer, the two
  `daisyui-theme` blocks and the same reader helpers; the snippet sections
  come first and the partial-index sections are marked as their own.

  ## Why this file exists

  The design canvas for this ticket specified the snippet's palette in the
  light theme only, and justified its contrast figure "on white". Two of the
  three slots it named do not survive the dark theme, and neither failure is
  visible to anyone reviewing on a laptop in light mode:

    * `--color-neutral` for the context runs. In dark it is `oklch(40% 0.01 0)`,
      which resolves to #4D4647 and lands at **1.64:1** on this row's ground —
      illegible, and far below the AA 4.5:1 this 12px text owes. (The ticket
      estimated 3.2:1 from the `/* #6A6A6A */` comment sitting on that
      declaration in `app.css`. That comment is wrong: `oklch(40% 0.01 0)` is
      not #6A6A6A, and the light one's `~#737373` is wrong the same way. The
      declarations are what this file reads; the comments are not asserted here
      and are left alone, but they are worth a follow-up.)
    * `--color-base-300` for the match fill. In dark it renders #091821, DARKER
      than the row's own ground, giving **1.19:1** in the wrong direction: a
      highlight that reads as a hole. That is the same hazard `app.css` records
      at the `--edge` declaration, which exists because base-300 could not be
      retuned without breaking its other job.

  ## What shipped instead, and why it is one declaration rather than two

  Both slots moved onto `--color-base-content`, at 65% for the context runs and
  20% for the match fill. That token is redefined per theme, so a single
  declaration resolves correctly in both with no second selector to keep in
  step — the property `app.css` already relies on elsewhere in this rule.

  It is also not a departure from the canvas's numbers where the canvas had
  them right: `--color-base-content` at 65% on this ground measures 6.6964:1 in
  light, against `--color-neutral`'s 6.6974:1. The light theme's specified
  recession is preserved to within 0.001, and dark goes from 1.64:1 to 6.40:1.

  The canvas's INTENT is unchanged and is what the clauses below hold: emphasis
  by **weight plus a neutral ground**, never by hue. `--color-primary` (cyan is
  the action slot) and `--color-warning` (amber means a human is being asked for
  something) are both forbidden here, which is also what removed the
  translucent cyan wash this rule shipped with in task 01a07402.

  ## How the clauses are arranged

  Every input is READ OUT OF THE FILE THAT DECLARES IT, never typed in:

    * the two theme blocks in `app.css`, for `--color-base-100`,
      `--color-base-content` and `--edge`
    * the `[data-role="canvas-result-snippet"] mark` rule in `app.css`, for the
      fill's token and its percentage
    * the container's own `class` attribute in `canvas_explorer.ex`, for the
      ground's alpha (`bg-base-content/5`) and the context runs'
      (`text-base-content/65`)

  So retuning a token, the fill percentage or a Tailwind opacity modifier moves
  these numbers rather than leaving a stale pin behind. A version of this file
  with the resolved colours hardcoded would go on passing after any of those
  changes, which is the failure mode it is arranged against.

  The separation floor for the fill is not a number of my choosing either. It
  is whatever `--edge` achieves against `--color-base-100` in the same theme
  (1.4355:1 light, 1.1966:1 dark) — this stylesheet's own shipped answer to
  "a boundary that reads", and a conservative floor for a filled chip, which
  has area a 1px hairline does not.

  ## THE PARTIAL-INDEX LINE (task `01a0792c`)

  `[data-role="canvas-search-indexing-state"]` carries the caveat "Older
  canvases are still being indexed…". It is a direct child of the drawer's own
  `bg-base-200` box, outside every result row. It shipped as a bare `text-neutral` utility at
  11px and measured **2.25:1 in dark**, a WCAG 1.4.3 AA failure on text that
  owes 4.5:1. Stage 1 left `--color-neutral` alone (it is also a FILL paired
  with `--color-neutral-content`, and lifting it would break that job) and
  added an unlayered rule scoped to the element, moving dark onto the
  `--color-base-content` alpha ramp. Light keeps the utility and its own
  passing figure, so there is exactly one declaration.

  The clauses for it are a PAIR and neither half stands alone, the same
  arrangement `candidate_closed_row_contrast_test.exs` sets out:

    * a STRUCTURAL half: dark declares a scoped colour, the
      `prefers-color-scheme` twin declares the identical one, light declares
      none at all, and the drawer box is an opaque `bg-base-200` so there is
      one ground rather than several.
    * a COMPUTED half: the colour is recomputed through **whatever token and
      whatever percentage that rule declares**, composited over the ground the
      drawer's class actually resolves to, and asserted at 4.5:1.

  The structural half alone cannot tell a correct value from a decayed one.
  The computed half alone cannot tell a scoped fix from a rule that was
  deleted and a token retuned underneath it. The named mutation is: **move the
  shipped percentage one step down, to the level where the ratio lands just
  under 4.5:1, and change nothing else.** The computed clause must go red and
  name this element. If it does not move, it is reading a declared property
  rather than the composited one and it proves nothing about this ticket.
  That is a finding to report, not something to iterate on until it dies.

  One ground and not three. The attribution line corrected on task `01a07402`
  sits on a result ROW, so it owed rest, hover and active figures. This one
  does not: stage 1 walked the live ancestry and found every ancestor between
  the line and the drawer box computing `rgba(0, 0, 0, 0)`, with the line's
  sampled pixels bit-identical under a hovered row, a hovered line and a
  SELECTED row. Enumerating the grounds found one, so one is asserted. The
  opaque-`bg-base-200` clause is what keeps that true.

  ## What this file cannot tell you

  Nothing here proves the row lays out correctly. It is arithmetic on declared
  colours. Whether the match is on screen at 375px is a browser measurement and
  belongs to stage 2.

  It equally cannot prove what the browser PAINTS, for either element. A
  painted-pixel read (CDP screenshot, sampled) is hex-to-hex and quantises to
  8-bit, so no `oklch()` survives into its arithmetic; this file converts
  `oklch()` itself and carries floats through. The two are different
  quantities and they disagree in the second or third decimal here. Stage 1's
  live CDP measurement read the partial-index line at 5.5179:1 in dark where
  the declaration-derived computation below gives 5.5449:1. Neither is wrong.
  Every figure in THIS file is declaration-derived; the browser measurement is
  stage 1's and lives in its commit message and evidence canvas.
  """

  use ExUnit.Case, async: true

  alias Platform.Design.CssRules
  alias Platform.Design.WcagContrast, as: W

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)
  # The snippet markup MOVED in task 01a0740d stage 3, from
  # `Conversation.canvas_result_snippet/1` to
  # `CanvasExplorer.explorer_row_snippet/1`, when the explorer took over the
  # drawer's results rows. The classes, the data-roles and the `<mark>` rule are
  # the shipped ones — only the file changed — so every pin below still resolves
  # to the same colours.
  #
  # This path being wrong does not fail a test; it fails `setup_all`, which
  # marks all 14 tests here INVALID and leaves the suite reading "0 failures".
  # That is exactly what happened on the first full run of that stage, and it is
  # the reason this comment names the file rather than leaving the path bare.
  @template_path Path.expand(
                   "../../../lib/platform_web/components/canvases/canvas_explorer.ex",
                   __DIR__
                 )

  # The partial-index line and the drawer box it sits on both live in
  # `canvases_drawer/1`, which stayed behind when task 01a0740d moved the
  # results rows out to the explorer. Same `setup_all` hazard as the path
  # above: wrong path, no failing test, every case here INVALID.
  @drawer_path Path.expand(
                 "../../../lib/platform_web/live/chat/partials/conversation.ex",
                 __DIR__
               )

  # Pins are stated to 4 decimals; the tolerance absorbs float noise only. Every
  # pair resolves deterministically from the two files, so a real change to any
  # input moves the value by orders of magnitude more than this.
  @tolerance 0.001

  # AA for body text. The snippet is `text-xs` (12px) at normal weight, so the
  # large-text 3:1 allowance does not apply to it.
  @aa_text 4.5

  setup_all do
    css = File.read!(@css_path)
    template = File.read!(@template_path)
    drawer = File.read!(@drawer_path)

    container_class = container_class!(template)

    fill = mark_fill!(css)

    drawer_class = drawer_box_class!(drawer)
    indexing_class = indexing_line_class!(drawer)

    {:ok,
     ground_alpha: tailwind_alpha!(container_class, "bg-base-content"),
     context_alpha: tailwind_alpha!(container_class, "text-base-content"),
     fill_spec: fill,
     mark_rule: rule_body!(css, ~s([data-role="canvas-result-snippet"] mark)),
     drawer_ground_token: opaque_bg_token!(drawer_class),
     indexing_utility_token: text_utility_token!(indexing_class),
     indexing_rules: %{
       "light" => indexing_color_rules(css, "light", drawer_class, indexing_class),
       "dark" => indexing_color_rules(css, "dark", drawer_class, indexing_class)
     },
     light: theme_colors!(css, "light", fill.token),
     dark: theme_colors!(css, "dark", fill.token)}
  end

  # The fill colour the rule actually declares, composited over the row's
  # ground: whatever token, at whatever percentage.
  defp fill_color(colors, fill_spec, ground) do
    W.composite(colors.fill_token, fill_spec.alpha, ground)
  end

  test "the converter is sound before anything below is trusted" do
    # A wrong oklch conversion would make every clause here pass for the wrong
    # reason, which is how the `--color-neutral` comments in app.css came to
    # disagree with their own declarations in the first place.
    assert_in_delta W.contrast(W.hex("#FFFFFF"), W.hex("#000000")), 21.0, @tolerance
    assert_in_delta W.contrast(W.hex("#777777"), W.hex("#777777")), 1.0, @tolerance
    assert W.to_hex(W.parse!("oklch(100% 0 0)")) == "#FFFFFF"
    assert W.to_hex(W.parse!("oklch(0% 0 0)")) == "#000000"
  end

  describe "the match is emphasised by weight and a neutral ground, never by hue" do
    test "the fill is derived from --color-base-content", %{mark_rule: rule} do
      assert rule =~ "var(--color-base-content)",
             "the match fill must come from the neutral text token: #{rule}"
    end

    test "neither the brand nor the warning hue appears in the rule", %{mark_rule: rule} do
      # Cyan is the action slot and a match that is merely present is not an
      # action; amber means a human is being asked for something. This is the
      # clause that would have caught the translucent `--color-primary` wash
      # this rule shipped with, and it is why that wash is gone.
      refute rule =~ "--color-primary",
             "cyan is the action slot and is forbidden on this row: #{rule}"

      refute rule =~ "--color-warning",
             "amber means a human is being asked for something: #{rule}"

      refute rule =~ "--color-accent"
    end

    test "the weight step is carried by the rule, not by a class", %{mark_rule: rule} do
      # The SECOND and later marks in a fragment are emitted inside the trailing
      # context run by `marked_text/1` and cannot take a Tailwind class, so a
      # weight applied at the template would style the protected match alone and
      # leave the others looking like ordinary context.
      assert rule =~ ~r/font-weight:\s*[5-9]\d\d/,
             "the match needs a weight step, and it has to live in the CSS: #{rule}"
    end
  end

  for theme <- ["light", "dark"] do
    describe "the #{theme} theme" do
      @describetag theme: theme

      setup context do
        colors = Map.fetch!(context, String.to_existing_atom(context.theme))

        ground = W.composite(colors.content, context.ground_alpha, colors.base_100)

        {:ok,
         colors: colors,
         ground: ground,
         fill: fill_color(colors, context.fill_spec, ground),
         context_text: W.composite(colors.content, context.context_alpha, ground)}
      end

      test "the context runs clear AA on the row's ground", %{
        context_text: text,
        ground: ground
      } do
        ratio = W.contrast(text, ground)

        assert ratio >= @aa_text,
               "context text #{W.to_hex(text)} on #{W.to_hex(ground)} is #{fmt(ratio)}:1, " <>
                 "under AA #{@aa_text}:1 for 12px text"
      end

      test "the match text clears AA on the match fill", %{colors: colors, fill: fill} do
        # The mark rule pins `color` back to `--color-base-content` at full
        # strength, so this is the same pairing for the protected match and for
        # any later mark riding inside the trailing run.
        ratio = W.contrast(colors.content, fill)

        assert ratio >= @aa_text,
               "match text #{W.to_hex(colors.content)} on fill #{W.to_hex(fill)} is " <>
                 "#{fmt(ratio)}:1, under AA #{@aa_text}:1"
      end

      test "the match fill separates from the ground at least as well as --edge does",
           %{colors: colors, ground: ground, fill: fill} do
        floor = W.contrast(colors.edge, colors.base_100)
        ratio = W.contrast(fill, ground)

        assert ratio >= floor,
               "match fill #{W.to_hex(fill)} on #{W.to_hex(ground)} is #{fmt(ratio)}:1, " <>
                 "below this theme's own --edge separation of #{fmt(floor)}:1. A fill the " <>
                 "reader cannot see is not a highlight."
      end

      test "the fill moves TOWARD the text colour, not away from it", %{
        colors: colors,
        ground: ground,
        fill: fill
      } do
        # This is the clause `--color-base-300` fails in dark, and the reason
        # the canvas's named token was not used. A fill that is further from the
        # text than its own ground reads as a hole punched in the row rather
        # than as a raised chip, and it inverts between themes.
        assert W.contrast(fill, colors.content) < W.contrast(ground, colors.content),
               "fill #{W.to_hex(fill)} is further from the text colour than the ground " <>
                 "#{W.to_hex(ground)} is — that is a hole, not a highlight"
      end
    end
  end

  describe "the measured ratios" do
    # Pinned so a token move is visible as a number rather than only as a
    # threshold crossing. The thresholds above are what must hold; these say
    # what the shipped values actually are.
    test "light", %{light: c, ground_alpha: ga, context_alpha: ta, fill_spec: fs} do
      ground = W.composite(c.content, ga, c.base_100)
      fill = fill_color(c, fs, ground)

      assert_in_delta W.contrast(W.composite(c.content, ta, ground), ground), 6.6964, @tolerance
      assert_in_delta W.contrast(c.content, fill), 11.7647, @tolerance
      assert_in_delta W.contrast(fill, ground), 1.5980, @tolerance
      assert_in_delta W.contrast(c.edge, c.base_100), 1.4355, @tolerance
    end

    test "dark", %{dark: c, ground_alpha: ga, context_alpha: ta, fill_spec: fs} do
      ground = W.composite(c.content, ga, c.base_100)
      fill = fill_color(c, fs, ground)

      assert_in_delta W.contrast(W.composite(c.content, ta, ground), ground), 6.3992, @tolerance
      assert_in_delta W.contrast(c.content, fill), 7.2295, @tolerance
      assert_in_delta W.contrast(fill, ground), 1.8189, @tolerance
      assert_in_delta W.contrast(c.edge, c.base_100), 1.1966, @tolerance
    end
  end

  # ══ THE PARTIAL-INDEX LINE (task 01a0792c) ════════════════════════════════
  #
  # `[data-role="canvas-search-indexing-state"]`, on the drawer's own box. See
  # the moduledoc for why the two describes below are a PAIR and what the named
  # mutation for them is.

  describe "the partial-index line's correction is scoped to the element" do
    test "dark declares a colour for it, and the prefers-color-scheme twin declares the same one",
         %{indexing_rules: rules} do
      dark = rules["dark"]

      assert length(dark) == 2,
             "the canvas-search-indexing-state line needs BOTH dark selectors: the " <>
               "`[data-theme=\"dark\"]` one and its `prefers-color-scheme` twin. A viewer " <>
               "on \"system\" under a dark OS has no `data-theme` attribute at all " <>
               "(`setAppTheme(\"system\")` removes it), so the attribute selector alone " <>
               "silently stops applying and the 2.23:1 failure comes back for exactly the " <>
               "people who never touched the toggle. Found: " <>
               inspect(Enum.map(dark, & &1.selector))

      assert Enum.any?(dark, &(&1.at == [])),
             "neither dark rule is unconditional: #{inspect(Enum.map(dark, & &1.at))}"

      assert Enum.any?(dark, &match?(["@media (prefers-color-scheme: dark)"], &1.at)),
             "no `prefers-color-scheme: dark` twin: #{inspect(Enum.map(dark, & &1.at))}"

      specs = dark |> Enum.map(&color_mix_spec!(&1.body)) |> Enum.uniq()

      assert length(specs) == 1,
             "the two dark selectors for canvas-search-indexing-state declare DIFFERENT " <>
               "colours, so which one a viewer gets depends on how they chose the theme: " <>
               inspect(Enum.map(dark, & &1.body))
    end

    test "light declares none, so the line keeps its own utility there", %{
      indexing_rules: rules
    } do
      assert rules["light"] == [],
             "a rule now colours canvas-search-indexing-state in LIGHT: " <>
               inspect(Enum.map(rules["light"], & &1.selector)) <>
               ". Light passed before this ticket and was deliberately left on the " <>
               "`text-neutral` utility: one declaration instead of two, and nothing to " <>
               "keep in step. A second declaration needs its own measured figure."
    end

    test "the correction is not a hue", %{indexing_rules: rules} do
      for rule <- rules["dark"] do
        refute rule.body =~ "--color-primary",
               "cyan is the action slot and nothing is being asked of the reader here: " <>
                 rule.body

        refute rule.body =~ "--color-warning",
               "amber means a human is being asked for something; this line is " <>
                 "informational: " <> rule.body

        refute rule.body =~ "--color-error"
      end
    end

    test "the drawer box is an opaque bg-base-200, which is what makes ONE ground true", %{
      drawer_ground_token: token
    } do
      # `opaque_bg_token!` already flunks on an alpha modifier or a missing
      # background. This pins WHICH surface, so a move to another token is a
      # named failure rather than a silently re-grounded figure.
      assert token == "--color-base-200",
             "the canvases-drawer box's ground moved to #{token}. Every " <>
               "canvas-search-indexing-state figure in this file was measured on " <>
               "--color-base-200."
    end

    test "the light colour still comes from --color-neutral via the utility", %{
      indexing_utility_token: token
    } do
      assert token == "--color-neutral",
             "the partial-index line's text utility now resolves to #{token}, not " <>
               "--color-neutral. Light was left on that token on purpose; a change here " <>
               "needs a light measurement, which this ticket did not take."
    end
  end

  describe "the partial-index line clears AA on the drawer box" do
    test "dark, through whatever token and percentage the rule declares", %{
      dark: c,
      drawer_ground_token: ground_token,
      indexing_rules: rules
    } do
      ground = token_color!(c, ground_token)
      spec = dark_indexing_spec!(rules)
      text = W.composite(token_color!(c, spec.token), spec.alpha, ground)

      ratio = W.contrast(text, ground)

      assert ratio >= @aa_text,
             "canvas-search-indexing-state resolves to #{W.to_hex(text)} " <>
               "(#{spec.token} at #{round(spec.alpha * 100)}%) on #{W.to_hex(ground)} " <>
               "and is #{fmt(ratio)}:1 in DARK, under AA #{@aa_text}:1 for 11px text. " <>
               "11px carries no large-text allowance."
    end

    test "light, on the same box, from the token the utility names", %{
      light: c,
      drawer_ground_token: ground_token,
      indexing_utility_token: text_token
    } do
      ground = token_color!(c, ground_token)
      text = token_color!(c, text_token)

      ratio = W.contrast(text, ground)

      assert ratio >= @aa_text,
             "canvas-search-indexing-state is #{fmt(ratio)}:1 in LIGHT " <>
               "(#{W.to_hex(text)} on #{W.to_hex(ground)}), under AA #{@aa_text}:1. " <>
               "Light passed untouched through task 01a0792c; this is the regression " <>
               "control for the half that was NOT changed."
    end

    test "--color-neutral itself is unchanged against --color-neutral-content in dark", %{
      dark: c
    } do
      # The clause that catches a fix applied to the TOKEN instead of to the
      # element. `--color-neutral` is also a fill, and lifting it far enough to
      # rescue 11px text on the near-black drawer box drops this pairing under
      # the floor. Whoever tries it should fail here, not in a screenshot.
      ratio = W.contrast(c.neutral, c.neutral_content)

      assert ratio >= @aa_text,
             "--color-neutral on --color-neutral-content is now #{fmt(ratio)}:1 in dark, " <>
               "under AA #{@aa_text}:1. That token is a FILL as well as a text colour. If " <>
               "it was retuned to fix canvas-search-indexing-state, revert it: that line " <>
               "has its own scoped rule precisely so this pairing does not have to move."

      assert_in_delta ratio, 6.8701, @tolerance
    end
  end

  describe "the measured ratios, partial-index line" do
    # Declaration-derived, four decimals. Stage 1's painted-pixel reads of the
    # same three pairs were 5.5179, 6.6918 and 6.8383. That is the instrument gap the
    # moduledoc describes, not a disagreement about what shipped.
    test "dark, after the fix", %{
      dark: c,
      drawer_ground_token: ground_token,
      indexing_rules: rules
    } do
      ground = token_color!(c, ground_token)
      spec = dark_indexing_spec!(rules)

      assert_in_delta W.contrast(
                        W.composite(token_color!(c, spec.token), spec.alpha, ground),
                        ground
                      ),
                      5.5449,
                      @tolerance
    end

    test "dark, the defect this ticket fixed", %{dark: c, drawer_ground_token: ground_token} do
      # Pins the failure the scoped rule exists to route around, and with it
      # both of its inputs. A retune of either token that "fixes" the line by
      # moving this number is visible here as well as in the AA clauses.
      assert_in_delta W.contrast(c.neutral, token_color!(c, ground_token)), 2.2346, @tolerance
    end

    test "light, untouched", %{
      light: c,
      drawer_ground_token: ground_token,
      indexing_utility_token: text_token
    } do
      assert_in_delta W.contrast(token_color!(c, text_token), token_color!(c, ground_token)),
                      6.6599,
                      @tolerance
    end
  end

  # ── reading the two source files ──────────────────────────────────────────

  defp fmt(ratio), do: :erlang.float_to_binary(ratio, decimals: 4)

  defp theme_colors!(css, name, fill_token) do
    block = theme_block!(css, name)

    %{
      # Kept so a clause can resolve a token the snippet does not use: the
      # partial-index line's ground and its utility token are both read out of
      # markup, so which ones they are is not knowable here.
      block: block,
      base_100: color!(block, "--color-base-100"),
      content: color!(block, "--color-base-content"),
      edge: color!(block, "--edge"),
      neutral: color!(block, "--color-neutral"),
      neutral_content: color!(block, "--color-neutral-content"),
      fill_token: color!(block, fill_token)
    }
  end

  # A token named by markup rather than by this file, resolved in one theme.
  defp token_color!(colors, token), do: color!(colors.block, token)

  # The body of a `@plugin "../vendor/daisyui-theme" { ... }` block, chosen by
  # its `name:` line. Same extraction as primary_contrast_sweep_test.exs: a
  # matching value elsewhere in a 6000-line stylesheet must not be able to
  # satisfy a clause about one theme.
  defp theme_block!(css, name) do
    css
    |> String.split(~s(@plugin "../vendor/daisyui-theme" {))
    |> Enum.drop(1)
    |> Enum.map(&(&1 |> String.split(~r/^\}/m, parts: 2) |> hd()))
    |> Enum.find(&Regex.match?(~r/name:\s*"#{name}"/, &1))
    |> case do
      nil -> flunk("no daisyui-theme block named #{inspect(name)} in #{@css_path}")
      block -> block
    end
  end

  defp color!(block, token) do
    re = ~r/^[^\S\n]*#{Regex.escape(token)}:[^\S\n]*([^;\n]+);/m

    case Regex.run(re, block, capture: :all_but_first) do
      [value] -> value |> String.trim() |> W.parse!()
      nil -> flunk("no `#{token}:` declaration in the theme block being read.")
    end
  end

  defp rule_body!(css, selector) do
    re = ~r/^[^\S\n]*#{Regex.escape(selector)}\s*\{([^}]*)\}/m

    case Regex.run(re, css, capture: :all_but_first) do
      [body] ->
        body

      nil ->
        flunk(
          "no `#{selector} { ... }` rule starting a line in #{@css_path}. Every clause " <>
            "measured against it would be measuring nothing."
        )
    end
  end

  # The fill's DECLARED token and percentage, as `%{token: ..., alpha: ...}`.
  #
  # Deliberately not pinned to `--color-base-content`. A reader that insisted on
  # that token would flunk in setup for any other one, and the direction clause
  # below — the clause carrying the whole reason this rule does not use the
  # token the design canvas named — could then never fire, because no mutation
  # could reach it. Resolving whatever is declared is what makes swapping the
  # fill back to `--color-base-300` fail on the arithmetic and say why.
  defp mark_fill!(css) do
    body = rule_body!(css, ~s([data-role="canvas-result-snippet"] mark))

    re =
      ~r/background-color:\s*color-mix\(\s*in\s+\w+\s*,\s*var\((--[\w-]+)\)\s*([\d.]+)%\s*,\s*transparent\s*\)/

    case Regex.run(re, body, capture: :all_but_first) do
      [token, pct] ->
        {value, ""} = Float.parse(pct)
        %{token: token, alpha: value / 100.0}

      nil ->
        flunk(
          "the match fill is no longer a `color-mix` of a single token with transparent, " <>
            "so this file cannot say what colour it resolves to: #{body}"
        )
    end
  end

  # The snippet container's `class` attribute, out of the template itself. The
  # sub-role attributes carry a longer `data-role`, so the closing quote is what
  # keeps this matching the container and not one of its three children.
  defp container_class!(template) do
    re = ~r/data-role="canvas-result-snippet"\s+class="([^"]+)"/

    case Regex.run(re, template, capture: :all_but_first) do
      [class] ->
        class

      nil ->
        flunk(
          "no `data-role=\"canvas-result-snippet\"` element with a class attribute in " <>
            "#{@template_path}. The ground and context colours this file measures are " <>
            "read from that class."
        )
    end
  end

  # ── reading the partial-index line and its box (task 01a0792c) ────────────

  # The drawer's own box: the `<div :if={@show_canvases}>` that opens
  # `canvases_drawer/1`. Its class carries the ground every clause below
  # composites against.
  defp drawer_box_class!(drawer) do
    re = ~r/:if=\{@show_canvases\}\s+class="([^"]+)"/

    case Regex.run(re, drawer, capture: :all_but_first) do
      [class] ->
        class

      nil ->
        flunk(
          "no `:if={@show_canvases}` element with a class attribute in #{@drawer_path}. " <>
            "That element is the drawer box, and it is the ground every " <>
            "canvas-search-indexing-state clause here measures against."
        )
    end
  end

  defp indexing_line_class!(drawer) do
    re = ~r/data-role="canvas-search-indexing-state"\s+class="([^"]+)"/

    case Regex.run(re, drawer, capture: :all_but_first) do
      [class] ->
        class

      nil ->
        flunk(
          "no `data-role=\"canvas-search-indexing-state\"` element with a class attribute " <>
            "in #{@drawer_path}. The light theme's colour for that line is read from it."
        )
    end
  end

  # The CSS custom property a bare `bg-<token>` utility resolves to, e.g.
  # `bg-base-200` -> `--color-base-200`.
  #
  # An opacity modifier is a FAILURE rather than something to composite: the
  # whole "one ground" claim for the partial-index line rests on this box being
  # opaque. `bg-base-200/40` would make the ground depend on whatever is behind
  # the drawer, and then the single figure this file pins is the wrong shape of
  # answer, not merely a stale one. Failing loudly is the point.
  defp opaque_bg_token!(class) do
    cond do
      match = Regex.run(~r/(?:^|\s)bg-([\w-]+)(?:\s|$)/, class, capture: :all_but_first) ->
        "--color-" <> hd(match)

      Regex.match?(~r/(?:^|\s)bg-[\w-]+\/\d+(?:\s|$)/, class) ->
        flunk(
          "the canvases-drawer box now carries a TRANSLUCENT background: " <>
            "class=#{inspect(class)}. The canvas-search-indexing-state line then has " <>
            "no single ground, and the figures in this file measure a surface that is " <>
            "no longer there. Re-measure the line against every ground it can land on."
        )

      true ->
        flunk(
          "no `bg-<token>` in the canvases-drawer box's class, so the ground the " <>
            "canvas-search-indexing-state clauses composite against is not knowable: " <>
            "class=#{inspect(class)}"
        )
    end
  end

  # The custom property a bare `text-<token>` utility resolves to. Same refusal
  # on an opacity modifier, and for the same reason: `text-neutral/70` is a
  # different colour from `--color-neutral` and the light clause would be
  # measuring a colour nobody renders.
  defp text_utility_token!(class) do
    cond do
      match = Regex.run(~r/(?:^|\s)text-([a-z][\w-]*)(?:\s|$)/, class, capture: :all_but_first) ->
        "--color-" <> hd(match)

      Regex.match?(~r/(?:^|\s)text-[\w-]+\/\d+(?:\s|$)/, class) ->
        flunk("the partial-index line's text utility now carries an alpha: #{inspect(class)}")

      true ->
        flunk(
          "no `text-<token>` utility on the partial-index line, so the colour the LIGHT " <>
            "theme renders it in is not knowable from markup: class=#{inspect(class)}"
        )
    end
  end

  # Every rule in the stylesheet that declares `color` AND applies to the
  # partial-index line under `theme`, with the `@media` preludes it sits under.
  #
  # LIMIT, stated because it bounds what the light clause proves: the element is
  # modelled with the drawer box and the `<html>` element as its ancestors. The
  # two layout wrappers between them (`grid …` and `min-w-0 space-y-2`) are not
  # modelled, so a `color` rule keyed on THEIR classes would be missed here.
  # They carry layout utilities only. Everything that decides this element's
  # colour today keys on the theme attribute or on the data-role, and both are
  # modelled exactly.
  defp indexing_color_rules(css, theme, drawer_class, indexing_class) do
    html = CssRules.element("html", [{"data-theme", theme}], [])
    box = CssRules.element("div", [{"class", drawer_class}], [html])

    line =
      CssRules.element(
        "p",
        [{"data-role", "canvas-search-indexing-state"}, {"class", indexing_class}],
        [box, html]
      )

    css
    |> CssRules.rules()
    |> Enum.filter(
      &(CssRules.declares?(&1.body, "color") and CssRules.matches?(&1.selector, line))
    )
  end

  # The colour the dark rules declare for the partial-index line, as
  # `%{token:, alpha:}`. An empty list is the "someone deleted the rule" case
  # and gets a message that names the element, rather than an `hd([])` raise
  # that names nothing.
  defp dark_indexing_spec!(rules) do
    case rules["dark"] do
      [rule | _] ->
        color_mix_spec!(rule.body)

      [] ->
        flunk(
          "no rule in app.css colours `[data-role=\"canvas-search-indexing-state\"]` in " <>
            "DARK. Without it the line falls back to the `text-neutral` utility, which " <>
            "measures 2.23:1 on the drawer box, the WCAG 1.4.3 AA failure task 01a0792c " <>
            "fixed."
        )
    end
  end

  # The token and percentage a `color: color-mix(in <space>, var(--x) N%,
  # transparent)` declaration actually names. Deliberately not pinned to a
  # token or a number: pinning either is what would make the mutation probe
  # unable to move this file.
  defp color_mix_spec!(body) do
    re =
      ~r/(?:^|;)\s*color:\s*color-mix\(\s*in\s+\w+\s*,\s*var\((--[\w-]+)\)\s*([\d.]+)%\s*,\s*transparent\s*\)/

    case Regex.run(re, body, capture: :all_but_first) do
      [token, pct] ->
        {value, ""} = Float.parse(pct)
        %{token: token, alpha: value / 100.0}

      nil ->
        flunk(
          "the canvas-search-indexing-state colour is no longer a `color-mix` of a single " <>
            "token with transparent, so this file cannot say what it resolves to: #{body}"
        )
    end
  end

  # A Tailwind opacity modifier, e.g. `bg-base-content/5` -> 0.05. An absent
  # modifier is a failure rather than a default of 1.0: `bg-base-content` with
  # no slash would be a solid black or white row, which is a real bug and not
  # something to measure quietly.
  defp tailwind_alpha!(class, utility) do
    case Regex.run(~r/(?:^|\s)#{Regex.escape(utility)}\/(\d+)(?:\s|$)/, class,
           capture: :all_but_first
         ) do
      [pct] ->
        String.to_integer(pct) / 100.0

      nil ->
        flunk(
          "no `#{utility}/<n>` in the snippet container's class, so the colour this " <>
            "file measures is not the colour that renders. class=#{inspect(class)}"
        )
    end
  end
end
