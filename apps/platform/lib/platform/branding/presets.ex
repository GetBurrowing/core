defmodule Platform.Branding.Presets do
  @moduledoc """
  The catalogue of starting palettes the branding admin page offers
  (task 01a0dbee-f598-7001-b450-7890103f44c4 stage 3).

  Each preset is `%{key, name, light: %{action, surface, accent},
  dark: %{action, surface, accent}}` in the shape `Branding.app_colors/1`
  returns, so applying one is `Branding.update_colors/2` with the six colours
  plus `color_preset: key`.

  ## `suite_default` is first and is all nil

  Its values are nil in every slot on purpose. Applying it writes the same row
  `Branding.reset_colors/1` writes, so "Reset to Burrow default restores
  today's look exactly" is literally true: nil means `app.css` stands, not a
  derived approximation of it. The key stays `suite_default` because it is
  stored data (`install_branding.color_preset`); only the displayed name moved
  to "Burrow default" (task 01a120c5).

  ## The rest are published open palettes

  Each value is taken from that palette's own published spec; the source is
  cited on the preset. Presets are held to exactly the checks a manual pick is:
  `presets_test.exs` asserts `Palette.checks/2` returns no `:block` for any
  preset in either mode, so a preset that could not be saved by hand cannot
  ship here either. Warnings are allowed (a preset's action colour may, say,
  read as the info hue) and are surfaced by the admin page like any other.

  The GitHub-derived pair is named descriptively ("Paper") rather than after
  the company, per open question 1 on the design canvas. Renaming it is a one
  string change to `name` below; the `key` is what is stored, so a rename does
  not orphan installs that already applied it.

  An accent of nil follows the action colour, as it does for a manual pick.
  """

  alias Platform.Branding.Contrast

  @type colours :: %{
          action: String.t() | nil,
          surface: String.t() | nil,
          accent: String.t() | nil
        }
  @type t :: %{key: String.t(), name: String.t(), light: colours(), dark: colours()}

  @nil_mode %{action: nil, surface: nil, accent: nil}

  @presets [
    %{
      key: "suite_default",
      name: "Burrow default",
      light: @nil_mode,
      dark: @nil_mode
    },
    # Nord, https://www.nordtheme.com/docs/colors-and-palettes
    # Light: Snow Storm nord6 surface, Frost nord10 action, Frost nord8 accent.
    # Dark: Polar Night nord0 surface, Frost nord8 action, Frost nord9 accent.
    %{
      key: "nord",
      name: "Nord",
      light: %{action: "#5e81ac", surface: "#eceff4", accent: "#88c0d0"},
      dark: %{action: "#88c0d0", surface: "#2e3440", accent: "#81a1c1"}
    },
    # Dracula, https://draculatheme.com/spec
    # Light is the official Alucard variant: Background #fffbeb, Purple #644ac9,
    # Pink #a3144d. Dark is Dracula: Background #282a36, Purple #bd93f9,
    # Pink #ff79c6.
    %{
      key: "dracula",
      name: "Dracula",
      light: %{action: "#644ac9", surface: "#fffbeb", accent: "#a3144d"},
      dark: %{action: "#bd93f9", surface: "#282a36", accent: "#ff79c6"}
    },
    # Solarized, https://ethanschoonover.com/solarized/
    # Light: base3 #fdf6e3 surface. Dark: base03 #002b36 surface. Both modes use
    # blue #268bd2 for action and cyan #2aa198 for accent, as Solarized's accent
    # colours are shared between its light and dark modes.
    %{
      key: "solarized",
      name: "Solarized",
      light: %{action: "#268bd2", surface: "#fdf6e3", accent: "#2aa198"},
      dark: %{action: "#268bd2", surface: "#002b36", accent: "#2aa198"}
    },
    # One Dark / One Light (Atom), the syntax theme colour files:
    # https://github.com/atom/atom/blob/master/packages/one-light-syntax/styles/colors.less
    # https://github.com/atom/atom/blob/master/packages/one-dark-syntax/styles/colors.less
    # Light: syntax-bg hsl(230, 1%, 98%) #fafafa, hue-2 blue hsl(221, 87%, 60%)
    # #4078f2, hue-3 purple hsl(301, 63%, 40%) #a626a4.
    # Dark: syntax-bg hsl(220, 13%, 18%) #282c34, hue-2 blue #61afef,
    # hue-3 purple #c678dd.
    %{
      key: "one",
      name: "One",
      light: %{action: "#4078f2", surface: "#fafafa", accent: "#a626a4"},
      dark: %{action: "#61afef", surface: "#282c34", accent: "#c678dd"}
    },
    # Paper: GitHub's Primer palette, https://primer.style/foundations/primitives/color
    # Light: canvas.default #ffffff, accent.emphasis #0969da.
    # Dark: canvas.default #0d1117, accent.emphasis #1f6feb.
    # Primer's primary button is green; the blue accent is used as the action
    # colour instead so buttons do not read as the success status colour.
    %{
      key: "paper",
      name: "Paper",
      light: %{action: "#0969da", surface: "#ffffff", accent: nil},
      dark: %{action: "#1f6feb", surface: "#0d1117", accent: nil}
    }
  ]

  @doc "Every preset, `suite_default` first, in the order the admin page shows them."
  @spec all() :: [t()]
  def all, do: @presets

  @doc "The preset stored under `key`, or nil."
  @spec get(String.t() | nil) :: t() | nil
  def get(key) when is_binary(key), do: Enum.find(@presets, &(&1.key == key))
  def get(_), do: nil

  @doc """
  What to call the colours currently saved.

    * the preset's name when `color_preset_key` names a preset and the current
      values equal it exactly, in both modes;
    * `"Custom (from <Name>)"` when a preset is stored but a value was edited
      after applying it;
    * `"Custom"` when no preset is stored (or the stored key no longer names
      one).

  One special case of "no key": a row with no key and every colour nil IS the
  Suite default (that is exactly what `Branding.reset_colors/1` writes), so it
  is labelled with the default's name rather than "Custom".

  `current_values` is the shape `Branding.app_colors/1` returns. Hexes are
  compared case-insensitively.
  """
  @spec label(String.t() | nil, %{light: map(), dark: map()}) :: String.t()
  def label(color_preset_key, current_values) do
    case get(color_preset_key) do
      nil ->
        default = hd(@presets)
        if matches?(default, current_values), do: default.name, else: "Custom"

      preset ->
        if matches?(preset, current_values),
          do: preset.name,
          else: "Custom (from #{preset.name})"
    end
  end

  defp matches?(preset, current) do
    Enum.all?([:light, :dark], fn mode ->
      mode_values = Map.get(current, mode) || %{}

      Enum.all?([:action, :surface, :accent], fn slot ->
        normalize(Map.get(preset[mode], slot)) == normalize(Map.get(mode_values, slot))
      end)
    end)
  end

  defp normalize(nil), do: nil

  defp normalize(hex) when is_binary(hex) do
    case Contrast.normalize_hex(hex) do
      {:ok, normalized} -> normalized
      :error -> hex
    end
  end
end
