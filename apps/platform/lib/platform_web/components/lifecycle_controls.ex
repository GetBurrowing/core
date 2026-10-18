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

  import PlatformWeb.CoreComponents, only: [icon: 1, button: 1, chip: 1]

  @doc """
  Kebab overflow menu with Archive + Schedule deletion for one container.

  The host gates rendering on `Tenancy.root_admin?/1` and never renders it
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
  thing you can see. Fixed after the designer hit it walking the review
  (task 019f4eaa).

  The affirmative-looking primary is deliberately NOT used — the confirm
  button is `error`-filled because this is the one destructive step.
  """
  attr :resource, :map,
    default: nil,
    doc:
      "nil when closed. A project is `%{type: \"project\", id:, name:, preview:}` (simple confirm). An org is `%{type: \"org\", id:, name:, items: [%{id, name, type, status}], kept: MapSet, acknowledged: boolean}` (surface & choose)."

  attr :retention_days, :integer, required: true

  def schedule_delete_modal(assigns) do
    ~H"""
    <%!-- The backdrop carries NO phx-click: the org variant is a form whose
         checkboxes have no binding of their own, and a backdrop phx-click would
         be the nearest bound ancestor, closing the modal on every toggle. Both
         cards use phx-click-away instead — a click outside the card closes it,
         a click on a control never does. Escape still closes from the window. --%>
    <div
      :if={@resource}
      id="schedule-delete-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4 safe-area-x"
      phx-window-keydown="close_delete_modal"
      phx-key="escape"
      data-role="schedule-delete-modal"
    >
      <.org_purge_card
        :if={@resource.type == "org"}
        resource={@resource}
        retention_days={@retention_days}
      />
      <.simple_delete_card
        :if={@resource.type != "org"}
        resource={@resource}
        retention_days={@retention_days}
      />
    </div>
    """
  end

  # ── Simple confirm (projects — no children to surface) ─────────────────
  attr :resource, :map, required: true
  attr :retention_days, :integer, required: true

  defp simple_delete_card(assigns) do
    ~H"""
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
    """
  end

  # ── Surface & choose (orgs — task 019f7600 stage 5) ────────────────────
  #
  # Deleting an org takes every child with it. This card enumerates ALL of them
  # (`purge_preview/1`: active, cascade-hidden, and hand-archived alike — the
  # ones the old "Also hidden" list silently dropped) as an aligned checklist.
  # Default is delete-everything, matching "Delete <org> permanently"; checking
  # a row KEEPS that child — it stays archived and recoverable on its own,
  # surviving the org. A "I understand this is permanent" gate arms the button.
  attr :resource, :map, required: true
  attr :retention_days, :integer, required: true

  defp org_purge_card(assigns) do
    assigns =
      assign(assigns,
        kept_count: MapSet.size(assigns.resource.kept),
        item_count: length(assigns.resource.items)
      )

    ~H"""
    <form
      class="flex max-h-[calc(100dvh-2rem)] w-full max-w-xl flex-col rounded-box border border-base-content/10 bg-base-100 shadow-[var(--shadow-modal)]"
      role="dialog"
      aria-modal="true"
      aria-labelledby="schedule-delete-title"
      aria-describedby="schedule-delete-body"
      phx-click-away="close_delete_modal"
      phx-change="delete_modal_change"
      phx-submit="confirm_schedule_deletion"
    >
      <div class="border-b border-edge p-6 pb-4">
        <h2 id="schedule-delete-title" class="text-base font-semibold text-base-content">
          Delete {@resource.name} permanently?
        </h2>
        <p id="schedule-delete-body" class="mt-2 text-sm text-base-content/70">
          Everything below is scheduled for permanent deletion in
          <span class="font-semibold text-base-content">{@retention_days} days</span>
          and stays recoverable until then. Check anything you want to keep — it stays archived on its own and survives the delete.
        </p>
      </div>

      <div :if={@item_count > 0} class="flex items-center justify-between gap-3 px-6 py-3">
        <span class="text-xs font-medium uppercase tracking-wide text-base-content/50">
          <span class="tabular-nums text-base-content">{@kept_count}</span>
          of <span class="tabular-nums">{@item_count}</span>
          kept
        </span>
        <div class="flex items-center gap-1">
          <button
            type="button"
            phx-click="delete_keep_all"
            data-role="purge-keep-all"
            class="focus-visible-ring rounded-lg px-2.5 py-1 text-xs font-medium text-base-content/70 hover:bg-base-200 hover:text-base-content"
          >
            Keep all
          </button>
          <button
            type="button"
            phx-click="delete_include_all"
            data-role="purge-include-all"
            class="focus-visible-ring rounded-lg px-2.5 py-1 text-xs font-medium text-base-content/70 hover:bg-base-200 hover:text-base-content"
          >
            Delete all
          </button>
        </div>
      </div>

      <ul
        :if={@item_count > 0}
        data-role="purge-checklist"
        class="min-h-0 flex-1 overflow-y-auto border-y border-edge"
      >
        <.purge_row
          :for={item <- @resource.items}
          item={item}
          kept={MapSet.member?(@resource.kept, item.id)}
        />
      </ul>

      <p :if={@item_count == 0} class="px-6 py-4 text-sm text-base-content/60">
        Nothing else is filed under {@resource.name} — deleting it affects only the org.
      </p>

      <div class="flex flex-col gap-4 p-6 pt-4">
        <label class="flex items-center gap-2.5 text-sm text-base-content" data-role="purge-ack">
          <input
            type="checkbox"
            name="acknowledge"
            checked={@resource.acknowledged}
            class="checkbox checkbox-error checkbox-sm [--radius-selector:0.25rem] focus-visible-ring"
          />
          <span>I understand this is permanent.</span>
        </label>
        <div class="flex justify-end gap-2">
          <.button
            variant="ghost"
            type="button"
            phx-click="close_delete_modal"
            data-role="schedule-delete-cancel"
          >
            Cancel
          </.button>
          <.button
            variant="destructive"
            type="submit"
            disabled={not @resource.acknowledged}
            data-role="schedule-delete-confirm"
          >
            Delete
          </.button>
        </div>
      </div>
    </form>
    """
  end

  attr :item, :map, required: true
  attr :kept, :boolean, required: true

  defp purge_row(assigns) do
    ~H"""
    <li
      data-role="purge-item"
      data-id={@item.id}
      class="grid grid-cols-[1.25rem_1fr_auto_auto] items-center gap-3 border-b border-edge/60 px-6 py-2.5 last:border-0"
    >
      <input
        type="checkbox"
        name="keep[]"
        value={@item.id}
        checked={@kept}
        data-role="purge-keep"
        class="checkbox checkbox-success checkbox-sm [--radius-selector:0.25rem] focus-visible-ring"
        aria-label={"Keep #{@item.name}"}
      />
      <div class="flex min-w-0 items-center gap-2">
        <.icon name={purge_icon(@item.type)} class="size-4 shrink-0 text-base-content/40" />
        <span class={[
          "truncate text-sm",
          @kept && "text-base-content",
          !@kept && "text-base-content/70 line-through decoration-error/40"
        ]}>
          {@item.name}
        </span>
      </div>
      <.status_chip status={@item.status} />
      <.chip tone={if(@kept, do: "success", else: "error")} class="justify-self-end">
        {if @kept, do: "Keep", else: "Delete"}
      </.chip>
    </li>
    """
  end

  attr :status, :atom, required: true

  defp status_chip(%{status: :scheduled} = assigns),
    do: ~H|<.chip tone="warning">Scheduled</.chip>|

  defp status_chip(%{status: :archived} = assigns),
    do: ~H|<.chip tone="neutral">Archived</.chip>|

  defp status_chip(assigns), do: ~H|<.chip tone="info">Active</.chip>|

  defp purge_icon(:project), do: "hero-folder"
  defp purge_icon(:channel), do: "hero-hashtag"

  @doc """
  Undo toast for an archive. `undo` is `nil` (hidden) or
  `%{type:, id:, name:, hidden: [label]}`.

  Archive is instant and reversible with NO confirm dialog — that is the
  approved design, and the reason is the house principle: recoverable by
  default, undo rather than consent. But instant-and-silent meant an org
  archive could hide several things with no acknowledgement of what went.
  The designer asked for the same visibility the confirm dialog now has, so this is
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

  @doc """
  "Restore all" warning modal for an org whose children are individually
  counting down to a permanent purge (task 019f7600 stage 5).

  Restoring the org revives the whole subtree, which by default also cancels
  those countdowns. This card surfaces the scheduled children first — aligned
  columns of name · type · delete date · outcome — and lets the admin CHECK any
  child to leave it on its clock ("keep scheduled") while the rest come back.
  Without it, restoring an org silently left a child ticking toward deletion.

  `restore` is `nil` (closed) or
  `%{org: %{id:, name:}, children: [%{id, name, type, delete_on}], kept: MapSet}`
  where `kept` holds the ids the admin chose to keep scheduled.
  """
  attr :restore, :map,
    default: nil,
    doc: "nil when closed; %{org:, children: [], kept: MapSet} when open."

  def restore_all_modal(assigns) do
    ~H"""
    <div
      :if={@restore}
      id="restore-all-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4 safe-area-x"
      phx-window-keydown="close_restore_modal"
      phx-key="escape"
      data-role="restore-all-modal"
    >
      <div
        class="flex max-h-[calc(100dvh-2rem)] w-full max-w-xl flex-col rounded-box border border-base-content/10 bg-base-100 shadow-[var(--shadow-modal)]"
        role="dialog"
        aria-modal="true"
        aria-labelledby="restore-all-title"
        aria-describedby="restore-all-body"
        phx-click-away="close_restore_modal"
      >
        <div class="border-b border-edge p-6 pb-4">
          <h2 id="restore-all-title" class="text-base font-semibold text-base-content">
            Restore {@restore.org.name}?
          </h2>
          <p id="restore-all-body" class="mt-2 text-sm text-base-content/70">
            These items are counting down to permanent deletion. Restoring brings them all back too.
            Check any you'd rather keep scheduled — they stay on their countdown.
          </p>
        </div>

        <ul
          data-role="keep-scheduled-list"
          class="min-h-0 flex-1 overflow-y-auto border-b border-edge"
        >
          <li
            :for={child <- @restore.children}
            data-role="keep-scheduled-item"
            data-id={child.id}
            class="grid grid-cols-[1.25rem_1fr_auto_auto] items-center gap-3 border-b border-edge/60 px-6 py-2.5 last:border-0"
          >
            <input
              type="checkbox"
              checked={MapSet.member?(@restore.kept, child.id)}
              phx-click="toggle_keep_scheduled"
              phx-value-id={child.id}
              data-role="keep-scheduled"
              class="checkbox checkbox-warning checkbox-sm [--radius-selector:0.25rem] focus-visible-ring"
              aria-label={"Keep #{child.name} scheduled for deletion"}
            />
            <div class="flex min-w-0 items-center gap-2">
              <.icon name={purge_icon(child.type)} class="size-4 shrink-0 text-base-content/40" />
              <span class="truncate text-sm text-base-content">{child.name}</span>
            </div>
            <span class="flex items-center gap-1.5 whitespace-nowrap text-xs tabular-nums text-base-content/60">
              <.icon name="hero-calendar" class="size-3.5 shrink-0" />
              {child.delete_on}
            </span>
            <.chip tone={if(MapSet.member?(@restore.kept, child.id), do: "warning", else: "success")}>
              {if MapSet.member?(@restore.kept, child.id), do: "Delete scheduled", else: "Restore"}
            </.chip>
          </li>
        </ul>

        <div class="flex justify-end gap-2 p-6 pt-4">
          <.button variant="ghost" phx-click="close_restore_modal" data-role="restore-all-cancel">
            Cancel
          </.button>
          <.button variant="primary" phx-click="confirm_restore_all" data-role="restore-all-confirm">
            <.icon name="hero-arrow-uturn-left" class="size-4" /> Restore all
          </.button>
        </div>
      </div>
    </div>
    """
  end

  # ── Delete-modal (org "surface & choose") state reducers ───────────────
  # Kept out of the host LiveViews so both the Tasks and Chat surfaces drive the
  # same include/keep state without duplicating the logic.

  @doc "Open state for the org delete confirm — nothing kept, gate un-armed."
  @spec build_org_delete_modal(String.t(), String.t(), [map()]) :: map()
  def build_org_delete_modal(id, name, items) do
    %{type: "org", id: id, name: name, items: items, kept: MapSet.new(), acknowledged: false}
  end

  @doc "Fold a `delete_modal_change` form payload (checked keeps + the gate) into the modal."
  @spec delete_modal_apply_change(map(), map()) :: map()
  def delete_modal_apply_change(resource, params) do
    kept = params |> Map.get("keep", []) |> MapSet.new()
    acknowledged = truthy?(Map.get(params, "acknowledge"))
    %{resource | kept: kept, acknowledged: acknowledged}
  end

  @doc "Mark every child Keep (spare all)."
  @spec delete_modal_keep_all(map()) :: map()
  def delete_modal_keep_all(resource),
    do: %{resource | kept: MapSet.new(Enum.map(resource.items, & &1.id))}

  @doc "Clear every Keep (delete all — the default)."
  @spec delete_modal_include_all(map()) :: map()
  def delete_modal_include_all(resource), do: %{resource | kept: MapSet.new()}

  defp truthy?(v), do: v in ["true", "on", true]

  # Plain-language "what gets hidden" line, tuned per resource type. The org
  # copy deliberately does NOT enumerate ("its projects and channels") any
  # more — the cascade list below does that by name.
  defp schedule_body("org"), do: "This hides the org and everything under it from everyone."

  defp schedule_body("project"),
    do: "This hides the project and its tasks from everyone."

  defp schedule_body(_), do: "This hides it from everyone."
end
