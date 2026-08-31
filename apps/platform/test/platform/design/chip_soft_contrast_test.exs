defmodule Platform.Design.ChipSoftContrastTest do
  @moduledoc """
  Pins the recorded contrast verdict on the `.chip-soft` block in
  `apps/platform/assets/css/app.css`.

  ## Why a source scan, and what it is actually worth

  There is no runtime observable for "someone measured this and wrote the answer
  down". The finding is a **comment**, so the only thing that can guard it is a
  scan of the file the comment lives in, and a scan cannot tell a comment from a
  call. That weakness is accepted here because the subject *is* the comment.

  What the scan is arranged to avoid is the failure mode that makes such a test
  worthless — passing on text that happens to be somewhere in a 4500-line
  stylesheet. Three arrangements:

    1. The comment is extracted as the block **immediately preceding**
       `.chip-soft {`, not searched for file-wide. A matching phrase anywhere
       else in `app.css` does not satisfy this test.
    2. Whitespace is collapsed before every phrase match, so a formatter rewrap
       that re-flows a sentence across lines does not silently red the suite —
       or, worse, silently green a broken one.
    3. It is paired with declaration assertions on the rule body and on all six
       tone selectors. Delete the `.chip-soft` block and this file goes red on
       those, not merely on a missing string.

  ## The measurement it pins

  Verdict: **LOAD-BEARING**. The chip fill against the card surface it abuts
  (`--color-base-100` on both sides of the pair) reaches at most 1.1741:1 light
  and 1.2973:1 dark across the six tones, so no tone clears the 3:1 non-text
  floor on fill alone and the border is the chip's only boundary.

  Two corrections carried by the comment and asserted here:

    * The chip's edge is **not** adjacent to `--color-base-300`. That token is
      the card's own border (`border border-base-300 bg-base-100`), and a chip
      sits inside the card's padding, so an earlier figure taken against
      base-300 named a pair that does not occur.
    * `background-clip` is at its `border-box` default, so the 25%-alpha border
      composites over the chip's own fill rather than over the card surface.

  The verdict applies to all six tones because all six route through one
  formula, which is why every tone name is asserted individually below.

  ## The disposition it pins (stage 4)

  NOT fixed, deliberately. Raising the border alpha cannot reach 3:1 in the
  light theme for `primary` (1.78748833:1 at 100% tint over `--color-base-100`)
  or `warning` (2.21457697:1); deepening the tint collapses the fill-vs-outline
  distinction the Tasks board relies on; a border drawn from `--chip-label` is
  the outlined box the design rules out. And the obligation never attached: the
  chip is a bare non-interactive `<span>` whose state is named in AA text, so
  WCAG 1.4.11 does not apply. The tests below pin each of those as a line-start
  token on the raw comment so the record cannot be flipped, narrowed to one
  tone, or deleted without this file going red.
  """
  use ExUnit.Case, async: true

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  @tones ~w(neutral info success warning error primary)

  setup_all do
    css = File.read!(@css_path)
    {:ok, css: css, comment: chip_soft_comment(css)}
  end

  describe "the .chip-soft rule itself" do
    test "still declares the formula the verdict was measured on", %{css: css} do
      body = chip_soft_body(css)

      assert body =~ "--chip-tint",
             ".chip-soft no longer declares --chip-tint; the pinned measurement " <>
               "in this file describes a formula that no longer exists."

      assert squish(body) =~
               "background: color-mix(in oklab, var(--chip-tint) 12%, var(--color-base-100))",
             "the 12% light fill is gone from .chip-soft — re-measure before " <>
               "editing the verdict comment. Body was:\n#{body}"

      assert squish(body) =~
               "border: 1px solid color-mix(in oklab, var(--chip-tint) 25%, transparent)",
             "the 25% border is gone from .chip-soft. The recorded verdict is " <>
               "LOAD-BEARING, meaning this border is the chip's only boundary " <>
               "against the card surface; it must not be dropped. Body was:\n#{body}"
    end

    # Anchored at line start on the RAW css, deliberately not on the squished
    # text: `[data-theme="dark"] .chip-primary { --chip-tint: ... }` contains
    # the substring `.chip-primary { --chip-tint`, so a substring scan stays
    # green when the base tone is deleted and only the dark override survives.
    # Probed: deleting the base `.chip-primary` rule reds this test.
    test "all six BASE tone selectors still route through it", %{css: css} do
      for tone <- @tones do
        assert Regex.match?(~r/^\s*\.chip-#{tone}\s*\{[^}]*--chip-tint/m, css),
               "the base (un-prefixed) tone selector .chip-#{tone} is missing " <>
                 "its --chip-tint. The verdict is recorded component-wide across " <>
                 "#{Enum.join(@tones, ", ")}; losing a tone means the pinned " <>
                 "table no longer describes what ships. A theme-prefixed " <>
                 "override does not count."
      end
    end

    test "background-clip is not overridden, so the border composites over the own fill", %{
      css: css
    } do
      refute squish(css) =~ "background-clip:",
             "app.css now sets a background-clip declaration. The .chip-soft verdict " <>
               "comment states the border composites over the chip's OWN fill on " <>
               "the border-box default; if that default is now overridden the " <>
               "border-vs-surface figures must be re-taken."
    end
  end

  describe "the verdict comment" do
    test "exists immediately above .chip-soft", %{comment: comment} do
      assert String.starts_with?(comment, "/*")
      assert String.ends_with?(comment, "*/")

      assert String.length(comment) > 400,
             "the comment above .chip-soft is only #{String.length(comment)} chars — " <>
               "too short to be the measurement record. It reads:\n#{comment}"
    end

    test "states an explicit verdict", %{comment: comment} do
      flat = squish(comment)

      assert flat =~ "VERDICT: the border is LOAD-BEARING",
             "no verdict line in the .chip-soft comment. The next person to " <>
               "measure this must find LOAD-BEARING or DECORATION stated " <>
               "outright. Comment reads:\n#{comment}"
    end

    test "names every one of the six tones", %{comment: comment} do
      flat = squish(comment)

      for tone <- @tones do
        assert flat =~ tone,
               "the .chip-soft verdict comment never names the #{tone} tone. " <>
                 "All six share one formula, so a verdict recorded against a " <>
                 "subset is wrong by construction. Comment reads:\n#{comment}"
      end
    end

    test "names the measured pair as slots, and rules out the non-adjacent one", %{
      comment: comment
    } do
      flat = squish(comment)

      assert flat =~ "--color-base-100",
             "the comment does not name --color-base-100, the surface the chip " <>
               "actually abuts. A ratio is meaningless without its pair."

      assert flat =~ "--color-base-300",
             "the comment does not mention --color-base-300. It must be named " <>
               "in order to be ruled out — that mis-picked pair is the reason " <>
               "the earlier figure was re-taken."

      refute flat =~ ~r/#[0-9a-fA-F]{6}\b/,
             "the .chip-soft verdict comment quotes a raw hex. Pairs are stated " <>
               "as slot vs slot so a palette re-tune cannot leave the record " <>
               "quietly false. Comment reads:\n#{comment}"
    end

    test "records the worst tone per theme, not the flattering one", %{comment: comment} do
      flat = squish(comment)

      assert flat =~ "1.0666",
             "the worst light-theme figure (primary, 1.0666:1) is not in the " <>
               "comment. Comment reads:\n#{comment}"

      # A bare figure pin is not enough here: 1.1948 is the dark `error` cell
      # and was in the table before the worst-pair sentence named `info`, so
      # the sentence itself is pinned, tone and figure together.
      assert flat =~ "`primary` at 1.0666:1 light and `error` at 1.1948:1 dark",
             "the worst-pair sentence does not name `error` at 1.1948:1 as the " <>
               "worst dark tone. Comment reads:\n#{comment}"

      # Stage 5 of task 01a01b22: the dark `info` cell was first recorded as
      # 1.1537, computed by mixing the LIGHT --color-info token into the dark
      # surface. The dark theme block redefines --color-info to oklch(72% 0.12
      # 255), which is what .chip-info takes as --chip-tint, and that gives
      # 1.2715. Reintroducing the light-token figure anywhere reds this.
      assert flat =~ "1.2715",
             "the dark-theme `info` fill figure (1.2715:1, dark --color-info " <>
               "token) is not in the comment. Comment reads:\n#{comment}"

      refute flat =~ "1.1537",
             "the .chip-soft comment carries 1.1537 again — that is the dark " <>
               "`info` fill computed with the LIGHT --color-info token. Use the " <>
               "dark theme's --color-info (1.2715:1). Comment reads:\n#{comment}"
    end
  end

  # Stage 4 of task 01a01b22. The verdict was settled as "document, do not
  # fix", and the record of THAT has to be as hard to erode as the measurement
  # itself. The token lines are matched on the RAW comment anchored at line
  # start — the same lesson as the tone selectors above: a squished substring
  # scan would accept "MUST NOT raise the border alpha" embedded in a sentence
  # that goes on to say "…is wrong, raise it". Prose that may rewrap is matched
  # squished.
  describe "the disposition: documented, deliberately not fixed" do
    test "carries a line-start VERDICT token that is LOAD-BEARING, not DECORATION", %{
      comment: comment
    } do
      assert Regex.match?(~r/^\s*VERDICT: the border is LOAD-BEARING\./m, comment),
             "no line in the .chip-soft comment begins with the verdict token. " <>
               "Flipping it to DECORATION, or burying it mid-sentence, reds this. " <>
               "Comment reads:\n#{comment}"

      refute squish(comment) =~ "DECORATION",
             "the .chip-soft comment now says DECORATION somewhere. The measured " <>
               "verdict is LOAD-BEARING; re-measure all six tones before changing it."
    end

    test "states the disposition as NOT fixed, at line start", %{comment: comment} do
      assert Regex.match?(~r/^\s*DISPOSITION \([^)]*\): NOT fixed\./m, comment),
             "no `DISPOSITION (...): NOT fixed.` line. The next person to measure " <>
               "must find that neither Fix A nor Fix B was taken, and why. " <>
               "Comment reads:\n#{comment}"
    end

    test "names all six tones in ONE list, so the record cannot be narrowed", %{
      comment: comment
    } do
      flat = squish(comment)

      assert flat =~ "all six tones — neutral, info, success, warning, error, primary —",
             "the disposition no longer lists the six tones together. A record " <>
               "narrowed to a subset (say, warning only) describes a per-tone " <>
               "override, which the comment itself calls wrong by construction. " <>
               "Comment reads:\n#{comment}"

      assert flat =~ "per-tone override is wrong by construction"
    end

    test "records the shortfall as pre-existing, not introduced by 01a01a4a", %{
      comment: comment
    } do
      flat = squish(comment)
      assert flat =~ "pre-existing"
      assert flat =~ "01a01a4a"
    end

    test "each MUST NOT arm is a line-start bullet naming its mechanism", %{comment: comment} do
      assert Regex.match?(~r/^\s*- MUST NOT raise the border alpha\./m, comment),
             "no `- MUST NOT raise the border alpha.` bullet. Comment reads:\n#{comment}"

      assert Regex.match?(~r/^\s*- MUST NOT deepen the tint\./m, comment),
             "no `- MUST NOT deepen the tint.` bullet. Comment reads:\n#{comment}"

      assert Regex.match?(~r/^\s*- MUST NOT draw the border from `--chip-label`\./m, comment),
             "no `- MUST NOT draw the border from \`--chip-label\`.` bullet. " <>
               "Comment reads:\n#{comment}"
    end

    test "the alpha ceiling is stated as slot pairs for BOTH impossible light tones", %{
      comment: comment
    } do
      flat = squish(comment)

      # Two tones, not one outlier: either alone would invite "but it works on
      # the other five". Unrounded, as slot vs slot, never a hex.
      assert flat =~ "`.chip-primary` --chip-tint vs --color-base-100 = 1.78748833:1",
             "the primary ceiling pair (1.78748833:1 light) is missing. " <>
               "Comment reads:\n#{comment}"

      assert flat =~ "`.chip-warning` --chip-tint vs --color-base-100 = 2.21457697:1",
             "the warning ceiling pair (2.21457697:1 light) is missing. " <>
               "Comment reads:\n#{comment}"

      # Dark clears everywhere; the record must say so, or someone reopens this
      # with "it would have worked in dark".
      assert flat =~ "Dark clears on all six"
      assert flat =~ "light cannot be satisfied"
    end

    test "explains why no obligation attaches: non-interactive span, state in AA text", %{
      comment: comment
    } do
      flat = squish(comment)
      assert flat =~ "WCAG 1.4.11"
      assert flat =~ "the 3:1 obligation does not attach"
      assert flat =~ "non-interactive <span>"
      assert flat =~ "no phx-click, href, role or tabindex"
    end

    test "still carries the mis-picked pair, framed as superseded", %{comment: comment} do
      flat = squish(comment)
      assert flat =~ "1.12:1 / 2.12:1"
      assert flat =~ "superseded by the table above"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # Collapse every whitespace run to one space. A formatter rewrap moves line
  # breaks around; without this, a phrase match is a test of the line width.
  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp chip_soft_index(css) do
    case :binary.match(css, ".chip-soft {") do
      {at, _len} ->
        at

      :nomatch ->
        flunk("no `.chip-soft {` rule in #{@css_path} — the component this test guards is gone.")
    end
  end

  # The comment block immediately preceding `.chip-soft {`, and nothing else in
  # the file. Deliberately not a file-wide search.
  defp chip_soft_comment(css) do
    at = chip_soft_index(css)
    preamble = binary_part(css, 0, at)

    case :binary.matches(preamble, "/*") do
      [] ->
        flunk("no comment precedes `.chip-soft {` in #{@css_path}.")

      matches ->
        {start, _} = List.last(matches)

        preamble
        |> binary_part(start, byte_size(preamble) - start)
        |> String.trim()
    end
  end

  defp chip_soft_body(css) do
    at = chip_soft_index(css)
    rest = binary_part(css, at, byte_size(css) - at)

    case :binary.match(rest, "}") do
      {close, _} -> binary_part(rest, 0, close)
      :nomatch -> flunk("`.chip-soft {` is never closed in #{@css_path}.")
    end
  end
end
