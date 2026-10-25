defmodule Platform.Design.MeetingReskinContrastGuardTest do
  @moduledoc """
  Painted contrast for the meetings re-skin (task 01a1557a rung 18, stage 3),
  in all ten theme variants (Burrow, Midnight, Sand, Forest, High contrast;
  light and dark), read through `Platform.Design.ThemeBlocks` from app.css and
  theme_presets.css, following `more_sheet_contrast_guard_test.exs`.

  ## Measurement

    * Opaque pairs: `WcagContrast.contrast/2`.
    * `--subtle` (alpha ink at the block's declared 55/57%): the worst pixel
      `PaintedComposite.contrast_min/3` allows.
    * Every other translucent paint (`bg-viewer/75`, `bg-success/15`, ...) at
      the strength DECLARED in the source file that paints it, read from that
      file here (never typed into this guard), as the set of pixels the four
      `PaintedComposite` formulas give channel by channel. A strength outside
      the measured corpus (55/57/60) is widened by `@slack` levels either way,
      the method `message_attention_contrast_guard_test.exs` uses for its 15%
      chip, so the pair is held on a pixel set strictly larger than the model.
    * The agent tint (`--ag-<id>-tint`, an opaque srgb mix): the pixels
      `PaintedMix.painted!/3` recorded for it.
    * Video bands are measured over the WORST underlay a frame can give: a
      #ffffff frame for white text and glyphs.

  The table prints before anything is asserted.

  ## Pairs that are measured but not held at 4.5

    * `--ag-text` on base-300. The light blocks give 4.01-4.44:1 there (stage
      1 recorded it). No meeting rule paints an agent's name or initials on
      base-300: the Ask row is base-100 and the transcript chip is
      `text-subtle` (see "the transcript AGENT chip" below). The row prints,
      and a structural clause asserts the pair stays unpainted. If a rule
      ever paints `--ag-text` on base-300, that clause goes red.
    * High contrast's agent chip: opaque viewer, 7:1 is advisory (it is 21:1).
    * The scrim and shade alphas: advisory, printed only.

  ## `--edge` is decorative

  `--edge` is exempt from 3:1, so no state rule in meeting_ask.css or the
  `.candidate-*` card rules may signal its state with `--edge` alone.

  ## Anti-vacuity

  The Ask label token is READ from `meeting_ask.css`. A clause swaps it for
  base-200 in memory and asserts the table would go red, naming variants.
  """
  use ExUnit.Case, async: true

  alias Platform.Agents.ColorPalette
  alias Platform.Design.CssRules
  alias Platform.Design.PaintedComposite, as: PC
  alias Platform.Design.PaintedMix
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.WcagContrast, as: W

  @root Path.expand("../../..", __DIR__)
  @app_css_path Path.join(@root, "assets/css/app.css")
  @presets_path Path.join(@root, "assets/css/theme_presets.css")
  @ask_css_path Path.join(@root, "assets/css/meeting_ask.css")

  @aa_text 4.5
  @aaa 7.0
  @non_text 3.0
  @slack 2

  @variants [
    {"burrow", "light"},
    {"burrow", "dark"},
    {"burrow-midnight", "light"},
    {"burrow-midnight", "dark"},
    {"burrow-sand", "light"},
    {"burrow-sand", "dark"},
    {"burrow-forest", "light"},
    {"burrow-forest", "dark"},
    {"high-contrast", "light"},
    {"high-contrast", "dark"}
  ]

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/
  @pct_form ~r/^(\d+)%$/
  @white W.hex("#ffffff")

  # Each translucent strength, read from the file that paints it. `{label,
  # file, regex}`: the regex's one capture is the integer percent.
  @strengths %{
    captions:
      {"lib/platform_web/live/meeting_live.html.heex",
       ~r/bg-viewer\/(\d+) backdrop-blur-sm text-sm text-on-viewer/},
    chip:
      {"lib/platform_web/components/meeting/agent_tile.ex",
       ~r/agent-tile-chip [^"]*bg-viewer\/(\d+)/},
    stage_label:
      {"lib/platform_web/live/meeting_live.html.heex", ~r/rounded-full bg-viewer\/(\d+) px-2/},
    band:
      {"lib/platform_web/components/meeting/video_tile.ex",
       ~r/bg-gradient-to-t from-viewer\/(\d+) to-transparent/},
    band_js:
      {"assets/css/app.css",
       ~r/\.meeting-tile-name \{[^}]*linear-gradient\(transparent, color-mix\(in oklab, var\(--viewer\) (\d+)%, transparent\)\)/s},
    mic:
      {"lib/platform_web/components/meeting/video_tile.ex",
       ~r/glyph_tone\(_state\), do: "text-on-viewer\/(\d+)"/},
    interim: {"assets/js/hooks/meeting_captions.js", ~r/CAPTION_INTERIM = "opacity-(\d+)"/},
    ask_hover:
      {"assets/css/meeting_ask.css",
       ~r/\.meeting-ask \.ask:hover\{background:color-mix\(in oklab,var\(--color-info\) (\d+)%,var\(--viewer\)\)\}/},
    rail_well:
      {"lib/platform_web/components/meetings/participant_rail.ex",
       ~r/well_class\(:off\), do: "bg-error\/(\d+)"/},
    meter:
      {"lib/platform_web/components/meetings/participant_rail.ex",
       ~r/rounded-full bg-primary opacity-(\d+) transition-transform/},
    veil:
      {"lib/platform_web/components/meetings/participant_rail.ex", ~r/bg-viewer\/(\d+) opacity-0/},
    whiteboard_notice:
      {"lib/platform_web/live/meeting_live.html.heex",
       ~r/rounded-lg bg-info\/(\d+) px-4 py-3 text-sm text-info-content/}
  }

  # The files whose class strings are scanned for `text-base-content` on a
  # status-hue fill (pills, wells, leave buttons, banners).
  @fill_files [
    "lib/platform_web/live/meeting_live.html.heex",
    "lib/platform_web/live/meeting_live.ex",
    "lib/platform_web/live/meeting_bar_live.ex",
    "lib/platform_web/components/meetings/call_shell.ex",
    "lib/platform_web/components/meetings/intents_collapse.ex",
    "lib/platform_web/components/meetings/invite_control.ex",
    "lib/platform_web/components/meetings/participant_rail.ex",
    "lib/platform_web/components/meetings/meeting_detail.ex",
    "lib/platform_web/components/meetings/call_recap.ex",
    "lib/platform_web/components/meetings/candidate_rail.ex"
  ]

  setup_all do
    app_css = File.read!(@app_css_path)
    presets = File.read!(@presets_path)
    ask_css = File.read!(@ask_css_path)

    by_key =
      Map.new(Blocks.preset_blocks(presets), &{{&1.id, &1.mode}, &1})
      |> Map.put({"burrow", "light"}, Blocks.burrow_block(app_css, "light"))
      |> Map.put({"burrow", "dark"}, Blocks.burrow_block(app_css, "dark"))

    blocks =
      for {id, mode} = key <- @variants do
        Map.get(by_key, key) || flunk("no #{id} #{mode} block")
      end

    strengths =
      Map.new(@strengths, fn {k, {file, re}} ->
        src = File.read!(Path.join(@root, file))

        case Regex.run(re, src) do
          [_, n] ->
            {k, String.to_integer(n)}

          nil ->
            flunk("#{k}: no #{inspect(re.source)} in #{file}; the guard cannot read its strength")
        end
      end)

    {:ok,
     blocks: blocks,
     strengths: strengths,
     ask_css: ask_css,
     ask_rules: CssRules.rules(ask_css),
     app_rules: CssRules.rules(app_css),
     ask_label: ask_label_token(ask_css),
     danger_label: danger_label_token(ask_css),
     fills: fills()}
  end

  # ── source readers ─────────────────────────────────────────────────────

  defp ask_label_token(css) do
    rule =
      css
      |> CssRules.rules()
      |> Enum.find(
        &(&1.selector == ".meeting-ask .ask" and &1.at == [] and &1.body =~ "background:")
      )

    rule || flunk("meeting_ask.css: no `.meeting-ask .ask` rule with a background")
    assert rule.body =~ ~r/background:\s*var\(--color-info\)/

    case Regex.run(~r/(?:^|;)\s*color:\s*var\((--[a-z0-9-]+)\)/, rule.body) do
      [_, token] -> token
      nil -> flunk("`.meeting-ask .ask` has no `color: var(--token)`")
    end
  end

  defp danger_label_token(css) do
    rule =
      css
      |> CssRules.rules()
      |> Enum.find(&(&1.selector == ".meeting-ask .mbtn.danger"))

    rule || flunk("meeting_ask.css: no `.meeting-ask .mbtn.danger` rule")
    assert rule.body =~ ~r/background:\s*var\(--color-error\)/
    [_, token] = Regex.run(~r/(?:^|;)\s*color:\s*var\((--[a-z0-9-]+)\)/, rule.body)
    token
  end

  # `{hue, strength}` of every status-hue fill that shares a class string with
  # `text-base-content` (a `lg:hover:` fill included), across `@fill_files`.
  defp fills do
    for file <- @fill_files,
        src = File.read!(Path.join(@root, file)),
        [str] <- Regex.scan(~r/"[^"\n]*text-base-content[^"\n]*"/, src),
        [_, hue, n] <-
          Regex.scan(
            ~r/(?<![\w-])(?:lg:hover:)?bg-(success|primary|error|info|warning)\/(\d+)/,
            str
          ),
        uniq: true do
      {hue, String.to_integer(n)}
    end
    |> Enum.sort()
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: ThemeBlockAssertions.resolve!(b, token)
  defp bytes(color), do: PC.bytes(color)
  defp px(rgb), do: PC.from_bytes(rgb)

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

  defp tint_pct(b) do
    value =
      Blocks.declaration(b.decls, "--ag-tint-pct") || flunk("#{b.id} #{b.mode}: no --ag-tint-pct")

    [_, n] = Regex.run(@pct_form, value) || flunk("#{b.id} #{b.mode}: --ag-tint-pct #{value}")
    String.to_integer(n)
  end

  # Every pixel the four formulas paint for `ink` at `p`% over `ground` (8-bit
  # pixels), channel by channel, widened by `@slack` outside the measured corpus.
  defp alpha_pixels(ink, ground, p) do
    {ir, ig, ib} = bytes(ink)
    {gr, gg, gb} = ground
    slack = if p in PC.measured_strengths(), do: 0, else: @slack

    ch = fn i, g ->
      for(f <- PC.formulas(), do: elem(PC.paint(f, {i, 0, 0}, {g, 0, 0}, p), 0))
      |> Enum.flat_map(fn v -> Enum.to_list(max(v - slack, 0)..min(v + slack, 255)) end)
      |> Enum.uniq()
    end

    for r <- ch.(ir, gr), g <- ch.(ig, gg), bl <- ch.(ib, gb), do: {r, g, bl}
  end

  defp over(ink, grounds, p), do: Enum.flat_map(grounds, &alpha_pixels(ink, &1, p)) |> Enum.uniq()

  # Worst contrast of opaque `ink` against any of `grounds` (8-bit pixels).
  defp on(ink, grounds), do: grounds |> Enum.map(&W.contrast(ink, px(&1))) |> Enum.min()

  # Worst contrast of `ink` at `p`% over each ground pixel, against that ground.
  defp alpha_on(ink, grounds, p) do
    grounds
    |> Enum.map(fn g ->
      alpha_pixels(ink, g, p) |> Enum.map(&W.contrast(px(&1), px(g))) |> Enum.min()
    end)
    |> Enum.min()
  end

  defp subtle_on(b, ground) do
    {r, _} = PC.contrast_min(c(b, "--color-base-content"), ground, subtle_pct(b))
    r
  end

  defp g(b, token), do: [bytes(c(b, token))]
  defp ratio(b, ink, ground), do: W.contrast(c(b, ink), c(b, ground))

  defp tints(b, id),
    do:
      PaintedMix.painted!(bytes(c(b, "--ag-#{id}")), bytes(c(b, "--color-base-100")), tint_pct(b))

  # The video name band over a white frame.
  defp band(b, s), do: alpha_pixels(c(b, "--viewer"), bytes(@white), s.band)

  defp hc?(b), do: b.id == "high-contrast"

  defp pairs(b, s, ctx) do
    info = c(b, "--color-info")
    on_viewer = c(b, "--on-viewer")
    viewer = c(b, "--viewer")
    base = c(b, "--color-base-content")
    white = [bytes(@white)]
    b100 = g(b, "--color-base-100")
    b300 = g(b, "--color-base-300")
    ids = ColorPalette.ids()
    band_px = band(b, s)
    hover_fill = W.mix_oklab(info, s.ask_hover, viewer)

    chip =
      if hc?(b) do
        W.contrast(on_viewer, viewer)
      else
        ids
        |> Enum.map(fn id -> on(on_viewer, over(viewer, tints(b, id), s.chip)) end)
        |> Enum.min()
      end

    fill_pairs =
      for {hue, n} <- ctx.fills do
        {"base-content / #{hue}/#{n} over base-100",
         on(base, over(c(b, "--color-#{hue}"), b100, n)), @aa_text}
      end

    [
      # ── text ──
      {"base-content / base-100", ratio(b, "--color-base-content", "--color-base-100"), @aa_text},
      {"base-content / base-200", ratio(b, "--color-base-content", "--color-base-200"), @aa_text},
      {"base-content / base-300", ratio(b, "--color-base-content", "--color-base-300"), @aa_text},
      {"subtle / base-100", subtle_on(b, c(b, "--color-base-100")), @aa_text},
      {"subtle / base-200", subtle_on(b, c(b, "--color-base-200")), @aa_text},
      {"subtle / base-300", subtle_on(b, c(b, "--color-base-300")), @aa_text},
      {"Ask label #{ctx.ask_label} / info", W.contrast(c(b, ctx.ask_label), info), @aa_text},
      {"Ask label / hover fill (info #{s.ask_hover}% viewer)",
       W.contrast(c(b, ctx.ask_label), hover_fill), @aa_text},
      {"#{ctx.danger_label} / error (.mbtn.danger)",
       W.contrast(c(b, ctx.danger_label), c(b, "--color-error")), @aa_text},
      {"primary-content / primary", ratio(b, "--color-primary-content", "--color-primary"),
       @aa_text},
      {"on-viewer / viewer/#{s.captions} over #fff (captions)",
       on(on_viewer, over(viewer, white, s.captions)), @aa_text},
      {"interim caption on-viewer opacity-#{s.interim} / viewer/#{s.captions} over #fff",
       interim_min(on_viewer, over(viewer, white, s.captions), s.interim), @aa_text},
      {"on-viewer / viewer/#{s.stage_label} over #fff (stage label)",
       on(on_viewer, over(viewer, white, s.stage_label)), @aa_text},
      {"on-viewer / agent chip viewer/#{s.chip} on each tint#{if hc?(b), do: " (HC opaque)"}",
       chip, @aa_text},
      {"on-viewer / band viewer #{s.band}% over #fff (video tile)", on(on_viewer, band_px),
       @aa_text},
      {"on-viewer / band viewer #{s.band_js}% over #fff (.meeting-tile-name)",
       on(on_viewer, alpha_pixels(viewer, bytes(@white), s.band_js)), @aa_text},
      {"base-content / card ask (info 12% base-100)",
       W.contrast(base, px(bytes(W.mix_oklab(info, 12, c(b, "--color-base-100"))))), @aa_text},
      {"info-content / info/#{s.whiteboard_notice} over #fff and viewer",
       on(
         c(b, "--color-info-content"),
         over(info, white ++ g(b, "--viewer"), s.whiteboard_notice)
       ), @aa_text}
    ] ++
      fill_pairs ++
      [
        {"--ag-text / base-100 (10 slots)",
         ids |> Enum.map(&ratio(b, "--ag-#{&1}-text", "--color-base-100")) |> Enum.min(),
         @aa_text},
        # The transcript AGENT chip: --ag-text label, --ag outline, on the
        # rail pane (base-100 on desktop, the base-100 sheet on a phone; the
        # base-200 page under the rail's /40 wash is the other bound).
        {"transcript chip --ag-text / base-100, base-200 (10 slots)",
         for(
           id <- ids,
           g <- ["--color-base-100", "--color-base-200"],
           do: ratio(b, "--ag-#{id}-text", g)
         )
         |> Enum.min(), @aa_text},
        # ── non-text ──
        {"transcript chip --ag border / base-100, base-200 (10 slots)",
         for(
           id <- ids,
           g <- ["--color-base-100", "--color-base-200"],
           do: ratio(b, "--ag-#{id}", g)
         )
         |> Enum.min(), @non_text},
        {"info ring / base-100", ratio(b, "--color-info", "--color-base-100"), @non_text},
        {"info ring / base-300", ratio(b, "--color-info", "--color-base-300"), @non_text},
        {"primary underline, ring-2 / base-300", ratio(b, "--color-primary", "--color-base-300"),
         @non_text},
        {"primary meter opacity-#{s.meter} / base-300",
         alpha_on(c(b, "--color-primary"), b300, s.meter), @non_text},
        {"error icon / error/#{s.rail_well} over base-100, base-300",
         on(c(b, "--color-error"), over(c(b, "--color-error"), b100 ++ b300, s.rail_well)),
         @non_text},
        {"video mic-off glyph error-content / solid error well",
         ratio(b, "--color-error-content", "--color-error"), @non_text},
        {"success dot / base-100", ratio(b, "--color-success", "--color-base-100"), @non_text},
        {"--ag rail, ring / --ag-tint (10 slots)",
         ids |> Enum.map(&on(c(b, "--ag-#{&1}"), tints(b, &1))) |> Enum.min(), @non_text},
        {"--ag rail, ring / base-100 (10 slots)",
         ids |> Enum.map(&ratio(b, "--ag-#{&1}", "--color-base-100")) |> Enum.min(), @non_text},
        {"mic glyph on-viewer/#{s.mic} / band", mic_min(on_viewer, band_px, s.mic), @non_text}
      ]
  end

  defp interim_min(ink, grounds, p), do: mic_min(ink, grounds, p)

  defp mic_min(ink, band_px, p) do
    band_px
    |> Enum.map(fn bp ->
      alpha_pixels(ink, bp, p) |> Enum.map(&W.contrast(px(&1), px(bp))) |> Enum.min()
    end)
    |> Enum.min()
  end

  defp f2(r), do: :erlang.float_to_binary(r / 1, decimals: 2)

  defp rows(blocks, s, ctx), do: for(b <- blocks, do: {b, pairs(b, s, ctx)})

  defp failures(rows) do
    for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
      "#{b.id} #{b.mode}: #{label} #{f2(r)} < #{floor}"
    end
  end

  # ── contrast ───────────────────────────────────────────────────────────

  test "every pair clears its floor in all ten variants; the table prints", ctx do
    %{blocks: blocks, strengths: s} = ctx
    assert length(blocks) == 10
    # The fill scan is not vacuous: the pills the plan names are found.
    for f <- [{"success", 15}, {"primary", 12}, {"error", 10}, {"info", 10}] do
      assert f in ctx.fills,
             "fill #{inspect(f)} not found in the meeting class strings: #{inspect(ctx.fills)}"
    end

    # The opaque mic-off pair is the one VideoTile paints.
    tile = File.read!(Path.join(@root, "lib/platform_web/components/meeting/video_tile.ex"))
    assert tile =~ ~S|defp well_class(:off), do: "size-5 rounded-md bg-error"|
    assert tile =~ ~S|defp glyph_tone(:off), do: "text-error-content"|

    rows = rows(blocks, s, ctx)
    labels = rows |> hd() |> elem(1) |> Enum.map(fn {l, _, f} -> {l, f} end)

    IO.puts(
      "\nMeetings re-skin contrast (WCAG 2.x; translucent pairs on the worst painted pixel; " <>
        "strengths read from source: #{inspect(s)}):\n" <>
        "| pair | floor | " <>
        Enum.map_join(blocks, " | ", &"#{&1.id} #{&1.mode}") <>
        " | min |\n|---|---|" <>
        String.duplicate("---|", length(blocks) + 1) <>
        "\n" <>
        (labels
         |> Enum.with_index()
         |> Enum.map_join("\n", fn {{label, floor}, i} ->
           vals = Enum.map(rows, fn {_, ps} -> elem(Enum.at(ps, i), 1) end)

           "| #{label} | #{floor} | " <>
             Enum.map_join(vals, " | ", &f2/1) <> " | #{f2(Enum.min(vals))} |"
         end))
    )

    IO.puts(
      "\nAdvisory (not asserted):\n" <>
        Enum.map_join(blocks, "\n", fn b ->
          ag300 =
            ColorPalette.ids()
            |> Enum.map(&ratio(b, "--ag-#{&1}-text", "--color-base-300"))
            |> Enum.min()

          chip =
            if hc?(b),
              do:
                " | HC chip #{f2(W.contrast(c(b, "--on-viewer"), c(b, "--viewer")))} (7:1 advisory)",
              else: ""

          "#{b.id} #{b.mode}: --ag-text / base-300 (unpainted) #{f2(ag300)} | scrim #{Blocks.declaration(b.decls, "--scrim")}" <>
            " | shade #{Blocks.declaration(b.decls, "--shade")}" <> chip
        end)
    )

    assert failures(rows) == []
  end

  test "high contrast's agent chip is the opaque viewer and clears 7:1", %{blocks: blocks} do
    for b <- blocks, hc?(b) do
      assert W.contrast(c(b, "--on-viewer"), c(b, "--viewer")) >= @aaa
    end
  end

  # The plan's plant was base-200. Measured, base-200 on the info fill CLEARS
  # 4.5 in all ten variants (4.93:1 at worst, forest light), so it cannot make
  # this guard go red; that is recorded here rather than assumed. base-content
  # (black on the light teal fills, near-white on the dark cyan ones) fails,
  # and is the plant that proves the pair can fail.
  test "anti-vacuity: a planted Ask label goes red with the variant and ratio", ctx do
    plant = fn token ->
      ctx.blocks
      |> rows(ctx.strengths, %{ctx | ask_label: token})
      |> failures()
      |> Enum.filter(&(&1 =~ "Ask label #{token} / info"))
    end

    assert plant.("--color-base-200") == [],
           "base-200 now fails somewhere: make it the plant again"

    red = plant.("--color-base-content")
    assert length(red) >= 5, inspect(red)
    assert Enum.all?(red, &(&1 =~ ~r/^[a-z-]+ (light|dark): Ask label .* \d+\.\d\d < 4\.5$/))
  end

  # ── structure ──────────────────────────────────────────────────────────

  test "--ag-text is never painted on base-300 in the meeting rules", %{
    ask_rules: ask,
    app_rules: app
  } do
    meeting_app =
      Enum.filter(app, &(&1.selector =~ ~r/meeting|candidate|agent-tile|transcript/))

    for r <- ask ++ meeting_app, r.body =~ ~r/color:\s*var\(--ag-text\)/ do
      refute r.body =~ ~r/background(?:-color)?:\s*var\(--color-base-300\)/, r.selector
    end

    # The rows that DO paint --ag-text sit on the Ask section's base-100.
    assert Enum.any?(ask, &(&1.selector == ".meeting-ask .nm" and &1.body =~ "var(--ag-text)"))

    [root] =
      Enum.filter(
        ask,
        &(&1.selector == ".meeting-ask" and &1.at == [] and &1.body =~ "background")
      )

    assert root.body =~ ~r/background:\s*var\(--color-base-100\)/

    # No meeting markup puts an agent name in --ag-text on a base-300 surface.
    for file <- @fill_files do
      src = File.read!(Path.join(@root, file))
      refute Regex.match?(~r/"[^"\n]*bg-base-300[^"\n]*text-ag[^"\n]*"/, src), file
    end
  end

  @state_selector ~r/\[data-(held|sent|kick|open|state|selected)|\[aria-(pressed|selected|current|checked)|:checked|--current|--shaping|--acting|--selected|--armed/

  test "--edge is never the only signal of a state", %{ask_rules: ask, app_rules: app} do
    state_rules =
      Enum.filter(
        ask ++ Enum.filter(app, &(&1.selector =~ "candidate")),
        &(&1.selector =~ @state_selector)
      )

    assert state_rules != [], "no state rules found: the clause would be vacuous"

    offenders =
      for r <- state_rules,
          colours =
            Regex.scan(~r/var\((--[a-z0-9-]+)\)/, r.body, capture: :all_but_first)
            |> List.flatten(),
          colours != [],
          Enum.all?(colours, &(&1 == "--edge")),
          do: r.selector

    assert offenders == []
  end
end
