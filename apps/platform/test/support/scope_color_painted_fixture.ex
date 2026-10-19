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
  fragments the measurement used (`vandelay-ind`, not the row's `vandelay_ind`).
  """
  def tints do
    %{
      {"legacy", "base-100"} => {"#FDF0E7", 4.6121},
      {"initech", "base-100"} => {"#F3EDFE", 4.6375},
      {"vandelay-ind", "base-100"} => {"#E3F4FD", 4.6738},
      {"globex", "base-100"} => {"#E3F7F0", 4.5539},
      {"hooli", "base-100"} => {"#FBF7E3", 4.6724},
      {"wonka", "base-100"} => {"#FBEBF6", 4.6142},
      {"legacy", "base-200"} => {"#F1E4DB", 4.1375},
      {"initech", "base-200"} => {"#E7E1F2", 4.1560},
      {"vandelay-ind", "base-200"} => {"#D7E8F1", 4.1914},
      {"globex", "base-200"} => {"#D7EBE4", 4.0857},
      {"hooli", "base-200"} => {"#EFEBD7", 4.1982},
      {"wonka", "base-200"} => {"#EFDFEA", 4.1349}
    }
  end

  @doc """
  The painted light-theme label bytes of the six shipped `.text-<slug>-label`
  values (the one label each org wore on every surface before stage 5).
  """
  def labels do
    %{
      "legacy" => {183, 77, 0},
      "initech" => {126, 78, 215},
      "vandelay-ind" => {0, 112, 181},
      "globex" => {0, 127, 74},
      "hooli" => {140, 106, 0},
      "wonka" => {182, 55, 149}
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
      {"initech", "base-100"} => {0, 1, 0},
      {"legacy", "base-200"} => {1, 0, 1},
      {"initech", "base-200"} => {0, 1, 1},
      {"vandelay-ind", "base-200"} => {1, 0, 0},
      {"hooli", "base-200"} => {0, 0, 1}
    }
  end

  @doc "`\"#RRGGBB\"` (either case) as integer bytes."
  def bytes("#" <> hex) do
    <<r::binary-2, g::binary-2, b::binary-2>> = hex
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end
end
