defmodule PlatformWeb.MeetingBarLive do
  @moduledoc """
  Root-level LiveComponent that persists across LiveView navigation.

  Rendered in the shell layout (outside per-page LiveViews), this component:
  - Receives meeting state from ShellLive assigns (active_meeting, mic/camera state)
  - Renders a fixed-position mini-bar when the user is in an active meeting
    and not currently viewing the meeting space page
  - Communicates with the MeetingRoom JS hook for LiveKit Room persistence

  Meeting state is managed by ShellLive (via PubSub subscriptions and JS hook
  events). This component is a pure rendering surface that also handles its
  own button click events (toggle mic/camera, leave).

  The JS hook (`MeetingRoom`) holds the LiveKit Room instance at root level,
  attached to the shell DOM rather than per-page containers, so audio/video
  survives navigation.
  """

  use PlatformWeb, :live_component

  @impl true
  def update(assigns, socket) do
    current_path = assigns[:current_path] || "/"
    active_meeting = assigns[:active_meeting]

    # Determine if we're currently viewing the meeting space page
    viewing_meeting_space? = meeting_space_path?(current_path, active_meeting)

    socket =
      socket
      |> assign(assigns)
      |> assign(:viewing_meeting_space?, viewing_meeting_space?)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="meeting-bar-root"
      phx-hook="MeetingRoom"
      data-user-id={@user_id}
      class={if @active_meeting && !@viewing_meeting_space?, do: "", else: "hidden"}
    >
      <div class="fixed bottom-0 left-0 right-0 z-50 border-t border-base-300 bg-base-200/95 backdrop-blur-sm safe-area-bottom">
        <div class="flex h-12 items-center justify-between px-4">
          <%!-- Left: meeting info --%>
          <div class="flex items-center gap-3 min-w-0">
            <span class="inline-block size-2 rounded-full bg-green-500 animate-pulse flex-shrink-0">
            </span>
            <div class="min-w-0">
              <span class="text-sm font-medium text-base-content truncate block">
                {meeting_display_name(@active_meeting)}
              </span>
            </div>
            <span
              id="meeting-duration"
              class="text-xs text-base-content/50 tabular-nums flex-shrink-0"
              data-started-at={@meeting_started_at && DateTime.to_iso8601(@meeting_started_at)}
            >
              0:00
            </span>
            <span class="text-xs text-base-content/40 flex-shrink-0">
              <span class="hero-users size-3.5 inline-block align-text-bottom"></span>
              {@participant_count}
            </span>
          </div>

          <%!-- Right: controls --%>
          <div class="flex items-center gap-1.5">
            <%!-- Mic toggle --%>
            <button
              phx-click="toggle_meeting_mic"
              class={[
                "rounded-lg p-2 transition-colors",
                if(@mic_enabled,
                  do: "text-base-content/70 hover:bg-base-300",
                  else: "bg-error/20 text-error hover:bg-error/30"
                )
              ]}
              title={if @mic_enabled, do: "Mute microphone", else: "Unmute microphone"}
            >
              <span class={[
                "size-4",
                if(@mic_enabled, do: "hero-microphone", else: "hero-microphone-slash")
              ]}>
              </span>
            </button>

            <%!-- Camera toggle --%>
            <button
              phx-click="toggle_meeting_camera"
              class={[
                "rounded-lg p-2 transition-colors",
                if(@camera_enabled,
                  do: "text-base-content/70 hover:bg-base-300",
                  else: "bg-error/20 text-error hover:bg-error/30"
                )
              ]}
              title={if @camera_enabled, do: "Turn off camera", else: "Turn on camera"}
            >
              <span class={[
                "size-4",
                if(@camera_enabled, do: "hero-video-camera", else: "hero-video-camera-slash")
              ]}>
              </span>
            </button>

            <%!-- Return to call --%>
            <.link
              :if={@active_meeting}
              navigate={meeting_space_url(@active_meeting)}
              class="rounded-lg px-3 py-1.5 text-xs font-medium text-primary hover:bg-primary/10 transition-colors"
            >
              Return
            </.link>

            <%!-- Leave --%>
            <button
              phx-click="leave_meeting"
              class="rounded-lg px-3 py-1.5 text-xs font-medium text-error hover:bg-error/10 transition-colors"
            >
              Leave
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp meeting_display_name(nil), do: ""

  defp meeting_display_name(meeting) when is_map(meeting) do
    meeting[:space_name] || meeting[:room_name] || "Meeting"
  end

  defp meeting_display_name(_), do: ""

  defp meeting_space_url(nil), do: "/chat"

  defp meeting_space_url(meeting) when is_map(meeting) do
    case meeting[:space_slug] do
      slug when is_binary(slug) and slug != "" -> "/chat/#{slug}"
      _ -> "/chat"
    end
  end

  defp meeting_space_url(_), do: "/chat"

  defp meeting_space_path?(_current_path, nil), do: false

  defp meeting_space_path?(current_path, meeting) when is_map(meeting) do
    case meeting[:space_slug] do
      slug when is_binary(slug) and slug != "" ->
        current_path == "/chat/#{slug}"

      _ ->
        false
    end
  end

  defp meeting_space_path?(_, _), do: false
end
