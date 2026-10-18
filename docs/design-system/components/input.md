# `<.input>` and auto-resize textarea spec

**Phase 4 deliverable.** Code-ready specification for the Input component and its auto-resize textarea variant. Implements Phase 2 `02-components.md` §2.3 + §2.4.

> **Anchored:** `1B-VIS-2` (`<.input>` used once across 5,901 lines), `1A-COMP-INPUT-1` (bare inputs everywhere), `1B-A11Y-4` (composer + search inputs without label), `1A-TOK-INLINE-1` (auto-resize textarea repeated 5x).

---

## 1. Use the existing `<.input>` from `core_components.ex`

`~/projects/core/apps/platform/lib/platform_web/components/core_components.ex` already defines `<.input>` per the Phoenix v1.8 convention. **Do not reimplement.** The Phase 4 work is consumer migration + adding the auto-resize textarea variant.

### Existing signature (from `core_components.ex`)

```elixir
attr :field, Phoenix.HTML.FormField
attr :type, :string, default: "text",
     values: ~w(text email number password url tel search date datetime-local checkbox color file hidden month range select textarea time week)
attr :label, :string, default: nil
attr :placeholder, :string, default: nil
attr :helper, :string, default: nil
attr :rest, :global
```

The component generates:
- `<label for="...">` paired with the input by ID.
- The input/textarea/select itself.
- An error block below (from `field.errors`) with `role="alert"`.
- An optional helper-text line.

---

## 2. HEEx examples per state

### Default (text input with visible label)

```heex
<.input
  field={@form[:title]}
  label="Task title"
  placeholder="What needs to be done?"
/>
```

### With helper text

```heex
<.input
  field={@form[:slug]}
  label="Space slug"
  helper="Lowercase letters, numbers, and dashes only."
/>
```

### Error state (driven by changeset)

When `@form[:email].errors` is non-empty, the component automatically:
- Sets `aria-invalid="true"` on the input.
- Adds `border-error` class.
- Renders the error text below in `text-error` with `role="alert"`.

No special HEEx — drive this through the changeset.

```heex
<.input field={@form[:email]} label="Email" type="email" />
```

If `@form` is built from a changeset that `validate_format(:email, ...)` rejects, the error renders.

### Search / no visible label — `aria_label` required

The composer textarea, mention search, message search are intentionally unlabeled (visual context provides the meaning). Phase 4 adds an `aria_label` attr to `<.input>` (one-line addition to `core_components.ex` since the existing `:rest` global already passes through arbitrary attributes — the explicit attr is for documentation):

```heex
<.input
  field={@form[:query]}
  type="search"
  placeholder="Search messages…"
  aria_label="Search this space's messages"
/>
```

### Disabled

```heex
<.input
  field={@form[:title]}
  label="Task title"
  disabled
/>
```

### Required field (asterisk + aria-required)

```heex
<.input
  field={@form[:title]}
  label="Task title"
  required
/>
```

The component renders a `*` after the label and sets `aria-required="true"` on the input.

---

## 3. Auto-resize textarea variant — **new**

The composer textarea pattern (5 inline copies in chat + tasks per audit `1A-TOK-INLINE-1`) consolidates into `<.input type="textarea">` with an auto-resize sub-variant.

### Approach

Add a `kind` attr to the textarea path of `<.input>`:

```elixir
# In core_components.ex, extend the textarea branch:
attr :kind, :atom,
     default: :default,
     values: [:default, :auto_resize],
     doc: "Auto-resize textarea uses field-sizing: content + min/max heights."
```

When `type="textarea"` AND `kind={:auto_resize}`:

```heex
<textarea
  id={@id}
  name={@name}
  class={[
    "textarea textarea-bordered focus-visible-ring",
    "min-h-8 max-h-50 leading-normal py-1.5 px-3"
  ]}
  style="field-sizing: content"
  aria-label={@aria_label}
  {@rest}
><%= Phoenix.HTML.Form.normalize_value("textarea", @value) %></textarea>
```

The `style="field-sizing: content"` is the only inline-style that survives consolidation — there's no Tailwind utility for it (per `01-foundations.md` §3.2). All other formerly-inline values map to spacing-scale classes.

### Composer usage example

```heex
<.input
  field={@form[:body]}
  type="textarea"
  kind={:auto_resize}
  aria_label="Compose a message in #design-review"
  placeholder="Type a message — Enter to send, Shift+Enter for newline"
/>
```

This single line replaces all five inline-style instances at:
- `chat_live.html.heex:1185` (with `min-h-8` instead of `min-h-[33px]`; the 1px shift snaps to the spacing scale).
- `tasks_live.html.heex:1188`, `:1752`, `:1764`, `:1898`.

### Submit-on-Enter behavior

The composer convention is **Enter sends, Shift+Enter newline**. Phase 4 wires this in the existing `compose_input` JS hook at `~/projects/core/apps/platform/assets/js/hooks/compose_input.js`. The textarea component itself doesn't enforce the keybinding — that's a hook concern.

---

## 4. Accessibility notes

| Rule                              | How |
|-----------------------------------|-----|
| Label association                  | `<label for="id">` paired with `<input id="id">` automatically when `label` attr passed. |
| Error announcement                  | Error text has `role="alert"` so screen readers announce on appearance. `aria-describedby` ties input to error region. |
| Required-field indicator           | Visible `*` + `aria-required="true"` when `required` attr passed. |
| Focus ring                         | `focus-visible-ring` class applied; for inputs uses no-offset variant (border itself is the offset) — see `05-app-css-diff.md` §3. |
| Touch target                        | DaisyUI `.input` is ≥40px tall; `.input-sm` only on desktop. Mobile-only uses default size. |
| `aria-invalid`                      | Set automatically when `field.errors` non-empty. |

---

## 5. Migration map (consumer side)

### Bare-input transforms

| Existing                                                  | New                                                                                  |
|-----------------------------------------------------------|--------------------------------------------------------------------------------------|
| `<input type="text" name="task[title]" value={@title} />` | `<.input field={@form[:title]} type="text" label="Title" />`                         |
| `<textarea name="msg[body]" />` (any inline-style variant) | `<.input field={@form[:body]} type="textarea" kind={:auto_resize} aria_label="…" />` |
| `<select name="filter">…</select>`                       | `<.input field={@form[:filter]} type="select" label="Filter" options={…} />`         |

### Specific migration targets

From `IMPLEMENTATION.md` step 4:

```heex
<%!-- chat_live.html.heex composer (was line ~1185 inline textarea) --%>
<.input
  field={@form[:body]}
  type="textarea"
  kind={:auto_resize}
  aria_label="Compose a message in #{@space.name}"
  placeholder="Type a message…"
/>
```

```heex
<%!-- chat_live.html.heex search input --%>
<.input
  field={@search_form[:query]}
  type="search"
  aria_label="Search messages in this space"
  placeholder="Search messages…"
/>
```

```heex
<%!-- tasks_live.html.heex 4 instances of the auto-resize textarea --%>
<%!-- All four migrate to the same pattern as the chat composer above. --%>
```

---

## 6. What this spec does NOT cover

- **Rich text / markdown editor.** Out of scope; Burrow uses plain text in composers today. If a surface needs rich text, that's a separate component.
- **File-upload inputs** (`type="file"`). Existing `<.live_file_input>` handles uploads; not part of this consolidation.
- **Date pickers.** Native `type="date"` is fine for now; a styled date picker is a future task.
- **Combobox / autocomplete.** The existing mention-autocomplete in `chat_live.html.heex` is its own pattern; doesn't migrate to `<.input>`.

---

## 7. Phase 4 checklist

- [ ] Add `kind` attr to `<.input>` textarea branch in `core_components.ex` (single small edit).
- [ ] Add `aria_label` attr explicit declaration to `<.input>` (currently passes through via `:rest` but explicit attr is documentation).
- [ ] Migrate the 4 `tasks_live.html.heex` auto-resize textareas + 1 `chat_live.html.heex` composer to `<.input type="textarea" kind={:auto_resize}>`. Smoke-test each surface visually after migration (per `04-accessibility.md` §2 the touch-target test passes).
- [ ] Migrate other bare `<input>` sites (chat search, mention search, task forms) per `IMPLEMENTATION.md` step 4.
- [ ] Verify error rendering: introduce a deliberate validation failure (e.g. blank required field) and confirm error appears below the input with red border + `role="alert"` announcement.
- [ ] LiveView tests: form submission with invalid data → assert `has_element?(view, "[aria-invalid='true']")` and `has_element?(view, "[role='alert']")`.
