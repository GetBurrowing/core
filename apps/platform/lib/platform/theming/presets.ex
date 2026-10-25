defmodule Platform.Theming.Presets do
  @moduledoc """
  The five shipped presets, parsed at compile time from
  `assets/css/theme_presets.css` and `assets/css/app.css` (task 01a1557a-fe9b
  stage 1), and mapped back to the masters' theme keys.

  Burrow is app.css's daisyUI blocks plus its theme-scoped selectors and
  `:root`, resolved the way the guards resolve it
  (`Platform.Design.ThemeBlocks.burrow_block/2`); the other four are their
  preset blocks. Nothing here holds a colour: every value is read from the
  stylesheets, and the module recompiles when either file changes.

  A preset is `%{id, name, default_mode, light, dark, shape, variants}`:

    * `light` / `dark` — master key => lowercase `#rrggbb`, the shape an org
      theme stores, so a preset can seed a draft; every slot the block
      declares apart from what the master keys alone paint (an agent's
      text colour, a `-content` slot, the ring colour) is carried as its
      optional key (`Tokens.override_slots/0`), so an unmodified draft
      seeded from a preset paints every colour slot as the block does;
    * `shape` — mode-independent; `glass_alpha` is the higher of the two
      modes' declared floors, so a draft seeded from it clears both;
    * `variants` — per mode, every slot exactly as the block declares it
      (`Platform.Theming.Tokens.variant/2` returns it as is), so a preset's
      ledger measures what its block paints, not a re-derivation.
  """

  alias Platform.Accounts.ThemePreference
  alias Platform.Theming.PresetParser

  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)

  @external_resource @presets_path
  @external_resource @app_css_path

  @presets PresetParser.parse(File.read!(@presets_path), File.read!(@app_css_path))

  @doc "The five shipped presets, in `ThemePreference.presets/0` order."
  @spec all() :: [map()]
  def all, do: @presets

  @doc "One shipped preset by id, or nil."
  @spec get(String.t()) :: map() | nil
  def get(id), do: Enum.find(@presets, &(&1.id == id))

  @doc "The preset an org theme is seeded from when no palette is given."
  @spec base() :: map()
  def base, do: get(ThemePreference.base_preset())
end
