defmodule PlatformWeb.Components.MoreSheet do
  @moduledoc """
  Mobile-only bottom sheet for the long-tail surfaces that don't get a
  dedicated tab in the bottom rail.

  Triggered by the `phx-click="open_more_sheet"` button on the More tab in
  `<.bottom_rail>`. The destination list is now data-driven from
  `PlatformWeb.Components.IconRail.destinations/1` — the same single source
  of truth that drives the desktop rail and the mobile bottom rail.

  Sections, from `IconRail.more_sheet_sections/2`:
    * **Inbox** — first, with its unread count badge
      (`data-role="more-sheet-inbox-badge"`, the `IconRail.badge_text/1`
      grammar). Inbox left the bar in task 01a1557a-7a71 stage 2, and as a
      `:live` destination it would otherwise be unreachable on mobile.
    * **Working** — the `:working` cluster minus anything the bar already
      carries (`IconRail.mobile_tab_keys/0`, so not Meetings).
    * **Admin** — gated on `root_user`; hidden entirely (DOM-absent, not
      `display: none`) for non-root users.

  Rung 5 (task 01a1557a-807f) owns the sheet's final row set and order.

  A profile row at the bottom exposes the user's name and the sign-out
  shortcut (unchanged from the previous revision).

  Surface choice: bottom sheet (vs full-screen drawer) per the
  ui-ux-pro-max `modal-motion` rule — the sheet animates up from the More
  tab's position for spatial continuity. `lg:hidden` ensures the desktop
  icon rail keeps doing its job at lg+ widths.

  Dismissal: Sheet's hook handles backdrop tap, Esc, and close button. The
  rows carry no `phx-click` (task 01a1557a-7a71 stage 5): a `navigate` link
  remounts the shell with the sheet closed, and a BARE event name on a
  live-navigation link is handed to `liveSocket.execJS`, which throws
  `TypeError: this[kind] is not a function` on every tap.
  Drag-to-dismiss is a future enhancement (out of scope).

  ## Examples

      <.more_sheet open={@more_sheet_open} current_user={@current_user} root_user={@root_user} />
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.Components.Sheet
  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias PlatformWeb.Components.IconRail

  attr(:open, :boolean, default: false, doc: "whether the sheet is shown")

  attr(:root_user, :boolean,
    default: false,
    doc: "when true, the Admin section renders; otherwise it is omitted from the DOM entirely"
  )

  attr(:access_scope, :any,
    default: nil,
    doc:
      "the actor's `%Platform.Access.Scope{}`; when set both sections are filtered through " <>
        "`Platform.Access.module_access?/3` and the Admin section renders only when " <>
        "`module_access?(scope, :admin)` holds (task 01a1386d-fb6e stage 1)"
  )

  attr(:inbox_unread_count, :integer,
    default: 0,
    doc: "the viewer's unread inbox count; above 0 renders a badge on the Inbox row"
  )

  attr(:current_user, :map,
    default: nil,
    doc: "current_user assign so the profile row can render the name + avatar"
  )

  def more_sheet(assigns) do
    root_user = Map.get(assigns, :root_user, false)
    scope = assigns[:access_scope]
    sections = IconRail.more_sheet_sections(scope, root_user)

    assigns =
      assigns
      |> assign(:inbox_destinations, sections.inbox)
      |> assign(:inbox_badge, IconRail.badge_text(assigns[:inbox_unread_count]))
      |> assign(:working_destinations, sections.working)
      |> assign(:admin_destinations, sections.admin)
      |> assign(:show_admin, sections.admin != [])

    ~H"""
    <.sheet
      id="more-sheet"
      open={@open}
      placement={:bottom}
      on_close="close_more_sheet"
      class="more-sheet lg:hidden"
    >
      <:title>More</:title>

      <nav class="more-sheet-list" aria-label="Long-tail navigation">
        <.link
          :for={dest <- @inbox_destinations}
          navigate={dest.path}
          class="more-sheet-row"
          data-destination={dest.key}
          aria-label={
            if @inbox_badge, do: "#{dest.label}, #{@inbox_unread_count} unread", else: dest.label
          }
        >
          <.icon name={dest.hero_icon} class="more-sheet-icon size-5" />
          <span>{dest.label}</span>
          <span
            :if={@inbox_badge}
            class="badge badge-error badge-sm ml-auto tabular-nums"
            data-role="more-sheet-inbox-badge"
          >
            {@inbox_badge}
          </span>
        </.link>

        <%!-- A guest's Scope admits no Working tile (task 01a1386d-fb6e
             stage 1): drop the empty section's label rather than render a
             heading over nothing. The legacy path always has Working tiles. --%>
        <p :if={@working_destinations != []} class="more-sheet-section-label">Working</p>

        <.link
          :for={dest <- @working_destinations}
          navigate={dest.path}
          class="more-sheet-row"
          data-destination={dest.key}
          aria-label={dest.label}
        >
          <.icon name={dest.hero_icon} class="more-sheet-icon size-5" />
          <span>{dest.label}</span>
        </.link>

        <%= if @show_admin do %>
          <div class="more-sheet-divider" aria-hidden="true"></div>
          <p class="more-sheet-section-label">Admin</p>

          <.link
            :for={dest <- @admin_destinations}
            navigate={dest.path}
            class="more-sheet-row"
            data-destination={dest.key}
            aria-label={dest.label}
          >
            <.icon name={dest.hero_icon} class="more-sheet-icon size-5" />
            <span>{dest.label}</span>
          </.link>
        <% end %>

        <div
          :if={@inbox_destinations != [] or @working_destinations != [] or @show_admin}
          class="more-sheet-divider"
          aria-hidden="true"
        >
        </div>

        <%!-- Profile row + sign-out. Renders only when current_user is present
             (mount-time, not session-derived). --%>
        <a
          :if={@current_user}
          href={~p"/auth/logout"}
          class="more-sheet-row more-sheet-profile"
        >
          <div class="more-sheet-avatar" aria-hidden="true">{user_initial(@current_user)}</div>
          <div class="more-sheet-profile-info">
            <div class="more-sheet-profile-name">{user_name(@current_user)}</div>
            <div class="more-sheet-profile-meta">Sign out</div>
          </div>
          <.icon name="hero-chevron-right" class="more-sheet-chevron size-4" />
        </a>
      </nav>
    </.sheet>
    """
  end

  defp user_initial(%{name: name}) when is_binary(name) and name != "" do
    name |> String.trim() |> String.first() |> String.upcase()
  end

  defp user_initial(_), do: "?"

  defp user_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_name(_), do: "Account"
end
