defmodule Platform.Design.CandidateLiveQuoteContrastTest do
  @moduledoc """
  Contrast for the live candidate card's verbatim quote line, both card
  grounds, both themes — task `01a08da6-ea60` stage 2.

  ## Why this file exists

  `.candidate-card__quote` (`--cc-micro`) measured 3.66:1 in dark — under
  AA — and stage 1 traced the root cause to a token that never got a dark
  value at all: `--cc-micro` was pinned at the same light hex (`#6b7385`)
  in every theme block, while every sibling in its group (`--cc-stage`,
  `--cc-byline`, `--cc-reason`) got a distinct one. The fix aliases it to
  `var(--cc-title-half)`, the same pattern `--cc-stage` already used
  (task `01a07a90`).

  This file is what stops that regressing silently. It does not assert a
  single number: the card's ground is a **two-stop linear gradient**
  (`--cc-bg-shaping`, `--cc-bg-acting`), and stage 1's own painted-pixel
  measurement found the two stops of one gradient disagree by as much as
  0.05:1 in light and 0.04:1 in dark — enough, in light, to be the entire
  margin over the 4.5:1 floor. A single-point check would pass or fail
  depending on which stop it happened to sample. This file asserts both
  stops of both grounds, in both themes.

  ## Every input is READ OUT OF THE FILE THAT DECLARES IT

  `--cc-micro`, `--cc-title-half`, and the raw `linear-gradient(...)` text
  of `--cc-bg-shaping` / `--cc-bg-acting` are all read from `app.css` at
  test time, and the quote's foreground TOKEN (not colour) is read from
  `.candidate-card__quote`'s own `color:` declaration. A version of this
  file with the resolved hex values typed in would go on passing after
  any of them changed — the defect `--cc-micro` itself was.

  ## The anti-vacuity pair — both halves, neither optional

  `opacity` composites an element against its backdrop AFTER the colour
  has resolved, so it multiplies whatever contrast the token gives the
  quote and no token substitution can undo it from inside — the same
  mechanism `candidate_closed_row_contrast_test.exs` guards for the
  closed row.

    * Clause A (`describe "the quote line declares no opacity"`) asserts
      the ABSENCE of an `opacity` declaration on `.candidate-card__quote`
      and on every one of its rendered ancestors (the card article and
      the two wrapping `<div>`s `card_head/1` puts between them) — a fade
      on `.candidate-card--acting` would dim the quote exactly as
      effectively as one on the `<p>` itself, and only checking the leaf
      would miss it.
    * Clause B (`describe "the quote clears AA at every gradient stop"`)
      recomputes the ratio **through whatever the stylesheet currently
      declares**, at every stop, and asserts 4.5:1.

  An absence-assertion alone cannot tell "fixed" from "deleted" — a
  mutation that only removes a declaration adds no forbidden token, so
  Clause A cannot see it. A contrast assertion alone cannot tell
  "composited correctly" from "the number happens to still clear" — a
  hardcoded-expectation bug produces an unmoving green exactly like a
  real pass. Together they discriminate, which is the whole design.

  **The named mutation for this module** (run once while writing it, not
  a permanent test case — see the stage evidence for the recorded
  before/after ratios): put `--cc-micro: #6b7385` back in the
  `[data-theme="dark"]` block, change nothing else. At least one dark
  Clause-B assertion must go red, AND the reported ratio must MOVE to
  roughly 3.40:1 — stage 1's own painted-pixel figure for the acting
  card's worst stop. A clause that stays green, or goes red while still
  reporting the fixed ratio, is reading a hardcoded expectation rather
  than the stylesheet; that is a finding to report, not something to
  iterate on until it dies.

  ## Negative control

  A detector that flags every token is not a detector. `--cc-title-half`
  is evaluated with the identical `resolve!`/`WcagContrast` pipeline
  against the rail's own ground (the SAME ground `01a07a90`'s own comment
  in `app.css` measured `--cc-stage`'s replacement against) and asserted
  to clear AA at roughly the figures that comment records: 5.0024:1
  light, 6.7068:1 dark. If `--cc-title-half` were never evaluated here at
  all, the control would be untested rather than passing.

  ## Section 5 (stage 3): the root cause, not just the symptom

  Clauses A and B above are `--cc-micro`-specific: the contrast number was
  the symptom. The cause was that `--cc-micro` was declared with the same
  literal in the light block and both dark blocks while every one of its
  nine siblings was per-theme — a shape a contrast test on one token
  cannot catch in the next token that ships the same way. `describe "every
  --cc-* token shared by both theme blocks is intentionally shared"` sweeps
  every `--cc-*` custom property declared in both theme blocks and asserts
  each one's declared value differs, against an explicit, individually
  justified allowlist (`@invariant_cc_tokens`) for the tokens that are
  legitimately shared. See that section's own comment for the full
  rationale and the anti-vacuity design.

  ## Out of scope

  Clauses A and B: no `--cc-*` token other than `--cc-micro`. Section 5:
  `--color-*` brand tokens (a different ticket), and fixing anything the
  sweep finds — an honest finding is a follow-up row, not something this
  file retunes or launders into the allowlist. `candidate_closed_row_contrast_test.exs`
  is untouched throughout — its assertions cover a different surface (the
  CLOSED disclosure, not a live card) and are already green.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Platform.Design.CssRules
  alias Platform.Design.WcagContrast, as: W
  alias Platform.Meetings.MeetingCandidate
  alias PlatformWeb.Components.Meetings.CandidateRail

  @css_path "assets/css/app.css"
  @shell_path "lib/platform_web/components/meetings/call_shell.ex"
  @rail_path "lib/platform_web/components/meetings/candidate_rail.ex"

  # WCAG AA for body text. The quote is 10.5px italic (app.css :7271),
  # under the 18.66px large-text threshold, so the floor is 4.5:1 and not
  # the 3:1 large-text allowance.
  @aa_text 4.5

  # Floats that should be bit-identical, not merely close.
  @exact 0.0000001

  # The two card grounds stage 1 measured, each a two-stop gradient, and a
  # human label for failure messages. Order matches the CSS declaration
  # order, not measured severity — both stops of both are asserted, so
  # nothing here depends on which is "worse".
  @grounds [
    {"--cc-bg-shaping", "shaping (thinking/taking-shape cards)"},
    {"--cc-bg-acting", "acting (armed cards)"}
  ]

  @now ~U[2026-09-18 12:00:00.000000Z]

  setup_all do
    css = File.read!(@css_path)

    light = theme_tokens(css, :light)
    dark = theme_tokens(css, :dark)

    # The quote line, RENDERED rather than typed here, so the ancestor
    # chain Clause A walks is the markup the browser gets (real
    # `card_head/1` divs included) and a drift in the component reds at
    # the `query!` rather than being quietly matched against nothing.
    html = quote_card_html()
    article = query!(html, "[data-role='meeting-candidate-card']")
    quote_node = query!(article, "[data-role='meeting-candidate-quote']")

    {:ok,
     css: css,
     rules: CssRules.rules(css),
     tokens: %{light: light, dark: dark},
     rail_ground: %{light: rail_ground(light), dark: rail_ground(dark)},
     quote_rule: rule_body!(css, ".candidate-card__quote"),
     quote_fg_token: property_token!(css, ".candidate-card__quote", "color"),
     quote_element: element(quote_node),
     quote_ancestors: ancestors(quote_node)}
  end

  # ── 1. the converter, before anything below is trusted ────────────────────

  describe "the converter is sound" do
    test "the extremes and the identity are exact" do
      assert_in_delta W.contrast(W.hex("#FFFFFF"), W.hex("#000000")), 21.0, @exact
      assert_in_delta W.contrast(W.hex("#777777"), W.hex("#777777")), 1.0, @exact
      assert W.to_hex(W.parse!("oklch(100% 0 0)")) == "#FFFFFF"
      assert W.to_hex(W.parse!("oklch(0% 0 0)")) == "#000000"
    end
  end

  # ── 2. the quote line declares no opacity (Clause A) ───────────────────────

  describe "the quote line declares no opacity" do
    test "`.candidate-card__quote`'s own rule declares no opacity", %{quote_rule: rule} do
      refute Regex.match?(~r/(^|;)\s*opacity\s*:/, rule),
             "`.candidate-card__quote` declares an `opacity` property: #{inspect(rule)}. " <>
               "That composites the quote's colour against its backdrop AFTER the colour " <>
               "resolves, so no token substitution (including the --cc-micro fix this file " <>
               "guards) can restore contrast from inside."
    end

    test "the quote still declares its colour from --cc-micro", %{quote_fg_token: token} do
      # The positive half. Without it, "no opacity" is satisfiable by
      # deleting the colour declaration entirely.
      assert token == "--cc-micro",
             "expected `.candidate-card__quote`'s `color:` to read `var(--cc-micro)`, got " <>
               "#{inspect(token)}. This file measures the quote through whatever token the " <>
               "rule names; if that token changed, retarget the fix, not this assertion."
    end

    test "no rule matching the rendered quote or any of its ancestors declares opacity", ctx do
      assert_no_opacity(ctx.rules, ctx.quote_element, "the quote line itself")

      for {ancestor, idx} <- Enum.with_index(ctx.quote_ancestors, 1) do
        assert_no_opacity(
          ctx.rules,
          ancestor,
          "ancestor #{idx} of the quote (<#{ancestor.tag}#{class_suffix(ancestor)}>)"
        )
      end
    end
  end

  # ── 3. the quote clears AA at every gradient stop (Clause B) ───────────────

  describe "the quote clears AA at every gradient stop, both themes" do
    for {token, label} <- @grounds do
      test "light: #{label}", ctx do
        assert_gradient_stops(ctx, :light, unquote(token), unquote(label))
      end

      test "dark: #{label}", ctx do
        assert_gradient_stops(ctx, :dark, unquote(token), unquote(label))
      end
    end
  end

  # ── 4. negative control: a known-good token is NOT flagged ─────────────────

  # `01a07a90`'s comment says these figures were "measured" alongside two
  # other browser pixel-reads in the same sentence (`#7B8395 measured
  # 3.5494:1 on the rail's own ground`), so they are PAINTED-PIXEL anchors,
  # not declaration-derived ones — unlike `@recorded_pure_hex` /
  # `@recorded_conversion` in candidate_closed_row_contrast_test.exs, whose
  # tolerance of 0.005 is calibrated to a documented quantize-vs-float-through
  # gap of about 0.01. A cross-instrument comparison against a browser
  # reading is not held to that tolerance; the brief itself says "roughly".
  # What actually discriminates a real detector from one that flags
  # everything is the AA assertion below, not decimal-matching a number this
  # file did not produce.
  @negative_control_tolerance 0.05

  describe "negative control: --cc-title-half is not flagged" do
    test "light: --cc-title-half on the rail's own ground is roughly 5.00:1, clears AA", ctx do
      fg = painted(resolve!(ctx.tokens.light, "--cc-title-half"))
      got = W.contrast(fg, ctx.rail_ground.light)

      assert_in_delta got,
                      5.0024,
                      @negative_control_tolerance,
                      "--cc-title-half on the rail's own ground (#{W.to_hex(ctx.rail_ground.light)}) " <>
                        "measures #{fmt(got)}, expected roughly 5.00:1 — the figure task 01a07a90's " <>
                        "own comment in app.css records (a browser pixel-read) for this token/ground " <>
                        "pair. A miss bigger than this is worth reporting as a real drift, not widening " <>
                        "further."

      assert got >= @aa_text,
             "negative control failed: --cc-title-half measures #{fmt(got)} against the AA " <>
               "floor and should clear it comfortably. If it does not, this file's detector " <>
               "flags a known-good token and is not trustworthy."
    end

    test "dark: --cc-title-half on the rail's own ground is roughly 6.71:1, clears AA", ctx do
      fg = painted(resolve!(ctx.tokens.dark, "--cc-title-half"))
      got = W.contrast(fg, ctx.rail_ground.dark)

      assert_in_delta got,
                      6.7068,
                      @negative_control_tolerance,
                      "--cc-title-half on the rail's own ground (#{W.to_hex(ctx.rail_ground.dark)}) " <>
                        "measures #{fmt(got)}, expected roughly 6.71:1 — the figure task 01a07a90's " <>
                        "own comment in app.css records (a browser pixel-read) for this token/ground " <>
                        "pair. A miss bigger than this is worth reporting as a real drift, not widening " <>
                        "further."

      assert got >= @aa_text,
             "negative control failed: --cc-title-half measures #{fmt(got)} against the AA " <>
               "floor and should clear it comfortably. If it does not, this file's detector " <>
               "flags a known-good token and is not trustworthy."
    end
  end

  # ── 5. every --cc-* token shared by both theme blocks is not an accident ──

  # `--cc-micro` was not a one-off. Every sibling in its declaration group
  # (`--cc-stage`, `--cc-byline`, `--cc-reason`) already carried a distinct
  # value per theme; `--cc-micro` alone had been left at its light literal
  # in all three blocks (task 01a08da6 stage 1). Clause B above watches the
  # ONE token that already shipped broken. It cannot catch the next token
  # that ships the same way — that needs a sweep over the whole namespace,
  # not a bigger anchor list.
  #
  # This section reads `--cc-*` custom properties declared in BOTH the
  # light `:root` block and `[data-theme="dark"]`, off the SAME
  # `theme_tokens/2` maps Clause B already trusts, and asserts each one's
  # DECLARED VALUE — the string after the colon, the same granularity
  # `--cc-micro`'s own defect lived at (`#6b7385` typed twice, verbatim) —
  # differs between the two blocks.
  #
  # String identity, not resolved colour: a token that reads
  # `var(--cc-title-half)` in both blocks is NOT flagged by this sweep,
  # because the split lives in the token it points at rather than in its
  # own literal. That is a real, common, and correct pattern here — it is
  # what stage 1 itself used to fix `--cc-micro` — so a sweep that could
  # not tell it apart from the defect would either miss the next literal
  # duplicate or flag every alias in the file. `@invariant_cc_tokens` below
  # is the explicit list of tokens this sweep does not expect to differ,
  # each with the one-line reason a reviewer would otherwise have to
  # rediscover:
  #
  #   * SIX are pure indirection through a token that is ITSELF per-theme:
  #     `--cc-micro`, `--cc-stage` (both -> `--cc-title-half`), `--cc-border`
  #     (-> `--edge`), `--cc-correct-bg` (-> `--color-base-200`),
  #     `--cc-correct-fg` (-> `--color-base-content`), and `--cc-correct-rule`
  #     (-> `--cc-border`, so two hops deep). The declared STRING is
  #     identical; the PAINTED colour is not.
  #   * SIX are true literals, kept identical on purpose:
  #     `--cc-go-bg` / `--cc-go-border` / `--cc-go-fg` are the filled "Go
  #     ahead" button's own closed colour system (app.css :7352-7354) —
  #     fill and text are always used as the SAME pair in both themes
  #     (7.02:1, white on #2f57a0), so there is no separate light/dark
  #     pairing to check. `--cc-ask-rule` is a decorative left-rule
  #     (app.css :7337), not text, and measures 3.69:1 light / 3.85:1 dark
  #     against `--cc-ask-bg`, which DOES move per theme. `--cc-live-dot`
  #     is one semantic "live" status green in both themes, the same
  #     posture the brand `--color-success`/`--color-warning`/
  #     `--color-error` tokens take. `--cc-title-dead` is UNUSED — app.css
  #     :7205 records it was measured under AA on the closed row and
  #     superseded there by `--cc-title-half`; no `var(--cc-title-dead)`
  #     consumer remains anywhere in this file, so an invariant value on it
  #     cannot paint a regression nobody reads.
  #
  # This sweep does not resolve `var()` chains or recompute contrast for
  # the allowlisted tokens — that would just be a second, weaker copy of
  # Clause B. Its only claim is "shared on purpose, for a stated reason,"
  # never "passes AA."
  #
  # OUT OF SCOPE, deliberately: `--color-*` brand tokens (a different
  # ticket), and fixing anything this sweep finds. A token that is shared
  # WITHOUT an honest reason is a finding for a follow-up, not something
  # this stage retunes or launders into the allowlist to go green.
  @invariant_cc_tokens %{
    "--cc-ask-rule" =>
      "decorative left-rule on the ask block, not text; 3.69:1 light / 3.85:1 dark " <>
        "against --cc-ask-bg, which is itself per-theme",
    "--cc-border" => "aliases --edge, which is per-theme (oklch(88% 0 0) light, #232A38 dark)",
    "--cc-correct-bg" =>
      "aliases --color-base-200, per-theme via the daisyui-theme plugin blocks",
    "--cc-correct-fg" =>
      "aliases --color-base-content, per-theme (oklch(0% 0 0) light, oklch(95% 0 0) dark)",
    "--cc-correct-rule" => "aliases --cc-border, itself aliasing the per-theme --edge",
    "--cc-go-bg" => "the filled Go-ahead button's own fill; always paired with --cc-go-fg",
    "--cc-go-border" => "the same button's border, drawn against its own fixed fill",
    "--cc-go-fg" =>
      "white text on the fixed --cc-go-bg fill (7.02:1); the pair is theme-independent by " <>
        "construction, not by oversight",
    "--cc-live-dot" => "one semantic status green in both themes, the brand-colour posture",
    "--cc-micro" =>
      "aliases --cc-title-half (task 01a08da6 stage 1) — the fix this file guards; " <>
        "per-theme via the alias, not via its own literal",
    "--cc-stage" => "aliases --cc-title-half (task 01a07a90); documented at app.css :6605-6612",
    "--cc-title-dead" =>
      "UNUSED — no `var(--cc-title-dead)` consumer remains; app.css :7205 records why it " <>
        "was superseded rather than retuned"
  }

  # This sweep's own positive control: three siblings from `--cc-micro`'s
  # own declaration group that are genuinely per-theme at
  # `origin/main@2c09f728`. Asserted present AND differing, so a parser
  # that silently matched nothing could not pass the rest of this section
  # by accident.
  @known_per_theme_members ["--cc-title-half", "--cc-byline", "--cc-reason"]

  describe "every --cc-* token shared by both theme blocks is intentionally shared" do
    test "the sweep finds a non-trivial, expected-size set of shared tokens", %{tokens: tokens} do
      both = shared_cc_tokens(tokens)

      assert both != [],
             "no `--cc-*` token is declared in BOTH the light and dark theme blocks — the " <>
               "block parser has drifted from app.css's actual shape and this sweep is not " <>
               "looking at anything. An empty result here is a broken parser, not a clean " <>
               "stylesheet: --cc-title-half alone is declared in both."

      assert length(both) >= 40,
             "expected roughly 46 shared `--cc-*` tokens (measured at task 01a08da6 stage 3), " <>
               "got #{length(both)}: #{inspect(Enum.sort(both))}. A count this far off means " <>
               "the block parser is reading the wrong `:root` or `[data-theme=\"dark\"]` " <>
               "block — app.css declares more than one of each."
    end

    test "the known per-theme members are present and actually differ", %{tokens: tokens} do
      for token <- @known_per_theme_members do
        light = Map.fetch!(tokens.light, token)
        dark = Map.fetch!(tokens.dark, token)

        refute light == dark,
               "#{token} is expected to be per-theme (light #{inspect(light)}, dark " <>
                 "#{inspect(dark)} at origin/main@2c09f728) and is this sweep's own positive " <>
                 "control. If it ever reads the SAME in both blocks, either app.css " <>
                 "regressed or this sweep is reading the wrong block."
      end
    end

    test "every shared token differs between themes, or is named on the allowlist with a reason",
         %{tokens: tokens} do
      offenders =
        tokens
        |> shared_cc_tokens()
        |> Enum.reject(&Map.has_key?(@invariant_cc_tokens, &1))
        |> Enum.filter(fn token ->
          Map.fetch!(tokens.light, token) == Map.fetch!(tokens.dark, token)
        end)

      assert offenders == [],
             "these `--cc-*` tokens declare the IDENTICAL value in the light and dark theme " <>
               "blocks and are not on @invariant_cc_tokens: " <>
               Enum.map_join(offenders, "; ", fn token ->
                 "#{token} = #{inspect(Map.fetch!(tokens.light, token))}"
               end) <>
               ". This is the exact shape of --cc-micro's own defect (task 01a08da6): a " <>
               "token that never got a dark value, sharing the light one by omission rather " <>
               "than by design. Give it a per-theme value, or — ONLY if the sharing is " <>
               "genuinely deliberate — add it to @invariant_cc_tokens with a one-line reason. " <>
               "Do not add it there just to make this assertion pass."
    end

    test "the allowlist stays honest: every entry names a real, currently-shared token", %{
      tokens: tokens
    } do
      both = MapSet.new(shared_cc_tokens(tokens))

      stale = Enum.reject(Map.keys(@invariant_cc_tokens), &MapSet.member?(both, &1))

      assert stale == [],
             "these @invariant_cc_tokens entries do not name a `--cc-*` token declared in " <>
               "BOTH theme blocks: #{Enum.join(stale, ", ")}. The token was renamed, removed, " <>
               "or never shared in the first place — either way the entry is stale."

      drifted =
        @invariant_cc_tokens
        |> Map.keys()
        |> Enum.filter(&MapSet.member?(both, &1))
        |> Enum.filter(fn token ->
          Map.fetch!(tokens.light, token) != Map.fetch!(tokens.dark, token)
        end)

      assert drifted == [],
             "these tokens are on @invariant_cc_tokens (claimed theme-invariant) but now " <>
               "declare DIFFERENT values per theme: #{Enum.join(drifted, ", ")}. The value " <>
               "moved apart, which is good, but the allowlist entry is stale and should be " <>
               "removed rather than left claiming an invariance that no longer holds."
    end
  end

  # ── assertions ───────────────────────────────────────────────────────────

  defp assert_gradient_stops(ctx, theme, ground_token, ground_label) do
    tokens = Map.fetch!(ctx.tokens, theme)
    fg = painted(resolve!(tokens, ctx.quote_fg_token))
    {top_hex, bottom_hex} = gradient_stops!(tokens, ground_token)

    for {stop_label, stop_hex} <- [{"top (0%)", top_hex}, {"bottom (100%)", bottom_hex}] do
      bg = painted(W.hex(stop_hex))
      got = W.contrast(fg, bg)

      assert got >= @aa_text,
             "#{theme}: .candidate-card__quote via #{ctx.quote_fg_token} measures " <>
               "#{fmt(got)} against the #{stop_label} stop of #{ground_token} " <>
               "(#{ground_label}, #{stop_hex}), under the #{@aa_text} floor. Text " <>
               "#{W.to_hex(fg)}."
    end
  end

  # The matched rules for `element` that declare `opacity`, asserted empty.
  # Non-empty match set first: a matcher that matches nothing proves nothing.
  defp assert_no_opacity(rules, element, what) do
    matched = Enum.filter(rules, &CssRules.matches?(&1.selector, element))

    assert matched != [],
           "no rule in #{@css_path} matches #{what}; the matcher or the rendered markup " <>
             "has drifted and this clause is not looking at anything"

    offenders = Enum.filter(matched, &CssRules.declares?(&1.body, "opacity"))

    assert offenders == [],
           "these rules match #{what} and declare `opacity`: " <>
             Enum.map_join(offenders, "; ", &"`#{&1.selector}` { #{String.trim(&1.body)} }") <>
             ". `opacity` composites the colour AFTER it resolves, so Clause B (which " <>
             "recomputes from declared colours) is blind to it and no token choice can " <>
             "restore the quote's contrast from inside."
  end

  # Every `--cc-*` custom property declared in BOTH theme maps — the input
  # to the section 5 sweep. Reuses the SAME `tokens.light` / `tokens.dark`
  # maps Clause B already trusts (built by `theme_tokens/2` below), so this
  # sweep cannot disagree with Clause B about how a theme resolves.
  defp shared_cc_tokens(%{light: light, dark: dark}) do
    cc_keys = fn map -> map |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "--cc-")) end

    cc_keys.(light)
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(cc_keys.(dark)))
    |> Enum.to_list()
  end

  defp class_suffix(%{classes: classes}) do
    case MapSet.to_list(classes) do
      [] -> ""
      list -> "." <> Enum.join(list, ".")
    end
  end

  defp fmt(ratio), do: :erlang.float_to_binary(ratio, decimals: 4) <> ":1"

  # ── the rendered quote card ─────────────────────────────────────────────

  # One OPEN, populated (`:acting`) candidate — the state stage 1's own
  # screenshot evidence used, and the one whose card ground is
  # `--cc-bg-acting`. `presentation/1` returns `:full` for any state
  # other than `:heard`/`:thinking`, so this exercises the SAME
  # `.candidate-card__quote` markup a `:shaping` card would, and the
  # `--cc-bg-shaping` assertions above still hold because they resolve
  # the token from the stylesheet, not from what state this fixture uses.
  defp quote_card_html do
    candidate = %MeetingCandidate{
      id: Ecto.UUID.generate(),
      evidence_quote: "we should ship the onboarding funnel changes before the Friday cutoff",
      state: :acting,
      classified_intent: "create_task",
      outcome_kind: :task,
      assigned_agent_slug: "octavius",
      target_role: "engineer",
      transcript_chunk_ids: [],
      acts_at: nil,
      inserted_at: @now
    }

    render_component(&CandidateRail.candidate_rail/1,
      candidates: [candidate],
      closed: [],
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
          "expected exactly one #{inspect(selector)} in the rendered card, got #{length(tags)}"
        )
    end
  end

  # A `CssRules` element for a LazyHTML node with its real ancestors.
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

  # ── the rail's own ground (the negative control's backdrop) ────────────

  # `bg-base-200/40` appears TWICE in the ancestor chain — once on the
  # `<aside>` in call_shell.ex and again on the rail `<section>` in
  # candidate_rail.ex — mirrored from candidate_closed_row_contrast_test.exs,
  # which is where `--cc-stage`'s (and so, via the same
  # `var(--cc-title-half)`, this file's negative control's) recorded
  # 5.0024:1 / 6.7068:1 figures were measured against.
  defp rail_ground(tokens) do
    aside = tailwind_alpha!(class_attr!(File.read!(@shell_path), "call-rail"), "bg-base-200")
    rail = tailwind_alpha!(class_attr!(File.read!(@rail_path), "rail-section"), "bg-base-200")

    base_100 = resolve!(tokens, "--color-base-100")
    base_200 = resolve!(tokens, "--color-base-200")

    base_100
    |> then(&W.composite(base_200, aside, &1))
    |> then(&W.composite(base_200, rail, &1))
    |> painted()
  end

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

  # ── reading app.css ──────────────────────────────────────────────────────

  # A theme's token map. Light is the base cascade; dark is light with the
  # dark blocks layered over it, matching what the browser actually
  # resolves — mirrors candidate_closed_row_contrast_test.exs exactly, so
  # the two files cannot silently disagree about how a theme resolves.
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

  # The TOKEN a selector's property points at, read from the rule rather
  # than assumed — what makes a retune move this file's numbers.
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
          "`#{selector}`'s `#{property}` is #{inspect(value)}, not a `var(--token)`. This " <>
            "quote's colour is supposed to come from a named token so a retune is visible " <>
            "in one place; a literal here is what this file exists to notice."
        )
    end
  end

  # The two hex stops of a `linear-gradient(180deg, #rrggbb 0%, #rrggbb 100%)`
  # custom property. Raises on any other shape rather than guessing, since a
  # gradient rewritten as three stops or a different angle is exactly the
  # kind of drift a silent partial match would hide.
  defp gradient_stops!(tokens, token) do
    value = tokens |> Map.fetch!(token) |> String.trim()

    case Regex.run(
           ~r/^linear-gradient\(\s*180deg\s*,\s*(#[0-9a-fA-F]{6})\s+0%\s*,\s*(#[0-9a-fA-F]{6})\s+100%\s*\)$/,
           value,
           capture: :all_but_first
         ) do
      [top, bottom] ->
        {top, bottom}

      nil ->
        flunk(
          "#{token} is #{inspect(value)}, not the expected " <>
            "`linear-gradient(180deg, #rrggbb 0%, #rrggbb 100%)` form this file parses. " <>
            "Teach gradient_stops!/2 the new shape rather than hardcoding a stop here."
        )
    end
  end

  # ── resolving a declared value to a colour ──────────────────────────────

  @color_mix_re ~r/^color-mix\(\s*in\s+(oklch|oklab|srgb)\s*,\s*(.+?)\s+(\d+)%\s*,\s*(.+?)\s*\)$/

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

      value == "white" ->
        W.hex("#FFFFFF")

      value == "black" ->
        W.hex("#000000")

      true ->
        W.parse!(value)
    end
  end

  defp mix!(tokens, space, a, pct, b, seen) when space in ["oklch", "oklab"] do
    ca = resolve_value!(tokens, a, seen)
    cb = resolve_value!(tokens, b, seen)

    if space == "oklch" and not achromatic?(ca) and not achromatic?(cb) do
      flunk(
        "`color-mix(in oklch, ...)` between two chromatic colours (#{W.to_hex(ca)} and " <>
          "#{W.to_hex(cb)}) cannot be computed with mix_oklab/3 here."
      )
    end

    W.mix_oklab(ca, pct, cb)
  end

  defp mix!(tokens, "srgb", a, pct, b, seen) do
    ca = resolve_value!(tokens, a, seen)
    cb = resolve_value!(tokens, b, seen)
    W.composite(ca, pct / 100.0, cb)
  end

  defp achromatic?(color) do
    {_l, a, b} = W.to_oklab(color)
    abs(a) < 0.0005 and abs(b) < 0.0005
  end

  # ── which quantity this file measures ───────────────────────────────────

  # THE PAINTED QUANTITY, matching candidate_closed_row_contrast_test.exs:
  # the compositor rounds every colour to 8 bits per channel before it
  # reaches a pixel, so that is where this file rounds too.
  defp painted(color), do: color |> W.to_hex() |> W.hex()

  defp capture!(source, re, what) do
    case Regex.run(re, source, capture: :all_but_first) do
      [value] -> value
      nil -> flunk("could not find #{what}")
    end
  end
end
