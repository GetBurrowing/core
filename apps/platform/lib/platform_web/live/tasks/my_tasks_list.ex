defmodule PlatformWeb.Tasks.MyTasksList do
  @moduledoc """
  The phone Tasks tab's "my tasks" list (task 01a1557a-b20a stage 2,
  masters prototype 01a137f2 `master-mobile.html` v3 :26, :42-44, :274-280,
  :586-594).

  Renders `@my_tasks` and `@my_needs_you`, both written by
  `PlatformWeb.Tasks.BoardHooks.refresh_board/1`, so the list follows every
  PubSub board event without a handler of its own. Below `lg` it is what
  /tasks shows at load. At `lg` and wider it is `display: none` and the
  desktop board is unchanged.

  ## Rows are plain patch links

  Each row is `<.link patch={~p"/tasks/<id>"}>` with no `phx-click`. A
  bare-string `phx-click` on a live link throws
  `TypeError: this[kind] is not a function` in the client, and a `JS.push` on
  a redirect link never reaches the server (both measured in rung 5).
  `TasksLive.handle_params/3` for `/tasks/:task_id` already does everything an
  open needs, including `Inbox.dismiss_sponsor_row_on_open/2`.

  ## The All tasks / My tasks switch

  Today's phone board stays reachable through "All tasks", because it is
  still the only phone path to the projects menu, create menu, filters, board
  and task gates (coverage rows 162-166), which have no phone design yet. The
  switch is a client-side class toggle on `#tasks-my-list`, `#tasks-main` and
  the create FAB (`#tasks-create-fab`). It adds no server event, assign,
  field or route. JS class ops are sticky across LiveView patches (the same
  mechanism `TaskDetailComponent` uses on `#tasks-mobile-list`), so the
  chosen view survives PubSub refreshes and opening or closing a task. A
  tab-bar navigate remounts the LiveView and lands on this list again.

  ## States

  Row: default, pressed (`active:bg-base-100`) and focus-visible. There is
  NO hover state on the row or on either switch button: Saru's ruling on
  canvas 01a15db1 (rev 2 and later) rules hover out on phone-only lists,
  although the prototype shows one.

  The status dot is decorative (`aria-hidden`). The status word on the meta
  line carries the same meaning in text, so the dot has no contrast floor
  (WCAG 1.4.11 applies to graphics required to understand the content).
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  alias Phoenix.LiveView.JS
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

  attr :my_tasks, :list, required: true
  attr :my_needs_you, :any, required: true
  attr :mask_names?, :boolean, default: false
  attr :mask_labels, :map, default: %{}

  def my_tasks_list(assigns) do
    ~H"""
    <section
      id="tasks-my-list"
      data-role="tasks-my-list"
      class="lg:hidden flex min-h-0 min-w-0 flex-1 flex-col bg-base-200"
    >
      <header class="flex h-13 shrink-0 items-center gap-2.5 px-4">
        <h1 class="min-w-0 flex-1 truncate text-[17px] font-semibold text-base-content">
          Tasks
          <span data-role="tasks-my-subtitle" class="block text-xs font-normal text-subtle">
            mine · {length(@my_tasks)} open
          </span>
        </h1>
        <button
          type="button"
          data-role="tasks-show-board"
          phx-click={show_board()}
          class="inline-flex h-11 min-w-11 shrink-0 items-center justify-center rounded-field px-3 text-sm font-medium text-base-content active:bg-base-100 focus-visible-ring"
        >
          All tasks
        </button>
      </header>
      <div class="flex-1 overflow-y-auto overscroll-contain clears-tab-bar">
        <p
          :if={@my_tasks == []}
          data-role="tasks-my-empty"
          class="px-6 py-10 text-center text-sm text-subtle"
        >
          No tasks assigned to you.
        </p>
        <.link
          :for={task <- @my_tasks}
          patch={~p"/tasks/#{task.id}"}
          data-role="tasks-my-row"
          data-task-id={task.id}
          class="flex min-h-14 items-start gap-3 rounded-box px-[18px] py-3 active:bg-base-100 focus-visible-ring"
        >
          <span
            data-role="tasks-my-dot"
            class={["mt-1.5 size-2.5 shrink-0 rounded-full", dot_class(task.status)]}
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
            <span class="flex min-w-0 gap-1 text-xs text-subtle">
              <span class="shrink-0">{status_word(task.status)}</span>
              <%= if project = loaded_project(task) do %>
                <span aria-hidden="true">·</span>
                <span data-role="tasks-my-project" class="min-w-0 truncate">
                  {TaskDisplay.label_for(@mask_labels, @mask_names?, {:project, project.id},
                    real: project.name
                  )}
                </span>
              <% end %>
            </span>
          </span>
          <span
            :if={MapSet.member?(@my_needs_you, task.id)}
            data-role="tasks-needs-you"
            class="shrink-0 self-start whitespace-nowrap rounded-selector bg-warning px-2 py-0.5 text-xs font-medium text-warning-content"
          >
            Needs you
          </span>
        </.link>
      </div>
    </section>
    """
  end

  @doc "The status word on the meta line: the board's label, lower-cased."
  def status_word(status), do: status |> StatusLabels.status_label() |> String.downcase()

  @doc """
  The status dot's slot (prototype `--active` / `--warning` / `--edge`). A
  status added later falls to the neutral edge slot.
  """
  def dot_class(status) when status in ~w(planning in_progress deploying), do: "bg-success"
  def dot_class(status) when status in ~w(in_review blocked), do: "bg-warning"
  def dot_class(_status), do: "bg-edge"

  defp loaded_project(%{project: %{id: _} = project}), do: project
  defp loaded_project(_task), do: nil
end
