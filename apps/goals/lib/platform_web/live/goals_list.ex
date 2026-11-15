defmodule PlatformWeb.GoalsList do
  @moduledoc """
  The Goals list (task 01a1dfc1, Goals 4/8 stage 2), built to canvas
  01a15ef6 node `p` (prototype v4, screen `list`): the desktop list pane
  (`section.lpane[data-pane='goals']`, rows `li.brow`) and the phone list
  (`.app.ph .ph-head`, rows `button.prow`).

  Markup follows core's Inbox: the desktop pane is
  `PlatformWeb.InboxLive`'s 380px list column and the row is
  `PlatformWeb.Components.BriefingRow`'s recipe; the phone list is
  `PlatformWeb.Inbox.InboxList`'s header and row recipe, shown below `lg`.
  Those components take Inbox structs, so their class recipes are copied,
  not called.

  ## A row's copy

  `rows/2` turns `Platform.Goals.describe_goals/1` cards into rows. The
  number line is read through `Platform.Goals.goal_number/2`, once per row
  (Goals 2/8 offers no batch read). The target is the current stop's
  `target_value`, else the goal's; the unit is the goal's.

    * a reading and a target: "{latest} of {target} {unit}";
    * no reading (no source, an unknown source, a source that refuses, no
      reading yet) and a target: "Target: {target} {unit}", with no reading
      value and no reason text;
    * no target or no unit: "No number to follow yet", with the muted tile.

  A goal that stops being visible between the two reads (`{:error, _}`
  from `goal_number/2`) is dropped.
  """
  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Goals
  alias PlatformWeb.Components.InboxItem
  alias PlatformWeb.GoalsComponents

  # ── rows ───────────────────────────────────────────────────────────────

  @doc "The rows for `user`'s cards, in card order; unreadable goals dropped."
  @spec rows(term(), [map()]) :: [map()]
  def rows(user, cards) do
    Enum.flat_map(cards, fn card ->
      case Goals.goal_number(user, card.goal.id) do
        {:ok, number} -> [row(card, number)]
        _ -> []
      end
    end)
  end

  defp row(%{goal: goal} = card, number) do
    target = target(card)
    numberless? = is_nil(target) or blank?(goal.unit)
    reading = reading(number)

    %{
      id: goal.id,
      href: "/m/goals?goal=" <> goal.id,
      title: goal.title,
      numberless?: numberless?,
      kind: "Goal · " <> who(card),
      who: who(card),
      number_line: number_line(numberless?, reading, target, goal.unit),
      time: time(reading, goal),
      short_time: short_time(reading, goal),
      at: if(reading, do: reading.measured_at, else: goal.inserted_at),
      privacy: privacy(card)
    }
  end

  defp target(%{current_stop: %{target_value: %Decimal{} = t}}), do: t
  defp target(%{goal: %{target_value: %Decimal{} = t}}), do: t
  defp target(_card), do: nil

  defp reading({:reading, %{latest: latest}}), do: latest
  defp reading(_cannot_measure), do: nil

  defp number_line(true, _reading, _target, _unit), do: "No number to follow yet"

  defp number_line(false, nil, target, unit),
    do: "Target: #{GoalsComponents.format_number(target)} #{unit}"

  defp number_line(false, reading, target, unit),
    do:
      "#{GoalsComponents.format_number(reading.value)} of #{GoalsComponents.format_number(target)} #{unit}"

  # Kind line, without its "Goal · " prefix (the phone row's third line).
  defp who(%{role: :viewer, owner_name: owner}), do: "Shared by #{owner}"

  defp who(%{audience: [_ | _] = audience}),
    do: "Shared with " <> Enum.map_join(audience, ", ", & &1.name)

  defp who(%{coach_name: coach, goal: goal}) when is_binary(coach),
    do: "#{coach} #{coach_verb(goal.agent_mode)}"

  defp who(%{owner_name: owner}), do: first_name(owner)

  defp coach_verb("do"), do: "leads"
  defp coach_verb("coach"), do: "coaches"
  defp coach_verb(_advise), do: "advises"

  defp privacy(%{role: :viewer, owner_name: owner}),
    do: %{label: "Shared by #{owner}", shared?: true}

  defp privacy(%{audience: [_ | _] = audience}),
    do: %{label: "Shared: " <> Enum.map_join(audience, ", ", & &1.name), shared?: true}

  defp privacy(_card), do: %{label: "Only you", shared?: false}

  defp time(nil, goal), do: "Added " <> date(goal.inserted_at)
  defp time(reading, _goal), do: "Updated " <> InboxItem.relative_time(reading.measured_at)

  defp short_time(nil, goal), do: date(goal.inserted_at)
  defp short_time(reading, _goal), do: InboxItem.relative_time(reading.measured_at)

  defp date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d")

  defp first_name(name) when is_binary(name) do
    case String.split(name) do
      [first | _] -> first
      [] -> name
    end
  end

  defp blank?(value), do: is_nil(value) or String.trim(value) == ""

  # ── desktop ────────────────────────────────────────────────────────────

  @doc "The desktop list pane's content: header, rows or the empty state."
  attr :rows, :list, required: true
  attr :selected_id, :string, default: nil

  def desktop_list(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-6" data-pane="goals">
      <header class="mb-6 flex items-start justify-between gap-4">
        <div class="min-w-0">
          <h1 class="text-2xl font-bold text-base-content">Goals</h1>
          <p class="mt-1 text-sm text-subtle">
            What you're working towards, and how it's going. Only you see your goals until you open them up.
          </p>
        </div>
        <span data-goals-slot="new-goal" class="shrink-0"></span>
      </header>

      <.empty :if={@rows == []} />

      <ul :if={@rows != []} class="flex flex-col gap-2" data-role="goals-rows">
        <.desktop_row :for={row <- @rows} row={row} selected?={row.id == @selected_id} />
      </ul>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :selected?, :boolean, default: false

  defp desktop_row(assigns) do
    ~H"""
    <li
      class={[
        "group relative flex items-stretch rounded-2xl border border-edge transition-colors lg:hover:border-base-content/20",
        if(@selected?, do: "bg-base-100 lg:bg-base-300", else: "bg-base-100")
      ]}
      data-role="goals-row"
      data-goal-id={@row.id}
      data-selected={to_string(@selected?)}
      data-numberless={to_string(@row.numberless?)}
    >
      <span
        :if={@selected?}
        class="absolute inset-y-0 left-0 hidden w-1 rounded-l-2xl bg-primary lg:block"
        aria-hidden="true"
      >
      </span>
      <.link
        navigate={@row.href}
        class="flex min-w-0 flex-1 items-start gap-3 rounded-2xl py-3 pl-4 pr-4 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-2 focus-visible:ring-offset-base-100"
        aria-current={if(@selected?, do: "page")}
      >
        <GoalsComponents.flag_tile muted?={@row.numberless?} />
        <span class="min-w-0 flex-1">
          <span
            class="block truncate text-[11px] font-medium uppercase tracking-wide text-subtle"
            data-role="goals-row-kind"
          >
            {@row.kind}
          </span>
          <span
            class={[
              "mt-1 block truncate text-sm text-base-content",
              if(@row.numberless?, do: "font-normal", else: "font-semibold")
            ]}
            data-role="goals-row-title"
          >
            {@row.title}
          </span>
          <span class="mt-0.5 block text-sm tabular-nums text-subtle" data-role="goals-row-number">
            {@row.number_line}
          </span>
          <span class="mt-1 flex min-w-0 items-center gap-2 text-xs text-subtle">
            <time datetime={DateTime.to_iso8601(@row.at)} data-role="goals-row-time" class="shrink-0">
              {@row.time}
            </time>
            <GoalsComponents.privacy_chip privacy={@row.privacy} />
          </span>
        </span>
      </.link>
    </li>
    """
  end

  # ── phone ──────────────────────────────────────────────────────────────

  @doc """
  The phone list: `InboxList`'s 52px header and its row recipe. "Back to
  More" opens core's More sheet by clicking the bottom bar's More tab: the
  sheet's `open_more_sheet` event belongs to the parent page, which a
  nested LiveView cannot push to.
  """
  attr :rows, :list, required: true

  def phone_list(assigns) do
    ~H"""
    <section data-role="goals-phone" class="flex h-full min-h-0 flex-col bg-base-200 lg:hidden">
      <header class="flex h-13 shrink-0 items-center gap-2.5 px-4">
        <button
          type="button"
          phx-click={JS.dispatch("click", to: "[data-destination='more']")}
          aria-label="Back to More"
          data-role="goals-back"
          class="inline-flex size-11 shrink-0 items-center justify-center rounded-full text-subtle focus-visible-ring"
        >
          <.icon name="hero-chevron-left" class="size-[22px]" />
        </button>
        <h1 class="min-w-0 flex-1 truncate text-[17px] font-semibold text-base-content">Goals</h1>
        <span data-goals-slot="new-goal" class="shrink-0"></span>
      </header>
      <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain clears-tab-bar">
        <.empty :if={@rows == []} />
        <ul :if={@rows != []} role="list" data-role="goals-phone-rows">
          <li :for={row <- @rows}>
            <.phone_row row={row} />
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :row, :map, required: true

  defp phone_row(assigns) do
    ~H"""
    <.link
      navigate={@row.href}
      data-role="goals-phone-row"
      data-goal-id={@row.id}
      class="flex min-h-14 select-none items-center gap-3 rounded-box px-[18px] py-3 active:bg-base-100 focus-visible-ring"
    >
      <GoalsComponents.flag_tile size={:lg} muted?={@row.numberless?} />
      <span class="min-w-0 flex-1">
        <span class="flex items-baseline gap-2">
          <b class={[
            "min-w-0 flex-1 truncate text-[15px] text-base-content",
            if(@row.numberless?, do: "font-normal", else: "font-semibold")
          ]}>
            {@row.title}
          </b>
          <time
            datetime={DateTime.to_iso8601(@row.at)}
            class="shrink-0 whitespace-nowrap text-xs tabular-nums text-subtle"
          >
            {@row.short_time}
          </time>
        </span>
        <span class="mt-0.5 block text-sm tabular-nums text-base-content">{@row.number_line}</span>
        <span class="mt-0.5 flex min-w-0 items-center gap-1.5 text-xs text-subtle">
          <span class="truncate">{@row.who}</span>
          <GoalsComponents.privacy_chip privacy={@row.privacy} />
        </span>
      </span>
    </.link>
    """
  end

  # ── empty ──────────────────────────────────────────────────────────────

  defp empty(assigns) do
    ~H"""
    <div data-role="goals-empty">
      <PlatformWeb.Components.EmptyState.empty_state variant={:minimal}>
        <:body>
          <span class="block font-semibold" data-role="goals-empty-title">No goals yet</span>
          <span class="mt-1 block" data-role="goals-empty-body">
            Goals you create, and goals other people open up to you, show up here.
          </span>
        </:body>
      </PlatformWeb.Components.EmptyState.empty_state>
    </div>
    """
  end
end
