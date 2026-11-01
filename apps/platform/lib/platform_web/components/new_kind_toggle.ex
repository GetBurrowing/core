defmodule PlatformWeb.Components.NewKindToggle do
  @moduledoc """
  The Event | Meeting segmented control at the top of Calendar's New editor
  (task 01a1986e, design canvas `01a19878-a1c2-7000-ad1d-fb72f7b6c1f0`).

  It chooses WHAT is being created before WHEN. Event is the calendar's own
  editor; Meeting hands the date and start time to the existing MeetingLive
  scheduling sheet, so there is one meeting create path. The Meeting side
  carries the calendar's teal meeting swatch, so the choice previews how the
  entry will look on the grid.

  Each side is a `role="radio"` button that fires its own click event; the
  component holds no state. It does not remember the last choice (declared
  follow-up).
  """
  use Phoenix.Component

  attr(:active, :atom, values: [:event, :meeting], default: :event)
  attr(:event_click, :string, default: nil, doc: "phx-click for the Event side")
  attr(:meeting_click, :string, default: nil, doc: "phx-click for the Meeting side")
  attr(:class, :string, default: nil)

  def new_kind_toggle(assigns) do
    ~H"""
    <div class={["flex flex-col gap-1.5", @class]}>
      <div
        role="radiogroup"
        aria-label="What to create"
        data-role="new-kind-toggle"
        class="grid grid-cols-2 overflow-hidden rounded-field border border-edge bg-base-200 p-1"
      >
        <.segment kind="event" checked={@active == :event} click={@event_click}>
          Event
        </.segment>
        <.segment kind="meeting" checked={@active == :meeting} click={@meeting_click}>
          <i class="cal-sw cal-k-meeting" aria-hidden="true"></i> Meeting
        </.segment>
      </div>
      <p class="text-[13px] text-subtle">Meetings get a room link and send invites.</p>
    </div>
    """
  end

  attr(:kind, :string, required: true)
  attr(:checked, :boolean, required: true)
  attr(:click, :string, default: nil)
  slot(:inner_block, required: true)

  defp segment(assigns) do
    ~H"""
    <button
      type="button"
      role="radio"
      data-kind={@kind}
      aria-checked={to_string(@checked)}
      tabindex={if @checked, do: "0", else: "-1"}
      phx-click={@click}
      class={[
        "inline-flex min-h-11 items-center justify-center gap-2 rounded-field px-3 text-[15px] font-medium",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring",
        @kind == "meeting" && "border-l border-edge",
        if(@checked,
          do: "bg-primary text-primary-content",
          else: "text-base-content hover:bg-base-300"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end
end
