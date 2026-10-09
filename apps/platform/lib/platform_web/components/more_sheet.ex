defmodule PlatformWeb.Components.MoreSheet do
  @moduledoc """
  Mobile-only bottom sheet for the long-tail surfaces that don't get a
  dedicated tab in the bottom rail.

  Triggered by the `phx-click="open_more_sheet"` button on the More tab in
  `<.bottom_rail>`. The destination list is now data-driven from
  `PlatformWeb.Components.IconRail.destinations/1` — the same single source
  of truth that drives the desktop rail and the mobile bottom rail.

  Sections:
    * **Working** — Skills, Context, Memory, Prompts, Meetings (the
      `:working` cluster from `IconRail.destinations/1`).
    * **Admin** — gated on `root_user`; hidden entirely (DOM-absent, not
      `display: none`) for non-root users.

  A profile row at the bottom exposes the user's name and the sign-out
  shortcut (unchanged from the previous revision).

  Surface choice: bottom sheet (vs full-screen drawer) per the
  ui-ux-pro-max `modal-motion` rule — the sheet animates up from the More
  tab's position for spatial continuity. `lg:hidden` ensures the desktop
  icon rail keeps doing its job at lg+ widths.

  Dismissal: Sheet's hook handles backdrop tap, Esc, and close button.
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

  attr(:current_user, :map,
    default: nil,
    doc: "current_user assign so the profile row can render the name + avatar"
  )

  def more_sheet(assigns) do
    root_user = Map.get(assigns, :root_user, false)

    assigns =
      assigns
      |> assign(:working_destinations, working_destinations(root_user))
      |> assign(:admin_destinations, admin_destinations())

    ~H"""
    <.sheet
      id="more-sheet"
      open={@open}
      placement={:bottom}
      on_close="close_more_sheet"
      class="lg:hidden"
    >
      <:title>More</:title>

      <nav class="more-sheet-list" aria-label="Long-tail navigation">
        <p class="more-sheet-section-label">Working</p>

        <.link
          :for={dest <- @working_destinations}
          navigate={dest.path}
          class="more-sheet-row"
          data-destination={dest.key}
          aria-label={dest.label}
          phx-click="close_more_sheet"
        >
          <.icon name={dest.hero_icon} class="more-sheet-icon size-5" />
          <span>{dest.label}</span>
        </.link>

        <%= if @root_user do %>
          <div class="more-sheet-divider" aria-hidden="true"></div>
          <p class="more-sheet-section-label">Admin</p>

          <.link
            :for={dest <- @admin_destinations}
            navigate={dest.path}
            class="more-sheet-row"
            data-destination={dest.key}
            aria-label={dest.label}
            phx-click="close_more_sheet"
          >
            <.icon name={dest.hero_icon} class="more-sheet-icon size-5" />
            <span>{dest.label}</span>
          </.link>
        <% end %>

        <div class="more-sheet-divider" aria-hidden="true"></div>

        <%!-- Profile row + sign-out. Renders only when current_user is present
             (mount-time, not session-derived). --%>
        <a
          :if={@current_user}
          href="/oidc/logout"
          data-method="post"
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

  # Pass the actual root_user through so root_only? tiles (e.g. Prompts
  # as of 2026-05-20) are correctly hidden from members. Previously this
  # hardcoded `root_user: true` which leaked admin-only working-cluster
  # tiles to every user in the More sheet.
  defp working_destinations(root_user) do
    IconRail.destinations(root_user: root_user)
    |> Enum.filter(&(&1.cluster == :working))
  end

  defp admin_destinations do
    IconRail.destinations(root_user: true)
    |> Enum.filter(&(&1.cluster == :admin))
  end

  defp user_initial(%{name: name}) when is_binary(name) and name != "" do
    name |> String.trim() |> String.first() |> String.upcase()
  end

  defp user_initial(_), do: "?"

  defp user_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_name(_), do: "Account"
end
