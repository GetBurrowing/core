defmodule PlatformWeb.Tasks.BoardHooks do
  @moduledoc """
  Lifecycle hook module for the Tasks BOARD DATA (task 01a008f6 stage 7).

  See ADR 0035 for the hook-vs-component criterion and
  `docs/decisions/0050-tasks-surface-budget-ratchet.md` for why the board
  was split in two rather than filed as one or the other.

  The board's *markup* is a LiveComponent (`BoardComponent`) because it is
  one contiguous, self-contained region. Its *subscriptions* cannot be:
  PubSub delivers to the LiveView process, not to a component, so the
  board's ten `handle_info` clauses and the `refresh_board/1` they all
  funnel through live here as a hook on the shell.

  This module owns:

    * Assigns: `:all_tasks`, `:stacks`, `:stack_board_data`, `:columns`,
      `:desktop_stacks_by_column`, `:board_items`, `:board_sort`,
      `:expanded_stacks`,
      `:review_counts`, `:pending_plan_count`, `:scope_counts`,
      `:scope_counts_db`, `:visible_task_count`,
      `:review_request_subscriptions`, `:my_tasks`, `:my_needs_you`,
      and (task 01a161fd stage 1) `:status_filters`, `:kind_filters`,
      `:mine_filter`, `:filtered_tasks`, `:filtered_count`, and (stage 3,
      through `FilterHooks`)
      `:tasks_filter_sheet`, `:tasks_filter_epics`
    * Info: `{:task_updated, _}`, `{:task_created, _}`, `{:task_deleted, _}`,
      `{:tasks_batch_deleted, _, _}`, `{:epic_created, _}`,
      `{:epic_updated, _}`, `{:plan_updated, _}`,
      `{:stack_gate_opened, _, _}`, `{:review_request_pending, _}`,
      `{:review_request_resolved, _}`, `{:tasks_pref_settled}` (stage 2)

  The component re-renders from the assigns the hook writes — no
  `send_update/2` mediation is needed for board data, because
  `BoardComponent` takes every board map as an attr and LiveView diffs
  attrs on the parent's re-render. `send_update/2` IS used for the stack
  panel, whose state belongs to `StacksComponent` and is not an attr.

  ## List order

  `:board_sort` (`:priority` | `:updated`, see `BoardData.sort_items/3`) is
  read by both writers of the board shapes and defaults to `:priority` when
  absent, so `refresh_board/1` assigns it on the first mount and the shell
  needs no mount line of its own. `:columns` is still loaded with
  `Tasks.list_by_status/1`'s `updated_at desc` query order, but that is NOT
  the rendered order: `BoardComponent.desktop_column_items/5` re-sorts every
  desktop column through `BoardData.sort_items/3`.

  ## Usage

      # In TasksLive.mount/3, after the initial board assigns:
      socket = PlatformWeb.Tasks.BoardHooks.attach(socket)
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]

  alias Platform.Tasks
  alias Platform.Tasks.ReviewRequests
  alias Platform.Tasks.Stacks
  alias PlatformWeb.Tasks.BoardData
  alias PlatformWeb.Tasks.FilterHooks
  alias PlatformWeb.Tasks.FilterPrefs
  alias PlatformWeb.Tasks.Selection
  alias PlatformWeb.Tasks.StacksComponent

  import PlatformWeb.Tasks.ReviewLoaders, only: [pending_review_counts: 1]

  @doc """
  Attach the board PubSub handlers. Call from `TasksLive.mount/3`.

  The board topic subscription itself stays in `mount/3` next to the other
  connected?-gated subscribes; this only registers the `:handle_info` hook.
  """
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    # The External Feedback lane (task 01a11ec3 stage 4). Defaulted here, not
    # in the budgeted shell; `apply_url_filters/3` is its only other writer.
    |> assign(:origin_filter, :all)
    # Task 01a161fd stage 1: the multi-value URL filters, likewise defaulted
    # here and written only by `apply_url_filters/3`.
    |> assign(:status_filters, [])
    |> assign(:kind_filters, [])
    |> assign(:mine_filter, false)
    # Task 01a161fd stage 3: the phone header's sheet state and events.
    |> FilterHooks.attach()
    |> attach_hook(:board_info, :handle_info, &handle_info/2)
  end

  @doc """
  Task 01a166be: the mount's stand-in for `refresh_board/1`. Call LAST in
  `TasksLive.mount/3`.

  `handle_params/3` always runs before the first render (dead and
  connected), and on a bare or filtered `/tasks` it narrows the board to the
  URL's or the stored project. Loading the widest board in mount only for
  that first `handle_params/3` to replace it was a wasted pass on every
  arrival. So mount marks the board `:board_pending`, and the first
  `handle_params/3` loads it exactly once: `apply_url_filters/3` on the
  board routes, and the `:board_arrival` hook below on `/tasks/:task_id`,
  whose clause never reaches `apply_url_filters/3`. `load_board/1` clears
  the flag.
  """
  @spec defer_board(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def defer_board(socket) do
    socket
    |> assign(:board_pending, true)
    |> attach_hook(:board_arrival, :handle_params, &load_pending_for_task_route/3)
  end

  defp load_pending_for_task_route(
         %{"task_id" => _},
         _uri,
         %{assigns: %{board_pending: true}} = s
       ),
       do: {:cont, refresh_board(s)}

  defp load_pending_for_task_route(_params, _uri, socket), do: {:cont, socket}

  # ── PubSub ─────────────────────────────────────────────────────────────

  defp handle_info({:task_updated, _task}, socket), do: {:halt, full_refresh(socket)}
  defp handle_info({:plan_updated, _plan}, socket), do: {:halt, full_refresh(socket)}
  defp handle_info({:review_request_pending, _payload}, socket), do: {:halt, full_refresh(socket)}

  defp handle_info({:review_request_resolved, _payload}, socket),
    do: {:halt, full_refresh(socket)}

  defp handle_info({:task_created, _task}, socket), do: {:halt, refresh_board(socket)}
  defp handle_info({:task_deleted, _task}, socket), do: {:halt, refresh_board(socket)}

  # M5b (task 019f6e2c) stage 5: batch soft-delete from
  # `Platform.Meetings.Triage.junk_batch/2`. One refresh drops every listed
  # row in a single kanban reflow — cheaper than N sequential
  # `{:task_deleted, _}` broadcasts at any batch size >= 2. `refresh_board/1`
  # is a full re-query so we don't need to splice the delta ourselves.
  defp handle_info({:tasks_batch_deleted, _ids, _meta}, socket),
    do: {:halt, refresh_board(socket)}

  # New / renamed epic — refresh so the epic chips and the dropdown pick it
  # up immediately.
  defp handle_info({:epic_created, _epic}, socket), do: {:halt, refresh_board(socket)}
  defp handle_info({:epic_updated, _epic}, socket), do: {:halt, refresh_board(socket)}

  # ADR 0042 Decision 4: stack-v2 commencement gate signal. UI reaction is
  # deliberately out of scope for the gate stage — the plan carrier is
  # `{:task_updated, ...}` as members transition, handled above. This
  # permissive clause exists so the LiveView doesn't crash on the shape.
  defp handle_info({:stack_gate_opened, _stack_id, _executable_ids}, socket),
    do: {:halt, socket}

  # Task 01a161fd stage 2: the URL selection's messages have all been handled.
  defp handle_info({:tasks_pref_settled}, socket), do: {:halt, FilterPrefs.settled(socket)}

  defp handle_info(_message, socket), do: {:cont, socket}

  # Board + open detail panel + open stack panel all re-read. Used by the
  # four broadcasts that can change what a single selected task renders,
  # not just which cards are on the board.
  defp full_refresh(socket) do
    socket
    |> refresh_board()
    |> Selection.reload_selected_task()
    |> reload_stacks_panel()
  end

  @doc """
  Apply the four URL-decoded board filters (`:sponsor_filter`, `:board_sort`,
  `:task_search_query`, `:scope_filter`) that `TasksLive.handle_params/3`
  resolves on every mount/patch — task 01a08df0 stage 1 added the last two
  to task 019f3f22/01a0cef1's original pair, so a shared link can carry a
  search and a status scope, not just the sponsor toggle and sort order.

  Sponsor/sort changes are a DB-level re-query (`refresh_board/1`); search is
  an in-memory narrowing over already-loaded sources (`rebuild_board_shapes/1`
  — no DB round trip, mirroring `TasksLive`'s `{:tasks_filters_changed, _}`
  handler for the same assign); scope needs neither of those, because
  `BoardComponent` reads `@scope_filter` directly at render, so assigning it
  below is the whole job.

  At most one of the two board functions runs per call: a sponsor/sort
  change already re-derives the board with the (also newly assigned) search
  query via `refresh_board/1`'s own `maybe_reapply_search/1`, so stacking a
  search-only rebuild on top of that would be redundant work, not a
  correctness fix.

  Task 01a161fd stage 4: a status set, Mine or kind-list change is a
  `refresh_board/1` too, because the desktop board honours them
  (`maybe_reapply_search/1` re-narrows through `BoardData.narrow_board/3`).

  No expanded-stack assign is touched BY THIS FUNCTION directly — a plain,
  unchanged `refresh_board/1` still resets `:expanded_stacks` (pre-existing,
  ADR 0041 acceptance criterion 3) and a plain `rebuild_board_shapes/1`
  still unions in member-matched stacks on a non-blank query (pre-existing,
  task 01a06df3 stage 2); neither behavior is new here, and a call where
  NEITHER branch fires (no filter actually changed — e.g. a bare `/tasks`
  mount) touches `:expanded_stacks` not at all.
  """
  def apply_url_filters(socket, filters, params \\ %{})

  def apply_url_filters(
        socket,
        {new_sponsor, new_sort, new_query, new_scope},
        params
      ) do
    # `?origin=` (task 01a11ec3 stage 4) is decoded HERE from the raw params
    # rather than in `TasksLive.handle_params/3`, whose line count is pinned.
    # So are task 01a161fd stage 1's `project`, `epic`, `status`, the kind
    # LIST and `mine`. With no `project` key, the person's stored project
    # and epic (stage 2, `FilterPrefs`) stand in for it on the first call.
    {socket, params} = FilterPrefs.apply_stored(socket, params)
    new_origin = BoardData.decode_origin_param(params["origin"])
    decoded = BoardData.decode_filter_params(params)

    narrow =
      {decoded.status_filters, decoded.kind_filters, decoded.mine_filter}

    narrow_changed? =
      narrow !=
        {socket.assigns[:status_filters], socket.assigns[:kind_filters],
         socket.assigns[:mine_filter]}

    {socket, selection_changed?} = apply_url_selection(socket, params, decoded)

    board_changed? =
      selection_changed? or
        {new_sponsor, new_sort, new_origin} !=
          {socket.assigns[:sponsor_filter], socket.assigns[:board_sort],
           socket.assigns[:origin_filter]}

    search_changed? = new_query != socket.assigns[:task_search_query]

    socket =
      socket
      |> assign(:sponsor_filter, new_sponsor)
      |> assign(:board_sort, new_sort)
      |> assign(:task_search_query, new_query)
      |> assign(:scope_filter, new_scope)
      |> assign(:origin_filter, new_origin)
      |> assign(:status_filters, decoded.status_filters)
      |> assign(:kind_filters, decoded.kind_filters)
      |> assign(:mine_filter, decoded.mine_filter)

    socket =
      cond do
        # Task 01a166be: the arrival's one board load (`defer_board/1`).
        board_changed? or socket.assigns[:board_pending] == true -> refresh_board(socket)
        search_changed? -> rebuild_board_shapes(socket)
        # Stage 4: the desktop board narrows by these too. A re-query, so
        # clearing the last one restores the DB-derived shapes exactly.
        narrow_changed? -> refresh_board(socket)
        true -> socket
      end

    # A URL that changes nothing (`project=all` over a stored project) still
    # stores its resolved selection. Stage 3: a pick closes the project sheet.
    # Stage 5: the bare entry the LiveView opened on is rewritten in place to
    # the selection it shows, so Back to it shows that selection again.
    socket |> FilterHooks.after_patch() |> FilterPrefs.sync() |> FilterPrefs.pin_url()
  end

  # `?project=` / `?epic=` (task 01a161fd stage 1). The selection itself is
  # the shell's: a changed project goes through `{:sidebar_project_selected,
  # id}` (readability check, archived fallback, epic reload) and `nil`
  # through
  # `{:tasks_filters_cleared}`, so there is no second selection path.
  #
  # Those are messages, handled AFTER this render. Measured: without help
  # the first connected render still shows the previous project. So a
  # project the viewer can read (and that is not archived) is ALSO assigned
  # here, with its epic and epic list, before the send, and the dead render
  # (where nothing is sent) shows it too. An unreadable or archived id is
  # never pre-assigned; the shell's fallback resolves it.
  #
  # Absent `project` keeps today's selection. Absent `epic` keeps the
  # current epic only when `project` is absent too. An epic is honoured only
  # when it belongs to the target project. `{:sidebar_epic_selected, id}`
  # TOGGLES, so it is sent only when the epic actually differs.
  defp apply_url_selection(socket, params, decoded) do
    current_project = socket.assigns[:selected_project_id]
    current_epic = socket.assigns[:selected_epic_id]
    project_key? = Map.has_key?(params, "project")

    target_project = if project_key?, do: decoded.selected_project_id, else: current_project

    target_epic =
      cond do
        Map.has_key?(params, "epic") -> epic_in_project(decoded.selected_epic_id, target_project)
        project_key? -> nil
        true -> current_epic
      end

    cond do
      target_project != current_project ->
        {select_url_project(socket, target_project, target_epic), true}

      # Connected, the epic message refreshes the board itself.
      target_epic != current_epic ->
        {select_url_epic(socket, target_epic, current_epic), not connected?(socket)}

      true ->
        {socket, false}
    end
  end

  defp select_url_project(socket, nil, _epic) do
    socket =
      if connected?(socket) do
        send(self(), {:tasks_filters_cleared})
        FilterPrefs.hold(socket)
      else
        socket
      end

    assign_selection(socket, nil, nil)
  end

  defp select_url_project(socket, project_id, epic_id) do
    project = Selection.readable_project(socket, project_id)
    readable? = not is_nil(project) and not Platform.Projects.archived?(project)

    if inline_selection?(socket) do
      select_inline(socket, readable?, project_id, epic_id)
    else
      select_url_project_later(socket, readable?, project_id, epic_id)
    end
  end

  # Task 01a166be: a URL project change is applied here, inline, and the
  # caller's cond loads the board once. The message path
  # (`{:sidebar_project_selected, _}` -> `select_project/2`, then
  # `{:sidebar_epic_selected, _}`) refreshed the board a second and third
  # time on every arrival with a stored project.
  #
  # Inline only when the message path's extra work is a no-op: no task
  # detail is selected (its `clear_detail/1`) and no execution space is held
  # (its `resubscribe_execution_space(nil)`). That is always true on the
  # LiveView's first `handle_params/3` (mount sets neither). A patch away
  # from an open
  # `/tasks/:task_id` keeps the message path, as do sidebar clicks, which
  # send the message themselves.
  defp inline_selection?(socket) do
    socket.assigns[:board_pending] == true or
      (is_nil(socket.assigns[:selected_task]) and
         is_nil(socket.assigns[:subscribed_execution_space_id]))
  end

  # What the message path does that still applies is done here: the
  # unreadable/archived fallback to All projects, the epic and epic-list
  # load. No hold is taken, so `FilterPrefs.sync/1` writes the resolved
  # selection in the same pass, and only when it differs from the stored one.
  defp select_inline(socket, true, project_id, epic_id),
    do: assign_selection(socket, project_id, epic_id)

  defp select_inline(socket, false, _project_id, _epic_id),
    do: assign_selection(socket, nil, nil)

  defp select_url_project_later(socket, readable?, project_id, epic_id) do
    if connected?(socket) do
      send(self(), {:sidebar_project_selected, project_id})
      # `select_project/2` resets the epic to nil first, so this toggle sets it.
      if readable? and epic_id, do: send(self(), {:sidebar_epic_selected, epic_id})
    end

    socket = if connected?(socket), do: FilterPrefs.hold(socket), else: socket
    if readable?, do: assign_selection(socket, project_id, epic_id), else: socket
  end

  defp select_url_epic(socket, epic_id, current_epic) do
    if connected?(socket) do
      send(self(), {:sidebar_epic_selected, epic_id || current_epic})
      FilterPrefs.hold(socket)
    else
      assign(socket, :selected_epic_id, epic_id)
    end
  end

  defp assign_selection(socket, project_id, epic_id) do
    socket
    |> assign(:selected_project_id, project_id)
    |> assign(:selected_epic_id, epic_id)
    |> PlatformWeb.Tasks.EpicLoaders.reload_epics()
  end

  defp epic_in_project(nil, _project_id), do: nil
  defp epic_in_project(_epic_id, nil), do: nil

  defp epic_in_project(epic_id, project_id) do
    case Tasks.get_epic(epic_id) do
      %{project_id: ^project_id} -> epic_id
      _ -> nil
    end
  end

  @doc """
  The ONE narrowed task list (task 01a161fd stage 1): `:filtered_tasks` and
  `:filtered_count`, `BoardData.narrow_list/3` over `:all_tasks` with the
  socket's own filter assigns. Written by `refresh_board/1` and
  `rebuild_board_shapes/1`, and alone when only an in-memory filter changed.
  """
  def assign_filtered(socket) do
    ctx = %{
      current_user_id: socket.assigns[:current_user_id],
      agent_names: socket.assigns[:agent_names] || %{},
      root_org_slug: socket.assigns[:root_org_slug]
    }

    filtered = BoardData.narrow_list(socket.assigns[:all_tasks] || [], socket.assigns, ctx)

    socket
    |> assign(:filtered_tasks, filtered)
    |> assign(:filtered_count, length(filtered))
  end

  @doc """
  Re-query every board source with the current project / epic / sponsor
  filters applied, and re-derive the render maps.

  Public because the shell's non-PubSub paths (project selection, epic
  selection, filter clear, `handle_params/3`'s sponsor decode) and the
  components' notifies all funnel through it too.

  Wrapped in a `[:platform_web, :tasks, :refresh_board]` telemetry span
  (`:start` / `:stop` / `:exception`, empty metadata) so a test or a local
  probe can count board loads per LiveView process. With no handler
  attached the span costs two ETS lookups.
  """
  def refresh_board(socket) do
    :telemetry.span([:platform_web, :tasks, :refresh_board], %{}, fn ->
      {load_board(socket), %{}}
    end)
  end

  defp load_board(socket) do
    socket = assign(socket, :board_pending, false)

    opts =
      []
      |> maybe_put(:project_id, socket.assigns.selected_project_id)
      |> maybe_put(:epic_id, socket.assigns.selected_epic_id)
      # Stage-2 of task 019f3f22 (ADR-0042 sponsor visibility): thread the
      # active sponsor filter through the query pipeline so both the desktop
      # kanban (`list_by_status/1`) and the mobile section list
      # (`list_all_tasks/1`) narrow to `sponsor_user_id == current_user_id`
      # when the "Sponsored by me" toggle is active. `nil` is the unfiltered
      # passthrough that matches every prior refresh_board call site.
      |> maybe_put(:sponsor_user_id, sponsor_filter_user_id(socket))
      |> maybe_put(:origin, origin_filter_value(socket))
      # RBAC v2 resource scoping (task 01a1386d-e528 stage 3): the viewer's
      # `@access_scope` (LiveAuth). With no grant an internal member's
      # `tasks.read :all` keeps every row; a deny on a project drops it.
      |> maybe_put(:access_scope, access_scope(socket))

    tasks = Tasks.list_all_tasks(opts)

    # Stage 3 of task 019f487e (ADR-0042 Decision 8 stack-level sponsor):
    # the same sponsor filter narrows the stacks query so the "Sponsored by
    # me" pill filters BOTH surfaces with one toggle.
    stack_filters =
      %{}
      |> maybe_put_map(:project_id, socket.assigns.selected_project_id)
      |> maybe_put_map(:sponsor_user_id, sponsor_filter_user_id(socket))
      |> maybe_put_map(:origin, origin_filter_value(socket))
      |> maybe_put_map(:access_scope, access_scope(socket))

    stack_entries = Stacks.list_stacks_with_members(stack_filters)
    {stack_board_data, stacks} = BoardData.split_stack_entries(stack_entries)
    board_sort = board_sort(socket)

    socket
    |> assign(:board_sort, board_sort)
    |> assign(:all_tasks, tasks)
    |> assign(:stacks, stacks)
    |> assign(:stack_board_data, stack_board_data)
    # The same rows as `tasks`, bucketed in memory (task 01a166be stage 3):
    # `list_by_status(opts)` re-ran the widest query and its preloads.
    |> assign(:columns, Tasks.group_by_status(tasks))
    |> assign(:desktop_stacks_by_column, BoardData.group_desktop_stacks(stack_entries))
    |> assign(:board_items, BoardData.group_board_items(tasks, stack_entries, board_sort))
    # Per ADR 0041 acceptance criterion 3, any list refetch collapses
    # ephemeral expansion. `refresh_board/1` is the common funnel for
    # project / epic / filter changes AND every PubSub board event, so
    # resetting here covers all the reset triggers in one place.
    |> assign(:expanded_stacks, MapSet.new())
    |> assign(:pending_plan_count, count_pending_plans(tasks))
    |> assign(:review_counts, pending_review_counts(tasks))
    # Recompute the scope-rail counts whenever the board refreshes so the
    # rail badges stay in sync with project/epic filter changes and PubSub
    # board events.
    # `:access_scope` (task 01a1386d-e528 stage 3): a badge counting hidden
    # tasks would report how many a deny removed.
    |> assign_scope_counts()
    # The all-tasks bucket's key (task 01a116de stage 3): the root org's slug
    # from config or its row, read once per LiveView, never a literal.
    |> assign_new(:root_org_slug, fn -> Platform.Tenancy.root_org_slug() end)
    |> assign(:visible_task_count, length(tasks))
    |> sync_review_request_subscriptions(tasks)
    |> assign_my_tasks(board_sort)
    # An active search must survive PubSub-driven refreshes — the assigns
    # above are the unfiltered sources; re-narrow the derived shapes.
    |> maybe_reapply_search()
    |> assign_filtered()
    # Task 01a161fd stage 2: remember the resolved selection, when it changed.
    |> FilterPrefs.sync()
  end

  @doc """
  Narrow the three derived board shapes in-memory from the unfiltered
  sources every mount/refresh assigns. No DB round-trip per keystroke.

  Public because `FiltersComponent`'s `{:tasks_filters_changed, _}` notify
  lands on the shell, which calls this directly for a search change.
  """
  def rebuild_board_shapes(socket) do
    q = BoardData.normalize_search(socket.assigns.task_search_query)
    board_sort = board_sort(socket)
    agent_names = socket.assigns.agent_names

    searched =
      case q do
        "" ->
          socket.assigns.all_tasks

        _ ->
          Enum.filter(
            socket.assigns.all_tasks,
            &BoardData.task_matches_search?(&1, q, agent_names)
          )
      end

    # Task 01a161fd stage 4: the desktop board also honours the status set,
    # Mine and the kind set, through narrow_list/3's own predicate. With
    # none set this is skipped, so the shapes are exactly the search-only ones.
    narrowing? = BoardData.board_narrowing?(socket.assigns)
    ctx = %{current_user_id: socket.assigns[:current_user_id]}

    tasks =
      if narrowing?,
        do: BoardData.narrow_board(searched, socket.assigns, ctx),
        else: searched

    # A stack card stays while narrowing only if one of its members survives.
    kept_stack_ids =
      if narrowing? do
        socket.assigns.all_tasks
        |> BoardData.narrow_board(socket.assigns, ctx)
        |> MapSet.new(& &1.stack_id)
      end

    # Pair each stack with its board data BEFORE narrowing: the matcher is
    # member-aware (task 01a06df3), and a member's title is only reachable
    # through `:stack_board_data`. Filtering the bare `%Stack{}` list first
    # would drop a stack whose only match is one of its members' titles —
    # and a stacked member has no column of its own to render in.
    stack_entries =
      socket.assigns.stacks
      |> Enum.map(&{&1, Map.get(socket.assigns.stack_board_data, &1.id, %{})})
      |> Enum.filter(fn {stack, board_data} ->
        BoardData.stack_matches_search?(stack, board_data, q) and
          (is_nil(kept_stack_ids) or MapSet.member?(kept_stack_ids, stack.id))
      end)

    # Design review 2026-07-12 ("narrow everything"): while a query is active every
    # on-screen count — columns, scope-rail chips, header total — describes
    # the filtered board. Chips mirror Tasks.count_by_scope/0's current stub
    # semantics (everything under the root org's slug); when that becomes a
    # real per-org GROUP BY this branch needs the matching in-memory group-by
    # over `tasks`.
    #
    # The key is the root org's slug as a STRING (task 01a116de stage 3; a
    # literal before that), matching `count_by_scope/0`'s row-derived keys.
    # An atom key would add a SECOND entry beside the real one rather than
    # overwriting it — the header total is `Map.values |> Enum.sum`, so the
    # searched board's total would double-count instead of failing.
    scope_counts =
      if q == "" do
        socket.assigns.scope_counts_db
      else
        zeroed = Map.new(socket.assigns.scope_counts_db, fn {key, _} -> {key, 0} end)

        case socket.assigns[:root_org_slug] || Platform.Tenancy.root_org_slug() do
          root_slug when is_binary(root_slug) -> Map.put(zeroed, root_slug, length(tasks))
          nil -> zeroed
        end
      end

    socket
    |> assign(:board_sort, board_sort)
    |> assign(:columns, BoardData.bucket_tasks_by_desktop_column(tasks, board_sort))
    |> assign(:desktop_stacks_by_column, BoardData.group_desktop_stacks(stack_entries))
    |> assign(:board_items, BoardData.group_board_items(tasks, stack_entries, board_sort))
    |> assign(:scope_counts, scope_counts)
    |> assign(:visible_task_count, length(tasks))
    |> expand_member_matched_stacks(stack_entries, q)
    |> assign_filtered()
  end

  # The active list order; `:priority` until something (the stage-2 `?sort=`
  # decode) assigns otherwise.
  defp board_sort(socket), do: socket.assigns[:board_sort] || :priority

  defp origin_filter_value(socket) do
    case socket.assigns[:origin_filter] do
      "external_feedback" -> "external_feedback"
      _ -> nil
    end
  end

  # Task 01a06df3 stage 2: a member the search FOUND must be visible without a
  # further click. Matching the parent stack (stage 1) only gets its card onto
  # the board — `BoardComponent` renders the member rows behind
  # `MapSet.member?(@expanded_stacks, item.id)`, and `refresh_board/1` resets
  # `:expanded_stacks` to an empty MapSet immediately before calling
  # `maybe_reapply_search/1`. Without this the found task is still invisible,
  # which is the ticket's original complaint moved one click along.
  #
  # UNION, not replace: a stack the user opened by hand stays open, and only
  # member-matched stacks are added — a stack matched on its own name is
  # hiding nothing, so forcing it open would be unasked-for motion.
  #
  # Gated on a non-empty query. With no query there is nothing to reveal and
  # the user's manual expansion state is the only truth, so this must never
  # write then. `""` is the only value `normalize_search/1` yields for a blank
  # or whitespace query, so the first clause is that whole case.
  defp expand_member_matched_stacks(socket, _stack_entries, ""), do: socket

  defp expand_member_matched_stacks(socket, stack_entries, q) do
    matched =
      for {stack, board_data} <- stack_entries,
          BoardData.stack_member_matches_search?(board_data, q),
          into: MapSet.new(),
          do: stack.id

    expanded = socket.assigns[:expanded_stacks] || MapSet.new()

    assign(socket, :expanded_stacks, MapSet.union(expanded, matched))
  end

  @doc """
  `send_update/2` rather than a direct assign: the stack panel's state
  belongs to `StacksComponent`, and a PubSub refresh is one of the two
  transitions the shell is allowed to drive.
  """
  def reload_stacks_panel(socket) do
    send_update(StacksComponent, id: "tasks-stacks", action: :reload)
    socket
  end

  @doc "The other allowed transition: selection takes the slide-in slot."
  def close_stacks_panel do
    send_update(StacksComponent, id: "tasks-stacks", action: :close)
    :ok
  end

  @doc """
  Keep the `review_requests:<task_id>` subscription set in sync with the
  visible board (stage 5 of task 019e2c25). No-op on a disconnected
  socket — `mount/3`'s guard already skipped the initial subscribe.
  """
  def sync_review_request_subscriptions(socket, tasks) do
    if connected?(socket) do
      current = socket.assigns[:review_request_subscriptions] || MapSet.new()
      desired = MapSet.new(tasks, & &1.id)

      Enum.each(MapSet.difference(desired, current), &ReviewRequests.subscribe_for_task/1)
      Enum.each(MapSet.difference(current, desired), &ReviewRequests.unsubscribe_for_task/1)

      assign(socket, :review_request_subscriptions, desired)
    else
      socket
    end
  end

  @doc "Count of tasks carrying a plan awaiting review — the header badge."
  def count_pending_plans(tasks), do: Enum.count(tasks, &plan_awaiting_review?/1)

  # The one "a plan is awaiting review" predicate, shared by the header badge
  # and `:my_needs_you`. Answered from the preloaded `:plans`, no query (an
  # unloaded or nil `:plans` answers false rather than querying).
  defp plan_awaiting_review?(task), do: Tasks.plan_pending_review?(task)

  # `:my_tasks` / `:my_needs_you` (task 01a1557a-b20a stage 1), the phone
  # Tasks tab's "mine" list. The query is DELIBERATELY independent of the
  # board's project / epic / sponsor / kind / origin / search filters: the
  # list is the viewer's own open tasks whatever the board is filtered to.
  # It honours only `:access_scope`. Sorted with the board's own `board_sort`.
  #
  # Cost per refresh: one task query + one plans preload + one project
  # preload (`list_my_open_tasks/2`) and one grouped ReviewRequest count over
  # the my-tasks ids (`pending_review_counts/1`). Constant, not per task.
  #
  # `:my_needs_you` is the set of my task ids gated on a human: a pending
  # ReviewRequest, or a plan in `pending_review`.
  defp assign_my_tasks(socket, board_sort) do
    my_tasks =
      socket.assigns[:current_user_id]
      |> Tasks.list_my_open_tasks(access_scope: access_scope(socket))
      |> BoardData.sort_items(board_sort)

    review_counts = pending_review_counts(my_tasks)

    needs_you =
      for task <- my_tasks,
          Map.get(review_counts, task.id, 0) > 0 or plan_awaiting_review?(task),
          into: MapSet.new(),
          do: task.id

    socket
    |> assign(:my_tasks, my_tasks)
    |> assign(:my_needs_you, needs_you)
  end

  # No-op passthrough when there is no active query and no board narrowing
  # (status set, Mine, kind set; task 01a161fd stage 4), so the
  # DB-computed shapes from `refresh_board/1` stay authoritative in the
  # common case.
  defp maybe_reapply_search(socket) do
    if BoardData.search_active?(socket.assigns[:task_search_query]) or
         BoardData.board_narrowing?(socket.assigns) do
      rebuild_board_shapes(socket)
    else
      socket
    end
  end

  # Resolve the current filter state to the `sponsor_user_id:` opt value.
  # `:mine` maps to the logged-in user's id (or `nil` if the session lacks
  # one, defensive since `/tasks` requires auth); anything else is
  # unfiltered.
  defp sponsor_filter_user_id(socket) do
    case socket.assigns[:sponsor_filter] do
      :mine -> socket.assigns[:current_user_id]
      _ -> nil
    end
  end

  # A `%Platform.Access.Scope{}` or nil (a socket mounted without LiveAuth's
  # `:default` hook passes nothing, exactly as before).
  defp access_scope(socket) do
    case socket.assigns[:access_scope] do
      %Platform.Access.Scope{} = scope -> scope
      _ -> nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  # One `Tasks.count_by_scope/1` per refresh (task 01a166be; it ran twice
  # with identical args). The rail badges read `:scope_counts`;
  # `:scope_counts_db` keeps the DB read so `rebuild_board_shapes/1` can
  # re-derive `:scope_counts` for a search and restore it when it clears.
  defp assign_scope_counts(socket) do
    counts = Tasks.count_by_scope(access_scope: access_scope(socket))

    socket
    |> assign(:scope_counts, counts)
    |> assign(:scope_counts_db, counts)
  end
end
