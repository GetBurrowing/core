defmodule Platform.Design.AgentSlotTokensGuardTest do
  @moduledoc """
  Guards the agent identity slots (task 01a1557a, Burrow redesign 3, stage 1):
  for each of the ten `Platform.Agents.ColorPalette` slots, `--ag-<id>` (rail,
  avatar ring, pill border) and `--ag-<id>-text` (name and pill text) in every
  theme block, the per-block `--ag-tint-pct`, and app.css's one opaque tint
  declaration per slot. There is no hover tint (Saru's ruling, a recorded
  deviation from the masters' 14%): an agent row keeps its rest tint.

  What is held:

    * DECLARED. Every block (app.css's two Burrow daisyUI blocks and the eight
      in theme_presets.css) declares all 20 slot tokens and its strength
      itself; tints are declared once, in app.css, in the one opaque form;
      no hover strength or hover tint exists anywhere.
    * NAME ON TINT, PAINTED. `--ag-<id>-text` against the worst pixel two
      Chrome builds paint for the tint at the block's strength (8%) clears 4.5:1 (7:1 in high contrast, where the tint is 0% and
      so base-100 itself). Pixels come from `Platform.Design.PaintedMix`,
      which raises for a slot, ground or strength nobody painted.
    * RAIL. `--ag-<id>` clears 3:1 on base-100, base-200 and the painted tint.
    * METADATA ON TINT. `--subtle` (base-content at the block's own strength)
      composited over every candidate tint pixel, through
      `PaintedComposite.contrast_min/3`, clears 4.5:1, and base-content clears
      4.5:1 (7:1 in high contrast) on it.
    * HUE. Every rail and text value stays within 10 degrees OKLCH hue of the
      slot's value in THAT PRESET's dark block (Saru's ruling): "the same hue"
      across a preset's modes and surfaces.
    * SEPARATION (Saru's ruling, canvas 01a15b1e-d673 rev 5). One rule: no
      two rails of a block closer than delta E 4.5 (OKLab x100), in every
      block. Before stage 3 it failed only burrow-forest amber/orange
      (1.97 dark, 3.01 light: theme.js made forest's orange its gold
      accent), so forest orange moved. The hue reference for a slot moved
      in a dark block is the moved value.
    * NO EXEMPTION. No floor under 4.5 in this file, no exemption comment.
    * DEVIATIONS. Every value that differs from the masters' theme.js
      (prototype 01a137f2 v3) names the master value and both measurements:
      both contrast ratios for a text step, both hue drifts for a rail.
    * AGENT HUE NEVER ON AN ACTION OR A STATUS. Saru's canvas 01a15b1e-d673,
      verbatim: "An agent hue never appears on a button, link or focus ring."
      and "Error, warning and success states always carry an icon and words,
      never colour alone, so a rail never carries status." No stylesheet rule
      that styles a button, link, focus state or status chip reads `--ag-`.
    * THE CHAT SKIN READS ONLY THE SLOT (stage 2). One `[data-agent-slot]`
      pointer rule per ColorPalette slot, each pointing `--ag`, `--ag-text`
      and `--ag-tint` at that slot's own tokens; `.msg-agent` and its avatar,
      name and pill read only those and paint no literal colour; no theme-
      or scheme-specific `.msg-agent` override; no row-inner hover fill over
      the tint; no legacy `agent-accent` variable left anywhere. Stage 2 mutations: (a)
      restore `[data-theme="dark"] .msg-agent { background: #1c2531 }`; (b)
      drop the teal pointer; (c) `.msg-agent-name` to `var(--ag)`; (d) put
      the inline legacy accent variable back (also red in chat_message_test.exs).

  SCOPE. The blocks as app.css and theme_presets.css declare them. An install
  colour (`Platform.Branding.ThemeCss`) that overrides Burrow's base-100 moves
  the tint, and no such ground is painted here.

  The last test prints the masters' 12-row table per slot (120 rows; Burrow
  dark and Burrow light both resolve to the two Burrow blocks, so 100 are
  distinct).

  Named mutations (stage 1 commit): (a) Burrow light `--ag-purple-text` back
  to #805eb6; (b) delete one block's `--ag-lime`; (c) high-contrast dark
  `--ag-tint-pct` 0% to 8%; (d) drop one tie rounding from PaintedMix
  (painted_mix_test.exs); (e) move one value's hue 15 degrees. Each turns a
  test red.
  """
  use ExUnit.Case, async: true

  alias Platform.Agents.ColorPalette
  alias Platform.Design.PaintedComposite
  alias Platform.Design.PaintedMix
  alias Platform.Design.ThemeBlocks, as: T
  alias Platform.Design.WcagContrast, as: W

  @css_dir Path.expand("../../../assets/css", __DIR__)
  @lib_dir Path.expand("../../../lib", __DIR__)
  @modes ["dark", "light"]

  @aa 4.5
  @aaa 7.0
  @non_text 3.0
  @max_hue_drift 10.0
  # Saru's slot-separation rule (canvas 01a15b1e-d673 rev 5): no two rails of
  # one block closer than this in OKLab x100.
  @min_delta_e 4.5

  # Dark-block rails that deviate from theme.js. A light value's hue is held
  # against THESE, not the master, since they are what the dark block ships.
  @dark_moved %{{"burrow-forest", "orange"} => "#f47721"}

  @master_rest 8

  # theme.js (prototype 01a137f2 v3): BURROW_DARK / BURROW_LIGHT give all ten,
  # midnight overrides four, sand and forest override orange, high contrast
  # gives all ten.
  @burrow_dark %{
    "teal" => "#22d3ee",
    "green" => "#6bae75",
    "amber" => "#e5a33d",
    "orange" => "#f47721",
    "blue" => "#59bbfb",
    "purple" => "#c89eff",
    "brick" => "#ef806f",
    "rose" => "#fc90bc",
    "indigo" => "#86a4ff",
    "lime" => "#9fd959"
  }
  @burrow_light %{
    "teal" => "#0e7382",
    "green" => "#2d7638",
    "amber" => "#925d0c",
    "orange" => "#ad4b07",
    "blue" => "#1e74a6",
    "purple" => "#805eb6",
    "brick" => "#ae5548",
    "rose" => "#a85276",
    "indigo" => "#546aba",
    "lime" => "#4f7b00"
  }
  @masters %{
    {"burrow", "dark"} => @burrow_dark,
    {"burrow", "light"} => @burrow_light,
    {"burrow-midnight", "dark"} =>
      Map.merge(@burrow_dark, %{
        "teal" => "#4fd7ea",
        "green" => "#7cc98a",
        "amber" => "#f0b24a",
        "orange" => "#ff8a3d"
      }),
    {"burrow-midnight", "light"} =>
      Map.merge(@burrow_light, %{
        "teal" => "#0b6e7f",
        "green" => "#2a7036",
        "amber" => "#8d5a0a",
        "orange" => "#b4470a"
      }),
    {"burrow-sand", "dark"} => Map.put(@burrow_dark, "orange", "#e8842e"),
    {"burrow-sand", "light"} => Map.put(@burrow_light, "orange", "#9c4306"),
    {"burrow-forest", "dark"} => Map.put(@burrow_dark, "orange", "#f0a040"),
    {"burrow-forest", "light"} => Map.put(@burrow_light, "orange", "#a3500a"),
    {"high-contrast", "dark"} => %{
      "teal" => "#5ff0ff",
      "green" => "#8ef59a",
      "amber" => "#ffd060",
      "orange" => "#ff8c2a",
      "blue" => "#7cc8ff",
      "purple" => "#d9b8ff",
      "brick" => "#ff9a8a",
      "rose" => "#ffa8cc",
      "indigo" => "#a6bcff",
      "lime" => "#b8f070"
    },
    {"high-contrast", "light"} => %{
      "teal" => "#004f5c",
      "green" => "#0f5a1c",
      "amber" => "#6a4000",
      "orange" => "#8a3300",
      "blue" => "#005e8f",
      "purple" => "#69469c",
      "brick" => "#933d31",
      "rose" => "#8e3b60",
      "indigo" => "#3e52a0",
      "lime" => "#396300"
    }
  }

  @pct_form ~r/^(\d+)%$/
  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/
  @tint_selector ":root,\n[data-theme],\n[data-preset]"

  setup_all do
    app_css = File.read!(Path.join(@css_dir, "app.css"))
    presets = File.read!(Path.join(@css_dir, "theme_presets.css"))

    burrow =
      for mode <- @modes do
        b = T.burrow_block(app_css, mode)
        # "Itself": the daisyUI theme block's own declarations.
        Map.put(b, :own, T.strip_comments(b.raw))
      end

    blocks = burrow ++ Enum.map(T.preset_blocks(presets), &Map.put(&1, :own, &1.decls))
    {:ok, app_css: app_css, presets: presets, blocks: blocks}
  end

  # ── declared ─────────────────────────────────────────────────────────────

  test "ten blocks, and the slot ids are exactly ColorPalette's", %{blocks: blocks} do
    assert Enum.map(blocks, &{&1.id, &1.mode}) |> Enum.sort() == Map.keys(@masters) |> Enum.sort()
    assert Enum.sort(ColorPalette.ids()) == Enum.sort(Map.keys(@burrow_dark))
  end

  test "every block declares all 20 slot tokens and its strength itself", %{blocks: blocks} do
    missing =
      for b <- blocks,
          token <- ["--ag-tint-pct" | slot_tokens()],
          T.declaration(b.own, token) == nil,
          do: "#{b.id} #{b.mode}: #{token}"

    assert missing == [], "not declared in the block:\n  " <> Enum.join(missing, "\n  ")

    extra =
      for b <- blocks,
          [_, id] <- Regex.scan(~r/^\s*--ag-([a-z]+)(?:-text)?\s*:/m, b.own),
          id not in ColorPalette.ids(),
          do: "#{b.id} #{b.mode}: --ag-#{id}"

    assert extra == [], "slot tokens for no ColorPalette id: #{inspect(extra)}"
  end

  test "a text token is a colour or exactly var(--ag-<id>)", %{blocks: blocks} do
    odd =
      for b <- blocks,
          id <- ColorPalette.ids(),
          v = T.declaration(b.own, "--ag-#{id}-text"),
          v != "var(--ag-#{id})" and not Regex.match?(~r/^#[0-9a-f]{6}$/, v),
          do: "#{b.id} #{b.mode}: --ag-#{id}-text: #{v}"

    assert odd == []
  end

  test "high contrast's tint is 0%; every other block keeps the masters' #{@master_rest}%",
       %{blocks: blocks} do
    for b <- blocks do
      want = if b.id == "high-contrast", do: 0, else: @master_rest
      assert pct(b) == want, "#{b.id} #{b.mode}: --ag-tint-pct #{pct(b)}%, want #{want}%"
    end
  end

  test "no hover tint: no hover strength or hover tint token, and the deviation is recorded",
       %{app_css: app_css, presets: presets} do
    for {name, css} <- [{"app.css", app_css}, {"theme_presets.css", presets}] do
      refute T.strip_comments(css) =~ ~r/--ag-[a-z-]*hover/,
             "#{name} declares an agent hover token"
    end

    [comment] = Regex.run(~r{/\* Agent slot tints.*?\*/}s, app_css)
    assert comment =~ "NO HOVER TINT (design deviation"
    assert comment =~ ".m:hover"
    assert comment =~ "14%"
  end

  test "the tints are declared once, in app.css, as an opaque mix with base-100",
       %{app_css: app_css, presets: presets} do
    [body] = T.blocks_after(app_css, "\n" <> @tint_selector <> " {")
    body = T.strip_comments(body)

    for id <- ColorPalette.ids() do
      assert T.declaration(body, "--ag-#{id}-tint") ==
               "color-mix(in srgb, var(--ag-#{id}) var(--ag-tint-pct), var(--color-base-100))"
    end

    decls = Regex.scan(~r/^\s*--ag-[a-z]+-tint\s*:/m, T.strip_comments(app_css))
    assert length(decls) == 10, "a tint is declared outside the one rule"
    refute T.strip_comments(presets) =~ ~r/--ag-[a-z]+-tint\s*:/
  end

  test "no slot value lives outside the token blocks", %{app_css: app_css} do
    # The only --ag- colour declarations in app.css are inside its two plugin blocks.
    outside =
      app_css
      |> T.strip_comments()
      |> then(&Regex.replace(~r/@plugin "..\/vendor\/daisyui-theme" \{.*?\n\}/s, &1, ""))
      |> then(&Regex.scan(~r/--ag-[a-z]+(?:-text)?\s*:\s*#[0-9a-fA-F]+/, &1))

    assert outside == []
  end

  # ── painted contrast ─────────────────────────────────────────────────────

  test "name on tint: --ag-<id>-text clears 4.5:1 (7:1 high contrast) on the painted tint",
       %{blocks: blocks} do
    failures =
      for b <- blocks,
          id <- ColorPalette.ids(),
          {label, p} <- strengths(b),
          r = name_on_tint(b, id, p),
          r < target(b),
          do: "#{b.id} #{b.mode} #{id} on #{label} (#{p}%): #{fixed4(r)}:1 < #{target(b)}"

    assert failures == [], Enum.join(failures, "\n")
  end

  test "rail: --ag-<id> clears 3:1 on base-100, base-200 and the painted tint",
       %{blocks: blocks} do
    failures =
      for b <- blocks,
          id <- ColorPalette.ids(),
          r = rail_min(b, id),
          r < @non_text,
          do: "#{b.id} #{b.mode} #{id}: #{fixed4(r)}:1"

    assert failures == [], Enum.join(failures, "\n")
  end

  test "metadata on tint: --subtle and base-content clear their floors on every painted tint pixel",
       %{blocks: blocks} do
    failures =
      for b <- blocks,
          id <- ColorPalette.ids(),
          {subtle_min, ink_min} <- [metadata_min(b, id)],
          problem <- [
            subtle_min < @aa && "--subtle #{fixed4(subtle_min)}:1",
            ink_min < target(b) && "base-content #{fixed4(ink_min)}:1"
          ],
          is_binary(problem),
          do: "#{b.id} #{b.mode} #{id}: #{problem}"

    assert failures == [], Enum.join(failures, "\n")
  end

  test "hue: every rail and text value is within #{@max_hue_drift} degrees of its preset's dark value",
       %{blocks: blocks} do
    failures =
      for b <- blocks,
          id <- ColorPalette.ids(),
          token <- ["--ag-#{id}", "--ag-#{id}-text"],
          d = hue_drift(b, id, token),
          d > @max_hue_drift,
          do: "#{b.id} #{b.mode} #{token}: #{fixed2(d)} degrees"

    assert failures == [], Enum.join(failures, "\n")
  end

  test "the guard measures only painted combinations: an unpainted value raises", %{
    blocks: blocks
  } do
    b = Enum.find(blocks, &(&1.id == "burrow" and &1.mode == "light"))
    # Repaint-free change of the rail: one byte off purple.
    shifted = %{
      b
      | decls: String.replace(b.decls, "--ag-purple: #805eb6", "--ag-purple: #805eb7")
    }

    assert_raise ArgumentError, ~r/no painted row/, fn -> name_on_tint(shifted, "purple", 8) end

    assert_raise ArgumentError, ~r/no browser has been painted/, fn ->
      name_on_tint(b, "purple", 20)
    end
  end

  test "the shipped token pixels were painted at each block's declared strengths", %{
    blocks: blocks
  } do
    painted =
      for row <- PaintedMix.fixture_rows(),
          row.file =~ "_tokens",
          into: MapSet.new(),
          do: {row.build, row.ink, row.ground, row.strength}

    missing =
      for b <- blocks,
          id <- ColorPalette.ids(),
          {_label, p} <- strengths(b),
          build <- PaintedMix.builds(),
          key = {build, bytes(b, "--ag-#{id}"), bytes(b, "--color-base-100"), p},
          not MapSet.member?(painted, key),
          do: "#{build}: #{b.id} #{b.mode} #{id} at #{p}%"

    assert missing == [],
           "the shipped tints were not repainted after a change:\n" <> Enum.join(missing, "\n")
  end

  # ── no exemption, deviations ─────────────────────────────────────────────

  test "no exemption: no comment declares one and no floor here is below 4.5",
       %{app_css: app_css, presets: presets} do
    for {name, text} <- [{"app.css", app_css}, {"theme_presets.css", presets}] do
      refute text =~ ~r/\bEXEMPT/, "#{name} declares a contrast EXEMPTION"
    end

    src = File.read!(__ENV__.file)
    detector = ~r/(?:=>|@\w+)\s+(4\.[0-4]\d*)\b/
    assert Regex.scan(detector, src) == []

    # The detector fires on a floor in this shape. (Assembled so this file's
    # own source does not match.)
    assert Regex.match?(detector, "@floor " <> Float.to_string(4.34))
  end

  test "every value that differs from theme.js names the master value and both ratios",
       %{blocks: blocks} do
    failures =
      for b <- blocks, id <- ColorPalette.ids(), problem <- deviation_problems(b, id) do
        "#{b.id} #{b.mode} #{id}: #{problem}"
      end

    assert failures == [], Enum.join(failures, "\n")
  end

  # ── agent hue never on an action or a status ─────────────────────────────

  @forbidden ~r/\.btn\b|(?:^|[\s,>+~(])a(?:[\s,:.\[>+~)]|$)|:focus|ring-focus|focus-ring|\b(?:success|warning|error|info)\b|\balert\b/

  test "no rule that styles a button, link, focus state or status chip reads --ag-" do
    offenders =
      for file <- Path.wildcard(Path.join(@css_dir, "*.css")),
          {sel, body} <- innermost_rules(File.read!(file)),
          body =~ "--ag-",
          Regex.match?(@forbidden, sel),
          do: "#{Path.basename(file)}: #{sel}"

    assert offenders == [], Enum.join(offenders, "\n")

    # The detector fires on each forbidden shape.
    for sel <- [".btn-primary", "a:hover", ".msg a", "button:focus-visible", ".badge-error"] do
      assert Regex.match?(@forbidden, sel), sel
    end

    for sel <- [".msg-agent", ".msg-agent-name", "[data-agent-slot=\"teal\"]", ".avatar"] do
      refute Regex.match?(@forbidden, sel), sel
    end
  end

  test "no markup puts an --ag- token on a button, link or focus class" do
    offenders =
      for file <- Path.wildcard(Path.join(@lib_dir, "**/*.{ex,heex}")),
          {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ "--ag-",
          line =~ ~r/\bbtn\b|<a\b|<\.link\b|<button\b|focus|ring-/,
          do: "#{Path.relative_to(file, @lib_dir)}:#{n}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # ── the chat skin reads only the slot (stage 2) ──────────────────────────

  @pointer_selector ~r/^\[data-agent-slot="([a-z]+)"\]$/
  @literal_colour ~r/#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|oklch|oklab|lab|lch)\(|\b(?:white|black)\b/

  test "one pointer rule per ColorPalette slot, each pointing at that slot's own tokens",
       %{app_css: app_css} do
    pointers =
      for {sel, body} <- innermost_rules(app_css),
          [_, id] <- [Regex.run(@pointer_selector, sel)],
          do: {id, body}

    assert pointers |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.sort(ColorPalette.ids()),
           "pointer rules #{inspect(Enum.map(pointers, &elem(&1, 0)))} != ColorPalette slots"

    for {id, body} <- pointers do
      decls =
        Regex.scan(~r/(--[a-z-]+)\s*:\s*([^;]+);?/, body, capture: :all_but_first)
        |> Map.new(fn [k, v] -> {k, String.trim(v)} end)

      assert decls == %{
               "--ag" => "var(--ag-#{id})",
               "--ag-text" => "var(--ag-#{id}-text)",
               "--ag-tint" => "var(--ag-#{id}-tint)"
             },
             "[data-agent-slot=#{id}] declares #{inspect(decls)}"
    end

    # No other rule anywhere sets the row-local pointers.
    stray =
      for file <- Path.wildcard(Path.join(@css_dir, "*.css")),
          {sel, body} <- innermost_rules(File.read!(file)),
          body =~ ~r/(?:^|[;{\s])--ag(?:-text|-tint)?\s*:/,
          not Regex.match?(@pointer_selector, sel),
          do: "#{Path.basename(file)}: #{sel}"

    assert stray == [],
           "a rule sets --ag/--ag-text/--ag-tint outside the pointers: #{inspect(stray)}"
  end

  test "the .msg-agent skin reads only the slot pointers and sets no literal colour",
       %{app_css: app_css} do
    rules = for {sel, body} <- innermost_rules(app_css), sel =~ "msg-agent", do: {sel, body}

    want = %{
      ".msg-agent" => [{"border-left", "3px solid var(--ag)"}, {"background", "var(--ag-tint)"}],
      ".msg-agent-avatar" => [{"box-shadow", "0 0 0 2px var(--ag)"}],
      ".msg-agent-name" => [{"color", "var(--ag-text)"}, {"font-weight", "600"}],
      ".msg-agent-badge" => [
        {"color", "var(--ag-text)"},
        {"border", "1px solid var(--ag)"},
        {"background", "transparent"},
        {"font-size", "11px"},
        {"font-weight", "500"},
        {"text-transform", "uppercase"}
      ]
    }

    for {sel, pairs} <- want do
      [body] = for {^sel, body} <- rules, do: body

      for {prop, value} <- pairs do
        assert T.declaration(body, prop) == value, "#{sel} #{prop}: #{T.declaration(body, prop)}"
      end
    end

    literal =
      for {sel, body} <- rules,
          not (sel =~ ":not(.msg-agent)"),
          Regex.match?(@literal_colour, body),
          do: sel

    assert literal == [], "a .msg-agent rule paints a literal colour: #{inspect(literal)}"

    # The detector fires on the shapes it exists for.
    for body <- ["background: #1c2531", "color: rgb(0 0 0)", "x: oklch(82% 0.12 207)"] do
      assert Regex.match?(@literal_colour, body), body
    end

    # No theme- or scheme-specific .msg-agent override: the tokens already
    # differ per block, and an override would paint an unmeasured ground.
    refute T.strip_comments(app_css) =~ ~r/\[data-theme[^\]]*\][^{,]*\.msg-agent\b/
    refute T.strip_comments(app_css) =~ ~r/:root:not\(\[data-theme="light"\]\)\s+\.msg-agent\b/
  end

  test "an agent row draws no row-inner hover fill over its tint (Saru's ruling)",
       %{app_css: app_css} do
    [body] =
      for {sel, body} <- innermost_rules(app_css),
          sel == ".msg-agent > .message-row-inner,\n.msg-agent > .message-row-inner:hover",
          do: body

    assert T.declaration(body, "background-color") == "transparent"
  end

  test "no legacy agent-accent variable remains in the stylesheets or the markup" do
    files =
      Path.wildcard(Path.join(@css_dir, "*.css")) ++
        Path.wildcard(Path.join(@lib_dir, "**/*.{ex,heex}"))

    hits = for f <- files, File.read!(f) =~ "--agent-" <> "accent", do: f
    assert hits == []
  end

  # ── the table ────────────────────────────────────────────────────────────

  test "the 12-row x 10-slot table: every master variant passes", %{blocks: blocks} do
    rows =
      for(
        master <- ["burrow-dark", "burrow-light"],
        mode <- @modes,
        do: {"#{master} #{mode}", find(blocks, "burrow", mode)}
      ) ++
        for id <- ["burrow-midnight", "burrow-sand", "high-contrast", "burrow-forest"],
            mode <- @modes do
          {"#{id} #{mode}", find(blocks, id, mode)}
        end

    assert length(rows) == 12

    lines =
      for {label, b} <- rows, id <- ColorPalette.ids() do
        p = pct(b)
        {subtle_min, ink_min} = metadata_min(b, id)
        text = T.declaration(b.own, "--ag-#{id}-text")

        "| #{label} | #{id} | #{hexs(b, "--ag-#{id}")} | #{hexs(b, "--ag-#{id}-text")}" <>
          if(String.starts_with?(text, "var("), do: " (rail)", else: " (step)") <>
          " | #{p}% | #{fixed2(name_on_tint(b, id, p))} | #{fixed2(rail_min(b, id))} | " <>
          "#{fixed2(subtle_min)} | #{fixed2(ink_min)} | " <>
          "#{fixed2(max(hue_drift(b, id, "--ag-#{id}"), hue_drift(b, id, "--ag-#{id}-text")))} | " <>
          "#{fixed2(target(b))} | pass |"
      end

    assert length(lines) == 120

    drift =
      for id <- ColorPalette.ids() do
        max =
          for(b <- blocks, t <- ["--ag-#{id}", "--ag-#{id}-text"], do: hue_drift(b, id, t))
          |> Enum.max()

        "#{id} #{fixed2(max)}"
      end

    IO.puts(
      "\nAgent slot AA table (painted tints, worst pixel over Chrome 147 + 151; " <>
        "hue drift from the preset's own dark value):\n" <>
        "| Variant | slot | rail | text | tint | name on tint | rail min | " <>
        "subtle on tint | ink on tint | hue drift | target | verdict |\n" <>
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|\n" <>
        Enum.join(lines, "\n") <>
        "\nMax hue drift from the preset's own dark value, per slot (degrees): " <>
        Enum.join(drift, ", ")
    )
  end

  # ── separation (stage 3) ─────────────────────────────────────────────────

  test "separation: no two rails of a block are closer than delta E #{@min_delta_e}",
       %{blocks: blocks} do
    failures =
      for b <- blocks,
          {d, x, y} <- pairs(b),
          d < @min_delta_e,
          do: "#{b.id} #{b.mode} #{x}/#{y}: delta E #{fixed2(d)}"

    assert failures == [], Enum.join(failures, "\n")
  end

  test "separation: the floor fires on the masters' forest values" do
    # Positive control: theme.js's own forest rails are what the floor exists
    # for, so they must fail it.
    for mode <- @modes do
      m = Map.fetch!(@masters, {"burrow-forest", mode})
      d = delta_e(W.hex(m["amber"]), W.hex(m["orange"]))
      assert d < @min_delta_e, "#{mode}: masters' forest amber/orange #{fixed2(d)}"
    end
  end

  test "a moved dark rail is what its dark block declares", %{blocks: blocks} do
    for {{id, slot}, value} <- @dark_moved do
      b = find(blocks, id, "dark")
      assert String.downcase(T.declaration(b.own, "--ag-#{slot}")) == value
    end
  end

  test "the separation table: closest pair and amber/orange per block", %{blocks: blocks} do
    lines =
      for b <- blocks do
        [{d, x, y} | _] = pairs(b)
        ao = delta_e(color(b, "--ag-amber"), color(b, "--ag-orange"))
        "| #{b.id} #{b.mode} | #{x}/#{y} #{fixed2(d)} | amber/orange #{fixed2(ao)} |"
      end

    IO.puts("\nRail separation (delta E, OKLab x100):\n" <> Enum.join(lines, "\n"))
  end

  # ── meeting surfaces (stage 3) ───────────────────────────────────────────

  # The Ask row follows the PAGE theme (rung 18): meeting_ask.css declares no
  # slot and no ground of its own, so each block's own slots are measured on
  # the grounds the Ask row paints. The name and initials (--ag-<id>-text)
  # sit only on base-100, the section ground: the base-300 confirm row covers
  # the row it confirms, and the popover header is base-content. The rail
  # (--ag-<id>) is measured on base-100 and base-300. Measured, not assumed:
  # --ag-<id>-text on base-300 is under 4.5:1 in every light block (4.01 to
  # 4.44), which is why no rule may paint the name on base-300.
  @ask_text_grounds ["--color-base-100"]
  @ask_grounds ["--color-base-100", "--color-base-300"]

  test "ask surface: meeting_ask.css declares no slot, no palette and paints base-100" do
    css = T.strip_comments(File.read!(Path.join(@css_dir, "meeting_ask.css")))
    refute css =~ ~r/--ag-[a-z]+(?:-text)?\s*:/
    refute css =~ ~r/--(?:bg|s|s2|b|t|m|a|ai|live|ok|bad)\s*:/

    [root] =
      for {".meeting-ask", body} <- innermost_rules(css), body =~ "background:", do: body

    assert root =~ "background:var(--color-base-100)"
    assert root =~ "color:var(--color-base-content)"
  end

  test "ask surface: --ag-<id>-text clears 4.5:1 (7:1 high contrast) on base-100 and --ag-<id> 3:1 on base-100 and base-300",
       %{blocks: blocks} do
    pairs =
      for(id <- ColorPalette.ids(), g <- @ask_text_grounds, do: {"--ag-#{id}-text", g, :text}) ++
        for id <- ColorPalette.ids(), g <- @ask_grounds, do: {"--ag-#{id}", g, :rail}

    failures =
      for b <- blocks,
          {token, ground, kind} <- pairs,
          floor = if(kind == :text, do: target(b), else: @non_text),
          r = W.contrast(color(b, token), color(b, ground)),
          r < floor,
          do: "ask surface #{b.id} #{b.mode} #{token} on #{ground}: #{fixed4(r)}:1 < #{floor}"

    assert failures == [], Enum.join(failures, "\n")
  end

  # Tile chip: on-viewer 10px name text on `bg-viewer/60` (agent_tile.ex) over
  # the tile's painted tint. 60% is a painted strength, so every pixel the
  # measured formulas allow is checked. High contrast paints the band as the
  # opaque viewer ground (app.css), because 60% over its white base-100 gives
  # 5.74:1, under the 7:1 name-text floor there.
  @chip_strength 60

  test "tile chip: on-viewer name text clears 4.5:1 on viewer at 60% over every painted tint",
       %{blocks: blocks} do
    failures =
      for b <- blocks,
          b.id != "high-contrast",
          id <- ColorPalette.ids(),
          r = chip_min(b, id),
          r < target(b),
          do: "#{b.id} #{b.mode} #{id}: #{fixed4(r)}:1"

    assert failures == [], Enum.join(failures, "\n")
  end

  test "tile chip: high contrast paints the band as the opaque viewer ground (21:1)",
       %{app_css: app_css, blocks: blocks} do
    [body] =
      for {sel, body} <- innermost_rules(app_css),
          sel == ~s([data-preset="high-contrast"] .agent-tile-chip),
          do: body

    assert T.declaration(body, "background-color") == "var(--viewer)"

    for b <- blocks, b.id == "high-contrast" do
      assert W.contrast(color(b, "--on-viewer"), color(b, "--viewer")) >= @aaa
    end

    tile = File.read!(Path.join(@lib_dir, "platform_web/components/meeting/agent_tile.ex"))
    assert tile =~ ~s(class="agent-tile-chip absolute inset-x-0 bottom-0 bg-viewer/60 )
    assert tile =~ "font-medium text-on-viewer"
    refute tile =~ "from-black"
    refute tile =~ "bg-black"
  end

  # The masters paint the tile waveform in --ag (burrow-meeting.js `.bm-wave`).
  # At the bars' 60% that is under 3:1 on the tint (2.24:1, Burrow light
  # indigo), so the bars stay base-content (rung 18, recorded deviation).
  test "tile waveform: base-content bars at 60% clear 3:1 on every painted tint",
       %{blocks: blocks, app_css: app_css} do
    refute app_css =~ "[data-voice-waveform] {\n  color: var(--ag)"

    failures =
      for b <- blocks,
          id <- ColorPalette.ids(),
          r = wave_min(b, id),
          r < @non_text,
          do: "#{b.id} #{b.mode} #{id}: #{fixed4(r)}:1"

    assert failures == [], Enum.join(failures, "\n")
  end

  test "the meeting tile reads only the slot pointers and composes the speaking ring",
       %{app_css: app_css} do
    rules = innermost_rules(app_css)
    [tile] = for {".meeting-agent-tile[data-agent-slot]", body} <- rules, do: body
    assert T.declaration(tile, "background") == "var(--ag-tint)"
    assert tile =~ "inset 3px 0 0 var(--ag)"
    assert tile =~ "var(--tw-ring-shadow"
    refute Regex.match?(@literal_colour, Regex.replace(~r/0 0 #0000/, tile, ""))

    [ring] = for {".meeting-agent-tile[data-agent-slot] .agent-tile-avatar", b} <- rules, do: b
    assert T.declaration(ring, "box-shadow") == "0 0 0 2px var(--ag)"
  end

  test "the meeting table: ask surface, tile chip and waveform minima", %{blocks: blocks} do
    IO.puts(
      "\nAsk surface (page slots), tile chip (on-viewer on viewer 60% over the tint; HC is " <>
        "opaque viewer) and waveform (base-content 60% on the tint), minimum over slots and pixels:\n" <>
        Enum.map_join(blocks, "\n", fn blk ->
          ask =
            for id <- ColorPalette.ids(),
                g <- @ask_text_grounds,
                do: W.contrast(color(blk, "--ag-#{id}-text"), color(blk, g))

          chip =
            if blk.id == "high-contrast",
              do: "21.00 (opaque)",
              else: fixed4(Enum.min(for id <- ColorPalette.ids(), do: chip_min(blk, id)))

          wave = fixed4(Enum.min(for id <- ColorPalette.ids(), do: wave_min(blk, id)))

          "| #{blk.id} #{blk.mode} | ask text #{fixed4(Enum.min(ask))} | chip #{chip} | " <>
            "waveform #{wave} |"
        end)
    )
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp chip_min(b, id) do
    for px <- tint_pixels(b, id, pct(b)),
        f <- PaintedComposite.formulas(),
        band = PaintedComposite.paint(f, bytes(b, "--viewer"), px, @chip_strength) do
      W.contrast(color(b, "--on-viewer"), PaintedMix.from_bytes(band))
    end
    |> Enum.min()
  end

  defp wave_min(b, id) do
    ink = color(b, "--color-base-content")

    for px <- tint_pixels(b, id, pct(b)) do
      {r, _} = PaintedComposite.contrast_min(ink, PaintedMix.from_bytes(px), @chip_strength)
      r
    end
    |> Enum.min()
  end

  defp delta_e(c1, c2) do
    {l1, a1, b1} = W.to_oklab(c1)
    {l2, a2, b2} = W.to_oklab(c2)
    100 * :math.sqrt((l1 - l2) ** 2 + (a1 - a2) ** 2 + (b1 - b2) ** 2)
  end

  # Every pair of rails in a block, closest first.
  defp pairs(b) do
    for(
      {x, i} <- Enum.with_index(ColorPalette.ids()),
      {y, j} <- Enum.with_index(ColorPalette.ids()),
      i < j,
      do: {delta_e(color(b, "--ag-#{x}"), color(b, "--ag-#{y}")), x, y}
    )
    |> Enum.sort()
  end

  # The master value fails the separation floor in this block: `{other, delta E}`
  # of its closest offending pair, or nil.
  defp separation_miss(b, id, master) do
    for other <- ColorPalette.ids(),
        other != id,
        d = delta_e(W.hex(master), color(b, "--ag-#{other}")),
        d < @min_delta_e do
      {other, d}
    end
    |> Enum.min_by(&elem(&1, 1), fn -> nil end)
  end

  defp slot_tokens, do: for(id <- ColorPalette.ids(), s <- ["", "-text"], do: "--ag-#{id}#{s}")

  defp find(blocks, id, mode), do: Enum.find(blocks, &(&1.id == id and &1.mode == mode))

  defp target(%{id: "high-contrast"}), do: @aaa
  defp target(_), do: @aa

  defp pct(b), do: pct(b, "--ag-tint-pct")

  defp pct(b, token) do
    value = T.declaration(b.own, token) || flunk("#{b.id} #{b.mode}: no #{token}")

    case Regex.run(@pct_form, value) do
      [_, n] -> String.to_integer(n)
      nil -> flunk("#{b.id} #{b.mode}: #{token} is #{inspect(value)}, not an integer percent")
    end
  end

  defp strengths(b), do: [{"tint", pct(b)}]

  defp color(b, token), do: T.resolve!(b, token)
  defp bytes(b, token), do: PaintedMix.bytes(color(b, token))
  defp hexs(b, token), do: "#" <> PaintedMix.hex(bytes(b, token))

  defp tint_pixels(b, id, p),
    do: PaintedMix.painted!(bytes(b, "--ag-#{id}"), bytes(b, "--color-base-100"), p)

  defp name_on_tint(b, id, p),
    do:
      PaintedMix.text_min(
        color(b, "--ag-#{id}-text"),
        color(b, "--ag-#{id}"),
        color(b, "--color-base-100"),
        p
      )

  defp rail_min(b, id) do
    rail = color(b, "--ag-#{id}")
    grounds = [color(b, "--color-base-100"), color(b, "--color-base-200")]

    Enum.min(
      Enum.map(grounds, &W.contrast(rail, &1)) ++
        for(
          {_l, p} <- strengths(b),
          do: PaintedMix.text_min(rail, rail, color(b, "--color-base-100"), p)
        )
    )
  end

  # {min --subtle on any tint pixel, min base-content on any tint pixel}.
  defp metadata_min(b, id) do
    ink = color(b, "--color-base-content")
    strength = subtle_strength(b)

    pixels = for {_l, p} <- strengths(b), px <- tint_pixels(b, id, p), uniq: true, do: px

    subtle =
      pixels
      |> Enum.map(fn px ->
        {r, _} = PaintedComposite.contrast_min(ink, PaintedMix.from_bytes(px), strength)
        r
      end)
      |> Enum.min()

    full = pixels |> Enum.map(&W.contrast(ink, PaintedMix.from_bytes(&1))) |> Enum.min()
    {subtle, full}
  end

  defp subtle_strength(b) do
    value = T.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, n] -> String.to_integer(n)
      nil -> flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}")
    end
  end

  defp hue_drift(b, id, token), do: hue_drift_of(color(b, token), b, id)

  defp hue_drift_of(c, b, id) do
    d = abs(hue(c) - hue(W.hex(reference(b, id))))
    if d > 180, do: 360 - d, else: d
  end

  # The slot's value in this preset's own dark block: theme.js's, unless the
  # dark block moved it (`@dark_moved`).
  defp reference(b, id),
    do:
      Map.get(@dark_moved, {b.id, id}) || @masters |> Map.fetch!({b.id, "dark"}) |> Map.fetch!(id)

  defp hue(c) do
    {_l, a, bb} = W.to_oklab(c)
    deg = :math.atan2(bb, a) * 180 / :math.pi()
    if deg < 0, do: deg + 360, else: deg
  end

  defp deviation_problems(b, id) do
    master = @masters |> Map.fetch!({b.id, b.mode}) |> Map.fetch!(id)
    rail = T.declaration(b.own, "--ag-#{id}")
    text = T.declaration(b.own, "--ag-#{id}-text")

    rail_problems =
      cond do
        String.downcase(rail) == master ->
          []

        sep = separation_miss(b, id, master) ->
          {other, master_de} = sep
          new_de = delta_e(color(b, "--ag-#{id}"), color(b, "--ag-#{other}"))

          [
            not String.contains?(
              b.raw,
              "theme.js #{master} is delta E #{fixed2(master_de)} from --ag-#{other}"
            ) &&
              "--ag-#{id}: no comment naming theme.js #{master} at delta E #{fixed2(master_de)} from --ag-#{other}",
            not String.contains?(
              b.raw,
              "delta E #{fixed2(new_de)} from --ag-#{other}. */\n  --ag-#{id}:"
            ) &&
              "--ag-#{id}: comment does not record its own delta E #{fixed2(new_de)} from --ag-#{other}"
          ]

        true ->
          master_d = hue_drift_of(W.hex(master), b, id)
          new_d = hue_drift(b, id, "--ag-#{id}")

          [
            not String.contains?(b.raw, "theme.js #{master} is #{fixed2(master_d)} degrees") &&
              "--ag-#{id}: no comment naming theme.js #{master} at #{fixed2(master_d)} degrees",
            not String.contains?(b.raw, "#{fixed2(new_d)} degrees. */\n  --ag-#{id}:") &&
              "--ag-#{id}: comment does not record its own #{fixed2(new_d)} degrees",
            master_d <= @max_hue_drift &&
              "--ag-#{id} moves off theme.js #{master}, which is already the same hue"
          ]
      end

    text_problems =
      if text == "var(--ag-#{id})" do
        []
      else
        master_r = master_name_min(b, id, master)
        new_r = Enum.min(for {_l, p} <- strengths(b), do: name_on_tint(b, id, p))

        [
          not String.contains?(b.raw, "theme.js #{master} measures #{fixed4(master_r)}:1") &&
            "--ag-#{id}-text: no comment naming theme.js #{master} at #{fixed4(master_r)}:1",
          not String.contains?(b.raw, "measures #{fixed4(new_r)}:1. */\n  --ag-#{id}-text:") &&
            "--ag-#{id}-text: comment does not record its own #{fixed4(new_r)}:1",
          master_r >= target(b) &&
            "--ag-#{id}-text steps off theme.js #{master}, which already clears (#{fixed4(master_r)}:1)"
        ]
      end

    Enum.filter(rail_problems ++ text_problems, &is_binary/1)
  end

  defp master_name_min(b, id, master) do
    for(
      {_l, p} <- strengths(b),
      do:
        PaintedMix.text_min(
          W.hex(master),
          color(b, "--ag-#{id}"),
          color(b, "--color-base-100"),
          p
        )
    )
    |> Enum.min()
  end

  defp innermost_rules(css) do
    css
    |> T.strip_comments()
    |> then(&Regex.scan(~r/([^{}]+)\{([^{}]*)\}/, &1, capture: :all_but_first))
    |> Enum.map(fn [sel, body] -> {String.trim(sel), body} end)
  end

  defp fixed4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)
  defp fixed2(r), do: :erlang.float_to_binary(r / 1, decimals: 2)
end
