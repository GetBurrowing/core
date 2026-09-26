defmodule Platform.Branding.PresetsTest do
  # Task 01a0dbee-f598-7001-b450-7890103f44c4 stage 3: the preset catalogue.
  use ExUnit.Case, async: true

  alias Platform.Branding.{InstallBranding, Palette, Presets}

  @modes [:light, :dark]
  @slots [:action, :surface, :accent]

  describe "all/0" do
    test "keys are unique" do
      keys = Enum.map(Presets.all(), & &1.key)
      assert keys == Enum.uniq(keys)
    end

    test "names are unique" do
      names = Enum.map(Presets.all(), & &1.name)
      assert names == Enum.uniq(names)
    end

    test "suite_default is first and is nil in every slot of both modes" do
      [first | _] = Presets.all()
      assert first.key == "suite_default"

      for mode <- @modes, slot <- @slots do
        assert Map.fetch!(first[mode], slot) == nil, "suite_default #{mode}.#{slot} is not nil"
      end
    end

    test "every preset has all three slots in both modes, as lowercase #rrggbb or nil" do
      for preset <- Presets.all(), mode <- @modes do
        assert preset[mode] |> Map.keys() |> Enum.sort() == Enum.sort(@slots)

        for slot <- @slots, value = preset[mode][slot], value != nil do
          assert value =~ ~r/\A#[0-9a-f]{6}\z/, "#{preset.key} #{mode}.#{slot} = #{value}"
        end
      end
    end

    test "every preset but suite_default differs from the Suite defaults in both modes" do
      defaults = Palette.suite_defaults()

      for preset <- tl(Presets.all()), mode <- @modes do
        resolved = %{
          action: preset[mode].action,
          surface: preset[mode].surface,
          accent: preset[mode].accent || preset[mode].action
        }

        refute resolved == defaults[mode],
               "#{preset.key} #{mode} is indistinguishable from the Suite default"
      end
    end

    test "no preset, in either mode, has a contrast check that blocks" do
      results =
        for preset <- Presets.all(), mode <- @modes do
          checks = Palette.checks(mode, preset[mode])
          {preset.key, mode, checks}
        end

      # Warnings are allowed; print them so the stage report can list them.
      for {key, mode, checks} <- results, %{level: :warn} = c <- checks do
        IO.puts("[presets] #{key} #{mode} warns #{c.id}: #{c.message}")
      end

      blocks =
        for {key, mode, checks} <- results, %{level: :block} = c <- checks do
          "#{key} #{mode} #{c.id}: #{c.message}"
        end

      assert blocks == [], "presets that could not be saved by hand:\n" <> Enum.join(blocks, "\n")
    end
  end

  describe "applying a preset through the same changeset a manual pick uses" do
    test "every preset's six colours plus its key make a valid colors_changeset" do
      for preset <- Presets.all() do
        attrs =
          for mode <- @modes, slot <- @slots, into: %{color_preset: preset.key} do
            {:"#{mode}_#{slot}", preset[mode][slot]}
          end

        changeset = InstallBranding.colors_changeset(%InstallBranding{}, attrs)
        assert changeset.valid?, "#{preset.key}: #{inspect(changeset.errors)}"

        if preset.key != "suite_default" do
          assert Ecto.Changeset.get_change(changeset, :color_preset) == preset.key
        end
      end
    end
  end

  describe "get/1" do
    test "returns the preset for a known key" do
      assert %{key: "nord", name: "Nord"} = Presets.get("nord")
    end

    test "returns nil for an unknown or nil key" do
      assert Presets.get("no_such_preset") == nil
      assert Presets.get(nil) == nil
    end
  end

  describe "label/2" do
    setup do
      nord = Presets.get("nord")
      %{nord: nord, values: %{light: nord.light, dark: nord.dark}}
    end

    test "exact values under a stored key are labelled with the preset name", %{values: v} do
      assert Presets.label("nord", v) == "Nord"
    end

    test "exact comparison ignores hex case", %{values: v} do
      upper = put_in(v, [:dark, :surface], String.upcase(v.dark.surface))
      assert Presets.label("nord", upper) == "Nord"
    end

    test "an edited value under a stored key is Custom (from <Name>)", %{values: v} do
      edited = put_in(v, [:light, :action], "#123456")
      assert Presets.label("nord", edited) == "Custom (from Nord)"
    end

    test "an edit in dark mode alone still counts as an edit", %{values: v} do
      edited = put_in(v, [:dark, :accent], nil)
      assert Presets.label("nord", edited) == "Custom (from Nord)"
    end

    test "no stored key is Custom, even when the values happen to equal a preset",
         %{values: v} do
      assert Presets.label(nil, v) == "Custom"
    end

    test "a stored key that names no preset is Custom", %{values: v} do
      assert Presets.label("retired_preset", v) == "Custom"
    end

    test "suite_default applied is labelled Suite default" do
      all_nil = %{
        light: %{action: nil, surface: nil, accent: nil},
        dark: %{action: nil, surface: nil, accent: nil}
      }

      assert Presets.label("suite_default", all_nil) == "Suite default"
      # reset_colors/1 writes a nil key with every colour nil: the same look.
      assert Presets.label(nil, all_nil) == "Suite default"
    end

    test "suite_default with one colour set is Custom (from Suite default)" do
      values = %{
        light: %{action: "#ff0000", surface: nil, accent: nil},
        dark: %{action: nil, surface: nil, accent: nil}
      }

      assert Presets.label("suite_default", values) == "Custom (from Suite default)"
    end
  end
end
