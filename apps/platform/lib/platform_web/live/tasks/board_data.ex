defmodule PlatformWeb.Tasks.BoardData do
  @moduledoc """
  Pure board-shaping functions for the Tasks surface (task 01a008f6 stage 7).

  Everything here is a total function over already-loaded data: column
  definitions, the mobile/desktop bucketing that turns `[%Task{}]` +
  `[{%Stack{}, board_data}]` into the render maps, and the in-memory
  search narrowing. No `Repo`, no socket, no assigns.

  ## List order (task 01a0cef1)

  Every rendered board list is ordered by `sort_items/3` — the mobile
  section list (`group_board_items/3`), the search-narrowed desktop buckets
  (`bucket_tasks_by_desktop_column/2`) and the desktop kanban column merge
  (`BoardComponent.desktop_column_items/5`). The default mode, `:priority`,
  is priority rank (`Platform.Tasks.Task.priority_rank/1`), then newest
  `inserted_at`, then id descending. `:updated` is `updated_at` descending,
  then id descending — the board's pre-task-01a0cef1 recency order.

  The ordering lives HERE and not in the queries on purpose: the in-memory
  re-sorts run after `Platform.Tasks.list_all_tasks/1` /
  `list_by_status/1` return, so a query-level `ORDER BY` would be
  overwritten and never reach the page.

  Stack MEMBER rows inside an expanded stack card are not a list order: the
  component sorts them by `stack_position` (dependency order) and
  `sort_items/3` does not touch them.

  Split out from `PlatformWeb.TasksLive` so both writers of those maps —
  `BoardHooks.refresh_board/1` (DB-backed) and
  `BoardHooks.rebuild_board_shapes/1` (search-narrowed) — share one
  implementation, and so `BoardComponent` can read the column constants
  without depending on the shell.
  """

  use PlatformWeb, :verified_routes

  alias Platform.Tasks.{Epic, Stack, Task}

  # Desktop kanban columns (Stage 2 of Tasks v2 plan, 2026-05-19). Seven
  # explicit buckets — planning + blocked are split out from Backlog so
  # users can see and act on them directly, and `cancelled` folds into
  # Done (handled by `Platform.Tasks.list_by_status/1`).
  #
  # Column render order is the visual reading order across the board.
  # String keys keep the template's HTML id / data-column / `phx-value-*`
  # plumbing unchanged (atoms would serialize as ":backlog").
  @kanban_columns [
    {"backlog", "Backlog"},
    {"planning", "Planning"},
    {"in_progress", "In Progress"},
    {"blocked", "Blocked"},
    {"in_review", "In Review"},
    {"deploying", "Deploying"},
    {"done", "Done"}
  ]

  # Mobile pill order — INTENTIONALLY left at the pre-Stage-2 5-bucket
  # shape per the responsive-scope contract on the Stage 2 dispatch
  # ("Mobile keeps the existing list view unchanged — DO NOT touch the
  # mobile render path"). Planning + blocked tasks continue to roll up
  # under the "Backlog" mobile pill via `@mobile_column_statuses`.
  @mobile_columns [
    {"backlog", "Backlog"},
    {"in_progress", "In Progress"},
    {"in_review", "In Review"},
    {"deploying", "Deploying"},
    {"done", "Done"}
  ]

  # Statuses that map into each MOBILE kanban pill / section (5-bucket
  # shape). `forming` (stack rollup status) + planning + blocked all fold
  # into the Backlog pill on mobile so forming/early-stage work stays
  # visible from the moment it's created.
  @mobile_column_statuses %{
    "backlog" => ~w(backlog planning blocked forming),
    "in_progress" => ~w(in_progress),
    "in_review" => ~w(in_review),
    "deploying" => ~w(deploying),
    "done" => ~w(done)
  }

  # Statuses that map into each DESKTOP kanban column (7-bucket shape).
  # Mirrors `Platform.Tasks.list_by_status/1` so the stack-bucketing
  # helper below produces consistent buckets for the desktop board.
  # `forming` lives under Planning (a fresh stack is being planned);
  # `cancelled` folds into Done (matches the Stage 1 helper).
  @desktop_column_statuses %{
    "backlog" => ~w(backlog),
    "planning" => ~w(planning forming),
    "in_progress" => ~w(in_progress),
    "blocked" => ~w(blocked),
    "in_review" => ~w(in_review),
    "deploying" => ~w(deploying),
    "done" => ~w(done cancelled)
  }

  @sort_modes [:priority, :updated]
  @task_kinds Task.kinds()

  @spec sort_modes() :: [:priority | :updated]
  def sort_modes, do: @sort_modes

  @doc """
  Decode a `?sort=` value. `"updated"` selects `:updated`; anything else —
  `nil`, `"priority"`, `"bogus"` — is the default `:priority`.
  """
  @spec decode_sort(term()) :: :priority | :updated
  def decode_sort("updated"), do: :updated
  def decode_sort(_other), do: :priority

  # A pasted/forged URL is untrusted input (task 01a08df0 stage 1
  # architecture note): a `?q=` with no practical bound could otherwise be
  # copied into the search box and re-run against every board refresh
  # forever. This is generous enough that no real title/id/name search
  # would ever hit it, and truncating rather than rejecting means an
  # over-long shared link still degrades to *some* board instead of an
  # error page.
  @max_search_param_length 200

  @doc """
  Decode a `?q=` value. Any binary is the raw search text, capped at
  #{@max_search_param_length} characters — matching itself happens later via
  `normalize_search/1`, so no trimming/downcasing here. Anything else
  (missing, non-binary) is the default `""`.
  """
  @spec decode_search_param(term()) :: String.t()
  def decode_search_param(q) when is_binary(q), do: String.slice(q, 0, @max_search_param_length)
  def decode_search_param(_other), do: ""

  @doc """
  Decode a `?scope=` value against the viewer's active scopes (the same
  `%{slug: ...}` list `FiltersComponent.parse_scope/2` validates a click
  against, task 01a09287 stage 2). `"all"` is always valid. Anything else
  that isn't a slug the viewer actually has — missing, garbage, or a
  stale/forged org the viewer has since lost access to — falls back to
  `:all`, mirroring `TasksLive`'s private `decode_sponsor_param/1`'s
  malformed-input handling.

  Deliberately more permissive than `parse_scope/2`: a live click on an
  invalid scope is IGNORED there (the current filter is left exactly as it
  was, because there's a real current value to fall back to). A URL round
  trip has no "current value" to preserve — this runs before the board has
  rendered anything — so an invalid `scope` here resolves to the default
  instead of being dropped on the floor.
  """
  @spec decode_scope_param(term(), [%{slug: String.t()}] | nil) :: :all | String.t()
  def decode_scope_param("all", _active_scopes), do: :all

  def decode_scope_param(scope, active_scopes) when is_binary(scope) do
    if Enum.any?(active_scopes || [], &(&1.slug == scope)), do: scope, else: :all
  end

  def decode_scope_param(_scope, _active_scopes), do: :all

  @doc "Decode a shareable task-kind filter, falling back to the unfiltered board."
  @spec decode_kind_param(term()) :: :all | String.t()
  def decode_kind_param(kind) when kind in @task_kinds, do: kind
  def decode_kind_param(_kind), do: :all

  @doc """
  The board URL for a sponsor filter, a sort mode, a search query, a
  status scope and a task kind — the ONE builder for every patch back to `/tasks` (task
  01a0cef1 stage 2, extended by task 01a08df0 stage 1), so no patch can drop
  a param another control set.

  Defaults emit nothing (`:all`, `:priority`, `""`, `:all`, `:all`),
  exactly as `?sponsor=all` is never emitted, so the canonical URL stays
  `/tasks`. Keys come out in a fixed order — sponsor, sort, q, scope, kind:

      iex> PlatformWeb.Tasks.BoardData.tasks_path(:all, :priority, "", :all, :all)
      "/tasks"
      iex> PlatformWeb.Tasks.BoardData.tasks_path(:mine, :updated, "zephyr", "acme", "chore")
      "/tasks?sponsor=mine&sort=updated&q=zephyr&scope=acme&kind=chore"
  """
  @spec tasks_path(
          :all | :mine | nil,
          :priority | :updated | nil,
          String.t() | nil,
          :all | String.t() | nil,
          :all | String.t() | nil
        ) :: String.t()
  def tasks_path(sponsor_filter, board_sort, task_search_query, scope_filter, kind_filter) do
    query =
      Enum.reject(
        [
          sponsor: sponsor_filter == :mine && "mine",
          sort: board_sort == :updated && "updated",
          q: search_active?(task_search_query) && task_search_query,
          scope: scope_filter not in [:all, nil] && scope_filter,
          kind: kind_filter not in [:all, nil] && kind_filter
        ],
        fn {_key, value} -> value == false end
      )

    # `URI.encode_query/1` keeps the keyword order; `~p"/tasks?#{query}"`
    # does NOT (it emits `sort` before `sponsor`), and the fixed order is
    # what keeps `assert_patched` strings and shared URLs stable.
    if query == [], do: ~p"/tasks", else: ~p"/tasks" <> "?" <> URI.encode_query(query)
  end

  def tasks_path(sponsor_filter, board_sort, task_search_query, scope_filter),
    do: tasks_path(sponsor_filter, board_sort, task_search_query, scope_filter, :all)

  @doc """
  The board URL for a sponsor filter and a sort mode only — kept exactly as
  it was before task 01a08df0 (same 2-argument shape, same output for the
  same inputs) so existing pinned callers/tests are untouched. Delegates to
  `tasks_path/4` with the two new fields at their defaults (`""`, `:all`),
  so this arity can never itself carry a `q` or `scope` — a call site that
  has a live search or scope to preserve must use `tasks_path/4` (or the
  `tasks_path/1` map form) instead.

      iex> PlatformWeb.Tasks.BoardData.tasks_path(:all, :priority)
      "/tasks"
      iex> PlatformWeb.Tasks.BoardData.tasks_path(:mine, :updated)
      "/tasks?sponsor=mine&sort=updated"
  """
  @spec tasks_path(:all | :mine | nil, :priority | :updated | nil) :: String.t()
  def tasks_path(sponsor_filter, board_sort),
    do: tasks_path(sponsor_filter, board_sort, "", :all, :all)

  @doc """
  `tasks_path/5` read off a socket's (or component's) assigns
  (`:sponsor_filter`, `:board_sort`, `:task_search_query`, `:scope_filter`,
  `:kind_filter`),
  so a shell/component call site stays one line. An absent assign is the
  default.
  """
  @spec tasks_path(map()) :: String.t()
  def tasks_path(%{} = assigns) do
    tasks_path(
      assigns[:sponsor_filter],
      assigns[:board_sort],
      assigns[:task_search_query],
      assigns[:scope_filter],
      assigns[:kind_filter]
    )
  end

  @doc """
  Order a board list of `%Task{}` and `%Stack{}` items. A TOTAL order: the id
  is the last key, so items that tie on every other key come out the same
  way whatever order they went in.

    * `:priority` — `{priority rank asc, inserted_at desc, id desc}`. A
      `%Stack{}` has no priority of its own; it ranks as its BEST
      (lowest-rank) member, read from `stack_board_data[stack.id].members`,
      and a stack with no ranked member ranks 4 (with unknown/nil
      priorities, after `"low"`). A stack's newest-key is its own
      `inserted_at`.
    * `:updated` — `{updated_at desc, id desc}`.

  Timestamps compare as integer microseconds, never by term order on
  `%DateTime{}` structs.
  """
  @spec sort_items([%Task{} | %Stack{}], :priority | :updated, map() | nil) ::
          [%Task{} | %Stack{}]
  def sort_items(items, mode, stack_board_data \\ %{}) when mode in @sort_modes do
    stack_board_data = stack_board_data || %{}

    items
    |> Enum.map(&{sort_key(&1, mode, stack_board_data), sort_id(&1), &1})
    |> Enum.sort(fn {key_a, id_a, _}, {key_b, id_b, _} ->
      key_a < key_b or (key_a == key_b and id_a >= id_b)
    end)
    |> Enum.map(&elem(&1, 2))
  end

  defp sort_key(item, :priority, stack_board_data),
    do: {item_rank(item, stack_board_data), -timestamp_us(item.inserted_at)}

  defp sort_key(item, :updated, _stack_board_data), do: {-timestamp_us(item.updated_at)}

  defp item_rank(%Task{priority: priority}, _stack_board_data), do: Task.priority_rank(priority)

  defp item_rank(%Stack{id: id}, stack_board_data) do
    case stack_board_data |> Map.get(id, %{}) |> member_list() do
      [] -> 4
      members -> members |> Enum.map(&member_rank/1) |> Enum.min()
    end
  end

  defp item_rank(_item, _stack_board_data), do: 4

  defp member_list(board_data) when is_map(board_data) do
    case Map.get(board_data, :members) do
      members when is_list(members) -> members
      _ -> []
    end
  end

  defp member_list(_board_data), do: []

  defp member_rank(%Task{priority: priority}), do: Task.priority_rank(priority)
  defp member_rank(_member), do: 4

  # `nil` timestamps (unsaved structs) read as the epoch: oldest, so last in
  # a descending key.
  defp timestamp_us(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp timestamp_us(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)

  defp timestamp_us(_other), do: 0

  defp sort_id(%{id: id}) when is_binary(id), do: id
  defp sort_id(_item), do: ""

  @spec kanban_columns() :: [{String.t(), String.t()}]
  def kanban_columns, do: @kanban_columns

  @spec mobile_columns() :: [{String.t(), String.t()}]
  def mobile_columns, do: @mobile_columns

  @doc """
  Bucket `%Task{}` and `%Stack{}` into MOBILE kanban columns (5-bucket
  shape — backlog absorbs planning + blocked + forming). Each column is
  ordered by `sort_items/3` in `mode` (default `:priority`), with stacks
  interleaved among standalone tasks per ADR 0041 acceptance criterion 1.

  `stack_entries` is the `[{%Stack{}, board_data}, ...]` shape returned
  by `Stacks.list_stacks_with_members/1`. Only the `%Stack{}` is placed
  in the column; `board_data` lives in the `:stack_board_data` assign
  (keyed by stack id) so the template can look it up without changing
  the entry shape downstream consumers pattern-match on.

  A task that belongs to a stack (`stack_id != nil`) is suppressed from
  the flat column list — it renders only under its parent stack card.

  Discriminate-by-`__struct__`: a column entry is either `%Task{}` or
  `%Stack{}`. The template pattern-matches `case item.__struct__`.
  """
  def group_board_items(tasks, stack_entries, mode \\ :priority) do
    standalone_tasks = Enum.filter(tasks, &is_nil(&1.stack_id))

    stack_board_data =
      Map.new(stack_entries, fn {stack, board_data} -> {stack.id, board_data} end)

    Enum.reduce(@mobile_columns, %{}, fn {col_key, _label}, acc ->
      statuses = Map.get(@mobile_column_statuses, col_key, [])
      col_tasks = Enum.filter(standalone_tasks, &(&1.status in statuses))

      col_stacks =
        stack_entries
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&(&1.status in statuses))

      merged = sort_items(col_tasks ++ col_stacks, mode, stack_board_data)

      Map.put(acc, col_key, merged)
    end)
  end

  @doc """
  Bucket `%Stack{}` entries into DESKTOP kanban columns (7-bucket shape,
  string-keyed for template parity with `kanban_columns/0`). Tasks for the
  desktop board come from `Platform.Tasks.list_by_status/1` (atom-keyed);
  stacks live in this separate map so the template can merge them
  column-by-column without re-bucketing tasks too.
  """
  def group_desktop_stacks(stack_entries) do
    Enum.reduce(@kanban_columns, %{}, fn {col_key, _label}, acc ->
      statuses = Map.get(@desktop_column_statuses, col_key, [])

      col_stacks =
        stack_entries
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&(&1.status in statuses))

      Map.put(acc, col_key, col_stacks)
    end)
  end

  @doc """
  Split `[{stack, board_data}, ...]` into `{%{stack_id => board_data},
  [stack, ...]}`.
  """
  def split_stack_entries(stack_entries) when is_list(stack_entries) do
    Enum.reduce(stack_entries, {%{}, []}, fn {%Stack{} = stack, board_data},
                                             {data_acc, stacks_acc} ->
      {Map.put(data_acc, stack.id, board_data), [stack | stacks_acc]}
    end)
    |> then(fn {data_acc, stacks_acc} -> {data_acc, Enum.reverse(stacks_acc)} end)
  end

  @doc """
  In-memory equivalent of `Platform.Tasks.list_by_status/1`'s bucket shape
  (atom keys) for a search-filtered `:columns` map, each bucket ordered by
  `sort_items/3` in `mode` (default `:priority`).
  """
  def bucket_tasks_by_desktop_column(tasks, mode \\ :priority) do
    Map.new(@desktop_column_statuses, fn {col_key, statuses} ->
      bucket =
        tasks
        |> Enum.filter(&(&1.status in statuses))
        |> sort_items(mode)

      {String.to_existing_atom(col_key), bucket}
    end)
  end

  @doc "Downcased, trimmed search query. `nil` normalises to an empty string."
  def normalize_search(nil), do: ""
  def normalize_search(q) when is_binary(q), do: q |> String.trim() |> String.downcase()

  @doc "True when the query narrows the board."
  def search_active?(query), do: normalize_search(query) != ""

  @doc """
  A task matches when the (downcased) query is a substring of its id,
  title, sponsor display name, assignee/agent display name, or epic name.
  """
  def task_matches_search?(%Task{} = task, q, agent_names) do
    [
      task.id,
      task.title,
      sponsor_search_name(task),
      PlatformWeb.Tasks.TaskDisplay.assignee_name(task, agent_names),
      epic_search_name(task)
    ]
    |> Enum.any?(fn value ->
      is_binary(value) and String.contains?(String.downcase(value), q)
    end)
  end

  @doc """
  A stack matches when the query hits the stack's own `id`/`name` **or any
  member's `id`/`title`** (task 01a06df3 stage 1).

  Member-aware by construction: a stacked task is suppressed from the flat
  column list (`group_board_items/3` drops `stack_id != nil`) and a
  `stack_pending` member has no desktop/mobile column to land in at all, so
  the parent stack card is the *only* place a member can render. Matching on
  `stack.id`/`stack.name` alone therefore hid a real member from a query on
  its own title — the ticket's observed failure, twice, by two people.

  `board_data` is one value of the `:stack_board_data` assign
  (`Stacks.build_board_data/1`'s shape). A missing or nil `:members` key
  reads as `[]` rather than raising: the call site defaults an unknown stack
  id to `%{}`, so a stack whose board data has not been built yet must still
  match on its own fields.
  """
  def stack_matches_search?(_stack, _board_data, ""), do: true

  def stack_matches_search?(%Stack{} = stack, board_data, q) do
    Enum.any?([stack.id, stack.name], &contains_query?(&1, q)) or
      stack_member_matches_search?(board_data, q)
  end

  @doc """
  True when the query hits **a member's** `id`/`title` specifically — the
  member half of `stack_matches_search?/3`, split out so there is exactly one
  definition of "this stack was found because of one of its members".

  `BoardHooks.rebuild_board_shapes/1` needs that distinction and not just the
  boolean from `stack_matches_search?/3`: a stack found via a member must be
  auto-expanded so the member is visible without a further click (task
  01a06df3 stage 2), while a stack found by its own name has nothing hidden
  and is left as the user left it. Duplicating the member walk in the hook
  would let the two answers drift the moment a field is added here.

  Always false for an empty query — `stack_matches_search?/3`'s `""` fast path
  means "no query narrows nothing", which is not a member match.
  """
  def stack_member_matches_search?(_board_data, ""), do: false

  def stack_member_matches_search?(board_data, q) when is_binary(q) do
    board_data
    |> member_search_values()
    |> Enum.any?(&contains_query?(&1, q))
  end

  defp contains_query?(value, q),
    do: is_binary(value) and String.contains?(String.downcase(value), q)

  defp member_search_values(board_data) when is_map(board_data) do
    case Map.get(board_data, :members) do
      members when is_list(members) ->
        Enum.flat_map(members, fn
          %Task{id: id, title: title} -> [id, title]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp member_search_values(_board_data), do: []

  defp sponsor_search_name(%Task{sponsor: %{name: name, email: email}}), do: name || email
  defp sponsor_search_name(_task), do: nil

  defp epic_search_name(%Task{epic: %Epic{name: name}}), do: name
  defp epic_search_name(_task), do: nil
end
