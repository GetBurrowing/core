# `<.empty_state>` component spec

**Phase 4 deliverable.** Code-ready specification for the EmptyState component. Implements Phase 2 `02-components.md` §2.13 + `03-voice.md` §5 (per-surface copy + V3 conversational pattern).

> **Anchored:** `1B-USE-3` (empty states lack agent-native context), Marlowe's empty-state direction (2026-05-09).

---

## 1. Module signature

New file: `~/projects/core/apps/platform/lib/platform_web/components/empty_state.ex`.

```elixir
defmodule PlatformWeb.Components.EmptyState do
  @moduledoc """
  Three layouts of empty state, per `docs/design-system/02-components.md` §2.13:

  - `:minimal`     — centered text only. Used on Activity (Marlowe pin 2026-05-09).
  - `:standard`    — icon + headline + body + CTA(s). Used as a generic fallback.
  - `:conversational` — V3 pattern: system message + Saru bubble + chip CTAs.
                        Used on chat sidebar, chat space, tasks (per `03-voice.md` §5.1, §5.2, §5.3).
  """
  use Phoenix.Component
  import PlatformWeb.CoreComponents, only: [icon: 1]

  attr :variant, :atom,
       default: :standard,
       values: [:minimal, :standard, :conversational]

  attr :icon_name, :string,
       default: nil,
       doc: "Heroicon name (`hero-...`). Optional. Used by :standard variant."

  slot :title
  slot :body, required: true
  slot :actions, doc: "CTA buttons. Used by :standard."
  slot :chips, doc: "List of {label, event} tuples. Used by :conversational."
  slot :system_message, doc: "Above the bot bubble. Used by :conversational."

  def empty_state(%{variant: :minimal} = assigns) do
    ~H"""
    <div class="empty-state empty-minimal">
      <p class="empty-body type-body">
        <%= render_slot(@body) %>
      </p>
    </div>
    """
  end

  def empty_state(%{variant: :standard} = assigns) do
    ~H"""
    <div class="empty-state empty-standard">
      <div :if={@icon_name} class="empty-icon-wrapper">
        <.icon name={@icon_name} class="size-8 text-secondary" />
      </div>
      <h2 :if={@title != []} class="empty-title type-h2">
        <%= render_slot(@title) %>
      </h2>
      <p class="empty-body type-body">
        <%= render_slot(@body) %>
      </p>
      <div :if={@actions != []} class="empty-actions">
        <%= render_slot(@actions) %>
      </div>
    </div>
    """
  end

  def empty_state(%{variant: :conversational} = assigns) do
    ~H"""
    <div class="empty-state empty-conversational">
      <p :if={@system_message != []} class="empty-system-msg">
        <%= render_slot(@system_message) %>
      </p>
      <div class="empty-bot-bubble">
        <span class="empty-bot-author">Saru · suggested</span>
        <%= render_slot(@body) %>
      </div>
      <%= for chip <- @chips do %>
        <button
          class="empty-chip focus-visible-ring"
          phx-click={chip[:event]}
          phx-value-label={chip[:label]}
        >
          <%= chip.inner_block && Phoenix.LiveView.TagEngine.component(chip.inner_block, [], %{}) %>
        </button>
      <% end %>
    </div>
    """
  end
end
```

Register in `platform_web.ex` HTML helpers.

---

## 2. CSS

CSS rules land in `app.css` (proposed):

```css
@layer components {
  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: stretch;
    padding: 1.5rem;
    flex: 1;
  }

  /* Minimal */
  .empty-minimal {
    align-items: center;
    justify-content: center;
    text-align: center;
  }
  .empty-minimal .empty-body {
    color: var(--color-secondary);
    max-width: 280px;
  }

  /* Standard */
  .empty-standard {
    align-items: center;
    justify-content: center;
    text-align: center;
    gap: 1rem;
  }
  .empty-icon-wrapper {
    width: 4.5rem;
    height: 4.5rem;
    border-radius: 50%;
    background: var(--color-base-200);
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .empty-title { margin: 0; }
  .empty-standard .empty-body {
    color: var(--color-secondary);
    max-width: 320px;
    margin: 0;
  }
  .empty-actions {
    display: flex;
    gap: 0.5rem;
    flex-direction: column;
    width: 100%;
    max-width: 240px;
  }

  /* Conversational */
  .empty-conversational {
    align-items: flex-start;
    justify-content: flex-end;
    gap: 0.5rem;
  }
  .empty-system-msg {
    align-self: center;
    background: var(--color-base-200);
    color: var(--color-secondary);
    padding: 0.4rem 0.75rem;
    border-radius: 999px;
    font-size: 0.7rem;
    margin: 0 0 0.5rem;
    max-width: 240px;
    text-align: center;
  }
  .empty-bot-bubble {
    align-self: flex-start;
    max-width: 80%;
    background: var(--color-base-200);
    padding: 0.6rem 0.75rem;
    border-radius: 0.75rem 0.75rem 0.75rem 0.25rem;
    font-size: 0.8125rem;
    line-height: 1.45;
    margin: 0;
  }
  .empty-bot-author {
    display: block;
    font-size: 0.7rem;
    color: var(--color-secondary);
    font-weight: 500;
    margin-bottom: 0.15rem;
  }
  .empty-chip {
    align-self: flex-start;
    background: var(--color-primary);
    color: var(--color-primary-content);
    border: 1px solid var(--color-primary);
    padding: 0.4rem 0.85rem;
    border-radius: 999px;
    font-size: 0.8125rem;
    font-weight: 600;
    cursor: pointer;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04);
  }
  .empty-chip:hover {
    background: oklch(78% 0.12 207);
  }
}
```

---

## 3. HEEx examples per surface

### Brand-new user (chat sidebar, no spaces yet) — `:conversational`

```heex
<.empty_state variant={:conversational}>
  <:system_message>— no spaces yet —</:system_message>
  <:body>Welcome to Suite. To get started, create a space or connect your agent.</:body>
  <:chips label="+ Create a space" event="new_channel_open" />
  <:chips label="+ Connect an agent" event={JS.navigate(~p"/control")} />
</.empty_state>
```

### Brand-new chat space (no posts) — `:conversational`

```heex
<.empty_state variant={:conversational}>
  <:system_message>— this space is quiet —</:system_message>
  <:body>Connect your agent and @ them to plan and work in this space.</:body>
  <:chips label="+ Add an agent" event="open_add_agent_sheet" />
</.empty_state>
```

### Tasks (no tasks) — `:conversational`

```heex
<.empty_state variant={:conversational}>
  <:system_message>— no tasks here yet —</:system_message>
  <:body>Create a task and assign to an agent to plan and execute.</:body>
  <:chips label="+ Create a task" event="open_create_task_sheet" />
  <:chips label="@ Saru, plan a project" event="prefill_compose_with_plan_request" />
</.empty_state>
```

### Activity (no actions in range) — `:minimal` (Marlowe pin 2026-05-09)

```heex
<.empty_state variant={:minimal}>
  <:body>
    When your agents start working, what they do appears here. Try a wider date range, or connect an agent to start.
  </:body>
</.empty_state>
```

**Important:** Activity uses `:minimal`, NOT `:conversational`. Per Marlowe 2026-05-09: "the activity feed empty state is fine to stay empty at start, we don't need to force content."

### Search (no results) — `:standard`

```heex
<.empty_state variant={:standard} icon_name="hero-magnifying-glass">
  <:title>No matches</:title>
  <:body>No messages match "<%= @query %>".</:body>
  <:actions>
    <.button variant={:tertiary} phx-click="clear_search">Clear search</.button>
  </:actions>
</.empty_state>
```

---

## 4. Accessibility notes

| Rule                              | How |
|-----------------------------------|-----|
| Heading hierarchy                  | `:standard` uses `<h2>` for the title (presumes the page has an `<h1>` elsewhere). |
| Live region                        | The empty state itself is not a live region — it's the static fallback when a list is empty. Use `aria-live` on the LIST container, not the empty state. |
| Chip is a button                   | `:conversational` chips are `<button>` elements; inherit native click + Enter+Space activation. |
| Focus ring                         | All chip buttons get the canonical focus ring per `04-accessibility.md` §1. |

---

## 5. Migration map

### Sites that consume `<.empty_state>`

| Site                                    | Variant            | Uses copy from           |
|-----------------------------------------|--------------------|---------------------------|
| `chat_live.html.heex:54` (sidebar, no channels) | `:conversational` | `03-voice.md` §5.1 |
| `chat_live.html.heex:92` / `:187` (sidebar, no DMs / no spaces) | `:conversational` | `03-voice.md` §5.1 |
| `chat_live.html.heex:454` (search no results) | `:standard` | `03-voice.md` §5.5 |
| Future: chat space empty (no posts)      | `:conversational` | `03-voice.md` §5.2 |
| `tasks_live.html.heex:331` (no tasks)    | `:conversational` | `03-voice.md` §5.3 |
| `activity_live.html.heex` (no actions)   | **`:minimal`**     | `03-voice.md` §5.4 (Marlowe pin) |

### Inline empty-state replacement

Existing inline pattern (e.g. `chat_live.html.heex:54-55`):
```heex
<div class="hidden only:block">
  No channels yet
</div>
```

→

```heex
<.empty_state variant={:conversational}>
  <:system_message>— no spaces yet —</:system_message>
  <:body>Welcome to Suite. To get started, create a space or connect your agent.</:body>
  <:chips label="+ Create a space" event="new_channel_open" />
  <:chips label="+ Connect an agent" event={JS.navigate(~p"/control")} />
</.empty_state>
```

---

## 6. What this spec does NOT cover

- **Skeleton loaders** for in-flight list loads. Different state (loading, not empty). Out of audit scope.
- **Filter-applied empty states** beyond search. If a future filter (e.g. "completed tasks only") returns empty, it follows `:standard` with copy explaining the filter context. Phase 4 doesn't enumerate these.
- **Onboarding tooltips / coach-marks.** The empty state's CTAs are the onboarding surface; if richer onboarding is needed, separate component.

---

## 7. Phase 4 checklist

- [ ] Create `~/projects/core/apps/platform/lib/platform_web/components/empty_state.ex`.
- [ ] Add CSS rules to `app.css` (folded into `05-app-css-diff.md`).
- [ ] Migrate the 4 chat empty-state sites in `chat_live.html.heex`.
- [ ] Migrate `tasks_live.html.heex` empty-state.
- [ ] Migrate `activity_live.html.heex` empty-state — **MUST use `:minimal`, not `:conversational`** (Marlowe pin).
- [ ] Manual verification: each empty state renders the verbatim copy from `03-voice.md` §5.
- [ ] LiveView tests: when the list is empty, `assert has_element?(view, ".empty-state")`; when the list has items, `assert not has_element?(view, ".empty-state")`.
