defmodule Platform.Agents.ColorPaletteTest do
  use ExUnit.Case, async: true

  alias Platform.Agents.ColorPalette

  describe "all/0" do
    test "returns a non-empty list of color families" do
      colors = ColorPalette.all()
      assert is_list(colors)
      assert length(colors) > 0
    end

    test "each slot has an id, a label and a token, and no colour value" do
      for color <- ColorPalette.all() do
        assert is_binary(color.id), "expected id to be a string for #{inspect(color)}"
        assert is_binary(color.label), "expected label to be a string for #{inspect(color)}"
        assert Map.keys(color) |> Enum.sort() == [:id, :label, :token]
      end
    end

    test "the pre-token accent API is gone (task 01a1557a rung 3 stage 2)" do
      Code.ensure_loaded!(ColorPalette)
      refute function_exported?(ColorPalette, :accent_for, 1)
      refute function_exported?(ColorPalette, :default_accent, 0)
    end
  end

  describe "slots and tokens" do
    test "the ten slot ids are the masters' ten, one token each" do
      assert Enum.sort(ColorPalette.ids()) ==
               Enum.sort(~w(teal green amber orange blue purple brick rose indigo lime))

      for color <- ColorPalette.all() do
        assert color.token == "--ag-" <> color.id
        assert ColorPalette.token(color.id) == color.token
      end
    end

    test "slot_for/1 keeps a known id and resolves nil, blank and unknown to blue" do
      for id <- ColorPalette.ids(), do: assert(ColorPalette.slot_for(id) == id)

      for stored <- [nil, "", "  ", "magenta", "Purple", 42] do
        assert ColorPalette.slot_for(stored) == "blue", "stored #{inspect(stored)}"
      end
    end

    test "token/1 falls back to the blue slot's token" do
      assert ColorPalette.token(nil) == "--ag-blue"
      assert ColorPalette.token("magenta") == "--ag-blue"
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
