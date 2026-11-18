defmodule PlatformWeb.GoalsComponents do
  @moduledoc """
  Pieces shared by the Goals screens (task 01a1dfc1, Goals 4/8): the flag
  tile, the privacy chip and number formatting. Class recipes are copied
  from core's shipped components (`PlatformWeb.Components.BriefingRow`'s
  icon tile, `PlatformWeb.Inbox.InboxList`'s 42px disc, the `chip-soft`
  chip in core's app.css); colours come only from their semantic token
  classes.
  """
  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  @doc """
  The flag tile. `size` is `:md` (36px, the desktop row) or `:lg` (42px, the
  phone row). A goal with no number to follow gets the muted tile.
  """
  attr :size, :atom, default: :md, values: [:md, :lg]
  attr :muted?, :boolean, default: false

  def flag_tile(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      data-role="goal-tile"
      data-muted={to_string(@muted?)}
      class={[
        "flex shrink-0 items-center justify-center",
        if(@size == :lg, do: "size-[42px] rounded-full", else: "size-9 rounded-xl"),
        if(@muted?, do: "bg-base-300 text-subtle", else: "bg-primary text-primary-content")
      ]}
    >
      <.icon name="hero-flag" class="size-5" />
    </span>
    """
  end

  @doc """
  The privacy chip: "Only you" (neutral), "Shared: {names}" for the owner
  of an opened goal, "Shared by {owner}" for a goal someone else owns
  (both success-tinted).
  """
  attr :privacy, :map, required: true, doc: "`%{label: String, shared?: boolean}`"

  def privacy_chip(assigns) do
    ~H"""
    <span
      data-role="goal-privacy"
      data-shared={to_string(@privacy.shared?)}
      class={[
        "chip-soft min-w-0 max-w-[12rem] truncate",
        if(@privacy.shared?, do: "chip-success", else: "chip-neutral")
      ]}
    >
      <.icon :if={!@privacy.shared?} name="hero-lock-closed" class="size-3 shrink-0" />
      <span class="truncate">{@privacy.label}</span>
    </span>
    """
  end

  @doc """
  The coach cards (task 01a1eab7, canvas 01a1eab7-ddae node `md`): a radio
  group of the agents `Platform.Goals.list_coaches/1` returned, never a
  `<select>`. It renders exactly the `coaches` it is given and filters none
  (ineligible agents are absent because the context left them out).

  Selection is state, not action: the selected card gets the `info` ring
  and a check, never `primary`. The agent's own palette slot colours only
  the avatar ring. With more than 4 coaches and `expanded?` false it shows
  3 cards (the selected one always among them) and a "More coaches" card
  that sends `more_event`. Clicking a card sends `event` with
  `phx-value-agent_id`; the screen that owns the event decides nothing from
  it except what to send to the server. Free of any screen's state, so the
  goal page's Change sheet (stage 3) reuses it with `layout: :sheet`.
  """
  attr :id, :string, required: true, doc: "id prefix for the group and its cards"
  attr :coaches, :list, required: true, doc: "`Platform.Goals.Coaches.coach()` maps"
  attr :selected_id, :string, default: nil
  attr :default_id, :string, default: nil

  attr :keep_id, :string,
    default: nil,
    doc: "another card kept in view when collapsed, unlabelled (the goal page's current coach)"

  attr :expanded?, :boolean, default: false
  attr :event, :string, required: true
  attr :more_event, :string, default: nil
  attr :label, :string, default: "Who should coach you?"

  attr :layout, :atom,
    default: :row,
    values: [:row, :sheet],
    doc:
      "`:row` (New goal: up to 4 across at lg) or `:sheet` (the goal page's Change sheet: at most 2 across)"

  def coach_cards(assigns) do
    {shown, hidden} =
      visible_coaches(
        assigns.coaches,
        assigns.selected_id,
        assigns.expanded?,
        [assigns.default_id, assigns.keep_id]
      )

    assigns = assign(assigns, shown: shown, hidden: hidden)

    ~H"""
    <div data-role="goals-coach-cards" id={@id}>
      <p id={@id <> "-label"} class="mb-2 text-sm text-base-content" data-role="goals-coach-label">
        {@label}
      </p>
      <div
        role="radiogroup"
        aria-labelledby={@id <> "-label"}
        class={[
          "grid grid-cols-1 gap-2 sm:grid-cols-2",
          @layout == :row && "lg:grid-cols-4"
        ]}
      >
        <button
          :for={coach <- @shown}
          id={"#{@id}-#{coach.id}"}
          type="button"
          role="radio"
          aria-checked={to_string(coach.id == @selected_id)}
          phx-click={@event}
          phx-value-agent_id={coach.id}
          data-role="goals-coach-card"
          data-agent-id={coach.id}
          data-selected={to_string(coach.id == @selected_id)}
          class={[
            "focus-visible-ring flex min-h-11 min-w-0 cursor-pointer items-start gap-3 rounded-xl border bg-base-200 p-3 text-left transition-colors",
            if(coach.id == @selected_id,
              do: "border-info ring-2 ring-info",
              else: "border-edge lg:hover:border-subtle"
            )
          ]}
        >
          <span
            data-agent-slot={coach.slot}
            data-role="goals-coach-avatar"
            class="mt-0.5 shrink-0 rounded-full ring-2 ring-(--ag) ring-offset-2 ring-offset-base-200"
          >
            <PlatformWeb.AvatarComponents.agent_avatar
              name={coach.name || ""}
              avatar_url={Map.get(coach, :avatar_url)}
              size="sm"
            />
          </span>
          <span class="flex min-w-0 flex-1 flex-col">
            <span
              class="shrink-0 break-words text-sm text-base-content"
              data-role="goals-coach-name"
            >
              {coach.name}
            </span>
            <span
              :if={coach.role_label}
              class="truncate text-xs text-subtle"
              data-role="goals-coach-good-at"
            >
              {coach.role_label}
            </span>
            <span
              :if={coach.id == @default_id or coach.model_label}
              class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1"
            >
              <span
                :if={coach.id == @default_id}
                class="inline-flex items-center gap-1 text-xs text-subtle"
                data-role="goals-coach-default"
              >
                <.icon name="hero-check" class="size-3.5 shrink-0" /> Default
              </span>
              <span
                :if={coach.model_label}
                class="font-mono text-[11px] text-subtle"
                data-role="goals-coach-model"
              >
                {coach.model_label}
              </span>
            </span>
          </span>
          <span
            :if={coach.id == @selected_id}
            class="shrink-0 text-info"
            data-role="goals-coach-check"
          >
            <.icon name="hero-check-circle-solid" class="size-5" />
          </span>
        </button>
        <button
          :if={@hidden > 0}
          id={@id <> "-more"}
          type="button"
          phx-click={@more_event}
          data-role="goals-coach-more"
          class="focus-visible-ring flex min-h-11 cursor-pointer items-center justify-center gap-2 rounded-xl border border-dashed border-edge bg-base-200 p-3 text-sm text-subtle transition-colors lg:hover:text-base-content"
        >
          <.icon name="hero-chevron-down" class="size-4 shrink-0" />
          <span class="flex flex-col items-start">
            <span class="whitespace-nowrap">More coaches</span>
            <span class="font-mono text-[11px]">+{@hidden}</span>
          </span>
        </button>
      </div>
    </div>
    """
  end

  # More than 4 and collapsed: 3 cards, in list order, the selected one and
  # the pinned ones (the default; the goal page's current coach) always
  # among them; the rest fill up from the top.
  @doc false
  def visible_coaches(coaches, selected_id, expanded?, pin_ids \\ []) do
    if expanded? or length(coaches) <= 4 do
      {coaches, 0}
    else
      pin_ids = List.wrap(pin_ids)
      pinned = Enum.filter(coaches, &(&1.id in [selected_id | pin_ids]))
      keep = MapSet.new(Enum.take(pinned ++ (coaches -- pinned), 3), & &1.id)

      {Enum.filter(coaches, &MapSet.member?(keep, &1.id)), length(coaches) - 3}
    end
  end

  @doc """
  A number as the page shows it: thousands separators, no trailing decimal
  zeros. Takes a `Decimal` or an integer.

      iex> PlatformWeb.GoalsComponents.format_number(Decimal.new("1250.50"))
      "1,250.5"
  """
  @spec format_number(Decimal.t() | integer()) :: String.t()
  defdelegate format_number(n), to: Platform.Goals.NumberFormatting, as: :format
end
