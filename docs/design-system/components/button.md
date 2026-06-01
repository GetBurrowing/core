# `<.button>` component spec

**Phase 4 deliverable.** Code-ready specification for the Button component (and its `:icon_only` variant which subsumes IconButton). Implements Phase 2 `02-components.md` §2.1 + §2.2.

> **Anchored:** `1B-A11Y-1` (focus ring), `1B-A11Y-2` (icon-only aria-label), `1B-A11Y-6` (loading state), `1A-TOK-INLINE-1` (inline padding drift).

---

## 1. Module signature

New file: `~/projects/core/apps/platform/lib/platform_web/components/button.ex`.

```elixir
defmodule PlatformWeb.Components.Button do
  use Phoenix.Component
  import PlatformWeb.CoreComponents, only: [icon: 1]

  attr :variant, :atom,
       default: :secondary,
       values: [:primary, :secondary, :tertiary, :destructive, :icon_only]

  attr :size, :atom,
       default: :md,
       values: [:lg, :md, :sm, :xs]

  attr :loading, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :type, :string, default: "button", values: ~w(button submit reset)

  attr :aria_label, :string,
       default: nil,
       doc: "Required when variant is :icon_only. Optional otherwise (defaults to the inner_block text)."

  attr :rest, :global,
       include: ~w(form name value phx-click phx-target phx-disable-with phx-submit data-role)

  slot :inner_block, required: true
  slot :icon, doc: "Leading icon. Use `<.icon name=\"hero-...\">`."

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      disabled={@disabled}
      aria-busy={@loading}
      aria-label={@aria_label}
      class={[
        "btn",
        variant_class(@variant),
        size_class(@size),
        "focus-visible-ring",
        @loading && "btn-loading"
      ]}
      {@rest}
    >
      <%= if @loading do %>
        <.icon name="hero-arrow-path" class="size-4 animate-spin" />
      <% else %>
        <%= render_slot(@icon) %>
      <% end %>
      <span class={[@loading && "opacity-70"]}>
        <%= render_slot(@inner_block) %>
      </span>
    </button>
    """
  end

  # Variant → DaisyUI base class
  defp variant_class(:primary),     do: "btn-primary"
  defp variant_class(:secondary),   do: ""              # Default DaisyUI .btn
  defp variant_class(:tertiary),    do: "btn-ghost"
  defp variant_class(:destructive), do: "btn-error"
  defp variant_class(:icon_only),   do: "btn-square btn-ghost"

  defp size_class(:lg), do: "btn-lg"
  defp size_class(:md), do: ""
  defp size_class(:sm), do: "btn-sm"
  defp size_class(:xs), do: "btn-xs"
end
```

Register in `~/projects/core/apps/platform/lib/platform_web.ex` HTML helpers block so every LV gets `<.button>` for free.

---

## 2. HEEx examples per state

### Default (primary CTA)

```heex
<.button variant={:primary} phx-click="approve_plan">
  Approve plan
</.button>
```

### With leading icon

```heex
<.button variant={:primary} phx-click="add_agent">
  <:icon><.icon name="hero-plus" /></:icon>
  Add an agent
</.button>
```

### Icon-only — REQUIRED `aria_label`

```heex
<.button variant={:icon_only} aria_label="Close task panel" phx-click="close_task_sheet">
  <.icon name="hero-x-mark" />
</.button>
```

This is the canonical replacement for the 7 icon-only buttons currently missing names in the audit (`1B-A11Y-2`):
- `chat_live.html.heex:412` (search_clear)
- `tasks_live.html.heex:89` (clear_filters), `:101` (toggle_epics_panel), `:410` (close_detail), `:1407` (close_review_canvas), `:1524` (close_project_sheet), `:1705` (close_task_sheet)

### Loading state

```heex
<.button variant={:primary} loading={@saving?} phx-click="save_task">
  Save
</.button>
```

When `loading={true}`, the button:
- Replaces the leading icon (or prepends one) with `<.icon name="hero-arrow-path" class="animate-spin">`.
- Dims the inner_block via `opacity-70`.
- Sets `aria-busy="true"`.
- CSS rule (`05-app-css-diff.md` §3) applies `cursor: wait; pointer-events: none`.

**Delay-before-show:** the `loading={true}` flag should be flipped only after a 100ms delay from the action firing, not immediately. Phase 4 wires this in the JS hook `~/projects/core/apps/platform/assets/js/hooks/button_loading.js` (see `IMPLEMENTATION.md` step 3). Per Marlowe 2026-05-09: most Suite messages are near-instant; the delay prevents flicker.

### Disabled

```heex
<.button variant={:primary} disabled={true}>
  Save
</.button>
```

CSS handles the visual via DaisyUI `.btn[disabled]`. Click handlers are no-op via the native `disabled` attribute.

### Destructive

```heex
<.button variant={:destructive} phx-click="confirm_delete_task">
  Delete task
</.button>
```

Always pair with a confirmation modal — never destructive-as-bare-button. See `03-voice.md` §6.3 for the destructive-confirmation copy pattern.

### Submit (form)

```heex
<.form for={@form} id="task-form" phx-submit="save_task">
  <.input field={@form[:title]} label="Title" />
  <.button variant={:primary} type="submit" loading={@saving?}>
    Save
  </.button>
</.form>
```

---

## 3. Accessibility notes

| Rule                              | How |
|-----------------------------------|-----|
| Focus ring                         | `focus-visible-ring` class applied automatically; CSS rule lands in `05-app-css-diff.md` §3. |
| Icon-only accessible name          | `aria_label` attr is required (component validates at compile-time via `attr ... required: ...` if we want — currently soft check; raise in dev). |
| Loading state announced            | `aria-busy="true"` set automatically when `loading={true}`. |
| Keyboard activation                | Inherits native `<button>` Enter+Space activation. |
| Touch target                       | `btn` default = 48×48 (passes WCAG 2.5.8). `btn-sm` / `btn-xs` need external padding wrapper on mobile per `04-accessibility.md` §2.3 — wrapper is consumer's responsibility, not the component's. |

---

## 4. Migration map

Replace inline `<button class="btn ...">` patterns with `<.button>` equivalents.

### Common transforms

| Existing pattern                                                              | New invocation                                                             |
|-------------------------------------------------------------------------------|----------------------------------------------------------------------------|
| `<button class="btn btn-primary">Save</button>`                              | `<.button variant={:primary}>Save</.button>`                               |
| `<button class="btn btn-ghost btn-square" phx-click="close_x">…icon…</button>` | `<.button variant={:icon_only} aria_label="…" phx-click="close_x">…icon…</.button>` |
| `<button class="btn" phx-disable-with="Saving…">Save</button>`               | `<.button loading={@saving?}>Save</.button>` (component owns the spinner) |

### Specific migration targets

From `IMPLEMENTATION.md` step 2 (icon-only aria-label fix):

```heex
<%!-- chat_live.html.heex:412 --%>
<.button variant={:icon_only} aria_label="Clear search" phx-click="search_clear">
  <.icon name="hero-x-mark" class="size-4" />
</.button>
```

```heex
<%!-- tasks_live.html.heex:1705 --%>
<.button variant={:icon_only} aria_label="Close task sheet" phx-click="close_task_sheet">
  <.icon name="hero-x-mark" class="size-5" />
</.button>
```

(Same shape for the other 5 sites listed in `IMPLEMENTATION.md` step 2.)

---

## 5. What this spec does NOT cover

- **Button groups / segmented controls.** Not in audit scope. If a future surface needs them, extend this spec.
- **Split buttons** (primary action + dropdown). Not in audit scope.
- **Loading-state copy variation.** The component shows a spinner + dims label. If a surface wants "Saving…" replacement text, the consumer passes `loading={true}` and renders the loading copy in a sibling region. Phase 4 implementer can add a `loading_label` slot if it proves needed.

---

## 6. Phase 4 checklist

- [ ] Create `~/projects/core/apps/platform/lib/platform_web/components/button.ex` per signature in §1.
- [ ] Register in `platform_web.ex` HTML helpers.
- [ ] CSS rules for `.btn[aria-busy]` + `focus-visible-ring` already land in `05-app-css-diff.md` step 1; verify those are present before testing.
- [ ] JS hook for delay-before-show spinner — separate work in `IMPLEMENTATION.md` step 3.
- [ ] LiveView tests: `assert has_element?(view, "button[aria-busy='true']")` on send/save flows.
- [ ] Migrate one icon-only button as a smoke test before doing all 7 (validates the aria_label flow).
