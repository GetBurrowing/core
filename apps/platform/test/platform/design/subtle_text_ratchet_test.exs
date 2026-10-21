defmodule Platform.Design.SubtleTextRatchetTest do
  @moduledoc """
  The secondary-text floor (task 01a1557a stage 5 r2, rung 2's ratchet;
  widened by task 01a15902 stages 1 and 5). Text has two colour levels, body
  and `text-subtle` (direction canvas 01a15902-e3b2); this file makes that
  permanent.

    * ZERO FLOOR (task 01a15902 stage 5). Any base-content text utility at a
      strength below 55%, or at 55% or 60%, fails, with any variant prefix
      (`hover:`, `placeholder:`, `group-hover:`), and so does every arbitrary
      strength (`text-base-content/[0.4]`) and every arbitrary colour-mix text
      colour (`text-[color-mix(...)]`), whose strength this scanner cannot read.
      Each offence is printed as file:line. Secondary text paints
      `text-subtle`, which each theme block declares at its own AA-held
      strength (55%, 57% in Burrow sand light). The only exempt colours are
      `text-disabled` and `text-decorative`, and
      `text_exemption_guard_test.exs` polices where those may go.
    * FROZEN 65-90% (canvas Rulings 2). These clear AA, so they carry no
      accessibility risk, but they are a consistency debt that follow-up task
      01a15907 migrates. Each bucket has an exact ceiling, ADR 0050's ratchet:
      over it fails (the bucket grew), and under it fails with "lower the
      ceiling to N", so headroom never accumulates.
    * NO FAINT. The retired faint tier (`--faint`, `--color-faint`,
      `text-faint`, task 01a15902 stage 2) is refused in `apps/platform/lib`,
      `assets/css` and `assets/js`.
    * POSITIVE CONTROL. The floor scanner runs over fixture strings that must
      each be flagged, and over a clean fixture that must not be. A scanner
      that cannot fire fails the suite before its silence is trusted.

  Scanned: the five secondary-text grep paths (`apps/platform/lib`,
  `apps/platform/assets/js`, `apps/social/lib`, `apps/game_stream/lib`,
  `apps/game_stream/assets/js`) plus `apps/platform/assets/css` with its
  comments stripped, so an `@apply` is a use and prose about a utility is not.

    * CSS TEXT COLOURS (task 01a15902 stage 6). A stylesheet `color:` that
      mixes base-content with transparent at 60% or less fails too; see the
      test for its one measured exemption.
    * UTILITY TYPE (task 01a15902 stage 6). text-subtle paired with an
      arbitrary size under 12px is frozen at an exact ceiling (all
      pre-existing), and the stage-6 tier collapses are pinned at text-xs.

  NOT covered here, a bounded residual reported by task 01a15902 stage 5 (in
  its commit and the execution space) and not migrated: `opacity-N` on text
  elements, and literal CSS colours on text (`--text-muted: #666`-style
  custom properties, hex and rgb `color:` declarations, and opaque
  base-content mixes into another token).

  Named mutations, task 01a15902 stage 5: (a) `text-base-content/30` added in
  apps/social; (b) `group-hover:text-base-content/55` added; (c) the floor
  regex gutted to match nothing (the positive control goes red); (d)
  `--faint: #000` added to a token block. Each turns this file red.
  """
  use ExUnit.Case, async: true

  @app Path.expand("../../..", __DIR__)
  @root Path.expand("../..", @app)

  # 65-90%: frozen at their counts. Pinned at task 01a15902 stage 1 on
  # 952579d1 (70 => 235, 80 => 35), re-pinned at stage 5 after the rebase onto
  # feat/redesign b1e35b5c, where rung 3 (PR #1298) moved two 70% and two 80%
  # sites. Re-pinned again when rung 4 (task 01a1557a-7a71) rebased onto
  # feat/redesign 493ad2ba: retiring Activity deleted four 70% and two 80%
  # sites (70 => 229, 80 => 31).
  @ceilings %{65 => 4, 70 => 229, 75 => 1, 80 => 31, 90 => 2}

  @buckets Enum.sort(Map.keys(@ceilings))

  # The floor: a base-content text utility at a strength below 55%, or at 55
  # or 60, with any variant chain; any arbitrary strength; any arbitrary
  # colour-mix text colour.
  @floor ~r/(?<![\w-])(?:[a-z0-9-]+:)*text-(?:base-content\/(?:[0-4]?\d|5\d|60|\[[^\]]*\])(?![0-9])|\[color-mix\([^\]]*\])/

  @faint ~r/--faint\b|--color-faint\b|(?<![\w-])(?:[a-z0-9-]+:)*text-faint(?![\w-])/

  @code_dirs [
    {"apps/platform/lib", "**/*.{ex,exs,heex,eex}"},
    {"apps/platform/assets/js", "**/*.{js,mjs,ts}"},
    {"apps/social/lib", "**/*.{ex,exs,heex,eex}"},
    {"apps/game_stream/lib", "**/*.{ex,exs,heex,eex}"},
    {"apps/game_stream/assets/js", "**/*.{js,mjs,ts}"}
  ]

  defp sources do
    code =
      for {dir, glob} <- @code_dirs,
          path <- Path.wildcard(Path.join([@root, dir, glob])),
          do: {path, File.read!(path)}

    css =
      for path <- Path.wildcard(Path.join(@app, "assets/css/**/*.css")),
          do: {path, Regex.replace(~r{/\*.*?\*/}s, File.read!(path), "")}

    code ++ css
  end

  @doc false
  # [{line, match}] for every use the regex finds in `text`.
  def offenses(regex, text) do
    for [{at, len}] <- Regex.scan(regex, text, return: :index) do
      {text |> binary_part(0, at) |> String.split("\n") |> length(), binary_part(text, at, len)}
    end
  end

  defp report(hits) do
    Enum.map_join(hits, "\n  ", fn {path, line, match} ->
      "#{Path.relative_to(path, @root)}:#{line}: #{match}"
    end)
  end

  defp bucket_regex(n), do: Regex.compile!("text-base-content/#{n}(?![0-9])")

  defp total(sources, regex),
    do: sources |> Enum.map(fn {_, t} -> length(Regex.scan(regex, t)) end) |> Enum.sum()

  setup_all do
    {:ok, sources: sources()}
  end

  test "the scan reads the tree it claims to (anti-vacuity)", %{sources: files} do
    count = fn fragment -> Enum.count(files, fn {p, _} -> String.contains?(p, fragment) end) end

    assert count.("/apps/platform/lib/") > 500
    assert count.("/apps/platform/assets/js/") > 50
    assert count.("/apps/social/lib/") > 20
    assert count.("/apps/game_stream/lib/") > 10
    assert count.("/apps/game_stream/assets/js/") > 0
    assert Enum.any?(files, fn {p, _} -> String.ends_with?(p, "assets/css/app.css") end)

    # The replacement is really in use, so a zero floor is a migration and
    # not an empty scan.
    assert total(files, ~r/\btext-subtle\b/) > 800
  end

  describe "positive control: the floor scanner fires" do
    for fixture <- [
          ~s(<p class="text-base-content/40">x</p>),
          ~s(class="hover:text-base-content/60"),
          ~s(class="placeholder:text-base-content/50"),
          ~s(class="text-base-content/[0.5]"),
          ~s(class="group-hover:text-base-content/55"),
          ~s(class="text-base-content/5"),
          ~s|class="text-[color-mix(in_oklab,var(--color-base-content)_40%,transparent)]"|,
          ~s|el("span", "text-xs text-base-content/20")|
        ] do
      @fixture fixture
      test "flags #{inspect(fixture)}" do
        assert [_ | _] = offenses(@floor, @fixture)
      end
    end

    test "flags text-faint and --faint" do
      assert [_] = offenses(@faint, ~s(class="placeholder:text-faint"))
      assert [_] = offenses(@faint, "  --faint: #000;")
      assert length(offenses(@faint, "  --color-faint: var(--faint);")) == 2
    end

    test "passes a clean fixture" do
      clean = """
      <p class="text-subtle hover:text-base-content text-base-content/70">
        <span class="text-base-content/65 bg-base-content/40 border-base-content/50">x</span>
        <span class="disabled:text-disabled text-decorative text-base-content/600">y</span>
      </p>
      """

      assert offenses(@floor, clean) == []
      assert offenses(@faint, clean) == []
    end
  end

  test "no base-content text below subtle, at 55% or at 60%, in any form", %{sources: files} do
    found = for {path, text} <- files, {line, m} <- offenses(@floor, text), do: {path, line, m}

    assert found == [],
           "text below the subtle floor (task 01a15902): paint text-subtle, or body " <>
             "text, or text-disabled / text-decorative where the element is exempt. " <>
             "Found:\n  " <> report(found)
  end

  test "the retired faint tier stays retired in lib, assets/css and assets/js" do
    files =
      for glob <- [
            "lib/**/*.{ex,exs,heex,eex}",
            "assets/css/**/*.css",
            "assets/js/**/*.{js,mjs,ts}"
          ],
          path <- Path.wildcard(Path.join(@app, glob)),
          do: {path, File.read!(path)}

    assert length(files) > 600

    found = for {path, text} <- files, {line, m} <- offenses(@faint, text), do: {path, line, m}

    assert found == [],
           "the faint tier is retired (task 01a15902 stage 2): placeholders and " <>
             "quiet text paint text-subtle. Found:\n  " <> report(found)
  end

  # Utility type (direction canvas 01a15902-e3b2, "Type"): metadata is 12px
  # regular in text-subtle, and a tier kept by size drops to text-xs, never
  # below. Task 01a15902 stage 6 moved its two tier collapses from 11px to
  # text-xs; they are pinned here. Every other class string pairing
  # text-subtle with an arbitrary size under 12px is pre-existing: the size
  # was already there when this task changed the colour, and 14 such strings
  # were on feat/redesign b1e35b5c before this task. That set is frozen at an
  # exact ceiling (ADR 0050). A new one fails, and a migrated one fails with
  # "lower the ceiling".
  @small_subtle_ceiling 112
  @small_size ~r/(?<![\w-])text-\[(?:\d|1[01])(?:\.\d+)?px\]|(?<![\w-])text-\[0\.(?:[0-6]\d*|7[0-4]\d*)rem\]/
  @tier_collapses [
    {"apps/platform/lib/platform_web/live/control_center/roles_panel.ex", ">unassigned<"},
    {"apps/platform/lib/platform_web/live/external_recovery_live.html.heex",
     "Signed in {relative_time"}
  ]

  defp small_subtle_strings(files) do
    for {path, text} <- files,
        [string] <- Regex.scan(~r/"([^"\n]*)"/, text, capture: :all_but_first),
        Regex.match?(~r/(?<![\w-])text-subtle(?![\w-])/, string),
        Regex.match?(@small_size, string),
        do: {path, string}
  end

  test "the stage-6 tier collapses are 12px subtle, not a smaller size" do
    for {rel, marker} <- @tier_collapses do
      source = File.read!(Path.join(@root, rel))
      [before | _] = String.split(source, marker, parts: 2)
      assert before != source, "#{rel}: the marker #{inspect(marker)} is gone"

      # The class of the element that holds the marker.
      [_, class] = Regex.run(~r/class="([^"]*)"[^<]*$/, before)

      assert "text-xs" in String.split(class) and "text-subtle" in String.split(class),
             "#{rel}: the tier collapse holding #{inspect(marker)} is #{inspect(class)}; " <>
               "the canvas contract is 12px (text-xs) in text-subtle"

      refute Regex.match?(@small_size, class),
             "#{rel}: #{inspect(class)} drops below 12px; keep the tier by position or weight"
    end
  end

  test "text-subtle paired with a size under 12px stays at its ceiling of #{@small_subtle_ceiling}",
       %{sources: files} do
    found = small_subtle_strings(files)
    count = length(found)

    assert count <= @small_subtle_ceiling,
           "#{count} class strings pair text-subtle with a size under 12px (ceiling " <>
             "#{@small_subtle_ceiling}). Utility type is 12px (text-xs); keep a tier by " <>
             "position or weight, never by a smaller size."

    assert count >= @small_subtle_ceiling,
           "#{count} class strings pair text-subtle with a size under 12px: lower the " <>
             "ceiling to #{count}."
  end

  test "the small-size scanner fires on its fixtures" do
    assert [_] = small_subtle_strings([{"f", ~s(<span class="text-[11px] text-subtle">)}])
    assert [_] = small_subtle_strings([{"f", ~s(<p class="text-subtle text-[0.65rem]">)}])
    assert [] = small_subtle_strings([{"f", ~s(<span class="text-xs text-subtle">)}])
    assert [] = small_subtle_strings([{"f", ~s(<span class="text-[13px] text-subtle">)}])
  end

  # CSS text colours (task 01a15902 stage 6). The utility scanner above
  # cannot see a `color:` declared in a stylesheet. Here: any `color:`
  # property (not a custom property, not background-/border-color) whose
  # value is base-content mixed with TRANSPARENT at 60% or less is the same
  # translucent secondary text the zero floor refuses, so it fails.
  # Opaque mixes (base-content into another token, e.g. the reaction-picker
  # and message-context labels) are not translucency and are measured by
  # their own guards; they are out of this rule's scope.
  #
  # One exemption: the canvas-search partial-index line, whose dark colour
  # canvas_search_snippet_contrast_test measures on the drawer box it
  # actually paints on (and requires to be a token-with-transparent mix).
  @css_text_floor ~r/(?<![\w-])color\s*:\s*color-mix\(\s*in\s+\w+\s*,\s*var\(--color-base-content\)\s*(\d+(?:\.\d+)?)%\s*,\s*transparent\s*\)/
  @css_text_exempt ["canvas-search-indexing-state"]

  defp css_text_offenses(css) do
    for rule <- Platform.Design.CssRules.rules(css),
        not Enum.any?(@css_text_exempt, &String.contains?(rule.selector, &1)),
        [_, pct] <- Regex.scan(@css_text_floor, rule.body),
        elem(Float.parse(pct), 0) <= 60,
        do: "#{rule.selector} { color: base-content #{pct}% over transparent }"
  end

  test "no stylesheet paints text with base-content at 60% or less over transparent" do
    found =
      for path <- Path.wildcard(Path.join(@app, "assets/css/**/*.css")),
          offence <- css_text_offenses(File.read!(path)),
          do: "#{Path.relative_to(path, @root)}: #{offence}"

    assert found == [],
           "a stylesheet paints translucent secondary text below the floor; use " <>
             "color: var(--color-subtle) (task 01a15902 stage 6):\n  " <>
             Enum.join(found, "\n  ")
  end

  test "the CSS text-colour scanner fires on its fixtures and spares the rest" do
    fire = """
    .a { color: color-mix(in oklab, var(--color-base-content) 50%, transparent); }
    .b { color:color-mix(in oklch, var(--color-base-content) 60%, transparent) }
    """

    spare = """
    .c { color: color-mix(in oklab, var(--color-base-content) 70%, transparent); }
    .d { background-color: color-mix(in oklab, var(--color-base-content) 18%, transparent); }
    .e { color: color-mix(in oklab, var(--color-base-content) 50%, var(--color-neutral)); }
    .f { --x: color-mix(in oklab, var(--color-base-content) 40%, transparent); }
    [data-role="canvas-search-indexing-state"] { color: color-mix(in oklch, var(--color-base-content) 55%, transparent); }
    """

    assert length(css_text_offenses(fire)) == 2
    assert css_text_offenses(spare) == []
  end

  for n <- @buckets do
    @bucket n

    test "the #{n}% base-content text utility sits exactly at its ceiling of #{@ceilings[n]}",
         %{sources: files} do
      ceiling = Map.fetch!(@ceilings, @bucket)
      count = total(files, bucket_regex(@bucket))

      assert count <= ceiling,
             "text-base-content/#{@bucket} rose to #{count} (ceiling #{ceiling}). Prefer " <>
               "text-subtle or body text; raising the ceiling needs a reason in the " <>
               "commit (ADR 0050)."

      assert count >= ceiling,
             "text-base-content/#{@bucket} fell to #{count} (ceiling #{ceiling}): " <>
               "lower the ceiling to #{count} in #{Path.relative_to_cwd(__ENV__.file)}."
    end
  end
end
