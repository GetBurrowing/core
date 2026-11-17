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
    * `:meeting_started_at` — `DateTime` when the user joined
    * `:in_call_room` — boolean, true only on `/meetings/<meeting_slug>`
      (computed once, by `PlatformWeb.MeetingBarPresence.in_call_room?/2`)
    * `:meeting_roster` — up to four `%{id, name, initials}` faces
    * `:meeting_here_count` — how many participants are in the call
  """

  use PlatformWeb, :live_component

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
      |> assign(
        :return_path,
        return_to_call_path(assigns[:meeting_slug], assigns[:space_slug], assigns[:space_id])
      )

    ~H"""
    <div id="meeting-bar-mount" class="contents">
      <div
        :if={@meeting_active && !@in_call_room}
        id="meeting-top-bar"
        phx-hook="MeetingBar"
        phx-mounted={JS.ignore_attributes(["data-state"])}
        data-state="connected"
        data-started-at={@started_at && DateTime.to_iso8601(@started_at)}
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
        <%!-- Ticked by the MeetingBar hook from `data-started-at`. --%>
        <span data-timer class="shrink-0 tabular-nums">0:00</span>

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
        <span aria-hidden="true" class="shrink-0 text-[13px] font-semibold opacity-95 sm:hidden">
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
        <button
          :if={is_nil(@native) or @native.mic}
          type="button"
          data-bar-mic
          disabled={@mic_pending}
          aria-busy={if @mic_pending, do: "true"}
          aria-pressed={if @mic_on, do: "false", else: "true"}
          class={[control_class(), toggle_class(@mic_on), @mic_pending && "ring-2 ring-warning"]}
          title={if @mic_on, do: "Mute mic", else: "Unmute mic"}
        >
          <span><b>Mic</b> {if @mic_on, do: "on", else: "off"}</span>
        </button>

        <%!-- Camera. Same hook pathway as the mic. --%>
        <button
          :if={is_nil(@native) or @native.camera}
          type="button"
          data-bar-camera
          aria-pressed={if @camera_on, do: "true", else: "false"}
          class={[control_class(), toggle_class(@camera_on)]}
          title={if @camera_on, do: "Turn off camera", else: "Turn on camera"}
        >
          <span>{if @camera_on, do: "Cam on", else: "Cam off"}</span>
        </button>

        <.link
          navigate={@return_path}
          data-role="meeting-return"
          class={[control_class(), toggle_class(true)]}
        >
          Return to call ↗
        </.link>

        <button
          type="button"
          phx-click="leave_meeting"
          phx-target={@myself}
          data-bar-leave
          class={[control_class(), "bg-error text-error-content lg:hover:opacity-90"]}
          title="Leave meeting"
        >
          Leave
        </button>
      </div>
    </div>
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
  defp return_to_call_path(meeting_slug, _space_slug, _space_id) when is_binary(meeting_slug),
    do: "/meetings/#{meeting_slug}"

  defp return_to_call_path(_, space_slug, _space_id) when is_binary(space_slug),
    do: "/chat/#{space_slug}"

  defp return_to_call_path(_, _, space_id) when is_binary(space_id),
    do: "/chat/#{space_id}"

  defp return_to_call_path(_, _, _), do: "/meetings"

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
