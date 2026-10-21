defmodule PlatformWeb.Components.ActionPatterns do
  @moduledoc """
  Re-skin Phase 2 stage 2 (task 019f51ca): shared action patterns for
  list screens — sticky page header, search input, small add buttons and
  the single mobile create-FAB with an anchored menu.

  These are layout/behaviour shells: open/close state for menus lives in
  the host LiveView (an `open` assign + a toggle event name), never in
  the component. Spacing sticks to the 8px grid (gap-2/3/4 only) and
  every icon-only control requires an accessible label.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  @doc """
  Sticky list-screen header: title + count badge, optional search /
  filters / primary-action slots.

  Console-style two-row layout (design review 2026-07-12): a compact title row,
  then ONE toolbar row holding the search (caller sets a fixed width —
  never full-bleed), inline pre-filters, and the right-aligned primary
  action, all on the same level. Below `md` the search takes its own
  full line and the filters wrap under it. Bottom hairline is
  `border-base-content/10` — slot content should not add its own
  borders or padding rows.
  """
  attr(:title, :string, required: true)
  attr(:count, :integer, default: nil, doc: "total count badge; hidden when nil")
  attr(:class, :any, default: nil)
  attr(:rest, :global)

  slot(:leading, doc: "renders before the title (e.g. a mobile nav trigger)")
  slot(:badges, doc: "extra badges inline after the count")

  slot(:search,
    doc: "search control; caller sets width (e.g. md:w-80) — toolbar row, never full-bleed"
  )

  slot(:filters, doc: "inline pre-filters beside the search (Console pattern)")
  slot(:primary_action, doc: "right-aligned action cluster")

  def page_header(assigns) do
    assigns =
      assign(
        assigns,
        :has_toolbar?,
        assigns.search != [] or assigns.filters != [] or assigns.primary_action != []
      )

    ~H"""
    <header
      class={["sticky top-0 z-20 border-b border-base-content/10 bg-base-100", @class]}
      {@rest}
    >
      <div class={["flex items-center gap-3 px-4 pt-3", (@has_toolbar? && "pb-2") || "pb-3"]}>
        {render_slot(@leading)}
        <h1 class="text-sm font-semibold uppercase tracking-widest text-base-content">
          {@title}
        </h1>
        <span :if={not is_nil(@count)} class="badge badge-ghost badge-sm">{@count}</span>
        {render_slot(@badges)}
      </div>
      <div :if={@has_toolbar?} class="flex flex-wrap items-center gap-2 px-4 pb-3 md:gap-3">
        <div :if={@search != []} class="w-full min-w-0 md:w-auto md:shrink-0">
          {render_slot(@search)}
        </div>
        <div :if={@filters != []} class="flex min-w-0 flex-1 flex-wrap items-center gap-2">
          {render_slot(@filters)}
        </div>
        <div :if={@primary_action != []} class="ml-auto flex shrink-0 items-center gap-2">
          {render_slot(@primary_action)}
        </div>
      </div>
    </header>
    """
  end

  @doc """
  One search visual: magnifier + DaisyUI input (10px radius + cyan focus
  come from the stage-1 component layer).

  Live mode (default): `phx-change` on the wrapping form, debounce 200.
  `deep` mode drops live change events and renders an explicit Search
  button — the button IS the deep-search signal — switching the form to
  `phx-submit` semantics. Both modes submit on Enter and send Escape
  keydowns to the same event (`type="search"` also clears natively in
  Blink/WebKit) so the host LiveView can reset its query assign.
  """
  attr(:id, :string, required: true)
  attr(:event, :string, required: true, doc: "phx-change (live) / phx-submit (deep) event name")

  attr(:target, :any,
    default: nil,
    doc:
      "phx-target for `event`. Pass a LiveComponent's `@myself` (or a selector) when the handler lives in a component — the form, the keydown and the submit all need it, and without it they land on the parent LiveView. Task 01a008f6 stage 6."
  )

  attr(:value, :string, default: nil)
  attr(:placeholder, :string, default: "Search…")
  attr(:name, :string, default: "q", doc: "param key the event handler receives")
  attr(:aria_label, :string, default: nil, doc: "defaults to the placeholder")
  attr(:deep, :boolean, default: false)
  attr(:class, :any, default: nil)

  def search_input(assigns) do
    ~H"""
    <form
      id={"#{@id}-form"}
      phx-change={!@deep && @event}
      phx-submit={@event}
      phx-target={@target}
      class={["flex w-full items-center gap-2", @class]}
    >
      <label class="input input-sm flex w-full items-center gap-2">
        <.icon name="hero-magnifying-glass" class="size-4 shrink-0 opacity-50" />
        <input
          id={@id}
          type="search"
          name={@name}
          value={@value}
          placeholder={@placeholder}
          aria-label={@aria_label || @placeholder}
          autocomplete="off"
          phx-debounce={if(!@deep, do: "200")}
          phx-keydown={@event}
          phx-target={@target}
          phx-key="escape"
          class="grow"
        />
        <kbd class="kbd kbd-xs hidden opacity-50 md:inline-flex">esc</kbd>
      </label>
      <button :if={@deep} type="submit" class="btn btn-primary btn-sm shrink-0 focus-visible-ring">
        Search
      </button>
    </form>
    """
  end

  @doc """
  Small square icon-button for section headers (26px, exceeds the 24px
  minimum hit area). `aria_label` is required; `title` falls back to it.
  """
  attr(:aria_label, :string, required: true)
  attr(:title, :string, default: nil)
  attr(:icon, :string, default: "hero-plus")
  attr(:class, :any, default: nil)
  attr(:rest, :global)

  def section_add_button(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "inline-flex size-[26px] shrink-0 items-center justify-center rounded-lg",
        "border border-base-content/15 text-base-content transition-colors",
        "hover:bg-base-200 hover:text-base-content focus-visible-ring",
        @class
      ]}
      aria-label={@aria_label}
      title={@title || @aria_label}
      {@rest}
    >
      <.icon name={@icon} class="size-4" />
    </button>
    """
  end

  @doc """
  Mobile floating action button toggling an anchored create menu.

  Open state is host-owned: pass `open` + a `toggle_event` the LiveView
  flips. The menu is a plain card-styled div (NOT a browser popover):
  a tap-out scrim closes it (the scrim also carries a window-level
  Escape binding — hook-free, and only mounted while open), and the
  card sits above the FAB with `--shadow-dropdown`. Slot items must be
  buttons with icon + label; item clicks should also close the menu
  server-side (the host's action handlers reset the open assign).

  Offsets include `env(safe-area-inset-bottom)` + `--bottom-nav-height`
  so the FAB clears the mobile bottom nav; `class` on the wrapper is the
  place for visibility guards (`md:hidden`, `max-md:hidden`, …).
  """
  attr(:id, :string, default: nil, doc: "wrapper id — stable hook for tests/e2e")
  attr(:open, :boolean, required: true)
  attr(:toggle_event, :string, required: true)

  attr(:toggle_target, :any,
    default: nil,
    doc:
      "phx-target for `toggle_event`. Pass a LiveComponent's `@myself` when the FAB is rendered INSIDE a LiveComponent — without it the toggle, the scrim tap-out and the window Escape binding all escape to the parent LiveView, which no longer has the handler. Task 01a008f6 stage 6."
  )

  attr(:label, :string, default: "Create", doc: "accessible name for the FAB + menu")
  attr(:class, :any, default: nil, doc: "wrapper classes — visibility guards go here")
  attr(:rest, :global, doc: "extra attributes for the FAB button (e.g. data-role)")

  slot(:inner_block, required: true, doc: "menu items: buttons with icon + label")

  def fab_create(assigns) do
    ~H"""
    <div id={@id} class={@class}>
      <div
        :if={@open}
        class="fixed inset-0 z-30 bg-black/30"
        phx-click={@toggle_event}
        phx-target={@toggle_target}
        phx-window-keydown={@toggle_event}
        phx-key="escape"
        aria-hidden="true"
      >
      </div>
      <div
        :if={@open}
        id="fab-create-menu"
        role="menu"
        aria-label={@label}
        class="fixed bottom-[calc(env(safe-area-inset-bottom)+5rem+var(--bottom-nav-height,0px))] right-6 z-40 flex min-w-52 flex-col gap-2 rounded-box border border-base-content/10 bg-base-100 p-2"
        style="box-shadow: var(--shadow-dropdown);"
      >
        {render_slot(@inner_block)}
      </div>
      <button
        type="button"
        phx-click={@toggle_event}
        phx-target={@toggle_target}
        aria-label={@label}
        aria-haspopup="menu"
        aria-expanded={to_string(@open)}
        aria-controls={@open && "fab-create-menu"}
        class="btn btn-primary btn-circle fixed bottom-[calc(env(safe-area-inset-bottom)+1.5rem+var(--bottom-nav-height,0px))] right-6 z-40 focus-visible-ring"
        style="box-shadow: var(--glow-btn);"
        {@rest}
      >
        <.icon name="hero-plus" class={["size-6 transition-transform", @open && "rotate-45"]} />
      </button>
    </div>
    """
  end
end
