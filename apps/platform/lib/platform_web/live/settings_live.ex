defmodule PlatformWeb.SettingsLive do
  @moduledoc """
  `/settings`: the viewer's own account (task 01a1557a-807f stage 1, re-skinned
  to the masters by task 01a1557a-e538 stage 3: master-mobile.html v3
  :609-627).

  ## Sections

    * Header: a back button (`open_more_sheet`, handled by `ShellLive` on every
      shell page, so it reopens the More sheet this page was reached from) and
      the one `<h1>`, visible below lg and `lg:sr-only` at lg.
    * Profile head: xl avatar, display name and email. Read-only: `name` is
      rewritten from OIDC at every sign-in and there is no status model, so an
      editor here would lie.
    * Appearance: Theme. `phx-click="toggle_theme_picker"` opens the existing
      picker (ShellLive's `:drawer_events` hook). The row's value names the
      stored preset and mode, read from `:current_user_record`, which
      ShellLive's `set_theme` replaces, so the value follows a change without
      a reload.
    * Account: Notifications, Mask names, Usage, Admin. Then Sign out, last.

  ## Notifications (task 01a1557a-e538 stage 4)

  A row that opens a sheet: the "Push on this device" switch, whose state,
  line and action follow the device's push state (`push_state/1`, from the
  shell assigns the PushSubscribe hook keeps), then a `radiogroup` of the
  three levels (`Accounts.notification_level/1`), saved on change through
  `Accounts.put_notification_level/2`, with only the selected level's helper.
  Turning push off is web push only and per browser: `disable_notifications`
  makes the hook unsubscribe and set an opt-out, and ShellLive forgets that
  endpoint for this user with `Platform.Push.unsubscribe_for_user/2`. On the
  native apps the switch is display-only when on.

  ## Mask names

  A `role="switch"` button. Its state is `Accounts.mask_names?/1`, the same
  per-user, 12-hour preference ChatLive and TasksLive seed from on mount.
  `set_mask_names` writes it through `Accounts.put_mask_names/2`, the ONE
  write path for that key. While it is on, the helper also says when it ends,
  in the viewer's own zone (the socket's `timezone` connect param), for
  example "On until 9:41 pm".

  ## Gating

  The page itself is ungated (`PlatformWeb.ModuleGate`'s `@ungated` says
  why). Usage and every Admin sheet row render only when
  `PlatformWeb.ModuleGate.mounts?/2` says the destination's LiveView would
  mount for this actor: the same mapping and the same
  `Platform.Access.module_access?/3` call the mount gate runs, so the row and
  the page cannot disagree (the one pinned exception is 01a15be9, a
  project-scoped prompts.manage holder). Users also needs the sign-in admin
  switch (`Platform.SignInAdmin.Config.enabled?/0`), without which its route
  answers 404. The Admin row is absent when no sheet row is visible.

  ## Sign out

  The row is a button that opens a confirm sheet; it never signs out by
  itself. The sheet's confirm is a plain GET link to `/auth/logout` (the only
  logout route; there is no DELETE route), so it carries no phx-click.

  ## Sheet state

  One `@sheet` assign (`nil | :notifications | :admin | :sign_out`), set to
  nil in `mount/3` unless `?sheet=notifications` or `?sheet=admin` names one;
  `?sheet=appearance` opens the theme picker instead. Any other value is
  ignored.
  Every link here carries NO phx-click (a bare-string phx-click on a
  `navigate` link throws in LiveView, and a `JS.push` on a redirect link never
  arrives), so navigating away remounts and that is what closes a sheet.
  """
  use PlatformWeb, :live_view

  import PlatformWeb.Components.Sheet

  alias Platform.Accounts
  alias Platform.Accounts.ThemePreference
  alias PlatformWeb.Components.NotificationState
  alias PlatformWeb.MeetingLive.CalendarWindow
  alias PlatformWeb.ModuleGate

  @usage_row %{
    role: "settings-usage",
    label: "Usage",
    path: "/control/usage",
    view: PlatformWeb.UsageLive
  }

  # The Admin sheet's rows, alphabetical by label. Labels are the /admin hub's
  # tile titles in sentence case, so the hub and Settings agree. `:sign_in`
  # marks the row that also needs the sign-in admin switch. `:desktop_only`
  # marks a row hidden below lg (the theme editor is desktop only).
  @admin_rows [
    %{label: "Access", path: "/access", view: PlatformWeb.AccessLive},
    %{
      label: "Agent federation",
      path: "/admin/federation",
      view: PlatformWeb.AdminFederationLive
    },
    %{label: "Branding", path: "/admin/branding", view: PlatformWeb.AdminBrandingLive},
    %{
      label: "External logins",
      path: "/admin/external-logins",
      view: PlatformWeb.ExternalRecoveryLive
    },
    %{label: "Insights", path: "/admin/insights", view: PlatformWeb.AdminInsightsLive},
    %{label: "Orgs", path: "/admin/orgs", view: PlatformWeb.AdminOrgsLive},
    %{label: "Pipeline", path: "/tasks/pipeline", view: PlatformWeb.PipelineLive},
    %{label: "Prompts", path: "/admin/prompts", view: PlatformWeb.AdminPromptsLive},
    %{label: "Prototypes", path: "/admin/prototypes", view: PlatformWeb.AdminPrototypesLive},
    %{label: "Recovery", path: "/admin/recovery", view: PlatformWeb.RecoveryLive},
    %{
      label: "Themes",
      path: "/admin/themes",
      view: PlatformWeb.AdminThemesLive,
      desktop_only: true
    },
    %{label: "User access", path: "/admin/users", view: PlatformWeb.UserAccessLive},
    %{
      label: "Users",
      path: "/admin/sign-in-users",
      view: PlatformWeb.AdminSignInUsersLive,
      sign_in: true
    },
    %{label: "Vault", path: "/admin/vault", view: PlatformWeb.AdminVaultLive}
  ]

  @impl true
  def mount(params, _session, socket) do
    scope = socket.assigns[:access_scope]

    zone =
      if connected?(socket),
        do: CalendarWindow.resolve_time_zone((get_connect_params(socket) || %{})["timezone"])

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:app_name, Platform.Branding.app_name())
     |> assign(:sheet, nil)
     |> assign(:time_zone, zone)
     |> assign(:mask_error, nil)
     |> assign(:level_error, nil)
     |> assign(:mask_names?, Accounts.mask_names?(socket.assigns[:current_user_record]))
     |> assign(:usage_row, if(ModuleGate.mounts?(scope, @usage_row.view), do: @usage_row))
     |> assign(:admin_rows, visible_admin_rows(scope))
     |> open_from_params(params)}
  end

  # `?sheet=` (the command palette's Settings items, Burrow redesign 23):
  # opens what the matching row's click opens. Anything else is ignored.
  defp open_from_params(socket, %{"sheet" => "notifications"}),
    do: assign(socket, :sheet, :notifications)

  defp open_from_params(socket, %{"sheet" => "admin"}), do: assign(socket, :sheet, :admin)

  defp open_from_params(socket, %{"sheet" => "appearance"}),
    do: assign(socket, :theme_picker_open, true)

  defp open_from_params(socket, _params), do: socket

  @doc false
  # Public for the test that checks each row against a real mount.
  def admin_rows, do: @admin_rows

  @doc false
  # Public for the test that checks each row against a real mount.
  def visible_admin_rows(scope) do
    sign_in? = Platform.SignInAdmin.Config.enabled?()

    Enum.filter(@admin_rows, fn row ->
      ModuleGate.mounts?(scope, row.view) and (not Map.get(row, :sign_in, false) or sign_in?)
    end)
  end

  @doc """
  The Admin row's value: the first three visible labels, lower-case, joined
  by ", " (prototype :625, 'prompts, orgs, branding').
  """
  @spec admin_summary([map()]) :: String.t()
  def admin_summary(rows),
    do: rows |> Enum.take(3) |> Enum.map_join(", ", &String.downcase(&1.label))

  @doc """
  The Theme row's value, '{preset name} · {mode}', for example
  'Burrow sand · Light'. An org preset (task 01a1557a-fe9b stage 3) shows
  that theme's name from `org_themes`, the published themes the person can
  see: 'Ocean · Dark'.
  """
  @spec theme_value(map(), [Platform.Theming.OrgTheme.t()]) :: String.t()
  def theme_value(%{"preset" => preset, "mode" => mode}, org_themes \\ []) do
    rows =
      ThemePreference.presets() ++
        Enum.map(org_themes, &%{id: Platform.Theming.OrgTheme.preset_id(&1), name: &1.name})

    name = Enum.find_value(rows, preset, fn p -> p.id == preset && p.name end)

    "#{name} · #{String.capitalize(mode)}"
  end

  # The stored preference read against the same visible set the picker
  # shows (ShellLive's `:org_themes`), so the row and the picker agree.
  defp theme_row_value(assigns) do
    org_themes = assigns[:org_themes] || []
    visible = Enum.map(org_themes, &Platform.Theming.OrgTheme.preset_id/1)

    assigns[:current_user_record]
    |> Accounts.theme_preference(visible)
    |> theme_value(org_themes)
  end

  @doc """
  When the mask ends, in the viewer's zone: "On until 9:41 pm". Without a
  known zone the time is UTC and says so. nil when masking is off at `now`.
  """
  @spec mask_until_label(Accounts.User.t() | nil, String.t() | nil, DateTime.t()) ::
          String.t() | nil
  def mask_until_label(user, zone, now \\ DateTime.utc_now()) do
    with true <- Accounts.mask_names?(user, now),
         %DateTime{} = until <- Accounts.mask_names_until(user) do
      "On until " <> PlatformWeb.MaskNamesLabel.clock(until, zone)
    else
      _ -> nil
    end
  end

  @impl true
  def handle_event("set_mask_names", params, socket) do
    masked? = params["masked"] in ["true", true]
    # The shell's one web writer refreshes `:current_user_record` on success
    # and leaves it alone on error, so the stored state is read back from it.
    # If it now reads what was asked for, show it; if not, the write failed.
    socket = PlatformWeb.ShellLive.put_mask_names(socket, masked?)
    stored? = Accounts.mask_names?(socket.assigns[:current_user_record])

    if stored? == masked? do
      {:noreply, socket |> assign(:mask_names?, stored?) |> assign(:mask_error, nil)}
    else
      # Revert: the switch keeps showing what is stored.
      {:noreply, assign(socket, :mask_error, "Couldn't save. Your setting hasn't changed.")}
    end
  end

  def handle_event("set_notification_level", %{"level" => level}, socket) do
    case Accounts.put_notification_level(socket.assigns[:current_user_record], level) do
      {:ok, %Accounts.User{} = updated} ->
        {:noreply, socket |> assign(:current_user_record, updated) |> assign(:level_error, nil)}

      {:error, _reason} ->
        # Revert: the radios keep showing what is stored.
        {:noreply, assign(socket, :level_error, "Couldn't save. Your setting hasn't changed.")}
    end
  end

  def handle_event("open_notifications_sheet", _params, socket),
    do: {:noreply, assign(socket, :sheet, :notifications)}

  def handle_event("open_admin_sheet", _params, socket),
    do: {:noreply, assign(socket, :sheet, :admin)}

  def handle_event("open_sign_out_sheet", _params, socket),
    do: {:noreply, assign(socket, :sheet, :sign_out)}

  def handle_event("close_settings_sheet", _params, socket),
    do: {:noreply, assign(socket, :sheet, nil)}

  @impl true
  def render(assigns) do
    record = assigns[:current_user_record] || %{}

    assigns =
      assigns
      |> assign(:display_name, assigns[:current_user] || Map.get(record, :name) || "Account")
      |> assign(:email, Map.get(record, :email))
      |> assign(:avatar_url, Map.get(record, :avatar_url))
      |> assign(:avatar_seed, Map.get(record, :id) || assigns[:current_user])
      |> assign(:theme_value, theme_row_value(assigns))
      |> assign(:level, Accounts.notification_level(assigns[:current_user_record]))
      |> assign(:push_state, push_state(assigns))
      |> assign(
        :mask_until,
        if(assigns.mask_names?,
          do: mask_until_label(assigns[:current_user_record], assigns.time_zone)
        )
      )

    ~H"""
    <div
      id="settings"
      class="h-full overflow-y-auto overscroll-contain bg-base-200 text-base-content pb-4 clears-tab-bar"
    >
      <div class="mx-auto w-full max-w-lg">
        <header class="flex h-[52px] items-center gap-2.5 px-4">
          <button
            type="button"
            phx-click="open_more_sheet"
            aria-label="Back to More"
            data-role="settings-back"
            class="-ml-2 flex size-11 shrink-0 items-center justify-center rounded-full active:bg-base-100 focus-visible-ring lg:hidden"
          >
            <span class="hero-chevron-left size-5 text-subtle" aria-hidden="true"></span>
          </button>
          <h1 class="min-w-0 flex-1 truncate text-[17px] font-semibold text-base-content lg:sr-only">
            Settings
          </h1>
        </header>

        <div
          data-role="settings-profile"
          class="flex flex-col items-center gap-2 px-4 pt-6 pb-2 text-center"
        >
          <.human_avatar name={@display_name} avatar_url={@avatar_url} seed={@avatar_seed} size="xl" />
          <p class="max-w-full truncate text-lg font-semibold text-base-content">{@display_name}</p>
          <p
            :if={is_binary(@email) and @email != @display_name}
            class="max-w-full truncate text-[13px] text-subtle"
          >
            {@email}
          </p>
        </div>

        <p class={section_label_class()}>Appearance</p>
        <button
          type="button"
          data-role="settings-theme"
          phx-click="toggle_theme_picker"
          class={row_class()}
        >
          <span class="shrink-0">Theme</span>
          <span class="flex min-w-0 items-center gap-1">
            <span data-role="settings-theme-value" class={value_class()}>{@theme_value}</span>
            <span class="hero-chevron-right size-4 shrink-0 text-subtle" aria-hidden="true"></span>
          </span>
        </button>

        <p class={section_label_class()}>Account</p>
        <button
          type="button"
          phx-click="open_notifications_sheet"
          data-role="settings-notifications"
          class={row_class()}
        >
          <span class="shrink-0">Notifications</span>
          <span class="flex min-w-0 items-center gap-1">
            <span data-role="settings-notifications-value" class={value_class()}>
              {notifications_value(@level, @push_state)}
            </span>
            <span class="hero-chevron-right size-4 shrink-0 text-subtle" aria-hidden="true"></span>
          </span>
        </button>
        <button
          type="button"
          role="switch"
          aria-checked={to_string(@mask_names?)}
          phx-click="set_mask_names"
          phx-value-masked={to_string(!@mask_names?)}
          data-role="settings-mask-names"
          class={row_class()}
        >
          <span class="min-w-0">
            <span class="block">Mask names</span>
            <span class="block text-xs text-subtle">
              Hides org names in Chat and Tasks, for screen sharing. Turns off after 12 hours.
            </span>
            <span :if={@mask_until} data-role="settings-mask-until" class="block text-xs text-subtle">
              {@mask_until}
            </span>
          </span>
          <span class={track_class(@mask_names?)} aria-hidden="true">
            <span class={knob_class(@mask_names?)}></span>
          </span>
        </button>
        <p
          :if={@mask_error}
          data-role="settings-mask-error"
          class="px-[18px] pb-2 text-xs text-subtle"
        >
          {@mask_error}
        </p>

        <.link
          :if={@usage_row}
          navigate={@usage_row.path}
          data-role={@usage_row.role}
          class={row_class()}
        >
          <span class="shrink-0">{@usage_row.label}</span>
          <span class="hero-chevron-right size-4 shrink-0 text-subtle" aria-hidden="true"></span>
        </.link>

        <button
          :if={@admin_rows != []}
          type="button"
          phx-click="open_admin_sheet"
          data-role="settings-admin"
          class={row_class()}
        >
          <span class="shrink-0">Admin</span>
          <span class="flex min-w-0 items-center gap-1">
            <span class={value_class()}>{admin_summary(@admin_rows)}</span>
            <span class="hero-chevron-right size-4 shrink-0 text-subtle" aria-hidden="true"></span>
          </span>
        </button>

        <button
          type="button"
          phx-click="open_sign_out_sheet"
          data-role="settings-sign-out"
          class={["mt-4", row_class()]}
        >
          <span class="shrink-0">Sign out</span>
        </button>
      </div>

      <.sheet
        id="settings-notifications-sheet"
        open={@sheet == :notifications}
        placement={:bottom}
        on_close="close_settings_sheet"
        swipe_dismiss
        handle_close
      >
        <:title>Notifications</:title>
        <p class={sheet_title_class()} aria-hidden="true">Notifications</p>
        <.push_row :if={@push_state != :absent} state={@push_state} user_agent={@user_agent} />

        <p class={[section_label_class(), "pt-4"]} id="settings-level-label">Notify me about</p>
        <div role="radiogroup" aria-labelledby="settings-level-label" data-role="settings-levels">
          <button
            :for={opt <- levels()}
            type="button"
            role="radio"
            aria-checked={to_string(opt.value == @level)}
            phx-click="set_notification_level"
            phx-value-level={opt.value}
            data-role="settings-level"
            data-level={opt.value}
            class={sheet_row_class()}
          >
            <span class="min-w-0">
              <span class="block">{opt.label}</span>
              <span
                :if={opt.value == @level}
                data-role="settings-level-helper"
                class="block text-xs text-subtle"
              >
                {opt.helper}
              </span>
            </span>
            <span class={radio_class(opt.value == @level)} aria-hidden="true">
              <span :if={opt.value == @level} class="size-2.5 rounded-full bg-primary"></span>
            </span>
          </button>
        </div>
        <p
          :if={@level_error}
          data-role="settings-level-error"
          class="px-[18px] pb-2 text-xs text-subtle"
        >
          {@level_error}
        </p>
      </.sheet>

      <.sheet
        id="settings-admin-sheet"
        open={@sheet == :admin}
        placement={:bottom}
        on_close="close_settings_sheet"
        swipe_dismiss
        handle_close
      >
        <:title>Admin</:title>
        <p class={sheet_title_class()} aria-hidden="true">Admin</p>
        <nav aria-label="Admin pages">
          <.link
            :for={row <- @admin_rows}
            navigate={row.path}
            data-role="settings-admin-row"
            data-path={row.path}
            class={[sheet_row_class(), Map.get(row, :desktop_only, false) && "max-lg:hidden"]}
          >
            <span class="min-w-0 truncate">{row.label}</span>
            <span class="hero-chevron-right size-4 shrink-0 text-subtle" aria-hidden="true"></span>
          </.link>
        </nav>
      </.sheet>

      <.sheet
        id="settings-sign-out-sheet"
        open={@sheet == :sign_out}
        placement={:bottom}
        on_close="close_settings_sheet"
        swipe_dismiss
        handle_close
      >
        <:title>Sign out of {@app_name} on this device?</:title>
        <p class={sheet_title_class()} aria-hidden="true" data-role="settings-sign-out-title">
          Sign out of {@app_name} on this device?
        </p>
        <.link
          href={~p"/auth/logout"}
          data-role="settings-sign-out-confirm"
          class={[sheet_row_class(), "min-h-[52px] font-semibold"]}
        >
          Sign out
        </.link>
        <button
          type="button"
          phx-click="close_settings_sheet"
          data-role="settings-sign-out-cancel"
          class={[sheet_row_class(), "min-h-[52px]"]}
        >
          Cancel
        </button>
      </.sheet>
    </div>
    """
  end

  @levels [
    %{
      value: "all",
      label: "All messages",
      word: "all messages",
      helper: "A push for every message in your spaces while you're not in that space."
    },
    %{
      value: "mentions",
      label: "Mentions and direct messages",
      word: "mentions and DMs",
      helper: "A push when someone mentions you, uses @here, or messages you directly."
    },
    %{
      value: "direct",
      label: "Only direct mentions",
      word: "direct mentions only",
      helper:
        "You'll still get a push when someone mentions you directly. " <>
          "Calls still ring; everything else waits in your Inbox."
    }
  ]

  @doc false
  def levels, do: @levels

  @doc """
  The device's push state for the "Push on this device" row, from the shell
  assigns the PushSubscribe hook keeps (`:push_permission`,
  `:push_auto_denied`, `:push_native_platform`, `:push_registration_failed`,
  `:push_opted_out`). `:absent` means the row is not rendered (unknown or
  unsupported).
  """
  @spec push_state(map()) ::
          :absent
          | :prompt
          | :on
          | :opted_out
          | :blocked
          | :auto_denied
          | :subscribe_failed
          | :no_participant
          | :android_off
          | :native_on
  def push_state(assigns) do
    permission = assigns[:push_permission]
    native = assigns[:push_native_platform]
    failed = assigns[:push_registration_failed]

    cond do
      permission in [nil, "unknown", "unsupported"] -> :absent
      native == "android" and permission in ["prompt", "denied"] -> :android_off
      permission == "granted" and failed == :subscribe_failed -> :subscribe_failed
      permission == "granted" and failed == :no_participant -> :no_participant
      permission == "granted" and native in ["android", "ios"] -> :native_on
      permission == "granted" and assigns[:push_opted_out] == true -> :opted_out
      permission == "granted" -> :on
      permission == "denied" and assigns[:push_auto_denied] == true -> :auto_denied
      permission == "denied" -> :blocked
      true -> :prompt
    end
  end

  @doc "The Notifications row's value: '{level} · push {on | off | blocked | failed}'."
  @spec notifications_value(String.t(), atom()) :: String.t()
  def notifications_value(level, push_state) do
    word = Enum.find_value(@levels, "mentions and DMs", &(&1.value == level && &1.word))

    case push_word(push_state) do
      nil -> word
      push -> "#{word} · push #{push}"
    end
  end

  defp push_word(:absent), do: nil
  defp push_word(state) when state in [:on, :native_on], do: "on"
  defp push_word(state) when state in [:blocked, :auto_denied], do: "blocked"
  defp push_word(state) when state in [:subscribe_failed, :no_participant], do: "failed"
  defp push_word(_off), do: "off"

  # Rows sit on the base-200 ground; a pressed row is base-100. No dividers
  # and no hover (the phone list ruling).
  defp row_class do
    "flex w-full min-h-[52px] items-center justify-between gap-3 px-[18px] py-3.5 " <>
      "text-left text-[15px] text-base-content active:bg-base-100 focus-visible-ring"
  end

  # Sheet rows sit on the base-100 sheet; a pressed row is base-200.
  defp sheet_row_class do
    "flex w-full min-h-11 items-center justify-between gap-3 px-[18px] py-3 " <>
      "text-left text-[15px] text-base-content active:bg-base-200 focus-visible-ring"
  end

  # `handle_close` makes the sheet's handle a real Close button with
  # `touch-action: none`, so a touch swipe-down on it closes the sheet (a bare
  # `.sheet-handle` div is `touch-action: auto`: the browser claims the pan
  # and sends pointercancel). It also hides the title visually, so each sheet
  # draws a visible, aria-hidden copy; the accessible title stays in `:title`.
  defp sheet_title_class,
    do: "px-[18px] pt-1 pb-2 text-[17px] font-semibold text-base-content"

  defp value_class, do: "min-w-0 truncate text-[13px] text-subtle"

  defp section_label_class,
    do: "px-[18px] pt-3.5 pb-1 text-xs font-semibold uppercase tracking-[.08em] text-subtle"

  defp radio_class(selected?) do
    [
      "flex size-5 shrink-0 items-center justify-center rounded-full border-2",
      if(selected?, do: "border-primary", else: "border-subtle")
    ]
  end

  # "Push on this device": one switch whose state, line and action follow the
  # device's push state (see `push_state/1` and the stage 4 state table). The
  # shared sentences come from `NotificationState`, so /inbox and Settings
  # render one source. The subscribe-failed line was the one error-coloured
  # line; task 01a1557a-e538 stage 5's painted guard measured error on
  # base-100 under 4.5:1 in five variants (burrow light 3.74), so by the
  # stage's named fallback it is base-content: its words carry the meaning.
  attr :state, :atom, required: true
  attr :user_agent, :string, default: nil

  defp push_row(assigns) do
    assigns =
      assigns
      |> assign(:on?, assigns.state in [:on, :native_on])
      |> assign(:event, push_action(assigns.state))
      |> assign(:browser, NotificationState.browser_family(assigns.user_agent))

    ~H"""
    <div data-role="settings-push" data-state={Atom.to_string(@state)}>
      <button
        type="button"
        role="switch"
        aria-checked={to_string(@on?)}
        aria-disabled={if(is_nil(@event), do: "true")}
        disabled={@state == :auto_denied}
        phx-click={@event}
        data-role="settings-push-switch"
        class={sheet_row_class()}
      >
        <span class="min-w-0">Push on this device</span>
        <span class={track_class(@on?)} aria-hidden="true">
          <span class={knob_class(@on?)}></span>
        </span>
      </button>
      <div :if={@state not in [:on, :prompt, :opted_out]} class="px-[18px] pb-3">
        <p :if={@state == :blocked} data-role="settings-push-line" class="text-xs text-subtle">
          Blocked in your browser settings.
        </p>
        <details
          :if={@state == :blocked}
          data-role="settings-push-how"
          class="mt-1 text-xs text-subtle"
        >
          <summary class="focus-visible-ring">How to allow</summary>
          <p class="mt-1">{NotificationState.denied_instruction(@browser)}</p>
        </details>
        <p :if={@state == :auto_denied} data-role="settings-push-line" class="text-xs text-subtle">
          {copy(NotificationState.auto_denied_copy())}
        </p>
        <p
          :if={@state == :no_participant}
          data-role="settings-push-line"
          class="text-xs text-subtle"
        >
          {copy(NotificationState.no_participant_copy())}
        </p>
        <p :if={@state == :android_off} data-role="settings-push-line" class="text-xs text-subtle">
          {copy(NotificationState.android_off_copy())}
        </p>
        <p :if={@state == :native_on} data-role="settings-push-line" class="text-xs text-subtle">
          Turn off in your phone's settings.
        </p>
        <div :if={@state == :subscribe_failed} class="flex items-center justify-between gap-3">
          <p data-role="settings-push-line" class="text-xs text-error">
            Couldn't turn on notifications on this device.
          </p>
          <button
            type="button"
            phx-click="enable_notifications"
            data-role="settings-push-retry"
            class="shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold text-base-content active:bg-base-200 focus-visible-ring"
          >
            Try again
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp copy({headline, detail}), do: headline <> " " <> detail

  defp push_action(state) when state in [:prompt, :opted_out, :android_off, :subscribe_failed],
    do: "enable_notifications"

  defp push_action(:on), do: "disable_notifications"
  defp push_action(_state), do: nil

  # Prototype `.switch` :288-291: a 44x26 track, a 20px knob with a 3px inset.
  defp track_class(on?) do
    [
      "relative inline-flex h-[26px] w-11 shrink-0 rounded-full transition-colors motion-reduce:transition-none",
      if(on?, do: "bg-primary", else: "bg-subtle")
    ]
  end

  defp knob_class(on?) do
    [
      "absolute top-[3px] left-[3px] size-5 rounded-full transition-transform motion-reduce:transition-none",
      if(on?, do: "translate-x-[18px] bg-primary-content", else: "bg-base-100")
    ]
  end
end
