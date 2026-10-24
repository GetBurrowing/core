defmodule PlatformWeb.MeetingBarLive do
  @moduledoc """
  LiveComponent rendering the persistent meeting mini-bar.

  Displayed in the shell layout whenever the current user is in an active
  meeting. Manages local UI state for mic/camera toggles and the meeting
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
    * `:on_meeting_page` — boolean, true when viewing the meeting's chat page
      OR the canonical MeetingLive surface
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
          {:on_meeting_page, :on_meeting_page},
          {:sidebar_collapsed, :sidebar_collapsed},
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
  def render(assigns) do
    ~H"""
    <div
      id="meeting-mini-bar"
      phx-hook="MeetingBar"
      data-started-at={@started_at && DateTime.to_iso8601(@started_at)}
      class={[
        "fixed bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+var(--bottom-nav-gap,0px))] inset-x-0 z-40 h-12 bg-base-200 border-t border-edge shadow-lg flex items-center gap-3 px-4",
        if(@sidebar_collapsed, do: "lg:left-14", else: "lg:left-56"),
        if(!@meeting_active || @on_meeting_page, do: "hidden")
      ]}
    >
      <%!-- Pulsing indicator + space name --%>
      <div class="flex items-center gap-2 min-w-0">
        <span class="bg-success rounded-full w-2 h-2 animate-pulse flex-shrink-0"></span>
        <.link
          navigate={"/chat/#{@space_slug || @space_id}"}
          class="truncate font-medium text-success hover:text-success/80 transition-colors text-sm"
        >
          {@space_name || "Meeting"}
        </.link>
      </div>

      <%!-- Duration timer (updated by MeetingTimer JS hook) --%>
      <span class="tabular-nums text-subtle text-xs font-mono" data-timer>
        00:00
      </span>

      <div class="flex-1" />

      <%!-- Mic toggle. Stage 4 (task 019ee06b): click is bound by the
           MeetingBar JS hook on `[data-bar-mic]` and dispatched as
           `meeting_toggle_mic` to the active LiveView — ChatLive's
           MeetingHooks on /chat, ShellLive's fallback elsewhere. No
           `phx-click` so the LiveComponent doesn't intercept and create a
           local-only state path. --%>
      <%!-- Task 01a13c62 stage 3: in the iOS app the state is what the
           native call CONFIRMED. Pending (a tap in flight) is disabled with
           a warning ring; a build whose page cannot drive the mic hides it. --%>
      <button
        :if={is_nil(@native) or @native.mic}
        data-bar-mic
        disabled={@mic_pending}
        aria-busy={if @mic_pending, do: "true"}
        class={[
          "rounded-lg p-1.5 transition-colors",
          if(@mic_on,
            do: "text-base-content hover:bg-base-300",
            else: "text-error bg-error/10 hover:bg-error/20"
          ),
          @mic_pending && "ring-2 ring-warning"
        ]}
        title={if @mic_on, do: "Mute mic", else: "Unmute mic"}
      >
        <span class={["size-4", if(@mic_on, do: "hero-microphone", else: "hero-microphone-slash")]} />
      </button>

      <%!-- Camera toggle. Same JS-hook pathway as mic, see above. --%>
      <button
        :if={is_nil(@native) or @native.camera}
        data-bar-camera
        class={[
          "rounded-lg p-1.5 transition-colors",
          if(@camera_on,
            do: "text-base-content hover:bg-base-300",
            else: "text-subtle hover:bg-base-300"
          )
        ]}
        title={if @camera_on, do: "Turn off camera", else: "Turn on camera"}
      >
        <span class={[
          "size-4",
          if(@camera_on, do: "hero-video-camera", else: "hero-video-camera-slash")
        ]} />
      </button>

      <%!-- Return to call — deep links to the canonical MeetingLive surface.
           Falls back to the chat surface if `meeting_slug` is nil (race
           where the join broadcast fires before the Meeting row exists). --%>
      <.link
        navigate={return_to_call_path(@meeting_slug, @space_slug, @space_id)}
        class="rounded-lg px-2.5 py-1 text-xs font-medium text-success hover:bg-success/10 transition-colors hidden sm:inline-flex"
      >
        Return to call
      </.link>

      <%!-- Leave meeting --%>
      <button
        phx-click="leave_meeting"
        phx-target={@myself}
        data-bar-leave
        class="rounded-lg px-2.5 py-1 text-xs font-medium text-error hover:bg-error/10 transition-colors"
        title="Leave meeting"
      >
        Leave
      </button>
    </div>
    """
  end

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
