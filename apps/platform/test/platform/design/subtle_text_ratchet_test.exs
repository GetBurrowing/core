defmodule Platform.Design.SubtleTextRatchetTest do
  @moduledoc """
  The secondary-text floor (task 01a1557a stage 5 r2, rung 2's ratchet;
  widened by task 01a15902 stages 1 and 5, and by task 01a15907 stage 5).
  Text has two colour levels, body and `text-subtle` (direction canvas
  01a15902-e3b2); this file makes that permanent.

    * ZERO AT EVERY STRENGTH (task 01a15907). Any base-content text utility
      with a strength modifier fails: `text-base-content/N` for any N from 0
      to 100 (decimals included), with any variant chain (`hover:`,
      `group-hover:`, `placeholder:`, `focus:`, `aria-selected:`...), every
      arbitrary strength (`text-base-content/[0.4]`) and every arbitrary
      colour-mix text colour (`text-[color-mix(...)]`), whose strength this
      scanner cannot read. Body is the bare `text-base-content`.
      Deliberately wider than the strengths that were in use (55-90): a list
      would let `/85` or `/95` through, and once task 01a15907 migrated the
      last 65-90% site no strength other than 100% had a use.
      Each offence is printed as file:line. Secondary text paints
      `text-subtle`, which each theme block declares at its own AA-held
      strength (55%, 57% in Burrow sand light). The only exempt colours are
      `text-disabled` and `text-decorative`, and
      `text_exemption_guard_test.exs` polices where those may go.
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

    * STYLESHEET TEXT COLOURS (task 01a15902 stage 6; every strength since
      task 01a15907 stage 5). In every stylesheet under assets/css, comments
      stripped, a `color` / `fill` / `stroke` declaration, or a custom
      property used as text, that mixes base-content below 100% into
      anything fails. The only base-content mixes below 100% allowed are the
      definitions of the slot tokens themselves (`--subtle`, `--disabled`,
      `--decorative` and their `--color-` names), matched by name; see the
      test for the exact scope.
    * UTILITY TYPE (task 01a15902 stage 6). text-subtle paired with an
      arbitrary size under 12px is frozen at an exact ceiling (all
      pre-existing), and the stage-6 tier collapses are pinned at text-xs.

  NOT covered here, a bounded residual reported by task 01a15902 stage 5 (in
  its commit and the execution space) and not migrated: `opacity-N` on text
  elements, and literal CSS colours on text (`--text-muted: #666`-style
  custom properties, hex and rgb `color:` declarations). Opaque base-content
  mixes into another token ARE covered since task 01a15907 stage 5. Inline
  `style=` colours and JS-set colours are not scanned; task 01a15907 stage 5
  found none that mix base-content.

  Named mutations, task 01a15902 stage 5: (a) `text-base-content/30` added in
  apps/social; (b) `group-hover:text-base-content/55` added; (c) the floor
  regex gutted to match nothing (the positive control goes red); (d)
  `--faint: #000` added to a token block. Task 01a15907 stage 5: (a)
  `text-base-content/70` re-added in apps/social's social_live.ex; (b)
  `hover:text-base-content/80` re-added in call_shell.ex; (c) the floor
  regex emptied so it matches nothing; (d) `text-base-content/85` added, the
  widening; (e) base-content 70% over transparent put back on
  `.code-block-header`; (f) base-content 50% into neutral put back on
  `.message-context-label`. Each turns this file red.
  """
  use ExUnit.Case, async: true

  @app Path.expand("../../..", __DIR__)
  @root Path.expand("../..", @app)

  # The floor: a base-content text utility at ANY strength 0-100 (decimals
  # too), with any variant chain; any arbitrary strength; any arbitrary
  # colour-mix text colour. `/600`-style numbers are not strengths and stay
  # clean (the trailing lookahead refuses a longer number).
  @floor ~r/(?<![\w-])(?:[a-z0-9-]+:)*text-(?:base-content\/(?:(?:100|\d{1,2})(?:\.\d+)?|\[[^\]]*\])(?![0-9.])|\[color-mix\([^\]]*\])/

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
          ~s|el("span", "text-xs text-base-content/20")|,
          # Task 01a15907 stage 5: every strength, not only below 61.
          ~s(<dt class="text-base-content/70">Voice notes</dt>),
          ~s(class="text-base-content/65"),
          ~s(class="text-base-content/75"),
          ~s(class="text-base-content/85"),
          ~s(class="text-base-content/95"),
          ~s(class="hover:text-base-content/80"),
          ~s(class="group-hover:text-base-content/90"),
          ~s(class="placeholder:text-base-content/70"),
          ~s(class="focus:text-base-content/100"),
          ~s(class="aria-selected:text-base-content/12.5")
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
      <p class="text-subtle hover:text-base-content text-base-content">
        <span class="bg-base-content/40 border-base-content/50 hover:bg-base-content/70">x</span>
        <span class="disabled:text-disabled text-decorative text-base-content/600">y</span>
      </p>
      """

      assert offenses(@floor, clean) == []
      assert offenses(@faint, clean) == []
    end
  end

  test "no base-content text utility at any strength, in any form", %{sources: files} do
    found = for {path, text} <- files, {line, m} <- offenses(@floor, text), do: {path, line, m}

    assert found == [],
           "a base-content text strength (task 01a15907: zero at every strength): paint " <>
             "body (bare text-base-content) or text-subtle, or text-disabled / " <>
             "text-decorative where the element is exempt. Found:\n  " <> report(found)
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
  # "lower the ceiling". Rung 11 (task 01a1557a-9de3) deleted the upload
  # dialog's large-file row, whose 11px size line was one of them: 112 -> 111.
  # Rung 16 (task 01a1557a-b5f9 stage 2) retired the Files picker's 10px org
  # count and the upload sheet's 10px size note (now text-xs): 111 -> 109.
  # Rung 9 (task 01a1557a-9406 stage 1) deleted the agent header's 10px
  # "Context" button: 109 -> 108. Rung 9 stage 4 raised the 10px '(edited)'
  # affix to the masters' 13px and replaced the old version-history modal's
  # 11px meta line: 108 -> 106. Rung 8 (task 01a1557a-8f80 stage 3) deleted
  # the utility bar's agents dropdown and people-online panel, which carried
  # three of them (the 10px panel labels): 106 -> 103. Burrow redesign 22
  # stage 4 (2026-10-25) deleted the desktop search drawer, whose 11px and
  # 10px result meta carried three: 103 -> 100.
  @small_subtle_ceiling 100
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

  # Saru ruling 1 (canvas 01a15902-e3b2 rev 4, "Part 2 rulings"; rev 5 size
  # rule): every site task 01a15907 migrated that carried a size under 12px
  # moved to text-xs in the same edit. Each entry anchors the element by a
  # marker that survives a class change and captures its class string.
  # Exceptions, left at 10px by Saru's rev 5 ruling (a bold count inside a
  # fixed-height badge of 18px or less, or an uppercase badge of four
  # characters or fewer): meeting_live.html.heex's Cards count pill,
  # board_component.ex's and filters_component.ex's status count pills, and
  # the SYS author badge coloured by chat/canvas_hooks.ex badge_class/1.
  @migrated_small [
    {"apps/platform/lib/platform_web/components/meetings/intents_collapse.ex",
     ~r/class="([^"]*)"\s*data-role="intent-target"/},
    {"apps/platform/lib/platform_web/components/meetings/intents_collapse.ex",
     ~r/<p class="([^"]*)">\s*\{@row\.chunk_excerpt \|\| @row\.classified_intent\}/},
    {"apps/platform/lib/platform_web/components/inbox_item.ex",
     ~r/class="([^"]*)"\s*data-role="inbox-item-space"/},
    {"apps/platform/lib/platform_web/live/pipeline_live.ex",
     ~r/:for=\{row <- measured\(@breakdown\)\}\s*class="([^"]*)"/},
    {"apps/platform/lib/platform_web/live/control_center/roles_panel.ex",
     ~r/:for=\{key <- Map\.get\(@role_bundles, role\.key, \[\]\)\}\s*class="([^"]*)"/},
    {"apps/platform/lib/platform_web/live/control_center/roles_panel.ex",
     ~r/<code class="([^"]*)">\s*\{row\.responsibility_key\}/},
    {"apps/platform/lib/platform_web/live/tasks/task_detail_component.ex",
     ~r/<pre class="([^"]*)">\{value\}<\/pre>/}
  ]

  test "every formerly sub-12px site task 01a15907 migrated is text-xs" do
    for {rel, anchor} <- @migrated_small do
      source = File.read!(Path.join(@root, rel))

      assert [[_, class]] = Regex.scan(anchor, source),
             "#{rel}: #{inspect(anchor)} must find exactly one element"

      assert "text-xs" in String.split(class),
             "#{rel}: #{inspect(class)} lost text-xs; the migrated site is 12px (Saru ruling 1)"

      refute Regex.match?(@small_size, class),
             "#{rel}: #{inspect(class)} is back under 12px"
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

  # Stylesheet text colour (task 01a15902 stage 6; widened to every strength
  # by task 01a15907 stage 5). The utility scanner above cannot see a colour
  # declared in a stylesheet. SCOPE: in every comments-stripped stylesheet
  # under assets/css, this refuses any declaration that mixes base-content
  # below 100% into anything (transparent or another colour) when it is
  #
  #   * a `color`, `fill` or `stroke` declaration (or a `-webkit-text-fill-color`
  #     / `caret-color`), or
  #   * a custom property, unless it is one of the slot definitions below, or
  #     every use of it in the stylesheets is a non-text property (background,
  #     border, outline, box-shadow), which makes it a fill and not a text
  #     colour. A custom property with no use in the stylesheets is refused,
  #     since markup may consume it as text.
  #
  # Allowed by DECLARATION NAME, never by line or selector: the definitions
  # of the secondary-text slot (`--subtle`, `--color-subtle`) and of the two
  # canvas-exempt text slots, `--disabled` / `--decorative` (and their
  # `--color-` names), whose placement text_exemption_guard_test.exs polices.
  # A mix whose base-content weight is implicit is weighed as CSS does:
  # 100% minus the other colour's percentage, or 50% when neither has one.
  @css_text_props ~w(color fill stroke -webkit-text-fill-color caret-color)
  @css_fill_props ~r/^(?:background(?:-color|-image)?|border(?:-[a-z]+)*|outline(?:-color)?|box-shadow|text-decoration-color|accent-color)$/
  @css_slot_defs ~w(--subtle --color-subtle --disabled --color-disabled --decorative --color-decorative)
  @css_decl ~r/(?<![\w-])(-{0,2}[a-zA-Z][\w-]*)\s*:\s*([^;{}]*)/
  @css_mix ~r/color-mix\(\s*in\s+[\w-]+(?:\s+[\w-]+)?\s*,\s*([^,()]*(?:\([^()]*\)[^,()]*)*)\s*,\s*([^()]*(?:\([^()]*\)[^()]*)*)\)/

  @doc false
  # The weight (percent) base-content carries in each color-mix in `value`.
  def base_content_weights(value) do
    for [_, a, b] <- Regex.scan(@css_mix, value),
        {mine, other} <- [{a, b}, {b, a}],
        String.contains?(mine, "var(--color-base-content)") do
      pct = fn side ->
        case Regex.run(~r/([\d.]+)%/, side) do
          [_, n] -> elem(Float.parse(n), 0)
          nil -> nil
        end
      end

      case {pct.(mine), pct.(other)} do
        {n, _} when is_number(n) -> n
        {nil, m} when is_number(m) -> 100 - m
        {nil, nil} -> 50.0
      end
    end
  end

  @doc false
  def css_text_offenses(css) do
    css = Regex.replace(~r{/\*.*?\*/}s, css, "")
    decls = for [_, prop, value] <- Regex.scan(@css_decl, css), do: {prop, String.trim(value)}

    uses = fn name ->
      for {prop, value} <- decls,
          Regex.match?(~r/var\(\s*#{Regex.escape(name)}\s*[,)]/, value),
          do: prop
    end

    for {prop, value} <- decls,
        w <- base_content_weights(value),
        w < 100,
        offending?(prop, uses),
        uniq: true,
        do: "#{prop}: #{value} (base-content at #{fmt_pct(w)}%)"
  end

  defp offending?(prop, uses) do
    cond do
      prop in @css_text_props ->
        true

      String.starts_with?(prop, "--") ->
        prop not in @css_slot_defs and
          case uses.(prop) do
            [] -> true
            props -> not Enum.all?(props, &Regex.match?(@css_fill_props, &1))
          end

      true ->
        false
    end
  end

  defp fmt_pct(w) when w == trunc(w), do: Integer.to_string(trunc(w))
  defp fmt_pct(w), do: Float.to_string(w)

  test "no stylesheet paints text with base-content below 100%" do
    paths = Path.wildcard(Path.join(@app, "assets/css/**/*.css"))
    assert Enum.any?(paths, &String.ends_with?(&1, "app.css"))
    assert Enum.any?(paths, &String.ends_with?(&1, "theme_presets.css"))

    found =
      for path <- paths,
          offence <- css_text_offenses(File.read!(path)),
          do: "#{Path.relative_to(path, @root)}: #{offence}"

    assert found == [],
           "a stylesheet paints text with base-content below 100%; paint body " <>
             "(var(--color-base-content)) or var(--color-subtle) (task 01a15907 " <>
             "stage 5):\n  " <> Enum.join(found, "\n  ")
  end

  test "the stylesheet text-colour scanner fires on its fixtures and spares the rest" do
    fire = [
      ".a { color: color-mix(in oklab, var(--color-base-content) 50%, transparent); }",
      ".b { color:color-mix(in oklch, var(--color-base-content) 70%, transparent) }",
      ".c { color: color-mix(in oklab, var(--color-base-content) 70%, transparent); }",
      ".d { color: color-mix(in oklab, var(--color-base-content) 50%, var(--color-neutral)); }",
      ".e { color: color-mix(in oklch, var(--color-base-content) 55%, transparent); }",
      ".f { --x-label: color-mix(in oklab, var(--color-base-content) 70%, transparent); }",
      ".g { --x-label: color-mix(in oklab, var(--color-base-content) 70%, transparent); }\n" <>
        ".h { color: var(--x-label); }",
      ".i { fill: color-mix(in srgb, var(--color-neutral) 30%, var(--color-base-content)); }",
      ".j { color: color-mix(in oklab, var(--color-base-content) 99.5%, transparent); }"
    ]

    for css <- fire, do: assert([_ | _] = css_text_offenses(css), "not flagged: #{css}")

    spare = """
    .k { color: color-mix(in oklab, var(--color-base-content) 100%, transparent); }
    .l { color: var(--color-base-content); }
    .m { color: var(--color-subtle); }
    .n { background-color: color-mix(in oklab, var(--color-base-content) 18%, transparent); }
    .o { border: 1px solid color-mix(in oklab, var(--color-base-content) 10%, transparent); }
    .p { --x-tint: color-mix(in oklab, var(--color-base-content) 5%, var(--color-base-100)); }
    .q { background: var(--x-tint); }
    [data-theme="dark"] {
      --subtle: color-mix(in oklab, var(--color-base-content) 55%, transparent);
      --disabled: color-mix(in oklab, var(--color-base-content) 40%, transparent);
      --decorative: color-mix(in oklab, var(--color-base-content) 30%, transparent);
    }
    """

    assert css_text_offenses(spare) == []
  end
end
