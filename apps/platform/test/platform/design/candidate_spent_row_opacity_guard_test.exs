defmodule Platform.Design.CandidateSpentRowOpacityGuardTest do
  @moduledoc """
  No rule that applies to the meeting rail's SPENT row may fade it —
  task `01a078d1` stage 1.

  ## Why this file exists

  The spent row (task `01a0740e` stage 5) is what a stop leaves in a card's
  slot for ten seconds: `Stopped` and an `Undo`. It is dimmed on purpose,
  and the dim is ONE measured token, `--cc-spent-fg`, which sits at 5.39:1
  on `--cc-bg-closed` in the light theme (pinned by
  `candidate_closed_row_contrast_test.exs`). An `opacity` on the row, or on
  any rule that reaches it, composites that colour against the ground
  *after* it resolves, and no token can undo it from inside: at 0.72 the
  label would land near 3.6:1, under the 4.5:1 AA floor — the same
  mechanism task `01a07a90` removed from `.candidate-card--closed`.

  `candidate_closed_row_contrast_test.exs` guards that ONE rule body by
  regex. Nothing guarded the spent row, and "the closed rule declares no
  opacity" says nothing about `.candidate-card--spent`, `.candidate-card`,
  a `@media` override, a `:hover` on the undo control, or a descendant
  selector — every one of which fades the row just as well. This file
  closes that hole by asking the question the browser asks: *which rules
  apply to this element, and does any of them declare `opacity`?*

  ## Why not "no `opacity` in the candidate region"

  The region has four live `opacity` declarations and all four are
  legitimate: they sit inside `@keyframes candidate-card-in` and
  `candidate-card-out`, which animate a card's arrival and departure. A
  line grep reds shipped code; a grep that skips `@keyframes` has already
  parsed the file into rules, and a parser that far has selectors in hand.
  So this file uses `Platform.Design.CssRules`, which does exactly that, and
  matches the rendered element rather than a class name typed here.

  ## The anti-vacuity argument

    * `describe "the element is the rendered one"` RENDERS the row through
      `CandidateRail.candidate_rail/1` and reads its classes off the
      markup. If the markup drifts, that clause reds first with the new
      class list, so the matcher is never quietly matching a row that no
      longer exists.
    * every matched set is asserted NON-EMPTY before it is asserted clean.
      An empty match set means the matcher is broken, not that the row is
      clean.
    * `describe "the matcher discriminates"` runs the same assertion over
      synthetic stylesheets that MUST red (a fade on the base class, under a
      media query, on a `:hover`, via a descendant, in a selector list) and
      that MUST stay green (a comment, an unrelated class, the sibling
      modifier `.candidate-card--closed` the row does not carry, a
      keyframe step).

  The named mutation for this module is: **append `opacity: .7` to
  `.candidate-card--spent` in `app.css`.** The applies-to-the-row clause
  must red naming that selector. If it stays green, the matcher is
  matching the wrong thing — a finding to report, never a reason to weaken
  this to a string grep.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Platform.Design.CssRules
  alias PlatformWeb.Components.Meetings.CandidateRail

  @css_path "assets/css/app.css"
  @now ~U[2026-09-01 12:00:00.000000Z]

  # Contrast of --cc-spent-fg on --cc-bg-closed (light), as pinned by
  # candidate_closed_row_contrast_test.exs, and roughly where a 0.72 fade
  # would leave it. Quoted in failure messages only; the pin lives there.
  @spent_label_contrast "5.39:1"
  @faded_label_contrast "~3.6:1"

  setup_all do
    css = File.read!(@css_path)
    html = spent_row_html()

    article = LazyHTML.query(html, "[data-role='meeting-candidate-spent']")
    label = LazyHTML.query(article, "[data-role='meeting-candidate-spent-label']")
    undo = LazyHTML.query(article, "[data-role='meeting-candidate-undo']")

    %{
      css: css,
      rules: CssRules.rules(css),
      keyframes: CssRules.keyframes(css),
      article: article,
      label: label,
      undo: undo,
      elements: %{
        "article" => element(article),
        "label" => element(label),
        "undo" => element(undo)
      }
    }
  end

  # ── 1. the element is the rendered one ─────────────────────────────────

  describe "the element is the rendered one" do
    test "the spent row renders as one article carrying exactly its two classes", %{
      article: article
    } do
      assert LazyHTML.tag(article) == ["article"]

      assert classes(article) == MapSet.new(["candidate-card", "candidate-card--spent"]),
             "the spent row's class set drifted to #{inspect(LazyHTML.attribute(article, "class"))}; " <>
               "update the expected set here AND check every clause below still matches " <>
               "the rendered row"
    end

    test "its two text children are the label and the undo control", %{
      label: label,
      undo: undo
    } do
      assert LazyHTML.tag(label) == ["p"]
      assert classes(label) == MapSet.new(["candidate-spent__label"])

      assert LazyHTML.tag(undo) == ["button"]
      assert classes(undo) == MapSet.new(["candidate-btn", "candidate-btn--undo", "ml-auto"])
    end

    test "the article is the label's and the undo control's parent", %{
      elements: %{"label" => label, "undo" => undo, "article" => article}
    } do
      assert hd(label.ancestors).classes == article.classes
      assert hd(undo.ancestors).classes == article.classes
    end
  end

  # ── 2. no rule that applies to the spent row declares opacity ──────────

  describe "no rule that applies to the spent row declares opacity" do
    for {name, minimum} <- [
          {"article", [".candidate-card", ".candidate-card--spent"]},
          {"label", [".candidate-spent__label"]},
          {"undo", [".candidate-btn", ".candidate-btn--undo:hover"]}
        ] do
      @tag name: name, minimum: minimum
      test "the #{name}", %{rules: rules, elements: elements, name: name, minimum: minimum} do
        matched = matching(rules, elements[name])
        selectors = Enum.map(matched, & &1.selector)

        for selector <- minimum do
          assert selector in selectors,
                 "expected `#{selector}` to match the rendered #{name}; matched only " <>
                   "#{inspect(selectors)} — the matcher is broken, this is not a clean row"
        end

        assert_no_fade(matched, name)
      end
    end
  end

  # ── 3. no animation on the spent row reaches an opacity keyframe ───────

  describe "no animation on the spent row reaches an opacity keyframe" do
    # `@keyframes candidate-card-out` fades to 0 legitimately, for
    # `.candidate-card--leave`. `animation: candidate-card-out forwards` on
    # a rule that matches the spent row fades the row with no `opacity:`
    # on any matching rule, which is the side door clause 2 cannot see.
    test "on the real stylesheet", %{rules: rules, keyframes: keyframes, elements: elements} do
      for {name, element} <- elements do
        assert_no_fading_animation(matching(rules, element), keyframes, name)
      end
    end

    test "the resolver reds on a synthetic animation into an opacity keyframe" do
      css = """
      @keyframes candidate-card-out { from { opacity: 1 } to { opacity: 0 } }
      .candidate-card--spent { animation: candidate-card-out 1s ease-in forwards; }
      """

      assert_raise ExUnit.AssertionError, ~r/candidate-card-out/, fn ->
        assert_no_fading_animation(
          matching(CssRules.rules(css), synthetic_article()),
          CssRules.keyframes(css),
          "article"
        )
      end
    end

    test "and stays green on an animation whose keyframes move without fading" do
      css = """
      @keyframes nudge { from { transform: none } to { transform: translateY(-4px) } }
      .candidate-card--spent { animation: nudge 1s; }
      """

      assert_no_fading_animation(
        matching(CssRules.rules(css), synthetic_article()),
        CssRules.keyframes(css),
        "article"
      )
    end
  end

  # ── 4. the matcher discriminates ───────────────────────────────────────

  describe "the matcher discriminates" do
    @green [
      {"a comment", "/* opacity */ .candidate-card--spent { display: flex }"},
      {"an unrelated class", ".foo { opacity: .5 }"},
      {"the sibling modifier the row does not carry",
       ".candidate-card--closed { opacity: 0.72 }"},
      {"a keyframe step", "@keyframes candidate-card-out { to { opacity: 0 } }"}
    ]

    @red [
      {"the modifier itself", ".candidate-card--spent { opacity: .7 }", ".candidate-card--spent"},
      {"the base class", ".candidate-card { opacity: .9 }", ".candidate-card"},
      {"an at-rule override",
       "@media (max-width: 600px) { .candidate-card--spent { opacity: .7 } }",
       "@media (max-width: 600px)"},
      {"a pseudo-class on the undo control", ".candidate-btn--undo:hover { opacity: .5 }",
       ".candidate-btn--undo:hover"},
      {"a descendant selector", ".candidate-card--spent .candidate-spent__label { opacity: .5 }",
       ".candidate-card--spent .candidate-spent__label"},
      {"a selector list", ".candidate-card--spent, .other { opacity: .5 }",
       ".candidate-card--spent"}
    ]

    for {what, css} <- @green do
      test "green: #{what}" do
        assert_row_clean(unquote(css))
      end
    end

    for {what, css, expected} <- @red do
      test "red: #{what}" do
        assert_raise ExUnit.AssertionError, ~r/#{Regex.escape(unquote(expected))}/, fn ->
          assert_row_clean(unquote(css))
        end
      end
    end

    test "a negation is evaluated, not stripped" do
      assert_row_clean(".candidate-card:not(.candidate-card--spent) { opacity: .5 }")

      assert_raise ExUnit.AssertionError, ~r/:not\(\.candidate-card--closed\)/, fn ->
        assert_row_clean(".candidate-card:not(.candidate-card--closed) { opacity: .5 }")
      end
    end

    test "an unparseable selector raises rather than silently not matching" do
      assert_raise ArgumentError, ~r/50%/, fn ->
        assert_row_clean("50% { opacity: .5 }")
      end
    end
  end

  # ── 5. the wider net ───────────────────────────────────────────────────

  describe "no .candidate- rule outside @keyframes declares opacity" do
    # The wider net: clause 2 is the property the ticket names (the rules
    # that reach the RENDERED row); this is a prefix sweep over every
    # `.candidate-*` selector, which also catches a fade on a row this file
    # does not render. It is green today because the four live `opacity`
    # declarations in the region all sit inside `@keyframes`, which
    # `CssRules.rules/1` does not report.
    test "on the real stylesheet", %{rules: rules} do
      offenders =
        rules
        |> Enum.filter(&String.contains?(&1.selector, ".candidate-"))
        |> Enum.filter(&CssRules.declares?(&1.body, "opacity"))

      assert offenders == [],
             "these `.candidate-` rules declare `opacity`:\n" <> describe_rules(offenders)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp spent_row_html do
    id = Ecto.UUID.generate()

    render_component(&CandidateRail.candidate_rail/1,
      candidates: [],
      closed: [],
      events: %{},
      now: @now,
      order: nil,
      undo: %{
        id: id,
        acts_at: DateTime.add(@now, 12, :second),
        expires_at: DateTime.add(@now, 10, :second)
      }
    )
    |> LazyHTML.from_fragment()
  end

  defp classes(node) do
    node |> LazyHTML.attribute("class") |> Enum.join(" ") |> String.split() |> MapSet.new()
  end

  # A `CssRules` element for a single LazyHTML node, with its real
  # ancestors from the rendered tree so descendant selectors are judged
  # against the markup rather than against nothing.
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

  defp synthetic_article do
    CssRules.element("article", [{"class", "candidate-card candidate-card--spent"}])
  end

  defp synthetic_elements do
    article = synthetic_article()

    %{
      "article" => article,
      "label" => CssRules.element("p", [{"class", "candidate-spent__label"}], [article]),
      "undo" =>
        CssRules.element("button", [{"class", "candidate-btn candidate-btn--undo ml-auto"}], [
          article
        ])
    }
  end

  defp matching(rules, element), do: Enum.filter(rules, &CssRules.matches?(&1.selector, element))

  # Clause 2 over a synthetic stylesheet and the synthetic row.
  defp assert_row_clean(css) do
    rules = CssRules.rules(css)

    for {name, element} <- synthetic_elements() do
      assert_no_fade(matching(rules, element), name)
    end
  end

  defp assert_no_fade(matched, name) do
    offenders = Enum.filter(matched, &CssRules.declares?(&1.body, "opacity"))

    assert offenders == [],
           "a rule that applies to the spent row's #{name} declares `opacity`:\n" <>
             describe_rules(offenders) <>
             "\n`opacity` composites the row's colours AFTER they resolve, so the " <>
             "label's #{@spent_label_contrast} on --cc-bg-closed becomes " <>
             "#{@faded_label_contrast} and no token can recover it. Dim this row with " <>
             "darker token values (--cc-spent-fg), not a fade."
  end

  defp assert_no_fading_animation(matched, keyframes, name) do
    offenders =
      for rule <- matched,
          animation <- CssRules.animation_names(rule.body, Map.keys(keyframes)),
          Enum.any?(keyframes[animation], &CssRules.declares?(&1.body, "opacity")) do
        {rule, animation}
      end

    assert offenders == [],
           "a rule that applies to the spent row's #{name} animates with a @keyframes " <>
             "that declares `opacity`:\n" <>
             Enum.map_join(offenders, "\n", fn {rule, animation} ->
               "  `#{rule.selector}` -> @keyframes #{animation}\n" <> describe_rules([rule])
             end) <>
             "\nThat fades the row exactly as an `opacity:` on the rule would; see " <>
             "clause 2 for why."
  end

  defp describe_rules(rules) do
    Enum.map_join(rules, "\n", fn rule ->
      at = if rule.at == [], do: "", else: Enum.join(rule.at, " ") <> " "
      "  #{at}`#{rule.selector}` { #{rule.body} }"
    end)
  end
end
