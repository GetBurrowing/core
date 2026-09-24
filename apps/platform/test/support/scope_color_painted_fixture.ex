defmodule Platform.Tenancy.ScopeColorPaintedFixture do
  @moduledoc """
  The bytes a browser PAINTED for the six shipped scope orgs, measured in
  task 01a09333-d374 stage 1 and read by two tests:

    * `Platform.Tenancy.ScopeColorPaintedTest` pins the compositor's
      conventions against them;
    * `PlatformWeb.Components.ScopeColorStylesShippedSixTest` holds the
      EMITTED per-surface tints of the six against them (the stage 5 byte
      gate).

  One copy, here, because a painted value pinned in two test files under
  two attribute names is exactly the duplicate a grep for one name misses.

  Measured, never derived: DOM swatches of each `oklch(... / 12%)` painted
  over the ground, screenshotted and read back pixel-wise, reproduced byte
  for byte on two rigs (HeadlessChrome 147, and Chrome with
  `--force-color-profile=srgb` plus a canvas `fillStyle` probe). Light theme
  only: `base-100` is `oklch(100% 0 0)`, `base-200` is `oklch(96% 0 0)`
  (painted `#F2F2F2`).
  """

  @doc """
  `{slug, surface} => {painted 12% tint, recorded label-vs-tint ratio}` for
  the six orgs over the two light grounds. Slugs are the kebab-case class
  fragments the measurement used (`wayne-tech`, not the row's `wayne_tech`).
  """
  def tints do
    %{
      {"fabrikam", "base-100"} => {"#FDF0E7", 4.6121},
      {"soylent", "base-100"} => {"#F3EDFE", 4.6375},
      {"wayne-tech", "base-100"} => {"#E3F4FD", 4.6738},
      {"sxi", "base-100"} => {"#E3F7F0", 4.5539},
      {"paragon", "base-100"} => {"#FBF7E3", 4.6724},
      {"cyberdyne", "base-100"} => {"#FBEBF6", 4.6142},
      {"fabrikam", "base-200"} => {"#F1E4DB", 4.1375},
      {"soylent", "base-200"} => {"#E7E1F2", 4.1560},
      {"wayne-tech", "base-200"} => {"#D7E8F1", 4.1914},
      {"sxi", "base-200"} => {"#D7EBE4", 4.0857},
      {"paragon", "base-200"} => {"#EFEBD7", 4.1982},
      {"cyberdyne", "base-200"} => {"#EFDFEA", 4.1349}
    }
  end

  @doc """
  The painted light-theme label bytes of the six shipped `.text-<slug>-label`
  values (the one label each org wore on every surface before stage 5).
  """
  def labels do
    %{
      "fabrikam" => {183, 77, 0},
      "soylent" => {126, 78, 215},
      "wayne-tech" => {0, 112, 181},
      "sxi" => {0, 127, 74},
      "paragon" => {140, 106, 0},
      "cyberdyne" => {182, 55, 149}
    }
  end

  @doc """
  The compositor's recorded divergence from `tints/0`, per channel, as
  COMPUTED minus PAINTED. Seven cells are exact and absent from this map;
  these five are one byte high on the named channels. No mechanism for the
  byte survived testing (see `ScopeColorPaintedTest`), so this is data, not
  a rule.
  """
  def known_divergences do
    %{
      {"soylent", "base-100"} => {0, 1, 0},
      {"fabrikam", "base-200"} => {1, 0, 1},
      {"soylent", "base-200"} => {0, 1, 1},
      {"wayne-tech", "base-200"} => {1, 0, 0},
      {"paragon", "base-200"} => {0, 0, 1}
    }
  end

  @doc "`\"#RRGGBB\"` (either case) as integer bytes."
  def bytes("#" <> hex) do
    <<r::binary-2, g::binary-2, b::binary-2>> = hex
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end
end
