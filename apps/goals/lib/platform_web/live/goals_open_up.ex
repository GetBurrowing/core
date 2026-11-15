defmodule PlatformWeb.GoalsOpenUp do
  @moduledoc "Privacy badge and audience sheet, using core's responsive Sheet."
  use Phoenix.Component
  import PlatformWeb.CoreComponents, only: [icon: 1]
  alias PlatformWeb.Components.Sheet

  def label(%{role: role, owner_name: owner}, _options) when role != :owner,
    do: "Shared by #{owner}"

  def label(%{audience: []}, _options), do: "Only you"

  def label(%{audience: audience}, options) do
    case audience do
      [%{type: :space, id: id, name: name}] ->
        if Enum.any?(options.spaces, &(&1.id == id and &1.detail == :agents)),
          do: "Shown in ##{name}",
          else: "Shared: #{name}"

      _ ->
        "Shared: " <> (audience |> Enum.sort_by(&rank(&1.type)) |> Enum.map_join(", ", & &1.name))
    end
  end

  defp rank(:user), do: 0
  defp rank(:team), do: 1
  defp rank(:space), do: 2

  attr :card, :map, required: true
  attr :options, :map, required: true

  def badge(assigns) do
    assigns =
      assign(assigns,
        label: label(assigns.card, assigns.options),
        shared?: assigns.card.role != :owner or assigns.card.audience != []
      )

    ~H"""
    <span class="priv inline-flex flex-wrap items-center gap-2" data-role="privacy-badge">
      <span class={["chip-soft", if(@shared?, do: "chip-success", else: "chip-neutral")]}>
        <.icon name={if @shared?, do: "hero-users", else: "hero-lock-closed"} class="size-3 shrink-0" />
        {@label}
      </span>
      <button
        :if={@card.role == :owner}
        type="button"
        phx-click="open_share"
        class="lnk rounded text-sm font-semibold text-interactive focus-visible-ring"
      >
        {if @shared?, do: "Change", else: "Open up"}
      </button>
    </span>
    """
  end

  def chip_class(selected),
    do: [
      "focus-visible-ring inline-flex min-h-8 items-center rounded-full border px-3 text-sm",
      if(selected,
        do: "border-transparent bg-base-300 text-base-content",
        else: "border-edge text-subtle lg:hover:text-base-content"
      )
    ]

  attr :card, :map, required: true
  attr :options, :map, required: true
  attr :tab, :string, required: true

  def audience_sheet(assigns) do
    {items, type, empty} =
      case assigns.tab do
        "teams" -> {assigns.options.teams, "team", "No teams to add yet"}
        "spaces" -> {assigns.options.spaces, "space", "No spaces to add yet"}
        _ -> {assigns.options.people, "user", "Nobody to add yet"}
      end

    assigns =
      assign(assigns,
        items: items,
        type: type,
        empty: empty,
        label: label(assigns.card, assigns.options)
      )

    ~H"""
    <Sheet.sheet
      id="goals-share-sheet"
      open
      placement={:right}
      on_close="close_share"
      class="share-sheet"
      aria-label="Who can see this goal"
      data-role="share-sheet"
    >
      <:title>Who can see this goal?</:title>
      <p class="text-sm text-subtle">
        Only you, by default. Anyone you add sees progress and check-ins. {if @card.coach_name,
          do: "Only you and #{@card.coach_name} can change the goal.",
          else: "Only you can change the goal."}
      </p>
      <div class="mt-4 flex flex-wrap gap-1.5" role="tablist" aria-label="Audience">
        <button
          :for={{tab, name} <- [{"people", "People"}, {"teams", "Team"}, {"spaces", "Space"}]}
          type="button"
          role="tab"
          aria-selected={to_string(@tab == tab)}
          phx-click="share_tab"
          phx-value-tab={tab}
          class={chip_class(@tab == tab)}
        >
          {name}
        </button>
      </div>
      <div class="opts mt-3">
        <p :if={@items == []} class="py-4 text-sm text-subtle">{@empty}</p>
        <button
          :for={item <- @items}
          type="button"
          role="checkbox"
          aria-checked={to_string(item.open?)}
          phx-click="toggle_audience"
          phx-value-type={@type}
          phx-value-id={item.id}
          class="flex min-h-[52px] w-full items-center gap-3 border-b border-edge py-3 text-left focus-visible-ring"
          data-audience-id={item.id}
        >
          <span class={[
            "flex size-5 shrink-0 items-center justify-center rounded border",
            if(item.open?, do: "border-primary bg-primary text-primary-content", else: "border-edge")
          ]}>
            <.icon :if={item.open?} name="hero-check" class="size-4" />
          </span>
          <span>
            <span class="block text-sm font-semibold text-base-content">
              {if @type == "space", do: "##{item.name}", else: item.name}
            </span>
            <span class="block text-xs text-subtle">{detail(@type, item)}</span>
          </span>
        </button>
      </div>
      <:actions>
        <span class="mr-auto text-xs text-subtle" data-role="share-footer">
          {if @label == "Only you", do: "Only you can see it", else: @label}
        </span>
        <button type="button" phx-click="share_done" class="btn btn-primary">Done</button>
      </:actions>
    </Sheet.sheet>
    """
  end

  defp detail("user", _), do: "Person"
  defp detail("team", item), do: "#{item.detail} people"
  defp detail("space", %{detail: :agents, name: name}), do: "Links the goal in ##{name}"
  defp detail("space", _), do: "The channel space"

  attr :toast, :map, required: true

  def toast(assigns) do
    ~H"""
    <div
      role="status"
      aria-live="polite"
      data-role="goal-toast"
      class="fixed bottom-[calc(env(safe-area-inset-bottom)+1.5rem+var(--bottom-nav-height,0px))] left-4 right-4 z-50 sm:left-auto sm:max-w-sm"
    >
      <div class="flex min-h-11 items-center gap-3 rounded-lg border border-edge bg-base-100 pl-4 pr-2 shadow-md">
        <p class="min-w-0 flex-1 text-sm text-base-content">{@toast.message}</p>
        <button
          :if={@toast.undo}
          type="button"
          phx-click="undo"
          class="focus-visible-ring min-h-11 shrink-0 rounded px-2 text-sm font-medium text-base-content"
        >
          Undo
        </button>
        <button
          type="button"
          phx-click="dismiss_toast"
          aria-label="Dismiss"
          class="focus-visible-ring rounded p-2 text-subtle"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end
end
