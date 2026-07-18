defmodule PlatformWeb.Components.LifecycleControls do
  @moduledoc """
  Inline archive / schedule-deletion affordances for the container
  resources — orgs and projects (task 019f4eaa stage 6). Two pieces that
  work together on any surface that lists containers (Tasks sidebar, Chat
  sidebar):

    * `lifecycle_menu/1` — a kebab (overflow) button that opens a small
      menu with **Archive** (instant, reversible — no confirm) and
      **Schedule deletion…** (opens the confirm modal). Follows the
      styled-div dropdown pattern already used by the Tasks create menu:
      a full-screen scrim closes it on tap-out / Escape.

    * `schedule_delete_modal/1` — the one centered confirm dialog the
      "Schedule deletion…" item opens. Rendered once per surface; the
      parent LiveView points it at the resource being scheduled.

  Design direction (Saru, locked): **recoverable-by-default** — archive
  is instant and reversible with NO modal; only the irreversible-feeling
  "Schedule deletion" step confirms. `primary` (cyan) is reserved for the
  affirmative Restore action in the Recovery view, so nothing here uses
  it; the destructive step is the only `error`-toned control.

  ## Events the host LiveView must handle

    * `"toggle_lifecycle_menu"` — `%{"key" => key}` (the menu's own key,
      e.g. `"org:soylent"`); toggle `@lifecycle_menu_key`.
    * `"archive_container"` — `%{"type" => "org"|"project", "id" =>, "name" =>}`;
      set `@undo_archive` and render `archive_undo_toast/1`.
    * `"undo_archive"` / `"dismiss_undo_archive"` — the toast's two actions.
    * `"open_delete_modal"` — `%{"type" =>, "id" =>, "name" =>}`; set
      `@delete_modal`.
    * `"close_delete_modal"` / `"confirm_schedule_deletion"` — modal.
  """
  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1, button: 1]

  @doc """
  Kebab overflow menu with Archive + Schedule deletion for one container.

  The host gates rendering on `Tenancy.fabrikam_admin?/1` and never renders it
  for the root org (which the lifecycle refuses anyway).
  """
  attr :key, :string,
    required: true,
    doc: "Unique menu key, e.g. \"org:soylent\" or \"project:<uuid>\"."

  attr :open, :boolean, default: false, doc: "Whether this menu is the currently-open one."
  attr :type, :string, required: true, values: ~w(org project)
  attr :id, :string, required: true, doc: "Resource identifier — org slug/UUID or project UUID."

  attr :name, :string,
    required: true,
    doc: "Human label used in the menu's aria + the confirm modal."

  attr :class, :any,
    default: "relative",
    doc:
      "Positioning classes for the wrapper. MUST establish a positioned ancestor for the dropdown — default `\"relative\"`; pass e.g. `\"absolute right-1 top-1.5\"` to overlay a row without a `relative`/`absolute` clash."

  def lifecycle_menu(assigns) do
    ~H"""
    <div class={[@class]} data-role="lifecycle-menu" data-menu-key={@key}>
      <button
        type="button"
        phx-click="toggle_lifecycle_menu"
        phx-value-key={@key}
        class="btn btn-ghost btn-xs btn-square focus-visible-ring"
        aria-haspopup="menu"
        aria-expanded={to_string(@open)}
        aria-label={"Manage #{@name}"}
        data-role="lifecycle-menu-trigger"
      >
        <span class="hero-ellipsis-vertical size-4"></span>
      </button>

      <%!-- Styled-div dropdown (not a browser popover): scrim closes on
           tap-out / Escape; card reads elevation from --shadow-dropdown. --%>
      <div
        :if={@open}
        class="fixed inset-0 z-30"
        phx-click="toggle_lifecycle_menu"
        phx-value-key={@key}
        phx-window-keydown="toggle_lifecycle_menu"
        phx-key="escape"
        aria-hidden="true"
      >
      </div>
      <div
        :if={@open}
        role="menu"
        aria-label={"#{@name} actions"}
        class="absolute right-0 top-full z-40 mt-1 flex min-w-48 flex-col gap-1 rounded-box border border-base-content/10 bg-base-100 p-1.5"
        style="box-shadow: var(--shadow-dropdown);"
        data-role="lifecycle-menu-list"
      >
        <button
          type="button"
          role="menuitem"
          phx-click="archive_container"
          phx-value-type={@type}
          phx-value-id={@id}
          phx-value-name={@name}
          class="flex items-center gap-2 rounded-lg px-3 py-2 text-left text-sm hover:bg-base-200 focus-visible-ring"
          data-role="lifecycle-archive"
        >
          <.icon name="hero-archive-box" class="size-4 text-base-content/60" />
          <span class="flex-1">Archive</span>
        </button>
        <button
          type="button"
          role="menuitem"
          phx-click="open_delete_modal"
          phx-value-type={@type}
          phx-value-id={@id}
          phx-value-name={@name}
          class="flex items-center gap-2 rounded-lg px-3 py-2 text-left text-sm text-error hover:bg-error/10 focus-visible-ring"
          data-role="lifecycle-schedule-delete"
        >
          <.icon name="hero-trash" class="size-4" />
          <span class="flex-1">Schedule deletion…</span>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Centered confirm dialog for "Schedule deletion". Rendered once per
  surface; `resource` is `nil` (closed) or `%{type:, id:, name:}`.

  The card is styled with the reskin's own surface tokens — the same
  `rounded-box border border-base-content/10 bg-base-100` treatment the
  lifecycle menu above and `action_patterns.ex` use — plus `--shadow-modal`.

  It must NOT use DaisyUI's `.modal-box`. That class ships
  `scale: 95%; opacity: 0` (app.css) and is only revealed by a
  `.modal` PARENT carrying `.modal-open` / `[open]` / `:target`. This
  dialog rolls its own backdrop, so there is no such parent: a
  `.modal-box` here renders at the right size, in the right place, with
  its text — and is completely invisible. The symptom is "the page dims
  but nothing happens", because the hand-rolled backdrop is the only
  thing you can see. Fixed after Marlowe hit it walking the review
  (task 019f4eaa).

  The affirmative-looking primary is deliberately NOT used — the confirm
  button is `error`-filled because this is the one destructive step.
  """
  attr :resource, :map, default: nil, doc: "nil when closed; %{type:, id:, name:} when open."
  attr :retention_days, :integer, required: true

  def schedule_delete_modal(assigns) do
    ~H"""
    <div
      :if={@resource}
      id="schedule-delete-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4 safe-area-x"
      phx-click="close_delete_modal"
      phx-window-keydown="close_delete_modal"
      phx-key="escape"
      data-role="schedule-delete-modal"
    >
      <div
        class="w-full max-w-md rounded-box border border-base-content/10 bg-base-100 p-6 shadow-[var(--shadow-modal)]"
        role="dialog"
        aria-modal="true"
        aria-labelledby="schedule-delete-title"
        aria-describedby="schedule-delete-body"
        phx-click-away="close_delete_modal"
      >
        <h2 id="schedule-delete-title" class="text-base font-semibold text-base-content">
          Schedule deletion for {@resource.name}?
        </h2>
        <p id="schedule-delete-body" class="mt-2 text-sm text-base-content/70">
          {schedule_body(@resource.type)} It stays recoverable from the
          Recovery view for <span class="font-semibold text-base-content">{@retention_days} days</span>,
          then it's permanently deleted. You can bring it back any time before then.
        </p>
        <%!-- Exactly what the cascade takes with it, by name — Marlowe's call
             (2026-07-16): the bulk cascade is useful and stays, but a dialog
             that says "and everything under it" makes you retire a group
             without seeing what's in it. Absent for projects (they have no
             cascade) and for an org whose children are all already archived
             — in both cases nothing else changes, so there's nothing to warn
             about and the list correctly collapses to nothing. --%>
        <div
          :if={cascade_total(@resource) > 0}
          data-role="schedule-delete-cascade"
          class="mt-4 rounded-box border border-base-300 bg-base-200/40 p-3"
        >
          <p class="text-xs font-medium uppercase tracking-wide text-base-content/50">
            Also hidden ({cascade_total(@resource)})
          </p>
          <ul class="mt-2 space-y-1 text-sm text-base-content/80">
            <li :for={name <- @resource.preview.projects} class="flex items-center gap-2">
              <.icon name="hero-folder" class="size-3.5 shrink-0 text-base-content/40" />
              <span class="truncate">{name}</span>
            </li>
            <li :for={name <- @resource.preview.channels} class="flex items-center gap-2">
              <span class="shrink-0 text-base-content/40">#</span>
              <span class="truncate">{name}</span>
            </li>
          </ul>
        </div>
        <div class="modal-action mt-5 flex justify-end gap-2">
          <.button variant="ghost" phx-click="close_delete_modal" data-role="schedule-delete-cancel">
            Cancel
          </.button>
          <.button
            variant="destructive"
            phx-click="confirm_schedule_deletion"
            data-role="schedule-delete-confirm"
          >
            Schedule deletion
          </.button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Undo toast for an archive. `undo` is `nil` (hidden) or
  `%{type:, id:, name:, hidden: [label]}`.

  Archive is instant and reversible with NO confirm dialog — that is the
  approved design, and the reason is the house principle: recoverable by
  default, undo rather than consent. But instant-and-silent meant an org
  archive could hide several things with no acknowledgement of what went.
  Marlowe asked for the same visibility the confirm dialog now has, so this is
  the undo-shaped version of it: act immediately, say what happened, keep the
  escape hatch one click away.

  Rendered as a TOP-LEVEL sibling, never inside an `:if` wrapper — pinned
  chrome nested in a conditional region remounts when the region toggles.
  """
  attr :undo, :map,
    default: nil,
    doc: "nil when hidden; %{type:, id:, name:, hidden: []} when shown."

  def archive_undo_toast(assigns) do
    ~H"""
    <div
      :if={@undo}
      id="archive-undo-toast"
      data-role="archive-undo-toast"
      class="fixed inset-x-0 bottom-[calc(env(safe-area-inset-bottom)+1.5rem+var(--bottom-nav-height,0px))] z-50 mx-auto flex w-fit max-w-[calc(100vw-2rem)] items-center gap-3 rounded-box border border-base-content/10 bg-base-100 px-4 py-3 shadow-[var(--shadow-modal)]"
      role="status"
      aria-live="polite"
    >
      <div class="min-w-0">
        <p class="text-sm font-medium text-base-content">
          Archived {@undo.name}
        </p>
        <p :if={@undo.hidden != []} class="truncate text-xs text-base-content/60">
          Also hid {length(@undo.hidden)}: {Enum.join(@undo.hidden, ", ")}
        </p>
      </div>
      <.button
        variant="ghost"
        phx-click="undo_archive"
        data-role="archive-undo"
        class="btn btn-ghost btn-xs shrink-0 focus-visible-ring"
      >
        Undo
      </.button>
      <button
        type="button"
        phx-click="dismiss_undo_archive"
        data-role="archive-undo-dismiss"
        class="shrink-0 rounded p-1 text-base-content/40 transition-colors hover:text-base-content focus-visible-ring"
        aria-label="Dismiss"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    """
  end

  # Plain-language "what gets hidden" line, tuned per resource type. The org
  # copy deliberately does NOT enumerate ("its projects and channels") any
  # more — the cascade list below does that by name.
  defp schedule_body("org"), do: "This hides the org and everything under it from everyone."

  defp schedule_body("project"),
    do: "This hides the project and its tasks from everyone."

  defp schedule_body(_), do: "This hides it from everyone."

  # How many children the cascade would take. Tolerant of a resource with no
  # `preview` key: every caller supplies one today, but this component is
  # rendered from two LiveViews and a missing key must not crash the dialog —
  # it should just fall back to the old, vaguer copy.
  defp cascade_total(%{preview: %{projects: projects, channels: channels}}),
    do: length(projects) + length(channels)

  defp cascade_total(_), do: 0
end
