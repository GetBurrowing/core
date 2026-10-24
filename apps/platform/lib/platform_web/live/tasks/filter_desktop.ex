defmodule PlatformWeb.Tasks.FilterDesktop do
  @moduledoc """
  The desktop Tasks picker and filters (task 01a161fd stage 4, the designer's
  prototype canvas 01a16202 node `p`, Desktop mode): the project title menu
  under the title (320px, top-left) and the filter popover under Filter
  (400px, right-aligned), in the board's existing `page_header`, at `lg`
  only (`hidden lg:inline-flex` triggers). The old desktop controls stay.

  ## Shared, not duplicated

  The bodies are stage 3's `FilterSheets.project_picker/1`,
  `FilterSheets.filter_body/1` and `FilterSheets.filter_foot/1`; the triggers
  are `FilterBar.title_button/1` and `FilterBar.filter_button/1` in their
  `:desktop` variant. The open state is the same `@tasks_filter_sheet`
  assign (`PlatformWeb.Tasks.FilterHooks`), so the phone sheet and the
  desktop popover can never disagree.

  ## A styled div, not a browser popover and not a Sheet

  The shape mirrors the header create-menu in `tasks_live.html.heex`: a
  transparent fixed scrim (no dimming, no grab handle) that closes on click,
  `phx-window-keydown` with `phx-key="escape"`, and a card in `bg-base-100
  border-edge rounded-box` with `--shadow-dropdown`. Both close paths push
  `tasks_filter_close` and return focus to the trigger with `JS.focus/1`.

  Every option is still a plain `<.link patch>` with no `phx-click`. A project
  or epic pick closes the title menu; the filter popover stays open so its
  options apply live (`FilterHooks.after_patch/1`).

  ## The Project row (task 01a168c2)

  The filter popover hosts the project picker when opened from its Project
  row: `@tasks_filter_sheet` is `{:filter, inner}` and the popover renders
  `FilterSheets.project_picker/1` at `inner` (with Back to filter) in place
  of the filter body and footer. The title menu stays closed (its `open?` is
  `project_open?/1`), so the picker never jumps across the header. A pick
  returns the popover to the filter body; the scrim and Escape still close it
  and return focus to the Filter button.

  ## Hover

  Desktop option hover is plain CSS in app.css (`.tasks-filter-opt`,
  `.tasks-filter-tog` under `@media (hover: hover) and (min-width: 1024px)`).
  No `hover:` utility here or in the shared bodies.

  ## Called with the shell's assigns

  `tasks_live.html.heex` is budgeted (ADR 0050), so each popover takes the
  shell's assigns as one `shell` attr and reads what it needs here.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias PlatformWeb.Tasks.{FilterBar, FilterSheets}

  @title_id "tasks-title-picker-desktop"
  @filter_id "tasks-filter-button-desktop"

  @card "absolute top-full z-40 mt-2 flex max-h-[min(70vh,640px)] flex-col overflow-hidden rounded-box border border-edge bg-base-100"

  @doc "Push `tasks_filter_close` and return focus to `trigger` (a selector)."
  def close(trigger), do: "tasks_filter_close" |> JS.push() |> JS.focus(to: trigger)

  attr :shell, :map, required: true, doc: "the TasksLive assigns"

  @doc "The desktop title button and its project menu."
  def title_menu(assigns) do
    shell = assigns.shell
    sheet = shell[:tasks_filter_sheet]

    assigns =
      assigns
      |> assign(:open?, FilterSheets.project_open?(sheet))
      |> assign(:sheet, sheet)
      |> assign(:url, FilterBar.url_state(shell))
      |> assign(:project_label, FilterBar.title_project(shell))
      |> assign(:epic_label, FilterBar.title_epic(shell))
      |> assign(:close, close("##{@title_id}"))
      |> assign(:card, @card)

    ~H"""
    <div class="relative hidden lg:block">
      <FilterBar.title_button
        id={title_id()}
        variant={:desktop}
        project_label={@project_label}
        epic_label={@epic_label}
        expanded?={@open?}
        aria-controls="tasks-title-menu"
      />
      <.scrim :if={@open?} close={@close} />
      <div
        :if={@open?}
        id="tasks-title-menu"
        role="dialog"
        aria-label="Choose project"
        data-role="tasks-title-menu"
        class={[@card, "left-0 w-80 p-2"]}
        style="box-shadow: var(--shadow-dropdown);"
      >
        <div class="min-h-0 overflow-y-auto">
          <FilterSheets.project_picker
            sheet={@sheet}
            url={@url}
            projects={@shell[:projects] || []}
            drill_epics={@shell[:tasks_filter_epics] || []}
            mask_names?={@shell[:mask_names?] || false}
            mask_labels={@shell[:mask_labels] || %{}}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :shell, :map, required: true, doc: "the TasksLive assigns"

  @doc "The desktop Filter button, its badge and the filter popover."
  def filter_menu(assigns) do
    shell = assigns.shell
    url = FilterBar.url_state(shell)

    org_label =
      &FilterBar.org_label(
        shell[:mask_labels] || %{},
        shell[:mask_names?] || false,
        shell[:active_scopes] || [],
        &1
      )

    sheet = shell[:tasks_filter_sheet]

    assigns =
      assigns
      |> assign(:open?, FilterSheets.filter_open?(sheet))
      |> assign(:picker, FilterSheets.filter_picker(sheet))
      |> assign(:url, url)
      |> assign(:count, length(FilterBar.active_filters(url, org_label)))
      |> assign(:close, close("##{@filter_id}"))
      |> assign(:card, @card)

    ~H"""
    <div class="relative hidden lg:block">
      <FilterBar.filter_button
        id={filter_id()}
        variant={:desktop}
        count={@count}
        expanded?={@open?}
        aria-controls="tasks-filter-popover"
      />
      <.scrim :if={@open?} close={@close} />
      <div
        :if={@open?}
        id="tasks-filter-popover"
        role="dialog"
        aria-label="Filter and sort tasks"
        data-role="tasks-filter-popover"
        class={[@card, "right-0 w-[400px]"]}
        style="box-shadow: var(--shadow-dropdown);"
      >
        <div class={["min-h-0 overflow-y-auto px-4 pt-2", @picker && "pb-2"]}>
          <FilterSheets.project_picker
            :if={@picker}
            sheet={@picker}
            url={@url}
            projects={@shell[:projects] || []}
            drill_epics={@shell[:tasks_filter_epics] || []}
            mask_names?={@shell[:mask_names?] || false}
            mask_labels={@shell[:mask_labels] || %{}}
            back_to_filter?
          />
          <FilterSheets.filter_body
            :if={is_nil(@picker)}
            url={@url}
            active_scopes={@shell[:active_scopes] || []}
            project_label={FilterBar.title_project(@shell)}
            epic_label={FilterBar.title_epic(@shell)}
            mask_names?={@shell[:mask_names?] || false}
            mask_labels={@shell[:mask_labels] || %{}}
          />
        </div>
        <div :if={is_nil(@picker)} class="shrink-0 border-t border-edge bg-base-100 px-4 py-3">
          <FilterSheets.filter_foot
            url={@url}
            count={@shell[:filtered_count] || 0}
            on_show={@close}
          />
        </div>
      </div>
    </div>
    """
  end

  @doc "The desktop title button's DOM id (focus returns here)."
  def title_id, do: @title_id

  @doc "The desktop Filter button's DOM id (focus returns here)."
  def filter_id, do: @filter_id

  attr :close, :any, required: true

  # Transparent: the prototype's desktop menu has no dimming scrim. It only
  # catches the click-away and owns the Escape binding.
  defp scrim(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-30"
      data-role="tasks-filter-scrim"
      phx-click={@close}
      phx-window-keydown={@close}
      phx-key="escape"
      aria-hidden="true"
    >
    </div>
    """
  end
end
