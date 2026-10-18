defmodule PlatformWeb.Components.ScopeColorStylesShippedSixTest do
  @moduledoc """
  The regression gate for moving the six shipped orgs onto the runtime
  colour path (task 01a09333-d374 stage 5).

  Robin's ruling, 2026-09-13: "You can move the existing 6 org pills. Ensure
  the move does not cause regressions for the existing systems, especially
  tasks in flight for projects like SXI." This file is what makes the move
  checkable. Everything here is asserted on the CSS the emitter actually
  writes for the six, built from the values the stage 5 migration stores,
  so the chain under test is row values -> `ScopeColorStyles.css_for/1` ->
  bytes, compared against bytes a browser painted before the move.

  What it pins, and what is allowed to differ:

    * Chip backgrounds (`--scope-tint-100/-200`, light) equal the painted
      pre-move tints on seven cells and sit one byte HIGH on the five cells
      the compositor has always disagreed on. Anything else is red.
    * `--scope-fill` paints the shipped fill for all six.
    * Hue and chroma of every label and edge are the fill's; only L moves.
      Every label slot's L is pinned, with the moves against the shipped
      single label named.
    * `--scope-active-content` is the emitter's measured choice. It keeps
      dark text on four orgs and flips soylent and wayne-tech from white to
      dark: pinned as a named delta.
    * sxi, the thinnest margin, by name with its figures.
    * The four base-100 label cells the stage 6 behavioural gate flagged for
      moving off the browser's pre-retrofit bytes: pinned by byte and by
      contrast, with the approval that allows the move named (stage 7).
    * No `color-mix` anywhere in the six's emitted rules.

  `async: false` because the migration module is loaded with
  `Code.require_file/1`, which the data-migration test does too.
  """
  use ExUnit.Case, async: false

  alias Platform.Tenancy.ScopeColor
  alias Platform.Tenancy.ScopeColorPaintedFixture, as: Painted
  alias PlatformWeb.Components.ScopeColorStyles

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260921190000_add_color_lightness_to_orgs.exs",
                    __DIR__
                  )

  # Row slug -> the kebab fragment the painted fixture was measured under.
  @fixture_slug %{
    "legacy" => "legacy",
    "soylent" => "soylent",
    "wayne_tech" => "wayne-tech",
    "sxi" => "sxi",
    "paragon" => "paragon",
    "cyberdyne" => "cyberdyne"
  }

  @six Map.keys(@fixture_slug)

  # The shipped fills and active-pill text, pasted from app.css at 98eb79ab.
  @shipped %{
    "legacy" => %{fill: "oklch(72% 0.16 50)", active: "oklch(15% 0 0)"},
    "soylent" => %{fill: "oklch(65% 0.20 295)", active: "oklch(98% 0 0)"},
    "wayne_tech" => %{fill: "oklch(68% 0.15 240)", active: "oklch(98% 0 0)"},
    "sxi" => %{fill: "oklch(70% 0.15 162)", active: "oklch(15% 0 0)"},
    "paragon" => %{fill: "oklch(80% 0.16 95)", active: "oklch(15% 0 0)"},
    "cyberdyne" => %{fill: "oklch(66% 0.19 340)", active: "oklch(15% 0 0)"}
  }

  # The single label each org wore on BOTH surfaces before the move, as
  # app.css declared it at 98eb79ab: {light L, dark L}.
  @shipped_label_l %{
    "legacy" => {55.0, 72.0},
    "soylent" => {55.0, 67.0},
    "wayne_tech" => {52.0, 68.0},
    "sxi" => {51.0, 70.0},
    "paragon" => {54.0, 80.0},
    "cyberdyne" => {55.5, 67.5}
  }

  # Every label slot after the move, as L percent:
  # {light-100, light-200, dark-100, dark-200}. Hue and chroma are the
  # fill's in every slot (asserted below), so L is the whole of the change.
  #
  # Against the shipped single label:
  #   * light base-100: legacy, paragon, cyberdyne unchanged; sxi one 0.5%
  #     step DARKER (51 -> 50.5, it had no margin); soylent and wayne-tech one
  #     step LIGHTER (55 -> 55.5, 52 -> 52.5), because the solver walks down
  #     from the fill and stops at the first L that holds its margin.
  #   * light base-200 (the rail): all six darker, the defect this task fixes.
  #   * dark base-100: all six unchanged.
  #   * dark base-200 (the rail): soylent 67 -> 65 and cyberdyne
  #     67.5 -> 66, both walking back to their fill; the rest unchanged.
  @label_l %{
    "legacy" => {55.0, 52.5, 72.0, 72.0},
    "soylent" => {55.5, 53.0, 67.0, 65.0},
    "wayne_tech" => {52.5, 49.5, 68.0, 68.0},
    "sxi" => {50.5, 48.0, 70.0, 70.0},
    "paragon" => {54.0, 52.0, 80.0, 80.0},
    "cyberdyne" => {55.5, 53.0, 67.5, 66.0}
  }

  # ── the four base-100 labels the behavioural gate flagged ─────────────
  #
  # The stage 6 behavioural gate carried a plan-time clause reading "LABEL
  # COLOUR ... must be identical on base-100". Four base-100 label cells do
  # not satisfy it. They land one solver step from the bytes a browser
  # painted for the pre-retrofit `.text-<slug>-label` values at base sha
  # 151c8f6d:
  #
  #   cell                 was       now       delta (r,g,b)  before -> after
  #   soylent light-100   #7e4ed7   #7f50d9   {+1, +2, +2}   4.6668 -> 4.5589
  #   wayne_tech light-100   #0070b5   #0072b7   { 0, +2, +2}   4.6738 -> 4.5530
  #   sxi      light-100   #007f4a   #007d49   { 0, -2, -1}   4.5539 -> 4.6725
  #   wayne_tech dark-100    #19a2eb   #1aa2eb   {+1,  0,  0}   5.112  -> 5.1137
  #
  # All four still clear 4.5:1 against their own tint, so AA is what binds
  # and byte identity is not; the clause was written before the measurement
  # and is stale. sxi, the slug the constraint exists to protect, is the one
  # cell that GAINS margin. Alex Rivera approved the move with it
  # disclosed in these words on 2026-09-23, review request
  # 01a0c74f-ab00-7001-9666-7ff46eb41f6a, item "What changes, your choices,
  # and one question":
  #
  #   "Page labels, light theme: SXI slightly darker. Soylent and Wayne-Tech
  #    slightly lighter (the plan said darker; measuring said lighter),
  #    still passing 4.5:1."
  #
  # The block below RECORDS that decision rather than waving it through:
  # each cell is pinned by its emitted bytes and by its contrast, so any
  # further move goes red and comes back for a fresh ruling.
  #
  # Both ratios are taken against the SAME emitted tint, so each delta is
  # the label's alone and not the tint's. The three light `was` values are
  # `ScopeColorPaintedFixture.labels/0`, measured in stage 1.
  #
  # The dark cell is a different kind of move and was already characterised
  # before this gate ran. Its L never changed, so nothing was re-solved:
  # `ScopeColorTest`'s `@chrome_painted_edges` records Chrome converting
  # `oklch(68% 0.15 240)` to #19a2eb where the solver quantises #1aa2eb, one
  # byte low on red, one of exactly two such misses in 40 measured values
  # (task 01a09333-d374 stage 4). That is the one-byte browser disagreement
  # `ScopeColorStyles`' moduledoc names as the reason labels ship as hex at
  # all. It is a browser reading, so it is not reproducible in Elixir and is
  # not asserted here; the dark cell is pinned by the stricter
  # every-channel floor instead, a bound that contains it.

  # `{slug, theme}` => `{contrast after, green floor after}` on base-100.
  @flagged_after %{
    {"soylent", :light} => {4.5589, 4.5260},
    {"wayne_tech", :light} => {4.5530, 4.5030},
    {"sxi", :light} => {4.6725, 4.6143},
    {"wayne_tech", :dark} => {5.1137, 5.0653}
  }

  # Light base-100 only: `{now minus was per channel, the contrast the
  # painted label held against the emitted tint}`.
  @flagged_light %{
    "soylent" => {{1, 2, 2}, 4.6668},
    "wayne_tech" => {{0, 2, 2}, 4.6738},
    "sxi" => {{0, -2, -1}, 4.5539}
  }

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  # ── the emitted CSS, parsed ───────────────────────────────────────────

  defp entries do
    for {slug, hue, chroma, lightness} <-
          Platform.Tenancy.HistoricalRootSlug.relabel(migration().shipped()),
        slug in @six do
      %{slug: slug, label: slug, hue: hue, chroma: chroma, lightness: lightness}
    end
  end

  defp css, do: ScopeColorStyles.css_for(entries())

  # `%{{slug, :light | :dark} => %{property => value}}`, from the text.
  defp emitted(css \\ css()) do
    for line <- String.split(css, "\n", trim: true), into: %{} do
      [_, dark, slug, body] =
        Regex.run(~r/\A(\[data-theme=dark\] )?\[data-scope="([^"]+)"\]\{([^}]*)\}\z/, line)

      declarations =
        body
        |> String.split(";")
        |> Map.new(fn declaration ->
          [property, value] = String.split(declaration, ":", parts: 2)
          {property, value}
        end)

      {{slug, if(dark == "", do: :light, else: :dark)}, declarations}
    end
  end

  defp slot(emitted, slug, theme, property),
    do: emitted |> Map.fetch!({slug, theme}) |> Map.fetch!(property)

  defp painted_hex(color), do: ScopeColor.composite_painted(color, 1.0, "#000000").hex

  defp hue_and_chroma(slug) do
    {_, hue, chroma, _} =
      Enum.find(
        Platform.Tenancy.HistoricalRootSlug.relabel(migration().shipped()),
        &(elem(&1, 0) == slug)
      )

    {hue, chroma}
  end

  # ── the gate ──────────────────────────────────────────────────────────

  # Per-channel EMITTED minus PAINTED for all twelve light tint cells, keyed
  # the way the fixture is. Only non-zero deltas are returned.
  defp tint_misses(emitted) do
    for {{fixture_slug, surface}, {painted, _ratio}} <- Painted.tints(),
        {slug, ^fixture_slug} <- @fixture_slug,
        property = if(surface == "base-100", do: "--scope-tint-100", else: "--scope-tint-200"),
        {er, eg, eb} = emitted |> slot(slug, :light, property) |> Painted.bytes(),
        {pr, pg, pb} = Painted.bytes(painted),
        delta = {er - pr, eg - pg, eb - pb},
        delta != {0, 0, 0},
        into: %{} do
      {{fixture_slug, surface}, delta}
    end
  end

  # THE gate, as a function so the anti-vacuity test below can hand it a
  # mutated emission and watch it refuse.
  defp gate(emitted) do
    misses = tint_misses(emitted)
    if misses == Painted.known_divergences(), do: :ok, else: {:red, misses}
  end

  describe "chip backgrounds: the gate" do
    test "7 tints are the painted bytes and 5 are the named one-byte-high deltas, nothing else" do
      emitted = emitted()

      assert gate(emitted) == :ok,
             """
             The emitted chip backgrounds of the six moved.
             allowed: #{inspect(Painted.known_divergences())}
             now:     #{inspect(tint_misses(emitted))}
             """

      assert map_size(Painted.tints()) == 12
      assert map_size(Painted.known_divergences()) == 5
    end

    test "every allowed delta is one byte HIGH on the named channels, never low, never two" do
      for {cell, {r, g, b}} <- Painted.known_divergences() do
        assert Enum.all?([r, g, b], &(&1 in [0, 1])), inspect(cell)
        assert r + g + b >= 1, inspect(cell)
      end
    end

    test "anti-vacuity: the gate reds on a one-byte move of an exact cell and of a named cell" do
      emitted = emitted()

      bump = fn emitted, slug, property, fun ->
        update_in(emitted, [{slug, :light}, property], fn "#" <> _ = hex ->
          {r, g, b} = hex |> Painted.bytes() |> fun.()

          "#" <>
            Enum.map_join(
              [r, g, b],
              "",
              &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase())
            )
        end)
      end

      # An exact cell (legacy on base-100) moved one byte on red.
      assert {:red, _} =
               gate(
                 bump.(emitted, "legacy", "--scope-tint-100", fn {r, g, b} -> {r + 1, g, b} end)
               )

      # A named cell whose delta CLOSES (legacy on base-200 back to the painted
      # red) and one whose delta GROWS (a second byte on blue): both red, so
      # the five deltas are pinned as values, not as "somewhere near".
      assert {:red, _} =
               gate(
                 bump.(emitted, "legacy", "--scope-tint-200", fn {r, g, b} -> {r - 1, g, b} end)
               )

      assert {:red, _} =
               gate(
                 bump.(emitted, "legacy", "--scope-tint-200", fn {r, g, b} -> {r, g, b + 1} end)
               )

      # A dark tint is outside the painted fixture, so it is NOT what this
      # gate watches; it is pinned below instead.
      assert gate(
               update_in(emitted, [{"legacy", :dark}, "--scope-tint-100"], fn _ -> "#000000" end)
             ) ==
               :ok
    end

    test "dark tints are the compositor's 12% over each dark ground, unpainted" do
      # No dark tint was painted before the move, so there is no browser
      # measurement to hold them to. They are the same compositor the light
      # gate calibrates, over `#171b25` and `oklch(9% 0.018 240)`.
      emitted = emitted()

      for slug <- @six do
        fill = @shipped[slug].fill

        assert slot(emitted, slug, :dark, "--scope-tint-100") ==
                 ScopeColor.composite_painted(fill, 0.12, "#171b25").hex

        assert slot(emitted, slug, :dark, "--scope-tint-200") ==
                 ScopeColor.composite_painted(fill, 0.12, "oklch(9% 0.018 240)").hex
      end
    end
  end

  describe "the dot and the active pill" do
    test "--scope-fill paints each org's shipped fill" do
      emitted = emitted()

      for slug <- @six do
        fill = slot(emitted, slug, :light, "--scope-fill")
        assert painted_hex(fill) == painted_hex(@shipped[slug].fill), slug
      end
    end

    test "active-pill text keeps dark on four orgs and flips soylent and wayne-tech from white to dark" do
      # The emitter picks the higher-contrast of the two tokens the shipped
      # blocks used. On soylent and wayne-tech the hand-picked white measures
      # 3.30 and 2.67 against the fill, under AA; dark measures 5.62 and 6.95.
      # Pinned as a named delta so a change in either direction is red.
      emitted = emitted()

      flipped =
        for slug <- @six,
            slot(emitted, slug, :light, "--scope-active-content") != @shipped[slug].active,
            do: slug

      assert Enum.sort(flipped) == ["soylent", "wayne_tech"]

      for slug <- @six do
        now = slot(emitted, slug, :light, "--scope-active-content")
        fill = @shipped[slug].fill
        assert now == "oklch(15% 0 0)", slug
        assert ScopeColor.contrast(now, fill) > ScopeColor.contrast("oklch(98% 0 0)", fill), slug
      end

      for {slug, white, dark} <- [{"soylent", 3.3033, 5.6218}, {"wayne_tech", 2.6727, 6.9481}] do
        fill = @shipped[slug].fill
        assert_in_delta ScopeColor.contrast("oklch(98% 0 0)", fill), white, 0.00005, slug
        assert_in_delta ScopeColor.contrast("oklch(15% 0 0)", fill), dark, 0.00005, slug
      end
    end
  end

  describe "labels and edges: only L moves" do
    test "every label slot is the fill's hue and chroma at the pinned L, painted as given" do
      emitted = emitted()

      for {slug, {l100, l200, d100, d200}} <- @label_l,
          {theme, property, l} <- [
            {:light, "--scope-label-100", l100},
            {:light, "--scope-label-200", l200},
            {:dark, "--scope-label-100", d100},
            {:dark, "--scope-label-200", d200}
          ] do
        {hue, chroma} = hue_and_chroma(slug)
        expected = "oklch(#{fmt(l)}% #{fmt(chroma)} #{hue})"

        assert slot(emitted, slug, theme, property) == painted_hex(expected),
               "#{slug} #{theme} #{property}: expected #{expected}"
      end
    end

    test "against the shipped single label, exactly the named slots move" do
      moved =
        for {slug, {l100, l200, d100, d200}} <- @label_l,
            {shipped_light, shipped_dark} = @shipped_label_l[slug],
            {slot_name, now, was} <- [
              {"light-100", l100, shipped_light},
              {"light-200", l200, shipped_light},
              {"dark-100", d100, shipped_dark},
              {"dark-200", d200, shipped_dark}
            ],
            now != was,
            into: MapSet.new() do
          {slug, slot_name, was, now}
        end

      assert moved ==
               MapSet.new([
                 # base-100, light: one darker, two lighter.
                 {"sxi", "light-100", 51.0, 50.5},
                 {"soylent", "light-100", 55.0, 55.5},
                 {"wayne_tech", "light-100", 52.0, 52.5},
                 # the rail, light: all six darker.
                 {"legacy", "light-200", 55.0, 52.5},
                 {"soylent", "light-200", 55.0, 53.0},
                 {"wayne_tech", "light-200", 52.0, 49.5},
                 {"sxi", "light-200", 51.0, 48.0},
                 {"paragon", "light-200", 54.0, 52.0},
                 {"cyberdyne", "light-200", 55.5, 53.0},
                 # the rail, dark: two walk back to their fill.
                 {"soylent", "dark-200", 67.0, 65.0},
                 {"cyberdyne", "dark-200", 67.5, 66.0}
               ])
    end

    test "every label clears 4.5 with the solver's margin against its own emitted tint" do
      emitted = emitted()

      for slug <- @six, theme <- [:light, :dark], n <- ["100", "200"] do
        label = slot(emitted, slug, theme, "--scope-label-#{n}")
        tint = slot(emitted, slug, theme, "--scope-tint-#{n}")
        floor = green_floor(label, tint)

        assert floor >= 4.5, "#{slug} #{theme} base-#{n}: floor #{floor}"
      end
    end

    test "every edge is the fill's hue and chroma, and clears 3:1 against its page ground" do
      emitted = emitted()

      grounds = %{
        light: {"#ffffff", "#f2f2f2"},
        dark: {"#171b25", painted_hex("oklch(9% 0.018 240)")}
      }

      for slug <- @six, theme <- [:light, :dark] do
        {hue, chroma} = hue_and_chroma(slug)
        {g100, g200} = grounds[theme]
        ramp = ScopeColor.derive(hue, chroma, lightness(slug))

        for {n, ground, edge} <- [
              {"100", g100,
               if(theme == :light, do: ramp.edge_light_100, else: ramp.edge_dark_100)},
              {"200", g200,
               if(theme == :light, do: ramp.edge_light_200, else: ramp.edge_dark_200)}
            ] do
          assert edge =~ ~r/ #{fmt(chroma)} #{hue}\)\z/, "#{slug} #{theme} #{n}: #{edge}"
          emitted_edge = slot(emitted, slug, theme, "--scope-edge-#{n}")
          assert emitted_edge == painted_hex(edge)
          assert green_floor(emitted_edge, ground) >= 3.0, "#{slug} #{theme} #{n}"
        end
      end
    end
  end

  describe "sxi, by name" do
    # Stark Industries is a live client and held the thinnest margin of
    # the six: its shipped label painted 4.5539 against its tint, and a
    # single +1 on the label's green took it to 4.4974, under AA. After the
    # move every sxi label clears 4.5 under a +/-1 move on its green (the
    # solver's margin) AND under a +/-1 move on every channel at once (the
    # stricter test), on both surfaces in both themes. Figures are read off
    # the EMITTED bytes: label hex against tint hex.
    @sxi %{
      {:light, "100"} => {4.6725, 4.6143, 4.6098},
      {:light, "200"} => {4.6030, 4.5443, 4.5398},
      {:dark, "100"} => {5.6959, 5.6388, 5.6337},
      {:dark, "200"} => {7.2567, 7.1839, 7.1775}
    }

    test "every sxi label holds 4.5 under both perturbations, at the recorded figures" do
      emitted = emitted()

      for {{theme, n}, {nominal, green, all_channel}} <- @sxi do
        label = slot(emitted, "sxi", theme, "--scope-label-#{n}")
        tint = slot(emitted, "sxi", theme, "--scope-tint-#{n}")
        at = "sxi #{theme} base-#{n}"

        assert_in_delta ScopeColor.contrast(label, tint), nominal, 0.00005, at
        assert_in_delta green_floor(label, tint), green, 0.00005, at
        assert_in_delta all_channel_floor(label, tint), all_channel, 0.00005, at

        assert green >= 4.5 and all_channel >= 4.5, at
      end

      # The thinnest sxi cell is the light rail, 0.0398 above AA on the
      # strict test. The shipped label had -0.0026 on the single-channel one.
      assert @sxi |> Map.values() |> Enum.map(&elem(&1, 2)) |> Enum.min() == 4.5398
    end

    test "sxi's light base-100 label is darker than it shipped, and its tint is the painted byte" do
      emitted = emitted()

      assert slot(emitted, "sxi", :light, "--scope-tint-100") ==
               "#e3f7f0"

      assert slot(emitted, "sxi", :light, "--scope-label-100") ==
               painted_hex("oklch(50.5% 0.15 162)")

      assert ScopeColor.contrast(slot(emitted, "sxi", :light, "--scope-label-100"), "#e3f7f0") >
               ScopeColor.contrast("#007f4a", "#e3f7f0")
    end
  end

  describe "the four base-100 labels the behavioural gate flagged" do
    test "exactly three light base-100 labels moved off the painted bytes, by the named deltas" do
      emitted = emitted()

      moved =
        for slug <- @six,
            now = slot(emitted, slug, :light, "--scope-label-100"),
            delta = channel_delta(now, fixture_label_hex(slug)),
            delta != {0, 0, 0},
            into: %{} do
          {slug, delta}
        end

      assert moved == Map.new(@flagged_light, fn {slug, {delta, _before}} -> {slug, delta} end)

      # The other three ARE byte-identical to the browser's pre-retrofit
      # paint, which is why the stale clause read as a near miss rather than
      # as a wholesale repaint.
      for slug <- @six -- Map.keys(@flagged_light) do
        assert slot(emitted, slug, :light, "--scope-label-100") == fixture_label_hex(slug), slug
      end
    end

    test "each moved light label held AA before the move, at the recorded figure" do
      emitted = emitted()

      for {slug, {_delta, before}} <- @flagged_light do
        tint = slot(emitted, slug, :light, "--scope-tint-100")

        assert_in_delta ScopeColor.contrast(fixture_label_hex(slug), tint), before, 0.00005, slug
        assert before >= 4.5, slug
      end
    end

    test "wayne_tech's dark base-100 label is the shipped oklch, repainted by the solver" do
      # Its L never moved (68%, see @label_l), so this cell is not a colour
      # change at all. The browser used to convert `oklch(68% 0.15 240)`
      # itself and painted #19a2eb; the emitter now hands it the bytes the
      # solver quantised, #1aa2eb, one apart on red. That exact pair is
      # already pinned by `ScopeColorTest`, "Chrome's own oklch() conversion
      # of the edges". A browser reading is not reproducible here, so rather
      # than restate it this asserts that EVERY byte within +/-1 on all
      # three channels clears 4.5, a set that contains it, and a stricter
      # bound than the solver's own green-only margin.
      emitted = emitted()
      {hue, chroma} = hue_and_chroma("wayne_tech")
      {_shipped_light_l, shipped_dark_l} = @shipped_label_l["wayne_tech"]

      assert elem(@label_l["wayne_tech"], 2) == shipped_dark_l

      label = slot(emitted, "wayne_tech", :dark, "--scope-label-100")
      tint = slot(emitted, "wayne_tech", :dark, "--scope-tint-100")

      assert label ==
               painted_hex("oklch(#{fmt(shipped_dark_l)}% #{fmt(chroma)} #{hue})")

      assert_in_delta all_channel_floor(label, tint), 5.0556, 0.00005
      assert all_channel_floor(label, tint) >= 4.5
    end

    test "all four still clear 4.5:1 against their own tint, at the recorded figures" do
      emitted = emitted()

      for {{slug, theme}, {nominal, green}} <- @flagged_after do
        label = slot(emitted, slug, theme, "--scope-label-100")
        tint = slot(emitted, slug, theme, "--scope-tint-100")
        at = "#{slug} #{theme} base-100"

        assert_in_delta ScopeColor.contrast(label, tint), nominal, 0.00005, at
        assert_in_delta green_floor(label, tint), green, 0.00005, at

        assert green >= 4.5, at
      end

      # sxi holds the thinnest margin of the six and is the slug the AA
      # constraint exists to protect. It is the one flagged cell that GAINS:
      # pinning these labels back to the base bytes would return it to the
      # tightest figure in the set.
      {_delta, sxi_before} = @flagged_light["sxi"]
      {sxi_after, _green} = @flagged_after[{"sxi", :light}]

      assert sxi_after > sxi_before
    end
  end

  describe "nothing composites any of the six" do
    test "no color-mix and no alpha in any value the six emit" do
      css = css()

      refute css =~ "color-mix"
      refute css =~ "/"

      for {_key, declarations} <- emitted(css), {property, value} <- declarations do
        assert value =~ ~r/\A#[0-9a-f]{6}\z/ or value =~ ~r/\Aoklch\([0-9.]+% [0-9.]+ [0-9.]+\)\z/,
               "#{property}: #{value}"
      end
    end

    test "all six emit both rules: none is dropped by the value whitelist" do
      assert emitted() |> Map.keys() |> length() == 12
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  # The migration module is loaded at runtime by `Code.require_file/1`, so
  # it is named dynamically: a literal call would warn at compile time that
  # the module is undefined.
  defp migration, do: Module.concat(Platform.Repo.Migrations, AddColorLightnessToOrgs)

  defp lightness(slug) do
    {_, _, _, lightness} =
      Enum.find(
        Platform.Tenancy.HistoricalRootSlug.relabel(migration().shipped()),
        &(elem(&1, 0) == slug)
      )

    lightness
  end

  defp unit({r, g, b}), do: {r / 255, g / 255, b / 255}

  # The browser's pre-retrofit paint of `.text-<slug>-label`, as `#rrggbb`.
  defp fixture_label_hex(slug) do
    Painted.labels()
    |> Map.fetch!(@fixture_slug[slug])
    |> Tuple.to_list()
    |> Enum.map_join("", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> then(&String.downcase("#" <> &1))
  end

  # Per-channel `now` minus `was`, both `#rrggbb`.
  defp channel_delta(now_hex, was_hex) do
    {nr, ng, nb} = Painted.bytes(now_hex)
    {wr, wg, wb} = Painted.bytes(was_hex)
    {nr - wr, ng - wg, nb - wb}
  end

  defp green_floor(color_hex, ground_hex) do
    ScopeColor.floor_contrast(unit(Painted.bytes(color_hex)), [
      %{ground: unit(Painted.bytes(ground_hex))}
    ])
  end

  # The worst contrast over every +/-1 combination on all three channels.
  defp all_channel_floor(color_hex, ground_hex) do
    {r, g, b} = Painted.bytes(color_hex)

    for dr <- -1..1, dg <- -1..1, db <- -1..1 do
      candidate =
        [r + dr, g + dg, b + db]
        |> Enum.map_join("", fn c ->
          c |> max(0) |> min(255) |> Integer.to_string(16) |> String.pad_leading(2, "0")
        end)

      ScopeColor.contrast("#" <> candidate, ground_hex)
    end
    |> Enum.min()
  end

  # The emitter's own number formatting: whole numbers bare, else one or
  # more decimals with no trailing zeros.
  defp fmt(value) do
    rounded = Float.round(value * 1.0, 4)
    int = trunc(rounded)
    if rounded == int * 1.0, do: Integer.to_string(int), else: Float.to_string(rounded)
  end
end
