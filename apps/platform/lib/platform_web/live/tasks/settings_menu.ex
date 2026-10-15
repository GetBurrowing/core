defmodule PlatformWeb.Tasks.SettingsMenu do
  @moduledoc """
  The Tasks settings menu (task 019fed1e), lifted out of the
  `TasksLive` shell template so the shell stays inside its surface line
  budget (`scripts/surface-budgets.txt`).

  Two render sites, one concern: the desktop dropdown that hangs off the
  header cog, and the phone bottom-sheet form of the same rows. They are
  never both visible, but both are in the DOM, so their pipeline links
  carry DISTINCT `data-role`s — a shared role would make every selector
  ambiguous.

  These are plain **function components**, not a LiveComponent, and that is
  deliberate: `toggle_settings_menu` and `:settings_menu_open` stay on
  `PlatformWeb.TasksLive`. A LiveComponent here would have needed a
  `phx-target`, and any JS-hook-pushed event into this markup would have
  ignored it. Nothing about the rendered output or the event routing
  changes relative to the inline markup this replaces.
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  alias Platform.Access

  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  attr :access_scope, :any, required: true
  attr :open?, :boolean, required: true

  @doc """
  Desktop cog + dropdown. LAST in the header control order so it never
  competes with what a member came to use. One row today (Pipeline); the
  row carries a description line, which is the reason this is a menu and
  not a bare link. Deliberately NO lock icon, NO "Admin" badge, NO tinted
  row: a member never renders the trigger, so a marker would warn nobody,
  and for an admin every row here is admin-only, so a badge would mark the
  rule rather than the exception. The cog's presence IS the signal. Same
  styled-div/scrim mechanism as the header create menu —
  `border-base-content/10` matches that sibling rather than the base-300
  the design canvas names, for visual consistency between two menus in one
  header.
  """
  def settings_menu(assigns) do
    assigns = assign(assigns, :show_pipeline?, Access.module_access?(assigns.access_scope, :tasks, "tasks.manage"))

    ~H"""
    <div :if={@show_pipeline?} class="relative">
      <button
        type="button"
        phx-click="toggle_settings_menu"
        class="btn btn-ghost btn-sm px-2 text-base-content/60 hover:text-base-content focus-visible-ring"
        aria-label="Tasks settings"
        aria-haspopup="menu"
        aria-controls="tasks-settings-menu"
        aria-expanded={to_string(@open?)}
        data-role="tasks-settings-menu-trigger"
      >
        <span class="hero-cog-6-tooth size-5"></span>
      </button>

      <div
        :if={@open?}
        class="fixed inset-0 z-30 hidden md:block"
        phx-click="toggle_settings_menu"
        phx-window-keydown="toggle_settings_menu"
        phx-key="escape"
        aria-hidden="true"
      >
      </div>
      <div
        :if={@open?}
        id="tasks-settings-menu"
        role="menu"
        aria-label="Tasks settings"
        class="absolute right-0 top-full z-40 mt-2 hidden min-w-64 flex-col rounded-box border border-base-content/10 bg-base-100 p-2 md:flex"
        style="box-shadow: var(--shadow-dropdown);"
      >
        <.link
          navigate={~p"/tasks/pipeline"}
          role="menuitem"
          class="flex flex-col gap-0.5 rounded-lg px-3 py-2 text-left hover:bg-base-200 focus-visible-ring"
          data-role="tasks-settings-pipeline-link"
        >
          <span class="text-sm font-medium text-base-content">Pipeline</span>
          <span class="text-xs text-base-content/60">
            Stage and validation flow across all tasks
          </span>
        </.link>
      </div>
    </div>
    """
  end

  attr :access_scope, :any, required: true
  attr :open?, :boolean, required: true

  @doc """
  The phone form of the same menu. Uses the house sheet primitive rather
  than a dropdown at phone width, per the design canvas; its known >768px
  centred-card reflow and inert grab handle are task 019fed0f-ed70 and out
  of scope here.
  """
  def settings_sheet(assigns) do
    assigns = assign(assigns, :show_pipeline?, Access.module_access?(assigns.access_scope, :tasks, "tasks.manage"))

    ~H"""
    <.sheet
      :if={@show_pipeline? and @open?}
      id="tasks-settings-sheet"
      open={true}
      placement={:bottom}
      on_close="toggle_settings_menu"
      class="md:hidden"
    >
      <:title>Tasks settings</:title>
      <div class="flex flex-col gap-1">
        <.link
          navigate={~p"/tasks/pipeline"}
          class="flex flex-col gap-0.5 rounded-lg px-4 py-3 text-left hover:bg-base-200 transition-colors focus-visible-ring"
          data-role="tasks-settings-pipeline-link-mobile"
        >
          <span class="text-sm font-medium text-base-content">Pipeline</span>
          <span class="text-xs text-base-content/60">
            Stage and validation flow across all tasks
          </span>
        </.link>
      </div>
    </.sheet>
    """
  end
end
