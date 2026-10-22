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
  `:newest` and `:oldest` (task 01a161fd stage 1) are `inserted_at`
  descending / ascending, then id descending.

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

  @sort_modes [:priority, :updated, :newest, :oldest]
  @task_kinds Task.kinds()
  @task_statuses Task.statuses()

  @type sort_mode :: :priority | :updated | :newest | :oldest

  @spec sort_modes() :: [sort_mode()]
  def sort_modes, do: @sort_modes

  @doc """
  Decode a `?sort=` value. `"updated"`, `"newest"` and `"oldest"` select
  their mode; anything else — `nil`, `"priority"`, `"bogus"` — is the
  default `:priority`.
  """
  @spec decode_sort(term()) :: sort_mode()
  def decode_sort("updated"), do: :updated
  def decode_sort("newest"), do: :newest
  def decode_sort("oldest"), do: :oldest
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
  Decode the External Feedback lane (`?origin=external_feedback`, task
  01a11ec3 stage 4). Only the persisted `external_feedback` origin selects a
  lane; every other value, including `internal`, fails open to the full board.
  """
  @spec decode_origin_param(term()) :: :all | String.t()
  def decode_origin_param("external_feedback"), do: "external_feedback"
  def decode_origin_param(_origin), do: :all

  @doc """
  Decode `?project=` (task 01a161fd stage 1): a canonical UUID (downcased,
  `Platform.UUID.cast/1`) selects that project; `"all"`, a non-UUID or a
  missing value is `nil`, the All projects view. Whether the key was
  present at all is the caller's question (`BoardHooks.apply_url_filters/3`
  keeps today's selection when it is absent); readability is checked later,
  on the shell's selection path.
  """
  @spec decode_project_param(term()) :: String.t() | nil
  def decode_project_param(value), do: decode_uuid_param(value)

  @doc "Decode `?epic=`: a canonical UUID, else `nil`. Membership is checked by the caller."
  @spec decode_epic_param(term()) :: String.t() | nil
  def decode_epic_param(value), do: decode_uuid_param(value)

  defp decode_uuid_param(value) do
    case Platform.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  @doc """
  Decode `?status=`, a comma list, to the subset of `Task.statuses/0` it
  names, in `Task.statuses/0` order with no duplicates. Unknown values are
  dropped; nothing valid is `[]` (every status shows).
  """
  @spec decode_status_param(term()) :: [String.t()]
  def decode_status_param(value), do: decode_list_param(value, @task_statuses)

  @doc """
  Decode `?kind=` as a LIST (`:kind_filters`): the subset of `Task.kinds/0`
  it names, in `Task.kinds/0` order. `decode_kind_param/1` stays the
  single-value reading the old kind select and the DB opt use.
  """
  @spec decode_kind_list_param(term()) :: [String.t()]
  def decode_kind_list_param(value), do: decode_list_param(value, @task_kinds)

  defp decode_list_param(value, allowed) when is_binary(value) do
    named = value |> String.split(",") |> Enum.map(&String.trim/1)
    Enum.filter(allowed, &(&1 in named))
  end

  defp decode_list_param(_value, _allowed), do: []

  @doc """
  The single `:kind_filter` derived from `:kind_filters`: the one kind when
  exactly one is set, otherwise `:all` (so a multi-kind URL narrows in
  memory, not in the DB query). A single `?kind=bug` decodes exactly as
  `decode_kind_param/1` always did.
  """
  @spec kind_filter_from_list([String.t()]) :: :all | String.t()
  def kind_filter_from_list([kind]), do: kind
  def kind_filter_from_list(_kinds), do: :all

  @doc """
  Decode `?mine=1` to `:mine_filter`. Only `"1"` is on. (The prototype spells
  it `scope=mine`, but `?scope=` is already the org-scope param.)
  """
  @spec decode_mine_param(term()) :: boolean()
  def decode_mine_param("1"), do: true
  def decode_mine_param(_value), do: false

  @doc """
  Decode every task-01a161fd board param from a raw `params` map into the
  assign-shaped map `tasks_path/1` reads back, so
  `decode_filter_params(params_of(tasks_path(x)))` round-trips `x`.

  `:selected_project_id` / `:selected_epic_id` here are the URL's own
  values; `BoardHooks.apply_url_filters/3` decides whether they apply
  (absent key, epic membership, readability).
  """
  @spec decode_filter_params(map()) :: map()
  def decode_filter_params(params) when is_map(params) do
    kind_filters = decode_kind_list_param(params["kind"])

    %{
      board_sort: decode_sort(params["sort"]),
      selected_project_id: decode_project_param(params["project"]),
      selected_epic_id: decode_epic_param(params["epic"]),
      status_filters: decode_status_param(params["status"]),
      kind_filters: kind_filters,
      kind_filter: kind_filter_from_list(kind_filters),
      mine_filter: decode_mine_param(params["mine"])
    }
  end

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
          sort_mode() | nil,
          String.t() | nil,
          :all | String.t() | nil,
          :all | String.t() | nil
        ) :: String.t()
  def tasks_path(sponsor_filter, board_sort, task_search_query, scope_filter, kind_filter),
    do: tasks_path(sponsor_filter, board_sort, task_search_query, scope_filter, kind_filter, :all)

  @doc """
  `tasks_path/5` plus the External Feedback lane, emitted last as
  `origin=external_feedback` (task 01a11ec3 stage 4).

      iex> PlatformWeb.Tasks.BoardData.tasks_path(:all, :priority, "", :all, "bug", "external_feedback")
      "/tasks?kind=bug&origin=external_feedback"
  """
  def tasks_path(
        sponsor_filter,
        board_sort,
        task_search_query,
        scope_filter,
        kind_filter,
        origin_filter
      ) do
    query =
      Enum.reject(
        [
          sponsor: sponsor_filter == :mine && "mine",
          sort: board_sort in [:updated, :newest, :oldest] && Atom.to_string(board_sort),
          q: search_active?(task_search_query) && task_search_query,
          scope: scope_filter not in [:all, nil] && scope_filter,
          kind: kind_filter not in [:all, nil] && kind_filter,
          origin: origin_filter == "external_feedback" && origin_filter
        ],
        fn {_key, value} -> value == false end
      )

    build_tasks_path(query)
  end

  # `URI.encode_query/1`'s pair encoding, done pair by pair so a LIST value
  # (status, the kind list) comes out as a literal comma list
  # (`status=in_progress,blocked`) instead of `%2C`. A string value encodes
  # byte-identically to `URI.encode_query/1`. The keyword order is kept;
  # `~p"/tasks?#{query}"` does NOT keep it (it emits `sort` before
  # `sponsor`), and the fixed order is what keeps `assert_patched` strings
  # and shared URLs stable.
  defp build_tasks_path([]), do: ~p"/tasks"

  defp build_tasks_path(query) do
    ~p"/tasks" <> "?" <> Enum.map_join(query, "&", &encode_pair/1)
  end

  defp encode_pair({key, values}) when is_list(values),
    do: "#{key}=" <> Enum.map_join(values, ",", &URI.encode_www_form/1)

  defp encode_pair({key, value}), do: URI.encode_query([{key, value}])

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
  @spec tasks_path(:all | :mine | nil, sort_mode() | nil) :: String.t()
  def tasks_path(sponsor_filter, board_sort),
    do: tasks_path(sponsor_filter, board_sort, "", :all, :all)

  @doc """
  The board URL read off a socket's (or component's) assigns — the ONE
  builder every patch back to `/tasks` goes through, so a control that
  changes one param can never drop another.

  Reads `:sponsor_filter`, `:board_sort`, `:task_search_query`,
  `:scope_filter`, `:kind_filter`, `:origin_filter`, and (task 01a161fd
  stage 1) `:selected_project_id`, `:selected_epic_id`, `:status_filters`,
  `:kind_filters` and `:mine_filter`. Keys come out in a fixed order:
  sponsor, sort, q, scope, kind, origin, project, epic, status, mine. `kind`
  is the comma list of `:kind_filters` when it is non-empty, else
  `:kind_filter`. An absent assign is the default and defaults emit nothing,
  so a bare board is still `/tasks`:

      iex> PlatformWeb.Tasks.BoardData.tasks_path(%{})
      "/tasks"
      iex> PlatformWeb.Tasks.BoardData.tasks_path(%{board_sort: :oldest, status_filters: ["in_progress", "blocked"], kind_filters: ["feature", "bug"], mine_filter: true})
      "/tasks?sort=oldest&kind=feature,bug&status=in_progress,blocked&mine=1"
  """
  @spec tasks_path(map()) :: String.t()
  def tasks_path(%{} = assigns) do
    kind_filters = list_assign(assigns[:kind_filters])
    status_filters = list_assign(assigns[:status_filters])

    [
      sponsor: assigns[:sponsor_filter] == :mine && "mine",
      sort:
        assigns[:board_sort] in [:updated, :newest, :oldest] &&
          Atom.to_string(assigns[:board_sort]),
      q: search_active?(assigns[:task_search_query]) && assigns[:task_search_query],
      scope: assigns[:scope_filter] not in [:all, nil] && assigns[:scope_filter],
      kind:
        if(kind_filters == [],
          do: assigns[:kind_filter] not in [:all, nil] && assigns[:kind_filter],
          else: kind_filters
        ),
      origin: assigns[:origin_filter] == "external_feedback" && assigns[:origin_filter],
      project: is_binary(assigns[:selected_project_id]) && assigns[:selected_project_id],
      epic: is_binary(assigns[:selected_epic_id]) && assigns[:selected_epic_id],
      status: status_filters != [] && status_filters,
      mine: assigns[:mine_filter] == true && "1"
    ]
    |> Enum.reject(fn {_key, value} -> value in [false, nil] end)
    |> build_tasks_path()
  end

  defp list_assign(values) when is_list(values), do: values
  defp list_assign(_values), do: []

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
    * `:newest` — `{inserted_at desc, id desc}`.
    * `:oldest` — `{inserted_at asc, id desc}`.

  Timestamps compare as integer microseconds, never by term order on
  `%DateTime{}` structs.
  """
  @spec sort_items([%Task{} | %Stack{}], sort_mode(), map() | nil) ::
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
  defp sort_key(item, :newest, _stack_board_data), do: {-timestamp_us(item.inserted_at)}
  defp sort_key(item, :oldest, _stack_board_data), do: {timestamp_us(item.inserted_at)}

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

  @doc """
  The ONE narrowed task list (task 01a161fd stage 1): every board filter
  applied in memory over already-loaded tasks, then `sort_items/3`.

  `filters` is assign-shaped (the socket's assigns work as-is):
  `:selected_project_id`, `:selected_epic_id`, `:status_filters`,
  `:kind_filters` / `:kind_filter`, `:mine_filter`, `:sponsor_filter`,
  `:task_search_query`, `:origin_filter`, `:scope_filter`, `:board_sort`.
  `ctx` carries `:current_user_id`, `:agent_names` and `:root_org_slug`.
  An absent key is that filter's default, which keeps everything; by default
  every status shows, done included.

    * mine — `Platform.Tasks.mine?/2` (sponsor, or a `"user"` assignee in
      any phase), the same rule as `Tasks.list_my_open_tasks/2`.
    * org scope — mirrors `BoardComponent`'s `board_scope/1` +
      `desktop_column_items_for_scope/6`: `:all`, `nil` or the root org's
      slug keeps everything; any other org slug is empty today.
    * kind — the `:kind_filters` set when non-empty, else the single
      `:kind_filter`.

  Pure: no Repo, no socket.
  """
  @spec narrow_list([%Task{}], map(), map()) :: [%Task{}]
  def narrow_list(tasks, filters, ctx) when is_list(tasks) do
    user_id = ctx[:current_user_id]
    q = normalize_search(filters[:task_search_query])
    agent_names = ctx[:agent_names] || %{}
    statuses = list_assign(filters[:status_filters])
    kinds = narrow_kinds(filters)

    if org_scope_empty?(filters[:scope_filter], ctx[:root_org_slug]) do
      []
    else
      tasks
      |> Enum.filter(fn task ->
        matches_id?(task.project_id, filters[:selected_project_id]) and
          matches_id?(task.epic_id, filters[:selected_epic_id]) and
          board_keep?(task, statuses, kinds, filters[:mine_filter] == true, user_id) and
          (filters[:sponsor_filter] != :mine or
             (is_binary(user_id) and task.sponsor_user_id == user_id)) and
          (filters[:origin_filter] != "external_feedback" or
             task.origin == "external_feedback") and
          (q == "" or task_matches_search?(task, q, agent_names))
      end)
      |> sort_items(narrow_sort(filters[:board_sort]))
    end
  end

  @doc """
  True when the desktop board needs `narrow_board/3` (task 01a161fd stage 4):
  a status set, Mine, or MORE than one kind. A single kind already narrows the
  board's DB query (`:kind_filter`), and project, epic, sponsor and origin are
  DB opts too, so with none of these three set the board is today's board.
  """
  @spec board_narrowing?(map()) :: boolean()
  def board_narrowing?(filters) do
    list_assign(filters[:status_filters]) != [] or filters[:mine_filter] == true or
      length(list_assign(filters[:kind_filters])) > 1
  end

  @doc """
  The desktop board's narrowing (task 01a161fd stage 4): the status set, the
  kind set and Mine, through the SAME predicate `narrow_list/3` applies.
  Order-preserving; it filters and never sorts, so the board's own sort and
  bucketing stay in charge.
  """
  @spec narrow_board([%Task{}], map(), map()) :: [%Task{}]
  def narrow_board(tasks, filters, ctx) when is_list(tasks) do
    statuses = list_assign(filters[:status_filters])
    kinds = narrow_kinds(filters)
    mine? = filters[:mine_filter] == true
    user_id = ctx[:current_user_id]

    Enum.filter(tasks, &board_keep?(&1, statuses, kinds, mine?, user_id))
  end

  defp board_keep?(task, statuses, kinds, mine?, user_id) do
    (statuses == [] or task.status in statuses) and
      (kinds == [] or task.kind in kinds) and
      (not mine? or Platform.Tasks.mine?(task, user_id))
  end

  defp matches_id?(_value, nil), do: true
  defp matches_id?(value, id), do: value == id

  defp narrow_kinds(filters) do
    case {list_assign(filters[:kind_filters]), filters[:kind_filter]} do
      {[], kind} when is_binary(kind) -> [kind]
      {kinds, _kind} -> kinds
    end
  end

  defp narrow_sort(mode) when mode in @sort_modes, do: mode
  defp narrow_sort(_mode), do: :priority

  # `BoardComponent.board_scope/1`: the root org's chip is the unfiltered
  # board; `desktop_column_items_for_scope/6`: any other binary scope is
  # empty.
  defp org_scope_empty?(scope, root_slug) when is_binary(scope), do: scope != root_slug
  defp org_scope_empty?(_scope, _root_slug), do: false

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
