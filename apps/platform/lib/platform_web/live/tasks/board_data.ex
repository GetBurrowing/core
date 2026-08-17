defmodule PlatformWeb.Tasks.BoardData do
  @moduledoc """
  Pure board-shaping functions for the Tasks surface (task 01a008f6 stage 7).

  Everything here is a total function over already-loaded data: column
  definitions, the mobile/desktop bucketing that turns `[%Task{}]` +
  `[{%Stack{}, board_data}]` into the render maps, and the in-memory
  search narrowing. No `Repo`, no socket, no assigns.

  Split out from `PlatformWeb.TasksLive` so both writers of those maps —
  `BoardHooks.refresh_board/1` (DB-backed) and
  `BoardHooks.rebuild_board_shapes/1` (search-narrowed) — share one
  implementation, and so `BoardComponent` can read the column constants
  without depending on the shell.
  """

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

  @spec kanban_columns() :: [{String.t(), String.t()}]
  def kanban_columns, do: @kanban_columns

  @spec mobile_columns() :: [{String.t(), String.t()}]
  def mobile_columns, do: @mobile_columns

  @doc """
  Bucket `%Task{}` and `%Stack{}` into MOBILE kanban columns (5-bucket
  shape — backlog absorbs planning + blocked + forming). Sorted within
  each column by `updated_at` descending so stacks interleave with
  standalone tasks per ADR 0041 acceptance criterion 1.

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
  def group_board_items(tasks, stack_entries) do
    standalone_tasks = Enum.filter(tasks, &is_nil(&1.stack_id))

    Enum.reduce(@mobile_columns, %{}, fn {col_key, _label}, acc ->
      statuses = Map.get(@mobile_column_statuses, col_key, [])
      col_tasks = Enum.filter(standalone_tasks, &(&1.status in statuses))

      col_stacks =
        stack_entries
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&(&1.status in statuses))

      merged =
        (col_tasks ++ col_stacks)
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

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
  (atom keys, `updated_at` desc within each bucket) so a search-filtered
  `:columns` map is indistinguishable downstream.
  """
  def bucket_tasks_by_desktop_column(tasks) do
    Map.new(@desktop_column_statuses, fn {col_key, statuses} ->
      bucket =
        tasks
        |> Enum.filter(&(&1.status in statuses))
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

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

  def stack_matches_search?(_stack, ""), do: true

  def stack_matches_search?(%Stack{} = stack, q) do
    [stack.id, stack.name]
    |> Enum.any?(fn value ->
      is_binary(value) and String.contains?(String.downcase(value), q)
    end)
  end

  defp sponsor_search_name(%Task{sponsor: %{name: name, email: email}}), do: name || email
  defp sponsor_search_name(_task), do: nil

  defp epic_search_name(%Task{epic: %Epic{name: name}}), do: name
  defp epic_search_name(_task), do: nil
end
