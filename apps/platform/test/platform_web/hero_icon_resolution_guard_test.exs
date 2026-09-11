defmodule PlatformWeb.HeroIconResolutionGuardTest do
  @moduledoc """
  Corpus-wide ratchet (task 01a07486-7985-7001-87ce-277681791f52): every
  `hero-*` class used under `apps/platform/lib` must correspond to a real
  SVG in the icon set the Tailwind plugin actually resolves.

  A `hero-*` class that names a file Heroicons does not ship generates NO
  CSS. Tailwind's `matchComponents` simply never emits a rule for it, so
  the `<span class="hero-microphone-slash">` renders as an empty inline
  box: no glyph, no console warning, no compiler error, no failing
  assertion. Every test that checks for the class name still passes,
  because the class name is present in the markup. It just paints
  nothing. `hero-microphone-slash` shipped that way through every mute
  indicator in meetings, and the participant-rail tests were green the
  whole time.

  Heroicons is inconsistent about which negations it ships:
  `bell-slash` and `video-camera-slash` exist, `microphone-slash` and
  `camera-slash` do not. There will be a next one, which is why this is a
  ratchet and not a one-line fix.

  ## The resolution rule mirrors `assets/vendor/heroicons.js`

  The plugin reads TWO roots (the vendored Heroicons set, then our own
  `assets/icons`, local last so a same-named local file wins) and maps a
  suffix onto a subdirectory: bare -> `24/outline`, `-solid` ->
  `24/solid`, `-mini` -> `20/solid`, `-micro` -> `16/solid`. The Tailwind
  component key is `hero-` plus (basename + suffix), so `hero-X` resolves
  exactly when `X` is one of those keys.

  This test resolves against the SAME two roots, anchored the same way
  the plugin anchors them (relative to `assets/vendor/`, where
  `heroicons.js` lives). A guard that reads a different set from the
  plugin is worthless: it can go green while the class generates
  nothing, which is the exact defect being fixed. If `heroicons.js`
  gains, loses or re-anchors a root, this file must move with it.

  ## Scope and known-noise handling

  Every `.ex` and `.heex` file under `apps/platform/lib`. HEEx
  (`<%!-- --%>`) and HTML (`<!-- -->`) comments are stripped first, as in
  `inline_onclick_guard_test.exs`, because comments routinely describe
  the classes below them in prose.

  `@doc` and `@moduledoc` are deliberately NOT stripped. A docstring can
  hold a real `~H` example, and a stripper that eats docstrings blinds
  the guard. The cost is that English prose containing the literal
  "hero-icon" trips it; that noise is handled by `@allowed`, one entry
  per phrase, each naming its file. The noisy failure mode is the
  correct one here: a blind guard is the defect.
  """
  use ExUnit.Case, async: true

  # test/platform_web -> apps/platform/lib
  @lib_root Path.expand("../../lib", __DIR__)

  # `assets/vendor/heroicons.js` builds its roots as
  # `path.join(__dirname, "../../deps/heroicons/optimized")` and
  # `path.join(__dirname, "../icons")`. Anchoring off the plugin's own
  # directory rather than off this test keeps the two expressions
  # literally comparable.
  @plugin_dir Path.expand("../../assets/vendor", __DIR__)
  @icon_roots [
    Path.expand("../../deps/heroicons/optimized", @plugin_dir),
    Path.expand("../icons", @plugin_dir)
  ]

  # Suffix -> subdirectory, verbatim from the plugin's `icons` list.
  @icon_subdirs [
    {"", "24/outline"},
    {"-solid", "24/solid"},
    {"-mini", "20/solid"},
    {"-micro", "16/solid"}
  ]

  # Tokens that look like a `hero-*` class but are English. Each entry
  # MUST name the file and the reason.
  #
  #   "hero-icon":  the phrase "hero-icon slug" / "hero-icon glyph" in
  #                  docstrings: lib/platform/roles/role.ex and
  #                  lib/platform_web/components/meetings/intents_collapse.ex
  #                  (twice). Heroicons ships no `icon.svg`.
  #   "hero-icons": "so hero-icons and LiveView ..." in a docstring:
  #                  lib/platform_web/components/layouts.ex. Heroicons
  #                  ships no `icons.svg`.
  #
  # Anything added here must carry the same: file, phrase, reason. If the
  # token is a real class rather than prose, the fix is an SVG in
  # `assets/icons`, not a line in this list.
  @allowed ["hero-icon", "hero-icons"]

  # `(?<![-\w])` stops `superhero-icon` and `data-hero-x` from matching.
  @hero_token ~r/(?<![-\w])(hero-[a-z0-9]+(?:-[a-z0-9]+)*)/

  defp sources do
    for path <- Path.wildcard(Path.join(@lib_root, "**/*.{ex,heex}")),
        do: {relative(path), File.read!(path)}
  end

  defp relative(path), do: Path.relative_to(path, Path.expand("../..", @lib_root))

  defp strip_comments(source) do
    source
    |> String.replace(~r/<%!--.*?--%>/s, "")
    |> String.replace(~r/<!--.*?-->/s, "")
  end

  defp comments(source) do
    ~r/<%!--.*?--%>|<!--.*?-->/s
    |> Regex.scan(source)
    |> Enum.map(&hd/1)
  end

  # The Tailwind component keys the plugin would generate, as a set.
  # Later roots overwrite earlier ones in the plugin; in a set that
  # distinction does not matter, since we only ask whether a key exists.
  #
  # Divergence from the plugin, deliberate: non-`.svg` entries are
  # skipped. The plugin would turn a stray `.DS_Store` into a key. That
  # can only ever make this guard STRICTER than the plugin (red when the
  # plugin is green), never blinder, which is the safe direction.
  defp resolvable_keys do
    for root <- @icon_roots,
        {suffix, dir} <- @icon_subdirs,
        subdir = Path.join(root, dir),
        File.dir?(subdir),
        file <- File.ls!(subdir),
        String.ends_with?(file, ".svg"),
        into: MapSet.new(),
        do: Path.basename(file, ".svg") <> suffix
  end

  # {token, path} for every `hero-*` token in the comment-stripped corpus.
  defp scanned_tokens do
    for {path, source} <- sources(),
        [_, token] <- Regex.scan(@hero_token, strip_comments(source)),
        do: {token, path}
  end

  defp distinct_tokens, do: scanned_tokens() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  describe "the icon set" do
    test "positive control: both roots are read and the set is not empty" do
      keys = resolvable_keys()

      # Measured 1289 on this branch head: 324 + 324 + 324 + 316 vendored,
      # plus the one local `24/outline/microphone-slash.svg`. The floor is
      # ~three-quarters of that: low enough not to churn as Heroicons
      # grows, high enough that a missing or misanchored vendored root
      # trips it instead of silently allowing every token through.
      assert MapSet.size(keys) > 1000,
             "resolved only #{MapSet.size(keys)} icon keys. A root is missing or misanchored, " <>
               "so this guard would pass classes that generate no CSS"

      # Vendored root.
      assert MapSet.member?(keys, "video-camera-slash")
      assert MapSet.member?(keys, "bars-3-mini")
      assert MapSet.member?(keys, "check-circle-solid")

      # Local root (`assets/icons`). If this fails the second root is not
      # being read, and `hero-microphone-slash` is generating nothing
      # again: the original defect.
      assert MapSet.member?(keys, "microphone-slash"),
             "the local `assets/icons` root is not being resolved"
    end

    test "the suffix mapping matches the plugin" do
      keys = resolvable_keys()

      # A bare name comes from 24/outline; `-solid` from 24/solid. If the
      # mapping were inverted these two would still both be present, so
      # check a file that exists at one size and not the other.
      assert File.exists?(Path.join(hd(@icon_roots), "24/outline/microphone.svg"))
      assert MapSet.member?(keys, "microphone")
      assert MapSet.member?(keys, "microphone-solid")
      assert MapSet.member?(keys, "microphone-mini")
      assert MapSet.member?(keys, "microphone-micro")
    end
  end

  describe "the scanner itself" do
    test "positive control: comment stripping does not gut the corpus" do
      tokens = distinct_tokens()

      # Measured 127 distinct `hero-*` tokens under `apps/platform/lib`
      # after comment stripping, at c77afb81 (this branch head) on
      # 2026-09-06. The floor of 100 is deliberately below that: an empty
      # scan passes every offender check vacuously, and a greedy `.*`
      # instead of `.*?` in strip_comments/1 produces exactly an empty
      # scan.
      assert length(tokens) >= 100,
             "scanner found only #{length(tokens)} distinct hero-* tokens. " <>
               "Comment stripping likely ate the corpus"

      assert "hero-microphone-slash" in tokens
      assert "hero-video-camera-slash" in tokens
    end

    test "positive control: a comment is stripped without skipping its file" do
      # A witness is a file where some `hero-*` token appears BOTH inside a
      # HEEx/HTML comment AND in the code that survives stripping. Located by
      # content, never by path, line number or a fixed token: the original
      # witness was `hero-microphone-slash` in video_tile.ex (a HEEx comment
      # above a `class=`), and FE-4 (#939) moved that class into a `defp`
      # under an Elixir `#` comment, which is neither. A control pinned to one
      # token dies on the next refactor; a control over every token does not.
      # Measured 10 witness files at this head (stage 4, 2026-09-11):
      # participant_rail.ex, intents_collapse.ex, conversation.ex, rail.ex,
      # canvas_live.html.heex, meeting_live.html.heex and four more.
      #
      # If strip_comments/1 removed the whole file, or skipped any file
      # containing a comment, there would be no such file left.
      witnesses =
        for {path, source} <- sources(),
            stripped = strip_comments(source),
            in_comments =
              source
              |> comments()
              |> Enum.flat_map(&Regex.scan(@hero_token, &1))
              |> Enum.map(fn [_, token] -> token end)
              |> Enum.uniq(),
            token <- in_comments,
            Regex.match?(~r/(?<![-\w])#{Regex.escape(token)}(?![-\w])/, stripped),
            do: {path, token, source, stripped}

      assert witnesses != [],
             "no file carries a `hero-*` token in BOTH a comment and its code; " <>
               "this control can no longer prove the stripper is surgical. Re-point it at a " <>
               "file that does, do not delete it"

      # Floor well under the measured 10, so a corpus that lost most witnesses
      # to refactors still fails loudly rather than trivially passing on one.
      assert length(Enum.uniq_by(witnesses, &elem(&1, 0))) >= 3

      for {path, token, source, stripped} <- witnesses do
        pattern = ~r/(?<![-\w])#{Regex.escape(token)}(?![-\w])/
        raw = Regex.scan(pattern, source) |> length()
        kept = Regex.scan(pattern, stripped) |> length()

        assert kept > 0, "#{path}: the whole file was stripped, not just its comments"
        assert kept < raw, "#{path}: the comment mention of #{token} survived stripping"
      end
    end

    test "the detector fires on a synthetic unresolvable token" do
      source = ~S|<span class="hero-not-a-real-icon size-4" />|

      assert [[_, "hero-not-a-real-icon"]] = Regex.scan(@hero_token, strip_comments(source))
      refute MapSet.member?(resolvable_keys(), "not-a-real-icon")
    end

    test "token boundary: superhero- and data-hero- are not matches" do
      refute Regex.match?(@hero_token, "superhero-icon")
      refute Regex.match?(@hero_token, "data-hero-tag")
      assert Regex.match?(@hero_token, ~S|class="hero-bell"|)
    end

    test "prose in a comment is stripped, but the class below it survives" do
      source = ~S"""
      <%!-- Mute indicator: hero-microphone-slash in the corner. --%>
      <span class="hero-microphone-slash block size-3.5" />
      <!-- hero-not-a-real-icon is only described here -->
      """

      tokens =
        Regex.scan(@hero_token, strip_comments(source))
        |> Enum.map(fn [_, token] -> token end)

      assert tokens == ["hero-microphone-slash"]
    end
  end

  describe "hero-* corpus" do
    test "every hero-* class used in lib resolves to a real icon file" do
      keys = resolvable_keys()

      offenders =
        scanned_tokens()
        |> Enum.reject(fn {token, _path} -> token in @allowed end)
        |> Enum.reject(fn {token, _path} ->
          MapSet.member?(keys, String.replace_prefix(token, "hero-", ""))
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.map(fn {token, paths} -> {token, Enum.uniq(paths)} end)
        |> Enum.sort()

      assert offenders == [], """
      #{length(offenders)} hero-* class(es) name an icon that does not exist in either root:

      #{Enum.map_join(offenders, "\n", fn {token, paths} -> "  #{token}\n#{Enum.map_join(paths, "\n", &"    #{&1}")}" end)}

      Tailwind emits NO rule for these, so they render as empty boxes: no
      glyph, no warning, no failing assertion. Heroicons is inconsistent
      about which negations it ships (`bell-slash` yes, `microphone-slash`
      no), so a plausible name is not evidence the file exists.

      Roots searched (in plugin order, local last):
      #{Enum.map_join(@icon_roots, "\n", &"    #{&1}")}

      Fix by adding the SVG under `apps/platform/assets/icons/<size>/<style>/`
      (NOT under `deps/`, which is gitignored), or by using a class that
      resolves. Add to @allowed in this file ONLY if the token is English
      prose rather than a class, and say which file and phrase.
      """
    end

    test "the allowlist covers only English prose, not missing icons" do
      # Guards the guard: if someone parks a real missing icon here, this
      # fails. Each allowed token must be absent from every `class=`
      # attribute in the corpus.
      misuse =
        for {path, source} <- sources(),
            stripped = strip_comments(source),
            token <- @allowed,
            Regex.match?(
              ~r/class=[^>]*"[^"]*(?<![-\w])#{Regex.escape(token)}(?![-\w])/,
              stripped
            ),
            do: {token, path}

      assert misuse == [],
             "allowlisted token(s) used as a real class: #{inspect(misuse)}. " <>
               "These generate no CSS; ship the SVG instead of allowlisting"
    end

    test "hero-camera-slash is not used anywhere, so the guard must not fail on it" do
      # Heroicons ships no `camera-slash.svg` at any size, exactly like
      # `microphone-slash`. It is absent from the corpus today, so this
      # guard is silent about it. Asserted so nobody later "fixes" a
      # failure that was never there, and so that the day someone DOES
      # write `hero-camera-slash`, this test and the corpus test both
      # point at it.
      refute MapSet.member?(resolvable_keys(), "camera-slash"),
             "Heroicons now ships camera-slash: delete this test's premise, not the guard"

      refute "hero-camera-slash" in distinct_tokens(),
             "hero-camera-slash is now used in lib and generates no CSS; add the SVG under " <>
               "apps/platform/assets/icons/24/outline/"
    end
  end
end
