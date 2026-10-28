defmodule Platform.Design.CandidateDrainRearmSnapTest do
  @moduledoc """
  The candidate drain must EASE when it shrinks and SNAP when it grows —
  task `01a0740e`, remediation of the behavioural gate's one failed clause.

  ## The defect this pins

  `.candidate-drain { transition: width 0.9s linear }` arrived with FE-9
  (`adef1917`, #942) and was written for a bar that only ever shrinks: the
  0.9s ramp is what makes a once-a-second width change read as a continuous
  drain rather than as a staircase.

  `Platform.Meetings.Candidates.rearm/2` is the first thing in this codebase
  that makes that width GROW. A correction hands the card its full thirty
  seconds back, and because the drain node is patched in place rather than
  replaced, the inherited rule eased the growth too. Measured in a real
  browser over three trials: the inline style stepped `80% -> 100%` in one
  go while the PAINTED width interpolated `228px -> 285px` across ten
  samples, about 0.9s of bar sweeping left to right. The numeral jumped and
  the bar refilled — one event, drawn two contradictory ways.

  ## Why the guard is shaped like this and not like a grep

  Two mistakes are equally easy here and this file has to separate them:

    * **the fix missing** — the growth still eases, and the sweep is back;
    * **the fix over-applied** — somebody deletes the transition, or leaves
      the suppression on permanently, and FE-9's drain silently becomes a
      staircase on every countdown in the product. That is a defect on a
      surface nobody is looking at, manufactured by the remedy for one
      nobody was looking at either.

  So this file does not ask "does `transition` appear in the file". It asks
  what the BROWSER asks — which rules apply to the rendered drain, and which
  `transition` declaration wins — and it asks it TWICE, once for the drain
  as it renders and once for the same drain carrying
  `candidate-drain--snap`. Those two answers must differ, and each must be
  the right one. A guard that only checked the second would pass a
  stylesheet with no easing left in it at all.

  ## What this file CANNOT prove, and where that proof lives

  A `transition: none` class nobody applies is worth nothing, and no
  stylesheet assertion can tell the difference. The behavioural half — that
  `CandidateClock` adds the class on the tick where `remaining` INCREASES
  and takes it off again on the next tick that decreases — is pinned in
  `assets/test/hooks/candidate_clock.test.js`, under
  `describe("the drain when the window comes BACK")`, which CI gates as its
  own vitest step. The one clause below that reaches across is the name
  pin: the class this stylesheet defines has to be the string that hook
  actually applies, or the two halves are each green about nothing.

  ## The named mutation for this module

  **Delete the `.candidate-drain--snap` rule from `app.css`.** The clause
  `the snap class wins for a growing width` must red, reporting that the
  winning declaration for the snapped drain is `width 0.9s linear`. The
  converse mutation — replacing `.candidate-drain`'s body with
  `transition: none` — must red `a shrinking drain still eases`. If either
  survives, the matcher is looking at the wrong element: report it, never
  weaken this to a string grep.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Platform.Design.CssRules
  alias Platform.Meetings.MeetingCandidate
  alias PlatformWeb.Components.Meetings.CandidateRail

  @css_path "assets/css/app.css"
  @hook_path "assets/js/hooks/candidate_clock.js"

  @snap_class "candidate-drain--snap"
  @easing "width 0.9s linear"

  @now ~U[2026-09-01 12:00:00.000000Z]

  setup_all do
    html =
      render_component(&CandidateRail.candidate_rail/1,
        candidates: [armed(18)],
        closed: [],
        events: %{},
        now: @now
      )
      |> LazyHTML.from_fragment()

    drain = LazyHTML.query(html, "[data-role='meeting-candidate-drain']")

    %{
      rules: CssRules.rules(File.read!(@css_path)),
      drain: drain,
      plain: css_element(drain),
      snapped: css_element(drain, [@snap_class])
    }
  end

  # ── 1. the element is the rendered one ─────────────────────────────────

  describe "the element is the rendered one" do
    test "an armed card renders exactly one drain, and it carries the base class", %{
      drain: drain
    } do
      assert LazyHTML.tag(drain) == ["span"]

      assert classes(drain) == MapSet.new(["candidate-drain"]),
             "the drain's class set drifted to " <>
               "#{inspect(LazyHTML.attribute(drain, "class"))}; update the expectation here " <>
               "AND re-check every clause below still matches the rendered bar"
    end

    test "the rendered drain does NOT already carry the snap class", %{drain: drain} do
      # The suppression is a per-tick client decision, never server markup.
      # A drain rendered snapped would be the permanent over-fix, shipped
      # from the other end of the stack.
      refute MapSet.member?(classes(drain), @snap_class)
    end

    test "the drain is a descendant of the armed card, so descendant rules are judged", %{
      plain: plain
    } do
      # Without real ancestors, `.candidate-card .candidate-drain { ... }`
      # would be invisible to the matcher and the guard would be narrower
      # than it reads.
      assert Enum.any?(plain.ancestors, &MapSet.member?(&1.classes, "candidate-card"))
    end
  end

  # ── 2. the cascade, resolved the way the browser resolves it ───────────

  describe "the winning transition declaration" do
    test "a shrinking drain still eases — FE-9's 0.9s ramp survives", %{
      rules: rules,
      plain: plain
    } do
      declared = transitions(rules, plain)

      assert declared != [],
             "no rule declaring `transition` applies to the rendered drain at all. " <>
               "That is a broken matcher, not a clean stylesheet."

      assert winner(declared) == {".candidate-drain", @easing},
             "the drain a normal countdown paints resolves to " <>
               "#{inspect(winner(declared))}, not the 0.9s easing.\n" <>
               describe_transitions(declared) <>
               "\nThat easing is what makes a once-a-second width change read as a drain " <>
               "instead of a staircase. Suppressing the re-arm sweep must not cost it."
    end

    test "the snap class wins for a growing width", %{rules: rules, snapped: snapped} do
      declared = transitions(rules, snapped)

      assert declared != [],
             "no rule declaring `transition` applies to a snapped drain. Broken matcher."

      assert winner(declared) == {".#{@snap_class}", "none"},
             "a drain carrying `#{@snap_class}` resolves to " <>
               "#{inspect(winner(declared))}, so a width that GROWS is still eased and the " <>
               "bar sweeps backwards for 0.9s.\n" <>
               describe_transitions(declared) <>
               "\nThe suppressing rule must exist AND sit after `.candidate-drain`: they " <>
               "are the same specificity, so source order is the whole of what decides."
    end

    test "the two answers differ — the pair is the claim, not either half", %{
      rules: rules,
      plain: plain,
      snapped: snapped
    } do
      # Stated on its own because each clause above passes against a
      # stylesheet the other rejects. `transition: none` everywhere satisfies
      # the second; no snap rule at all satisfies the first.
      #
      # The comparison is on the VALUE and not on the winning selector. A
      # stylesheet where `.candidate-drain` itself declares `transition:
      # none` has two different winning SELECTORS resolving to the same
      # suppression, which is the over-fix wearing the shape of a pass.
      {_plain_selector, plain_value} = winner(transitions(rules, plain))
      {_snap_selector, snap_value} = winner(transitions(rules, snapped))

      refute plain_value == snap_value
    end

    test "nothing else declares `transition` onto the drain, under a media query or otherwise",
         %{rules: rules, plain: plain, snapped: snapped} do
      # The whole matching set, at-rules included, pinned by name. A new
      # rule reaching this bar reds here and a human decides, rather than
      # quietly changing which declaration wins.
      assert all_transitions(rules, plain) == [
               {"", ".candidate-drain", @easing},
               {"@media (prefers-reduced-motion: reduce)", ".candidate-drain", "none"}
             ]

      assert all_transitions(rules, snapped) == [
               {"", ".candidate-drain", @easing},
               {"", ".#{@snap_class}", "none"},
               {"@media (prefers-reduced-motion: reduce)", ".candidate-drain", "none"}
             ]
    end
  end

  # ── 3. the class is one somebody applies ───────────────────────────────

  describe "the stylesheet and the hook agree on the name" do
    test "CandidateClock applies the class this stylesheet defines" do
      hook = File.read!(@hook_path)

      assert String.contains?(hook, @snap_class),
             "`#{@hook_path}` never mentions `#{@snap_class}`. A `transition: none` rule " <>
               "nobody applies suppresses nothing, and every stylesheet clause above would " <>
               "stay green. WHEN the class is applied is pinned in " <>
               "assets/test/hooks/candidate_clock.test.js, which this cannot see."
    end
  end

  # ── 4. the resolver discriminates ──────────────────────────────────────

  describe "the resolver discriminates" do
    @real """
    .candidate-drain { transition: width 0.9s linear }
    .candidate-drain--snap { transition: none }
    """

    test "green: the shipped shape" do
      assert resolve(@real) == {@easing, "none"}
    end

    test "red: the snap rule declared BEFORE the base rule loses on source order" do
      reversed = """
      .candidate-drain--snap { transition: none }
      .candidate-drain { transition: width 0.9s linear }
      """

      assert resolve(reversed) == {@easing, @easing}
    end

    test "red: no snap rule at all" do
      assert resolve(".candidate-drain { transition: width 0.9s linear }") == {@easing, @easing}
    end

    test "red: the over-fix, easing deleted from the base rule" do
      over = """
      .candidate-drain { transition: none }
      .candidate-drain--snap { transition: none }
      """

      assert resolve(over) == {"none", "none"}
    end

    test "a rule on a class the drain does not carry is not counted" do
      # `.candidate-drain--spent` is a real rule in the stylesheet declaring
      # `transition: none`, and an armed drain never carries it. A matcher
      # that swept selectors by prefix would read it as the winner and call
      # the bug fixed.
      with_spent = @real <> "\n.candidate-drain--spent { transition: none }\n"
      assert resolve(with_spent) == {@easing, "none"}
    end

    test "`transition-duration` is not a `transition`" do
      # The universal reduced-motion damper declares `transition-duration`.
      # An unanchored match would read it as the winning `transition` for
      # every element on the page.
      damped = @real <> "\n* { transition-duration: 0.01ms }\n"
      assert resolve(damped) == {@easing, "none"}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp armed(secs) do
    %MeetingCandidate{
      id: Ecto.UUID.generate(),
      evidence_quote: "we should rotate the staging secrets",
      state: :shaping,
      outcome_kind: :artifact,
      classified_intent: "action_items",
      transcript_chunk_ids: [Ecto.UUID.generate()],
      acts_at: DateTime.add(@now, secs, :second),
      inserted_at: @now
    }
  end

  defp classes(node) do
    node |> LazyHTML.attribute("class") |> Enum.join(" ") |> String.split() |> MapSet.new()
  end

  # A `CssRules` element for the rendered drain, with its real ancestors, and
  # optionally carrying classes the client adds at runtime.
  defp css_element(node, extra_classes \\ []) do
    [tag] = LazyHTML.tag(node)
    [attrs] = LazyHTML.attributes(node)

    attrs =
      Enum.map(attrs, fn
        {"class", value} -> {"class", Enum.join([value | extra_classes], " ")}
        other -> other
      end)

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

  # Every rule that applies to `element` and declares `transition`, in source
  # order, as `{at_prelude, selector, value}`.
  defp all_transitions(rules, element) do
    rules
    |> Enum.filter(&CssRules.matches?(&1.selector, element))
    |> Enum.filter(&CssRules.declares?(&1.body, "transition"))
    |> Enum.map(&{Enum.join(&1.at, " "), &1.selector, transition_value(&1.body)})
  end

  # The UNCONDITIONAL ones. A rule inside `@media (prefers-reduced-motion)`
  # is not what a default session resolves, and folding it in here would
  # report every drain as already suppressed.
  defp transitions(rules, element) do
    rules |> all_transitions(element) |> Enum.filter(&(elem(&1, 0) == ""))
  end

  # Last one wins. Honest only because every selector in this set is a
  # single class and therefore the same specificity — which is exactly what
  # the `nothing else declares transition` clause above is pinning.
  defp winner([]), do: nil
  defp winner(declared), do: declared |> List.last() |> then(fn {_at, sel, v} -> {sel, v} end)

  defp transition_value(body) do
    [_, value] = Regex.run(~r/(^|;)\s*transition\s*:\s*([^;]+)/, body, capture: :all_but_first)
    String.trim(value)
  end

  # `{winning value for a plain drain, winning value for a snapped one}`
  # over a synthetic stylesheet and a synthetic drain.
  defp resolve(css) do
    rules = CssRules.rules(css)

    plain = CssRules.element("span", [{"class", "candidate-drain"}])
    snapped = CssRules.element("span", [{"class", "candidate-drain #{@snap_class}"}])

    {value(rules, plain), value(rules, snapped)}
  end

  defp value(rules, element) do
    case winner(transitions(rules, element)) do
      nil -> nil
      {_selector, value} -> value
    end
  end

  defp describe_transitions(declared) do
    Enum.map_join(declared, "\n", fn {at, selector, value} ->
      at = if at == "", do: "", else: at <> " "
      "  #{at}`#{selector}` { transition: #{value} }"
    end)
  end
end
