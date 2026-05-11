defmodule PlatformWeb.Components.MoreSheet do
  @moduledoc """
  Mobile-only bottom sheet for the long-tail surfaces that don't get a
  dedicated tab in the bottom nav (originally task 019e1322 Stage 2;
  refactored under task 019e0d4b Stage 2 to use the generic `<.sheet>`
  component instead of duplicating its chrome).

  Triggered by the `phx-click="open_more_sheet"` on the More tab in
  `<.bottom_nav>`. Lists Skills / Changelog / Agent Resources / Org
  Context / Usage / Admin·Prompts / Admin·Federation in two sections,
  plus a profile row at the bottom that exposes Dev Alice's name and
  the sign-out shortcut.

  Surface choice: bottom sheet (vs full-screen drawer) per the
  ui-ux-pro-max `modal-motion` rule — the sheet animates up from the
  More tab's position for spatial continuity. `lg:hidden` ensures the
  desktop left rail keeps doing its job at lg+ widths.

  Dismissal: Sheet's hook handles backdrop tap, Esc, and close button.
  Drag-to-dismiss is a future enhancement (out of scope).

  ## Examples

      <.more_sheet open={@more_sheet_open} current_user={@current_user} />
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.Components.Sheet

  attr :open, :boolean, default: false, doc: "whether the sheet is shown"

  attr :current_user, :map,
    default: nil,
    doc: "current_user assign so the profile row can render the name + avatar"

  def more_sheet(assigns) do
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
        <p class="more-sheet-section-label">Workspace</p>

        <.link navigate={~p"/skills"} class="more-sheet-row" phx-click="close_more_sheet">
          <svg
            class="more-sheet-icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2zM22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z" />
          </svg>
          <span>Skills</span>
        </.link>

        <.link navigate={~p"/changelog"} class="more-sheet-row" phx-click="close_more_sheet">
          <svg
            class="more-sheet-icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" /><path d="M14 2v6h6M16 13H8M16 17H8M10 9H8" />
          </svg>
          <span>Changelog</span>
        </.link>

        <.link navigate={~p"/control"} class="more-sheet-row" phx-click="close_more_sheet">
          <svg
            class="more-sheet-icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
          </svg>
          <span>Agent Resources</span>
        </.link>

        <.link navigate={~p"/org-context"} class="more-sheet-row" phx-click="close_more_sheet">
          <svg
            class="more-sheet-icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M3 21h18M5 21V8M19 21V8M9 8V5l3-2 3 2v3M9 13h.01M15 13h.01M9 17h.01M15 17h.01" />
          </svg>
          <span>Org Context</span>
        </.link>

        <.link navigate={~p"/control/usage"} class="more-sheet-row" phx-click="close_more_sheet">
          <svg
            class="more-sheet-icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M3 3v18h18M18 17l-5-5-4 4-4-4" />
          </svg>
          <span>Usage</span>
        </.link>

        <div class="more-sheet-divider" aria-hidden="true"></div>
        <p class="more-sheet-section-label">Admin</p>

        <.link navigate={~p"/admin/prompts"} class="more-sheet-row" phx-click="close_more_sheet">
          <svg
            class="more-sheet-icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z" />
          </svg>
          <span>Prompts</span>
        </.link>

        <.link navigate={~p"/admin/federation"} class="more-sheet-row" phx-click="close_more_sheet">
          <svg
            class="more-sheet-icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <circle cx="5" cy="12" r="3" /><circle cx="19" cy="12" r="3" /><circle
              cx="12"
              cy="5"
              r="3"
            /><circle cx="12" cy="19" r="3" />
          </svg>
          <span>Federation</span>
        </.link>

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
          <svg
            class="more-sheet-chevron"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            aria-hidden="true"
          >
            <path d="m9 18 6-6-6-6" />
          </svg>
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
