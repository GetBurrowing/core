defmodule PlatformWeb.Tasks.MyTasksList do
  @moduledoc """
  The phone Tasks tab's "my tasks" list (task 01a1557a-b20a stage 2,
  masters prototype 01a137f2 `master-mobile.html` v3 :26, :42-44, :274-280,
  :586-594).

  Renders `@filtered_tasks`, `BoardData.narrow_list/3` over the board's
  tasks with the URL filters (task 01a161fd stage 1), written by
  `PlatformWeb.Tasks.BoardHooks`, so the list follows every PubSub board
  event without a handler of its own. "Mine" is a filter (`?mine=1`), not the
  list's definition: the default is every task in every status, as in the
  designer's prototype (canvas 01a16202). The header, chips and sheets are
  `PlatformWeb.Tasks.FilterBar` and `FilterSheets` (stage 3). Below `lg` it
  is what /tasks shows at load. At `lg` and wider it is `display: none` and
  the desktop board is unchanged.

  ## Rows are plain patch links

  Each row is `<.link patch={~p"/tasks/<id>"}>` with no `phx-click`. A
  bare-string `phx-click` on a live link throws
  `TypeError: this[kind] is not a function` in the client, and a `JS.push` on
  a redirect link never reaches the server (both measured in rung 5).
  `TasksLive.handle_params/3` for `/tasks/:task_id` already does everything an
  open needs, including `Inbox.dismiss_sponsor_row_on_open/2`.

  ## The Board / list switch

  Today's phone board stays reachable through "Board" (rung 15 called it
  "All tasks"), because it is
  still the only phone path to the projects menu, create menu, filters, board
  and task gates (coverage rows 162-166), which have no phone design yet. The
  switch is a client-side class toggle on `#tasks-my-list`, `#tasks-main` and
  the create FAB (`#tasks-create-fab`). It adds no server event, assign,
  field or route. JS class ops are sticky across LiveView patches (the same
  mechanism `TaskDetailComponent` uses on `#tasks-mobile-list`), so the
  chosen view survives PubSub refreshes and opening or closing a task. A
  tab-bar navigate remounts the LiveView and lands on this list again.

  ## Rows only where the list can show (task 01a166be stage 3)

  `row_limit` (`FilterHooks`' `@tasks_my_list_limit`) caps the row links a
  join renders: none on a desktop join, the first screenful on a phone
  join, all when `nil`. The section, header, count and sheets render as
  always. `data-rows` says which (`none`, `some` or `all`), and the
  `TasksMyListRows` hook (`assets/js/hooks/tasks_my_list_rows.js`) asks
  for the rest when the `#tasks-my-list-more` sentinel nears the viewport
  or the window narrows below `lg`.

  ## States

  Row: default, pressed (`active:bg-base-100`) and focus-visible. There is
  NO hover state on the row or on either switch button: Saru's ruling on
  canvas 01a15db1 (rev 2 and later) rules hover out on phone-only lists,
  although the prototype shows one.

  The status dot (`StatusLabels.dot_class/1`) is decorative (`aria-hidden`). The status word on the meta
  line carries the same meaning in text, so the dot has no contrast floor
  (WCAG 1.4.11 applies to graphics required to understand the content).
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  alias Phoenix.LiveView.JS
  alias PlatformWeb.Tasks.FilterBar
  alias PlatformWeb.Tasks.FilterSheets
  alias PlatformWeb.Tasks.StatusLabels
  alias PlatformWeb.Tasks.TaskDisplay

  @board_ids "#tasks-main, #tasks-create-fab"

  @doc "JS that hides this list and shows today's phone board and its FAB."
  def show_board do
    "max-lg:hidden"
    |> JS.add_class(to: "#tasks-my-list")
    |> JS.remove_class("max-lg:hidden", to: @board_ids)
  end

  @doc "JS that hides the phone board and its FAB and shows this list."
  def show_mine do
    "max-lg:hidden"
    |> JS.add_class(to: @board_ids)
    |> JS.remove_class("max-lg:hidden", to: "#tasks-my-list")
  end

  attr :filtered_tasks, :list, required: true, doc: "BoardData.narrow_list/3 (stage 1)"
  attr :filtered_count, :integer, required: true

  attr :row_limit, :any,
    default: nil,
    doc: "@tasks_my_list_limit: rows to render, nil for all (0 on a desktop join)"

  attr :my_needs_you, :any, required: true
  attr :mask_names?, :boolean, default: false
  attr :mask_labels, :map, default: %{}
  attr :projects, :list, default: []
  attr :epics, :list, default: [], doc: "the selected project's epics"
  attr :active_scopes, :list, default: []
  attr :sheet, :any, default: nil, doc: "@tasks_filter_sheet"
  attr :drill_epics, :list, default: [], doc: "@tasks_filter_epics"
  # The URL state, read by `FilterBar.url_state/1` for every patch link.
  attr :selected_project_id, :any, default: nil
  attr :selected_epic_id, :any, default: nil
  attr :board_sort, :atom, default: PlatformWeb.Tasks.BoardData.default_sort()
  attr :status_filters, :list, default: []
  attr :kind_filters, :list, default: []
  attr :mine_filter, :boolean, default: false
  attr :sponsor_filter, :atom, default: :all
  attr :task_search_query, :string, default: ""
  attr :scope_filter, :any, default: :all
  attr :origin_filter, :any, default: :all

  def my_tasks_list(assigns) do
    url = FilterBar.url_state(assigns)

    org_label =
      &FilterBar.org_label(assigns.mask_labels, assigns.mask_names?, assigns.active_scopes, &1)

    filters = FilterBar.active_filters(url, org_label)

    assigns =
      assigns
      |> assign(:url, url)
      |> assign(:filters, filters)
      |> assign_rows()
      |> assign(:clear_href, FilterBar.clear_href(url))
      |> assign(:project_label, FilterBar.title_project(assigns))
      |> assign(:epic_label, FilterBar.title_epic(assigns))

    ~H"""
    <section
      id="tasks-my-list"
      data-role="tasks-my-list"
      phx-hook="TasksMyListRows"
      data-rows={@rows_state}
      class="lg:hidden flex min-h-0 min-w-0 flex-1 flex-col bg-base-200"
    >
      <div class="flex shrink-0 items-center pr-2">
        <FilterBar.header
          project_label={@project_label}
          epic_label={@epic_label}
          expanded?={FilterSheets.project_open?(@sheet)}
          count={length(@filters)}
        />
        <button
          type="button"
          data-role="tasks-show-board"
          phx-click={show_board()}
          class="inline-flex h-11 min-w-11 shrink-0 items-center justify-center rounded-field px-2 text-sm font-medium text-base-content active:bg-base-100 focus-visible-ring"
        >
          Board
        </button>
      </div>
      <FilterBar.search query={@task_search_query} />
      <FilterBar.chips board_sort={@board_sort} filters={@filters} clear_href={@clear_href} />
      <div class="flex-1 overflow-y-auto overscroll-contain clears-tab-bar">
        <div
          :if={@filtered_tasks == []}
          data-role="tasks-my-empty"
          class="px-6 py-10 text-center text-sm text-subtle"
        >
          <p>No tasks match these filters</p>
          <.link
            :if={@filters != []}
            patch={@clear_href}
            data-role="tasks-empty-clear"
            class="mt-1.5 inline-flex min-h-11 items-center text-sm font-medium text-base-content underline focus-visible-ring"
          >
            Clear all
          </.link>
        </div>
        <.link
          :for={task <- @rows}
          patch={~p"/tasks/#{task.id}"}
          data-role="tasks-my-row"
          data-row-task-id={task.id}
          class="flex min-h-14 items-start gap-3 rounded-box px-[18px] py-3 active:bg-base-100 focus-visible-ring"
        >
          <span
            :if={task.status != "in_progress"}
            data-role="tasks-my-dot"
            class={["mt-1.5 size-2.5 shrink-0 rounded-full", StatusLabels.dot_class(task.status)]}
            aria-hidden="true"
          >
          </span>
          <span class="min-w-0 flex-1">
            <%!-- No `block` here: Tailwind emits `.block` after `.line-clamp-2`,
                 so display: block would win and the clamp would not apply. --%>
            <b
              data-role="tasks-my-title"
              class="break-words text-[15px] font-semibold text-base-content line-clamp-2"
            >
              {task.title}
            </b>
            <PlatformWeb.ExecutionStatus.line
              :if={task.status == "in_progress"}
              status={Map.get(task, :execution_activity)}
            />
            <span class="flex min-w-0 gap-1 text-xs text-subtle">
              <span :if={task.status != "in_progress"} class="shrink-0">
                {StatusLabels.status_sentence(task.status)}
              </span>
              <%= if project = loaded_project(task) do %>
                <span aria-hidden="true">·</span>
                <span data-role="tasks-my-project" class="min-w-0 truncate">
                  {TaskDisplay.label_for(@mask_labels, @mask_names?, {:project, project.id},
                    real: project.name
                  )}
                  <%= if epic = loaded_epic(task) do %>
                    <span data-role="tasks-my-epic">
                      › {TaskDisplay.label_for(@mask_labels, @mask_names?, {:epic, epic.id},
                        real: epic.name
                      )}
                    </span>
                  <% end %>
                </span>
              <% end %>
            </span>
          </span>
          <span class="flex shrink-0 flex-col items-end gap-1">
            <span
              :if={MapSet.member?(@my_needs_you, task.id)}
              data-role="tasks-needs-you"
              class="whitespace-nowrap rounded-selector bg-warning px-2 py-0.5 text-xs font-medium text-warning-content"
            >
              Needs you
            </span>
            <span
              data-role="tasks-my-priority"
              class="whitespace-nowrap pt-0.5 text-xs font-semibold text-base-content"
            >
              {priority_word(task.priority)}
            </span>
          </span>
        </.link>
        <div
          :if={@rows_state == "some"}
          id="tasks-my-list-more"
          data-role="tasks-my-list-more"
          class="h-px"
          aria-hidden="true"
        >
        </div>
      </div>
      <FilterSheets.project_sheet
        sheet={@sheet}
        url={@url}
        projects={@projects}
        drill_epics={@drill_epics}
        mask_names?={@mask_names?}
        mask_labels={@mask_labels}
      />
      <FilterSheets.filter_sheet
        open?={FilterSheets.filter_open?(@sheet)}
        sheet={@sheet}
        url={@url}
        count={@filtered_count}
        active_scopes={@active_scopes}
        projects={@projects}
        drill_epics={@drill_epics}
        project_label={@project_label}
        epic_label={@epic_label}
        mask_names?={@mask_names?}
        mask_labels={@mask_labels}
      />
    </section>
    """
  end

  @doc "The priority word at a row's right: 'Critical', 'High', 'Medium', 'Low'."
  def priority_word(priority) when is_binary(priority), do: String.capitalize(priority)
  def priority_word(_priority), do: nil

  defp assign_rows(%{row_limit: limit, filtered_tasks: tasks} = assigns)
       when is_integer(limit) and length(tasks) > limit do
    assigns
    |> assign(:rows, Enum.take(tasks, limit))
    |> assign(:rows_state, if(limit == 0, do: "none", else: "some"))
  end

  defp assign_rows(assigns),
    do: assigns |> assign(:rows, assigns.filtered_tasks) |> assign(:rows_state, "all")

  defp loaded_epic(%{epic: %{id: _} = epic}), do: epic
  defp loaded_epic(_task), do: nil

  defp loaded_project(%{project: %{id: _} = project}), do: project
  defp loaded_project(_task), do: nil
end
