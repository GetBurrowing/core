defmodule Platform.Design.MeetingPaletteGuardTest do
  @moduledoc """
  The meeting room's palette guard (task 01a1557a rung 18, stage 1: "Meetings
  skin only").

  The room was re-skinned to theme tokens: DaisyUI semantic slots, `--edge`,
  `--subtle`, `--viewer` / `--on-viewer`, `--shade` / `--scrim` and the rung-3
  agent slot pointers (`--ag`, `--ag-text`, `--ag-tint`). This guard holds that
  over a NAMED list of the room's files, so a colour literal or a status hue on
  text cannot come back in.

  ## What fails

    * R1, a colour literal: a hex colour (except `#0000`, the transparent
      fallback inside Tailwind's ring-shadow composition), `rgb()`/`rgba()`,
      `hsl()`/`hsla()`, `oklch()`, `oklab()`, `lab()`, `lch()`, `hwb()`; an
      arbitrary `-[#` / `-[rgb` / `-[hsl` / `-[oklch` utility; a Tailwind
      palette colour (`bg-black`, `text-white`, `border-slate-200`, ...); a
      named CSS colour (`white`, `black`, ...) as a colour declaration's value.
    * R3, text colour: `text-base-content/<n>` anywhere, and
      `text-(error|success|warning|info|primary|secondary|accent|neutral)` on
      an element that is not an icon. An icon is a tag carrying
      `aria-hidden="true"`, a `hero-*` class, a class list that opens with an
      `*_icon(...)` helper (the stage-mode glyphs), an `<svg>` or `<.icon>`. A hue
      class written OUTSIDE any tag (in a helper) fails unless it is one of
      the `@icon_tone_helpers` below, each of which feeds only an icon.

  Comments are stripped before the scan, keeping line numbers: `<%!-- --%>`,
  `<!-- -->`, Elixir `#` comments and `@moduledoc` / `@doc` heredocs, CSS
  `/* */`, JS `//` and `/* */`. Documentation may quote the old values.

  ## Scope

  Stage 1's room files, whole, except: `meeting_live.html.heex` is read only
  inside its room branch (`<% @meeting != nil -> %>` up to `<% true -> %>`);
  `meeting_live.ex` without the index helpers that stage 2 re-skins
  (`@stage_2_helpers`, each asserted present so the exclusion is not
  vacuous); and `app.css` only as the meeting-room rules in
  `@app_css_selectors`, sliced with `Platform.Design.CssRules`, the expected
  set asserted before any body is read. Theme token definitions live in the
  theme blocks, which are not in scope.

  ## Anti-vacuity

  The scanner is run on planted literals in this file (a hex in
  meeting_ask.css, `bg-black/40` in agent_tile.ex, a hue on a text span) and
  must flag each with its file and line.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules

  @root Path.expand("../../..", __DIR__)

  @files [
    "assets/css/meeting_ask.css",
    "lib/platform_web/components/meeting/agent_tile.ex",
    "lib/platform_web/components/meeting/video_tile.ex",
    "lib/platform_web/components/meeting/canvas_tile.ex",
    "lib/platform_web/components/meeting/voice_waveform.ex",
    "lib/platform_web/components/meetings/participant_rail.ex",
    "lib/platform_web/components/meetings/call_shell.ex",
    "lib/platform_web/components/meetings/call_rail_frame.ex",
    "lib/platform_web/components/meetings/transcript_pane.ex",
    "lib/platform_web/components/meetings/agent_activity_badge.ex",
    "lib/platform_web/components/meetings/invite_control.ex",
    "lib/platform_web/live/meeting_bar_live.ex",
    "lib/platform_web/live/meeting_live.ex",
    "lib/platform_web/live/meeting_live.html.heex",
    "assets/js/hooks/meeting_captions.js",
    "assets/js/hooks/meeting_client.js",
    "assets/js/hooks/meeting_screen_share.js",
    "assets/js/hooks/meeting_ask_floor_veil.js",
    # Stage 2: index, detail, new-meeting sheet, cards and recap.
    "lib/platform_web/live/meeting_live/calendar_window.ex",
    "lib/platform_web/components/meetings/meeting_detail.ex",
    "lib/platform_web/components/meetings/candidate_rail.ex",
    "lib/platform_web/components/meetings/candidate_display.ex",
    "lib/platform_web/components/meetings/intents_collapse.ex",
    "lib/platform_web/components/meetings/call_recap.ex"
  ]

  @heex_room_open "<% @meeting != nil -> %>"
  @heex_index_open "<% true -> %>"

  @stage_2_files [
    "lib/platform_web/live/meeting_live.html.heex",
    "lib/platform_web/live/meeting_live/calendar_window.ex",
    "lib/platform_web/components/meetings/meeting_detail.ex",
    "lib/platform_web/components/meetings/candidate_rail.ex",
    "lib/platform_web/components/meetings/candidate_display.ex",
    "lib/platform_web/components/meetings/intents_collapse.ex",
    "lib/platform_web/components/meetings/call_recap.ex"
  ]

  # The heex is read from the index branch on for the stage-2 R4 clause.
  defp stage_2_text("lib/platform_web/live/meeting_live.html.heex" = rel) do
    [before, rest] = String.split(read(rel), @heex_index_open, parts: 2)
    String.replace(before, ~r/[^\n]/, "") <> rest
  end

  defp stage_2_text(rel), do: read(rel)

  # Hue classes written outside a tag, each of which only ever reaches an
  # icon (an aria-hidden glyph). {file, line pattern}.
  @icon_tone_helpers [
    # (VideoTile's mic/camera-off glyph left this list in stage 3: it is
    # `text-error-content` on a solid error well, not a hue on text.)
    # The People tab's mic/camera glyph (hero-* span).
    {"lib/platform_web/components/meetings/participant_rail.ex",
     ~r/^\s*defp glyph_tone\(:off\), do: "text-error"$/},
    # The activity ring and corner glyph, both `aria-hidden="true"`.
    {"lib/platform_web/components/meetings/agent_activity_badge.ex",
     ~r/^\s*ring: "border-(info|success|error) text-(info|success|error)",$/}
  ]

  @app_css_selectors MapSet.new([
                       ".meeting-agent-tile[data-agent-slot]",
                       ".meeting-agent-tile[data-agent-slot] .agent-tile-avatar",
                       ~s([data-preset="high-contrast"] .agent-tile-chip),
                       ".meeting-tile-name",
                       ".meeting-tile-you",
                       ".meeting-control-btn",
                       ".meeting-control-btn:hover",
                       ".meeting-control-btn:active",
                       ".screen-share-fullscreen-button",
                       ".screen-share-fullscreen-button:hover",
                       ".screen-share-viewer--fallback",
                       ".screen-share-viewer--fallback [data-screen-share-slot]",
                       ".screen-share-viewer--fallback [data-quickmeet-screen-share-slot]",
                       ".screen-share-viewer--fallback video",
                       "[data-screen-share-viewer]:fullscreen video",
                       "[data-screen-share-viewer]:-webkit-full-screen video",
                       ".screen-share-viewer--fallback [data-quickmeet-screen-share-sharer]"
                     ])

  # Every app.css rule naming a `.candidate-` class (stage 2: the meeting
  # cards and the sheet handle's countdown), asserted as a set before any
  # body is read.
  @candidate_selectors MapSet.new([
                         ".candidate-avatar-fallback",
                         ".candidate-avatar-ghost",
                         ".candidate-btn",
                         ".candidate-btn--go",
                         ".candidate-btn--stop:focus-visible",
                         ".candidate-btn--stop:hover",
                         ".candidate-btn--undo:focus-visible",
                         ".candidate-btn--undo:hover",
                         ".candidate-card",
                         ".candidate-card--acting",
                         ".candidate-card--closed",
                         ".candidate-card--enter",
                         ".candidate-card--forming",
                         ".candidate-card--leave",
                         ".candidate-card--spent",
                         ".candidate-card--spent[hidden]",
                         ".candidate-card--taking-shape",
                         ".candidate-card--thinking",
                         ".candidate-card__ask",
                         ".candidate-card__assignment",
                         ~s(.candidate-card__assignment > [aria-hidden="true"]),
                         ".candidate-card__attrib",
                         ".candidate-card__byline",
                         ".candidate-card__chip",
                         ".candidate-card__chips",
                         ".candidate-card__dash",
                         ".candidate-card__forming",
                         ".candidate-card__forming-dot",
                         ".candidate-card__head",
                         ".candidate-card__outcome",
                         ~s(.candidate-card__outcome > [aria-hidden="true"]),
                         ".candidate-card__quote",
                         ".candidate-card__reason",
                         ".candidate-card__title",
                         ".candidate-card__title--dead",
                         ".candidate-card__title--half",
                         ".candidate-closed",
                         ".candidate-closed__empty",
                         ".candidate-closed__kind",
                         ".candidate-closed__line",
                         ".candidate-closed__link",
                         ".candidate-closed__link:focus-visible",
                         ".candidate-closed__link:hover",
                         ".candidate-closed__summary",
                         ".candidate-correct-btn",
                         ".candidate-correct-btn:focus-visible",
                         ".candidate-correct-btn:hover",
                         ".candidate-correction",
                         ".candidate-correction__choice",
                         ".candidate-correction__choice:focus-visible",
                         ".candidate-correction__choice:hover",
                         ".candidate-correction__list",
                         ".candidate-correction__note",
                         ".candidate-count",
                         ".candidate-count--warning",
                         ".candidate-drain",
                         ".candidate-drain--snap",
                         ".candidate-drain--spent",
                         ".candidate-drain--warning",
                         ".candidate-foot",
                         ".candidate-foot__actions",
                         ".candidate-log",
                         ".candidate-log__dot",
                         ".candidate-log__line",
                         ".candidate-outcome-line",
                         ".candidate-outcome-line__noun",
                         ".candidate-rail-dot",
                         ".candidate-skeleton",
                         ".candidate-skeleton--a",
                         ".candidate-skeleton--b",
                         ".candidate-spent__label",
                         ".sheet-handle__fill.candidate-drain--warning",
                         ".sheet-handle__numeral.candidate-count--warning"
                       ])

  # ── the scanner ────────────────────────────────────────────────────────

  @hex ~r/#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})\b/
  @transparent_hex ~w(#0000 #00000000)
  @functional ~r/\b(?:rgba?|hsla?|oklch|oklab|lab|lch|hwb)\(/
  @arbitrary ~r/-\[(?:#|rgb|hsl|oklch|oklab)/
  @tw_prefix "(?:bg|text|from|via|to|border|ring|ring-offset|fill|stroke|outline|shadow|decoration|divide|accent|caret|placeholder)"
  @tw_bw Regex.compile!("\\b#{@tw_prefix}-(?:black|white)\\b")
  @tw_palette Regex.compile!(
                "\\b#{@tw_prefix}-(?:slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-\\d{2,3}\\b"
              )
  @named_decl ~r/(?<![-\w])(?:color|background|background-color|border|border-color|fill|stroke|outline|outline-color|box-shadow)\s*:[^;{}"]*\b(?:white|black|red|blue|green|gray|grey|silver|yellow|orange|purple|navy)\b/
  @opacity_text ~r/\btext-base-content\/\d+/
  @hue_text ~r/(?<![-\w])text-(?:error|success|warning|info|primary|secondary|accent|neutral)(?![-\w])(?:\/\d+)?/
  @tag_re ~r/<([a-zA-Z.][\w.:-]*)((?:[^>"{]|"[^"]*"|\{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*\})*)>/s

  @doc false
  # Every violation in `text` (already comment-stripped, line numbers kept),
  # as "file:line: what".
  def scan(file, text, opts \\ []) do
    lines = String.split(text, "\n")
    css? = Keyword.get(opts, :css?, false)

    literal =
      for {line, n} <- Enum.with_index(lines, 1),
          {what, re} <- [
            {"hex colour", @hex},
            {"colour function", @functional},
            {"arbitrary colour utility", @arbitrary},
            {"Tailwind black/white", @tw_bw},
            {"Tailwind palette colour", @tw_palette},
            {"named colour", @named_decl},
            {"text-base-content/<n>", @opacity_text}
          ],
          m <- Regex.scan(re, line),
          hit = hd(m),
          not (what == "hex colour" and String.downcase(hit) in @transparent_hex),
          do: "#{file}:#{n}: #{what} `#{hit}`"

    hue = if css?, do: [], else: hue_violations(file, text)
    literal ++ hue
  end

  defp hue_violations(file, text) do
    icon_ranges =
      for [{start, len} | _] <- Regex.scan(@tag_re, text, return: :index),
          tag = binary_part(text, start, len),
          icon_tag?(tag),
          do: {start, start + len}

    tag_ranges =
      for [{start, len} | _] <- Regex.scan(@tag_re, text, return: :index),
          do: {start, start + len}

    helpers = for {^file, re} <- @icon_tone_helpers, do: re

    for [{pos, len}] <- Regex.scan(@hue_text, text, return: :index),
        not inside?(pos, icon_ranges),
        line_no = line_of(text, pos),
        line = Enum.at(String.split(text, "\n"), line_no - 1),
        inside?(pos, tag_ranges) or not Enum.any?(helpers, &Regex.match?(&1, line)) do
      where = if inside?(pos, tag_ranges), do: "on a text element", else: "in a helper"
      "#{file}:#{line_no}: status hue on text #{where} `#{binary_part(text, pos, len)}`"
    end
  end

  defp icon_tag?(tag) do
    tag =~ ~r/aria-hidden=(?:"true"|\{true\})/ or tag =~ ~r/["\s\[]hero-[a-z]/ or
      tag =~ ~r/\[\s*\w+_icon\(/ or tag =~ ~r/^<(?:svg|\.icon)\b/
  end

  defp inside?(pos, ranges), do: Enum.any?(ranges, fn {a, b} -> pos >= a and pos < b end)

  defp line_of(text, pos),
    do: binary_part(text, 0, pos) |> String.split("\n") |> length()

  @doc false
  # Comments replaced by the same number of newlines, so line numbers hold.
  def strip(path, text) do
    blank = fn m -> String.duplicate("\n", length(String.split(m, "\n")) - 1) end

    cond do
      String.ends_with?(path, ".css") ->
        Regex.replace(~r{/\*.*?\*/}s, text, blank)

      String.ends_with?(path, ".js") ->
        text
        |> then(&Regex.replace(~r{/\*.*?\*/}s, &1, blank))
        |> then(&Regex.replace(~r{(?<![:\\"'])//[^\n]*}, &1, ""))

      true ->
        text
        |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
        |> then(&Regex.replace(~r/<!--.*?-->/s, &1, blank))
        |> then(
          &Regex.replace(
            ~r/(?:@(?:moduledoc|doc|typedoc)\s+|\bdoc:\s*)(?:~[sS])?""".*?"""/s,
            &1,
            blank
          )
        )
        # An Elixir comment's `#` is followed by whitespace, `#`, `!` or the
        # line end; a hex colour's never is, so ` #abcdef` in a class
        # string is scanned rather than stripped as a comment.
        |> then(&Regex.replace(~r/(^|\s)#(?=[\s#!]|$)[^\n]*/m, &1, "\\1"))
    end
  end

  # ── reading the scope ─────────────────────────────────────────────────

  defp read(rel), do: File.read!(Path.join(@root, rel))

  @doc false
  # The room branch (stage 1) and the index branch after it (stage 2: Calendar,
  # Archive, detail and the new-meeting sheet). The guest branch before the
  # room is out of scope; it is blanked to newlines so line numbers hold.
  def scope_text("lib/platform_web/live/meeting_live.html.heex" = rel) do
    text = read(rel)
    [before, rest] = String.split(text, @heex_room_open, parts: 2)
    pad = fn s -> String.replace(s, ~r/[^\n]/, "") end
    pad.(before) <> String.duplicate(" ", byte_size(@heex_room_open)) <> rest
  end

  def scope_text(rel), do: read(rel)

  defp violations(rel) do
    scan(rel, strip(rel, scope_text(rel)), css?: String.ends_with?(rel, ".css"))
  end

  defp app_css_rules do
    "assets/css/app.css"
    |> read()
    |> CssRules.rules()
    |> Enum.filter(&MapSet.member?(@app_css_selectors, &1.selector))
  end

  # Every app.css rule whose selector names a `.candidate-` class (stage 2).
  defp candidate_css_rules(css \\ read("assets/css/app.css")) do
    css
    |> CssRules.rules()
    |> Enum.filter(&(&1.selector =~ ".candidate-"))
  end

  # R3 in CSS: a `color:` declaration in a card rule names text ink only.
  @css_text_colours ~w[var(--color-base-content) var(--color-subtle) var(--color-primary-content) inherit currentColor]

  # An aria-hidden glyph (the card's ✓ and →) is an icon and may take a hue.
  defp css_text_colour(%{selector: sel, body: body}) do
    for [_, value] <- Regex.scan(~r/(?<![-\w])color\s*:\s*([^;]+)/, body),
        not String.ends_with?(sel, ~s([aria-hidden="true"])),
        value = String.trim(value),
        value not in @css_text_colours,
        do:
          "app.css #{sel}: text colour `#{value}` is not base-content, subtle or primary-content"
  end

  # R4 in markup: a `hover:` variant not behind `lg:` (stage-2 files only;
  # stage 1 recorded its own hover handling).
  @bare_hover ~r/(?<![\w:-])hover:[\w\/\[\]().%-]+/

  defp bare_hovers(file, text) do
    for {line, n} <- Enum.with_index(String.split(text, "\n"), 1),
        [hit] <- Regex.scan(@bare_hover, line),
        do: "#{file}:#{n}: bare hover: `#{hit}`"
  end

  # ── tests ─────────────────────────────────────────────────────────────

  test "the named file list is non-empty and every path exists" do
    assert length(@files) == 24

    for rel <- @files do
      assert File.regular?(Path.join(@root, rel)), "missing scope file: #{rel}"
    end
  end

  test "the heex slice is the room and index branches, line numbers kept" do
    text = read("lib/platform_web/live/meeting_live.html.heex")
    assert length(String.split(text, @heex_room_open)) == 2
    assert length(String.split(text, @heex_index_open)) == 2
    scoped = scope_text("lib/platform_web/live/meeting_live.html.heex")
    assert length(String.split(scoped, "\n")) == length(String.split(text, "\n"))
    # Room (stage 1).
    assert scoped =~ ~s(data-role="meeting-captions")
    assert scoped =~ ~s(data-role="meeting-live-pill")
    assert scoped =~ ~s(data-role="meeting-agent-removed-toast")
    # Index, detail, archive and new-meeting sheet (stage 2).
    assert scoped =~ @heex_index_open
    assert scoped =~ ~s(data-role="start-meeting-sheet")
    assert scoped =~ ~s(data-role="archive-row")
    assert scoped =~ ~s(data-role="meeting-detail-sheet-backdrop")

    for {rel, re} <- @icon_tone_helpers do
      assert rel in @files

      assert Enum.any?(String.split(read(rel), "\n"), &Regex.match?(re, &1)),
             "icon-tone helper #{inspect(re)} matches no line in #{rel}: drop it"
    end
  end

  test "R1/R3: no colour literal and no status hue on text in any room file" do
    failures = Enum.flat_map(@files, &violations/1)
    assert failures == [], Enum.join(failures, "\n")
  end

  test "R1: the meeting-room rules in app.css are sliced and colour-free" do
    rules = app_css_rules()
    assert MapSet.new(rules, & &1.selector) == @app_css_selectors

    failures =
      for r <- rules,
          hit <- scan("app.css #{r.selector}", r.body, css?: true),
          do: hit

    assert failures == [], Enum.join(failures, "\n")
  end

  test "R1/R3: the .candidate-* card rules in app.css are sliced, colour-free and hue-free on text" do
    rules = candidate_css_rules()
    assert MapSet.new(rules, & &1.selector) == @candidate_selectors

    failures =
      for r <- rules,
          hit <-
            scan("app.css #{r.selector}", r.body, css?: true) ++ css_text_colour(r),
          do: hit

    assert failures == [], Enum.join(failures, "\n")
  end

  test "R4: no bare hover: in the stage-2 markup (index, detail, cards, recap)" do
    failures =
      for rel <- @stage_2_files,
          text = strip(rel, stage_2_text(rel)),
          hit <- bare_hovers(rel, text),
          do: hit

    assert failures == [], Enum.join(failures, "\n")
  end

  test "R4: every .candidate-* :hover rule applies only to a real pointer at lg and up" do
    hovers = Enum.filter(candidate_css_rules(), &(&1.selector =~ ":hover"))
    assert hovers != []

    for r <- hovers do
      assert "@media (hover: hover) and (min-width: 1024px)" in r.at, r.selector
    end
  end

  test "R7: the --cc-* card palette is gone from app.css, with no alias left behind" do
    css = strip("app.css", read("assets/css/app.css"))
    refute css =~ ~r/--cc-[a-z]/, "a --cc-* token is declared or read in app.css"
  end

  test "R3: the Ask stylesheet keeps the hue off text and the old palette is gone" do
    css = strip("x.css", read("assets/css/meeting_ask.css"))
    refute css =~ ~r/--(?:bg|s|s2|b|t|m|a|ai|live|ok|bad)\s*:/
    refute css =~ ~r/var\(--(?:bg|s|s2|b|t|m|a|ai|live|ok|bad)\)/
    refute css =~ ~r/--ag-[a-z]+(?:-text)?\s*:/
    assert css =~ ".meeting-ask .ask{position:relative"
    assert css =~ "background:var(--color-info);color:var(--color-info-content)"
  end

  test "R4: the Ask row's hover rules apply only to a real pointer at lg and up" do
    rules = CssRules.rules(read("assets/css/meeting_ask.css"))
    hovers = Enum.filter(rules, &(&1.selector =~ ":hover"))
    assert hovers != []

    for r <- hovers do
      assert r.at == ["@media (hover:hover) and (min-width:1024px)"], r.selector
    end
  end

  # ── anti-vacuity ──────────────────────────────────────────────────────

  test "anti-vacuity: planted literals and a hued text span go red with file and line" do
    ask = "assets/css/meeting_ask.css"
    planted_css = read(ask) <> "\n.meeting-ask .x{color:#123456}\n"
    n_css = length(String.split(planted_css, "\n")) - 1

    assert "#{ask}:#{n_css}: hex colour `#123456`" in scan(ask, strip(ask, planted_css),
             css?: true
           )

    tile = "lib/platform_web/components/meeting/agent_tile.ex"

    planted_tile =
      String.replace(read(tile), "bg-viewer/60", "bg-black/40", global: false)

    [line_no] =
      for {l, n} <- Enum.with_index(String.split(planted_tile, "\n"), 1),
          l =~ "bg-black/40",
          do: n

    assert "#{tile}:#{line_no}: Tailwind black/white `bg-black`" in scan(
             tile,
             strip(tile, planted_tile)
           )

    hued =
      ~s(<span class="text-xs text-error">Couldn't</span>\n<span class="hero-x text-error"></span>)

    assert scan("t.heex", hued) == ["t.heex:1: status hue on text on a text element `text-error`"]

    # Comments are stripped: a literal in one is not a violation.
    assert scan(ask, strip(ask, "/* #123456 rgba(0,0,0,.5) */\n.a{color:var(--x)}")) == []
    assert scan("t.ex", strip("t.ex", "  # bg-black text-white #fff\n  x = 1")) == []
  end

  test "anti-vacuity (stage 2): #abcdef in call_recap.ex and --cc-bg back in app.css go red" do
    recap = "lib/platform_web/components/meetings/call_recap.ex"

    planted_recap =
      String.replace(
        read(recap),
        ~s(class="mt-1 inline-flex),
        ~s(class="mt-1 #abcdef inline-flex),
        global: false
      )

    [line_no] =
      for {l, n} <- Enum.with_index(String.split(planted_recap, "\n"), 1),
          l =~ "#abcdef",
          do: n

    assert "#{recap}:#{line_no}: hex colour `#abcdef`" in scan(recap, strip(recap, planted_recap))

    css = read("assets/css/app.css")

    planted_css =
      String.replace(css, "\n.candidate-card {\n", "\n.candidate-card {\n  --cc-bg: #ffffff;\n")

    refute planted_css == css
    assert strip("app.css", planted_css) =~ ~r/--cc-[a-z]/

    [card] = Enum.filter(candidate_css_rules(planted_css), &(&1.selector == ".candidate-card"))

    assert "app.css .candidate-card:1: hex colour `#ffffff`" in scan(
             "app.css .candidate-card",
             card.body,
             css?: true
           )

    # A hue on card text and an ungated :hover are caught too.
    hued = %{selector: ".candidate-x", body: "color: var(--color-warning);"}
    assert css_text_colour(hued) != []

    assert bare_hovers("t.heex", ~s(<a class="text-sm hover:bg-base-300 lg:hover:underline">)) ==
             ["t.heex:1: bare hover: `hover:bg-base-300`"]
  end
end
