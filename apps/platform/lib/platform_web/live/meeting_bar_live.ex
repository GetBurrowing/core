defmodule PlatformWeb.MeetingBarLive do
  @moduledoc """
  LiveComponent rendering the in-call top bar (task 01a1e82a stage 1; it
  replaced the bottom mini-bar ribbon).

  Displayed at the top of the shell's main column whenever the current user
  is in an active meeting, on every page except the call room. Manages local UI state for mic/camera toggles and the meeting
  duration timer. The bar persists across page navigations because it
  lives in the shell layout, not inside any specific LiveView.

  ## Required assigns (from parent)

    * `:meeting_active` — boolean, whether to show the bar
    * `:meeting_space_id` — the space ID of the active meeting
    * `:meeting_space_name` — display name of the meeting space
    * `:meeting_space_slug` — URL slug for the meeting space
    * `:meeting_slug` — slug of the active `%Platform.Meetings.Meeting{}` row
      (used by the Return-to-call deep link to `/meetings/<slug>`); may be nil
      if the meeting row hasn't been persisted yet, in which case the bar
      falls back to the chat surface via `space_slug`
    * `:meeting_started_at` — `DateTime` the MEETING started (its row's
      `started_at`; task 01a1e82a remediation), falling back to the join time
      for an ad-hoc room with no meeting row
    * `:in_call_room` — boolean, true only on `/meetings/<meeting_slug>`
      (computed once, by `PlatformWeb.MeetingBarPresence.in_call_room?/2`)
    * `:meeting_roster` — up to four `%{id, name, initials}` faces
    * `:meeting_here_count` — how many participants are in the call
    * `:meeting_can_end` — the viewer hosts the meeting, so the desktop bar
      offers "End for everyone" next to Leave (the server re-checks)

  ## The "Sound and video" panel (task 01a1f4c5 stage 4)

  At `sm` and up the Mic and Cam chips are split buttons: a caret
  (`data-bar-mic-devices` / `data-bar-camera-devices`) opens the shared
  `DevicePanel.device_panel/1` popover under the bar, on that section. Below
  `sm` the bar is the phone strip, whose whole job is to return to the call
  (where the room's own control is), so it gets NO device control.

  The panel is a FUNCTION-COMPONENT child rendered inside this
  LiveComponent's template (`devices/1` below), and its markup carries no
  `phx-target`. That is deliberate and safe: the `MeetingDevicePanel` hook
  pushes no server events at all, and device ids and labels never reach the
  server. Do not "fix" it into a `phx-target={@myself}` or a LiveComponent
  of its own: there is no event for it to target, and a hook's `pushEvent`
  ignores `phx-target` anyway (see `CallShell`'s moduledoc).

  The device-switched strap renders under the bar
  (`meeting-bar-device-notice`), because a person on another page is the one
  most likely to miss a fallback; it gives way to a call surface's own strap
  on the same page (`data-devices-notice="when-alone"`).

  Never in the iOS app: the carets and the panel are left out while the
  native call owns media (`@native`), and the MeetingBar hook hides them when
  the page learns it first (`nativeCallOwnsMedia`).
  """

  use PlatformWeb, :live_component

  alias PlatformWeb.Components.Meetings.DevicePanel

  # The panel root's DOM id; the bar names it in `data-bar-devices`.
  @devices_id "meeting-bar-devices"

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:mic_on, true)
     |> assign(:camera_on, false)
     # Task 01a13c62 stage 3: the native call's capabilities while the
     # Burrow iOS app owns the media (else nil), and whether a page mute is
     # waiting for the native call to confirm it. Both arrive with the
     # `:meeting_media_state` `send_update/2` from ShellLive.
     |> assign(:native, nil)
     |> assign(:mic_pending, false)}
  end

  @impl true
  def update(assigns, socket) do
    # Stage 3 (task 019ee06b): `mic_on`/`camera_on` are pushed in via
    # `send_update/2` from ShellLive's `:meeting_media_state` handler. They
    # are NOT part of the regular shell-meeting assigns the parent passes on
    # every render, so we use `Map.has_key?/2` (not `assigns[:mic_on] || ...`)
    # to apply them only when the parent explicitly sends them — otherwise
    # a normal parent re-render would silently clobber them with `nil`, and
    # a `false` from the server would be lost to the `||` short-circuit.
    #
    # Stage 4 (task 019ee06b): the SAME `Map.has_key?/2` pattern applies to
    # EVERY assign on a partial `send_update/2` — when ShellLive's
    # `:meeting_media_state` handler calls `send_update(__MODULE__, id:, mic_on:,
    # camera_on:)`, the other shell-meeting keys (`:meeting_active`,
    # `:meeting_space_id`, etc.) are absent. The prior `assigns[:meeting_active]
    # || false` shape silently flipped the bar to hidden on every toggle.
    # Treat ANY shell-meeting key the same way: assign only if present.
    socket =
      Enum.reduce(
        [
          {:meeting_active, :meeting_active},
          {:meeting_space_id, :space_id},
          {:meeting_space_name, :space_name},
          {:meeting_space_slug, :space_slug},
          {:meeting_slug, :meeting_slug},
          {:meeting_started_at, :started_at},
          {:in_call_room, :in_call_room},
          {:meeting_roster, :roster},
          {:meeting_here_count, :here_count},
          {:meeting_can_end, :can_end},
          {:id, :id},
          {:mic_on, :mic_on},
          {:camera_on, :camera_on},
          {:native, :native},
          {:mic_pending, :mic_pending}
        ],
        socket,
        fn {from_key, to_key}, acc ->
          if Map.has_key?(assigns, from_key) do
            assign(acc, to_key, assigns[from_key])
          else
            acc
          end
        end
      )

    {:ok, socket}
  end

  @impl true
  # Task 01a1e82a stage 1, direction A of prototype 01a1e823: a green band at
  # the top of the main column (right of the desktop sidebar) that pushes the
  # page down, never overlays it. Below `sm` the same element is the phone
  # strip: live dot, name, clock and "Tap to return ›", with a full-bleed
  # link over it so the whole strip opens the call.
  #
  # One element for both widths, deliberately: the MeetingBar hook ticks the
  # FIRST `[data-timer]` under its root and binds every `[data-bar-*]`, so a
  # second copy of the clock would never tick.
  #
  # `data-state` is the reconnect contract for stage 2: JS sets it to
  # "reconnecting" and the `data-[state=reconnecting]:` / `group-data-…`
  # variants repaint the bar in warning tokens. `JS.ignore_attributes/1`
  # keeps a server patch from resetting it to "connected".
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:in_call_room, fn -> false end)
      |> assign_new(:roster, fn -> [] end)
      |> assign_new(:here_count, fn -> 0 end)
      |> assign_new(:can_end, fn -> false end)
      |> assign(
        :return_path,
        return_to_call_path(assigns[:meeting_slug], assigns[:space_slug], assigns[:space_id])
      )
      |> assign(:devices_id, @devices_id)
      |> assign(:devices?, is_nil(assigns[:native]))

    ~H"""
    <div id="meeting-bar-mount" class="contents">
      <div
        :if={@meeting_active && !@in_call_room}
        id="meeting-top-bar"
        phx-hook="MeetingBar"
        phx-mounted={JS.ignore_attributes(["data-state", "data-lost"])}
        data-state="connected"
        data-started-at={@started_at && DateTime.to_iso8601(@started_at)}
        data-bar-devices={@devices? && @devices_id}
        aria-label="In call"
        class={[
          "group relative flex shrink-0 items-center gap-2.5 px-3.5 py-2 text-sm",
          "sm:h-11 sm:gap-3 sm:py-0 sm:pl-5 sm:pr-4",
          "bg-success text-success-content",
          "data-[state=reconnecting]:bg-warning data-[state=reconnecting]:text-warning-content"
        ]}
      >
        <span
          aria-hidden="true"
          class="size-2.5 shrink-0 rounded-full bg-current motion-safe:animate-pulse"
        />
        <span class="hidden shrink-0 sm:inline">In call</span>
        <span data-role="meeting-name" class="min-w-0 truncate font-bold">
          {@space_name || "Meeting"}
        </span>
        <%!-- Ticked by the MeetingBar hook from `data-started-at`. While
             reconnecting (stage 2, meeting_presence.js) the clock gives way
             to "Reconnecting… 0:07", and after 30s to "Connection lost". --%>
        <span data-timer class="shrink-0 tabular-nums group-data-[state=reconnecting]:hidden">
          0:00
        </span>
        <span
          data-role="meeting-conn-status"
          class="hidden shrink-0 tabular-nums group-data-[state=reconnecting]:inline"
        >
          <span class="group-data-[lost=true]:hidden">
            Reconnecting… <span data-conn-timer>0:00</span>
          </span>
          <span class="hidden font-semibold group-data-[lost=true]:inline">Connection lost</span>
        </span>

        <span :if={@roster != []} data-role="meeting-faces" class="hidden shrink-0 pl-1.5 sm:flex">
          <span
            :for={face <- @roster}
            aria-hidden="true"
            title={face.name}
            class={[
              "-ml-1.5 grid size-[22px] place-items-center rounded-full border-2 text-[9px] font-bold",
              "border-success bg-success-content/25 group-data-[state=reconnecting]:border-warning group-data-[state=reconnecting]:bg-warning-content/25"
            ]}
          >
            {face.initials}
          </span>
        </span>
        <span
          :if={@here_count > 0}
          data-role="meeting-here"
          class="hidden shrink-0 opacity-85 sm:inline"
        >
          {@here_count} here
        </span>

        <span class="flex-1" />

        <%!-- Phone strip action. The link over the strip is what you tap. --%>
        <span
          aria-hidden="true"
          class="shrink-0 text-[13px] font-semibold opacity-95 group-data-[lost=true]:hidden sm:hidden"
        >
          Tap to return ›
        </span>
        <.link
          navigate={@return_path}
          data-role="meeting-strip-link"
          aria-label={"Return to call: " <> (@space_name || "Meeting")}
          class="absolute inset-0 sm:hidden"
        >
        </.link>

        <%!-- Mic. No `phx-click`: the MeetingBar hook binds `[data-bar-mic]`
             and pushes `meeting_toggle_mic` to the active LiveView (task
             019ee06b stage 4). In the iOS app the state is what the native
             call CONFIRMED (task 01a13c62 stage 3): pending is disabled with
             a warning ring, and a build whose page cannot drive the mic hides
             it. Off is the inverted chip. --%>
        <span
          :if={is_nil(@native) or @native.mic}
          class="hidden shrink-0 items-stretch sm:inline-flex"
        >
          <button
            type="button"
            data-bar-mic
            disabled={@mic_pending}
            aria-busy={if @mic_pending, do: "true"}
            aria-pressed={if @mic_on, do: "false", else: "true"}
            class={[
              control_class(),
              toggle_class(@mic_on),
              @mic_pending && "ring-2 ring-warning",
              @devices? && "rounded-r-none"
            ]}
            title={if @mic_on, do: "Mute mic", else: "Unmute mic"}
          >
            <span><b>Mic</b> {if @mic_on, do: "on", else: "off"}</span>
          </button>
          <.caret
            :if={@devices?}
            data-bar-mic-devices
            devices_id={@devices_id}
            kind="audioinput"
            label="Choose microphone"
            on={@mic_on}
          />
        </span>

        <%!-- Camera. Same hook pathway as the mic. --%>
        <span
          :if={is_nil(@native) or @native.camera}
          class="hidden shrink-0 items-stretch sm:inline-flex"
        >
          <button
            type="button"
            data-bar-camera
            aria-pressed={if @camera_on, do: "true", else: "false"}
            class={[control_class(), toggle_class(@camera_on), @devices? && "rounded-r-none"]}
            title={if @camera_on, do: "Turn off camera", else: "Turn on camera"}
          >
            <span>{if @camera_on, do: "Cam on", else: "Cam off"}</span>
          </button>
          <.caret
            :if={@devices?}
            data-bar-camera-devices
            devices_id={@devices_id}
            kind="videoinput"
            label="Choose camera"
            on={@camera_on}
          />
        </span>

        <.link
          navigate={@return_path}
          data-role="meeting-return"
          class={[control_class(), toggle_class(true)]}
        >
          Return to call ↗
        </.link>

        <%!-- Connection lost (stage 2): Rejoin at both widths; on the phone
             strip, Leave opens the Leave sheet (meeting_presence.js). Above
             the strip link, so a tap reaches them. --%>
        <span class="hidden group-data-[lost=true]:contents">
          <button
            type="button"
            data-bar-rejoin
            class="relative z-10 inline-flex shrink-0 items-center rounded-lg bg-warning-content/15 px-2.5 py-1 text-[13px] font-semibold lg:hover:opacity-90"
          >
            Rejoin
          </button>
          <span class="contents sm:hidden">
            <button
              type="button"
              data-meeting-leave-sheet
              class="relative z-10 inline-flex shrink-0 items-center rounded-lg bg-error px-2.5 py-1 text-[13px] font-semibold text-error-content"
            >
              Leave
            </button>
          </span>
        </span>

        <%!-- Leave stays one click. For the host a split chevron beside it
             opens a one-item menu, "End for everyone" (task 01a1e82a
             remediation), which pushes the same host-checked
             `meeting_presence_end` the phone Leave sheet uses. Desktop
             only, like every bar control. --%>
        <span class="hidden shrink-0 items-stretch sm:inline-flex">
          <button
            type="button"
            phx-click="leave_meeting"
            phx-target={@myself}
            data-bar-leave
            class={[
              control_class(),
              "bg-error text-error-content lg:hover:opacity-90",
              @can_end && "rounded-r-none"
            ]}
            title="Leave meeting"
          >
            Leave
          </button>
          <span :if={@can_end} class="relative inline-flex">
            <button
              type="button"
              data-bar-end-menu
              aria-haspopup="menu"
              aria-expanded="false"
              aria-controls="meeting-bar-end-menu"
              title="More leave options"
              phx-click={
                JS.toggle(to: "#meeting-bar-end-menu")
                |> JS.toggle_attribute({"aria-expanded", "true", "false"})
              }
              class={[
                control_class(),
                "rounded-l-none border-l border-error-content/30 bg-error px-1.5 text-error-content lg:hover:opacity-90"
              ]}
            >
              <span class="hero-chevron-down size-3.5" aria-hidden="true" />
              <span class="sr-only">More leave options</span>
            </button>
            <div
              id="meeting-bar-end-menu"
              role="menu"
              phx-click-away={
                JS.hide(to: "#meeting-bar-end-menu")
                |> JS.set_attribute({"aria-expanded", "false"}, to: "[data-bar-end-menu]")
              }
              class="absolute right-0 top-full z-[60] mt-1.5 hidden min-w-44 rounded-xl border border-edge bg-base-100 p-1 text-base-content shadow-lg"
            >
              <button
                type="button"
                role="menuitem"
                data-bar-end
                phx-click={JS.hide(to: "#meeting-bar-end-menu") |> JS.push("meeting_presence_end")}
                class="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-[13px] font-semibold text-base-content lg:hover:bg-base-200"
              >
                <%!-- The room's palette rule (R3): the hue goes on the glyph,
                     never on the label. --%>
                <span class="hero-phone-x-mark size-4 shrink-0 text-error" aria-hidden="true" />
                End for everyone
              </button>
            </div>
          </span>
        </span>
      </div>
      <.devices :if={@meeting_active && !@in_call_room && @devices?} id={@devices_id} />
    </div>
    """
  end

  attr(:id, :string, required: true)

  # The panel root: a function component, NOT a LiveComponent, with no
  # `phx-target` (see the moduledoc). A SIBLING of the bar, in the mount's
  # `contents`, so the notice slot is the next item of the shell's column,
  # directly under the bar, and the fixed popover is not inside the bar's
  # `relative` band. `phx-update="ignore"`: the hook owns everything in it.
  defp devices(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="MeetingDevicePanel"
      phx-update="ignore"
      phx-mounted={JS.ignore_attributes(["hidden"])}
      data-role="meeting-devices"
      data-devices-surface="meeting"
      data-devices-notice="when-alone"
      class="contents"
    >
      <div
        id={"#{@id}-notice"}
        data-role="meeting-bar-device-notice"
        role="status"
        aria-live="polite"
        class="w-full shrink-0 empty:sr-only"
      >
      </div>
      <DevicePanel.device_panel id={"#{@id}-popover"} container={:popover} />
      <DevicePanel.device_panel id={"#{@id}-sheet"} container={:sheet} />
    </div>
    """
  end

  attr(:devices_id, :string, required: true)
  attr(:kind, :string, required: true)
  attr(:label, :string, required: true)
  attr(:on, :boolean, required: true)
  attr(:rest, :global, include: ~w(data-bar-mic-devices data-bar-camera-devices))

  # The caret half of a split Mic / Cam chip: the chip's own ground (so the
  # pair reads as one control, in success or, reconnecting, warning tokens)
  # and a hairline in the band's content colour between them. Compact on
  # the 44px band, with a full-height hit area from an `after:` box, so the
  # touch target is 44px without growing the chip. `aria-expanded` and
  # `hidden` belong to the hooks, so a LiveView patch (every mute) keeps them.
  defp caret(assigns) do
    ~H"""
    <button
      type="button"
      data-devices-for={@devices_id}
      data-devices-container="popover"
      data-devices-section={@kind}
      data-devices-placement="below"
      phx-mounted={JS.ignore_attributes(["aria-expanded", "hidden"])}
      aria-haspopup="dialog"
      aria-expanded="false"
      aria-controls={"#{@devices_id}-popover"}
      aria-label={@label}
      title={@label}
      class={[
        control_class(),
        toggle_class(@on),
        "relative rounded-l-none border-l border-current/30 px-1.5",
        "after:absolute after:inset-x-0 after:-inset-y-2 after:content-['']"
      ]}
      {@rest}
    >
      <span class="hero-chevron-down size-3.5" aria-hidden="true"></span>
    </button>
    """
  end

  # Desktop-only bar controls (the phone strip carries none).
  defp control_class,
    do:
      "hidden shrink-0 items-center gap-1.5 rounded-lg px-2.5 py-1 text-[13px] font-semibold transition-opacity sm:inline-flex"

  # An "on" control is a soft well on the band; an "off" one is the inverted
  # chip (the band's content colour as fill, the band colour as text), in
  # success tokens or, while reconnecting, warning tokens.
  defp toggle_class(true),
    do:
      "bg-success-content/15 group-data-[state=reconnecting]:bg-warning-content/15 lg:hover:opacity-90"

  defp toggle_class(false),
    do:
      "bg-success-content text-success group-data-[state=reconnecting]:bg-warning-content group-data-[state=reconnecting]:text-warning lg:hover:opacity-90"

  # Build the Return-to-call href. Prefer the canonical MeetingLive surface
  # (`/meetings/<meeting_slug>`); fall back to the chat surface (`/chat/<slug>`)
  # if the meeting_slug isn't available yet. The final `space_id` fallback
  # mirrors the pre-existing space-name link logic so a truly nil bar still
  # renders without a broken `nil` interpolation.
  @doc false
  def return_to_call_path(meeting_slug, _space_slug, _space_id) when is_binary(meeting_slug),
    do: "/meetings/#{meeting_slug}"

  def return_to_call_path(_, space_slug, _space_id) when is_binary(space_slug),
    do: "/chat/#{space_slug}"

  def return_to_call_path(_, _, space_id) when is_binary(space_id),
    do: "/chat/#{space_id}"

  def return_to_call_path(_, _, _), do: "/meetings"

  @impl true
  def handle_event("meeting_bar_state", %{"mic" => mic, "camera" => camera} = _params, socket) do
    # Sync state pushed from JS hook reading LiveKit room (initial _syncState
    # + livekit:room-connected events). This is a passive mirror, not a
    # user-initiated toggle — kept so a fresh bar mount learns the truth
    # from the live LiveKit room rather than the assign default.
    {:noreply,
     socket
     |> assign(:mic_on, mic)
     |> assign(:camera_on, camera)}
  end

  # Stage 4 (task 019ee06b): `toggle_meeting_mic` / `toggle_meeting_camera`
  # phx-click bindings are gone — `data-bar-mic` / `data-bar-camera` are now
  # driven by the MeetingBar JS hook, which pushes `meeting_toggle_mic` /
  # `meeting_toggle_camera` at the active LiveView (ChatLive on /chat,
  # ShellLive fallback elsewhere). The component-local toggles that used to
  # live here were the source of the bar/in-chat drift this stage fixes.
  # Likewise, `mic_toggled`/`camera_toggled` arrived from the JS hook's
  # post-LiveKit `pushEventTo`, which is also gone.

  def handle_event("leave_meeting", _params, socket) do
    # Notify the parent LiveView to handle the actual leave logic
    send(self(), :meeting_bar_leave)
    {:noreply, socket}
  end
end
