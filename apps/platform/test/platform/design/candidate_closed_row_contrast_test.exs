defmodule Platform.Design.CandidateClosedRowContrastTest do
  @moduledoc """
  Contrast for the meeting rail's CLOSED candidate disclosure, both themes —
  task `01a07a90` stage 2.

  ## Why this file exists

  `.candidate-card--closed` carried `opacity: 0.72` until `01a07a90` stage 1.
  `opacity` composites the element against its backdrop *after* the colour has
  been resolved, so it multiplies whatever contrast the token gave the row and
  **no token substitution can undo it from inside**. The vetoed and duplicate
  rows sat at 2.4501:1 and 2.2161:1 because of it, against a 4.5:1 floor.

  Stage 1 removed the fade and moved the row's three text slots onto measured
  values. This file is what stops that decaying: it recomputes the row's
  contrast **from the stylesheet's own declarations** every run, so a retune
  moves the number instead of leaving a stale figure in a comment.

  ## The anti-vacuity argument, which is a PAIR — do not delete either half

  Two clauses guard the fade, and they fail on opposite mechanisms:

    * `describe "the fade is gone"` asserts the **absence** of an `opacity`
      declaration on `.candidate-card--closed`.
    * `describe "the composited row clears AA"` recomputes each slot's contrast
      **through whatever alpha that rule actually declares** and asserts 4.5:1.

  An absence-assertion alone cannot tell "fixed" from "deleted": a mutation that
  merely removes something adds no forbidden token, so nothing trips. And a
  contrast assertion alone cannot tell "composited correctly" from "read the
  declared colour and ignored the alpha" — it would pass identically either way.
  Together they do discriminate, and that is the whole design. The named
  mutation for this module is: **put `opacity: 0.72` back on
  `.candidate-card--closed` and change no colour.** The absence clause must go
  red, *and* at least one composited clause must go red *because the value
  moved*. If the composited clauses do not move, they are reading the declared
  property rather than the painted one and they prove nothing about this
  ticket — that is a finding to report, not something to iterate on until it
  dies.

  ## Every input is READ OUT OF THE FILE THAT DECLARES IT

    * `app.css` — the theme blocks, for every `--cc-*` and `--color-*` token,
      and the rule bodies, for which property each selector actually uses.
    * `candidate_rail.ex` — the rail `<section>`'s own `class` attribute, for
      the ground's Tailwind alpha.
    * `call_shell.ex` — the `<aside>`'s `class`, because it carries a SECOND
      `bg-base-200/40`. The ground behind a closed row is that layer composited
      **twice**, which is not obvious from either file alone and is the thing a
      hand-written ground would get wrong.

  A version of this file with resolved hex values hardcoded would go on passing
  after any of those changed, which is the failure mode it is arranged against.

  ## Provenance of every figure quoted below — "measured" is not a provenance

  Two different instruments produce contrast numbers on this project and they
  are **different quantities**:

    * a **painted-pixel** read is hex-to-hex. The compositor quantizes to 8-bit
      before anything can sample it, so no `oklch()` survives into the
      arithmetic.
    * a **declaration-derived** computation (this file, via `WcagContrast`)
      converts `oklch()` itself and carries floats through, so it can differ
      from a pixel read in the third or fourth decimal.

  Everything in THIS file is declaration-derived. Where a figure came from a
  browser it says so explicitly. The `@recorded_*` anchors below are figures
  earlier work recorded from a browser; see the reproduction clause for why the
  ones that can disagree are separated from the ones that cannot.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Platform.Design.CssRules
  alias Platform.Design.WcagContrast, as: W
  alias Platform.Meetings.MeetingCandidate
  alias PlatformWeb.Components.Meetings.CandidateRail

  @css_path "assets/css/app.css"
  @rail_path "lib/platform_web/components/meetings/candidate_rail.ex"
  @shell_path "lib/platform_web/components/meetings/call_shell.ex"

  # WCAG AA for body text. Every slot this file measures is normal-weight text
  # far below the large-text threshold (18pt, or 14pt bold): the title is
  # 11.5px/500, the reason 11px/400 and the disclosure label 10px/400. The 3:1
  # large-text allowance does not apply to any of them.
  @aa_text 4.5

  # Half of the last digit of a figure recorded to two decimal places. This is
  # the tolerance rounding alone demands — it is NOT a knob to widen until a
  # clause passes. If a reproduction misses by more than this, stop and report
  # which instrument disagrees with which; see the note on the two conventions
  # in the moduledoc.
  @two_dp_tolerance 0.005

  # Floats that should be bit-identical, not merely close.
  @exact 0.0000001

  # ── Figures recorded by work that PREDATES this branch ────────────────────
  #
  # The reproduction clause is only a check if the figure it reproduces came
  # from an instrument independent of the thing being checked. Reproducing a
  # number that `01a07a90` stage 1 itself wrote into `app.css` would prove that
  # this file's arithmetic agrees with this file's arithmetic.
  #
  # So every anchor here was recorded by EARLIER work, and none of it by me:
  # `dc8d87fa` (task 01a078d0 stage 2) recorded the first group against this
  # row's own ground, and FE-9 recorded the spent row's. Both are in `app.css`
  # on `origin/main` at `f17c2662`, before stage 1's first commit.
  #
  # They are split by whether a colour-space conversion is involved, because
  # that decides whether the declaration-vs-painted convention gap can even
  # arise:
  #
  #   * PURE HEX — both endpoints are hex literals, so there is nothing to
  #     convert and nothing to round differently. A declaration-derived
  #     computation and a painted-pixel read MUST agree here. A miss in this
  #     group is a real converter or arithmetic fault.
  #   * CONVERSION-INVOLVED — the foreground is `oklch()` or a `color-mix()`.
  #     Here the two conventions legitimately differ in the third or fourth
  #     decimal, so a small miss is the convention, not a bug. The converter
  #     soundness clause is the discriminator: if 21.0 / 1.0 / #FFFFFF are
  #     exact, the converter is sound and any residual gap is the convention.
  @recorded_pure_hex [
    {"--cc-title-dead on --cc-bg-closed, light", :light, "--cc-title-dead", "--cc-bg-closed",
     3.78},
    {"--color-interactive on --cc-bg-closed, light", :light, "--color-interactive",
     "--cc-bg-closed", 4.31},
    {"--color-interactive on --cc-bg-closed, dark", :dark, "--color-interactive",
     "--cc-bg-closed", 10.61}
  ]

  @recorded_conversion [
    {"--color-neutral on --cc-bg-closed, light", :light, "--color-neutral", "--cc-bg-closed",
     6.87},
    {"--color-neutral on --cc-bg-closed, dark", :dark, "--color-neutral", "--cc-bg-closed", 1.99},
    {"--cc-spent-fg on --cc-bg-closed, light", :light, "--cc-spent-fg", "--cc-bg-closed", 5.39}
  ]

  # The three text slots on the closed disclosure, and which ground each is
  # painted on. The first two sit INSIDE `.candidate-card--closed` and so are
  # subject to whatever alpha that rule declares; the third is the `<summary>`,
  # which sits outside the card on the rail's own ground and is therefore NOT
  # affected by the fade. Keeping that distinction explicit is what stops the
  # summary being used as evidence about the card.
  @card_slots [
    {".candidate-card__title--dead", "color", "the closed row's title (11.5px/500)"},
    {".candidate-card__reason", "color", "the closed row's reason line (11px/400)"}
  ]

  # The light-theme figures `app.css` records for the two slots above, quoted
  # in failure text only. The pins themselves are the AA clauses below, which
  # recompute; these strings exist so a red names what a slot-level fade
  # would silently drop.
  @pinned %{
    ".candidate-card__title--dead" => "6.2274:1",
    ".candidate-card__reason" => "4.9127:1"
  }

  @now ~U[2026-09-01 12:00:00.000000Z]

  setup_all do
    css = File.read!(@css_path)

    light = theme_tokens(css, :light)
    dark = theme_tokens(css, :dark)

    # The closed row and its two text slots, RENDERED rather than typed here,
    # so the rule matcher below is judged against the markup the browser gets
    # (real ancestors included) and a drift in `closed_card/1` reds at the
    # `query!` rather than being quietly matched against nothing.
    html = closed_row_html()
    article = query!(html, "[data-role='meeting-candidate-closed-card']")

    slots =
      Map.new(@card_slots, fn {selector, _property, _label} ->
        {selector, element(query!(article, selector))}
      end)

    {:ok,
     css: css,
     rules: CssRules.rules(css),
     tokens: %{light: light, dark: dark},
     ground: %{
       light: ground(light),
       dark: ground(dark)
     },
     closed_rule: rule_body!(css, ".candidate-card--closed"),
     closed_element: element(article),
     slots: slots}
  end

  # ── 1. the converter, before anything below is trusted ────────────────────

  describe "the converter is sound" do
    # A wrong converter would make every clause below pass for the wrong
    # reason. It is also the discriminator named in the moduledoc: if these are
    # exact, a small miss in the conversion-involved reproductions is the
    # declaration-vs-painted convention rather than a broken converter.
    test "the extremes and the identity are exact" do
      assert_in_delta W.contrast(W.hex("#FFFFFF"), W.hex("#000000")), 21.0, @exact
      assert_in_delta W.contrast(W.hex("#777777"), W.hex("#777777")), 1.0, @exact
      assert W.to_hex(W.parse!("oklch(100% 0 0)")) == "#FFFFFF"
      assert W.to_hex(W.parse!("oklch(0% 0 0)")) == "#000000"
    end

    test "the oklch converter reproduces a token whose own comment is wrong" do
      # `--color-neutral`'s comment claims `~#737373`; it resolves to #5A5355.
      # A positive assertion on the RESOLVED value, so this clause states what
      # the converter should say rather than only what it should not.
      assert W.to_hex(W.parse!("oklch(45% 0.01 0)")) == "#5A5355"
      assert W.to_hex(W.parse!("oklch(40% 0.01 0)")) == "#4D4647"
    end
  end

  # ── 2. reproduction, against figures this branch did not write ────────────

  describe "recomputing figures recorded by earlier work" do
    for {label, theme, fg, bg, recorded} <- @recorded_pure_hex do
      test "pure hex: #{label} reproduces the recorded #{recorded}:1", ctx do
        {theme, fg, bg, recorded} = {unquote(theme), unquote(fg), unquote(bg), unquote(recorded)}
        got = contrast(ctx, theme, fg, bg)

        assert_in_delta got,
                        recorded,
                        @two_dp_tolerance,
                        "#{unquote(label)}: recomputed #{fmt(got)} against #{recorded} recorded " <>
                          "in app.css by earlier work. Both endpoints are hex literals, so no " <>
                          "colour-space conversion is involved and the declaration-vs-painted " <>
                          "convention gap CANNOT explain this. Treat it as a real fault."
      end
    end

    for {label, theme, fg, bg, recorded} <- @recorded_conversion do
      test "conversion-involved: #{label} reproduces the recorded #{recorded}:1", ctx do
        {theme, fg, bg, recorded} = {unquote(theme), unquote(fg), unquote(bg), unquote(recorded)}
        got = contrast(ctx, theme, fg, bg)

        assert_in_delta got,
                        recorded,
                        @two_dp_tolerance,
                        "#{unquote(label)}: recomputed #{fmt(got)} against #{recorded} recorded " <>
                          "in app.css by earlier work. This pair DOES involve a colour-space " <>
                          "conversion, so if the converter soundness clause above is green, " <>
                          "report this as declaration-derived vs painted-pixel and quote both " <>
                          "numbers — do not report it as a converter failure, and do not widen " <>
                          "@two_dp_tolerance."
      end
    end
  end

  # ── 3. the fade is gone (absence) ─────────────────────────────────────────

  describe "the fade is gone" do
    test "`.candidate-card--closed` declares no opacity at all", %{closed_rule: rule} do
      refute Regex.match?(~r/(^|;)\s*opacity\s*:/, rule),
             "`.candidate-card--closed` declares an `opacity` property: #{inspect(rule)}. " <>
               "That property composites every colour on the row AFTER the colour is " <>
               "resolved, which is the defect task 01a07a90 removed — at 0.72 it put the " <>
               "row's title and reason line at 2.4501:1 and 2.2161:1 (browser pixel reads). " <>
               "Dim this row by choosing darker token values, as `.candidate-card--spent` " <>
               "does, not by fading it."
    end

    test "no rule matching the closed row or its text slots declares opacity", ctx do
      # The clause above reads ONE rule body by name. A fade can also arrive
      # on a rule that merely APPLIES to the row — `.candidate-card`, a
      # `@media` override, a `:hover` — or on the text slots themselves:
      # `.candidate-card__reason { opacity: .7 }` drops the reason line's
      # pinned 4.9127:1 without touching `.candidate-card--closed`, and the
      # clause above cannot see it. So this one asks the browser's question
      # over the rendered elements: which rules match, and does any declare
      # `opacity`? Each match set is asserted non-empty first — an empty set
      # is a broken matcher, not a clean row.
      assert_no_fade(ctx.rules, ctx.closed_element, "the closed row (`.candidate-card--closed`)")

      for {selector, _property, label} <- @card_slots do
        assert_no_fade(
          ctx.rules,
          Map.fetch!(ctx.slots, selector),
          "#{label} via `#{selector}`, pinned at #{Map.fetch!(@pinned, selector)} in light"
        )
      end
    end

    test "the rule still declares the ground and border that carry the recession", %{
      closed_rule: rule
    } do
      # The positive half. Without this, "no opacity" is satisfied by deleting
      # the rule entirely, and the row would lose the background that is now
      # the ONLY thing making it recede.
      assert rule =~ "var(--cc-bg-closed)",
             "the closed row must keep its own background: #{inspect(rule)}"

      assert rule =~ "var(--cc-border-closed)",
             "the closed row must keep its own border: #{inspect(rule)}"
    end
  end

  # ── 4. the composited row clears AA (recomputed through the real alpha) ───

  describe "the composited row clears AA" do
    # Light and dark are written out separately rather than looped, so a bug in
    # a loop cannot silently skip the worse ground. Dark IS the worse ground on
    # this rail.
    test "light: every text slot on the card clears 4.5:1", ctx do
      assert_card_slots(ctx, :light)
    end

    test "dark: every text slot on the card clears 4.5:1", ctx do
      assert_card_slots(ctx, :dark)
    end

    test "light: the disclosure label clears 4.5:1 on the rail ground", ctx do
      assert_summary(ctx, :light)
    end

    test "dark: the disclosure label clears 4.5:1 on the rail ground", ctx do
      assert_summary(ctx, :dark)
    end

    test "the alpha being composited is the one the rule declares, not a constant", ctx do
      # This is what makes the clauses above move under the named mutation. If
      # `card_alpha/1` ever returns a hardcoded 1.0, the assertions above keep
      # passing with `opacity: 0.72` restored and the pair described in the
      # moduledoc stops discriminating.
      assert card_alpha(ctx.closed_rule) == 1.0

      assert card_alpha("background: red; opacity: 0.72;") == 0.72,
             "card_alpha/1 must read the declared opacity. If it cannot, the AA clauses " <>
               "are measuring the declared colour rather than the painted one and they " <>
               "prove nothing about this ticket."

      # `.7` is how app.css spells a fade; a reader that only takes `0.7`
      # would raise instead of measuring, and print no ratio for a red.
      assert card_alpha("opacity: .7;") == 0.7

      # The slot half. A fade declared on a SLOT's own rule, not on the card,
      # must reach the composite too: with the card at 1.0 and a synthetic
      # slot rule at 0.72, the slot composites at 0.72.
      slot = CssRules.element("p", [{"class", "candidate-card__reason"}])
      slot_rules = CssRules.rules(".candidate-card__reason { color: red; opacity: 0.72; }")
      assert slot_alpha(slot_rules, slot) == 0.72
      assert composite_alpha("background: red;", slot_rules, slot) == 0.72

      assert composite_alpha(
               "background: red;",
               CssRules.rules(".unrelated { opacity: 0.1; }"),
               slot
             ) == 1.0
    end
  end

  # ── 5. the dark hairline must not reach for base-300 ──────────────────────

  describe "the outcome hairline" do
    test "dark `--cc-outcome-bar` does not resolve to --color-base-300", ctx do
      bar = resolve!(ctx.tokens.dark, "--cc-outcome-bar")
      base_300 = resolve!(ctx.tokens.dark, "--color-base-300")

      refute W.to_hex(bar) == W.to_hex(base_300),
             "dark --cc-outcome-bar resolves to #{W.to_hex(bar)}, the same as " <>
               "--color-base-300. Dark base-300 is #{W.to_hex(base_300)} against a " <>
               "#{W.to_hex(resolve!(ctx.tokens.dark, "--cc-bg-closed"))} row ground, which is " <>
               "an INVISIBLE hairline rather than a quiet one. Dark uses --cc-border " <>
               "instead. Do not 'fix' this by retuning --color-base-300: it does double " <>
               "duty as a fill and lightening it to fix a line breaks the other pairing."

      # The positive half: say what it IS, not only what it is not.
      assert W.to_hex(bar) == W.to_hex(resolve!(ctx.tokens.dark, "--cc-border"))
    end

    test "the same clause is SILENT about light, where base-300 is correct", ctx do
      # The negative control. Light --cc-outcome-bar IS --color-base-300 and
      # that is deliberate: the bar is `aria-hidden`, carries no information,
      # and app.css records 1.32:1 as the intended weight for it. If the clause
      # above were written as a blanket "never base-300" it would fire here,
      # and this test is what proves it does not.
      bar = resolve!(ctx.tokens.light, "--cc-outcome-bar")
      base_300 = resolve!(ctx.tokens.light, "--color-base-300")

      assert W.to_hex(bar) == W.to_hex(base_300),
             "light --cc-outcome-bar is expected to BE --color-base-300; if that changed, " <>
               "this negative control no longer proves the dark clause is discriminating."
    end
  end

  # ── 6. the two dark declarations must not drift apart ─────────────────────

  describe "the dark theme is declared twice and the copies must agree" do
    test "[data-theme=dark] and the prefers-color-scheme block declare the same --cc-* values",
         %{css: css} do
      explicit = cc_block!(css, ~r/^\[data-theme="dark"\]\s*\{/m)
      media = cc_block!(css, ~r/^\s*:root:not\(\[data-theme="light"\]\)\s*\{/m)

      shared =
        explicit
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, "--cc-"))
        |> Enum.filter(&Map.has_key?(media, &1))

      assert shared != [], "no shared --cc-* tokens found; the block extraction is wrong"

      drifted =
        Enum.reject(shared, fn token ->
          Map.fetch!(explicit, token) == Map.fetch!(media, token)
        end)

      assert drifted == [],
             "these --cc-* tokens differ between the two dark declarations: " <>
               Enum.map_join(drifted, ", ", fn t ->
                 "#{t} = #{inspect(Map.fetch!(explicit, t))} vs #{inspect(Map.fetch!(media, t))}"
               end) <>
               ". A reader who only edits one gets a theme that changes depending on the OS " <>
               "setting rather than the app setting."
    end
  end

  # ── assertions ────────────────────────────────────────────────────────────

  defp assert_card_slots(ctx, theme) do
    card_alpha = card_alpha(ctx.closed_rule)
    ground = Map.fetch!(ctx.ground, theme)
    tokens = Map.fetch!(ctx.tokens, theme)

    row_bg = painted(W.composite(resolve!(tokens, "--cc-bg-closed"), card_alpha, ground))

    for {selector, property, description} <- @card_slots do
      token = property_token!(ctx.css, selector, property)

      # The alpha a slot is painted through is the card's AND its own: a fade
      # declared on the slot's rules (read through the matcher, so `:hover`
      # and `@media` variants count) reaches the text just as the card's
      # does. `min` rather than a product: the lower of the two is the bound
      # this file measures against, and a fade on BOTH already reds twice.
      alpha = composite_alpha(ctx.closed_rule, ctx.rules, Map.fetch!(ctx.slots, selector))
      painted = painted(W.composite(resolve!(tokens, token), alpha, ground))
      got = W.contrast_painted(painted, row_bg)

      assert got >= @aa_text,
             "#{theme}: #{description} via #{selector} -> #{token} measures #{fmt(got)} " <>
               "against a #{@aa_text} floor. Painted #{W.to_hex(painted)} on " <>
               "#{W.to_hex(row_bg)}, composited at alpha #{alpha} (card #{card_alpha}) " <>
               "over a ground of #{W.to_hex(ground)}. If alpha is not 1.0, an `opacity` " <>
               "has come back onto `.candidate-card--closed` or onto a rule matching " <>
               "`#{selector}`, and no token choice can fix this row from inside."
    end
  end

  # The matched rules for `element` that declare `opacity`, asserted empty.
  # Non-empty match set first: a matcher that matches nothing proves nothing.
  defp assert_no_fade(rules, element, what) do
    matched = Enum.filter(rules, &CssRules.matches?(&1.selector, element))

    assert matched != [],
           "no rule in #{@css_path} matches #{what}; the matcher or the rendered " <>
             "markup has drifted and this clause is not looking at the row"

    offenders = Enum.filter(matched, &CssRules.declares?(&1.body, "opacity"))

    assert offenders == [],
           "these rules match #{what} and declare `opacity`: " <>
             Enum.map_join(offenders, "; ", &"`#{&1.selector}` { #{String.trim(&1.body)} }") <>
             ". `opacity` composites the colour AFTER it resolves, so the pinned figure " <>
             "drops and no token can restore it from inside. Dim with a measured token."
  end

  defp assert_summary(ctx, theme) do
    ground = Map.fetch!(ctx.ground, theme)
    tokens = Map.fetch!(ctx.tokens, theme)

    token = property_token!(ctx.css, ".candidate-closed__summary", "color")
    got = W.contrast_painted(painted(resolve!(tokens, token)), ground)

    assert got >= @aa_text,
           "#{theme}: the `N CLOSED` disclosure label via --cc-stage -> #{token} measures " <>
             "#{fmt(got)} against a #{@aa_text} floor on the rail ground " <>
             "#{W.to_hex(ground)}. This label sits OUTSIDE the card, so it is not affected " <>
             "by any opacity on `.candidate-card--closed` — do not go looking for a fade."
  end

  defp contrast(ctx, theme, fg_token, bg_token) do
    tokens = Map.fetch!(ctx.tokens, theme)

    # The PAINTED ratio: both endpoints are already quantized by `painted/1`,
    # so re-quantizing is a no-op — the call NAMES the quantity it means.
    W.contrast_painted(painted(resolve!(tokens, fg_token)), painted(resolve!(tokens, bg_token)))
  end

  # ── the ground behind a closed row ────────────────────────────────────────

  # `bg-base-200/40` appears TWICE in the ancestor chain — once on the
  # `<aside>` in call_shell.ex and again on the rail `<section>` in
  # candidate_rail.ex — so the ground is that layer composited twice over
  # base-100. Both alphas are read from the class attributes rather than
  # assumed, because the doubling is exactly what a hand-written ground gets
  # wrong: a single layer computes #FAFAFA in light where the real painted
  # ground is #F7F7F7.
  defp ground(tokens) do
    aside = tailwind_alpha!(class_attr!(File.read!(@shell_path), "call-rail"), "bg-base-200")
    rail = tailwind_alpha!(class_attr!(File.read!(@rail_path), "rail-section"), "bg-base-200")

    base_100 = resolve!(tokens, "--color-base-100")
    base_200 = resolve!(tokens, "--color-base-200")

    base_100
    |> then(&W.composite(base_200, aside, &1))
    |> then(&W.composite(base_200, rail, &1))
    |> painted()
  end

  # The two class attributes this file depends on, each pinned by a marker that
  # lives in the same tag, so a reordered class list still resolves and an
  # unrelated `bg-base-200/40` elsewhere in the file cannot be picked up.
  defp class_attr!(source, "call-rail") do
    capture!(
      source,
      ~r/class=\{\[\s*"([^"]*bg-base-200\/\d+[^"]*)"[^\]]*\]\}\s*\n\s*data-component="call-rail"/,
      "the <aside> carrying data-component=\"call-rail\" in #{@shell_path}"
    )
  end

  defp class_attr!(source, "rail-section") do
    capture!(
      source,
      ~r/class="([^"]*bg-base-200\/\d+[^"]*)"[^>]*?data-role="meeting-candidate-countdown-rail"/s,
      "the rail <section> carrying data-role=\"meeting-candidate-countdown-rail\" in #{@rail_path}"
    )
  end

  defp tailwind_alpha!(class, utility) do
    case Regex.run(~r/(?:^|\s)#{Regex.escape(utility)}\/(\d+)(?:\s|$)/, class,
           capture: :all_but_first
         ) do
      [pct] -> String.to_integer(pct) / 100.0
      nil -> flunk("no `#{utility}/<alpha>` in #{inspect(class)}")
    end
  end

  # ── reading app.css ───────────────────────────────────────────────────────

  # A theme's token map. Light is the base cascade; dark is light with the dark
  # blocks layered over it, which is what the browser actually resolves — a
  # token declared only in the light blocks (there are several) must still
  # resolve in dark rather than raising.
  defp theme_tokens(css, :light) do
    Enum.reduce(light_blocks(css), %{}, &Map.merge(&2, declarations(&1)))
  end

  defp theme_tokens(css, :dark) do
    Enum.reduce(dark_blocks(css), theme_tokens(css, :light), &Map.merge(&2, declarations(&1)))
  end

  defp light_blocks(css) do
    [daisyui_theme!(css, "light") | all_blocks(css, ~r/^:root\s*\{/m)]
  end

  defp dark_blocks(css) do
    [daisyui_theme!(css, "dark") | all_blocks(css, ~r/^\[data-theme="dark"\]\s*\{/m)]
  end

  defp daisyui_theme!(css, name) do
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

  # Every block opened by `opener`, sliced to the next line-initial closing
  # brace at the block's own indentation. Blocks here contain no nested rules,
  # only declarations, so this is exact rather than a brace counter.
  defp all_blocks(css, opener) do
    Regex.scan(opener, css, return: :index)
    |> Enum.map(fn [{start, len} | _] ->
      indent =
        css
        |> binary_part(start, len)
        |> then(&(String.length(&1) - String.length(String.trim_leading(&1))))

      css
      |> binary_part(start + len, byte_size(css) - start - len)
      |> String.split(~r/^#{String.duplicate(" ", indent)}\}/m, parts: 2)
      |> hd()
    end)
  end

  defp declarations(block) do
    ~r/^\s*(--[a-z0-9-]+)\s*:\s*([^;\n]+);/m
    |> Regex.scan(block, capture: :all_but_first)
    |> Map.new(fn [token, value] -> {token, String.trim(value)} end)
  end

  defp rule_body!(css, selector) do
    capture!(
      css,
      ~r/^#{Regex.escape(selector)}\s*\{([^}]*)\}/m,
      "a `#{selector} { ... }` rule in #{@css_path}"
    )
  end

  # The TOKEN a selector's property points at, read from the rule rather than
  # assumed. This is what makes a retune move the number: change
  # `.candidate-card__reason`'s `color` to a different token and this file
  # measures the new one.
  defp property_token!(css, selector, property) do
    body = rule_body!(css, selector)

    value =
      capture!(
        body,
        ~r/(?:^|;)\s*#{Regex.escape(property)}\s*:\s*([^;]+)/,
        "a `#{property}:` declaration in `#{selector}`"
      )

    case Regex.run(~r/^var\(\s*(--[a-z0-9-]+)\s*\)$/, String.trim(value), capture: :all_but_first) do
      [token] ->
        token

      nil ->
        flunk(
          "`#{selector}`'s `#{property}` is #{inspect(value)}, not a `var(--token)`. " <>
            "This row's colours are supposed to come from named tokens so a retune is " <>
            "visible in one place; a literal here is what this file exists to notice."
        )
    end
  end

  # ── resolving a declared value to a colour ────────────────────────────────

  @color_mix_re ~r/^color-mix\(\s*in\s+(oklch|oklab|srgb)\s*,\s*(.+?)\s+(\d+)%\s*,\s*(.+?)\s*\)$/

  # Follows `var()` chains and the two `color-mix()` forms `app.css` actually
  # uses on this rail. Anything it does not understand RAISES rather than
  # falling back, because a silent fallback would let this file measure a
  # colour nobody declared.
  defp resolve!(tokens, token, seen \\ [])

  defp resolve!(_tokens, token, seen) when length(seen) > 16 do
    flunk("`var()` cycle resolving #{token}: #{inspect(Enum.reverse(seen))}")
  end

  defp resolve!(tokens, "--" <> _ = token, seen) do
    case Map.fetch(tokens, token) do
      {:ok, value} -> resolve_value!(tokens, value, [token | seen])
      :error -> flunk("no `#{token}:` declaration in this theme. Chain: #{inspect(seen)}")
    end
  end

  defp resolve_value!(tokens, value, seen) do
    value = String.trim(value)

    cond do
      match = Regex.run(~r/^var\(\s*(--[a-z0-9-]+)\s*\)$/, value, capture: :all_but_first) ->
        resolve!(tokens, hd(match), seen)

      match = Regex.run(@color_mix_re, value, capture: :all_but_first) ->
        [space, a, pct, b] = match
        mix!(tokens, space, a, String.to_float(pct <> ".0"), b, seen)

      # `white` / `black` appear as the achromatic endpoint of every
      # `color-mix()` on this rail. Handled here rather than in WcagContrast,
      # whose stated contract is hex and oklch and which is not this task's to
      # widen. Only these two, so any other named colour still raises.
      value == "white" ->
        W.hex("#FFFFFF")

      value == "black" ->
        W.hex("#000000")

      true ->
        W.parse!(value)
    end
  end

  # `in oklch` vs `in oklab` matters in general — one interpolates chroma and
  # hue polar, the other a/b rectangular — but NOT for the mixes on this rail,
  # every one of which has an ACHROMATIC second endpoint (white or black). When
  # one endpoint has no chroma its hue is powerless, so polar interpolation
  # reduces to scaling C toward zero at a fixed hue, which is exactly what
  # rectangular interpolation of a and b does. `WcagContrast.mix_oklab/3` is
  # therefore exact for these, and the guard below is what keeps that true: a
  # future `in oklch` mix between two CHROMATIC colours raises rather than
  # being quietly mixed in the wrong space.
  defp mix!(tokens, space, a, pct, b, seen) when space in ["oklch", "oklab"] do
    ca = resolve_value!(tokens, a, seen)
    cb = resolve_value!(tokens, b, seen)

    if space == "oklch" and not achromatic?(ca) and not achromatic?(cb) do
      flunk(
        "`color-mix(in oklch, ...)` between two chromatic colours (#{W.to_hex(ca)} and " <>
          "#{W.to_hex(cb)}) cannot be computed with mix_oklab/3 — polar and rectangular " <>
          "interpolation differ once both endpoints carry chroma. Teach WcagContrast the " <>
          "polar form rather than approximating it here."
      )
    end

    W.mix_oklab(ca, pct, cb)
  end

  defp mix!(tokens, "srgb", a, pct, b, seen) do
    # sRGB mixing is a gamma-encoded channel lerp, which is a different curve
    # from oklab and must not be routed through mix_oklab/3.
    ca = resolve_value!(tokens, a, seen)
    cb = resolve_value!(tokens, b, seen)
    W.composite(ca, pct / 100.0, cb)
  end

  defp achromatic?(color) do
    {_l, a, b} = W.to_oklab(color)
    abs(a) < 0.0005 and abs(b) < 0.0005
  end

  # ── which quantity this file measures ────────────────────────────────────

  # THE PAINTED QUANTITY. The compositor rounds every colour to 8 bits per
  # channel before it reaches a pixel, so that is where this file rounds too.
  #
  # This is NOT a free choice. `WcagContrast` documents a float-through
  # convention for `contrast/2` and scopes it: it reproduces the figures the
  # moduledoc names -- the `.chip-soft` alpha ceilings, which are
  # declaration-derived -- and NOT the figures on this rail, which `app.css`
  # labels "MEASURED on the real rendered row in a browser (painted pixels,
  # not palette arithmetic)". Both conventions live in one stylesheet and
  # which one applies depends on how the figure was produced;
  # `WcagContrast.contrast_painted/2` is the named mechanism for the painted
  # quantity.
  #
  # Measured, on the three conversion-involved anchors below:
  #
  #     float-through   quantized   app.css records (painted)
  #        6.8579        6.8674       6.87    --color-neutral light
  #        1.9724        1.9853       1.99    --color-neutral dark
  #        5.4101        5.3932       5.39    --cc-spent-fg light
  #
  # Quantizing reproduces all three; float-through misses all three. On a
  # pure-hex pair the two conventions are bit-identical (3.7833 either way),
  # which is what proves the gap is the convention and not the converter.
  defp painted(color), do: color |> W.to_hex() |> W.hex()

  # The block matching `opener` that actually declares the rail's tokens. Both
  # `[data-theme="dark"]` and the prefers-color-scheme block appear more than
  # once in this stylesheet, and the FIRST of each declares `--color-interactive`
  # and no `--cc-*` at all -- taking it silently compared an empty set and the
  # clause passed by measuring nothing.
  defp cc_block!(css, opener) do
    css
    |> all_blocks(opener)
    |> Enum.map(&declarations/1)
    |> Enum.find(fn decls -> Enum.any?(Map.keys(decls), &String.starts_with?(&1, "--cc-")) end)
    |> case do
      nil -> flunk("no block matching #{inspect(opener)} declares any --cc-* token")
      decls -> decls
    end
  end

  # ── small shared helpers ──────────────────────────────────────────────────

  defp capture!(source, re, what) do
    case Regex.run(re, source, capture: :all_but_first) do
      [value] -> value
      nil -> flunk("could not find #{what}")
    end
  end

  defp card_alpha(rule) do
    case Regex.run(~r/(?:^|;)\s*opacity\s*:\s*([\d.]+)/, rule, capture: :all_but_first) do
      [value] -> parse_alpha(value)
      nil -> 1.0
    end
  end

  # `1`, `0.72` and `.7` are all how a stylesheet spells an alpha.
  defp parse_alpha("." <> _ = value), do: parse_alpha("0" <> value)

  defp parse_alpha(value) when is_binary(value) do
    String.to_float(if String.contains?(value, "."), do: value, else: value <> ".0")
  end

  # The lowest `opacity` declared by any rule matching `element`, 1.0 when
  # none does. Read through `CssRules` so a `:hover`, a `@media` block or a
  # descendant selector counts, exactly as the fade clause above counts them.
  defp slot_alpha(rules, element) do
    rules
    |> Enum.filter(&CssRules.matches?(&1.selector, element))
    |> Enum.map(&card_alpha(&1.body))
    |> Enum.min(fn -> 1.0 end)
  end

  defp composite_alpha(closed_rule, rules, slot),
    do: min(card_alpha(closed_rule), slot_alpha(rules, slot))

  # ── the rendered closed row ───────────────────────────────────────────────

  # One NON-accepted closed row, which is the branch of `closed_card/1` that
  # renders both slots in `@card_slots`: the dead title (no outcome link) and
  # the reason line. Mirrors `candidate_rail_test.exs`'s `closed_rejected/1`.
  defp closed_row_html do
    candidate =
      %MeetingCandidate{
        id: Ecto.UUID.generate(),
        evidence_quote: "let us buy the expensive one",
        state: :closed,
        disposition: :rejected,
        disposition_at: @now,
        closed_at: @now,
        closed_reason: :vetoed,
        classified_intent: "action_item",
        transcript_chunk_ids: [Ecto.UUID.generate()],
        acts_at: nil,
        inserted_at: @now
      }

    render_component(&CandidateRail.candidate_rail/1,
      candidates: [],
      closed: [candidate],
      events: %{},
      now: @now
    )
    |> LazyHTML.from_fragment()
  end

  defp query!(html, selector) do
    node = LazyHTML.query(html, selector)

    case LazyHTML.tag(node) do
      [_] ->
        node

      tags ->
        flunk(
          "expected exactly one #{inspect(selector)} in the rendered closed row, got #{length(tags)}"
        )
    end
  end

  # A `CssRules` element for a LazyHTML node with its real ancestors, as
  # `candidate_spent_row_opacity_guard_test.exs` builds them.
  defp element(node) do
    [tag] = LazyHTML.tag(node)
    [attrs] = LazyHTML.attributes(node)
    CssRules.element(tag, attrs, ancestors(node))
  end

  defp ancestors(node) do
    parent = LazyHTML.parent_node(node)

    case LazyHTML.tag(parent) do
      [tag] ->
        [attrs] = LazyHTML.attributes(parent)
        above = ancestors(parent)
        [CssRules.element(tag, attrs, above) | above]

      [] ->
        []
    end
  end

  defp fmt(ratio), do: :erlang.float_to_binary(ratio, decimals: 4) <> ":1"
end
