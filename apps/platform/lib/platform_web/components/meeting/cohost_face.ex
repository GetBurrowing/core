defmodule PlatformWeb.Components.Meeting.CohostFace do
  @moduledoc "Square performance view of an existing meeting participant; owns no call audio."
  use Phoenix.Component

  attr(:id, :string, required: true)
  attr(:identity, :string, required: true)
  attr(:name, :string, required: true)

  def cohost_face(assigns) do
    ~H"""
    <div id={@id} phx-hook="MeetingCohostFace" phx-update="ignore" data-identity={@identity}>
      <button type="button" data-face-open class="btn btn-xs absolute left-2 top-2 z-10">
        CRT face
      </button>
      <dialog data-face-dialog class="cohost-performance" aria-label={"#{@name} CRT display"}>
        <div class="cohost-performance-controls">
          <button type="button" data-face-fullscreen class="btn btn-sm">Full screen</button>
          <button type="button" data-face-close class="btn btn-sm">Back to call</button>
        </div>
        <div class="cohost-face-stage" data-face-stage data-state="disconnected">
          <svg viewBox="0 0 600 600" role="img" aria-label={"#{@name}, computer cohost"}>
            <g class="cohost-face-ink">
              <path
                d="M135 194 Q190 164 235 190 M365 190 Q413 172 465 199"
                fill="none"
                stroke="currentColor"
                stroke-width="13"
                stroke-linecap="round"
              />
              <g class="cohost-face-eyes">
                <rect x="145" y="228" width="87" height="82" rx="29" fill="currentColor" />
                <rect x="368" y="228" width="87" height="82" rx="29" fill="currentColor" />
              </g>
              <rect
                data-face-mouth
                x="212"
                y="389"
                width="176"
                height="12"
                rx="6"
                fill="currentColor"
              />
              <path
                d="M181 399 L192 408 M408 408 L419 399"
                fill="none"
                stroke="currentColor"
                stroke-width="9"
                stroke-linecap="round"
              />
            </g>
          </svg>
          <p data-face-status class="cohost-face-status" aria-live="polite">Disconnected</p>
        </div>
      </dialog>
    </div>
    """
  end
end
