defmodule PlatformWeb.Components.ScopePillStaticOpacityTest do
  @moduledoc """
  What the NON-CLICKABLE scope chip's label really measures, at the opacity
  it ships with (task 01a09333-d374 stage 6).

  ## Read this before reading a number below

  **These figures are BELOW AA.** Forty-seven of the forty-eight cells are
  under 4.5:1, most of them around 2.1-2.3:1. That is not a bug this file
  is asking anyone to fix, and nothing here asserts a pass.

  The cause is one class. `scope_pill.ex` puts `opacity-55` (`opacity-70` at
  `:compact`) on the non-clickable `<span>`, and `opacity` composites the
  whole chip as a group: the LABEL is pulled toward the page ground along
  with the fill, in the same proportion, so the AA-tuned label token stops
  being AA the moment it is painted. **That opacity is Robin-approved
  (2026-05-18)** and recorded as such in `ScopePill`'s moduledoc. Robin's
  2026-09-13 ruling authorised moving the six shipped pills' COLOURS; it
  said nothing about this opacity. **The ruling is open, and it is hers.**
  This stage measured the cost and left the treatment alone.

  ## Why it took six stages to see

  The ticket swept 24 cells of `{six orgs} x {two grounds} x {rest, hover}`
  and found one cell type passing. Every one of those cells was a CLICKABLE
  chip. The opacity lives on the chip ROOT, not in any `--scope-*` token, so
  no sweep over token values can reach it: the tokens were correct and the
  painted result was not. A measurement taken under one named condition got
  read, downstream, as a property of the component.

  ## What this file is, mechanically

  A characterisation test. It pins the figures the chip paints TODAY so the
  next change to the opacity has to say so out loud.

    * The alpha is **read out of the rendered component** (`shipped_alpha/1`),
      never typed here. Change `opacity-55` to anything else and every
      computed figure moves off its pin, and this file goes red. It cannot
      be made green by editing the component alone.
    * The tint and label are the **emitted tokens**, parsed out of
      `ScopeColorStyles.css_for/1` for the six orgs as the stage 5 migration
      stores them: the bytes a browser is actually handed.
    * The ground is `ScopeColor.cells/1`'s surface for that theme, the same
      ground the tint was composited over.
    * Compositing follows `composite_painted/3`'s conventions: gamma-encoded
      sRGB, quantised once. See that function for why each matters.

  ## Corroborated against a browser, 2026-09-23

  Chrome 153 headless painted all 48 cells: the same `opacity-55` / `opacity-70`
  utilities and the same `--scope-label-*` / `--scope-tint-*` slots, as flat
  patches over the same grounds, screenshot and read pixel-wise. Flat patches,
  not glyphs, so no modal-background search sits between the claim and the
  pixel. **45 of the 48 ratios reproduce here to four decimal places.**

  The three that do not are one byte apart on one channel, each because a
  channel lands on exactly `x.5` to within float noise and `round/1` and
  Chrome's compositor take different sides of the tie:

      cell                                   here      Chrome    byte
      initech light base-100 :compact       2.7146    2.7357    label G 132.5
      initech dark  base-200 :compact       3.0999    3.1116    label R 108.5
      globex      dark  base-200 :compact       4.0319    4.0297    tint  B  16.5

  Largest disagreement 0.021, and no cell changes its side of the AA line. This
  is the same one-byte family `composite_painted/3` documents under "What this
  does not reproduce"; the pins below are the computed figures, because that is
  what this file computes.

  ## The one cell that is not below AA

  `hooli` on the DARK rail at `:compact` reads 5.1049:1. The dark rail
  ground is near black, so a 0.70 composite barely moves the near-black tint
  while the bright yellow label stays bright. It is still a LOSS: the same
  cell reads 9.4420:1 clickable. Every one of the forty-eight cells loses
  contrast to the opacity; forty-seven of them lose enough to fail.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.ScopePill

  alias Platform.Tenancy.ScopeColor
  alias PlatformWeb.Components.ScopeColorStyles

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260921190000_add_color_lightness_to_orgs.exs",
                    __DIR__
                  )

  @six ~w(legacy initech vandelay_ind globex hooli wonka)
  @surfaces ["base-100", "base-200"]
  @sizes [:default, :compact]
  @aa 4.5

  # The label's contrast against its own tint on the NON-CLICKABLE chip, as
  # painted: both composited toward the page ground at the shipped opacity.
  #
  # `{base-100 :default, base-100 :compact, base-200 :default, base-200 :compact}`
  #
  # base-100 is the chat pane and the page ground; base-200 is the chat rail.
  # BELOW AA throughout, bar the one dark-rail compact cell named in the
  # moduledoc. Do not "fix" a number here to make a run green — a figure that
  # has moved means the opacity or a colour token moved, and the fix is to
  # find out which and record why.
  @static_light %{
    "legacy" => {2.2100, 2.8291, 2.2136, 2.8330},
    "initech" => {2.1286, 2.7146, 2.1560, 2.7646},
    "vandelay_ind" => {2.1876, 2.7714, 2.1967, 2.8059},
    "globex" => {2.2112, 2.7966, 2.1796, 2.7919},
    "hooli" => {2.1374, 2.7036, 2.1131, 2.6924},
    "wonka" => {2.2293, 2.8547, 2.2581, 2.8811}
  }

  @static_dark %{
    "legacy" => {2.6036, 3.4314, 2.7700, 3.8769},
    "initech" => {2.3206, 2.9620, 2.2979, 3.0999},
    "vandelay_ind" => {2.4856, 3.2569, 2.6278, 3.6519},
    "globex" => {2.6812, 3.5254, 2.8727, 4.0319},
    "hooli" => {3.2614, 4.4018, 3.4946, 5.1049},
    "wonka" => {2.2907, 2.9331, 2.3142, 3.1527}
  }

  # The clickable chip's figure — the same label and tint with no opacity
  # over them — is computed live by `clickable_contrast/4` and printed in the
  # failure messages below. It is NOT pinned here: `ScopeColorTest` and
  # `ScopeColorStylesShippedSixTest` own that number, and a second copy of it
  # in this file would be a second thing to update when a hue moves.

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  describe "the non-clickable chip's label, as painted (task 01a09333-d374 stage 6)" do
    test "every cell reproduces its pinned figure at the opacity the component ships" do
      emitted = emitted()

      for slug <- @six, theme <- [:light, :dark], surface <- @surfaces, size <- @sizes do
        alpha = shipped_alpha(size)
        measured = round4(static_contrast(emitted, slug, theme, surface, alpha))
        expected = pinned(static_table(theme), slug, surface, size)
        at = "#{slug} #{theme} #{surface} #{size} (opacity #{alpha})"

        assert measured == expected,
               "#{at}: label reads #{measured}:1 against its tint, pinned at #{expected}:1.\n" <>
                 "Either a --scope-* token moved, or the chip's opacity did. " <>
                 "The opacity is Robin-approved (2026-05-18) and the ruling on it is " <>
                 "still open: if it has been changed, say so in the change and re-pin " <>
                 "this table with the new figures. Do not edit the number alone."
      end
    end

    test "the opacity costs contrast in all 48 cells, and 47 of them land below AA" do
      emitted = emitted()

      results =
        for slug <- @six, theme <- [:light, :dark], surface <- @surfaces, size <- @sizes do
          alpha = shipped_alpha(size)
          static = static_contrast(emitted, slug, theme, surface, alpha)
          clickable = clickable_contrast(emitted, slug, theme, surface)
          {{slug, theme, surface, size}, round4(static), round4(clickable)}
        end

      assert length(results) == 48

      # Not one cell gains from the opacity. This is the property the
      # component's comments now state, so it is the one under guard.
      gained = for {at, static, clickable} <- results, static >= clickable, do: at
      assert gained == [], "opacity raised the label's contrast at: #{inspect(gained)}"

      below = for {at, static, _} <- results, static < @aa, do: at

      assert length(below) == 47,
             "47 of 48 static-chip cells were below #{@aa}:1 when this was pinned; " <>
               "#{length(below)} are now. Cells at or above AA: " <>
               "#{inspect(for {at, s, _} <- results, s >= @aa, do: at)}"

      # And the one that clears is named, not merely counted.
      assert {"hooli", :dark, "base-200", :compact} not in below
    end

    test "the alpha every figure above was computed at is read from the component, not typed" do
      # The guard on the guard. If `shipped_alpha/1` ever stops finding an
      # opacity class it must raise, never default: a silent 1.0 would
      # recompute all 48 cells as the clickable chip and read as a fix.
      assert shipped_alpha(:default) > 0.0
      assert shipped_alpha(:compact) > shipped_alpha(:default)

      refute File.read!(__ENV__.file) =~ ~r/alpha\s*=\s*0\.\d/,
             "an alpha literal appeared in this file; every figure here must be " <>
               "computed at what `shipped_alpha/1` reads out of the rendered chip"
    end
  end

  # ── reading the shipped opacity out of the component ──────────────────

  # The alpha the non-clickable chip ACTUALLY carries at `size`, parsed from
  # its rendered class list. Deliberately not a constant: this is the input
  # to every figure above, so changing `opacity-55` in the component moves
  # the measurements rather than escaping them.
  defp shipped_alpha(size) do
    html = render_static_chip(size)

    case Regex.scan(~r/\bopacity-(\d{1,3})\b/, html, capture: :all_but_first) do
      [[percent]] ->
        String.to_integer(percent) / 100

      found ->
        flunk(
          "expected exactly one `opacity-N` class on the non-clickable #{size} chip, " <>
            "found #{inspect(found)}. The static chip's whole contrast story is that " <>
            "class; this file cannot measure anything without it."
        )
    end
  end

  defp render_static_chip(size) do
    assigns = %{size: size}

    rendered_to_string(~H"""
    <.scope_pill scope="legacy" clickable={false} size={@size} />
    """)
  end

  # ── the emitted tokens ────────────────────────────────────────────────

  defp entries do
    for {slug, hue, chroma, lightness} <-
          Platform.Tenancy.HistoricalRootSlug.relabel(migration().shipped()),
        slug in @six do
      %{slug: slug, label: slug, hue: hue, chroma: chroma, lightness: lightness}
    end
  end

  # `%{{slug, :light | :dark} => %{property => value}}`, parsed from the CSS
  # the emitter writes, so the tint and label under test are the bytes the
  # browser is handed and not a second derivation of them.
  defp emitted do
    for line <- String.split(ScopeColorStyles.css_for(entries()), "\n", trim: true), into: %{} do
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

  # ── the measurement ───────────────────────────────────────────────────

  # The chip is composited as a group: `opacity` on the root paints every
  # pixel of it as `alpha * pixel + (1 - alpha) * ground`, the label included.
  # So the label's ground is no longer the tint as declared — it is the tint
  # after the same composite.
  defp static_contrast(emitted, slug, theme, surface, alpha) do
    ground = ground_for(theme, surface)
    {label, tint} = label_and_tint(emitted, slug, theme, surface)

    ScopeColor.contrast(
      ScopeColor.composite_painted(label, alpha, ground).hex,
      ScopeColor.composite_painted(tint, alpha, ground).hex
    )
  end

  defp clickable_contrast(emitted, slug, theme, surface) do
    {label, tint} = label_and_tint(emitted, slug, theme, surface)
    ScopeColor.contrast(label, tint)
  end

  defp label_and_tint(emitted, slug, theme, surface) do
    suffix = slot_suffix(surface)

    {slot(emitted, slug, theme, "--scope-label-#{suffix}"),
     slot(emitted, slug, theme, "--scope-tint-#{suffix}")}
  end

  # The page ground for `surface`, AS PAINTED. `ScopeColor.cells/1` names it
  # as the declaration (`oklch(96% 0 0)`); the backdrop a chip composites
  # over is that declaration already rendered to 8-bit pixels, so it is
  # quantised once here before anything is composited over it.
  #
  # Not a nicety. Compositing over the unquantised float moves cells two ways:
  #
  #   * light base-200's float is 241.6167/255 where the browser paints 242,
  #     a real 0.38-of-a-byte gap (this is the `#F2F2F2` the declaration's own
  #     comment got wrong until this stage; see `app.css`'s surfaces block);
  #   * light base-100 parses to 0.9999999999999999, so 0.3 x ground is
  #     76.49999999999999 and rounds DOWN where an exact white gives 76.5 and
  #     rounds up. One float epsilon, one byte, up to 0.018 on the ratio.
  #
  # `ScopeColor.solve_cell/6` composites its tint over the declaration
  # instead. That is the convention the shipped tints were solved and
  # painted under, pinned by `ScopeColorStylesShippedSixTest` against
  # browser-read bytes, and this stage did not go near it.
  defp ground_for(theme, surface) do
    declared =
      theme
      |> ScopeColor.cells()
      |> Enum.find(&(&1.surface == surface))
      |> Map.fetch!(:color)

    ScopeColor.composite_painted(declared, 1.0, "#000000").hex
  end

  # ── the pinned tables, addressed ──────────────────────────────────────

  defp static_table(:light), do: @static_light
  defp static_table(:dark), do: @static_dark

  defp pinned(table, slug, surface, size) do
    {b100_default, b100_compact, b200_default, b200_compact} = Map.fetch!(table, slug)

    case {surface, size} do
      {"base-100", :default} -> b100_default
      {"base-100", :compact} -> b100_compact
      {"base-200", :default} -> b200_default
      {"base-200", :compact} -> b200_compact
    end
  end

  defp slot_suffix("base-100"), do: "100"
  defp slot_suffix("base-200"), do: "200"

  defp round4(ratio), do: Float.round(ratio, 4)

  # Loaded at runtime by `Code.require_file/1`, so it cannot be aliased.
  defp migration, do: Module.concat(Platform.Repo.Migrations, AddColorLightnessToOrgs)
end
