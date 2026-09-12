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
      `:desktop_stacks_by_column`, `:board_items`, `:expanded_stacks`,
      `:review_counts`, `:pending_plan_count`, `:scope_counts`,
      `:scope_counts_db`, `:visible_task_count`,
      `:review_request_subscriptions`
    * Info: `{:task_updated, _}`, `{:task_created, _}`, `{:task_deleted, _}`,
      `{:tasks_batch_deleted, _, _}`, `{:epic_created, _}`,
      `{:epic_updated, _}`, `{:plan_updated, _}`,
      `{:stack_gate_opened, _, _}`, `{:review_request_pending, _}`,
      `{:review_request_resolved, _}`

  The component re-renders from the assigns the hook writes — no
  `send_update/2` mediation is needed for board data, because
  `BoardComponent` takes every board map as an attr and LiveView diffs
  attrs on the parent's re-render. `send_update/2` IS used for the stack
  panel, whose state belongs to `StacksComponent` and is not an attr.

  ## Usage

      # In TasksLive.mount/3, after the initial board assigns:
      socket = PlatformWeb.Tasks.BoardHooks.attach(socket)
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]

  alias Platform.Tasks
  alias Platform.Tasks.ReviewRequests
  alias Platform.Tasks.Stacks
  alias PlatformWeb.Tasks.BoardData
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
    attach_hook(socket, :board_info, :handle_info, &handle_info/2)
  end

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
  Re-query every board source with the current project / epic / sponsor
  filters applied, and re-derive the render maps.

  Public because the shell's non-PubSub paths (project selection, epic
  selection, filter clear, `handle_params/3`'s sponsor decode) and the
  components' notifies all funnel through it too.
  """
  def refresh_board(socket) do
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

    tasks = Tasks.list_all_tasks(opts)

    # Stage 3 of task 019f487e (ADR-0042 Decision 8 stack-level sponsor):
    # the same sponsor filter narrows the stacks query so the "Sponsored by
    # me" pill filters BOTH surfaces with one toggle.
    stack_filters =
      %{}
      |> maybe_put_map(:project_id, socket.assigns.selected_project_id)
      |> maybe_put_map(:sponsor_user_id, sponsor_filter_user_id(socket))

    stack_entries = Stacks.list_stacks_with_members(stack_filters)
    {stack_board_data, stacks} = BoardData.split_stack_entries(stack_entries)

    socket
    |> assign(:all_tasks, tasks)
    |> assign(:stacks, stacks)
    |> assign(:stack_board_data, stack_board_data)
    |> assign(:columns, Tasks.list_by_status(opts))
    |> assign(:desktop_stacks_by_column, BoardData.group_desktop_stacks(stack_entries))
    |> assign(:board_items, BoardData.group_board_items(tasks, stack_entries))
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
    |> assign(:scope_counts, Tasks.count_by_scope())
    |> assign(:scope_counts_db, Tasks.count_by_scope())
    |> assign(:visible_task_count, length(tasks))
    |> sync_review_request_subscriptions(tasks)
    # An active search must survive PubSub-driven refreshes — the assigns
    # above are the unfiltered sources; re-narrow the derived shapes.
    |> maybe_reapply_search()
  end

  @doc """
  Narrow the three derived board shapes in-memory from the unfiltered
  sources every mount/refresh assigns. No DB round-trip per keystroke.

  Public because `FiltersComponent`'s `{:tasks_filters_changed, _}` notify
  lands on the shell, which calls this directly for a search change.
  """
  def rebuild_board_shapes(socket) do
    q = BoardData.normalize_search(socket.assigns.task_search_query)
    agent_names = socket.assigns.agent_names

    tasks =
      case q do
        "" ->
          socket.assigns.all_tasks

        _ ->
          Enum.filter(
            socket.assigns.all_tasks,
            &BoardData.task_matches_search?(&1, q, agent_names)
          )
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
        BoardData.stack_matches_search?(stack, board_data, q)
      end)

    # Marlowe 2026-07-12 ("narrow everything"): while a query is active every
    # on-screen count — columns, scope-rail chips, header total — describes
    # the filtered board. Chips mirror Tasks.count_by_scope/0's current stub
    # semantics (everything under "fabrikam"); when that becomes a real per-org
    # GROUP BY this branch needs the matching in-memory group-by over `tasks`.
    #
    # The key is the STRING "fabrikam" since task 01a09287 stage 2 re-keyed
    # `count_by_scope/0` on the org rows. As `:fabrikam` it would have added a
    # SEVENTH entry beside the real one rather than overwriting it — the
    # header total is `Map.values |> Enum.sum`, so the searched board's total
    # would have double-counted instead of failing.
    scope_counts =
      if q == "" do
        socket.assigns.scope_counts_db
      else
        socket.assigns.scope_counts_db
        |> Map.new(fn {key, _} -> {key, 0} end)
        |> Map.put("fabrikam", length(tasks))
      end

    socket
    |> assign(:columns, BoardData.bucket_tasks_by_desktop_column(tasks))
    |> assign(:desktop_stacks_by_column, BoardData.group_desktop_stacks(stack_entries))
    |> assign(:board_items, BoardData.group_board_items(tasks, stack_entries))
    |> assign(:scope_counts, scope_counts)
    |> assign(:visible_task_count, length(tasks))
    |> expand_member_matched_stacks(stack_entries, q)
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
  def count_pending_plans(tasks) do
    Enum.count(tasks, fn task ->
      Enum.any?(task.plans || [], &(&1.status == "pending_review"))
    end)
  end

  # No-op passthrough when there is no active query, so the DB-computed
  # shapes from `refresh_board/1` stay authoritative in the common case.
  defp maybe_reapply_search(socket) do
    if BoardData.search_active?(socket.assigns[:task_search_query]) do
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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)
end
