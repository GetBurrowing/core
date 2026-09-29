defmodule PlatformWeb.Tasks.SortControl do
  @moduledoc """
  The board's sort control (task 01a0cef1 stage 2; design direction canvas
  `01a0cef3-293f-7001-832c-2bb28beacd2e`).

  Two render sites, one concern: the desktop toolbar (after
  `#tasks-scope-rail`, in `FiltersComponent`) and the mobile status-pill row
  (in `BoardComponent`). Both are in the DOM at once, so each carries its own
  `data-role` — `board-sort-control` and `mobile-board-sort-control` — and a
  shared role would make every selector ambiguous.

  ## Why it looks the way it does

    * **The label states the CURRENT order** — "Sort: Priority" or
      "Sort: Updated" — so nobody has to open it to learn what they are
      looking at. There is no asc/desc arrow: these are two named orders,
      not one axis with two directions.
    * **A button with a caret at `rounded-field`, not a pill.** Pills on this
      surface are filters, and a sort does not narrow the set.
    * **No `--color-primary`.** The board spends it on the active row and
      the primary action; a sort control is neither.

  ## Why there is no event

  The URL is the source of truth (`?sort=updated`, decoded by
  `TasksLive.handle_params/3`, mirroring `?sponsor=mine`). Each option is a
  `<.link patch>` whose href is `BoardData.tasks_path/1` (the map form —
  task 01a08df0 stage 1 added `?q=`/`?scope=` to the same builder, and a
  sort-mode click must carry the board's CURRENT search/scope forward
  rather than dropping them, per that builder's "no patch can drop a param"
  contract), so it is a real, shareable URL and the choice needs no
  `handle_event` anywhere.

  Opening and closing is client-only (`Phoenix.LiveView.JS`). The inner
  wrapper's id carries the current mode, so choosing the other option
  re-renders a fresh, closed menu instead of leaving the JS-toggled one open.

  A plain function component, not a LiveComponent, for the reason
  `PlatformWeb.Tasks.SettingsMenu` gives: it owns no state.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias PlatformWeb.Tasks.BoardData

  @labels %{priority: "Sort: Priority", updated: "Sort: Updated"}

  @doc "The visible label for a sort mode."
  @spec label(:priority | :updated) :: String.t()
  def label(mode), do: Map.fetch!(@labels, mode)

  attr :id, :string, required: true
  attr :role, :string, required: true, doc: "the control's data-role"
  attr :board_sort, :atom, default: :priority
  attr :sponsor_filter, :atom, default: :all
  # Task 01a08df0 stage 1: threaded through so a sort-mode click's patch
  # preserves the board's current search/scope instead of silently
  # clearing them (see the moduledoc's "Why there is no event" section).
  attr :task_search_query, :string, default: ""
  attr :scope_filter, :any, default: :all
  attr :mobile?, :boolean, default: false, doc: "44px touch target"
  attr :class, :string, default: nil

  def sort_control(assigns) do
    board_sort =
      if assigns.board_sort in BoardData.sort_modes(), do: assigns.board_sort, else: :priority

    inner_id = "#{assigns.id}-#{board_sort}"

    assigns =
      assign(assigns,
        board_sort: board_sort,
        inner_id: inner_id,
        trigger_id: "#{inner_id}-trigger",
        menu_id: "#{inner_id}-menu",
        options: Enum.map(BoardData.sort_modes(), &{&1, label(&1)})
      )

    ~H"""
    <div
      id={@id}
      data-role={@role}
      data-sort={@board_sort}
      class={["relative items-center", @class]}
    >
      <div
        id={@inner_id}
        class="contents"
        phx-click-away={close(@menu_id, @trigger_id)}
        phx-window-keydown={close(@menu_id, @trigger_id)}
        phx-key="Escape"
      >
        <button
          id={@trigger_id}
          type="button"
          aria-label="Change sort order"
          aria-haspopup="menu"
          aria-expanded="false"
          aria-controls={@menu_id}
          phx-click={
            JS.toggle(to: "##{@menu_id}", display: "flex")
            |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          }
          class={[
            "inline-flex items-center gap-1 whitespace-nowrap rounded-field border border-edge bg-base-200 text-xs font-medium text-base-content/60 transition-colors hover:bg-base-300 focus-visible-ring",
            if(@mobile?, do: "min-h-11 min-w-11 px-3", else: "h-7 px-2.5")
          ]}
        >
          <span>{label(@board_sort)}</span>
          <span class="hero-chevron-down size-3" aria-hidden="true"></span>
        </button>
        <div
          id={@menu_id}
          role="menu"
          aria-label="Sort order"
          class="absolute right-0 top-full z-40 mt-1 hidden min-w-40 flex-col rounded-field border border-edge bg-base-100 p-1 shadow-lg"
        >
          <.link
            :for={{mode, text} <- @options}
            patch={
              BoardData.tasks_path(%{
                sponsor_filter: @sponsor_filter,
                board_sort: mode,
                task_search_query: @task_search_query,
                scope_filter: @scope_filter
              })
            }
            role="menuitemradio"
            aria-checked={to_string(mode == @board_sort)}
            data-role="board-sort-option"
            data-sort={mode}
            class={[
              "flex items-center justify-between gap-3 rounded-field px-2.5 text-xs text-base-content/80 hover:bg-base-200",
              if(@mobile?, do: "min-h-11", else: "min-h-8"),
              mode == @board_sort && "font-semibold text-base-content"
            ]}
          >
            <span>{text}</span>
            <span :if={mode == @board_sort} class="hero-check size-3.5" aria-hidden="true"></span>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp close(menu_id, trigger_id) do
    JS.hide(to: "##{menu_id}")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "##{trigger_id}")
  end
end
