defmodule Platform.Chat.Canvas.Theme do
  @moduledoc """
  Canvas theme resolution (ADR 0036, Phase 5).

  A theme is a map of design tokens (colors, typography scales, radii). Each
  kind module consumes a small subset at render time. Themes are stored in the
  canvas document under `theme` (or `meta.theme` for per-canvas overrides),
  and are patchable like any other prop — agents and humans can both update
  them via `canvas.patch`.

  ## Tokens

  Current tokens (all optional):

    * `tone` — `"neutral" | "info" | "warning" | "critical" | "success"`
    * `density` — `"compact" | "comfortable" | "spacious"`
    * `emphasis` — `"subdued" | "default" | "elevated"`
    * `accent` — Tailwind color hint (`"primary" | "secondary" | "accent"`)

  ## Class override escape hatch

  Every kind accepts a `class_overrides` prop — a freeform Tailwind class
  string appended after variant resolution. Gated by a per-space capability
  flag (`canvas_class_overrides_enabled`); casual canvases should not become
  CSS playgrounds, but the affordance exists where the use case demands it.
  """

  @type theme :: map()
  @type token ::
          {:tone, String.t()}
          | {:density, String.t()}
          | {:emphasis, String.t()}
          | {:accent, String.t()}

  @doc """
  Resolve a theme token to a list of Tailwind classes.

  Falls back to safe defaults when the token isn't present. Unknown values
  map to `[]` so agents can't inject arbitrary strings.
  """
  @spec resolve(theme(), atom()) :: [String.t()]
  def resolve(theme, token) when is_map(theme) do
    theme
    |> Map.get(Atom.to_string(token))
    |> classes_for(token)
  end

  def resolve(_theme, _token), do: []

  @doc """
  Resolve multiple tokens into a single class list, in declaration order.
  """
  @spec resolve_all(theme(), [atom()]) :: [String.t()]
  def resolve_all(theme, tokens) when is_list(tokens) do
    Enum.flat_map(tokens, &resolve(theme, &1))
  end

  @doc """
  Return the theme map from a canvas document, falling back to `%{}`.
  """
  @spec from_document(map()) :: theme()
  def from_document(%{"theme" => t}) when is_map(t), do: t
  def from_document(_), do: %{}

  # ── Token → class mapping ──────────────────────────────────────────────

  defp classes_for("info", :tone), do: ["bg-info/10", "text-info"]
  defp classes_for("warning", :tone), do: ["bg-warning/10", "text-warning"]
  defp classes_for("critical", :tone), do: ["bg-error/10", "text-error"]
  defp classes_for("success", :tone), do: ["bg-success/10", "text-success"]
  defp classes_for("neutral", :tone), do: []
  defp classes_for(_, :tone), do: []

  defp classes_for("compact", :density), do: ["gap-1", "p-2"]
  defp classes_for("comfortable", :density), do: ["gap-2", "p-3"]
  defp classes_for("spacious", :density), do: ["gap-4", "p-5"]
  defp classes_for(_, :density), do: []

  defp classes_for("subdued", :emphasis), do: ["opacity-70"]
  defp classes_for("elevated", :emphasis), do: ["shadow-md"]
  defp classes_for(_, :emphasis), do: []

  defp classes_for("primary", :accent), do: ["text-primary"]
  defp classes_for("secondary", :accent), do: ["text-secondary"]
  defp classes_for("accent", :accent), do: ["text-accent"]
  defp classes_for(_, :accent), do: []
end
