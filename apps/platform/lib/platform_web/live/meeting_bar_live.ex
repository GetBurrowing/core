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
    * `:meeting_started_at` — `DateTime` when the user joined
    * `:on_meeting_page` — boolean, true when viewing the meeting's chat page
  """

  use PlatformWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:mic_on, true)
     |> assign(:camera_on, false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:meeting_active, assigns[:meeting_active] || false)
     |> assign(:space_id, assigns[:meeting_space_id])
     |> assign(:space_name, assigns[:meeting_space_name])
     |> assign(:space_slug, assigns[:meeting_space_slug])
     |> assign(:started_at, assigns[:meeting_started_at])
     |> assign(:on_meeting_page, assigns[:on_meeting_page] || false)
     |> assign(:sidebar_collapsed, assigns[:sidebar_collapsed] || false)
     |> assign(:id, assigns[:id])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="meeting-mini-bar"
      phx-hook="MeetingBar"
      data-started-at={@started_at && DateTime.to_iso8601(@started_at)}
      class={[
        "fixed bottom-0 inset-x-0 z-40 h-12 bg-base-200 border-t border-base-300 shadow-lg flex items-center gap-3 px-4",
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
      <span class="tabular-nums text-base-content/60 text-xs font-mono" data-timer>
        00:00
      </span>

      <div class="flex-1" />

      <%!-- Mic toggle --%>
      <button
        phx-click="toggle_meeting_mic"
        phx-target={@myself}
        data-bar-mic
        class={[
          "rounded-lg p-1.5 transition-colors",
          if(@mic_on,
            do: "text-base-content/70 hover:bg-base-300",
            else: "text-error bg-error/10 hover:bg-error/20"
          )
        ]}
        title={if @mic_on, do: "Mute mic", else: "Unmute mic"}
      >
        <span class={["size-4", if(@mic_on, do: "hero-microphone", else: "hero-microphone-slash")]} />
      </button>

      <%!-- Camera toggle --%>
      <button
        phx-click="toggle_meeting_camera"
        phx-target={@myself}
        data-bar-camera
        class={[
          "rounded-lg p-1.5 transition-colors",
          if(@camera_on,
            do: "text-base-content/70 hover:bg-base-300",
            else: "text-base-content/40 hover:bg-base-300"
          )
        ]}
        title={if @camera_on, do: "Turn off camera", else: "Turn on camera"}
      >
        <span class={[
          "size-4",
          if(@camera_on, do: "hero-video-camera", else: "hero-video-camera-slash")
        ]} />
      </button>

      <%!-- Return to call --%>
      <.link
        navigate={"/chat/#{@space_slug || @space_id}"}
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

  @impl true
  def handle_event("toggle_meeting_mic", _params, socket) do
    new_mic = !socket.assigns.mic_on
    {:noreply, assign(socket, :mic_on, new_mic)}
  end

  def handle_event("toggle_meeting_camera", _params, socket) do
    new_camera = !socket.assigns.camera_on
    {:noreply, assign(socket, :camera_on, new_camera)}
  end

  def handle_event("meeting_bar_state", %{"mic" => mic, "camera" => camera} = _params, socket) do
    # Sync state pushed from JS hook reading LiveKit room
    {:noreply,
     socket
     |> assign(:mic_on, mic)
     |> assign(:camera_on, camera)}
  end

  def handle_event("mic_toggled", %{"enabled" => enabled}, socket) do
    {:noreply, assign(socket, :mic_on, enabled)}
  end

  def handle_event("camera_toggled", %{"enabled" => enabled}, socket) do
    {:noreply, assign(socket, :camera_on, enabled)}
  end

  def handle_event("leave_meeting", _params, socket) do
    # Notify the parent LiveView to handle the actual leave logic
    send(self(), :meeting_bar_leave)
    {:noreply, socket}
  end
end
