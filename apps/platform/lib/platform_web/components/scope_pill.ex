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
    2026-05-18) so context is still visible but no affordance. At `:compact`
    size the floor is 0.70 — the smaller chip needs more signal, not less.
  * Active — full-saturation fill + check icon (filtered-to-this-scope). At
    `:compact` size the check icon is dropped (illegible at ~12px); the dot is
    kept and the full-saturation fill alone signals "filtered".

  ## Sizes

  The `:size` attr selects chrome density; the **font stays `text-xs` (12px) at
  every size** — that is the design system's smallest type token (foundations
  doc `caption`, designated for taxonomy chips) and the mobile legibility floor.
  Density comes from padding/border, never from shrinking text.

  * `:default` — `px-2 py-0.5`, bordered, `size-2` dot. The original look; all
    existing call sites render byte-identically.
  * `:compact` — `px-1.5 py-px`, **no border**, `size-1.5` dot, label truncates
    at `max-w-20`. For message rows and card chrome where space is tight. A 1px
    border ring repeated down a list reads as noise, so compact drops it; the
    background fill + dot carry the scope signal.

  ### Compact + touch targets

  A ~16px-tall tappable pill fails WCAG 2.5.8 (24px) and the 44px iOS guideline,
  so at `:compact` the pill is **non-clickable unless the caller passes
  `clickable={true}` explicitly**. When they do, `.scope-pill-hit-expand`
  enlarges the tap target past 24px via an invisible inset pseudo-element
  without changing the visual size. Guidance: keep dense message-row pills
  non-clickable; surfaces that need tap-to-filter should use `:default`.

  ### Compact + propagated

  Two chips plus an arrow do not fit a 375px message row, so `:compact` +
  `:propagated_to` renders the **source chip only**; the full provenance
  (`X scope, propagated to Y`) moves into `aria-label` and the `title` tooltip
  so nothing is lost to assistive tech or hover.

  ## Accessibility

  The colored dot acts as a redundant signal beyond color alone (WCAG 1.4.1
  Use of Color). Screen readers get scope context via `aria-label` even
  on the non-clickable variant.

  ## Scope-color centralization

  Scope → color tokens are centralized in two places:

    * `Platform.Tenancy.scope_color/1` returns the Tailwind text-color
      utility (`text-fabrikam`, `text-soylent`, …) for any scope slug. This is
      the full-saturation token, reserved for the dot and other non-label use.
    * `apps/platform/assets/css/app.css` defines the matching `bg-*`,
      `border-*`, `bg-*-active`, `bg-*-dot`, `hover:bg-*/22`, and the
      AA-tuned `text-*-label` utilities — all anchored to the same scope
      `oklch(...)` hue/chroma.

  The non-active chip label uses `text-<slug>-label` (theme-aware, darker in
  light mode) rather than `scope_color/1`, so the colored label clears WCAG
  1.4.3 AA (≥4.5:1) on the 12% `bg-<slug>` tint. `scope_color/1` itself is
  unchanged — it has a second consumer (`inheritance_pill.ex`) and is not
  pill-specific.

  This component was previously inlining `bg-[oklch(...)]` arbitrary-value
  classes; Stage 2 of Working surfaces plan v4 retired that pattern in
  favor of the named utilities. The public `:scope` attr API is unchanged.

  ## Examples

      <.scope_pill scope={:fabrikam} />
      <.scope_pill scope={:soylent} propagated_to={:fabrikam} />
      <.scope_pill scope={:wayne_tech} clickable={false} />
      <.scope_pill scope={:sxi} active={true} />
      <.scope_pill scope={:fabrikam} size={:compact} />
      <.scope_pill scope={:soylent} propagated_to={:fabrikam} size={:compact} />
      <.scope_pill scope={:sxi} size={:compact} clickable={true} />
  """
  use Phoenix.Component
  import PlatformWeb.CoreComponents, only: [icon: 1]

  @scopes [:fabrikam, :soylent, :wayne_tech, :sxi, :paragon, :cyberdyne]

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
    values: [nil, :fabrikam, :soylent, :wayne_tech, :sxi, :paragon, :cyberdyne],
    doc:
      "When set, renders the propagated variant — `<scope> → <propagated_to>` joined by a hero-arrow-right glyph."
  )

  attr(:clickable, :boolean,
    default: nil,
    doc:
      "Renders as a `<button>` with `phx-click=\"scope_filter\"` when true, or a non-interactive `<span>` when false. Defaults to true at `:default` size and false at `:compact` size (touch-target safety); pass explicitly to override."
  )

  attr(:size, :atom,
    default: :default,
    values: [:default, :compact],
    doc:
      "`:default` for the standard bordered pill; `:compact` for a denser, borderless pill (message rows, card chrome). Font stays text-xs at both sizes."
  )

  attr(:label, :string,
    default: nil,
    doc: """
    Overrides the pill's visible text AND its `aria-label`. Used by the chat
    rail's screen-share name masking (task 01a00c66) to render `Workspace B`
    in place of the real org name. The mask table lives in
    `Platform.Chat.SidebarMask` and is passed in by the caller — this
    component deliberately holds no second copy of it, because two mask
    tables drift and the one that drifts is the one nobody is looking at.
    A masked pill whose screen-reader name still says the real org name has
    not been masked, so the override reaches both surfaces or neither.
    """
  )

  attr(:active, :boolean,
    default: false,
    doc:
      "When true, applies the active-filter visual treatment (full saturation, check-icon, soft outer ring). Used by parent LVs to signal the current filter."
  )

  def scope_pill(assigns) do
    assigns = assign(assigns, :clickable, resolve_clickable(assigns))

    ~H"""
    <%= if @propagated_to do %>
      <%= if @size == :compact do %>
        <%!-- Compact + propagated: source chip only (two chips + arrow don't fit
             a phone-width row). Full provenance lives in aria-label + title. --%>
        {render_chip(%{
          scope: @scope,
          clickable: @clickable,
          active: @active,
          propagated_to: @propagated_to,
          role: :source,
          size: @size,
          label: @label,
          aria_label: propagated_aria(display_label(@label, @scope), @propagated_to),
          title: propagated_title(display_label(@label, @scope), @propagated_to)
        })}
      <% else %>
        <span class="scope-pill-propagated inline-flex items-center gap-1">
          {render_chip(%{
            scope: @scope,
            clickable: @clickable,
            active: @active,
            propagated_to: @propagated_to,
            role: :source,
            size: @size,
            label: @label
          })}
          <.icon name="hero-arrow-right" class="size-3 text-base-content/60" />
          {render_chip(%{
            scope: @propagated_to,
            clickable: @clickable,
            active: @active,
            propagated_to: @propagated_to,
            role: :target,
            size: @size,
            label: nil
          })}
        </span>
      <% end %>
    <% else %>
      {render_chip(%{
        scope: @scope,
        clickable: @clickable,
        active: @active,
        propagated_to: nil,
        role: :single,
        size: @size,
        label: @label
      })}
    <% end %>
    """
  end

  # Compact pills default to non-clickable for touch-target safety; an explicit
  # clickable={true/false} always wins. nil means "caller didn't say".
  defp resolve_clickable(assigns) do
    case assigns[:clickable] do
      nil -> assigns[:size] != :compact
      explicit -> explicit
    end
  end

  # ── Chip rendering ──────────────────────────────────────────────────

  defp render_chip(assigns) do
    # render_chip is fed plain maps (not component assigns), so normalize the
    # optional keys with Map.put_new — assign_new/3 rejects un-tracked maps.
    assigns =
      assigns
      |> Map.put_new(:title, nil)
      |> Map.put_new(:aria_label, nil)
      |> Map.put_new(:label, nil)

    ~H"""
    <%= if @clickable do %>
      <button
        type="button"
        phx-click="scope_filter"
        phx-value-scope={@scope}
        phx-value-propagated-to={@propagated_to}
        title={@title}
        class={[
          chip_base_classes(@size),
          chip_color_classes(@scope, @active, @size),
          "focus-visible-ring cursor-pointer",
          not @active && chip_hover_classes(@scope),
          @size == :compact && "scope-pill-hit-expand"
        ]}
        aria-label={@aria_label || aria_label(display_label(@label, @scope), @active)}
        aria-pressed={if @active, do: "true", else: "false"}
      >
        {chip_inner(assigns)}
      </button>
    <% else %>
      <span
        title={@title}
        class={[
          chip_base_classes(@size),
          chip_color_classes(@scope, @active, @size),
          if(@size == :compact, do: "opacity-70", else: "opacity-55")
        ]}
        aria-label={@aria_label || aria_label_static(display_label(@label, @scope))}
      >
        {chip_inner(assigns)}
      </span>
    <% end %>
    """
  end

  defp chip_inner(assigns) do
    ~H"""
    <%= if @active and @size != :compact do %>
      <.icon name="hero-check" class="size-[13px]" />
    <% else %>
      <span
        class={["inline-block rounded-full", dot_size(@size), scope_dot(@scope)]}
        aria-hidden="true"
      />
    <% end %>
    <span class={label_class(@size)}>{display_label(@label, @scope)}</span>
    """
  end

  # Kept short so the HEEx formatter leaves the label span on one line — the
  # rendered `>Label</span>` (no surrounding whitespace) is part of the contract.
  defp label_class(:compact), do: "scope-pill-label truncate max-w-20"
  defp label_class(_default), do: "scope-pill-label"

  defp chip_base_classes(:compact),
    do:
      "inline-flex items-center gap-1 rounded-full px-1.5 py-px text-xs font-medium leading-none transition-colors"

  defp chip_base_classes(_default),
    do:
      "inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-xs font-medium leading-none transition-colors"

  # ── Color mapping ───────────────────────────────────────────────────
  #
  # Resolves to the named utility classes defined in `app.css` (and
  # surfaced as text-utilities by `Platform.Tenancy.scope_color/1`). The
  # oklch literals themselves live in `app.css`; if you need to change a
  # scope color, edit it there.
  #
  # Default (`active: false`) chip uses the 12% color-mix bg, the AA-tuned
  # `text-<slug>-label` text (WCAG 1.4.3 ≥4.5:1 on the tint; darker than
  # `scope_color/1`'s full-saturation `text-<slug>`), and the 30% color-mix
  # border. Active chip uses the full-saturation `bg-<slug>-active` (which
  # also bakes in the contrast-safe text and shadow ring).

  defp chip_color_classes(scope, false, :compact) do
    # Compact drops the border — bg fill + dot carry the signal.
    # Label text uses the AA-tuned `text-<slug>-label` token (darker than
    # `scope_color/1`'s `text-<slug>`) so it clears WCAG 1.4.3 on the 12% tint.
    [
      "bg-#{slug(scope)}",
      "text-#{slug(scope)}-label"
    ]
  end

  defp chip_color_classes(scope, false, _default) do
    # See the :compact clause above — `text-<slug>-label` is the AA-safe
    # label color on the 12% `bg-<slug>` tint (vs scope_color/1's full-sat
    # `text-<slug>`, which is reserved for the dot / active fill).
    [
      "bg-#{slug(scope)}",
      "text-#{slug(scope)}-label",
      "border-#{slug(scope)}"
    ]
  end

  defp chip_color_classes(scope, true, _size) do
    "bg-#{slug(scope)}-active"
  end

  # Hover state — bump default 12% bg to 22% color-mix on the button variant only.
  defp chip_hover_classes(scope), do: "hover:bg-#{slug(scope)}/22"

  # Dot color — full saturation, redundant-signal-beyond-color cue.
  defp scope_dot(scope), do: "bg-#{slug(scope)}-dot"

  # Dot diameter — compact uses a smaller dot to match the tighter chrome.
  defp dot_size(:compact), do: "size-1.5"
  defp dot_size(_default), do: "size-2"

  # Atom slug → kebab-case fragment used in the Tailwind utility class names
  # (e.g. :wayne_tech → "wayne-tech" so we get `bg-wayne-tech`).
  defp slug(:fabrikam), do: "fabrikam"
  defp slug(:soylent), do: "soylent"
  defp slug(:wayne_tech), do: "wayne-tech"
  defp slug(:sxi), do: "sxi"
  defp slug(:paragon), do: "paragon"
  defp slug(:cyberdyne), do: "cyberdyne"

  # ── Labels ─────────────────────────────────────────────────────────

  defp scope_label(:fabrikam), do: "Fabrikam"
  defp scope_label(:soylent), do: "Soylent"
  defp scope_label(:wayne_tech), do: "Wayne-Tech"
  defp scope_label(:sxi), do: "SXI"
  defp scope_label(:paragon), do: "Paragon"
  defp scope_label(:cyberdyne), do: "Cyberdyne"

  # The caller's override wins over the scope enum's own name. Anything that
  # is not a binary (`nil`, or the `false` an inline `@mask_names? && ...`
  # produces when the mode is off) means "caller didn't say" and falls back to
  # the scope's own name. An empty string IS a caller decision and is honoured
  # — a blank label is never a leak.
  defp display_label(label, _scope) when is_binary(label), do: label
  defp display_label(_label, scope), do: scope_label(scope)

  # These take the already-resolved LABEL, not the scope atom, so there is no
  # path that renders a masked pill whose accessible name is the real one.
  defp aria_label(label, true), do: "Currently filtered by #{label} scope"
  defp aria_label(label, false), do: "Filter by #{label} scope"

  defp aria_label_static(label), do: "#{label} scope"

  # Compact propagated collapses to the source chip; provenance is preserved
  # for assistive tech (aria-label) and hover (title).
  defp propagated_aria(label, to),
    do: "#{label} scope, propagated to #{scope_label(to)}"

  defp propagated_title(label, to),
    do: "#{label} → #{scope_label(to)}"
end
