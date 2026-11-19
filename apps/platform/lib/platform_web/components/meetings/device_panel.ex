defmodule PlatformWeb.Components.Meetings.DevicePanel do
  @moduledoc """
  The "Sound and video" panel (task 01a1f4c5 stage 2; design direction
  canvas 01a1f4c7): one panel, up to three sections (MICROPHONE, CAMERA,
  SPEAKER), opened from every meeting surface. Only the trigger and the
  container change between surfaces.

  ## A function component, NOT a LiveComponent

  The panel is driven entirely by the `MeetingDevicePanel` JS hook and
  pushes no server events, but the markup sits inside
  `CallShell.call_controls/1`, whose moduledoc explains why nothing in that
  neighbourhood may become a LiveComponent (`pushEvent` from a hook ignores
  `phx-target`). Keep it a function component.

  ## The server renders the FRAME, the browser renders the rows

  Device ids and labels exist only in the browser (`enumerateDevices`), and
  they never reach the server. So the server renders the title, the
  section labels and EMPTY list containers (`phx-update="ignore"`), and the
  hook fills the rows from `assets/js/lib/media_devices.js`.

  The SPEAKER section is rendered here and REMOVED by the hook where the
  browser cannot choose an output (`supportsOutputSelection()` false:
  Safari, Firefox, WKWebView). Removed, never disabled.

  ## Containers

    * `:popover` - desktop (`sm` and up with a fine pointer). Fixed-position,
      placed by the hook above the caret that opened it.
    * `:sheet` - phone. A bottom sheet over a scrim; rows wrap to two lines
      instead of truncating.
    * `:inline` - no chrome; the lobby (stage 3) expands ONE section under
      its "You'll join with" rows. Rendered with every section and hidden;
      the hook un-hides the panel and only the section its Change link
      names. No history layer and no outside-click close: it is an
      accordion, not an overlay. Esc collapses it.

  ## Tokens

  `bg-base-100` surface, `border-edge`, `text-base-content` for every label
  (section labels are set apart by size, weight and case, never by a dimmer
  colour), `text-subtle` for secondary lines, `bg-info` for the meter. The
  sheet's backdrop is `bg-scrim`: the canvas's `bg-black/40` is a palette
  literal, which the meeting palette guard refuses.
  """

  use Phoenix.Component

  @kinds ~w(audioinput videoinput audiooutput)

  @labels %{
    "audioinput" => "Microphone",
    "videoinput" => "Camera",
    "audiooutput" => "Speaker"
  }

  @doc "Every section kind, in render order."
  def kinds, do: @kinds

  @doc "The section label for a kind (rendered uppercase by CSS)."
  def section_label(kind), do: Map.fetch!(@labels, kind)

  attr(:id, :string, required: true)

  attr(:sections, :list,
    default: @kinds,
    doc: "a subset of #{inspect(@kinds)}; rendered in the canonical order"
  )

  attr(:container, :atom, values: [:popover, :sheet, :inline], default: :popover)
  attr(:class, :string, default: nil)

  def device_panel(assigns) do
    assigns =
      assign(assigns, :sections, Enum.filter(@kinds, &(&1 in assigns.sections)))

    ~H"""
    <div
      :if={@container == :sheet}
      id={@id}
      data-role="meeting-device-panel"
      data-container="sheet"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      hidden
      class={["fixed inset-0 z-50", @class]}
    >
      <div data-device-backdrop class="absolute inset-0 bg-scrim" aria-hidden="true"></div>
      <div
        data-device-card
        class="clears-tab-bar absolute inset-x-0 bottom-0 max-h-[75vh] overflow-y-auto rounded-t-2xl border-t border-edge bg-base-100 pb-[env(safe-area-inset-bottom)] text-base-content"
      >
        <div class="flex items-center justify-between gap-2 px-4 pt-3 pb-1">
          <h2 id={"#{@id}-title"} class="text-sm font-semibold text-base-content">
            Sound and video
          </h2>
          <button
            type="button"
            data-device-close
            aria-label="Close"
            class="btn btn-ghost btn-sm btn-square min-h-11 min-w-11 text-base-content"
          >
            <span class="hero-x-mark size-5" aria-hidden="true"></span>
          </button>
        </div>
        <.section :for={kind <- @sections} panel_id={@id} kind={kind} container={:sheet} />
      </div>
    </div>

    <div
      :if={@container == :popover}
      id={@id}
      data-role="meeting-device-panel"
      data-container="popover"
      role="dialog"
      aria-labelledby={"#{@id}-title"}
      hidden
      class={[
        "fixed z-50 max-h-[min(70vh,36rem)] w-80 max-w-[calc(100vw-1rem)] overflow-y-auto rounded-box border border-edge bg-base-100 pb-2 text-base-content shadow-lg",
        @class
      ]}
    >
      <h2 id={"#{@id}-title"} class="px-3 pt-3 pb-1 text-sm font-semibold text-base-content">
        Sound and video
      </h2>
      <.section :for={kind <- @sections} panel_id={@id} kind={kind} container={:popover} />
    </div>

    <div
      :if={@container == :inline}
      id={@id}
      data-role="meeting-device-panel"
      data-container="inline"
      hidden
      class={["text-base-content", @class]}
    >
      <.section :for={kind <- @sections} panel_id={@id} kind={kind} container={:inline} />
    </div>
    """
  end

  @lobby_rows %{
    "audioinput" => %{
      icon: "hero-microphone",
      noun: "microphone",
      placeholder: "Default microphone",
      substituted: "Your usual microphone isn't connected."
    },
    "videoinput" => %{
      icon: "hero-video-camera",
      noun: "camera",
      placeholder: "Default camera",
      substituted: "Your usual camera isn't connected."
    },
    "audiooutput" => %{
      icon: "hero-speaker-wave",
      noun: "speaker",
      placeholder: "Default speaker",
      substituted: "Your usual speaker isn't connected."
    }
  }

  @doc """
  The lobby's "You'll join with" block (task 01a1f4c5 stage 3): one row per
  kind naming WHICH device the person will join with. The lobby's Mic on /
  Camera on toggles say on or off; this block never duplicates them.

  The rows, the mic-check line and the remembered-device lines are
  server-rendered with every string in place, all of it inside ONE
  `phx-update="ignore"` container: the `MeetingLobbyPreview` hook fills the
  device names (they exist only in the browser), shows or hides each line,
  and removes the speaker row where the browser cannot choose an output.
  Nothing in the container is patched by the server after mount.

  Each row's Change link is a `MeetingDevicePanel` trigger with
  `data-devices-container="auto"`: the inline accordion (one section) at
  `sm` and up, the bottom sheet below it.
  """
  attr(:id, :string, default: "meeting-lobby-devices")

  def lobby_devices(assigns) do
    assigns =
      assigns
      |> assign(:kinds, @kinds)
      |> assign(:panel_id, "#{assigns.id}-panel")

    ~H"""
    <section
      id={@id}
      data-role="meeting-lobby-devices"
      aria-labelledby={"#{@id}-title"}
      class="mt-4 flex flex-col text-base-content"
    >
      <h2 id={"#{@id}-title"} class="text-sm font-semibold text-base-content">
        You'll join with
      </h2>
      <div id={"#{@id}-rows"} phx-update="ignore" class="mt-1 flex flex-col">
        <.lobby_row :for={kind <- @kinds} kind={kind} panel_id={@panel_id} />
        <p
          id={"#{@id}-mic-check"}
          data-role="meeting-lobby-mic-check"
          data-state="off"
          role="status"
          aria-live="polite"
          hidden
          class="mt-1 flex items-center gap-2 text-sm text-base-content motion-safe:transition-opacity motion-safe:duration-500 data-[faded=true]:opacity-0"
        >
          <span
            data-mic-check-icon="heard"
            hidden
            class="hero-check size-4 shrink-0"
            aria-hidden="true"
          >
          </span>
          <span
            data-mic-check-icon="warning"
            hidden
            class="hero-exclamation-triangle size-4 shrink-0 text-warning"
            aria-hidden="true"
          >
          </span>
          <span data-mic-check-copy="invitation" hidden>
            Say something to check your microphone.
          </span>
          <span data-mic-check-copy="heard" hidden>We can hear you</span>
          <span data-mic-check-copy="warning" hidden>
            No sound from this microphone. Try another?
          </span>
        </p>
      </div>
      <div
        id={@panel_id}
        phx-hook="MeetingDevicePanel"
        phx-update="ignore"
        data-role="meeting-devices"
        class="contents"
      >
        <.device_panel
          id={"#{@panel_id}-inline"}
          container={:inline}
          class="mt-2 rounded-box border border-edge bg-base-100 pb-2"
        />
        <.device_panel id={"#{@panel_id}-sheet"} container={:sheet} />
      </div>
    </section>
    """
  end

  attr(:kind, :string, required: true)
  attr(:panel_id, :string, required: true)

  defp lobby_row(assigns) do
    assigns = assign(assigns, :row, Map.fetch!(@lobby_rows, assigns.kind))

    ~H"""
    <div data-lobby-device={@kind} class="flex flex-col">
      <div
        data-role="meeting-lobby-device-row"
        data-kind={@kind}
        class="flex min-h-11 items-center gap-2 text-sm text-base-content"
      >
        <span class={[@row.icon, "size-5 shrink-0"]} aria-hidden="true"></span>
        <span
          data-lobby-device-alert
          hidden
          class="hero-exclamation-circle size-4 shrink-0 text-error"
          aria-hidden="true"
        >
        </span>
        <span data-lobby-device-label class="min-w-0 flex-1 truncate">{@row.placeholder}</span>
        <span
          :if={@kind == "audioinput"}
          data-lobby-meter
          hidden
          aria-hidden="true"
          class="flex h-4 shrink-0 items-end gap-0.5 rounded-sm bg-base-200 px-1 py-0.5"
        >
          <i :for={_ <- 1..5} data-meter-bar class="block h-3 w-1 origin-bottom rounded-sm bg-info">
          </i>
        </span>
        <button
          :if={@kind == "audiooutput"}
          type="button"
          data-lobby-test-sound
          data-role="meeting-lobby-test-sound"
          class="btn btn-ghost btn-xs shrink-0 font-normal text-base-content pointer-coarse:min-h-11"
        >
          Test sound
        </button>
        <button
          type="button"
          data-role="meeting-lobby-device-change"
          data-kind={@kind}
          data-devices-for={@panel_id}
          data-devices-container="auto"
          data-devices-section={@kind}
          aria-expanded="false"
          aria-label={"Change #{@row.noun}"}
          class="link shrink-0 px-1 text-sm text-base-content pointer-coarse:min-h-11"
        >
          Change
        </button>
      </div>
      <p
        data-role="meeting-lobby-device-substituted"
        data-kind={@kind}
        hidden
        class="pb-1 pl-7 text-xs text-subtle"
      >
        {@row.substituted}
      </p>
    </div>
    """
  end

  attr(:panel_id, :string, required: true)
  attr(:kind, :string, required: true)
  attr(:container, :atom, required: true)

  defp section(assigns) do
    assigns = assign(assigns, :label, section_label(assigns.kind))

    ~H"""
    <section
      data-device-section={@kind}
      data-role={"meeting-device-section-#{@kind}"}
      class="px-1 pt-2"
    >
      <h3
        id={"#{@panel_id}-#{@kind}-label"}
        class="px-2 pb-1 text-xs font-semibold tracking-wide uppercase text-base-content"
      >
        {@label}
      </h3>
      <div
        id={"#{@panel_id}-#{@kind}-list"}
        role="radiogroup"
        aria-labelledby={"#{@panel_id}-#{@kind}-label"}
        data-device-list={@kind}
        data-container={@container}
        phx-update="ignore"
        class="flex flex-col"
      >
      </div>
      <p
        id={"#{@panel_id}-#{@kind}-status"}
        data-device-status={@kind}
        hidden
        class="flex items-start gap-2 px-2 py-1.5 text-sm text-base-content"
      >
      </p>
      <div :if={@kind == "audiooutput"} class="flex justify-end px-2 pt-1">
        <button
          type="button"
          data-device-test-sound
          data-role="meeting-device-test-sound"
          class="btn btn-ghost btn-xs pointer-coarse:min-h-11 font-normal text-base-content"
        >
          Test sound
        </button>
      </div>
    </section>
    """
  end
end
