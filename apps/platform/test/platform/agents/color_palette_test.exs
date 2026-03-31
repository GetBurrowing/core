defmodule Platform.Agents.ColorPaletteTest do
  use ExUnit.Case, async: true

  alias Platform.Agents.ColorPalette

  describe "all/0" do
    test "returns a non-empty list of color families" do
      colors = ColorPalette.all()
      assert is_list(colors)
      assert length(colors) > 0
    end

    test "each color has id, label, and accent fields" do
      for color <- ColorPalette.all() do
        assert is_binary(color.id), "expected id to be a string for #{inspect(color)}"
        assert is_binary(color.label), "expected label to be a string for #{inspect(color)}"
        assert is_binary(color.accent), "expected accent to be a string for #{inspect(color)}"

        assert String.starts_with?(color.accent, "oklch("),
               "expected OKLCH accent for #{color.id}"
      end
    end
  end

  describe "accent_for/1" do
    test "returns default accent for nil" do
      assert ColorPalette.accent_for(nil) == ColorPalette.default_accent()
    end

    test "returns default accent for unknown color id" do
      assert ColorPalette.accent_for("nonexistent") == ColorPalette.default_accent()
    end

    test "returns the correct accent for known color ids" do
      for %{id: id, accent: expected_accent} <- ColorPalette.all() do
        assert ColorPalette.accent_for(id) == expected_accent,
               "expected accent for #{id} to be #{expected_accent}"
      end
    end

    test "blue is the default fallback" do
      assert ColorPalette.default_accent() =~ "207"
    end
  end

  describe "agent color assignment" do
    test "known agent slugs map to expected color ids" do
      colors_by_id = Map.new(ColorPalette.all(), &{&1.id, &1})

      assert Map.has_key?(colors_by_id, "purple"), "builder's purple color should be in palette"
      assert Map.has_key?(colors_by_id, "orange"), "pixel's orange color should be in palette"
      assert Map.has_key?(colors_by_id, "brick"), "beacon's brick red color should be in palette"
    end
  end
end
