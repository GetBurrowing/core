defmodule Platform.Design.CanvasSearchSnippetContrastTest do
  @moduledoc """
  Contrast for the canvases-drawer search snippet, BOTH THEMES — task
  `01a077e6` stage 1.

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

  ## What this file cannot tell you

  Nothing here proves the row lays out correctly. It is arithmetic on declared
  colours. Whether the match is on screen at 375px is a browser measurement and
  belongs to stage 2.
  """

  use ExUnit.Case, async: true

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

    container_class = container_class!(template)

    fill = mark_fill!(css)

    {:ok,
     ground_alpha: tailwind_alpha!(container_class, "bg-base-content"),
     context_alpha: tailwind_alpha!(container_class, "text-base-content"),
     fill_spec: fill,
     mark_rule: rule_body!(css, ~s([data-role="canvas-result-snippet"] mark)),
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

  # ── reading the two source files ──────────────────────────────────────────

  defp fmt(ratio), do: :erlang.float_to_binary(ratio, decimals: 4)

  defp theme_colors!(css, name, fill_token) do
    block = theme_block!(css, name)

    %{
      base_100: color!(block, "--color-base-100"),
      content: color!(block, "--color-base-content"),
      edge: color!(block, "--edge"),
      fill_token: color!(block, fill_token)
    }
  end

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
