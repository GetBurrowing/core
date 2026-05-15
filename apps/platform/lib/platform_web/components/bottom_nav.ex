defmodule PlatformWeb.Components.BottomNav do
  @moduledoc """
  Mobile-only bottom tab bar (Chat / Tasks / Meetings / Activity / More).

  Replaces the shell hamburger drawer as the primary cross-surface
  navigation on mobile. Per the ui-ux-pro-max `bottom-nav-limit` and
  `tab-bar-ios` rules: max 5 items, labels with icons, bottom-of-screen
  for thumb reach.

  Active tab is determined from the `:active_module` assign passed by
  `PlatformWeb.ShellLive` (`derive_active_module/1`). Renders `<.link>`
  navigation for Chat / Tasks / Activity (1-tap surface switch). The More
  tab fires `phx-click="open_more_sheet"` instead of navigating; the
  More sheet itself is a Stage 2 deliverable of task 019e1322.

  The component is `lg:hidden` — desktop continues to use the existing
  left rail (`shell.html.heex` lines 1-150ish).

  ## Examples

      <.bottom_nav active_module={@active_module} />
      <.bottom_nav active_module={@active_module} tasks_count={@tasks_count} />
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  attr :active_module, :string, required: true, doc: "current surface label, e.g. \"Chat\""

  attr :tasks_count, :integer,
    default: 0,
    doc:
      "in-progress task count for the badge on the Tasks tab (Stage 3 wires the live data; Stage 1 ships with default 0 → badge hidden)"

  def bottom_nav(assigns) do
    ~H"""
    <nav
      class="bottom-nav lg:hidden"
      role="navigation"
      aria-label="Main navigation"
    >
      <.link
        navigate={~p"/chat"}
        class={["bottom-nav-tab", tab_active_class(@active_module, "Chat")]}
        aria-label="Chat"
        aria-current={tab_aria_current(@active_module, "Chat")}
      >
        <svg
          class="bottom-nav-icon"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
        </svg>
        <span class="bottom-nav-label">Chat</span>
      </.link>

      <.link
        navigate={~p"/tasks"}
        class={["bottom-nav-tab", tab_active_class(@active_module, "Tasks")]}
        aria-label="Tasks"
        aria-current={tab_aria_current(@active_module, "Tasks")}
      >
        <svg
          class="bottom-nav-icon"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M9 11l3 3L22 4M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11" />
        </svg>
        <span class="bottom-nav-label">Tasks</span>
        <span
          :if={@tasks_count > 0}
          class="bottom-nav-badge"
          aria-label={"#{@tasks_count} in progress"}
        >
          {format_badge_count(@tasks_count)}
        </span>
      </.link>

      <.link
        navigate={~p"/meetings"}
        class={["bottom-nav-tab", tab_active_class(@active_module, "Meetings")]}
        aria-label="Meetings"
        aria-current={tab_aria_current(@active_module, "Meetings")}
      >
        <svg
          class="bottom-nav-icon"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="m15.75 10.5 4.72-4.72a.75.75 0 0 1 1.28.53v11.38a.75.75 0 0 1-1.28.53l-4.72-4.72M4.5 18.75h9a2.25 2.25 0 0 0 2.25-2.25v-9a2.25 2.25 0 0 0-2.25-2.25h-9A2.25 2.25 0 0 0 2.25 7.5v9a2.25 2.25 0 0 0 2.25 2.25Z" />
        </svg>
        <span class="bottom-nav-label">Meetings</span>
      </.link>

      <.link
        navigate={~p"/activity"}
        class={["bottom-nav-tab", tab_active_class(@active_module, "Activity")]}
        aria-label="Activity"
        aria-current={tab_aria_current(@active_module, "Activity")}
      >
        <svg
          class="bottom-nav-icon"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M22 12h-4l-3 9L9 3l-3 9H2" />
        </svg>
        <span class="bottom-nav-label">Activity</span>
      </.link>

      <button
        type="button"
        phx-click="open_more_sheet"
        class="bottom-nav-tab"
        aria-label="More surfaces"
      >
        <svg
          class="bottom-nav-icon"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <circle cx="5" cy="12" r="1" />
          <circle cx="12" cy="12" r="1" />
          <circle cx="19" cy="12" r="1" />
        </svg>
        <span class="bottom-nav-label">More</span>
      </button>
    </nav>
    """
  end

  defp tab_active_class(active, label) when active == label, do: "bottom-nav-tab--active"
  defp tab_active_class(_, _), do: nil

  defp tab_aria_current(active, label) when active == label, do: "page"
  defp tab_aria_current(_, _), do: nil

  # Cap at 99+ so the badge stays a single-glyph circle.
  defp format_badge_count(n) when n > 99, do: "99+"
  defp format_badge_count(n), do: Integer.to_string(n)
end
