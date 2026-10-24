defmodule Platform.Agents.ColorPalette do
  @moduledoc """
  The ten agent identity slots.

  An agent stores a slot id (`agents.color`, e.g. `"purple"`). The id resolves
  to THEME TOKENS, not to a colour: every theme block (app.css's two Burrow
  daisyUI blocks and each preset block in `assets/css/theme_presets.css`)
  declares, per slot,

    * `--ag-<id>`: the full-strength hue, for the rail, the avatar ring and the
      AI pill's border (non-text, 3:1);
    * `--ag-<id>-text`: the name and AI-pill text colour, chosen so it clears
      4.5:1 (7:1 in high contrast) on the painted tint;

  and app.css derives the opaque `--ag-<id>-tint` from the block's
  `--ag-tint-pct` (there is no hover tint). So one stored id paints a
  different, separately measured value under each preset and mode, and no
  colour value lives in Elixir. `token/1` names the base token; the guard in
  `test/platform/design/agent_slot_tokens_guard_test.exs` holds the values.

  `slot_for/1` is the resolver: a nil, blank or unknown stored id is the blue
  slot. A surface renders `data-agent-slot="<id>"`, and app.css's ten pointer
  rules (`[data-agent-slot="<id>"]`) point `--ag`, `--ag-text` and `--ag-tint`
  at that slot's tokens; the colour pickers read `var(<token>)` directly.
  The pre-token OKLCH accent strings (`accent_for/1`, `default_accent/0`,
  `:accent`) were removed in task 01a1557a rung 3 stage 2 with their last
  consumer.
  """

  @default_slot "blue"

  @colors [
    %{id: "blue", label: "Blue", token: "--ag-blue"},
    %{id: "purple", label: "Purple", token: "--ag-purple"},
    %{id: "orange", label: "Orange", token: "--ag-orange"},
    %{id: "brick", label: "Brick Red", token: "--ag-brick"},
    %{id: "green", label: "Green", token: "--ag-green"},
    %{id: "rose", label: "Rose", token: "--ag-rose"},
    %{id: "amber", label: "Amber", token: "--ag-amber"},
    %{id: "teal", label: "Teal", token: "--ag-teal"},
    %{id: "indigo", label: "Indigo", token: "--ag-indigo"},
    %{id: "lime", label: "Lime", token: "--ag-lime"}
  ]

  @ids Enum.map(@colors, & &1.id)

  @doc "All available slots."
  def all, do: @colors

  @doc "Every slot id, in palette order."
  @spec ids() :: [String.t()]
  def ids, do: @ids

  @doc "The slot a stored colour id paints: nil, blank or unknown is \"#{@default_slot}\"."
  @spec slot_for(String.t() | nil) :: String.t()
  def slot_for(color_id) when is_binary(color_id) and color_id in @ids, do: color_id
  def slot_for(_), do: @default_slot

  @doc "The base token of a slot, `\"--ag-<id>\"`; nil, blank or unknown is blue's."
  @spec token(String.t() | nil) :: String.t()
  def token(color_id), do: "--ag-" <> slot_for(color_id)
end
