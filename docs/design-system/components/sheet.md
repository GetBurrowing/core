# `<.sheet>` component spec

**Phase 4 deliverable.** Code-ready specification for the Sheet component (mobile bottom-sheet, desktop side-panel). Implements Phase 2 `02-components.md` §2.7.

> **Anchored:** `1B-USE-4` (drawer flag duplication), `1A-IA-DRIFT-5` (drawer ↔ sidebar ↔ nav ↔ menu — 3 flag systems for one element).

---

## 1. Module signature

New file: `~/projects/core/apps/platform/lib/platform_web/components/sheet.ex`.

```elixir
defmodule PlatformWeb.Components.Sheet do
  use Phoenix.Component
  import PlatformWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true,
       doc: "Unique DOM id. Required for focus-management hook + aria-controls wiring."

  attr :open, :boolean, default: false

  attr :placement, :atom,
       default: :bottom,
       values: [:bottom, :right, :left, :top],
       doc: "Mobile uses :bottom regardless; placement applies to desktop side-panel."

  attr :on_close, :string,
       default: "close_sheet",
       doc: "phx-click event fired when backdrop tapped, ESC pressed, or close-button clicked."

  slot :title
  slot :inner_block, required: true
  slot :actions, doc: "Bottom action bar. Typically Cancel + primary CTA."

  def sheet(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "sheet",
        "sheet-#{@placement}",
        @open && "sheet-open"
      ]}
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-hook="Sheet"
      data-open={@open}
      data-on-close={@on_close}
    >
      <div class="sheet-backdrop" phx-click={@on_close} />
      <div class="sheet-panel">
        <div :if={@placement == :bottom} class="sheet-handle" aria-hidden="true" />

        <header class="sheet-header">
          <h2 id={"#{@id}-title"} class="sheet-title">
            <%= render_slot(@title) %>
          </h2>
          <.button variant={:icon_only} aria_label="Close" phx-click={@on_close}>
            <.icon name="hero-x-mark" class="size-5" />
          </.button>
        </header>

        <div class="sheet-body">
          <%= render_slot(@inner_block) %>
        </div>

        <footer :if={@actions != []} class="sheet-actions">
          <%= render_slot(@actions) %>
        </footer>
      </div>
    </div>
    """
  end
end
```

Register in `platform_web.ex` HTML helpers.

---

## 2. JS hook — focus management + escape + drag-to-dismiss

New file: `~/projects/core/apps/platform/assets/js/hooks/sheet.js`.

```javascript
const Sheet = {
  mounted() {
    this.previousFocus = null;
    this.handleEscape = (e) => {
      if (e.key === "Escape" && this.el.dataset.open === "true") {
        this.pushEvent(this.el.dataset.onClose);
      }
    };
    this.handleFocusTrap = (e) => {
      if (this.el.dataset.open !== "true") return;
      const focusable = this.el.querySelectorAll(
        'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
      );
      if (focusable.length === 0) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (e.key === "Tab") {
        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault(); last.focus();
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault(); first.focus();
        }
      }
    };

    document.addEventListener("keydown", this.handleEscape);
    this.el.addEventListener("keydown", this.handleFocusTrap);
  },

  updated() {
    if (this.el.dataset.open === "true" && !this.previousFocus) {
      this.previousFocus = document.activeElement;
      // Focus first interactive element inside sheet
      const first = this.el.querySelector(
        'button:not([aria-label="Close"]), [href], input, textarea, select'
      );
      if (first) first.focus();
    } else if (this.el.dataset.open === "false" && this.previousFocus) {
      this.previousFocus.focus();
      this.previousFocus = null;
    }
  },

  destroyed() {
    document.removeEventListener("keydown", this.handleEscape);
  }
};

export default Sheet;
```

Register in `~/projects/core/apps/platform/assets/js/app.js` LiveSocket constructor.

---

## 3. CSS

CSS rules land in `app.css` (proposed addition to the `05-app-css-diff.md`):

```css
@layer components {
  .sheet {
    position: fixed;
    inset: 0;
    z-index: 100;
    pointer-events: none;
    visibility: hidden;
  }
  .sheet.sheet-open {
    pointer-events: auto;
    visibility: visible;
  }

  .sheet-backdrop {
    position: absolute;
    inset: 0;
    background: rgba(0, 0, 0, 0);
    transition: background 0.2s ease;
  }
  .sheet-open .sheet-backdrop {
    background: rgba(0, 0, 0, 0.5);
  }

  .sheet-panel {
    position: absolute;
    background: var(--color-base-100);
    box-shadow: 0 -4px 24px rgba(0, 0, 0, 0.12);
    transform: translateY(100%);
    transition: transform 0.25s cubic-bezier(0.32, 0.72, 0, 1);
    display: flex;
    flex-direction: column;
    max-height: 90vh;
  }
  .sheet-open .sheet-panel {
    transform: translateY(0);
  }
  .sheet-bottom .sheet-panel {
    bottom: 0; left: 0; right: 0;
    border-radius: 1rem 1rem 0 0;
  }
  .sheet-right .sheet-panel {
    top: 0; right: 0; bottom: 0;
    transform: translateX(100%);
    width: min(420px, 100vw);
    max-height: none;
    border-radius: 1rem 0 0 1rem;
  }
  .sheet-right.sheet-open .sheet-panel { transform: translateX(0); }
  /* (analogous rules for .sheet-left and .sheet-top — generate per placement) */

  .sheet-handle {
    width: 36px; height: 4px;
    background: var(--color-base-300);
    border-radius: 999px;
    margin: 0.25rem auto 0;
  }

  .sheet-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 1rem 1.5rem 0.75rem;
    border-bottom: 1px solid var(--color-base-300);
  }
  .sheet-title { margin: 0; font-size: 1.125rem; font-weight: 600; }
  .sheet-body { flex: 1; padding: 1.5rem; overflow-y: auto; }
  .sheet-actions {
    display: flex;
    gap: 0.5rem;
    justify-content: flex-end;
    padding: 1rem 1.5rem;
    border-top: 1px solid var(--color-base-300);
  }

  /* Desktop: side-panel becomes sticky-positioned, mobile-only bottom-sheet */
  @media (min-width: 768px) {
    .sheet-bottom .sheet-panel {
      max-width: 480px;
      left: 50%;
      transform: translate(-50%, 100%);
      border-radius: 1rem;
      bottom: 1.5rem;
    }
    .sheet-bottom.sheet-open .sheet-panel {
      transform: translate(-50%, 0);
    }
  }
}

@media (prefers-reduced-motion: reduce) {
  .sheet-panel { transition: none; }
}
```

---

## 4. HEEx examples

### Mobile bottom-sheet for task detail

```heex
<.sheet
  id="task-sheet"
  open={@show_task_sheet}
  placement={:bottom}
  on_close="close_task_sheet"
>
  <:title><%= @selected_task.title %></:title>

  <.input field={@task_form[:description]} label="Description" type="textarea" />
  <.input field={@task_form[:assignee_id]} label="Assignee" type="select" options={@agent_options} />

  <:actions>
    <.button variant={:tertiary} phx-click="close_task_sheet">Cancel</.button>
    <.button variant={:primary} type="submit" loading={@saving?}>Save</.button>
  </:actions>
</.sheet>
```

### Desktop side-panel for project filter

```heex
<.sheet
  id="project-sheet"
  open={@show_project_sheet}
  placement={:right}
  on_close="close_project_sheet"
>
  <:title>Filter by project</:title>
  <%!-- project list inside --%>
</.sheet>
```

---

## 5. Accessibility notes

| Rule                              | How |
|-----------------------------------|-----|
| `role="dialog"` + `aria-modal="true"` | Set automatically by the component. |
| `aria-labelledby`                  | Sheet title gets an id derived from `@id`; body region references it. |
| Focus management (focus into sheet on open, return to trigger on close) | JS hook tracks `previousFocus`; verified via `04-accessibility.md` §3.2. |
| Focus trap                         | Tab + Shift+Tab cycle within the sheet. |
| Escape-to-close                     | JS hook listens for Escape key. |
| Backdrop tap = close                | Backdrop has `phx-click={@on_close}`. |
| Reduced motion                      | Transitions disabled via `prefers-reduced-motion: reduce` block. |

---

## 6. Migration map (current → unified Sheet)

### Site 1: shell sidebar drawer (`shell_live.ex` + `shell.html.heex`)

**Current state:** two flags (`drawer_open` + `sidebar_collapsed`) governing one element.

**After:**
```heex
<%!-- shell.html.heex --%>
<.sheet
  id="shell-drawer"
  open={@drawer_open}
  placement={:left}
  on_close="close_drawer"
>
  <:title>Burrow</:title>
  <%!-- channels list, DM list, settings link, etc. --%>
</.sheet>
```

Drop `sidebar_collapsed` from the assigns; derive collapsed-state from `@drawer_open`.

### Site 2-4: task detail / project filter / review canvas (`tasks_live.ex` + `tasks_live.html.heex`)

Three separate `<.sheet>` instances, each with its own `:open` state:
- `id="task-sheet"` `:open={@show_task_sheet}`
- `id="project-sheet"` `:open={@show_project_sheet}`
- `id="review-canvas-sheet"` `:open={@show_review_canvas}`

The flag-naming consistency (`show_*_sheet` for everything) replaces today's mix of `sidebar_open` + `show_*_sheet`.

---

## 7. What this spec does NOT cover

- **Modal dialogs** (`<.modal>`). Different from sheet — modal is centered + always blocks interaction. Use existing `<.modal>` from `core_components.ex`.
- **Toast / inline alerts.** Different component (`02-components.md` §2.9).
- **Drag-to-dismiss on mobile beyond what the JS hook stubs.** Phase 4 implementer can extend the hook with touch gesture handling if needed; first version ships with backdrop-tap + Escape only.

---

## 8. Phase 4 checklist

- [ ] Create `~/projects/core/apps/platform/lib/platform_web/components/sheet.ex`.
- [ ] Create `~/projects/core/apps/platform/assets/js/hooks/sheet.js`.
- [ ] Register hook in `app.js` LiveSocket.
- [ ] Add CSS rules to `app.css` (folded into `05-app-css-diff.md`).
- [ ] Migrate `shell.html.heex` drawer.
- [ ] Migrate `tasks_live.html.heex` 3 sheet sites (one at a time; each is a discrete commit).
- [ ] Manual verification per `04-accessibility.md` §3.2: open sheet → focus moves into sheet, Tab cycles, Escape closes, focus returns to trigger.
- [ ] LiveView tests: `assert has_element?(view, "#task-sheet[data-open='true']")` after click; click backdrop, assert `data-open='false'`.
