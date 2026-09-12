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

  ### Two colour paths, and which slug gets which (task 01a09287 stage 5)

  Everything above describes the BUILD-TIME path, and it now applies to
  exactly six slugs. A Tailwind utility is a literal rule compiled into the
  stylesheet, so `.bg-<slug>` exists only for a slug somebody hand-wrote
  into `app.css` — which meant standing up a tenant needed a CSS rebuild and
  a deploy, and an org created at runtime rendered grey.

  So there are two paths:

    * **legacy / build-time** — the six slugs in `@legacy_css_slugs`, which
      keep the `bg-<slug>` / `text-<slug>-label` / `border-<slug>` /
      `bg-<slug>-active` / `bg-<slug>-dot` utilities described above. They
      stay because their labels were solved against one contrast cell of
      four and re-solving them moves every shipped org's colour on every
      install — a brand call, filed as task 01a09333-d374.
    * **runtime / var-driven** — every other slug takes the slug-agnostic
      `.scope-tint` / `.scope-text` / `.scope-border` / `.scope-dot` /
      `.scope-active` / `.scope-tint-hover` rules, which read custom
      properties that `PlatformWeb.Components.ScopeColorStyles` emits into a
      server-rendered `<style>` block, one declaration set per org with a
      `color_hue`. A custom property resolves at RENDER time, so a
      brand-new org is coloured on its next page load with no deploy.

  The split is an explicit branch and not a reliance on the cascade: a chip
  carrying both class sets would match both rules at equal specificity and
  the winner would be a function of their ORDER in `app.css`, which is not a
  decision anybody would have made on purpose.

  ### `data-scope` is a leak surface

  Every chip carries `data-scope`, which is what the emitted rules match on,
  and its value is the org's SLUG AS STORED — not `slug/1`'s kebab-cased
  Tailwind fragment, since `:wayne_tech` is the class fragment `wayne-tech` and
  the database row `wayne_tech`.

  It is the same leak class as `phx-value-scope` and is resolved the same
  way. An explicit `:value` wins; failing that, a caller who passed a
  `:label` has RENAMED this chip for a masked session, and spelling its true
  slug one attribute over contradicts the rename, so nothing is emitted. See
  `data_scope/1` — the reasoning there is longer than the code because the
  first version of it leaked `wayne_tech` into a masked chat header.

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

  attr(:scope, :any,
    required: true,
    doc: """
    The primary scope this pill represents: one of the `scopes/0` atoms, or
    an org SLUG AS A STRING.

    Was `:atom` with `values: @scopes` until task 01a09287 stage 2. That
    `values:` list made the pill undrawable for any org created after the
    module was written, which is the whole thing that stage removed — the
    rail now feeds it slugs straight off the `orgs` rows. Callers passing a
    string should pass `label` too: `scope_label/1`'s fallback can only
    title-case the slug, and an org's `name` is not always its slug
    title-cased.
    """
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

  attr(:event, :string,
    default: "scope_filter",
    doc:
      "phx-click event name for the clickable variant. Defaults to the historical `\"scope_filter\"` (ChatLive's handler). Tasks passes `\"filter_scope\"` since task 01a008f6 stage 6 moved that concern into a LiveComponent with a renamed event."
  )

  attr(:target, :any,
    default: nil,
    doc:
      "phx-target for `event`. Required when the handler lives in a LiveComponent — this pill hardcoded an un-targeted `scope_filter` until stage 6, which would have silently dropped every sub-org chip click on the Tasks board while the surrounding rail kept rendering."
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

  attr(:value, :string,
    default: nil,
    doc: """
    Overrides the `phx-value-scope` PAYLOAD only, leaving `scope` itself — and
    therefore the colour classes and the `scope_label/1` fallback — untouched.
    The Tasks rail's screen-share masking (task 01a00cf1) emits a per-session
    placeholder slug here so the real org slug is absent from the DOM, and
    resolves it back to the real slug in its own `filter_scope` handler. A
    caller that overrides this MUST own that resolution: the pill does not.
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
            event: @event,
            target: @target,
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
            event: @event,
            target: @target,
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
        event: @event,
        target: @target,
        label: @label,
        value: @value
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
      # Defaults, not decoration: `render_chip/1` is fed plain maps from four
      # call sites, so a missing :event/:target/:label here is a runtime
      # KeyError rather than a compile error.
      |> Map.put_new(:event, "scope_filter")
      |> Map.put_new(:target, nil)
      |> Map.put_new(:label, nil)
      # The `phx-value-scope` PAYLOAD, separable from `@scope` since task
      # 01a00cf1: the Tasks rail emits a per-session placeholder slug there
      # while masking is on and resolves it back in its own handler. `@scope`
      # itself must stay the real atom — the chip's colour classes and its
      # `scope_label/1` fallback are both keyed on it.
      |> Map.put_new(:value, nil)

    ~H"""
    <%= if @clickable do %>
      <button
        type="button"
        phx-click={@event}
        phx-target={@target}
        phx-value-scope={@value || @scope}
        phx-value-propagated-to={@propagated_to}
        data-scope={data_scope(assigns)}
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
        data-scope={data_scope(assigns)}
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

  # The six slugs that HAVE hand-authored blocks in app.css. Everything else
  # takes the slug-agnostic `.scope-*` utilities, which read the custom
  # properties `PlatformWeb.Components.ScopeColorStyles` emits at render
  # time.
  #
  # This is a fallback list, not an allowlist: a slug that is missing from it
  # is coloured, not crashed. The split exists so the six shipped orgs render
  # byte-identically to what they render today — their app.css labels were
  # solved against one cell of four and moving them is a brand call filed as
  # task 01a09333-d374, not a thing to do by accident while wiring a call
  # site. It is deliberately NOT expressed as "whichever rule the cascade
  # happens to pick": both `.scope-tint` and `.bg-fabrikam` would match a fabrikam
  # chip carrying both class sets, and which one won would then be a
  # function of their order in app.css. Choosing here makes it a decision.
  @legacy_css_slugs ~w(fabrikam soylent wayne-tech sxi paragon cyberdyne)

  defp legacy_css?(scope), do: slug(scope) in @legacy_css_slugs

  defp chip_color_classes(scope, false, :compact) do
    # Compact drops the border — bg fill + dot carry the signal.
    # Label text uses the AA-tuned `text-<slug>-label` token (darker than
    # `scope_color/1`'s `text-<slug>`) so it clears WCAG 1.4.3 on the tint.
    if legacy_css?(scope) do
      [
        "bg-#{slug(scope)}",
        "text-#{slug(scope)}-label"
      ]
    else
      ["scope-tint", "scope-text"]
    end
  end

  defp chip_color_classes(scope, false, _default) do
    # See the :compact clause above — `text-<slug>-label` is the AA-safe
    # label color on the 12% `bg-<slug>` tint (vs scope_color/1's full-sat
    # `text-<slug>`, which is reserved for the dot / active fill).
    #
    # `.scope-border` is not optional on the var path: a scope chip's FILL
    # carries only 1.067-1.143 contrast against the surface behind it, so
    # the chip's edge comes from the border and the label, not the fill.
    if legacy_css?(scope) do
      [
        "bg-#{slug(scope)}",
        "text-#{slug(scope)}-label",
        "border-#{slug(scope)}"
      ]
    else
      ["scope-tint", "scope-text", "scope-border"]
    end
  end

  defp chip_color_classes(scope, true, _size) do
    if legacy_css?(scope),
      do: "bg-#{slug(scope)}-active",
      else: "scope-active"
  end

  # Hover state — bump default 12% bg to 22% color-mix on the button variant only.
  defp chip_hover_classes(scope) do
    if legacy_css?(scope),
      do: "hover:bg-#{slug(scope)}/22",
      else: "scope-tint-hover"
  end

  # Dot color — full saturation, redundant-signal-beyond-color cue.
  defp scope_dot(scope) do
    if legacy_css?(scope),
      do: "bg-#{slug(scope)}-dot",
      else: "scope-dot"
  end

  # The `data-scope` attribute value: the org's SLUG AS STORED, because that
  # is what `ScopeColorStyles` keys its `[data-scope="…"]{…}` rules on. NOT
  # `slug/1`, which kebab-cases for Tailwind class names — `:wayne_tech` is the
  # class fragment `wayne-tech` and the row `wayne_tech`, and using the class
  # fragment here would silently miss the rule.
  #
  # ── Why this takes the whole assigns map and not just the scope ──────
  #
  # `data-scope` is the same leak class as `phx-value-scope`: an attribute
  # value survives `refute html =~ "Wayne-Tech"` untouched and is legible in
  # the DOM inspector a screen share is likely to have open. There are two
  # kinds of caller and they need different answers.
  #
  #   * The TASKS rail masks by passing BOTH a placeholder `label` and a
  #     placeholder `value`. `@value` is the payload that is safe to spell,
  #     so it is what goes in the attribute, and the chip keeps whatever
  #     colour a rule keyed on that placeholder would give it (none, today).
  #
  #   * The CHAT rail and chat header mask by passing a placeholder `label`
  #     and NOTHING else — they hand over the real scope atom from
  #     `sub_org_scope_atom/1`. A first cut of this function fell back to
  #     `@scope` there and wrote `data-scope="wayne_tech"` into a masked
  #     session. `ChatLiveMaskMobileTest` caught it on both surfaces; it was
  #     a real leak, not a test being fussy, and it is the reason
  #     `refute_name_anywhere/3` checks all three spellings of a name rather
  #     than the display form.
  #
  # So: an explicit `@value` is authoritative. Failing that, a caller who has
  # OVERRIDDEN the visible label has renamed this chip, and spelling its true
  # slug one attribute over contradicts the rename — emit nothing. Only an
  # un-renamed chip gets its own scope. Suppression costs those two chat
  # surfaces their colour while masking is on; they route through
  # `sub_org_scope_atom/1`, a closed six-name map that returns nil for any
  # org created after this code was written, so they cannot reach the
  # runtime colour path at all and there is nothing to lose.
  #
  # `label` is `false` (not nil) when a caller writes `@mask_names? && …`
  # with masking off, which is why the guard is `is_binary/1` and not a nil
  # check: `false` must fall through to the scope, or an unmasked chat pill
  # would lose its colour too.
  defp data_scope(%{value: value}) when is_binary(value), do: value
  defp data_scope(%{label: label}) when is_binary(label), do: nil
  defp data_scope(%{scope: scope}), do: stringify_scope(scope)

  defp stringify_scope(scope) when is_atom(scope), do: Atom.to_string(scope)
  defp stringify_scope(scope) when is_binary(scope), do: scope
  defp stringify_scope(_), do: nil

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

  # TOTAL from task 01a09287 stage 2 on. These clauses used to cover exactly
  # six atoms, so a seventh org reached the renderer and raised
  # `FunctionClauseError` — a crash, on a surface whose whole job is to
  # tolerate arbitrary org slugs. A slug with no `bg-<slug>` utility in
  # app.css renders an unstyled chip; that is a cosmetic gap, not an outage,
  # and the colour-token wiring is the follow-on stage.
  #
  # `String.to_existing_atom/1` is NOT how the binary clause is implemented,
  # on purpose: it raises for precisely the new org this clause exists for.
  defp slug(scope) when is_binary(scope), do: String.replace(scope, "_", "-")
  defp slug(scope), do: scope |> to_string() |> String.replace("_", "-")

  # ── Labels ─────────────────────────────────────────────────────────

  defp scope_label(:fabrikam), do: "Fabrikam"
  defp scope_label(:soylent), do: "Soylent"
  defp scope_label(:wayne_tech), do: "Wayne-Tech"
  defp scope_label(:sxi), do: "SXI"
  defp scope_label(:paragon), do: "Paragon"
  defp scope_label(:cyberdyne), do: "Cyberdyne"

  # Total fallback (task 01a09287 stage 2). Reached by any org outside the
  # six compiled ones. Callers that know the org's real name pass it as
  # `label`, which wins over this via `display_label/2` — the rail always
  # does. This is only what a caller that passed a bare slug gets.
  defp scope_label(scope) when is_binary(scope) do
    scope
    |> String.split(~r/[-_]/, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp scope_label(scope), do: scope |> to_string() |> scope_label()

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
