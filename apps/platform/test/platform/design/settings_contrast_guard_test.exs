defmodule Platform.Design.SettingsContrastGuardTest do
  @moduledoc """
  Holds the Settings screen's paint (task 01a1557a-e538 stages 3 and 4,
  `PlatformWeb.SettingsLive`) in all ten preset variants (Burrow, Midnight,
  Sand, Forest, High contrast; light and dark).

  ## Pairs and floors

  | pair                                                              | floor |
  |-------------------------------------------------------------------|-------|
  | h1, row labels, profile name: base-content on base-200            | 4.5   |
  | the same on base-100 (pressed row; sheet rows)                    | 4.5   |
  | values, helpers, labels, email, blocked line: --subtle on base-200 | 4.5   |
  | the same on base-100 (painted)                                    | 4.5   |
  | subscribe-failed line: its text slot on base-100 (the sheet)      | 4.5   |
  | back chevron: --subtle on base-200                                | 3     |
  | switch ON track: its slot vs base-200 and vs base-100             | 3     |
  | switch ON knob: its slot on the ON track slot                     | 3     |
  | switch OFF track: its slot vs base-200 and vs base-100            | 3     |
  | switch OFF knob: its slot on the OFF track (over each ground)     | 3     |
  | selected radio dot: its slot on base-100                          | 3     |
  | unselected radio ring: its slot on base-100                       | 3     |

  Every slot in that table is READ from the class source of
  `settings_live.ex` (track, knob, radio ring and dot, the failed line, the
  root ground and the pressed state), so a slot edit the guard does not follow
  goes red rather than passing on a stale assumption.

  `--subtle` is `color-mix(in oklab, base-content N%, transparent)`: alpha
  over whatever is under it. Every pair it is in, including the OFF track
  (`bg-subtle`) and the unselected ring (`border-subtle`), is PAINTED: the
  worst pixel `Platform.Design.PaintedComposite` allows, never derived. The
  OFF knob sits on that painted track, so it is measured against every pixel
  the formulas allow for the track over each ground. Opaque tokens use
  `WcagContrast.contrast/2`. The table prints.

  ## The row chevrons have no floor (WCAG 1.4.11)

  1.4.11 asks 3:1 of graphical objects "required to understand the content".
  A row's chevron is not: the row's label names the action, and the chevron
  is `aria-hidden` (asserted from source below), decorative by construction.
  The BACK chevron is different: it is the only visible content of its button
  (its name is an aria-label), so it is required and is held at 3.

  ## Hypotheses (planner estimates), with verdicts measured and printed

    * H-on-track: primary vs base-200 is the tightest switch pair, likeliest
      to fail in sand light.
    * H-error: error on base-100 fails in at least one light variant.
    * H-subtle: --subtle on base-200 is the tightest text pair.

  ## Structure (anti-vacuity first)

  `settings_live.ex` is read and shown to be the Settings screen (non-empty,
  contains `id="settings"`) before anything is refuted in it. Then: no
  `text-base-content/`, no hex literal, no `[data-theme` selector, no
  `hover:`, no `text-[Npx]` under 12; the row class presses to base-100 on a
  base-200 root; no element names `text-error` (see the fallback below).

  ## Fallback applied (measured, task 01a1557a-e538 stage 5)

  The subscribe-failed line was `text-error`. Error on base-100 measured
  3.7360 (burrow light), 4.4233 (burrow dark), 4.4474 (midnight dark),
  4.2857 (sand dark) and 4.3921 (forest dark), all under 4.5. By the stage's
  named fallback the line is `text-base-content`: its words carry the
  meaning. The guard still reads the line's slot and measures it.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.PaintedComposite, as: PC
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @settings_path Path.expand("../../../lib/platform_web/live/settings_live.ex", __DIR__)
  @state_path Path.expand(
                "../../../lib/platform_web/components/notification_state.ex",
                __DIR__
              )

  @aa_text 4.5
  @aa_ui 3.0

  @ground "--color-base-200"
  @raised "--color-base-100"

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

  setup_all do
    app_css = File.read!(@app_css_path)
    presets = File.read!(@presets_path)

    by_key =
      Map.new(Blocks.preset_blocks(presets), &{{&1.id, &1.mode}, &1})
      |> Map.put({"burrow", "light"}, Blocks.burrow_block(app_css, "light"))
      |> Map.put({"burrow", "dark"}, Blocks.burrow_block(app_css, "dark"))

    blocks =
      for {id, mode} = key <- @variants do
        Map.get(by_key, key) || flunk("no #{id} #{mode} block")
      end

    {:ok,
     blocks: blocks, source: File.read!(@settings_path), state_source: File.read!(@state_path)}
  end

  # ── source reading ─────────────────────────────────────────────────────

  # The {on, off} class strings of a `defp name(flag)` whose body is
  # `if(flag, do: "...", else: "...")`.
  defp branch_classes(source, fun) do
    body =
      case Regex.run(~r/defp #{fun}\(\w+\?\) do(.*?)\n  end/s, source) do
        [_, body] -> body
        nil -> flunk("no defp #{fun}/1 in settings_live.ex")
      end

    case Regex.run(~r/if\(\w+\?, do: "([^"]*)", else: "([^"]*)"\)/, body) do
      [_, on, off] -> {on, off}
      nil -> flunk("#{fun}/1 no longer reads `if(flag, do: \"...\", else: \"...\")`")
    end
  end

  # The one colour slot a class string names with `prefix` (bg / border /
  # text), skipping sizes and arbitrary values.
  defp one_slot(classes, prefix) do
    slots =
      for class <- String.split(classes, ~r/\s+/, trim: true),
          String.starts_with?(class, prefix <> "-"),
          slot = String.replace_prefix(class, prefix <> "-", ""),
          slot not in ~w(xs sm base lg xl 2xl 2 0),
          not String.starts_with?(slot, "["),
          do: slot

    assert length(slots) == 1,
           "#{inspect(classes)}: expected one #{prefix} slot, got #{inspect(slots)}"

    hd(slots)
  end

  defp slots(source) do
    {track_on, track_off} = branch_classes(source, "track_class")
    {knob_on, knob_off} = branch_classes(source, "knob_class")
    {ring_on, ring_off} = branch_classes(source, "radio_class")

    dot =
      case Regex.run(~r/<span :if=\{opt\.value == @level\} class="([^"]+)"><\/span>/, source) do
        [_, classes] -> one_slot(classes, "bg")
        nil -> flunk("no selected-radio dot span")
      end

    failed =
      case Regex.run(~r/<p[^>]*class="([^"]+)"[^>]*>\s*Couldn't turn on notifications/, source) do
        [_, classes] -> one_slot(classes, "text")
        nil -> flunk("no subscribe-failed line")
      end

    %{
      track_on: one_slot(track_on, "bg"),
      track_off: one_slot(track_off, "bg"),
      knob_on: one_slot(knob_on, "bg"),
      knob_off: one_slot(knob_off, "bg"),
      ring_selected: one_slot(ring_on, "border"),
      ring_unselected: one_slot(ring_off, "border"),
      dot: dot,
      failed: failed
    }
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: Blocks.resolve!(b, token)

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

  # An opaque slot's colour: `--color-<slot>`, else Burrow's bare `--<slot>`.
  defp opaque(b, slot) do
    if Blocks.declaration(b.decls, "--color-#{slot}"),
      do: c(b, "--color-#{slot}"),
      else: c(b, "--#{slot}")
  end

  # Contrast of a slot painted on a ground token. `subtle` is alpha over the
  # ground, so it is PAINTED on the worst pixel; anything else is opaque.
  defp on(b, "subtle", ground) do
    {r, _} = PC.contrast_min(c(b, "--color-base-content"), c(b, ground), subtle_pct(b))
    r
  end

  defp on(b, slot, ground), do: W.contrast(opaque(b, slot), c(b, ground))

  # Every pixel the formulas allow for `subtle` over `ground` (per-channel
  # combinations, as PaintedComposite.envelope/3 builds them).
  defp subtle_pixels(b, ground) do
    {fr, fg, fb} = PC.bytes(c(b, "--color-base-content"))
    {br, bg, bb} = PC.bytes(c(b, ground))
    p = subtle_pct(b)

    opts = fn f, g ->
      PC.formulas() |> Enum.map(&elem(PC.paint(&1, {f, f, f}, {g, g, g}, p), 0)) |> Enum.uniq()
    end

    for r <- opts.(fr, br), gg <- opts.(fg, bg), bl <- opts.(fb, bb), do: {r, gg, bl}
  end

  # A knob slot on a track slot that sits on `ground`.
  defp knob_on_track(b, knob, "subtle", ground) do
    k = opaque(b, knob)

    b
    |> subtle_pixels(ground)
    |> Enum.map(&W.contrast(k, PC.from_bytes(&1)))
    |> Enum.min()
  end

  defp knob_on_track(b, knob, track, _ground), do: W.contrast(opaque(b, knob), opaque(b, track))

  # A track slot against a ground token.
  defp track_vs(b, "subtle", ground), do: on(b, "subtle", ground)
  defp track_vs(b, slot, ground), do: W.contrast(opaque(b, slot), c(b, ground))

  defp pairs(b, s) do
    [
      {"text base-content / base-200", @aa_text, on(b, "base-content", @ground)},
      {"text base-content / base-100", @aa_text, on(b, "base-content", @raised)},
      {"subtle / base-200 (painted)", @aa_text, on(b, "subtle", @ground)},
      {"subtle / base-100 (painted)", @aa_text, on(b, "subtle", @raised)},
      {"failed #{s.failed} / base-100", @aa_text, on(b, s.failed, @raised)},
      {"back chevron subtle / base-200", @aa_ui, on(b, "subtle", @ground)},
      {"ON track #{s.track_on} / base-200", @aa_ui, track_vs(b, s.track_on, @ground)},
      {"ON track #{s.track_on} / base-100", @aa_ui, track_vs(b, s.track_on, @raised)},
      {"ON knob #{s.knob_on} / #{s.track_on}", @aa_ui,
       knob_on_track(b, s.knob_on, s.track_on, @ground)},
      {"OFF track #{s.track_off} / base-200", @aa_ui, track_vs(b, s.track_off, @ground)},
      {"OFF track #{s.track_off} / base-100", @aa_ui, track_vs(b, s.track_off, @raised)},
      {"OFF knob #{s.knob_off} / #{s.track_off} on base-200", @aa_ui,
       knob_on_track(b, s.knob_off, s.track_off, @ground)},
      {"OFF knob #{s.knob_off} / #{s.track_off} on base-100", @aa_ui,
       knob_on_track(b, s.knob_off, s.track_off, @raised)},
      {"radio dot #{s.dot} / base-100", @aa_ui, on(b, s.dot, @raised)},
      {"radio ring #{s.ring_unselected} / base-100", @aa_ui, on(b, s.ring_unselected, @raised)}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  # ── contrast ───────────────────────────────────────────────────────────

  test "every Settings pair clears its floor in all ten variants; the table prints",
       %{blocks: blocks, source: source} do
    assert length(blocks) == 10
    s = slots(source)
    rows = for b <- blocks, do: {b, pairs(b, s)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    min_of = fn label ->
      rows
      |> Enum.map(fn {b, ps} -> {b, ps |> List.keyfind(label, 0) |> elem(2)} end)
      |> Enum.min_by(&elem(&1, 1))
    end

    verdict = fn
      true -> "HOLDS"
      false -> "FAILS"
    end

    switch_labels = Enum.filter(labels, &String.contains?(&1, ["track", "knob"]))

    {tight_switch, {ts_b, ts_r}} =
      switch_labels |> Enum.map(&{&1, min_of.(&1)}) |> Enum.min_by(fn {_, {_, r}} -> r end)

    text_labels = labels |> Enum.take(4)

    {tight_text, {tt_b, tt_r}} =
      text_labels |> Enum.map(&{&1, min_of.(&1)}) |> Enum.min_by(fn {_, {_, r}} -> r end)

    # H-error is about the ERROR slot itself, whatever the failed line names
    # now (after the fallback it names base-content).
    error_rows = for b <- blocks, do: {b, on(b, "error", @raised)}

    failed_light_failures =
      for {b, r} <- error_rows, b.mode == "light", r < @aa_text, do: "#{b.id} #{b.mode}"

    {fl_b, fl_r} = Enum.min_by(error_rows, &elem(&1, 1))

    IO.puts(
      "\nSettings AA table (WCAG 2.x; --subtle pairs painted on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n| floor | " <>
        (rows |> hd() |> elem(1) |> Enum.map_join(" | ", fn {_, f, _} -> f4(f) end)) <>
        " |\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", fn {_, _, r} -> f4(r) end) <> " |"
        end) <>
        "\nH-on-track: tightest switch pair is #{tight_switch} #{f4(ts_r)} (#{ts_b.id} #{ts_b.mode}) -> " <>
        verdict.(
          String.starts_with?(tight_switch, "ON track") and
            String.ends_with?(tight_switch, "base-200") and ts_b.id == "burrow-sand" and
            ts_b.mode == "light"
        ) <>
        "\nH-error: error / base-100 under 4.5 in light variants: #{inspect(failed_light_failures)}; min #{f4(fl_r)} (#{fl_b.id} #{fl_b.mode}); all variants: " <>
        Enum.map_join(error_rows, ", ", fn {b, r} -> "#{b.id} #{b.mode} #{f4(r)}" end) <>
        " -> " <>
        verdict.(failed_light_failures != []) <>
        "\nH-subtle: tightest text pair is #{tight_text} #{f4(tt_r)} (#{tt_b.id} #{tt_b.mode}) -> " <>
        verdict.(tight_text == "subtle / base-200 (painted)")
    )

    failures =
      for {b, ps} <- rows, {label, floor, r} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  test "the guard measures the slots the source names", %{source: source, blocks: [b | _]} do
    s = slots(source)

    for slot <- [
          s.track_on,
          s.track_off,
          s.knob_on,
          s.knob_off,
          s.dot,
          s.ring_unselected,
          s.failed
        ],
        do: assert(is_binary(slot) and slot != "")

    labels = b |> pairs(s) |> Enum.map(&elem(&1, 0))
    assert "failed #{s.failed} / base-100" in labels
    assert "OFF track #{s.track_off} / base-200" in labels
    assert "radio ring #{s.ring_unselected} / base-100" in labels
  end

  # ── structure ──────────────────────────────────────────────────────────

  test "anti-vacuity: the source read is the Settings screen", %{source: source} do
    assert byte_size(source) > 0
    assert source =~ ~s(id="settings")
    assert source =~ ~s(data-role="settings-push-switch")
  end

  test "no base-content alpha, hex, data-theme selector, hover or sub-12px text",
       %{source: source} do
    assert source =~ ~s(id="settings")
    # Positive controls: the vocabulary the refutes look for is present.
    assert source =~ "text-base-content"
    assert Regex.match?(~r/text-\[\d+px\]/, source)
    assert source =~ "active:bg-"

    refute source =~ "text-base-content/"
    refute Regex.match?(~r/#[0-9a-fA-F]{3,8}\b/, source)
    refute source =~ "[data-theme"
    refute source =~ "hover:"

    small =
      for [_, n] <- Regex.scan(~r/text-\[(\d+)px\]/, source), String.to_integer(n) < 12, do: n

    assert small == []
  end

  test "the root is base-200 and a pressed row is base-100", %{source: source} do
    [_, root] = Regex.run(~r/id="settings"\s+class="([^"]+)"/, source)
    assert root =~ "bg-base-200"

    [_, row] = Regex.run(~r/defp row_class do\s+"([^"]+)"/, source)
    rest = Regex.run(~r/defp row_class do\s+"[^"]+" <>\s+"([^"]+)"/, source) |> List.last()
    assert row <> " " <> rest =~ "active:bg-base-100"
  end

  # The stage's rule was "text-error exactly once" (the subscribe-failed
  # line). Measured here: error on base-100 is under 4.5 in five variants
  # (burrow light 3.7360), so the named fallback applied and the line is
  # base-content. The rule is now: no element in Settings or NotificationState
  # names text-error, and the failed line's slot is base-content.
  test "text-error is gone (fallback applied); the failed line is base-content",
       %{source: source, state_source: state_source} do
    assert state_source =~ "notification_state_row"
    assert slots(source).failed == "base-content"

    # Class attributes and class strings only: prose may name the slot.
    count = fn text ->
      length(Regex.scan(~r/class="[^"]*\btext-error\b[^"]*"/, text)) +
        length(Regex.scan(~r/do: "[^"]*\btext-error\b[^"]*"/, text))
    end

    # Positive control: the counter finds a class attribute when one exists.
    assert count.(~s(<p class="text-xs text-error">)) == 1
    assert count.(source) + count.(state_source) == 0
  end

  test "every row chevron is aria-hidden (decorative; no floor)", %{source: source} do
    chevrons = Regex.scan(~r/<span class="hero-chevron-(?:right|left)[^"]*"[^>]*>/, source)
    assert length(chevrons) >= 4

    for [tag] <- chevrons, do: assert(tag =~ ~s(aria-hidden="true"), tag)
  end
end
