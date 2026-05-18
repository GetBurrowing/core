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

  ## Futureproof seam (MT/RBAC stack)

  The private `scope_color/1` function hard-codes the 5 scope→Tailwind-class
  mappings. When the MT/RBAC `019e3c49-6983-755a-8550-d76ccd680c2c`
  (Stack B Colors+Inheritance) lands, the body of this helper becomes a
  one-line delegation to `Platform.Orgs.scope_color/1` — the component's
  public `:scope` attr API stays unchanged.

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

  # ── Color mapping (futureproof seam) ────────────────────────────────
  #
  # TODO(MT/RBAC stack 019e3c49-6983-755a-8550-d76ccd680c2c):
  # When Stack B (Colors+Inheritance) lands, replace the bodies of
  # `chip_color_classes/2`, `chip_hover_classes/1`, and `scope_dot/1`
  # with a one-line delegation to `Platform.Orgs.scope_color/1`.
  # The public `:scope` attr API of this component stays unchanged.

  # Dark-mode oklch values from the visual reference canvas
  # 019e3c34-c79f-7865-b636-d2ab60d0b556 (revision 3).
  defp chip_color_classes(:fabrikam, false),
    do: "bg-[oklch(72%_0.16_50/12%)] text-[oklch(72%_0.16_50)] border-[oklch(72%_0.16_50/30%)]"

  defp chip_color_classes(:fabrikam, true),
    do:
      "bg-[oklch(72%_0.16_50)] text-[oklch(15%_0_0)] border-[oklch(72%_0.16_50)] shadow-[0_0_0_2px_oklch(72%_0.16_50/30%)]"

  defp chip_color_classes(:soylent, false),
    do: "bg-[oklch(65%_0.20_295/12%)] text-[oklch(65%_0.20_295)] border-[oklch(65%_0.20_295/30%)]"

  defp chip_color_classes(:soylent, true),
    do:
      "bg-[oklch(65%_0.20_295)] text-[oklch(98%_0_0)] border-[oklch(65%_0.20_295)] shadow-[0_0_0_2px_oklch(65%_0.20_295/30%)]"

  defp chip_color_classes(:wayne_tech, false),
    do: "bg-[oklch(68%_0.15_240/12%)] text-[oklch(68%_0.15_240)] border-[oklch(68%_0.15_240/30%)]"

  defp chip_color_classes(:wayne_tech, true),
    do:
      "bg-[oklch(68%_0.15_240)] text-[oklch(98%_0_0)] border-[oklch(68%_0.15_240)] shadow-[0_0_0_2px_oklch(68%_0.15_240/30%)]"

  defp chip_color_classes(:sxi, false),
    do: "bg-[oklch(70%_0.15_162/12%)] text-[oklch(70%_0.15_162)] border-[oklch(70%_0.15_162/30%)]"

  defp chip_color_classes(:sxi, true),
    do:
      "bg-[oklch(70%_0.15_162)] text-[oklch(15%_0_0)] border-[oklch(70%_0.15_162)] shadow-[0_0_0_2px_oklch(70%_0.15_162/30%)]"

  defp chip_color_classes(:paragon, false),
    do: "bg-[oklch(80%_0.16_95/12%)] text-[oklch(80%_0.16_95)] border-[oklch(80%_0.16_95/30%)]"

  defp chip_color_classes(:paragon, true),
    do:
      "bg-[oklch(80%_0.16_95)] text-[oklch(15%_0_0)] border-[oklch(80%_0.16_95)] shadow-[0_0_0_2px_oklch(80%_0.16_95/30%)]"

  # Hover state — bump default 12% bg to 22% color-mix on the button variant only.
  defp chip_hover_classes(:fabrikam), do: "hover:bg-[oklch(72%_0.16_50/22%)]"
  defp chip_hover_classes(:soylent), do: "hover:bg-[oklch(65%_0.20_295/22%)]"
  defp chip_hover_classes(:wayne_tech), do: "hover:bg-[oklch(68%_0.15_240/22%)]"
  defp chip_hover_classes(:sxi), do: "hover:bg-[oklch(70%_0.15_162/22%)]"
  defp chip_hover_classes(:paragon), do: "hover:bg-[oklch(80%_0.16_95/22%)]"

  # Dot color — full saturation, redundant-signal-beyond-color cue.
  defp scope_dot(:fabrikam), do: "bg-[oklch(72%_0.16_50)]"
  defp scope_dot(:soylent), do: "bg-[oklch(65%_0.20_295)]"
  defp scope_dot(:wayne_tech), do: "bg-[oklch(68%_0.15_240)]"
  defp scope_dot(:sxi), do: "bg-[oklch(70%_0.15_162)]"
  defp scope_dot(:paragon), do: "bg-[oklch(80%_0.16_95)]"

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
