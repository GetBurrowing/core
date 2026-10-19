defmodule PlatformWeb.Components.ScopeColorStylesTest do
  @moduledoc """
  Task 01a09287 stage 3, extended by task 01a09333-d374 stages 3 and 4.

  Five things are under test: that a coloured org gets its fill plus the
  eight per-surface slots in light and a dark rule overriding exactly those
  eight; that each emitted label is the exact bytes the solver measured
  against the emitted tint; that each emitted edge and hover edge is the
  exact bytes the solver measured against the page ground; that an
  uncoloured org gets NOTHING (so the `text-muted` fallback survives); and
  that neither a slug nor a value can break out of the rule it is
  interpolated into.

  The hostile-slug case constructs its row as a bare map, bypassing the
  changeset, because that is the only way the dangerous value can exist:
  the point of the guard is that it does not trust the writer.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Platform.Tenancy.ScopeColor
  alias PlatformWeb.Components.ScopeColorStyles

  @slots ~w(--scope-tint-100 --scope-tint-200 --scope-label-100 --scope-label-200
             --scope-edge-100 --scope-edge-200 --scope-edge-hover-100 --scope-edge-hover-200)
  @hex ~r/\A#[0-9a-f]{6}\z/

  defp render(entries) do
    render_component(&ScopeColorStyles.scope_color_styles/1, entries: entries)
  end

  # The emitted CSS as `%{{slug, :light | :dark} => [{property, value}]}`,
  # declarations in emission order. Parsed from `css_for/1`'s text, so what
  # is asserted is what reaches the page, not a value recomputed here.
  defp parse(css) do
    for line <- String.split(css, "\n", trim: true), into: %{} do
      [_, dark, slug, body] =
        Regex.run(~r/\A(\[data-theme=dark\] )?\[data-scope="([^"]+)"\]\{([^}]*)\}\z/, line)

      declarations =
        body
        |> String.split(";")
        |> Enum.map(fn declaration ->
          [property, value] = String.split(declaration, ":", parts: 2)
          {property, value}
        end)

      {{slug, if(dark == "", do: :light, else: :dark)}, declarations}
    end
  end

  defp emitted(hue, chroma) do
    [%{slug: "acme", label: "Acme", hue: hue, chroma: chroma}]
    |> ScopeColorStyles.css_for()
    |> parse()
  end

  defp emitted_with(attrs) do
    [Map.merge(%{slug: "acme", label: "Acme"}, attrs)]
    |> ScopeColorStyles.css_for()
    |> parse()
  end

  defp slot_of(parsed, property) do
    {^property, value} = parsed |> Map.fetch!({"acme", :light}) |> List.keyfind(property, 0)
    value
  end

  defp fill_of(parsed), do: slot_of(parsed, "--scope-fill")

  defp bytes("#" <> hex) do
    <<r::binary-2, g::binary-2, b::binary-2>> = hex
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  defp unit({r, g, b}), do: {r / 255, g / 255, b / 255}

  describe "an org with a colour" do
    test "light carries the fill plus eight per-surface slots; dark overrides exactly those eight" do
      rules = emitted(15, 0.15)
      light = Map.fetch!(rules, {"acme", :light})
      dark = Map.fetch!(rules, {"acme", :dark})

      assert Enum.map(light, &elem(&1, 0)) ==
               ["--scope-fill", "--scope-active-content" | @slots]

      assert Enum.map(dark, &elem(&1, 0)) == @slots

      ramp = ScopeColor.derive(15, 0.15)
      assert Enum.drop(light, 2) == ScopeColorStyles.surface_slots(ramp, :light)
      assert dark == ScopeColorStyles.surface_slots(ramp, :dark)
      assert {"--scope-fill", ramp.fill} in light

      # Every slot differs between the themes: the two grounds are 17.21:1
      # apart, below the 4.5^2 = 20.25 a single colour would need, so a slot
      # that coincided across themes would mean the solver was not being
      # consulted per ground. See ScopeColor's moduledoc.
      for {{property, light_value}, {property, dark_value}} <- Enum.zip(Enum.drop(light, 2), dark) do
        refute light_value == dark_value, "#{property} is the same in both themes"
      end
    end

    test "the single shared --scope-label slot is gone" do
      css = ScopeColorStyles.css_for([%{slug: "acme", label: "Acme", hue: 15, chroma: 0.15}])

      refute css =~ "--scope-label:"
    end

    test "every per-surface slot is an opaque #rrggbb, so the browser composites nothing" do
      for {_key, declarations} <- emitted(200, 0.15),
          {property, value} <- declarations,
          property in @slots do
        assert value =~ @hex, "#{property} is #{inspect(value)}, not an opaque #rrggbb"
      end
    end

    test "each emitted label is the solver's painted bytes, measured against the emitted tint" do
      # The label is emitted as hex so the browser paints exactly the bytes
      # `floor_contrast/2` measured, rather than converting the oklch()
      # string itself (measured to differ by one byte on about one channel
      # in eighteen). Three checks per cell, each against the solver's own
      # record of that cell:
      #
      #   * the label hex is the oklch label's painted bytes;
      #   * its contrast against the emitted tint is the solver's figure,
      #     EXACTLY (float equality: same bytes in, same number out);
      #   * its one-byte floor is the solver's floor, and clears 4.5.
      for hue <- 0..359//5, chroma <- [0.15, 0.20] do
        ramp = ScopeColor.derive(hue, chroma)
        rules = emitted(hue, chroma)

        for theme <- [:light, :dark], cell <- ramp.cells[theme] do
          suffix = String.replace_prefix(cell.surface, "base-", "")
          declarations = Map.fetch!(rules, {"acme", theme})
          tint = :proplists.get_value("--scope-tint-#{suffix}", declarations)
          label = :proplists.get_value("--scope-label-#{suffix}", declarations)
          at = "hue #{hue} C=#{chroma} #{theme} #{cell.surface}"

          assert tint == cell.tint, "#{at}: emitted tint #{tint}, solved #{cell.tint}"

          assert label == ScopeColor.composite_painted(cell.label, 1.0, cell.tint).hex,
                 "#{at}: emitted label #{label} is not the painted bytes of #{cell.label}"

          assert ScopeColor.contrast(label, tint) == cell.contrast,
                 "#{at}: #{label} on #{tint} is not the figure the solver measured"

          floor = ScopeColor.floor_contrast(unit(bytes(label)), [%{ground: unit(bytes(tint))}])
          assert floor == cell.floor, "#{at}: floor #{floor}, solver's #{cell.floor}"
          assert floor >= 4.5, "#{at}: #{label} on #{tint} floors at #{floor}"
        end
      end
    end

    test "each emitted edge and hover edge is the solver's painted bytes, measured against the page ground" do
      # Task 01a09333-d374 stage 4. The edge is emitted as hex for the same
      # reason as the label: its margin is the same green-only floor, so
      # the browser must paint the bytes the solver measured. Per cell:
      #
      #   * the edge and hover hex are the oklch values' painted bytes;
      #   * each one's contrast against the PAGE GROUND (the surface, not
      #     the tint) is the solver's figure, exactly;
      #   * each one's one-byte floor is the solver's, and clears 3.0;
      #   * hover and rest are different bytes, so hover is not a no-op.
      #
      # The hue spread includes the low-chroma arc near hue 200, where the
      # C=0.20 request is clipped hardest.
      for hue <- 0..359//5, chroma <- [0.15, 0.20] do
        ramp = ScopeColor.derive(hue, chroma)
        rules = emitted(hue, chroma)

        for theme <- [:light, :dark], cell <- ramp.cells[theme] do
          suffix = String.replace_prefix(cell.surface, "base-", "")
          declarations = Map.fetch!(rules, {"acme", theme})
          edge = :proplists.get_value("--scope-edge-#{suffix}", declarations)
          hover = :proplists.get_value("--scope-edge-hover-#{suffix}", declarations)
          page = ScopeColor.composite_painted(cell.color, 1.0, "#000000").hex
          at = "hue #{hue} C=#{chroma} #{theme} #{cell.surface}"

          assert edge == ScopeColor.composite_painted(cell.edge, 1.0, page).hex,
                 "#{at}: emitted edge #{edge} is not the painted bytes of #{cell.edge}"

          assert hover == ScopeColor.composite_painted(cell.edge_hover, 1.0, page).hex,
                 "#{at}: emitted hover #{hover} is not the painted bytes of #{cell.edge_hover}"

          assert ScopeColor.contrast(edge, page) == cell.edge_contrast, at
          assert ScopeColor.contrast(hover, page) == cell.edge_hover_contrast, at

          ground = [%{ground: unit(bytes(page))}]
          edge_floor = ScopeColor.floor_contrast(unit(bytes(edge)), ground)
          hover_floor = ScopeColor.floor_contrast(unit(bytes(hover)), ground)
          assert edge_floor == cell.edge_floor, at
          assert hover_floor == cell.edge_hover_floor, at
          assert edge_floor >= 3.0, "#{at}: #{edge} on #{page} floors at #{edge_floor}"
          assert hover_floor >= 3.0, "#{at}: hover #{hover} on #{page} floors at #{hover_floor}"

          refute hover == edge, "#{at}: hover paints the same bytes as rest"
        end
      end
    end

    test "hover has a slot only for the edge: no per-state tint or label is emitted" do
      for {_key, declarations} <- emitted(162, 0.15) do
        hover_slots =
          declarations |> Enum.map(&elem(&1, 0)) |> Enum.filter(&String.contains?(&1, "hover"))

        assert hover_slots == ["--scope-edge-hover-100", "--scope-edge-hover-200"]
      end
    end

    test "globex, the shipped hue, is emitted at AA on both surfaces in both themes" do
      # globex is called out by name because it is where a recomputation went
      # wrong: at oklch(51% 0.15 162) the linear-sRGB red channel is
      # -0.041996, i.e. outside the sRGB gamut, and `ScopeColor`'s private
      # `encode/1` used to fold that sign with `abs/1` instead of clipping
      # it, reporting 4.37 where Chrome 152 paints rgb(0,127,74) and
      # measures 4.56. Stage 4 fixed it to clip; 4.37 is withdrawn and is
      # asserted against in ScopeColorTest.
      #
      # Since task 01a09333-d374 stage 5 globex is solved at its SHIPPED fill
      # lightness, 70%, carried on its row as `color_lightness`. The full
      # gate for the six, globex's figures included, is
      # `ScopeColorStylesShippedSixTest`.
      ramp = ScopeColor.derive(162, 0.15, 0.70)
      html = render([%{slug: "globex", label: "Globex", hue: 162, chroma: 0.15, lightness: 0.70}])

      assert html =~ "--scope-fill:oklch(70% 0.15 162)"

      for theme <- [:light, :dark],
          {property, value} <- ScopeColorStyles.surface_slots(ramp, theme) do
        assert html =~ "#{property}:#{value}"
      end

      assert ramp.contrast_light >= 4.5
      assert ramp.contrast_dark >= 4.5
    end

    test "a stored fill lightness is honoured, and an absent one takes the 72% default" do
      at_default = emitted_with(%{hue: 95, chroma: 0.16})
      at_eighty = emitted_with(%{hue: 95, chroma: 0.16, lightness: 0.80})

      assert fill_of(at_default) == "oklch(72% 0.16 95)"
      assert fill_of(at_eighty) == "oklch(80% 0.16 95)"

      # The lightness reaches every slot, not only the fill: the tints are
      # composites of the fill, so they differ too.
      refute slot_of(at_default, "--scope-tint-100") == slot_of(at_eighty, "--scope-tint-100")

      ramp = ScopeColor.derive(95, 0.16, 0.80)

      for theme <- [:light, :dark], pair <- ScopeColorStyles.surface_slots(ramp, theme) do
        assert pair in Map.fetch!(at_eighty, {"acme", theme}),
               "#{inspect(pair)} is not derive/3's value at the stored lightness"
      end
    end

    test "a lightness outside (0, 1) is ignored rather than solved" do
      # The column's CHECK constraint refuses these; this is the backstop for
      # a row that never passed it.
      for bad <- [0, 0.0, 1.0, 1.5, -0.2, "0.8"] do
        assert fill_of(emitted_with(%{hue: 95, chroma: 0.16, lightness: bad})) ==
                 "oklch(72% 0.16 95)",
               inspect(bad)
      end
    end

    test "no hue drops its row: every value the solver produces passes the value whitelist" do
      # The whitelist drops a row whose value falls outside it. That is a
      # backstop, so it must never fire on a real solve: a dropped row
      # renders the org grey, with no error.
      for hue <- 0..359, chroma <- [0.05, 0.15, 0.28] do
        css = ScopeColorStyles.css_for([%{slug: "acme", label: "Acme", hue: hue, chroma: chroma}])
        assert map_size(parse(css)) == 2, "hue #{hue} C=#{chroma} dropped its row"
      end
    end
  end

  describe "the value whitelist" do
    test "admits exactly a lowercase #rrggbb and a numeric oklch()" do
      for good <- [
            "#ffffff",
            "#0a1b2c",
            "oklch(72% 0.15 162)",
            "oklch(15% 0 0)",
            "oklch(50.5% 1.0e-4 7)"
          ] do
        assert ScopeColorStyles.safe_value?(good), "#{inspect(good)} was refused"
      end

      for bad <- [
            "#FFFFFF",
            "#fff",
            "#fffffff",
            "red",
            "var(--scope-fill)",
            "#ffffff;color:red",
            "#ffffff}body{display:none",
            "#ffffff\n",
            "oklch(72% 0.15 162) }",
            "oklch(72% 0.15 162 / 12%)",
            ~s|oklch(72% 0.15 "162")|,
            "",
            nil,
            {1, 2, 3}
          ] do
        refute ScopeColorStyles.safe_value?(bad), "#{inspect(bad)} was admitted"
      end
    end
  end

  describe "an org with no colour" do
    test "emits no rule for its slug" do
      html = render([%{slug: "colourless", label: "Colourless", hue: nil, chroma: 0.15}])

      refute html =~ "colourless"
      refute html =~ "--scope-fill"
      refute html =~ "--scope-tint"
    end

    test "does not suppress a coloured sibling in the same list" do
      html =
        render([
          %{slug: "colourless", label: "Colourless", hue: nil, chroma: 0.15},
          %{slug: "acme", label: "Acme", hue: 15, chroma: 0.15}
        ])

      refute html =~ "colourless"
      assert html =~ ~s([data-scope="acme"]{)
    end
  end

  describe "a slug that never passed the changeset" do
    test "is dropped, and neither quote nor brace reaches the stylesheet" do
      hostile = ~s(evil"]{color:red}body{display:none)

      html =
        render([
          %{slug: hostile, label: "Evil", hue: 200, chroma: 0.15},
          %{slug: "acme", label: "Acme", hue: 15, chroma: 0.15}
        ])

      refute html =~ "evil"
      refute html =~ "display:none"

      # The legitimate sibling still renders — the guard drops a row, it does
      # not abandon the block. Without this the test would pass on a
      # component that emitted nothing at all.
      assert html =~ ~s([data-scope="acme"]{)

      # Nothing inside any selector but the one slug we authorised. Strip the
      # known-good rules and assert what is left carries no CSS punctuation
      # from the hostile string.
      selectors = Regex.scan(~r/\[data-scope="([^"]*)"\]/, html) |> Enum.map(&Enum.at(&1, 1))
      assert selectors == ["acme", "acme"]
    end

    test "drops the other CSS-breaking characters too" do
      for bad <- [
            ~s(a"b),
            "a}b",
            "a{b",
            "a;b",
            "a<b",
            "A-upper",
            "1leading",
            "has space",
            "",
            "acme\n",
            "\nacme"
          ] do
        assert ScopeColorStyles.css_for([%{slug: bad, label: "x", hue: 15, chroma: 0.15}]) == "",
               "slug #{inspect(bad)} was not dropped"
      end
    end

    test "accepts every character the changeset's own regex allows" do
      refute ScopeColorStyles.css_for([%{slug: "a-b_c9", label: "x", hue: 15, chroma: 0.15}]) ==
               ""
    end
  end
end
