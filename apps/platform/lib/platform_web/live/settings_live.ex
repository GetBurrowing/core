defmodule PlatformWeb.SettingsLive do
  @moduledoc """
  `/settings`: the viewer's own account (task 01a1557a-807f stage 1).

  The smallest real Settings screen, so the More sheet's Settings row has
  somewhere to go and nothing the sheet carried before (Admin, Prompts, Usage,
  sign out) becomes unreachable. Rung 19 (task 01a1557a-e538) extends this
  LiveView in place with Notifications, the sign-out confirm and the full
  admin list.

  ## Sections (master-mobile.html v3 `#settings`, rows that exist today)

    * Profile head: avatar, display name, email. Read-only.
    * Appearance: Theme. `phx-click="toggle_theme_picker"` is handled by
      `ShellLive`'s `:drawer_events` hook on every shell page, which opens the
      existing theme picker (the bottom sheet below lg, the header popover at
      lg). This page builds no picker of its own.
    * Account: Usage, Admin, Prompts, Sign out.

  ## Gating

  The page itself is ungated (`PlatformWeb.ModuleGate`'s `@ungated` says
  why). Each Account row that links to another page renders only when that
  page would mount for this actor, decided by `PlatformWeb.ModuleGate.mounts?/2`
  over the destination's LiveView: the same mapping and the same
  `Platform.Access.module_access?/3` call the mount gate itself runs, so the
  row and the page cannot disagree. Hidden rows are absent from the DOM, and a
  section left with no rows drops its label.
  """
  use PlatformWeb, :live_view

  alias PlatformWeb.ModuleGate

  # Account rows that open another page, in display order. Each carries the
  # LiveView its path mounts, which is what the gate is asked about.
  @gated_rows [
    %{
      role: "settings-usage",
      label: "Usage",
      path: "/control/usage",
      view: PlatformWeb.UsageLive
    },
    %{role: "settings-admin", label: "Admin", path: "/admin", view: PlatformWeb.AdminLive},
    %{
      role: "settings-prompts",
      label: "Prompts",
      path: "/admin/prompts",
      view: PlatformWeb.AdminPromptsLive
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:access_scope]

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:account_rows, visible_rows(scope))}
  end

  @doc false
  # Public for the test that checks each row against a real mount.
  def visible_rows(scope), do: Enum.filter(@gated_rows, &ModuleGate.mounts?(scope, &1.view))

  @impl true
  def render(assigns) do
    record = assigns[:current_user_record] || %{}

    assigns =
      assigns
      |> assign(:display_name, assigns[:current_user] || Map.get(record, :name) || "Account")
      |> assign(:email, Map.get(record, :email))
      |> assign(:avatar_url, Map.get(record, :avatar_url))
      |> assign(:avatar_seed, Map.get(record, :id) || assigns[:current_user])

    ~H"""
    <div
      id="settings"
      class="h-full overflow-y-auto overscroll-contain bg-base-100 text-base-content pb-4 clears-tab-bar"
    >
      <div class="mx-auto w-full max-w-lg">
        <%!-- The shell's top bar already names the page (`active_module`),
             so the heading is for assistive tech only: one visible title. --%>
        <h1 class="sr-only">Settings</h1>

        <div data-role="settings-profile" class="flex items-center gap-3 px-4 pt-5 pb-3">
          <.human_avatar name={@display_name} avatar_url={@avatar_url} seed={@avatar_seed} size="lg" />
          <div class="min-w-0">
            <p class="truncate text-base font-medium text-base-content">{@display_name}</p>
            <p
              :if={is_binary(@email) and @email != @display_name}
              class="truncate text-sm text-subtle"
            >
              {@email}
            </p>
          </div>
        </div>

        <p class="px-4 pt-4 pb-1 text-xs text-subtle">Appearance</p>
        <button
          type="button"
          data-role="settings-theme"
          phx-click="toggle_theme_picker"
          class={row_class()}
        >
          <span class="min-w-0 flex-1 truncate text-left">Theme</span>
          <span class="hero-chevron-right size-4 shrink-0 text-subtle" aria-hidden="true"></span>
        </button>

        <p class="px-4 pt-4 pb-1 text-xs text-subtle">Account</p>
        <.link
          :for={row <- @account_rows}
          navigate={row.path}
          data-role={row.role}
          class={row_class()}
        >
          <span class="min-w-0 flex-1 truncate">{row.label}</span>
          <span class="hero-chevron-right size-4 shrink-0 text-subtle" aria-hidden="true"></span>
        </.link>
        <.link href={~p"/auth/logout"} data-role="settings-sign-out" class={row_class()}>
          <span class="min-w-0 flex-1 truncate">Sign out</span>
          <span class="hero-chevron-right size-4 shrink-0 text-subtle" aria-hidden="true"></span>
        </.link>
      </div>
    </div>
    """
  end

  defp row_class do
    "flex w-full min-h-12 items-center gap-3 border-b border-edge px-4 text-[15px] " <>
      "font-normal text-base-content hover:bg-base-200 active:bg-base-200 focus-visible-ring"
  end
end
