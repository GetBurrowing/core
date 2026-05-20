defmodule PlatformWeb.Components.ScopePill do
  @moduledoc """
  Scope-provenance pill — labels an item with the org-scope it belongs to,
  and optionally where it was propagated to.

  Part of the Suite scope-provenance system (sibling to icon-rail). Lives on
  the `ui-foundation-primitives` stack alongside other low-level chrome.

  ## Purpose

  Suite is a Linear-style unified workspace (one view, filterable) — NOT a
  Discord-style org switcher. Fabrikam admins see ALL orgs at once; the scope
  pill is the filter affordance.

  * Click a pill → narrows the surface to that scope (parent LV handles
    `"scope_filter"` event, reads `phx-value-scope`, then
    `push_patch(to: ~p"/...?scope=\#{scope}")` so the filter state lives
    in the URL query string — shareable links, back-button, deep linking).
  * Active pill stays highlighted to indicate the current filter (the
    `:active` attr — Stage 4 styling).

  ## Variants

  * Single scope — colored dot + label, low-saturation 12% background.
  * Propagated — two chips joined by a `hero-arrow-right` heroicon
    (renders when `:propagated_to` is set).
  * Clickable (default) — renders as a `<button>` with `phx-click`.
  * Non-clickable — renders as a `<span>` at 0.55 opacity (Marlowe approved
    2026-05-18) so context is still visible but no affordance.
  * Active — full-saturation fill + check icon (filtered-to-this-scope).

  ## Accessibility

  The colored dot acts as a redundant signal beyond color alone (WCAG 1.4.1
  Use of Color). Screen readers get scope context via `aria-label` even
  on the non-clickable variant.

  ## Scope-color centralization

  Scope → color tokens are centralized in two places:

    * `Platform.Tenancy.scope_color/1` returns the Tailwind text-color
      utility (`text-fabrikam`, `text-soylent`, …) for any scope slug.
    * `apps/platform/assets/css/app.css` defines the matching `bg-*`,
      `border-*`, `bg-*-active`, `bg-*-dot`, and `hover:bg-*/22`
      utilities — all anchored to the same `oklch(...)` literals.

  This component was previously inlining `bg-[oklch(...)]` arbitrary-value
  classes; Stage 2 of Working surfaces plan v4 retired that pattern in
  favor of the named utilities. The public `:scope` attr API is unchanged.

  ## Examples

      <.scope_pill scope={:fabrikam} />
      <.scope_pill scope={:soylent} propagated_to={:fabrikam} />
      <.scope_pill scope={:wayne_tech} clickable={false} />
      <.scope_pill scope={:sxi} active={true} />
  """
  use Phoenix.Component
  import PlatformWeb.CoreComponents, only: [icon: 1]

  @scopes [:fabrikam, :soylent, :wayne_tech, :sxi, :paragon]

  @doc """
  The canonical list of scope atoms, in display order.

  Used by tests and any caller that needs to iterate the scope enum without
  hard-coding it locally.
  """
  def scopes, do: @scopes

  attr(:scope, :atom,
    required: true,
    values: @scopes,
    doc: "The primary scope this pill represents."
  )

  attr(:propagated_to, :atom,
    default: nil,
    values: [nil, :fabrikam, :soylent, :wayne_tech, :sxi, :paragon],
    doc:
      "When set, renders the propagated variant — `<scope> → <propagated_to>` joined by a hero-arrow-right glyph."
  )

  attr(:clickable, :boolean,
    default: true,
    doc:
      "When true (default), renders as a `<button>` with `phx-click=\"scope_filter\"`. When false, renders as a non-interactive `<span>` at 0.55 opacity."
  )

  attr(:active, :boolean,
    default: false,
    doc:
      "When true, applies the active-filter visual treatment (full saturation, check-icon, soft outer ring). Used by parent LVs to signal the current filter."
  )

  def scope_pill(assigns) do
    ~H"""
    <%= if @propagated_to do %>
      <span class="scope-pill-propagated inline-flex items-center gap-1">
        {render_chip(%{
          scope: @scope,
          clickable: @clickable,
          active: @active,
          propagated_to: @propagated_to,
          role: :source
        })}
        <.icon name="hero-arrow-right" class="size-3 text-base-content/60" />
        {render_chip(%{
          scope: @propagated_to,
          clickable: @clickable,
          active: @active,
          propagated_to: @propagated_to,
          role: :target
        })}
      </span>
    <% else %>
      {render_chip(%{
        scope: @scope,
        clickable: @clickable,
        active: @active,
        propagated_to: nil,
        role: :single
      })}
    <% end %>
    """
  end

  # ── Chip rendering ──────────────────────────────────────────────────

  defp render_chip(assigns) do
    ~H"""
    <%= if @clickable do %>
      <button
        type="button"
        phx-click="scope_filter"
        phx-value-scope={@scope}
        phx-value-propagated-to={@propagated_to}
        class={[
          chip_base_classes(),
          chip_color_classes(@scope, @active),
          "focus-visible-ring cursor-pointer",
          not @active && chip_hover_classes(@scope)
        ]}
        aria-label={aria_label(@scope, @active)}
        aria-pressed={if @active, do: "true", else: "false"}
      >
        {chip_inner(assigns)}
      </button>
    <% else %>
      <span
        class={[
          chip_base_classes(),
          chip_color_classes(@scope, @active),
          "opacity-55"
        ]}
        aria-label={aria_label_static(@scope)}
      >
        {chip_inner(assigns)}
      </span>
    <% end %>
    """
  end

  defp chip_inner(assigns) do
    ~H"""
    <%= if @active do %>
      <.icon name="hero-check" class="size-[13px]" />
    <% else %>
      <span
        class={["inline-block size-2 rounded-full", scope_dot(@scope)]}
        aria-hidden="true"
      />
    <% end %>
    <span class="scope-pill-label">{scope_label(@scope)}</span>
    """
  end

  defp chip_base_classes do
    "inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-xs font-medium leading-none transition-colors"
  end

  # ── Color mapping ───────────────────────────────────────────────────
  #
  # Resolves to the named utility classes defined in `app.css` (and
  # surfaced as text-utilities by `Platform.Tenancy.scope_color/1`). The
  # oklch literals themselves live in `app.css`; if you need to change a
  # scope color, edit it there.
  #
  # Default (`active: false`) chip uses the 12% color-mix bg, the
  # full-saturation text, and the 30% color-mix border. Active chip uses
  # the full-saturation `bg-<slug>-active` (which also bakes in the
  # contrast-safe text and shadow ring).

  defp chip_color_classes(scope, false) do
    [
      "bg-#{slug(scope)}",
      Platform.Tenancy.scope_color(scope),
      "border-#{slug(scope)}"
    ]
  end

  defp chip_color_classes(scope, true) do
    "bg-#{slug(scope)}-active"
  end

  # Hover state — bump default 12% bg to 22% color-mix on the button variant only.
  defp chip_hover_classes(scope), do: "hover:bg-#{slug(scope)}/22"

  # Dot color — full saturation, redundant-signal-beyond-color cue.
  defp scope_dot(scope), do: "bg-#{slug(scope)}-dot"

  # Atom slug → kebab-case fragment used in the Tailwind utility class names
  # (e.g. :wayne_tech → "wayne-tech" so we get `bg-wayne-tech`).
  defp slug(:fabrikam), do: "fabrikam"
  defp slug(:soylent), do: "soylent"
  defp slug(:wayne_tech), do: "wayne-tech"
  defp slug(:sxi), do: "sxi"
  defp slug(:paragon), do: "paragon"

  # ── Labels ─────────────────────────────────────────────────────────

  defp scope_label(:fabrikam), do: "Fabrikam"
  defp scope_label(:soylent), do: "Soylent"
  defp scope_label(:wayne_tech), do: "Wayne-Tech"
  defp scope_label(:sxi), do: "SXI"
  defp scope_label(:paragon), do: "Paragon"

  defp aria_label(scope, true), do: "Currently filtered by #{scope_label(scope)} scope"
  defp aria_label(scope, false), do: "Filter by #{scope_label(scope)} scope"

  defp aria_label_static(scope), do: "#{scope_label(scope)} scope"
end
