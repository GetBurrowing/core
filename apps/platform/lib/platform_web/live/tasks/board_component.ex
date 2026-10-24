defmodule PlatformWeb.Tasks.BoardComponent do
  @moduledoc """
  The Tasks board itself — the epics strip, the mobile section list and the
  desktop kanban, plus the per-row task-actions sheet they open. Extracted
  from `PlatformWeb.TasksLive` by task 01a008f6 stage 7.

  ## Why a LiveComponent and not a LifecycleHook

  The stage-7 inventory filed the board as a LifecycleHook "because it is
  the page body". That is a rendering-POSITION fact, and ADR 0035's
  criterion is contiguity and self-containment, not position. The board's
  UI is one contiguous region (`tasks_live.html.heex` 215-1281 at
  `c1762b82`), so it is a component. Filing it as a hook would have left
  ~1,070 lines — the largest render region on the surface — in the shell
  template, which is the residual-concern shape task 01a008f6 exists to
  eliminate.

  The board's *subscriptions* genuinely cannot live here: PubSub delivers
  to the LiveView process, not to a component. Those, and the
  `refresh_board/1` they funnel through, are `PlatformWeb.Tasks.BoardHooks`
  — the hook/component pair `PlatformWeb.ChatLive.MeetingHooks` already
  established alongside its panel.

  ## Ownership

  Owns `:open_task_actions_id` (which row's action sheet is showing) and the
  Done column's render window, `:done_expanded?` and `:done_limit` (task
  01a13884 stage 3), and nothing else. Every board data map arrives as a
  read-only attr written by `BoardHooks`; the component never assigns one
  and never re-queries. Two
  outcomes are reported up rather than written:

    * `{:board_refresh_requested}` — after a drop or a promote
    * `{:board_flash, kind, message}` — every user-visible message

  ## Events

  `board_drop`, `board_promote_task`, `board_open_task_actions`,
  `board_close_task_actions`, plus the Done window's `board_toggle_done` and
  `board_done_more` (task 01a13884 stage 3). All are targeted at
  `#tasks-board`.

  ## The Done window (task 01a13884 stage 3)

  Done (which folds in cancelled) is most of a long-lived board: 1,150 of the
  1,363 tasks in the perf seed, and ~25 DOM nodes per card. It renders
  collapsed by default, at full column width with its full count in the
  header, and when opened shows the 20 most recently updated (there is no
  `completed_at` column), growing by 50 per "Show 50 more". Only the RENDER
  is windowed: the data assigns arrive whole, so counts, search and drops
  keep reading the full lists. An active search opens Done, so a found task
  is never behind the collapse. The `DoneColumnState` hook remembers the
  expansion per viewer through `client_state.js`.

  `select_task` and `select_task_and_delete` deliberately did NOT move.
  Both are pure navigation (`push_patch/2`), which the stage contract keeps
  in the shell — and `select_task` has two emitters OUTSIDE this component
  that push it untargeted: `PlatformWeb.PlanningStepExtension` (a shared
  function component, used on the board and elsewhere) and
  `StacksComponent`'s stack-panel member rows. Retargeting the board's own
  card clicks while those two kept pushing to the LiveView would have split
  one event across two owners. This is the same shared-component trap stage
  6 hit with `ScopePill`; here the resolution is to leave the event where
  both emitters already aim.

  ## Hook retargeting

  `kanban_drag_drop.js` pushed `kanban_drop` with `this.pushEvent`, which
  ignores `phx-target` and always lands on the parent LiveView. Moving the
  handler here without touching the hook would have killed drag-and-drop
  outright while every click path — and every `mix test` — stayed green.
  It now pushes `pushEventTo("#tasks-board", "board_drop", ...)`.

  `tasks_status_filter.js` also binds inside this region but targets
  `#tasks-filters` already (retargeted in stage 6); it is unchanged.
  """
  use PlatformWeb, :live_component

  alias Platform.Tasks
  alias Platform.Tasks.{Stack, Task}
  alias PlatformWeb.Tasks.BoardData
  alias PlatformWeb.Tasks.ExternalFeedbackComponents
  alias PlatformWeb.Tasks.Selection
  alias PlatformWeb.Tasks.SortControl

  import PlatformWeb.Tasks.StackStyles,
    only: [member_node_class: 1, member_parked_reason: 2, stack_member_action_label: 1]

  import PlatformWeb.Tasks.StatusLabels, only: [status_label: 1]

  import Platform.Tasks.StackGraph, only: [dep_annotation_text: 2, stack_position_glyph: 1]

  alias PlatformWeb.Tasks.TaskDisplay

  # The Done column's render window (task 01a13884 stage 3): first page and
  # step of "Show 50 more".
  @done_initial_limit 20
  @done_page_size 50

  import PlatformWeb.Tasks.TaskDisplay,
    only: [
      assignee_name: 2,
      deletable_task?: 1,
      priority_badge_class: 1,
      relative_time: 1,
      task_display_status: 2,
      unmet_dependency_count: 1
    ]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open_task_actions_id: nil,
       done_expanded?: false,
       done_limit: @done_initial_limit
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # The all-tasks scope is the ROOT org's slug, read once per component
    # from config or the root row (task 01a116de stage 3; a literal before).
    # `@board_scope` is what the column filters take: the root's chip is
    # the unfiltered board, so it maps onto `:all`.
    socket = assign_new(socket, :root_org_slug, fn -> Platform.Tenancy.root_org_slug() end)

    {:ok, assign(socket, :board_scope, board_scope(socket.assigns))}
  end

  defp board_scope(%{scope_filter: scope, root_org_slug: root})
       when is_binary(root) and scope == root,
       do: :all

  defp board_scope(%{scope_filter: scope}), do: scope
  defp board_scope(_assigns), do: :all

  # ── Events ─────────────────────────────────────────────────────────────

  @impl true
  # Open the per-row task-actions sheet (Sheet-based replacement for the
  # DaisyUI dropdown that was inert on mobile — task 019e0d4b stage 2).
  def handle_event("board_open_task_actions", %{"id" => task_id}, socket) do
    {:noreply, assign(socket, :open_task_actions_id, task_id)}
  end

  def handle_event("board_close_task_actions", _params, socket) do
    {:noreply, assign(socket, :open_task_actions_id, nil)}
  end

  # Done window (task 01a13884 stage 3). `"expanded"` sets the state
  # explicitly (the Show/Hide buttons and the `DoneColumnState` replay send
  # it); without it the event toggles. A change resets the window to its
  # first page and is pushed to the hook, which stores it per viewer.
  def handle_event("board_toggle_done", params, socket) do
    expanded? =
      case Map.get(params, "expanded") do
        value when value in [true, "true"] -> true
        value when value in [false, "false"] -> false
        _ -> not socket.assigns.done_expanded?
      end

    if expanded? == socket.assigns.done_expanded? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(done_expanded?: expanded?, done_limit: @done_initial_limit)
       |> push_event("done_column_changed", %{expanded: expanded?})}
    end
  end

  def handle_event("board_done_more", _params, socket) do
    {:noreply, assign(socket, :done_limit, socket.assigns.done_limit + @done_page_size)}
  end

  # Meeting-triage promotion (task 019f5e2b-8d29 stage 2 + M5b/019f6e2c
  # stage 2). Clears the `needs_promotion` flag on a filed-under-cap task
  # via `Platform.Tasks.promote/1` — the standard `update_task/2` broadcast
  # fires, so the kanban badge disappears without a full reload. When the
  # task was still in `backlog`, `promote/1` also transitions
  # `status: "planning"` atomically so the router dispatches a planner
  # without a second write — surface a `Promoted to planning` info flash iff
  # the status actually moved. Non-transition promotions (already in
  # planning, etc.) are silent — the badge disappearing is feedback enough.
  #
  # Guarded on `needs_promotion == true`: promoting an already-clear task is
  # a no-op (idempotent) and does not spam kanban subscribers with a
  # redundant `:task_updated`. Unknown ids surface a flash; non-flagged
  # tasks silently no-op (the button ought not to render, but this is
  # defense-in-depth against a stale client).
  def handle_event("board_promote_task", %{"id" => task_id}, socket) do
    case writable_record(socket, task_id) do
      nil ->
        send(self(), {:board_flash, :error, "Task not found."})

      %{needs_promotion: false} ->
        # Already promoted — refresh the board so a stale card that shipped
        # a lingering badge disappears.
        send(self(), {:board_refresh_requested})

      task ->
        case Tasks.promote(task, {:user, socket.assigns[:current_user_id]}) do
          {:ok, updated} ->
            send(self(), {:board_refresh_requested})
            maybe_flash_promotion_transition(task, updated)

          {:error, _changeset} ->
            send(self(), {:board_flash, :error, "Could not promote task."})
        end
    end

    {:noreply, socket}
  end

  # Kanban drag-and-drop. Pushed by `kanban_drag_drop.js` via
  # `pushEventTo("#tasks-board", ...)`.
  def handle_event("board_drop", %{"task_id" => task_id, "column" => column}, socket) do
    task = if Selection.permits?(socket, {:task, task_id}), do: Tasks.get_task_detail(task_id)

    if is_nil(task) do
      send(self(), {:board_flash, :error, "Task not found."})
    else
      # Thread the LiveView user actor into the drop so
      # `Tasks.require_approved_plan_for/3` inside `drop_task_to_column/3`
      # can fire the sponsor-bypass rule (ADR 0042 §sponsor-bypass, task
      # 019f6380).
      case Tasks.drop_task_to_column(task, column, {:user, socket.assigns[:current_user_id]}) do
        {:ok, _updated} ->
          send(
            self(),
            {:board_flash, :info, "Task moved to #{status_label(column_to_status(column))}."}
          )

          send(self(), {:board_refresh_requested})

        {:error, :unknown_column} ->
          send(self(), {:board_flash, :error, "Unknown column."})

        {:error, :invalid_drop} ->
          send(
            self(),
            {:board_flash, :error,
             "Cannot move task from #{status_label(task.status)} to #{status_label(column_to_status(column))}."}
          )

        {:error, :no_approved_plan} ->
          send(
            self(),
            {:board_flash, :error,
             "Cannot move task into #{status_label(column_to_status(column))}: no approved plan exists. Create and approve a plan first."}
          )

        {:error, reason} ->
          send(self(), {:board_flash, :error, "Move failed: #{inspect(reason)}"})
      end
    end

    {:noreply, socket}
  end

  # Only flash on an actual status change (backlog -> planning) so a
  # promote-in-planning is silent. The badge disappearing plus the kanban
  # card reflow is sufficient feedback for the flag-only case.
  defp maybe_flash_promotion_transition(%{status: same}, %{status: same}), do: :ok

  defp maybe_flash_promotion_transition(%{status: "backlog"}, %{status: "planning"}),
    do: send(self(), {:board_flash, :info, "Promoted to planning."})

  defp maybe_flash_promotion_transition(_before, _after), do: :ok

  defp column_to_status("backlog"), do: "backlog"
  defp column_to_status("in_progress"), do: "in_progress"
  defp column_to_status("in_review"), do: "in_review"
  defp column_to_status("deploying"), do: "deploying"
  defp column_to_status("done"), do: "done"
  defp column_to_status(_), do: "unknown"

  # ── Render ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <%!-- Done-column memory (task 01a13884 stage 3): replays a stored
           expansion on mount and stores every server-side change. --%>
      <div
        id="done-column-state"
        phx-hook="DoneColumnState"
        data-expanded={to_string(@done_expanded?)}
        hidden
      >
      </div>
      <%!-- External Feedback lane (task 01a11ec3 stage 4): a visible header
           while the board is narrowed to the persisted external origin. --%>
      <ExternalFeedbackComponents.lane_banner :if={@origin_filter == "external_feedback"} />
      <%!-- Epics above board --%>
      <div :if={@selected_project_id && @epics != []} class="px-4 pt-3" id="epics-section">
        <div class="flex items-center justify-between mb-2">
          <span class="text-xs font-semibold uppercase tracking-widest text-base-content">
            Epics
          </span>
          <button
            phx-click="sidebar_toggle_epics_panel"
            phx-target="#tasks-sidebar"
            class="btn btn-ghost btn-xs btn-square"
            aria-label={if @epics_collapsed, do: "Expand epics", else: "Collapse epics"}
            aria-expanded={if @epics_collapsed, do: "false", else: "true"}
          >
            <span class={"size-4 transition-transform #{if @epics_collapsed, do: "hero-chevron-down", else: "hero-chevron-up"}"}>
            </span>
          </button>
        </div>
        <div :if={!@epics_collapsed} class="flex gap-3 overflow-x-auto pb-2">
          <div
            :for={epic <- @epics}
            phx-click="sidebar_select_epic"
            phx-target="#tasks-sidebar"
            phx-value-id={epic.id}
            class={"card card-compact min-w-[180px] max-w-[220px] shrink-0 cursor-pointer border bg-base-100 shadow-sm transition-all hover:shadow-md #{if @selected_epic_id == epic.id, do: "border-primary ring-2 ring-primary", else: "border-edge"}"}
          >
            <div class="card-body gap-1 p-3">
              <div class="flex items-center justify-between gap-2">
                <%!-- The epic strip letters out of the SAME `@mask_labels` map
                     the breadcrumb reads (task 01a00cf1). An epic is an entity
                     with an id and a name — structurally a project — and this
                     card sits on the same screen as the breadcrumb one row
                     above it; masking one and not the other would show two
                     different names for one epic. Task TITLES on the cards
                     below are free text with no lookup table and stay real. --%>
                <h3 class="text-sm font-bold truncate">
                  {TaskDisplay.label_for(@mask_labels, @mask_names?, {:epic, epic.id},
                    real: epic.name
                  )}
                </h3>
                <span class={epic_status_badge_class(epic.status)}>{epic.status}</span>
              </div>
              <p :if={epic.description} class="text-xs text-subtle line-clamp-2">
                {epic.description}
              </p>
              <div class="flex items-center gap-2 mt-1 text-xs text-subtle">
                <span>{epic.task_count} tasks</span>
                <span class="text-success">{epic.done_count} done</span>
              </div>
              <div
                :if={Map.get(epic, :target_branch)}
                class="flex items-center gap-1 mt-1 text-xs text-info"
              >
                <span class="hero-code-bracket size-3"></span>
                <span class="truncate">{Map.get(epic, :target_branch)}</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Mobile task list — section-grouped vertical layout (audit 1B-USE-2).
         Replaces the horizontal kanban below md:. The kanban below this block
         is hidden on mobile via the same breakpoint, so desktop stays
         unchanged.

         Status-filter pill bar (design review, 2026-05-12) reuses the chat
         pills pattern of the time. Default-active = "in_progress" so users land
         on actionable work; previously the section iteration began at
         "Backlog" which buried in-progress work below the scroll fold. The
         @mobile_columns order (in_progress first) controls both the pill
         order and the rendered-section order — desktop @kanban_columns is
         unchanged. --%>
      <%!-- The inner scroll container (`flex-1 overflow-y-auto pb-24`)
         provides comfortable scroll-end padding so the last task isn't
         flush with the bottom-nav. The outer wrapper used to also carry
         pb-24 (pre-PR #334, when the shell wasn't properly bounded);
         that's now redundant and shows up as ~96px of empty space below
         the scroller.

         Hidden below `lg` while the detail panel is open by the panel's own
         `phx-mounted` / `phx-remove` JS commands in TaskDetailComponent
         (task 01a13884 stage 2), a class on THIS element only. It used to be
         `:if={!(@show_detail && @selected_task)}`, which unmounted the list
         on every click and re-sent all of it on close (57 KB on the seeded
         rig) and made every select and close re-render this component. A
         `data-*` attribute on the shell root with a `group-data-*` variant
         was measured first and rejected: toggling it cost ~140 ms of style
         recalculation per click on the 33,892-node board. --%>
      <div
        id="tasks-mobile-list"
        class="lg:hidden flex flex-1 flex-col overflow-hidden"
      >
        <%!-- T6 status-filter pill nav (PR #328). Counts are derived from
           `@board_items` so stack cards contribute to the per-pill
           total — `@columns` is task-only and would undercount.

           The row also carries the mobile sort control (task 01a0cef1
           stage 2), trailing and OUTSIDE the scrolling nav: the pills
           scroll, the sort never does, and an `overflow-x-auto` ancestor
           would clip its menu. --%>
        <div
          data-role="tasks-status-filter-row"
          class="flex items-center gap-2 pr-3 border-b border-base-content/10 shrink-0"
        >
          <nav
            id="tasks-status-filter-pills"
            phx-hook="TasksStatusFilter"
            class="flex min-w-0 flex-1 items-center gap-2 overflow-x-auto px-3 py-2"
            style="scrollbar-width: none; -webkit-overflow-scrolling: touch;"
            aria-label="Filter tasks by status"
          >
            <button
              :for={{col_key, col_label} <- @mobile_columns}
              type="button"
              phx-click="filter_by_status"
              phx-target="#tasks-filters"
              phx-value-status={col_key}
              aria-pressed={@active_status_filter == col_key}
              class={[
                "flex items-center gap-1.5 px-3 py-1.5 rounded-full whitespace-nowrap text-[13px] font-medium shrink-0 transition-all",
                "active:scale-[0.97] ease-[cubic-bezier(0.16,1,0.3,1)]",
                if @active_status_filter == col_key do
                  "bg-primary text-primary-content shadow-[0_0_16px_oklch(0.78_0.14_207_/_0.18)]"
                else
                  "bg-base-200 text-base-content border border-base-content/10 hover:bg-base-300"
                end
              ]}
            >
              <span class={["size-1.5 rounded-full", status_dot_class(col_key)]} aria-hidden="true">
              </span>
              {col_label}
              <span
                :if={length(Map.get(@board_items, col_key, [])) > 0}
                class={[
                  "inline-flex items-center justify-center min-w-[18px] h-[18px] rounded-full text-[10px] font-bold tabular-nums",
                  if(@active_status_filter == col_key,
                    do: "bg-primary-content/20 text-primary-content",
                    else: "bg-base-300 text-base-content"
                  )
                ]}
              >
                {length(Map.get(@board_items, col_key, []))}
              </span>
            </button>
          </nav>
          <SortControl.sort_control
            id="mobile-board-sort-control"
            role="mobile-board-sort-control"
            board_sort={@board_sort}
            sponsor_filter={@sponsor_filter}
            task_search_query={@task_search_query}
            scope_filter={@scope_filter}
            kind_filter={@kind_filter}
            origin_filter={@origin_filter}
            selected_project_id={@selected_project_id}
            selected_epic_id={@selected_epic_id}
            status_filters={@status_filters}
            kind_filters={@kind_filters}
            mine_filter={@mine_filter}
            mobile?={true}
            class="inline-flex shrink-0"
          />
        </div>

        <%!-- T7 mobile section list, rebased on top of T6's pill filter.
           Iterates `@mobile_columns` for ordering + only renders the
           active-filter section. Items come from `@board_items` so
           stack cards interleave with standalone tasks (ordered by
           `BoardData.sort_items/3` in `@board_sort`, priority first by
           default; ADR 0041, task 01a0cef1). Member rows inside a stack
           card stay in `stack_position` (dependency) order. Stack cards include the stage-3
           expansion contract (`stack-member-mobile-#{id}` rows + dep
           annotations). Empty-state checks also use `@board_items`. --%>
        <div class="flex-1 overflow-y-auto px-3 pb-24 clears-tab-bar">
          <div
            :for={{col_key, col_label} <- @mobile_columns}
            :if={@active_status_filter == col_key && Map.get(@board_items, col_key, []) != []}
            class="mt-4 first:mt-2"
          >
            <h2 class="text-xs font-semibold uppercase tracking-widest text-base-content mb-2 px-1 tabular-nums">
              {col_label} · {format_count(length(Map.get(@board_items, col_key, [])))}
            </h2>
            <div class="flex flex-col gap-2">
              <.mobile_board_item
                :for={
                  item <-
                    windowed_items(
                      Map.get(@board_items, col_key, []),
                      col_key,
                      true,
                      @done_limit,
                      @stack_board_data
                    )
                }
                :key={item.id}
                item={item}
                col_key={col_key}
                review_count={Map.get(@review_counts, item.id, 0)}
                assignee={assignee_identity(item, @users_by_id, @agents_by_id)}
                sponsor={sponsor_identity(item, @users_by_id)}
                data={stack_data(@stack_board_data, item)}
                member_review_counts={member_review_counts(@stack_board_data, item, @review_counts)}
                expanded?={MapSet.member?(@expanded_stacks, item.id)}
              />
              <.done_more_button
                :if={col_key == "done"}
                total={length(Map.get(@board_items, col_key, []))}
                limit={@done_limit}
                myself={@myself}
                role="done-more-mobile"
              />
            </div>
          </div>

          <%!-- With a search active, "no matching tasks" is the accurate
             message — "tap + to create one" would mislead. "Clear search"
             (task 01a08df0 stage 2) reuses the SAME `filter_search`
             Escape-clear path the search input's own Escape keydown fires
             (see filters_component.ex `filter_search` — a `%{"key" =>
             "Escape"}` param clears `:task_search_query` AND push_patches
             `?q=` out of the URL, per stage 1). No second clearing
             mechanism, no new empty-state design — same body copy, same
             `.empty_state` component, just a control added beside it. --%>
          <div
            :if={search_active?(@task_search_query) && empty_board?(@board_items)}
            data-role="search-empty-state-mobile"
          >
            <.empty_state variant={:minimal}>
              <:body>No matching tasks for "{@task_search_query}".</:body>
            </.empty_state>
            <div class="flex justify-center pb-3">
              <button
                type="button"
                phx-click="filter_search"
                phx-value-key="Escape"
                phx-target="#tasks-filters"
                class="btn btn-ghost btn-xs"
                data-role="clear-search"
              >
                Clear search
              </button>
            </div>
          </div>

          <.empty_state
            :if={!search_active?(@task_search_query) && empty_board?(@board_items)}
            variant={:minimal}
          >
            <:body>No tasks yet — tap the + button to create one.</:body>
          </.empty_state>

          <.empty_state
            :if={
              !empty_board?(@board_items) &&
                Map.get(@board_items, @active_status_filter, []) == []
            }
            variant={:minimal}
          >
            <:body>
              No tasks in {active_status_label(@active_status_filter, @mobile_columns)}.
            </:body>
          </.empty_state>
        </div>
      </div>

      <%!-- Kanban board (desktop, Stage 2 of Tasks v2 — 2026-05-19).
         7 columns: Backlog / Planning / In Progress / Blocked /
         In Review / Deploying / Done. Hidden below `lg` (1024px) — the
         pill-filtered mobile list above covers tablet + phone since 7
         columns don't fit comfortably under 1280px. At lg-1024 the
         board overflows horizontally; the user scrolls inside the
         board container.

         Items per column come from `desktop_column_items/5` which
         merges `@columns` (task-only, atom-keyed from
         `Platform.Tasks.list_by_status/1`) with
         `@desktop_stacks_by_column` (stack-only, string-keyed),
         interleaved per ADR 0041 and ordered by
         `BoardData.sort_items/3` in `@board_sort` (task 01a0cef1).

         Stage 3 (2026-05-19): `desktop_column_items_for_scope/6`
         wraps `desktop_column_items/5` with the active scope-rail
         selection (`@board_scope`) — `:all` and the root org's slug
         are passthrough today; the
         other four scopes render empty until `tasks.org_id` lands. --%>
      <%!-- Stage-2 of task 019f3f22 (ADR-0042 sponsor visibility):
         board-level custom empty state — shown ONLY when the
         "Sponsored by me" filter is active AND every kanban column
         resolves to zero items. Replaces the per-column generic
         "No tasks" empty states so the user sees a single, direct
         message ("You're not sponsoring any tasks currently") instead
         of seven small "No tasks" chips. The kanban board container
         below (`#kanban-board`) remains in the DOM either way so the
         `KanbanDragDrop` hook stays mounted — we render either the
         empty state OR the column list inside it. --%>
      <div
        id="kanban-board"
        phx-hook="KanbanDragDrop"
        data-board-target="#tasks-board"
        class="hidden lg:flex flex-1 gap-3 overflow-x-auto p-4"
      >
        <%!-- Search banner outranks the sponsor one: with a query active,
           "no matching tasks" is the accurate explanation for the empty
           board even if the sponsor filter is also on. --%>
        <div
          :if={
            search_active?(@task_search_query) and
              board_columns_empty?(
                @kanban_columns,
                @columns,
                @desktop_stacks_by_column,
                @board_scope
              )
          }
          data-role="search-empty-state"
          class="flex flex-1 flex-col items-center justify-center gap-3 py-16"
        >
          <.empty_state variant={:minimal}>
            <:body>No matching tasks for "{@task_search_query}".</:body>
          </.empty_state>
          <%!-- "Clear search" (task 01a08df0 stage 2): same `filter_search`
             Escape-clear path as the mobile empty state above and the
             search input's own Escape keydown — see that comment for the
             full reasoning. No copy-link/share control here, deliberately
             (design canvas 01a0ea77-4bef cut one; the URL is the whole
             sharing mechanism). --%>
          <button
            type="button"
            phx-click="filter_search"
            phx-value-key="Escape"
            phx-target="#tasks-filters"
            class="btn btn-ghost btn-sm"
            data-role="clear-search"
          >
            Clear search
          </button>
        </div>
        <div
          :if={
            @sponsor_filter == :mine and not search_active?(@task_search_query) and
              board_columns_empty?(
                @kanban_columns,
                @columns,
                @desktop_stacks_by_column,
                @board_scope
              )
          }
          data-role="sponsor-filter-empty-state"
          class="flex flex-1 items-center justify-center py-16"
        >
          <.empty_state variant={:minimal}>
            <:body>You're not sponsoring any tasks or stacks currently.</:body>
          </.empty_state>
        </div>
        <div
          :for={{col_key, col_label} <- @kanban_columns}
          :if={
            not ((@sponsor_filter == :mine or search_active?(@task_search_query)) and
                   board_columns_empty?(
                     @kanban_columns,
                     @columns,
                     @desktop_stacks_by_column,
                     @board_scope
                   ))
          }
          id={"column-#{col_key}"}
          data-column={col_key}
          class="flex w-56 min-w-[14rem] flex-shrink-0 flex-col rounded-box bg-base-200/50 transition-all duration-150"
        >
          <%!-- Column header --%>
          <div class="flex items-center justify-between px-3 py-2">
            <h2 class={"text-xs font-semibold uppercase tracking-wider #{column_header_class(col_key)}"}>
              {col_label}
            </h2>
            <div class="flex items-center gap-1">
              <button
                :if={
                  col_key == "done" and @done_expanded? and
                    not search_active?(@task_search_query)
                }
                type="button"
                phx-click="board_toggle_done"
                phx-value-expanded="false"
                phx-target={@myself}
                class="btn btn-ghost btn-xs"
                data-role="done-hide"
              >
                Hide
              </button>
              <span
                class="badge badge-ghost badge-xs tabular-nums"
                data-role={"column-count-#{col_key}"}
              >
                {format_count(
                  length(
                    desktop_column_items_for_scope(
                      @columns,
                      @desktop_stacks_by_column,
                      col_key,
                      @board_scope,
                      @board_sort,
                      @stack_board_data
                    )
                  )
                )}
              </span>
            </div>
          </div>

          <%!-- Board items (task cards + collapsed stack cards).
             Pattern-match on `item.__struct__`: %Platform.Tasks.Stack{}
             renders the new collapsed stack card; %Platform.Tasks.Task{}
             keeps the existing task card rendering. Stacks are NOT
             draggable (stack-level reordering is out of scope for T7) —
             only tasks carry `draggable="true"` and the KanbanDragDrop
             hook's drag handlers. --%>
          <div class="flex flex-1 flex-col gap-2 overflow-y-auto px-2 pb-2">
            <%!-- Done, collapsed (task 01a13884 stage 3): no cards in the
               DOM, only the opener. The column div above keeps
               `data-column`, so a drop onto it still lands. --%>
            <div
              :if={
                col_key == "done" and not done_open?(@done_expanded?, @task_search_query) and
                  desktop_column_items_for_scope(
                    @columns,
                    @desktop_stacks_by_column,
                    col_key,
                    @board_scope,
                    @board_sort,
                    @stack_board_data
                  ) != []
              }
              class="flex flex-1 flex-col items-center rounded-box bg-base-200 p-3"
              data-role="done-collapsed"
            >
              <button
                type="button"
                phx-click="board_toggle_done"
                phx-value-expanded="true"
                phx-target={@myself}
                class="btn btn-ghost btn-sm text-base-content"
                data-role="done-show"
              >
                Show done tasks
              </button>
            </div>
            <.desktop_board_item
              :for={
                item <-
                  windowed_items(
                    desktop_column_items_for_scope(
                      @columns,
                      @desktop_stacks_by_column,
                      col_key,
                      @board_scope,
                      @board_sort,
                      @stack_board_data
                    ),
                    col_key,
                    done_open?(@done_expanded?, @task_search_query),
                    @done_limit,
                    @stack_board_data
                  )
              }
              :key={item.id}
              item={item}
              review_count={Map.get(@review_counts, item.id, 0)}
              assignee={assignee_identity(item, @users_by_id, @agents_by_id)}
              assignee_name={assignee_name(item, @agent_names)}
              sponsor={sponsor_identity(item, @users_by_id)}
              data={stack_data(@stack_board_data, item)}
              member_review_counts={member_review_counts(@stack_board_data, item, @review_counts)}
              expanded?={MapSet.member?(@expanded_stacks, item.id)}
              myself={@myself}
              mask_labels={@mask_labels}
              mask_names?={@mask_names?}
            />
            <.done_more_button
              :if={col_key == "done" and done_open?(@done_expanded?, @task_search_query)}
              total={
                length(
                  desktop_column_items_for_scope(
                    @columns,
                    @desktop_stacks_by_column,
                    col_key,
                    @board_scope,
                    @board_sort,
                    @stack_board_data
                  )
                )
              }
              limit={@done_limit}
              myself={@myself}
              role="done-more"
            />

            <%!-- Per-column empty state. SPEC DEVIATION: spec §5.3 says
               :conversational with chips, but that's per-COLUMN here on a
               kanban with 4-5 columns — N Saru bubbles + chip pairs would
               clutter the board. :minimal keeps the column readable. The
               broader "no tasks anywhere" board-level conversational state
               is a separate concern that doesn't exist on this surface
               (no board-level @all_tasks == [] check); add later if the designer
               wants the V3 voice on the kanban-empty case. --%>
            <.empty_state
              :if={
                desktop_column_items_for_scope(
                  @columns,
                  @desktop_stacks_by_column,
                  col_key,
                  @board_scope,
                  @board_sort,
                  @stack_board_data
                ) == []
              }
              variant={:minimal}
            >
              <:body>No tasks</:body>
            </.empty_state>
          </div>
        </div>
      </div>
      <%!-- Per-row task-actions sheet (task 019e0d4b stage 2). Replaces the
           inert mobile DaisyUI dropdown that used to live inline in each task
           row. Single sheet, rendered once, only when @open_task_actions_id is
           set. It moved here with the card that opens it in stage 7 — leaving
           it in the shell would have split one two-event concern across two
           owners. `select_task_and_delete` inside it stays UNTARGETED: it is
           navigation (push_patch), which is the shell's. --%>
      <.sheet
        :if={@open_task_actions_id}
        id="task-actions-sheet"
        open={true}
        placement={:bottom}
        on_close="board_close_task_actions"
        on_close_target={@myself}
      >
        <:title>Task actions</:title>
        <div class="flex flex-col gap-1">
          <button
            type="button"
            phx-click="select_task_and_delete"
            phx-value-id={@open_task_actions_id}
            class="flex items-center gap-3 rounded-lg px-4 py-3 text-left text-error hover:bg-base-200 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-error/60"
          >
            <span class="hero-trash size-5"></span>
            <span class="font-medium">Delete task</span>
          </button>
        </div>
      </.sheet>
    </div>
    """
  end

  # ── Done window (task 01a13884 stage 3) ─────────────────────────────────

  # "Show 50 more (N older)" under an open Done list; renders nothing once
  # the window covers the whole column.
  attr :total, :integer, required: true
  attr :limit, :integer, required: true
  attr :myself, :any, required: true
  attr :role, :string, required: true

  defp done_more_button(assigns) do
    assigns = assign(assigns, :step, min(assigns.total - assigns.limit, @done_page_size))

    ~H"""
    <button
      :if={@total > @limit}
      type="button"
      phx-click="board_done_more"
      phx-target={@myself}
      class="btn btn-ghost btn-sm text-base-content"
      data-role={@role}
    >
      Show {@step} more ({format_count(@total - @limit)} older)
    </button>
    """
  end

  # A search opens Done: a found task must not sit behind the collapse.
  defp done_open?(expanded?, query), do: expanded? or search_active?(query)

  # Done renders most recently updated first, whatever `@board_sort` says,
  # and only `limit` of them; closed, it renders none. Other columns pass
  # through untouched.
  defp windowed_items(_items, "done", false, _limit, _stack_board_data), do: []

  defp windowed_items(items, "done", true, limit, stack_board_data) do
    items
    |> BoardData.sort_items(:updated, stack_board_data)
    |> Enum.take(limit)
  end

  defp windowed_items(items, _col_key, _open?, _limit, _stack_board_data), do: items

  # 1150 -> "1,150", for the tabular-nums column counts.
  defp format_count(n) when is_integer(n) and n >= 1000 do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_count(n), do: to_string(n)

  # ── Board cards (task 01a13884 stage 2) ─────────────────────────────────
  #
  # Each card body is a function component fed explicit, per-card attrs that
  # the `:for` generator computes, and the loops that render them are keyed
  # (`:key={item.id}`). Two measured reasons (stage 1 baseline, dad993a9):
  #
  #   * the desktop comprehension was tracked by INDEX, so a PubSub refresh
  #     that inserted a card into Done re-sent every Done card after the
  #     insertion point (1,756 KB of a 1,837 KB frame on the 1,363-task
  #     seed). Keyed, an insert sends the new entry plus moved indexes.
  #   * the mobile loop iterated a template local (`column_items`), which
  #     taints the comprehension, so every refresh re-sent the whole section
  #     (52 KB for a one-title rename).
  #
  # Nothing in these bodies binds a `<% x = ... %>` local: derived values are
  # computed in the component function, which only runs when one of the
  # card's own attrs changed.

  attr :item, :any, required: true
  attr :col_key, :string, required: true
  attr :review_count, :integer, default: 0
  attr :assignee, :any, default: nil
  attr :sponsor, :any, default: nil
  attr :data, :any, default: nil
  attr :member_review_counts, :map, default: %{}
  attr :expanded?, :boolean, default: false

  defp mobile_board_item(%{item: %Stack{}} = assigns) do
    ~H"""
    <.mobile_stack_card
      stack={@item}
      data={@data}
      sponsor={@sponsor}
      expanded?={@expanded?}
      member_review_counts={@member_review_counts}
    />
    """
  end

  defp mobile_board_item(assigns) do
    ~H"""
    <.mobile_task_card
      task={@item}
      col_key={@col_key}
      review_count={@review_count}
      assignee={@assignee}
      sponsor={@sponsor}
    />
    """
  end

  attr :item, :any, required: true
  attr :review_count, :integer, default: 0
  attr :assignee, :any, default: nil
  attr :assignee_name, :string, default: nil
  attr :sponsor, :any, default: nil
  attr :data, :any, default: nil
  attr :member_review_counts, :map, default: %{}
  attr :expanded?, :boolean, default: false
  attr :myself, :any, required: true
  attr :mask_labels, :map, default: %{}
  attr :mask_names?, :boolean, default: false

  defp desktop_board_item(%{item: %Stack{}} = assigns) do
    ~H"""
    <.desktop_stack_card
      stack={@item}
      data={@data}
      sponsor={@sponsor}
      expanded?={@expanded?}
      member_review_counts={@member_review_counts}
    />
    """
  end

  defp desktop_board_item(assigns) do
    ~H"""
    <.desktop_task_card
      task={@item}
      review_count={@review_count}
      assignee={@assignee}
      assignee_name={@assignee_name}
      sponsor={@sponsor}
      myself={@myself}
      mask_labels={@mask_labels}
      mask_names?={@mask_names?}
    />
    """
  end

  @empty_stack_data %{member_count: 0, dep_edge_count: 0, ready_count: 0, members: []}

  defp stack_data(stack_board_data, %Stack{id: id}),
    do: Map.get(stack_board_data, id, @empty_stack_data)

  defp stack_data(_stack_board_data, _task), do: nil

  # Only the counts a stack's member rows read, so a review on an unrelated
  # task does not re-render every stack card.
  defp member_review_counts(stack_board_data, %Stack{id: id}, review_counts) do
    ids = stack_board_data |> Map.get(id, @empty_stack_data) |> Map.get(:members, [])
    Map.take(review_counts, Enum.map(ids, & &1.id))
  end

  defp member_review_counts(_stack_board_data, _task, _review_counts), do: %{}

  attr :stack, Stack, required: true
  attr :data, :map, required: true
  attr :sponsor, :any, default: nil
  attr :expanded?, :boolean, default: false
  attr :member_review_counts, :map, default: %{}

  defp mobile_stack_card(assigns) do
    ~H"""
    <div
      data-stack-card="true"
      data-stack-id={@stack.id}
      data-expanded={if(@expanded?, do: "true", else: "false")}
      class="flex flex-col rounded-box border-l-4 border-violet-500 border border-edge bg-base-100"
    >
      <%!-- T8 stage 1: header opens the stack detail
         panel. Chevron is split into its own sibling
         button so the inline-expansion toggle remains
         reachable without bubbling through the panel
         opener (Discord "click thread to enter" pattern,
         Option A in the T8 dispatch). --%>
      <div class="relative flex min-w-0 items-stretch">
        <button
          type="button"
          phx-click="stack_open_detail"
          phx-target="#tasks-stacks"
          phx-value-id={@stack.id}
          data-role="stack-header"
          class="flex min-w-0 flex-1 flex-col gap-1.5 p-3 text-left transition-colors hover:bg-base-200/60 focus-visible-ring min-h-[44px]"
        >
          <div class="flex min-w-0 items-center gap-2 pr-7">
            <span
              class="hero-rectangle-stack size-4 shrink-0 text-violet-300"
              aria-hidden="true"
            >
            </span>
            <span class="text-[9px] font-semibold uppercase tracking-wider text-violet-300 shrink-0">
              Stack
            </span>
            <span class="ml-auto text-[10px] text-subtle font-medium whitespace-nowrap shrink-0">
              {@data.ready_count}/{@data.member_count} ready
            </span>
          </div>
          <h3 class="text-sm font-medium leading-snug truncate min-w-0">
            {@stack.name}
          </h3>
          <div class="flex min-w-0 items-center gap-1.5 text-[10px] text-subtle">
            <span class="bg-base-200 px-1.5 py-0.5 rounded whitespace-nowrap shrink-0">
              {@data.member_count} tasks
            </span>
            <span class="bg-base-200 px-1.5 py-0.5 rounded whitespace-nowrap shrink-0">
              {@data.dep_edge_count} dep edges
            </span>
            <%!-- Stage 4 of task 019f487e (ADR-0042 Decision 8):
               sponsor avatar mirrors desktop stack card. Absent
               sponsor renders nothing. No own-sponsorship ring
               affordance — the operator rejected it as always wrong. --%>
            <.human_avatar
              :if={@sponsor}
              name={@sponsor.name}
              avatar_url={@sponsor.avatar_url}
              seed={@sponsor.seed}
              size="xs"
              class="ml-auto size-4 shrink-0"
              title={"Sponsored by " <> @sponsor.name}
              data-role="stack-sponsor-avatar"
            />
          </div>
        </button>
        <button
          type="button"
          phx-click="stack_toggle_expand"
          phx-target="#tasks-stacks"
          phx-value-id={@stack.id}
          data-role="stack-chevron"
          aria-label="Toggle stack expansion"
          aria-expanded={if(@expanded?, do: "true", else: "false")}
          class="absolute right-0 top-0 flex h-11 w-9 items-center justify-center text-violet-300 transition-colors hover:bg-base-200/60 focus-visible-ring"
        >
          <span
            class={[
              "hero-chevron-down size-3 transition-transform",
              @expanded? && "rotate-180"
            ]}
            aria-hidden="true"
          >
          </span>
        </button>
      </div>
      <div
        :if={@expanded?}
        data-role="stack-members"
        data-stack-id={@stack.id}
        class="flex flex-col gap-1.5 px-3 pb-3 pl-4"
      >
        <.mobile_stack_member
          :for={member <- Enum.sort_by(@data.members, & &1.stack_position)}
          :key={member.id}
          member={member}
          members={@data.members}
          review_count={Map.get(@member_review_counts, member.id, 0)}
        />
      </div>
    </div>
    """
  end

  attr :member, Task, required: true
  attr :members, :list, required: true
  attr :review_count, :integer, default: 0

  defp mobile_stack_member(assigns) do
    reason = Tasks.needs_human_action_reason(assigns.member, assigns.review_count)
    dep_text = dep_annotation_text(assigns.member, assigns.members)
    {status_label, status_class} = task_display_status(assigns.member, reason)
    {action_label, action_reason_attr} = mobile_stack_member_action_label(reason)

    assigns =
      assign(assigns,
        dep_text: dep_text,
        parked_text: member_parked_reason(assigns.member.status, dep_text),
        status_label: status_label,
        status_class: status_class,
        action_label: action_label,
        action_reason_attr: action_reason_attr
      )

    ~H"""
    <%!-- Task 01a06df3 stage 3. Derived from data already in
       hand — `@member.status` plus the dep annotation computed
       on the line above — so this adds no query and no preload.
       Mutually exclusive with the dep annotation by
       construction: `member_parked_reason/2` returns nil
       whenever `@dep_text` is non-nil, so a member with
       real in-stack predecessors still renders the dep line and
       only that. --%>
    <%!-- Badges-for-tasks-that-need-feedback (task
       019e2c25 stage 4): mobile stack-member rows
       mirror the desktop stack-detail badge from
       stage 2 / mobile solo card from stage 3.
       Reuses `@review_counts` (the board-wide
       review_request count map populated in
       refresh_board/1, which already covers stack
       members because list_all_tasks/1 returns
       them) — same source as the mobile solo card.
       `:plans` is preloaded on members via
       list_stacks_with_members/1 so the
       `:plan_pending_review` branch resolves. --%>
    <%!-- One decider (task 01a01a4a stage 5): the status
       chip is keyed on the SAME resolved reason the
       action chip is, so the merge gate cannot be shown
       by one site while precedence has demoted it for
       the other. --%>
    <%!-- Post-rejection fix (stage 4): use
       `mobile_action_label/1` instead of
       `stack_member_action_label/1` so the
       `:plan_pending_review` branch does NOT
       render an action chip — the adjacent
       `task_display_status/2` "Plan Ready" status
       chip is the single signal. Other reasons
       still render the action chip. --%>
    <button
      type="button"
      id={"stack-member-mobile-#{@member.id}"}
      data-stack-member="true"
      data-member-id={@member.id}
      data-stack-position={@member.stack_position}
      phx-click="select_task"
      phx-value-id={@member.id}
      class="relative rounded border border-base-200/60 bg-base-100 py-3 pl-8 pr-2 text-left transition-colors hover:bg-base-200/60 min-h-[44px]"
    >
      <span class={[
        "absolute left-1 top-3 inline-flex size-5 items-center justify-center rounded-full text-[10px] font-semibold",
        member_node_class(@member.status)
      ]}>
        {stack_position_glyph(@member.stack_position)}
      </span>
      <div class="flex min-w-0 flex-col gap-1">
        <%!-- Task 01a08e0d stage 3, mobile half. Mirrors stage
           2's desktop restructure: the title used to share a
           `flex flex-wrap items-center gap-2` row with three
           shrink-0 siblings (the action badge, the
           planning-step marker and the status badge), so under
           `frontend/ui-ux.md`'s truncation rule the title
           (`flex-1 min-w-0 truncate`) yielded to them. Pulling
           the title onto its own full-width line and moving
           the three siblings into a second "meta" row beneath
           it stops them from competing with the title for
           space. `block w-full` replaces `flex-1` on the span
           because it is no longer a flex item — `truncate`
           needs a block-level box, which the flex-item context
           used to provide for free. Mobile carries one more
           shrink-0 sibling than desktop (the action badge),
           but every element on this line stays a `<span>`: this
           row IS a `<button>` on mobile, and a nested button is
           invalid HTML that browsers reparent. --%>
        <span
          class="block w-full min-w-0 truncate text-xs leading-snug"
          title={@member.title}
        >
          {@member.title}
        </span>
        <div class="flex flex-wrap items-center gap-2">
          <span
            class="badge badge-ghost badge-xs capitalize"
            data-role="task-kind-badge"
            data-task-kind={@member.kind}
          >
            {@member.kind}
          </span>
          <ExternalFeedbackComponents.trust_badge task={@member} />
          <span
            :if={@action_label}
            class="badge badge-warning badge-xs gap-1 whitespace-nowrap shrink-0"
            data-role="stack-member-mobile-action"
            data-action-reason={@action_reason_attr}
          >
            <span class="hero-eye size-3"></span>
            {@action_label}
          </span>
          <%!-- ADR-0046 member 8 (019f9b29-9c47) stage 3, mobile half.
             Same compact marker as the desktop member row; the
             `data-role` MUST differ because the two boards share
             ONE DOM (`lg:hidden` / `hidden lg:grid` — CSS
             visibility, not presence), so a shared value
             double-matches every selector. The component emits no
             `id` at all, so `data-role` is the only thing to
             split.
             It renders as a `<span>`, never a `<button>`: this
             row IS a `<button>` on mobile, and a nested button is
             invalid HTML that browsers reparent. --%>
          <.planning_step_extension
            task={@member}
            variant={:compact}
            data_role="mobile-stack-member-planning-step"
          />
          <span class={"#{@status_class} badge-xs whitespace-nowrap shrink-0"}>
            {@status_label}
          </span>
        </div>
      </div>
      <div
        :if={@dep_text}
        data-role="dep-annotation"
        class="mt-1 text-[10px] text-subtle"
      >
        <span class="text-violet-400" aria-hidden="true">↑</span>
        {@dep_text}
      </div>
      <%!-- Task 01a06df3 stage 3, mobile half. Shares ONE
         `data-role` with the desktop row below, matching the
         `dep-annotation` sibling directly above it rather than
         the planning-step marker's split-role convention: that
         component emits no `id`, whereas these rows do
         (`stack-member-mobile-<id>` vs `stack-member-<id>`), so a
         test can pin a surface through the row id and the two
         boards sharing one DOM costs nothing here.
         It is a `<div>` holding a `<span>`, never a `<button>`:
         this row IS a `<button>` on mobile, and a nested button
         is invalid HTML that browsers reparent. --%>
      <div
        :if={@parked_text}
        data-role="stack-member-parked-reason"
        class="mt-1 text-[10px] text-subtle"
      >
        <span class="hero-clock size-2.5 align-[-1px]" aria-hidden="true"></span>
        {@parked_text}
      </div>
    </button>
    """
  end

  attr :task, Task, required: true
  attr :col_key, :string, required: true
  attr :review_count, :integer, default: 0
  attr :assignee, :any, default: nil
  attr :sponsor, :any, default: nil

  defp mobile_task_card(assigns) do
    reason = Tasks.needs_human_action_reason(assigns.task, assigns.review_count)
    {status_label, status_class} = task_display_status(assigns.task, reason)
    {action_label, action_reason_attr} = mobile_stack_member_action_label(reason)

    assigns =
      assign(assigns,
        status_label: status_label,
        status_class: status_class,
        action_label: action_label,
        action_reason_attr: action_reason_attr
      )

    ~H"""
    <%!-- Post-rejection fix (stage 4): same doubled-chip
       pattern as the mobile stack-member row above —
       the `task_display_status/2` "Plan Ready" badge
       below already covers `:plan_pending_review`, so
       suppress the action chip there. --%>
    <%!-- ADR-0046 member 8 (019f9b29-9c47) stage 2, mobile half.
       Same wrapper shape as the desktop card. The `data-role`
       values MUST differ from the desktop ones: `frontend/ui-ux.md`
       records that the two boards share ONE DOM (`lg:hidden` /
       `hidden lg:grid` — CSS visibility, not presence), so a shared
       value double-matches every selector. The component emits no
       `id` at all, so only `data-role` needs splitting.
       The extension is a SIBLING of the card here too, which is what
       keeps it out of the mobile card's own `<button>` — a `<button>`
       inside a `<button>` is invalid HTML and browsers reparent it. --%>
    <div class="flex flex-col" data-role="mobile-task-card-group">
      <.planning_step_extension
        task={@task}
        data_role="mobile-planning-step-extension"
        class="min-h-[44px]"
      />
      <button
        type="button"
        phx-click="select_task"
        phx-value-id={@task.id}
        class={[
          "flex flex-col gap-1.5 rounded-box border border-edge bg-base-100 p-3 text-left transition-colors hover:bg-base-200/60 focus-visible-ring",
          PlanningStepExtension.visible?(@task) && "rounded-t-none"
        ]}
        data-task-id={@task.id}
      >
        <div class="flex items-start gap-2">
          <span
            class={[
              "mt-1.5 size-2 shrink-0 rounded-full",
              status_dot_class(@col_key)
            ]}
            aria-hidden="true"
          >
          </span>
          <span class="text-sm font-medium leading-snug flex-1">{@task.title}</span>
        </div>
        <div class="flex flex-wrap items-center gap-1.5 pl-4 text-xs text-subtle">
          <%= if @assignee do %>
            <%= if @assignee.type == :user do %>
              <.human_avatar
                name={@assignee.name}
                avatar_url={@assignee.avatar_url}
                seed={@assignee.seed}
                size="xs"
                class="size-4 shrink-0"
              />
            <% else %>
              <%!-- Mobile twin of the desktop assignee chip. Same
                 `size-4` wrapper the human branch beside it
                 uses. --%>
              <.agent_avatar
                name={@assignee.name}
                avatar_url={@assignee.avatar_url}
                size="xs"
                class="size-4 shrink-0"
              />
            <% end %>
            <span class="truncate">{@assignee.name}</span>
            <span aria-hidden="true">·</span>
          <% end %>
          <%!-- Sponsor chip (ADR 0042 stage 1). Only renders when
             `sponsor_user_id` is set — an absent sponsor is
             silent, not a noisy "Unsponsored" pill. No own-
             sponsorship ring affordance — the operator rejected it as
             always wrong (stage 4 rework). --%>
          <%= if @sponsor do %>
            <.human_avatar
              name={@sponsor.name}
              avatar_url={@sponsor.avatar_url}
              seed={@sponsor.seed}
              size="xs"
              class="size-4 shrink-0"
              title={"Sponsored by " <> @sponsor.name}
              data-role="sponsor-avatar"
            />
            <span class="truncate">{@sponsor.name}</span>
            <span aria-hidden="true">·</span>
          <% end %>
          <span :if={@task.inserted_at} class="whitespace-nowrap">
            {relative_time(@task.inserted_at)}
          </span>
          <span
            class="badge badge-ghost badge-xs capitalize"
            data-role="task-kind-badge"
            data-task-kind={@task.kind}
          >
            {@task.kind}
          </span>
          <ExternalFeedbackComponents.trust_badge task={@task} />
          <%!-- Badges-for-tasks-that-need-feedback (task
             019e2c25 stage 3): mobile solo task cards now
             render the same warning chip the stack-detail
             rows + desktop kanban surface. The status badge
             `task_display_status/2` is also rendered for the
             four "interesting" statuses so "Plan Ready"
             appears on mobile (previously hidden — that's
             why a pending-review plan was invisible on the
             mobile board). Mirrors the desktop kanban
             gating in tasks_live.html.heex line ~717-723. --%>
          <span
            :if={@task.status in ~w(blocked planning in_review deploying)}
            class={"#{@status_class} badge-xs"}
          >
            {@status_label}
          </span>
          <span
            :if={@action_label}
            class="badge badge-warning badge-xs gap-1"
            data-role="mobile-task-action"
            data-action-reason={@action_reason_attr}
          >
            <span class="hero-eye size-3"></span>
            {@action_label}
          </span>
        </div>
      </button>
    </div>
    """
  end

  attr :stack, Stack, required: true
  attr :data, :map, required: true
  attr :sponsor, :any, default: nil
  attr :expanded?, :boolean, default: false
  attr :member_review_counts, :map, default: %{}

  defp desktop_stack_card(assigns) do
    ~H"""
    <%!-- Collapsed stack card. Purple violet-500 left border
       accent matches mock canvas 019e1a16 rev 2
       (`--stk: #7b5cff`). Clicking the HEADER toggles
       `:expanded_stacks` MapSet membership; the
       expansion render is a sibling block so member
       clicks do NOT bubble back into the toggle handler
       (stage 3 §5). --%>
    <div
      id={"stack-card-#{@stack.id}"}
      data-stack-card="true"
      data-stack-id={@stack.id}
      data-expanded={if(@expanded?, do: "true", else: "false")}
      class="group card card-compact border-l-4 border-violet-500 border border-edge bg-base-100 shadow-sm transition-all hover:shadow-md"
    >
      <%!-- T8 stage 1: header opens the stack detail panel.
         Chevron is split into its own SIBLING button so
         the inline-expansion toggle remains reachable
         without bubbling through the panel opener
         (Discord "click thread to enter" pattern, Option A
         in the T8 dispatch).

         The separation is structural, not defensive: the
         chevron and `[data-role=stack-header]` are both
         direct children of the `div.relative` below, so a
         chevron click never traverses the header at all.
         No ancestor of the chevron carries a phx-click or
         any JS click/pointer listener (KanbanDragDrop
         binds drag events only; nothing in assets/js
         references stack-card / stack-header /
         stack-chevron).

         Do NOT "protect" the chevron with an inline
         `onclick="event.stopPropagation()"`. There is
         nothing to protect it from, and the two cannot
         coexist: LiveView binds its click handler in the
         BUBBLE phase on `window` (live_socket.js
         bindClick/2), so an inline onclick — which runs at
         TARGET phase — stops the event before LiveView
         ever sees it and silently kills this phx-click.
         That is exactly what shipped here and went
         unnoticed for two months (task 019fa298); the
         mobile chevron, which never had one, kept working.
         Guarded by test/platform_web/inline_onclick_guard_test.exs. --%>
      <div class="relative">
        <div
          class="card-body cursor-pointer gap-1.5 p-3 pr-9"
          phx-click="stack_open_detail"
          phx-target="#tasks-stacks"
          phx-value-id={@stack.id}
          data-role="stack-header"
        >
          <%!-- Header row: icon + STACK tag + rollup progress --%>
          <div class="flex min-w-0 items-center gap-1.5">
            <span
              class="hero-rectangle-stack size-4 shrink-0 text-violet-300"
              aria-hidden="true"
            >
            </span>
            <span class="text-[9px] font-semibold uppercase tracking-wider text-violet-300 shrink-0">
              Stack
            </span>
            <span class="ml-auto text-[10px] text-subtle font-medium whitespace-nowrap shrink-0">
              {@data.ready_count}/{@data.member_count} ready
            </span>
          </div>

          <%!-- Title row --%>
          <h3 class="text-sm font-medium leading-snug truncate min-w-0">
            {@stack.name}
          </h3>

          <%!-- Pills row: member count + dep edge count + optional
             sponsor avatar (Stage 4 of task 019f487e —
             ADR-0042 Decision 8). Mirrors the task-card
             sponsor chip: absent sponsor renders nothing.
             No own-sponsorship ring affordance — the operator
             rejected it as always wrong (stage 4 rework). --%>
          <div class="flex min-w-0 items-center gap-1.5 text-[10px] text-subtle">
            <span class="bg-base-200 px-1.5 py-0.5 rounded font-medium whitespace-nowrap shrink-0">
              {@data.member_count} tasks
            </span>
            <span class="bg-base-200 px-1.5 py-0.5 rounded font-medium whitespace-nowrap shrink-0">
              {@data.dep_edge_count} dep edges
            </span>
            <.human_avatar
              :if={@sponsor}
              name={@sponsor.name}
              avatar_url={@sponsor.avatar_url}
              seed={@sponsor.seed}
              size="xs"
              class="ml-auto size-4 shrink-0"
              title={"Sponsored by " <> @sponsor.name}
              data-role="stack-sponsor-avatar"
            />
          </div>
        </div>
        <button
          type="button"
          phx-click="stack_toggle_expand"
          phx-target="#tasks-stacks"
          phx-value-id={@stack.id}
          data-role="stack-chevron"
          aria-label="Toggle stack expansion"
          aria-expanded={if(@expanded?, do: "true", else: "false")}
          class="absolute right-1 top-2 flex h-9 w-7 items-center justify-center text-violet-300 hover:bg-base-200 rounded transition-colors focus-visible-ring"
        >
          <span
            class={[
              "hero-chevron-down size-3 transition-transform",
              @expanded? && "rotate-180"
            ]}
            aria-hidden="true"
          >
          </span>
        </button>
      </div>

      <%!-- Inline expansion — members rendered indented
         below the header when this stack id is in
         `:expanded_stacks`. Each row is its own
         `phx-click="select_task"` target reusing the
         task detail-panel handler (T8 will later add a
         stack-level detail panel for header clicks). --%>
      <div
        :if={@expanded?}
        data-role="stack-members"
        data-stack-id={@stack.id}
        class="flex flex-col gap-1.5 px-3 pb-3 pl-4"
      >
        <.desktop_stack_member
          :for={member <- Enum.sort_by(@data.members, & &1.stack_position)}
          :key={member.id}
          member={member}
          members={@data.members}
          review_count={Map.get(@member_review_counts, member.id, 0)}
        />
      </div>
    </div>
    """
  end

  attr :member, Task, required: true
  attr :members, :list, required: true
  attr :review_count, :integer, default: 0

  defp desktop_stack_member(assigns) do
    reason = Tasks.needs_human_action_reason(assigns.member, assigns.review_count)
    dep_text = dep_annotation_text(assigns.member, assigns.members)
    {status_label, status_class} = task_display_status(assigns.member, reason)

    assigns =
      assign(assigns,
        dep_text: dep_text,
        parked_text: member_parked_reason(assigns.member.status, dep_text),
        status_label: status_label,
        status_class: status_class
      )

    ~H"""
    <%!-- One decider (task 01a01a4a stage 5): resolve the
       human-action reason from `@review_counts` — the same
       map the review badge reads — and key the status chip
       on it, so a member whose merge gate is outranked by a
       live review request shows the review mark only. --%>
    <%!-- Task 01a06df3 stage 3, desktop half. Same derivation as
       the mobile row: status + the dep annotation already computed
       on the line above, no extra query. --%>
    <div
      id={"stack-member-#{@member.id}"}
      data-stack-member="true"
      data-member-id={@member.id}
      data-stack-position={@member.stack_position}
      phx-click="select_task"
      phx-value-id={@member.id}
      class="relative cursor-pointer rounded border border-base-200/60 bg-base-100 py-2 pl-8 pr-2 transition-colors hover:bg-base-200/60 min-h-[44px]"
    >
      <span class={[
        "absolute left-1 top-2 inline-flex size-5 items-center justify-center rounded-full text-[10px] font-semibold",
        member_node_class(@member.status)
      ]}>
        {stack_position_glyph(@member.stack_position)}
      </span>
      <div class="flex min-w-0 flex-col gap-1">
        <%!-- Task 01a08e0d stage 2, desktop half. The title used to
           share a `flex items-center gap-2` row with the compact
           planning-step marker and the status badge — both
           `shrink-0`, so under `frontend/ui-ux.md`'s truncation
           rule the title (`flex-1 min-w-0 truncate`) yielded to
           them and a long title rendered as ~38px of usable width,
           a redaction rather than a truncation. Pulling the title
           onto its own full-width line and moving the marker +
           badge into a second "meta" row beneath it stops the
           shrink-0 siblings from competing with the title for
           space. `block w-full` replaces `flex-1` on the span
           because it is no longer a flex item — `truncate`
           (overflow:hidden + text-overflow:ellipsis) needs a
           block-level box to take effect, which the flex-item
           context used to provide for free. --%>
        <span
          class="block w-full min-w-0 truncate text-xs leading-snug"
          title={@member.title}
        >
          {@member.title}
        </span>
        <div class="flex items-center gap-2">
          <span
            class="badge badge-ghost badge-xs capitalize"
            data-role="task-kind-badge"
            data-task-kind={@member.kind}
          >
            {@member.kind}
          </span>
          <ExternalFeedbackComponents.trust_badge task={@member} />
          <%!-- ADR-0046 member 8 (019f9b29-9c47) stage 3, desktop half.
             COMPACT, not the fused strip: this row is a ~44px line
             already carrying a position glyph, a truncated title, a
             status badge and a dependency annotation, so the marker
             is a single icon INSIDE the badge cluster rather than a
             band above the row (a band would overlap the absolutely
             positioned glyph at `left-1 top-2`).
             `variant={:compact}` is failure-only — `failed` and
             member 7's `no_ui_surface_contradicted`. `complete` and
             the active cursor are suppressed here and remain on the
             member's own detail panel; a fifth chip on every row of
             every expanded stack is the noise that gets a feature
             turned off. --%>
          <.planning_step_extension
            task={@member}
            variant={:compact}
            data_role="stack-member-planning-step"
          />
          <span class={"#{@status_class} badge-xs whitespace-nowrap shrink-0"}>
            {@status_label}
          </span>
        </div>
      </div>
      <div
        :if={@dep_text}
        data-role="dep-annotation"
        class="mt-1 text-[10px] text-subtle"
      >
        <span class="text-violet-400" aria-hidden="true">↑</span> {@dep_text}
      </div>
      <%!-- Task 01a06df3 stage 3, desktop half. See the mobile
         row for why the `data-role` is shared across surfaces. --%>
      <div
        :if={@parked_text}
        data-role="stack-member-parked-reason"
        class="mt-1 text-[10px] text-subtle"
      >
        <span class="hero-clock size-2.5 align-[-1px]" aria-hidden="true"></span>
        {@parked_text}
      </div>
    </div>
    """
  end

  attr :task, Task, required: true
  attr :review_count, :integer, default: 0
  attr :assignee, :any, default: nil
  attr :assignee_name, :string, default: nil
  attr :sponsor, :any, default: nil
  attr :myself, :any, required: true
  attr :mask_labels, :map, default: %{}
  attr :mask_names?, :boolean, default: false

  defp desktop_task_card(assigns) do
    reason = Tasks.needs_human_action_reason(assigns.task, assigns.review_count)
    {status_label, status_class} = task_display_status(assigns.task, reason)

    assigns =
      assign(assigns,
        status_label: status_label,
        status_class: status_class,
        progress: plan_progress(assigns.task)
      )

    ~H"""
    <%!-- ADR-0046 member 8 (019f9b29-9c47) stage 2: the planning-step
       extension is a SIBLING of the card inside a zero-gap
       `flex flex-col` wrapper, not a child of it. Two reasons, both
       load-bearing:
       1. The column container is `flex flex-1 flex-col gap-2`, so an
       unwrapped sibling would sit 0.5rem above the card and read as
       a separate object. The wrapper makes that gap structurally
       zero without a `-mb-2` magic number coupled to the column's
       spacing token.
       2. The wrapper carries NO `data-task-id`. `kanban_drag_drop.js`
       resolves the drag source with `e.target.closest("[data-task-id]")`;
       the card keeps the attribute and stays the drag source, and a
       drag begun on the extension resolves to `null` so the hook
       no-ops. Putting `data-task-id` here would fade the wrong
       element on drag.
       `rounded-t-none` is conditional on `visible?/1` so a task with
       nothing to show renders a byte-identical card to before. --%>
    <div class="flex flex-col" data-role="task-card-group">
      <.planning_step_extension task={@task} data_role="planning-step-extension" />
      <div
        id={"task-card-#{@task.id}"}
        data-task-id={@task.id}
        draggable="true"
        class={[
          "group card card-compact cursor-grab border border-edge bg-base-100 shadow-sm transition-all hover:shadow-md active:cursor-grabbing",
          PlanningStepExtension.visible?(@task) && "rounded-t-none"
        ]}
        phx-click="select_task"
        phx-value-id={@task.id}
      >
        <div class="card-body gap-1 p-3">
          <%!-- Project name --%>
          <p
            :if={@task.project}
            class="text-[10px] font-medium uppercase tracking-wider text-subtle"
          >
            {TaskDisplay.label_for(@mask_labels, @mask_names?, {:project, @task.project.id},
              real: @task.project.name
            )}
          </p>

          <%!-- Title row --%>
          <%!--
             v2 stage 3: kanban-card title is plain text. Clicking it
             bubbles to the card's outer `phx-click="select_task"` and
             opens the detail panel, where the title can be edited via
             the explicit edit-mode toggle.
             --%>
          <div class="flex items-start justify-between gap-2">
            <h3
              id={"card-title-#{@task.id}"}
              class="text-sm font-medium leading-snug flex-1"
              data-role="card-title"
            >
              {@task.title}
            </h3>
            <div class="flex items-center gap-1 flex-shrink-0">
              <%!-- Assignee --%>
              <%= if @assignee do %>
                <%= if @assignee.type == :user do %>
                  <.human_avatar
                    name={@assignee.name}
                    avatar_url={@assignee.avatar_url}
                    seed={@assignee.seed}
                    size="xs"
                    class="shrink-0"
                    title={@assignee.name}
                  />
                <% else %>
                  <%!-- An agent assigned to a task is an agent
                     appearing, so it gets the same face it has in
                     chat and in meetings. The accent ring rides on
                     the component's outer wrapper, which is
                     `rounded-full`, so it survives an image
                     avatar exactly as `.msg-agent-avatar` does. --%>
                  <.agent_avatar
                    name={@assignee.name}
                    avatar_url={@assignee.avatar_url}
                    size="xs"
                    class="shrink-0 ring-1 ring-accent/20"
                    title={@assignee.name}
                  />
                <% end %>
              <% end %>
              <%!-- Sponsor chip (ADR 0042 stage 1). Absent sponsor
                 renders nothing. No own-sponsorship ring
                 affordance — the operator rejected it as always wrong
                 (stage 4 rework). Mirrors the mobile chip shape. --%>
              <.human_avatar
                :if={@sponsor}
                name={@sponsor.name}
                avatar_url={@sponsor.avatar_url}
                seed={@sponsor.seed}
                size="xs"
                class="shrink-0"
                title={"Sponsored by " <> @sponsor.name}
                data-role="sponsor-avatar"
              />
              <%!-- Three-dot menu — opens a bottom sheet on mobile + a centered
                 sheet on desktop. Replaced the inert DaisyUI dropdown
                 (task 019e0d4b stage 2). The icon stays opacity-0 / hover-
                 reveal on desktop; on mobile it's always visible since
                 there's no hover signal.  --%>
              <button
                :if={deletable_task?(@task)}
                type="button"
                phx-click="board_open_task_actions"
                phx-target={@myself}
                phx-value-id={@task.id}
                aria-label="Task actions"
                title="Task actions"
                class="btn btn-ghost btn-xs btn-square opacity-100 lg:opacity-0 lg:group-hover:opacity-100 transition-opacity"
              >
                <span class="hero-ellipsis-vertical size-4"></span>
              </button>
            </div>
          </div>

          <%!-- Author + assignee + date --%>
          <div
            :if={
              @task.reported_by || @assignee_name ||
                @task.inserted_at
            }
            class="mt-1 flex items-center gap-1.5 text-[10px] text-subtle"
          >
            <span
              :if={@task.reported_by}
              class="truncate max-w-[100px]"
              title={"Reported by " <> @task.reported_by}
            >
              {@task.reported_by}
            </span>
            <span :if={
              @task.reported_by &&
                (@assignee_name || @task.inserted_at)
            }>
              ·
            </span>
            <span
              :if={@assignee_name}
              class="truncate max-w-[100px]"
            >
              → {@assignee_name}
            </span>
            <span :if={@assignee_name && @task.inserted_at}>·</span>
            <span :if={@task.inserted_at} class="whitespace-nowrap">
              {relative_time(@task.inserted_at)}
            </span>
          </div>

          <%!-- Bottom row: priority + progress --%>
          <div class="mt-1 flex items-center gap-2">
            <span
              class="badge badge-ghost badge-sm capitalize"
              data-role="task-kind-badge"
              data-task-kind={@task.kind}
            >
              {@task.kind}
            </span>
            <ExternalFeedbackComponents.trust_badge task={@task} />
            <span :if={@task.priority} class={priority_badge_class(@task.priority)}>
              {@task.priority}
            </span>
            <%!-- One decider (task 01a01a4a stage 5): this card's
               review badge below is driven by `@review_counts`,
               so the status chip resolves its reason from the
               same count. When a pending review outranks the
               merge gate the badge is the only "needs you" mark. --%>
            <span
              :if={@task.status in ~w(blocked planning in_review deploying)}
              class={"#{@status_class} badge-xs"}
            >
              {@status_label}
            </span>

            <%!-- Blocked-by-deps badge: only when status="blocked" AND
               metadata["unmet_dependencies"] is non-empty. Count is
               read straight from metadata (no per-card DB hit). --%>
            <span
              :if={@task.status == "blocked" and unmet_dependency_count(@task) > 0}
              class="badge badge-error badge-xs"
              title="Waiting on dependencies"
            >
              Blocked · {unmet_dependency_count(@task)}
            </span>

            <%!-- Review badge --%>
            <span
              :if={@review_count > 0}
              class="badge badge-warning badge-xs gap-1"
            >
              <span class="hero-eye size-3"></span>
              {@review_count} review
            </span>

            <%!-- Meeting-triage `needs_promotion` badge (task
               019f5e2b-8d29 stage 2, tooltip + icon polished in
               task 019f6e2c stage 3). Rendered only for backlog
               tasks flagged by the triage filer; clicking dispatches
               `promote_task` which clears the flag AND atomically
               transitions status → planning via `Platform.Tasks.promote/1`.
               Mirrors the review-badge shape (badge-warning +
               badge-xs). Backlog-scoped because promotion only
               makes sense before the task leaves the entry column.
               Browser-native `title=` tooltip — a Tippy hook per
               kanban card is overkill for a single-line message. --%>
            <button
              :if={@task.status == "backlog" and @task.needs_promotion}
              type="button"
              class="badge badge-warning badge-xs gap-1 cursor-pointer"
              phx-click="board_promote_task"
              phx-target={@myself}
              phx-value-id={@task.id}
              data-role="needs-promotion-badge"
              title="Filed from a meeting canvas. Click to promote."
            >
              <span class="hero-arrow-up-circle size-3"></span> Needs promotion
            </button>

            <%!-- Plan stage progress --%>
            <div :if={@progress} class="flex flex-1 items-center gap-1">
              <progress
                class="progress progress-primary h-1 flex-1"
                value={elem(@progress, 0)}
                max={elem(@progress, 1)}
              />
              <span class="text-[10px] text-subtle">
                {elem(@progress, 0)}/{elem(@progress, 1)}
              </span>
            </div>
          </div>

          <%!-- Per ADR 0029, plan approval is the only start signal.
             No separate manual "Start" button on the card. The user
             approves a plan from the detail panel, and the task
             transitions automatically. --%>
        </div>
      </div>
    </div>
    """
  end

  # ── Render helpers ─────────────────────────────────────────────────────

  defp epic_status_badge_class("in_progress"), do: "badge badge-warning badge-xs"
  defp epic_status_badge_class("closed"), do: "badge badge-success badge-xs"
  defp epic_status_badge_class(_), do: "badge badge-ghost badge-xs"

  defp column_header_class("backlog"), do: "text-subtle"
  # Planning + blocked split out from Backlog in Stage 2 of Tasks v2.
  # Planning leans on the neutral accent (work that hasn't started yet);
  # blocked uses the error accent so it visually stands out — the whole
  # point of the dedicated column is to surface things needing unblock.
  defp column_header_class("planning"), do: "text-subtle"
  defp column_header_class("in_progress"), do: "text-info"
  defp column_header_class("blocked"), do: "text-error"
  defp column_header_class("in_review"), do: "text-warning"
  defp column_header_class("deploying"), do: "text-secondary"
  defp column_header_class("done"), do: "text-success"
  defp column_header_class(_), do: "text-subtle"

  # Used by the mobile task list — color-coded dots mirror the column header
  # colors so the visual cue is consistent across mobile (dot per card) and
  # desktop (column header) layouts.
  defp status_dot_class("backlog"), do: "bg-base-content/30"
  defp status_dot_class("in_progress"), do: "bg-info"
  defp status_dot_class("in_review"), do: "bg-warning"
  defp status_dot_class("deploying"), do: "bg-secondary"
  defp status_dot_class("done"), do: "bg-success"
  defp status_dot_class(_), do: "bg-base-content/30"

  defp search_active?(query), do: BoardData.search_active?(query)

  defp empty_board?(columns) when is_map(columns) do
    Enum.all?(columns, fn {_key, tasks} -> tasks == [] end)
  end

  # Used by the mobile-list empty state. Looks up the label matching the
  # active status filter so the message reads naturally — 'No tasks in In
  # Progress.' rather than 'No tasks in in_progress.'
  defp active_status_label(status, columns) do
    case Enum.find(columns, fn {key, _label} -> key == status end) do
      {_key, label} -> label
      nil -> status
    end
  end

  defp plan_progress(%Task{plans: plans}) when is_list(plans) do
    case Enum.find(plans, &(&1.status in ~w(approved executing))) do
      nil ->
        nil

      plan ->
        stages = plan.stages || []
        total = length(stages)

        if total > 0 do
          completed = Enum.count(stages, &(&1.status in ~w(passed skipped)))
          {completed, total}
        else
          nil
        end
    end
  end

  defp plan_progress(_), do: nil

  # Stage-4 follow-up of task 019e2c25 (post-rejection fix): on the mobile
  # surfaces (stack-member rows and solo task cards) `task_display_status/2`
  # ALREADY surfaces "Plan Ready" with a warning badge for the
  # `:plan_pending_review` case, so rendering the action chip there too
  # produces a doubled chip on the same row. Suppress it — the status chip
  # is the single signal.
  defp mobile_stack_member_action_label(:plan_pending_review), do: {nil, nil}

  # Same doubled-chip rule for the human-only merge gate (task 01a01a4a
  # stage 4). `task_display_status/2` ALREADY replaces the neutral
  # `deploying` chip with the warning-toned "needs merge" chip on these
  # surfaces, and both the mobile solo card and the mobile stack-member row
  # render the status chip beside the action chip — so emitting the action
  # chip too would put "needs merge" on the card twice. One chip per card,
  # always. The reason atom stays intact for every other consumer.
  defp mobile_stack_member_action_label(:awaiting_human_merge), do: {nil, nil}

  # Task 01a0665e stage 1: same one-chip rule. `task_display_status/2`
  # already renders "delivered, close it" as the status chip.
  defp mobile_stack_member_action_label(:delivered_but_open), do: {nil, nil}

  # Post-rejection fix (task 01a00578 stage 1 rework). The
  # `:validation_failed` branch of `Tasks.needs_human_action_reason/2` is
  # purely status-driven (`task.status == "in_review"`), so EVERY task parked
  # in `in_review` rendered the "Needs review" pill — including the common
  # case of zero pending ReviewRequests. That makes the pill report STATUS
  # when its whole job is to say YOUR TURN. The operator rejected that directly:
  # "We need to conditionally show it when they have actionable review items
  # and clear it when there are none."
  #
  # Suppressing the chip here — rather than changing
  # `needs_human_action_reason/2` or `pending_review_counts/1` — keeps the
  # reason atom intact for every other consumer (desktop stack-detail rows
  # still call `stack_member_action_label/1`) and confines the change to the
  # mobile card surface the operator was looking at.
  defp mobile_stack_member_action_label(:validation_failed), do: {nil, nil}

  defp mobile_stack_member_action_label(reason), do: stack_member_action_label(reason)

  # Bridge between the string-keyed column list the template iterates and
  # the atom-keyed `:columns` map produced by
  # `Platform.Tasks.list_by_status/1`. Empty list when the column key
  # doesn't map to a known kanban status atom.
  defp tasks_in_column(columns, col_key) when is_map(columns) and is_binary(col_key) do
    case Map.fetch(columns, String.to_existing_atom(col_key)) do
      {:ok, list} -> list
      :error -> []
    end
  rescue
    ArgumentError -> []
  end

  defp tasks_in_column(_columns, _col_key), do: []

  # Merge tasks (from `@columns`, atom-keyed) and stacks (from
  # `@desktop_stacks_by_column`, string-keyed) into one list for one desktop
  # kanban column, ordered by `BoardData.sort_items/3` in `board_sort`
  # (`:priority` by default; task 01a0cef1). Mirrors
  # `BoardData.group_board_items/3`'s per-column sort so stacks and standalone
  # tasks interleave (ADR 0041 acceptance criterion 1). `stack_board_data` is
  # how a `%Stack{}` gets a priority: it ranks as its best member. This
  # re-sort is what the desktop board renders — `@columns` arrives in
  # `list_by_status/1`'s `updated_at desc` query order and is overridden here.
  #
  # Stack-member tasks (`stack_id != nil`) are suppressed here — they render
  # only under their parent stack card, never as their own column entry.
  # `Platform.Tasks.list_by_status/1` doesn't pre-filter stack members (it
  # serves the wider task set), so the filter lives in this render-shaping
  # layer.
  defp desktop_column_items(columns, stacks_by_column, col_key, board_sort, stack_board_data) do
    tasks =
      columns
      |> tasks_in_column(col_key)
      |> Enum.filter(&is_nil(&1.stack_id))

    stacks = Map.get(stacks_by_column || %{}, col_key, [])

    BoardData.sort_items(tasks ++ stacks, board_sort || :priority, stack_board_data)
  end

  # Stage-3 wrapper: filters `desktop_column_items/5` through the active
  # scope-rail selection, as `@board_scope`. `:all` is the unfiltered
  # passthrough, and the root org's chip arrives as `:all` too (see
  # `board_scope/1`), because every task folds under the root org until
  # `tasks.org_id` lands (the same contract `count_by_scope/0` encodes). The
  # other scopes return an empty list today; once MT/RBAC ships this helper
  # becomes the single seam to swap in real per-task scope filtering.
  defp desktop_column_items_for_scope(columns, stacks_by_column, col_key, :all, sort, data) do
    desktop_column_items(columns, stacks_by_column, col_key, sort, data)
  end

  # Any OTHER org. Task 01a09287 stage 2 turned `@scope_filter` into an org
  # slug string, and task 01a14dd9 stage 2 removed the last compiled atom
  # list from this guard, so it accepts binaries only: "is a scope that is
  # not the root" rather than a membership list that a new tenant falls
  # out of. Falling out of it silently returned the FULL board under the
  # other clause below, i.e. a new org's chip would have shown every task.
  defp desktop_column_items_for_scope(_columns, _stacks_by_column, _col_key, scope, _sort, _data)
       when is_binary(scope) do
    []
  end

  defp desktop_column_items_for_scope(columns, stacks_by_column, col_key, _other, sort, data) do
    desktop_column_items(columns, stacks_by_column, col_key, sort, data)
  end

  # True when every kanban column resolves to an empty item list through the
  # scope-filter lens. Shared by the sponsor-filter empty state AND the
  # search "no matching tasks" banner, so neither empty-state lies when
  # multiple filters are active.
  #
  # Stage-3 of task 019f487e invariant note (do NOT re-derive this):
  # `desktop_column_items_for_scope/6` merges tasks with stacks from
  # `desktop_stacks_by_column`, which `BoardHooks.refresh_board/1` already
  # narrows by `:sponsor_user_id`. The empty-state signal therefore reflects
  # tasks-AND-stacks visibility because both halves flow through the same
  # filtered pipeline.
  defp board_columns_empty?(kanban_columns, columns, stacks_by_column, scope_filter) do
    # Emptiness only: the list order is irrelevant here, so no sort mode or
    # stack board data is threaded through.
    Enum.all?(kanban_columns, fn {col_key, _label} ->
      items =
        desktop_column_items_for_scope(
          columns,
          stacks_by_column,
          col_key,
          scope_filter,
          :priority,
          %{}
        )

      items == []
    end)
  end

  # ADR 0042 stage 1 (task 019f3f22): sponsor chip on task cards. Returns a
  # `%{name, avatar_url, seed}` map for `<.human_avatar>` or `nil` when there
  # is no sponsor. Falls back to a sentinel entry when the FK points at a
  # user no longer in `users_by_id`, matching `sponsor_name/2`'s
  # deleted-user behaviour so the chip still renders instead of blinking on
  # ownership churn. Stage 4 of task 019f487e (ADR-0042 Decision 8) added
  # the `%Stack{}` clauses — stack cards surface the sponsor avatar too.
  defp sponsor_identity(%Task{sponsor_user_id: nil}, _users_by_id), do: nil

  defp sponsor_identity(%Task{sponsor_user_id: id}, users_by_id) when is_binary(id),
    do: identity_for_user(Map.get(users_by_id, id), id)

  defp sponsor_identity(%Stack{sponsor_user_id: nil}, _users_by_id), do: nil

  defp sponsor_identity(%Stack{sponsor_user_id: id}, users_by_id) when is_binary(id),
    do: identity_for_user(Map.get(users_by_id, id), id)

  defp sponsor_identity(_, _), do: nil

  defp identity_for_user(user, id) do
    %{
      name: (user && (user.name || user.email)) || "Unknown user",
      avatar_url: user && user.avatar_url,
      seed: user_seed(user, id)
    }
  end

  defp assignee_identity(%Task{assignee_type: nil}, _users_by_id, _agents_by_id), do: nil

  defp assignee_identity(
         %Task{assignee_type: "agent", assignee_id: id},
         _users_by_id,
         agents_by_id
       )
       when is_binary(id) do
    agent = Map.get(agents_by_id, id)

    # `agents_by_id` is built from `Chat.list_agents_for_picker/0`, which
    # selects whole `%Agent{}` rows. `:seed` stays for shape parity with the
    # user clause below; the agent chip does not pass it on, because
    # `agent_avatar/1` takes no seed (agents never draw the seeded human
    # palette).
    %{
      type: :agent,
      name: agent_name(agent),
      avatar_url: agent && agent.avatar_url,
      seed: id
    }
  end

  defp assignee_identity(
         %Task{assignee_type: "user", assignee_id: id},
         users_by_id,
         _agents_by_id
       )
       when is_binary(id) do
    user = Map.get(users_by_id, id)

    %{
      type: :user,
      name: user_name(user),
      avatar_url: user && user.avatar_url,
      seed: user_seed(user, id)
    }
  end

  defp assignee_identity(_task, _users_by_id, _agents_by_id), do: nil

  defp agent_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp agent_name(_agent), do: "Agent"

  defp user_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_name(%{email: email}) when is_binary(email) and email != "", do: email
  defp user_name(_user), do: "User"

  defp user_seed(%{oidc_sub: oidc_sub}, _fallback) when is_binary(oidc_sub) and oidc_sub != "",
    do: oidc_sub

  defp user_seed(%{email: email}, _fallback) when is_binary(email) and email != "", do: email
  defp user_seed(_user, fallback), do: fallback

  # The task id arrives from the client: a task the viewer may not
  # `tasks.write` (the org fence, an explicit deny; tasks 01a14721 stage 1
  # and 01a1472d stage 1) reads exactly like a missing one.
  defp writable_record(socket, task_id) do
    if Selection.permits?(socket, {:task, task_id}), do: Tasks.get_task_record(task_id)
  end
end
