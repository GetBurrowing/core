defmodule Platform.Theming.OrgThemeTest do
  @moduledoc """
  `Platform.Theming.OrgTheme`'s changeset (task 01a1557a-fe9b stage 1): shape
  bounds, colours stored as lowercase `#rrggbb` only, unknown keys refused.

  No colour literal appears here: every palette starts from a shipped preset
  (`Platform.Theming.Presets`) and test colours are built from bytes.
  """
  use ExUnit.Case, async: true

  alias Platform.Theming.OrgTheme
  alias Platform.Theming.Presets
  alias Platform.Theming.Tokens

  defp hex(r, g, b), do: "#" <> Base.encode16(<<r, g, b>>, case: :lower)

  # The #rgb form of three nibbles, upper case.
  defp short(r, g, b), do: "#" <> Enum.map_join([r, g, b], &Integer.to_string(&1, 16))

  defp base, do: Presets.base()

  defp changeset(attrs) do
    b = base()

    %OrgTheme{org_id: Ecto.UUID.generate(), status: "draft"}
    |> OrgTheme.changeset(
      Map.merge(%{name: "Ours", light: b.light, dark: b.dark, shape: b.shape}, attrs)
    )
  end

  defp error_on(cs, field), do: cs.errors |> Keyword.get_values(field) |> Enum.map(&elem(&1, 0))

  describe "colours" do
    test "the stored keys are theme.js's keys with an app slot, and no others" do
      keys = Tokens.color_keys()

      for gone <- ~w(desk faint bubbleMe dangerDim scrim shade), do: refute(gone in keys)

      for kept <-
            ~w(ground surface raised edge ink muted accent interactive onAccent agTeal agLime info infoDim active activeDim warning warningDim danger viewer stage),
          do: assert(kept in keys)

      assert length(keys) == length(Enum.uniq(keys))
    end

    test "#rgb, upper-case #RRGGBB and oklch() are normalised to lowercase #rrggbb" do
      assert OrgTheme.normalise_color(short(10, 11, 12)) == {:ok, hex(0xAA, 0xBB, 0xCC)}

      assert OrgTheme.normalise_color(String.upcase(hex(0x12, 0xAB, 0xEF))) ==
               {:ok, hex(0x12, 0xAB, 0xEF)}

      assert OrgTheme.normalise_color("oklch(100% 0 0)") == {:ok, hex(255, 255, 255)}
      assert OrgTheme.normalise_color("oklch(0% 0 0)") == {:ok, hex(0, 0, 0)}

      # A chromatic oklch lands on the 8-bit value it paints as.
      {:ok, painted} = OrgTheme.normalise_color("oklch(63% 0.22 25)")
      assert painted =~ ~r/^#[0-9a-f]{6}$/
    end

    test "anything but hex or oklch() is refused" do
      for bad <- [
            "red",
            "rgb(1, 2, 3)",
            String.slice(hex(1, 2, 3), 0, 5),
            "#ggg",
            hex(1, 2, 3) <> "ff",
            "",
            "oklch(50 0.1 3)",
            42,
            nil
          ] do
        assert {:error, _} = OrgTheme.normalise_color(bad), inspect(bad)
      end
    end

    test "a palette stores only lowercase #rrggbb" do
      light = Map.put(base().light, "accent", "oklch(50% 0.1 40)")
      cs = changeset(%{light: Map.put(light, "ink", short(10, 11, 12))})

      assert cs.valid?
      stored = Ecto.Changeset.get_field(cs, :light)
      assert Enum.all?(Map.values(stored), &Regex.match?(~r/^#[0-9a-f]{6}$/, &1))
      assert stored["ink"] == hex(0xAA, 0xBB, 0xCC)
    end

    test "an unknown colour key is refused, never dropped" do
      for extra <- ["faint", "desk", "bubbleMe", "dangerDim", "--color-base-100", "nope"] do
        cs = changeset(%{dark: Map.put(base().dark, extra, hex(1, 2, 3))})
        refute cs.valid?, extra
        assert [msg] = error_on(cs, :dark)
        assert msg =~ "unknown keys" and msg =~ extra
      end
    end

    test "a missing colour key is refused" do
      cs = changeset(%{light: Map.delete(base().light, "ink")})
      refute cs.valid?
      assert [msg] = error_on(cs, :light)
      assert msg =~ "missing keys: ink"
    end

    test "atom keys are read by name; nothing becomes an atom" do
      light = base().light
      atomised = light |> Map.delete("ground") |> Map.put(:ground, light["ground"])
      assert changeset(%{light: atomised}).valid?

      unknown = "zz_never_an_atom_#{System.unique_integer([:positive])}"
      cs = changeset(%{light: Map.put(light, unknown, hex(1, 2, 3))})
      refute cs.valid?
      assert [msg] = error_on(cs, :light)
      assert msg =~ unknown
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end
  end

  describe "shape" do
    test "every bound holds at its edges and refuses one step past them" do
      floor = OrgTheme.glass_alpha_floor()

      ok = [
        {"radius", 4},
        {"radius", 28},
        {"density", 0.8},
        {"density", 1.3},
        {"glass_alpha", floor},
        {"glass_alpha", 1},
        {"glass_blur", 0},
        {"glass_blur", 40}
      ]

      bad = [
        {"radius", 3},
        {"radius", 29},
        {"radius", 12.5},
        {"density", 0.79},
        {"density", 1.31},
        {"glass_alpha", Float.round(floor - 0.01, 2)},
        {"glass_alpha", 1.01},
        {"glass_blur", -1},
        {"glass_blur", 41},
        {"glass_blur", "lots"}
      ]

      for {k, v} <- ok do
        assert changeset(%{shape: Map.put(base().shape, k, v)}).valid?, "#{k} #{inspect(v)}"
      end

      for {k, v} <- bad do
        refute changeset(%{shape: Map.put(base().shape, k, v)}).valid?, "#{k} #{inspect(v)}"
      end
    end

    test "the glass floor is the lowest alpha any shipped non-High-contrast variant declares" do
      declared =
        for p <- Presets.all(),
            p.id != "high-contrast",
            {_mode, v} <- p.variants,
            do: String.to_float(v.shape["--glass-alpha"])

      assert OrgTheme.glass_alpha_floor() == Enum.min(declared)
    end

    test "a font is a chip stack or matches the allowed pattern" do
      for chip <- Tokens.font_chips() do
        assert changeset(%{shape: Map.put(base().shape, "font", chip)}).valid?
      end

      assert length(Tokens.font_chips()) == 5
      assert changeset(%{shape: Map.put(base().shape, "font", ~s('Acme Sans', serif))}).valid?

      for bad <- ["a; color: red", "x{}", "url(evil)", String.duplicate("a", 121), "", 7] do
        refute changeset(%{shape: Map.put(base().shape, "font", bad)}).valid?, inspect(bad)
      end
    end

    test "an unknown or missing shape key is refused" do
      refute changeset(%{shape: Map.put(base().shape, "fontSize", 15)}).valid?
      refute changeset(%{shape: Map.delete(base().shape, "radius")}).valid?
    end
  end

  test "name, default mode and preset id" do
    refute changeset(%{name: ""}).valid?
    refute changeset(%{name: String.duplicate("n", 81)}).valid?
    assert changeset(%{name: String.duplicate("n", 80)}).valid?
    refute changeset(%{default_mode: "system"}).valid?
    assert changeset(%{default_mode: "light"}).valid?

    assert OrgTheme.preset_id(%OrgTheme{id: "abc"}) == "org-abc"
  end
end
