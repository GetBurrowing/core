defmodule Platform.Agents.ColorPalette do
  @moduledoc """
  Predefined color families for agent identity.

  Each color is an OKLCH accent string that fans out to:
  - Chat bubble border and background
  - Avatar ring
  - Agent name text
  - AI badge border/text

  The accent color is stored on the agent record as a color id (e.g. "purple").
  At render time, it resolves to an OKLCH string and is injected as a CSS custom
  property (`--agent-accent`) on each message row. The `.msg-agent*` CSS classes
  read this variable to apply per-agent color identity.
  """

  @colors [
    %{id: "blue", label: "Blue", accent: "oklch(82% 0.12 207)"},
    %{id: "purple", label: "Purple", accent: "oklch(78% 0.16 300)"},
    %{id: "orange", label: "Orange", accent: "oklch(80% 0.17 55)"},
    %{id: "brick", label: "Brick Red", accent: "oklch(72% 0.14 30)"},
    %{id: "green", label: "Green", accent: "oklch(78% 0.15 160)"},
    %{id: "rose", label: "Rose", accent: "oklch(78% 0.14 355)"},
    %{id: "amber", label: "Amber", accent: "oklch(84% 0.18 85)"},
    %{id: "teal", label: "Teal", accent: "oklch(78% 0.13 185)"},
    %{id: "indigo", label: "Indigo", accent: "oklch(74% 0.15 270)"},
    %{id: "lime", label: "Lime", accent: "oklch(82% 0.17 130)"}
  ]

  @default_accent "oklch(82% 0.12 207)"

  @doc "All available color families."
  def all, do: @colors

  @doc "The default accent color (blue) used as fallback when no color is set."
  def default_accent, do: @default_accent

  @doc "Get the accent color string for a color id, falling back to the default blue."
  def accent_for(nil), do: @default_accent

  def accent_for(color_id) when is_binary(color_id) do
    case Enum.find(@colors, &(&1.id == color_id)) do
      %{accent: accent} -> accent
      nil -> @default_accent
    end
  end
end
