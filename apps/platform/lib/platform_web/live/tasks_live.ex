defmodule PlatformWeb.TasksLive do
  @moduledoc """
  Shell for the Tasks surface.

  After task 01a008f6 (seven extraction stages) this module holds only what
  a LiveView cannot delegate:

    * `mount/3` — session-derived assigns, subscriptions, hook attachment
    * `handle_params/3` — the `/tasks/:task_id` deep link and the
      `?sponsor=mine` filter, both of which are callbacks a LiveComponent
      cannot have
    * navigation events (`select_task`, `select_task_and_delete`) and the
      two header menus that span three components
    * the notify inbox — every component reports outcomes up here rather
      than writing a shell assign behind its back
    * `send_update/2` mediation for the pieces of state whose writer is a
      different component than the one that needs to change

  Everything else lives under `lib/platform_web/live/tasks/`:

  | Module                | Kind           | Owns                                  |
  |-----------------------|----------------|---------------------------------------|
  | `TasksLive.SidebarComponent` | component | projects / epics / org sections   |
  | `Tasks.StacksComponent`      | component | stack panel, dep graph, rollup    |
  | `Tasks.TaskDetailComponent`  | component | detail panel, inline edit, plans  |
  | `Tasks.SteeringComponent`    | component | execution log, composer, outputs  |
  | `Tasks.MergeControlComponent`| component | merge / open-PR cluster           |
  | `Tasks.AssigneesComponent`   | component | per-phase assignee modal          |
  | `Tasks.GatePanelComponent`   | component | pending reviews, review canvases  |
  | `Tasks.FiltersComponent`     | component | search, scope rail, sponsor, pills|
  | `Tasks.TaskCreateComponent`  | component | create FAB, sheet, uploads        |
  | `Tasks.SupersedeComponent`   | component | return-to-planning modal          |
  | `Tasks.BoardComponent`       | component | epics strip, mobile list, kanban  |
  | `Tasks.BoardHooks`           | hook      | board PubSub + `refresh_board/1`  |
  | `Tasks.LifecycleHooks`       | hook      | archive / schedule-deletion       |
  | `Tasks.PinHooks`             | hook      | pin-to-chat MapSet                |
  | `Tasks.BoardData`            | pure      | column buckets, search matching   |
  | `Tasks.Selection`            | pure-ish  | `:selected_task` assign plumbing  |

  See `docs/decisions/0050-tasks-surface-budget-ratchet.md` for the budget
  this shell is held to and how it is measured.
  """
  use PlatformWeb, :live_view

  require Logger

  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Skills
  alias Platform.Tasks
  alias Platform.Tasks.ReviewRequests
  alias Platform.Tenancy
  alias PlatformWeb.Tasks.BoardData
  alias PlatformWeb.Tasks.BoardHooks
  alias PlatformWeb.Tasks.LifecycleHooks
  alias PlatformWeb.Tasks.PinHooks
  alias PlatformWeb.Tasks.SteeringComponent
  alias PlatformWeb.Tasks.TaskDetailComponent

  import PlatformWeb.Tasks.ReviewLoaders, only: [load_review_canvases: 1]

  # `phase_entry/1` only — `all_phases_same_agent?/1` went to
  # `AssigneesComponent` with the modal. What is left here is the
  # back-compat `assign_agent` forward.
  import PlatformWeb.Tasks.PhaseAssigneeParams, only: [phase_entry: 1]

  import PlatformWeb.Tasks.Selection,
    only: [assign_selected_task: 2, bump_detail_epoch: 1, reload_selected_task: 1]

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Tasks.subscribe_board()
      # Pin-to-Chat stage 4 (task 019f62a1): the global space-lifecycle topic
      # carries the pin add/remove broadcasts; PinHooks reacts to them.
      ChatPubSub.subscribe_spaces()
    end

    agents = Chat.list_agents_for_picker()
    users = Platform.Accounts.list_users()

    {:ok,
     socket
     |> assign(:page_title, "Tasks")
     |> assign(:current_user_id, session["current_user_id"])
     |> assign(:selected_project_id, nil)
     |> assign(:selected_epic_id, nil)
     |> assign(:epics, enrich_epics(Tasks.list_epics_for_project(nil)))
     # Read-only MIRROR of SidebarComponent's `:epics_collapsed`. The epics
     # strip renders in the board column, so the shell threads the boolean
     # through as a BoardComponent attr; the sidebar remains the single
     # writer and pushes the value up via `{:sidebar_epics_collapsed, bool}`.
     |> assign(:epics_collapsed, false)
     |> assign(:orgs, Tenancy.list_orgs_in_priority_order())
     |> assign(:kanban_columns, BoardData.kanban_columns())
     |> assign(:mobile_columns, BoardData.mobile_columns())
     |> assign(:active_status_filter, "in_progress")
     |> assign(:scope_filter, :all)
     # `?sponsor=mine` is authoritative and `handle_params/3` is its writer,
     # which is why this one filter stays shell-owned (see FiltersComponent).
     |> assign(:sponsor_filter, :all)
     |> assign(:task_search_query, "")
     |> assign(:create_menu_open, false)
     # Task 019fed1e: the admin-only Tasks settings menu (one row today,
     # Pipeline). The trigger renders only behind `@fabrikam_admin?` and the
     # destination is gated again by `live_session :admin`.
     |> assign(:settings_menu_open, false)
     |> assign(:agents, agents)
     |> assign(:agents_by_id, Map.new(agents, &{&1.id, &1}))
     |> assign(:agent_names, Map.new(agents, fn a -> {a.id, a.name} end))
     # `:users` powers the Sponsor picker in the New-Task sheet (stage 3 of
     # ADR-0042). `:users_by_id` backs detail-panel + card lookups.
     |> assign(:users, users)
     |> assign(:users_by_id, Map.new(users, &{&1.id, &1}))
     |> assign(:selected_task, nil)
     |> assign(:selected_task_canvases, [])
     |> assign(:merge_control, nil)
     |> assign(:show_detail, false)
     |> assign(:pending_reviews, [])
     |> assign(:superseded_reviews, [])
     |> assign(:review_canvases, %{})
     |> assign(:attached_skills, [])
     |> assign(:available_skills, Skills.list_skills())
     # Subscription bookkeeping ONLY. Every steering render assign lives in
     # `SteeringComponent`; the shell keeps the space id it is subscribed to
     # because the shell is the process PubSub delivers to.
     |> assign(:subscribed_execution_space_id, nil)
     |> assign(:review_request_subscriptions, MapSet.new())
     |> bump_detail_epoch()
     |> PinHooks.attach(session["current_user_id"])
     |> LifecycleHooks.attach()
     |> LifecycleHooks.refresh_containers()
     |> BoardHooks.attach()
     |> BoardHooks.refresh_board()}
  end

  @impl true
  def handle_params(%{"task_id" => task_id}, _url, socket) do
    # Platform.UUID.cast/1, NOT Ecto.UUID.cast/1. This is a FABRICATED-VALUE
    # site, not a raise site: the {:ok, _} output flows on, so a bare cast
    # hex-encodes a 16-character LiveView param into a well-formed but
    # INVENTED uuid that silently misses instead of being rejected. Nothing
    # raises — an assert_raise-shaped test cannot see this. Assert the
    # :error branch is taken.
    with {:ok, _} <- Platform.UUID.cast(task_id),
         task when not is_nil(task) <- Tasks.get_task_detail(task_id) do
      pending_reviews = ReviewRequests.list_pending_for_task(task.id)

      # The execution log, its participant and the steering composer all
      # belong to `SteeringComponent` (stage 5). It loads them off the
      # bumped `detail_epoch` and tells the shell which space to subscribe
      # to via `{:steering_space_changed, id}`.
      {:noreply,
       socket
       |> assign_selected_task(task)
       |> assign(:show_detail, true)
       |> assign(:pending_reviews, pending_reviews)
       |> assign(:superseded_reviews, ReviewRequests.list_superseded_for_task(task.id))
       |> assign(:review_canvases, load_review_canvases(pending_reviews))
       |> assign(:attached_skills, Skills.resolve_skills(task.id))
       |> assign(:available_skills, Skills.list_skills())
       |> assign(:page_title, "Tasks · #{task.title}")}
    else
      # Either a malformed UUID, or valid-shape but the row is gone (deleted,
      # cross-tenant 404). Both are the same "stale saved URL" story: the
      # client's `route_resume:tasks` value can never resolve, so signal the
      # hook to clear it and fall back to `/tasks` on the next Tasks click.
      other ->
        message = if other == :error, do: "Invalid task ID.", else: "Task not found."

        {:noreply,
         socket
         |> handle_route_stale("tasks")
         |> clear_detail()
         |> put_flash(:error, message)}
    end
  end

  def handle_params(params, _url, socket) do
    # Stage-2 of task 019f3f22: `?sponsor=mine` is the authoritative source
    # of truth for the "Sponsored by me" filter — decoded here so both
    # push_patch toggles and direct URL loads (share-a-URL, refresh) land in
    # the same state. Any other value resolves to `:all` so we can't hang on
    # malformed input.
    new_filter = decode_sponsor_param(params)
    changed? = new_filter != socket.assigns[:sponsor_filter]

    socket = assign(socket, :sponsor_filter, new_filter)
    socket = if changed?, do: BoardHooks.refresh_board(socket), else: socket

    {:noreply, socket |> assign(:selected_task, nil) |> assign(:show_detail, false)}
  end

  # ── Events ──────────────────────────────────────────────────────────────
  #
  # What is left here is navigation and the two header menus. Board, filter,
  # sidebar, detail, steering, gate, create, supersede, assignee, merge and
  # container-lifecycle events all live in their own module.

  @impl true
  # Navigation. Deliberately UNTARGETED and deliberately still here: three
  # separate surfaces push `select_task` — BoardComponent's cards,
  # StacksComponent's stack-panel member rows, and the shared
  # `PlatformWeb.PlanningStepExtension` function component — and `push_patch/2`
  # is a LiveView concern in any case.
  def handle_event("select_task", %{"id" => task_id}, socket) do
    # T8 stage 4: opening a task closes the stack detail panel so the two
    # slide-ins don't fight for the same screen real-estate.
    BoardHooks.close_stacks_panel()

    {:noreply, push_patch(socket, to: ~p"/tasks/#{task_id}")}
  end

  # The row-level "Delete" action selects the task AND opens the detail
  # panel's delete confirmation. `:confirm_delete` belongs to
  # `TaskDetailComponent`, so the shell asks rather than writes — and it must
  # ask AFTER `push_patch/2` has run `handle_params/3` (which bumps
  # `:detail_epoch` and would otherwise reset the flag straight back).
  def handle_event("select_task_and_delete", %{"id" => task_id}, socket) do
    send(self(), {:detail_confirm_delete_requested})
    send_update(PlatformWeb.Tasks.BoardComponent, id: "tasks-board", open_task_actions_id: nil)

    {:noreply, push_patch(socket, to: ~p"/tasks/#{task_id}")}
  end

  # Desktop header ▾ split-button menu (spans epics + projects + tasks, i.e.
  # three components, which is why it is the shell's) and the admin-only
  # settings menu beside it. Each closes the other so the two can never be
  # open at once.
  def handle_event("toggle_create_menu", _params, socket) do
    {:noreply,
     socket
     |> assign(:create_menu_open, !socket.assigns.create_menu_open)
     |> assign(:settings_menu_open, false)}
  end

  def handle_event("toggle_settings_menu", _params, socket) do
    {:noreply,
     socket
     |> assign(:settings_menu_open, !socket.assigns.settings_menu_open)
     |> assign(:create_menu_open, false)}
  end

  # Back-compat: the old single-select dropdown used the `assign_agent`
  # event. Forward it to the per-phase path so any external client still
  # works. The modal itself is `AssigneesComponent`.
  def handle_event("assign_agent", %{"agent_id" => agent_id}, socket) do
    task = socket.assigns.selected_task

    cond do
      is_nil(task) ->
        {:noreply, socket}

      true ->
        entry = phase_entry(agent_id)
        attrs = %{"planning" => entry, "execution" => entry, "review" => entry}

        case Tasks.set_phase_assignees(task, attrs) do
          {:ok, _} ->
            {:noreply,
             socket
             |> BoardHooks.refresh_board()
             |> assign_selected_task(Tasks.get_task_detail(task.id))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to assign agent.")}
        end
    end
  end

  # ── Notify inbox ───────────────────────────────────────────────────────
  #
  # Every component reports outcomes here rather than writing a shell assign
  # behind its back. Board PubSub is `BoardHooks`; pin PubSub is `PinHooks`;
  # both are attached hooks and halt before reaching this function.

  # BoardComponent (stage 7) — drag-and-drop and promote change what the
  # whole board renders, so the component reports up instead of refreshing
  # itself.
  @impl true
  def handle_info({:board_refresh_requested}, socket) do
    {:noreply, socket |> BoardHooks.refresh_board() |> reload_selected_task()}
  end

  def handle_info({:board_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  # ── SidebarComponent (stage 2) ─────────────────────────────────────────

  def handle_info({:sidebar_project_selected, project_id}, socket) do
    # Stale-id fallback: a restored localStorage value may reference a
    # project that has since been deleted, been ARCHIVED, or that the current
    # user can no longer see. Drop back to the All Projects view rather than
    # render a board the sidebar no longer offers.
    #
    # Archived counts as stale (task 019f4eaa): `last_project.js` replays the
    # stored id via this event on EVERY mount, so filtering archived projects
    # out of the sidebar isn't enough on its own. Falling through here also
    # self-heals the stored value, because `push_selected_project_changed/1`
    # writes the corrected id back to localStorage.
    project = Tasks.get_project(project_id)

    resolved_id =
      if is_nil(project) or Platform.Projects.archived?(project), do: nil, else: project_id

    {:noreply, select_project(socket, resolved_id)}
  end

  def handle_info({:sidebar_epic_selected, epic_id}, socket) do
    new_id = if socket.assigns.selected_epic_id == epic_id, do: nil, else: epic_id

    {:noreply, socket |> assign(:selected_epic_id, new_id) |> BoardHooks.refresh_board()}
  end

  # Read-only mirror; SidebarComponent stays the single writer. The epics
  # strip renders inside BoardComponent, which takes it as an attr.
  def handle_info({:sidebar_epics_collapsed, collapsed}, socket) do
    {:noreply, assign(socket, :epics_collapsed, collapsed)}
  end

  # No PubSub topic for projects (no `tasks:lifecycle` topic exists) — the
  # SidebarComponent sends this directly; recompute container-derived assigns.
  def handle_info({:sidebar_projects_changed}, socket) do
    {:noreply, LifecycleHooks.refresh_containers(socket)}
  end

  def handle_info({:sidebar_epic_created}, socket) do
    {:noreply, socket |> BoardHooks.refresh_board() |> reload_epics()}
  end

  def handle_info({:sidebar_close_create_menus}, socket) do
    {:noreply, close_create_menus(socket)}
  end

  def handle_info({:sidebar_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  # ── TaskDetailComponent (stage 4) ──────────────────────────────────────

  def handle_info({:detail_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  def handle_info({:detail_refresh}, socket) do
    {:noreply, socket |> BoardHooks.refresh_board() |> reload_selected_task()}
  end

  def handle_info({:detail_task_transitioned, task}, socket) do
    {:noreply, socket |> BoardHooks.refresh_board() |> assign_selected_task(task)}
  end

  def handle_info({:detail_skills_changed}, socket) do
    task = socket.assigns[:selected_task]

    {:noreply,
     socket
     |> assign(:attached_skills, if(task, do: Skills.resolve_skills(task.id), else: []))
     |> assign(:available_skills, Skills.list_skills())}
  end

  def handle_info({:detail_confirm_delete_requested}, socket) do
    send_update(TaskDetailComponent, id: "tasks-detail", confirm_delete: true)
    {:noreply, socket}
  end

  # Panel teardown: fired by the component's close button and by a successful
  # delete. Everything cleared here is shell-owned.
  def handle_info({:detail_closed}, socket) do
    {:noreply,
     socket
     |> resubscribe_execution_space(nil)
     |> clear_detail()
     |> assign(:selected_task_canvases, [])
     |> BoardHooks.refresh_board()
     |> bump_detail_epoch()
     |> push_patch(to: ~p"/tasks")}
  end

  # ── StacksComponent (stage 3) ──────────────────────────────────────────

  def handle_info({:stacks_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  def handle_info({:stacks_board_refresh}, socket) do
    {:noreply, BoardHooks.refresh_board(socket)}
  end

  # `:expanded_stacks` is board render state (see `refresh_board/1`, which
  # resets it per ADR 0041 acceptance criterion 3), so the shell owns the
  # write. No-op if the id is not currently in `:stacks` — defensive against
  # stale DOM after a PubSub refresh removed the stack.
  def handle_info({:stacks_toggle_expand, stack_id}, socket) do
    if Enum.any?(socket.assigns.stacks, &(&1.id == stack_id)) do
      expanded = socket.assigns.expanded_stacks

      next =
        if MapSet.member?(expanded, stack_id),
          do: MapSet.delete(expanded, stack_id),
          else: MapSet.put(expanded, stack_id)

      {:noreply, assign(socket, :expanded_stacks, next)}
    else
      {:noreply, socket}
    end
  end

  # Opening a stack panel closes the per-task one so the two slide-ins do not
  # fight for the same screen real-estate.
  def handle_info({:stacks_close_task_detail}, socket) do
    {:noreply, socket |> assign(:selected_task, nil) |> assign(:show_detail, false)}
  end

  # ── SteeringComponent + GatePanelComponent (stages 5-6) ────────────────

  # The component loads the execution space for the selected task and reports
  # which space it landed on. The SHELL holds the subscription because PubSub
  # delivers to the LiveView process, not to a component.
  def handle_info({:steering_space_changed, space_id}, socket) do
    {:noreply, resubscribe_execution_space(socket, space_id)}
  end

  # Execution space PubSub — the component re-fetches its own log and
  # outputs; the shell just forwards the tick.
  def handle_info({:new_message, _msg}, socket) do
    send_update(SteeringComponent,
      id: "tasks-steering",
      reload: System.unique_integer([:monotonic])
    )

    {:noreply, socket}
  end

  # An output canvas was opened from the Outputs list. Neither component can
  # send_update the other, so the shell forwards: SteeringComponent resolves
  # the canvas, GatePanelComponent renders the modal.
  def handle_info({:steering_open_canvas, canvas}, socket) do
    send_update(PlatformWeb.Tasks.GatePanelComponent,
      id: "tasks-gate-panel",
      steering_canvas: canvas
    )

    {:noreply, socket}
  end

  # An item was approved or rejected in the gate panel. Both change what the
  # BOARD renders, which is why the component reports up.
  def handle_info({:gate_reviews_changed}, socket) do
    {:noreply, socket |> BoardHooks.refresh_board() |> reload_selected_task()}
  end

  # ── FiltersComponent (stage 6) ─────────────────────────────────────────

  # The component writes the filter values and hands them here; the shell
  # mirrors them and does the board work. Search filters IN MEMORY over the
  # already-loaded sources. Scope narrows the kanban render, which reads
  # `@scope_filter` directly. The mobile pill bar picks a section out of
  # `@board_items`. Only the first needs work.
  def handle_info({:tasks_filters_changed, changes}, socket) do
    socket = assign(socket, Enum.to_list(changes))

    socket =
      if Map.has_key?(changes, :task_search_query),
        do: BoardHooks.rebuild_board_shapes(socket),
        else: socket

    {:noreply, socket}
  end

  # Clearing the breadcrumb drops the project + epic selection, which IS a
  # re-query, and has to push the corrected id back to localStorage.
  def handle_info({:tasks_filters_cleared}, socket) do
    # `:show_project_sheet` belongs to SidebarComponent, so clearing the
    # filter dismisses the mobile sheet by send_update rather than by writing
    # the assign (stage 2).
    send_update(PlatformWeb.TasksLive.SidebarComponent,
      id: "tasks-sidebar",
      show_project_sheet: false
    )

    {:noreply, select_project(socket, nil)}
  end

  # ── TaskCreateComponent (stage 6) ──────────────────────────────────────

  def handle_info({:taskcreate_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  # Opening the create sheet must close the shell-owned header ▾ menu.
  def handle_info({:taskcreate_close_menus}, socket) do
    {:noreply, assign(socket, :create_menu_open, false)}
  end

  def handle_info({:taskcreate_created, message}, socket) do
    {:noreply, socket |> put_flash(:info, message) |> BoardHooks.refresh_board()}
  end

  # ── SupersedeComponent (stage 6) ───────────────────────────────────────

  def handle_info({:supersede_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  # Success: the plan is superseded and the task is back in planning.
  def handle_info({:supersede_completed, message}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> BoardHooks.refresh_board()
     |> reload_selected_task()}
  end

  # Refused because the task had already left the in-flight statuses. Same
  # reload as success — the shell's copy of the task is what was stale.
  def handle_info({:supersede_stale, message}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, message)
     |> BoardHooks.refresh_board()
     |> reload_selected_task()}
  end

  # ── AssigneesComponent + MergeControlComponent (stage 5) ───────────────

  def handle_info({:assignees_saved, task_id}, socket) do
    {:noreply,
     socket
     |> BoardHooks.refresh_board()
     |> assign_selected_task(Tasks.get_task_detail(task_id))
     |> put_flash(:info, "Assignees saved.")}
  end

  def handle_info({:assignees_save_failed}, socket) do
    {:noreply, put_flash(socket, :error, "Failed to save assignees.")}
  end

  def handle_info({:merge_control_merged, task_id, branch}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Merge requested for #{branch}.")
     |> assign_selected_task(Tasks.get_task_detail(task_id))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Private ────────────────────────────────────────────────────────────

  # Project selection is three writes plus a re-query plus a localStorage
  # push, and both `{:sidebar_project_selected, _}` and
  # `{:tasks_filters_cleared}` need all five.
  defp select_project(socket, project_id) do
    socket
    |> assign(:selected_project_id, project_id)
    |> assign(:selected_epic_id, nil)
    |> reload_epics()
    |> BoardHooks.refresh_board()
    |> push_selected_project_changed()
  end

  defp reload_epics(socket) do
    assign(
      socket,
      :epics,
      enrich_epics(Tasks.list_epics_for_project(socket.assigns.selected_project_id))
    )
  end

  # Push the canonical post-handler selection back to the client so the
  # LastProject JS hook can keep localStorage in sync. This MUST fire after
  # both project selection (including the stale-UUID fallback path) and
  # filter-clear — relying solely on a wrapper-attribute DOM diff misses the
  # case where the server-side state was already at the same value (e.g.
  # fallback from a stale UUID → nil when nil was the initial render).
  defp push_selected_project_changed(socket) do
    id = socket.assigns.selected_project_id || "__all__"
    push_event(socket, "selected_project_changed", %{id: id})
  end

  defp clear_detail(socket) do
    socket
    |> assign(:selected_task, nil)
    |> assign(:show_detail, false)
    |> assign(:pending_reviews, [])
    |> assign(:superseded_reviews, [])
    |> assign(:review_canvases, %{})
  end

  # The steering concern's loaders and uploads are `SteeringComponent`'s.
  # What remains here is the subscription, which belongs to the process the
  # messages are delivered to.
  defp resubscribe_execution_space(socket, space_id) do
    previous = socket.assigns[:subscribed_execution_space_id]

    if previous != space_id do
      if previous, do: Chat.PubSub.unsubscribe(previous)
      if space_id, do: Chat.PubSub.subscribe(space_id)
      assign(socket, :subscribed_execution_space_id, space_id)
    else
      socket
    end
  end

  # `:fab_menu_open` lives in TaskCreateComponent, so closing the FAB menu is
  # a send_update rather than an assign.
  defp close_create_menus(socket) do
    send_update(PlatformWeb.Tasks.TaskCreateComponent,
      id: "tasks-create",
      close_fab_menu: true
    )

    assign(socket, :create_menu_open, false)
  end

  # Stage-2 of task 019f3f22: decode the `?sponsor` URL param into the
  # canonical filter atom. Only `"mine"` activates the filter — everything
  # else (missing, empty, garbage) resolves to `:all` so malformed URLs can't
  # hang the mount.
  defp decode_sponsor_param(%{"sponsor" => "mine"}), do: :mine
  defp decode_sponsor_param(_), do: :all

  defp enrich_epics(epics) do
    counts = Tasks.epic_task_counts(Enum.map(epics, & &1.id))

    Enum.map(epics, fn epic ->
      c = Map.get(counts, epic.id, %{total: 0, done: 0})

      %{
        id: epic.id,
        name: epic.name,
        description: epic.description,
        status: epic.status,
        task_count: c.total,
        done_count: c.done
      }
    end)
  end

  # ── Blocked-explanation surface (task 01a004ad) ────────────────────────
  #
  # The implementation moved to `TaskDetailComponent` when the detail panel
  # was extracted (task 01a008f6): the helpers sit next to
  # `dependency_summary/1` and the markup that consumes them. These
  # delegates keep the pre-extraction call site — `TasksLive.blocked_*` —
  # working, so the read-side coverage in
  # `tasks_live_blocked_explanation_test.exs` and any other external caller
  # is unaffected by where the logic physically lives.
  defdelegate blocked_reason(task), to: TaskDetailComponent
  defdelegate blocked_reason_at(task), to: TaskDetailComponent
  defdelegate blocked_explanation(task), to: TaskDetailComponent
end
