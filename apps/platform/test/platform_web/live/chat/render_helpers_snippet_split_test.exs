defmodule PlatformWeb.ChatLive.RenderHelpersSnippetSplitTest do
  @moduledoc """
  `RenderHelpers.split_marked_snippet/1` — task `01a077e6` stage 1.

  ## WHAT THIS FILE CAN AND CANNOT PROVE

  It pins WHICH CHARACTERS LAND IN WHICH RUN, and nothing else. It says nothing
  about where those runs end up on screen, because no test in this repo's
  Elixir suite does layout. That is the whole reason the defect this stage
  fixes existed: nine passing LiveView tests covered the snippet and a real
  browser at 375px was what caught the match being clipped off the right edge.
  A green run here is NOT evidence the row renders correctly. The
  discriminating check is the browser-geometry spec in stage 2.

  What a wrong partition would look like, and therefore what these cases are
  actually worth: a splitter that protected EVERY mark instead of the first
  would make the row's unshrinkable width the sum of all of them and put the
  overflow back at a slightly narrower viewport, and a splitter that dropped
  the runs' own spacing would silently reflow the line. Both are visible here
  as character-level differences and invisible to a presence assertion.
  """

  use ExUnit.Case, async: true

  alias PlatformWeb.ChatLive.RenderHelpers

  # Runs come back as `Phoenix.HTML.safe()` or nil. Comparing the rendered
  # string is the point: the escaping is half of what is under test, so a
  # helper that unwrapped to raw text would hide exactly the failure that
  # matters.
  defp render(nil), do: nil
  defp render(safe), do: Phoenix.HTML.safe_to_string(safe)

  defp split(text) do
    {leading, match, trailing} = RenderHelpers.split_marked_snippet(text)
    {render(leading), render(match), render(trailing)}
  end

  describe "a fragment with one mark" do
    test "splits into leading context, the match, and trailing context" do
      # The shape `Chat.ellipsised_headline/2` actually produces: a `ts_headline`
      # fragment with the literal "… " prefix and " …" suffix around it.
      assert split("… the rollout requires <mark>zorbling</mark> before anyone sees it …") ==
               {"… the rollout requires ", "zorbling", " before anyone sees it …"}
    end

    test "keeps the inner spacing on the runs rather than trimming it inward" do
      # The space before the match belongs to the leading run and the space
      # after it to the trailing run. Trimming them here would move a
      # rendering decision into the splitter, and the row's spacing is set by
      # the flex gap.
      {leading, _match, trailing} = split("a b <mark>c</mark> d e")

      assert String.ends_with?(leading, " ")
      assert String.starts_with?(trailing, " ")
    end
  end

  describe "escaping" do
    test "every run goes through the same escape-then-re-enable path" do
      # The body is user-written. Markup in the surrounding text is escaped in
      # ALL THREE runs, not only the one that happens to be rendered first.
      assert split("<b>x</b> & y <mark>hit</mark> <script>z</script> & w") ==
               {"&lt;b&gt;x&lt;/b&gt; &amp; y ", "hit", " &lt;script&gt;z&lt;/script&gt; &amp; w"}
    end

    test "a quote or apostrophe in the match itself is escaped" do
      assert {_, ~s(a&#39;b &quot;c&quot;), _} = split("x <mark>a'b \"c\"</mark> y")
    end
  end

  describe "more than one mark in the fragment" do
    test "protects the FIRST mark and leaves the rest inside the trailing run" do
      # `MaxFragments=1` bounds fragments, not marks: a multi-word query marks
      # each lexeme and a repeated term marks each occurrence. Only the first
      # is pulled out to be held at `shrink-0`; the later ones stay marked and
      # ride inside the run that truncates.
      assert split("a <mark>one</mark> b <mark>two</mark> c <mark>three</mark> d") ==
               {"a ", "one", " b <mark>two</mark> c <mark>three</mark> d"}
    end

    test "the later marks are real markup in the trailing run, not escaped text" do
      {_leading, _match, trailing} = split("a <mark>one</mark> b <mark>two</mark>")

      assert trailing =~ "<mark>two</mark>"
      refute trailing =~ "&lt;mark&gt;"
    end
  end

  describe "degenerate positions" do
    test "a match at the very start has no leading run" do
      assert split("<mark>hit</mark> and the rest") == {nil, "hit", " and the rest"}
    end

    test "a match at the very end has no trailing run" do
      assert split("all the rest and <mark>hit</mark>") == {"all the rest and ", "hit", nil}
    end

    test "a whitespace-only run counts as absent" do
      # It would render as a zero-width box that still takes a flex gap on each
      # side, which reads as a stray indent next to the match.
      assert split(" <mark>hit</mark> ") == {nil, "hit", nil}
    end

    test "a match that is the whole fragment has neither context run" do
      assert split("<mark>hit</mark>") == {nil, "hit", nil}
    end
  end

  describe "fragments with no usable mark" do
    test "no mark at all returns a nil match, which is the caller's fallback signal" do
      assert split("… nothing marked in here …") == {nil, nil, nil}
    end

    test "an unterminated opening tag does not invent a partition" do
      # Better to fall back to the single-span render than to protect a
      # fragment whose end nobody declared.
      assert split("a <mark>b with no close") == {nil, nil, nil}
    end

    test "a stray closing tag with no opener is not a partition either" do
      assert split("a b</mark> c") == {nil, nil, nil}
    end

    test "the empty string" do
      assert split("") == {nil, nil, nil}
    end
  end
end
