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
    The opacity is on the chip ROOT, so it composites the LABEL as well as
    the fill: in light theme this variant's label reads 2.11-2.26:1
    (2.69-2.88 at compact) where the clickable chip reads 4.55-4.67. Below
    AA in 47 of the 48 slug/surface/theme/size cells, each one measured in
    `ScopePillStaticOpacityTest`. Marlowe's 2026-09-13 ruling moved the six
    pills' colours and said nothing about this opacity; changing it is her
    call, not an executor's.
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
    border repeated down a list costs 2px per chip in both axes, so compact
    has none. Its edge is an inset box-shadow instead (see "Edge and
    hover").

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

  ## Scope colour: one path, from the org row

  Every chip, for every org, takes the same slug-agnostic classes:
  `.scope-tint` / `.scope-text` / `.scope-edge` (or their `-200` spellings,
  see "Surface" below) / `.scope-dot` / `.scope-active`. They read custom
  properties that `PlatformWeb.Components.ScopeColorStyles` emits into a
  server-rendered `<style>` block, one declaration set per org with a
  `color_hue`, keyed on the chip's `data-scope`. A custom property resolves
  at RENDER time, so a brand-new org is coloured on its next page load with
  no deploy (task 01a09287 stage 5).

  ### How the six shipped orgs got here (task 01a09333-d374 stage 5)

  Until stage 5 there were two paths. The six shipped slugs (fabrikam, soylent,
  wayne-tech, sxi, paragon, cyberdyne) kept hand-authored build-time
  utilities in `app.css` (`bg-<slug>` at 12%, `text-<slug>-label`,
  `border-<slug>` at 30%, `bg-<slug>-active`, `hover:bg-<slug>/22`), chosen
  by an explicit six-slug branch here, because their labels were
  solved against one contrast cell of four and moving them was a brand
  call. Marlowe ruled on 2026-09-13 that they move. They now take the var
  path like every other org, coloured from their rows (hue, chroma and, for
  these six, the fill lightness they shipped at), and the chip-only
  utilities are deleted from `app.css` in the same change, so no chip can
  carry both class sets and leave the cascade to decide.

  Two per-slug utilities survive in `app.css` because things other than
  this chip use them: `text-<slug>` (`Platform.Tenancy.scope_color/1`,
  read by the inheritance pill, files, recovery and the tasks sidebar) and
  `bg-<slug>-dot` (`ChatLive.section_dot_class/1`, the chat rail's section
  dots). This component no longer emits either.

  ## Surface (task 01a09333-d374)

  A chip's tint and label are solved per surface, because one label cannot
  clear AA on both grounds a chip sits on. The `:surface` attr names the
  ground at the CALL SITE: `:base_100` (the default: the chat pane and the
  page ground) wears `.scope-tint` / `.scope-text`, and `:base_200` (the
  chat rail) wears `.scope-tint-200` / `.scope-text-200`. Each pair reads
  the matching opaque `--scope-tint-*` / `--scope-label-*` slots.

  **That AA solve is the CLICKABLE chip's, and only the clickable chip's.**
  It names one variant of two. The non-clickable `<span>` carries
  `opacity-55` (`opacity-70` at compact), which composites the label toward
  the ground along with the tint: light theme 2.11-2.26:1 at `:default` and
  2.69-2.88 at `:compact`, dark theme 2.29-3.49 and 2.93-5.10.
  `ScopePillStaticOpacityTest` computes each of those 48 cells from the
  shipped opacity and pins the figure. Every cell LOSES contrast to the
  opacity and 47 of the 48 land below AA (the exception is paragon on the
  dark rail at compact, 5.10:1, down from 9.44:1). Not disputed, and NOT
  this component's to change: the opacity is Marlowe-approved (2026-05-18)
  and the ruling is open. Read "Non-clickable" under "Variants" before
  proposing a number.

  The surface is a property of the call site, deliberately NOT inherited
  from the DOM. An ambient `[data-surface]` wrapper would make contrast a
  property of the container again, which is the defect this task exists to
  remove, and a missed wrapper would fail silently while the chip still
  looked legible. A declared attr is visible in the diff that adds a call
  site, and `ScopePillTest` pins every call site's declaration.

  Call sites as of stage 3:

    * `live/chat/partials/rail.ex`, the hidden-channels drawer group label:
      `:base_200` (the rail `<aside>` carries `bg-base-200`; the drawer sets
      no fill of its own).
    * `live/chat/partials/conversation.ex`, the mobile and desktop chat
      header pills: `:base_100` (the `<header>` sets no background and
      inherits the shell's `bg-base-100`).
    * `live/tasks/filters_component.ex`, the task-filter scope chips:
      `:base_100` (they sit in `page_header/1`'s `bg-base-100` `<header>`).

  Since stage 5 the six shipped orgs take the declared surface like any
  other org. The chat rail and the chat header reach ONLY those six
  (`sub_org_scope_atom/1` and `section_scope_atom/1` are closed six-name
  maps), so stage 5 is when those two declarations took effect.

  ## Edge and hover (task 01a09333-d374 stage 4)

  A chip's fill measures 1.07-1.14:1 against its ground, so the chip's shape
  comes from its edge. On the var path the edge is `--scope-edge-100` /
  `-200`, solved by `ScopeColor` to 3:1 against the page ground with a
  one-byte margin (WCAG 1.4.11):

    * `:default` colours its existing 1px border: `.scope-edge` /
      `.scope-edge-200`.
    * `:compact` has no border, so the edge is an inset 1px box-shadow at
      zero layout cost: `.scope-edge-inset` / `.scope-edge-inset-200`.

  Hover lives on the edge, never on the fill, and never changes a width.
  A clickable, non-active chip also carries `.scope-edge-hover` (or
  `.scope-edge-inset-hover`, `-200` on the rail), which swaps the edge to
  `--scope-edge-hover-*` on `:hover` and on `:focus-visible`. The compact
  focus rule keeps the standard focus ring alongside the inset edge,
  because both are box-shadows. The active chip keeps its own 2px ring and
  takes no edge class.

  The 3:1 figure is for the chip as solved. A non-clickable chip still
  carries `opacity-55` (`opacity-70` at compact), which composites its edge
  toward the ground along with its label: fabrikam's solved edge paints at
  about 1.8:1 there (2.2:1 at compact), and its label at 2.21:1 (2.83:1 at
  compact). That opacity is Marlowe-approved (2026-05-18) and its conflict
  with the contrast rules is an open decision on the design canvas; neither
  stage 4 nor stage 6 changed it. Stage 6 measured the label cost it had
  left unmeasured (`ScopePillStaticOpacityTest`, 48 cells).

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

  attr(:surface, :atom,
    default: :base_100,
    values: [:base_100, :base_200],
    doc: """
    The ground this chip sits on, declared by the CALL SITE: `:base_100` (the
    chat pane and the page ground) or `:base_200` (the chat rail). Selects
    which per-surface tint and label pair the chip wears. Never inferred from
    the DOM; see "Surface" in the moduledoc.
    """
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
          surface: @surface,
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
            surface: @surface,
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
            surface: @surface,
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
        surface: @surface,
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
      # Declared by the call site and threaded through `scope_pill/1`; the
      # default only covers a map built without it.
      |> Map.put_new(:surface, :base_100)

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
          chip_color_classes(@active, @size, @surface),
          "focus-visible-ring cursor-pointer",
          not @active && chip_hover_classes(@size, @surface),
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
          chip_color_classes(@active, @size, @surface),
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
        class={["inline-block rounded-full scope-dot", dot_size(@size)]}
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
  # One path for every org (task 01a09333-d374 stage 5): the slug-agnostic
  # `.scope-*` utilities in `app.css`, reading the custom properties
  # `PlatformWeb.Components.ScopeColorStyles` emits per org. The colour
  # itself lives on the org ROW, never here and never in a per-slug CSS
  # block, which is why none of these functions takes the scope.

  # Resting chip. The label is solved against exactly the opaque tint it
  # sits on (WCAG 1.4.3, >=4.5:1 with a one-byte margin), per surface.
  #
  # These classes are the same on both variants, so the solved figure is NOT.
  # It is what the CLICKABLE chip paints. The non-clickable `<span>` wraps
  # the identical classes in `opacity-55` (`opacity-70` at compact), which
  # composites label and tint alike toward the ground and leaves the label
  # at 2.11-2.26:1 in light theme (2.69-2.88 compact): below AA in 47 of 48
  # cells. That opacity is Marlowe-approved and this stage did not touch it;
  # the figures are computed and pinned in `ScopePillStaticOpacityTest`.
  # Quote the 4.5 figure about the clickable chip only.
  #
  # The edge is not optional: a scope chip's FILL carries only 1.07-1.14
  # contrast against the surface behind it, so the chip's shape comes from
  # its edge, solved to 3:1 against the page ground (task 01a09333-d374
  # stage 4). `:default` colours the 1px border `chip_base_classes/1`
  # already sets; `:compact` has no border (one would grow the chip 2px in
  # both axes) and draws the edge as an inset 1px box-shadow instead.
  defp chip_color_classes(false, :compact, surface),
    do: var_tint_classes(surface) ++ [surfaced("scope-edge-inset", surface)]

  defp chip_color_classes(false, _default, surface),
    do: var_tint_classes(surface) ++ [surfaced("scope-edge", surface)]

  # The active pill is the full-saturation fill on every surface, so the
  # surface does not reach it.
  defp chip_color_classes(true, _size, _surface), do: "scope-active"

  # The per-surface pair: an opaque tint and the label solved against
  # exactly that tint (`ScopeColorStyles`' `--scope-tint-*` /
  # `--scope-label-*`).
  defp var_tint_classes(surface),
    do: [surfaced("scope-tint", surface), surfaced("scope-text", surface)]

  # Every colour class comes in a base-100 spelling and a `-200` spelling
  # that reads the base-200 slot. One function names the pair, so a new slot
  # cannot pick up a surface suffix by a different rule.
  defp surfaced(class, :base_100), do: class
  defp surfaced(class, :base_200), do: class <> "-200"

  # Hover state, on clickable non-active chips only: on the EDGE, never the
  # fill (task 01a09333-d374 stage 4). A 22% fill cannot be tuned back to a
  # legible label. The hover class swaps the edge colour for
  # `--scope-edge-hover-*`, a solved value one step darker, at CONSTANT
  # width: `.scope-active` already owns the 2px box-shadow ring, a 2px hover
  # border would reflow the rail row, and compact has no border to widen.
  # The rules are plain `:hover` / `:focus-visible` selectors in `app.css`,
  # not a Tailwind `hover:` variant, because Tailwind gates `hover:` behind
  # `@media (hover: hover)`.
  defp chip_hover_classes(:compact, surface), do: surfaced("scope-edge-inset-hover", surface)
  defp chip_hover_classes(_default, surface), do: surfaced("scope-edge-hover", surface)

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
  # un-renamed chip gets its own scope.
  #
  # Suppression costs a masked chip its colour, because every colour rule is
  # keyed on `data-scope`. Since task 01a09333-d374 stage 5 that includes
  # the six shipped orgs, on the chat rail and header (no `data-scope`) and
  # on the tasks rail (a placeholder `data-scope` no rule names). Before
  # stage 5 those six kept their colour under masking through per-slug class
  # names (`bg-wayne-tech`), which the mask sweep tolerated because it strips
  # `class`. Those names are retired, so a masked chip is uncoloured on
  # every surface and no spelling of the real org is anywhere in it.
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
