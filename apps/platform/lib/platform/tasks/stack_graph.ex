defmodule Platform.Tasks.StackGraph do
  @moduledoc """
  Pure graph math for task stacks.

  Hoisted out of `PlatformWeb.TasksLive` by task 01a008f6 stage 3. Every
  function here takes and returns plain data — no socket, no assigns, no
  LiveView. That makes the stack dependency DAG the first piece of Tasks
  logic that is unit-testable without mounting a LiveView, which is the
  point of the move as much as the line count is.

  Three families live here:

    * **Cycle detection** — `acyclic?/2` and the `dep_edge_summary/1`
      wrapper that the stack detail meta-grid renders.
    * **Layout** — `stack_dag_layout/1` and its `dag_levels/2` helper turn
      a member list into a render-ready bag of nodes, edges and a viewBox.
    * **Annotations** — `dep_annotation_text/2` (terse, board-card inline
      expansion) and `member_dep_annotation/2` (verbose, stack detail
      member list). The two wordings diverged deliberately; see their docs.

  Presentation concerns (Tailwind classes, SVG fills, captions) deliberately
  did NOT come along — they live in `PlatformWeb.Tasks.StackStyles`.
  """

  alias Platform.Tasks
  alias Platform.Tasks.Task

  # Pixel constants (mock canvas 019e1a16 rev 2 dimensions):
  #   row_height = 76    (vertical stride between rows)
  #   col_width  = 160   (horizontal stride between columns)
  #   node_w     = 140   (rect width)
  #   node_h     = 44    (rect height)
  #   pad        = 8     (left/top padding inside the viewBox)
  @dag_row_height 76
  @dag_col_width 160
  @dag_node_w 140
  @dag_node_h 44
  @dag_pad 8

  @doc """
  In-stack dependency edge list for `members`.

  Returns `[{from_id, to_id}, ...]` where `from` depends on `to`. Edges
  leaving the stack (and self-edges) are dropped — only sibling-to-sibling
  deps survive.
  """
  @spec edges([Task.t()]) :: [{String.t(), String.t()}]
  def edges(members) when is_list(members) do
    member_ids = MapSet.new(members, & &1.id)

    Enum.flat_map(members, fn %Task{id: from_id} = m ->
      m
      |> Tasks.dependency_task_ids()
      |> Enum.reject(&(&1 == from_id))
      |> Enum.filter(&MapSet.member?(member_ids, &1))
      |> Enum.uniq()
      |> Enum.map(&{from_id, &1})
    end)
  end

  @doc """
  Meta-grid summary of the in-stack dep subgraph.

  Mirrors `Stacks.build_board_data/1`'s edge-count logic but also keeps the
  full edge list so a Kahn check for cycles can run over it.

  Returns `%{count: n, valid?: bool, text: "n · valid DAG" | "n · cycle detected"}`.
  """
  @spec dep_edge_summary([Task.t()]) :: %{
          count: non_neg_integer(),
          valid?: boolean(),
          text: String.t()
        }
  def dep_edge_summary(members) when is_list(members) do
    member_ids_set = MapSet.new(members, & &1.id)
    edge_list = edges(members)
    valid? = acyclic?(member_ids_set, edge_list)

    text =
      if valid? do
        "#{length(edge_list)} · valid DAG"
      else
        "#{length(edge_list)} · cycle detected"
      end

    %{count: length(edge_list), valid?: valid?, text: text}
  end

  @doc """
  Lightweight Kahn-style topological check.

  Returns true iff every node can be peeled away in some order — i.e. the
  graph is acyclic. Edges are `{from, to}` where `from` depends on `to`.
  Treating `from` as the dependent, `from` has an incoming "dependency"
  edge from `to`, so we count `from` occurrences as in-degree (= number of
  un-peeled deps remaining). Roots (members with no in-stack deps) start at
  in-degree 0 and peel first; removing them decrements the in-degree of any
  member that had THEM as a dep.

  `node_ids_set` may be a `MapSet` or any enumerable of ids.
  """
  @spec acyclic?(Enumerable.t(), [{String.t(), String.t()}]) :: boolean()
  def acyclic?(node_ids_set, edge_list) do
    in_degree =
      Enum.reduce(edge_list, Map.new(node_ids_set, &{&1, 0}), fn {from, _to}, acc ->
        Map.update(acc, from, 1, &(&1 + 1))
      end)

    do_acyclic(in_degree, edge_list)
  end

  defp do_acyclic(in_degree, _edges) when map_size(in_degree) == 0, do: true

  defp do_acyclic(in_degree, edge_list) do
    case Enum.find(in_degree, fn {_id, deg} -> deg == 0 end) do
      nil ->
        false

      {id, _} ->
        in_degree = Map.delete(in_degree, id)

        # Removing `id` (a peeled root) frees any member whose dep set
        # included `id` — those are edges `{dependent, id}`; decrement
        # in_degree of `dependent`.
        in_degree =
          Enum.reduce(edge_list, in_degree, fn
            {dependent, ^id}, acc -> Map.update(acc, dependent, 0, &max(&1 - 1, 0))
            _, acc -> acc
          end)

        do_acyclic(in_degree, edge_list)
    end
  end

  @doc """
  Turn a list of stack member tasks into a render-ready bag of nodes +
  edges + a viewBox tuple. The dep DAG SVG in the stack detail panel
  renders straight off this map.

  Algorithm:

    1. Build the in-stack edge list `{from_id, to_id}` where `from`
       depends on `to`. Edges leaving the stack are dropped — only
       sibling-to-sibling deps land on the canvas.
    2. Assign each node a topological **level** (row index) equal to the
       longest path from a root (in-degree 0) to that node. This means
       siblings runnable in parallel land on the same row even if one
       has a transitive ancestor that the other lacks. Nodes with cyclic
       deps fall back to level 0 so the layout never crashes; the meta-
       grid surfaces "cycle detected" separately.
    3. Within each level, sort by `stack_position` (stable, deterministic)
       and distribute columns left-to-right starting from 0.
    4. Translate (level, col) → pixel (x, y) via the `@dag_*` constants.
       Edge endpoints anchor to bottom-center of source, top-center of
       target so arrows visibly flow downward (matches mock).
  """
  @spec stack_dag_layout([Task.t()]) :: %{
          nodes: [map()],
          edges: [map()],
          viewbox: {non_neg_integer(), non_neg_integer()}
        }
  def stack_dag_layout([]) do
    %{nodes: [], edges: [], viewbox: {0, 0}}
  end

  def stack_dag_layout(members) when is_list(members) do
    edge_list = edges(members)
    levels = dag_levels(members, edge_list)

    # Group node ids by level; within a level, sort by stack_position so
    # the layout is deterministic and matches "dispatch order" left-to-
    # right within each row.
    by_level =
      members
      |> Enum.group_by(fn %Task{id: id} -> Map.get(levels, id, 0) end)
      |> Map.new(fn {lvl, ms} ->
        sorted = Enum.sort_by(ms, & &1.stack_position)
        {lvl, sorted}
      end)

    max_cols =
      by_level
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.max(fn -> 1 end)

    num_levels = (by_level |> Map.keys() |> Enum.max(fn -> 0 end)) + 1

    nodes =
      by_level
      |> Enum.flat_map(fn {level, ms} ->
        ms
        |> Enum.with_index()
        |> Enum.map(fn {%Task{} = m, col} ->
          x = @dag_pad + col * @dag_col_width + div(@dag_col_width - @dag_node_w, 2)
          y = @dag_pad + level * @dag_row_height

          %{
            id: m.id,
            level: level,
            col: col,
            x: x,
            y: y,
            w: @dag_node_w,
            h: @dag_node_h,
            status: m.status,
            label: m.title,
            num: stack_position_glyph(m.stack_position)
          }
        end)
      end)
      |> Enum.sort_by(& &1.id)

    node_by_id = Map.new(nodes, &{&1.id, &1})

    # Edge endpoints: source bottom-center → target top-center. Edges
    # whose endpoints aren't both placed (shouldn't happen for in-stack
    # edges, but guard anyway) are dropped.
    edge_records =
      edge_list
      |> Enum.flat_map(fn {from_id, to_id} ->
        with %{} = src <- Map.get(node_by_id, to_id),
             %{} = dst <- Map.get(node_by_id, from_id) do
          [
            %{
              from_id: from_id,
              to_id: to_id,
              x1: src.x + div(src.w, 2),
              y1: src.y + src.h,
              x2: dst.x + div(dst.w, 2),
              y2: dst.y
            }
          ]
        else
          _ -> []
        end
      end)

    # viewBox: width = max columns * col_width + 2*pad ; height = rows *
    # row_height + node_h + 2*pad (so the bottom row's full rect fits).
    width = max(max_cols, 1) * @dag_col_width + 2 * @dag_pad
    height = num_levels * @dag_row_height + @dag_node_h - @dag_row_height + 2 * @dag_pad
    height = max(height, @dag_node_h + 2 * @dag_pad)

    %{nodes: nodes, edges: edge_records, viewbox: {width, height}}
  end

  @doc """
  Compute a level map `%{node_id => longest_path_from_root}` via
  topological propagation.

  Roots (no in-stack deps) start at 0; each successor's level becomes
  `max(parent_level + 1)` across its parents. If the graph contains a
  cycle, nodes that never get processed are simply absent from the map —
  callers default them to level 0 (`dep_edge_summary/1` already flags
  cycles separately).
  """
  @spec dag_levels([Task.t()], [{String.t(), String.t()}]) :: %{String.t() => non_neg_integer()}
  def dag_levels(members, edge_list) do
    # `parents` :: %{node_id => MapSet of predecessor ids}
    parents =
      Enum.reduce(edge_list, Map.new(members, fn %{id: id} -> {id, MapSet.new()} end), fn {from,
                                                                                           to},
                                                                                          acc ->
        Map.update(acc, from, MapSet.new([to]), &MapSet.put(&1, to))
      end)

    # `children` :: %{node_id => MapSet of successor ids}
    children =
      Enum.reduce(edge_list, Map.new(members, fn %{id: id} -> {id, MapSet.new()} end), fn {from,
                                                                                           to},
                                                                                          acc ->
        Map.update(acc, to, MapSet.new([from]), &MapSet.put(&1, from))
      end)

    in_degree = Map.new(parents, fn {id, ps} -> {id, MapSet.size(ps)} end)

    roots =
      in_degree
      |> Enum.filter(fn {_id, deg} -> deg == 0 end)
      |> Enum.map(&elem(&1, 0))

    initial_levels = Map.new(roots, &{&1, 0})

    do_dag_levels(roots, in_degree, children, initial_levels)
  end

  defp do_dag_levels([], _in_degree, _children, levels), do: levels

  defp do_dag_levels([id | rest], in_degree, children, levels) do
    parent_level = Map.get(levels, id, 0)
    succs = Map.get(children, id, MapSet.new())

    {in_degree, levels, queued} =
      Enum.reduce(succs, {in_degree, levels, []}, fn child, {ind, lvls, q} ->
        child_level = max(Map.get(lvls, child, 0), parent_level + 1)
        ind = Map.update(ind, child, 0, &max(&1 - 1, 0))
        lvls = Map.put(lvls, child, child_level)

        q =
          if Map.get(ind, child, 0) == 0 do
            [child | q]
          else
            q
          end

        {ind, lvls, q}
      end)

    do_dag_levels(rest ++ Enum.reverse(queued), in_degree, children, levels)
  end

  @doc """
  Numbered-node glyph for a member's `stack_position`.

  Positions 1..10 map to the unicode circled digits per ADR 0041
  §"UI surface — inline expansion"; positions 11+ fall back to `(N)` so the
  layout never breaks on absurdly large stacks.
  """
  @spec stack_position_glyph(term()) :: String.t()
  def stack_position_glyph(pos) when is_integer(pos) and pos in 1..10 do
    Enum.at(~w(① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩), pos - 1)
  end

  def stack_position_glyph(pos) when is_integer(pos), do: "(#{pos})"
  def stack_position_glyph(_), do: "(?)"

  @doc """
  Terse dep-annotation line for a single in-stack member — the T7 board
  card inline expansion format. Mirrors the mock's `needs ① • parallel with ②`:

    * `needs <glyph>[ + <glyph>...]` — joined with ` + ` when the member has
      multiple in-stack predecessors.
    * `parallel with <glyph>[ + ...]` — appended (separated by ` • `) when
      another in-stack member at a different position shares the same dep
      set (siblings runnable in parallel).

  Returns `nil` when the member has no in-stack deps — the template
  suppresses the dep-line entirely in that case (per mock: member ① has no
  annotation line).
  """
  @spec dep_annotation_text(term(), [Task.t()]) :: String.t() | nil
  def dep_annotation_text(%Task{} = member, members) when is_list(members) do
    annotate(member, members, &terse_phrasing/2)
  end

  def dep_annotation_text(_, _), do: nil

  @doc """
  Verbose dep-annotation line for a stack detail member row — the T8
  stage 4 format: `depends on ① + ②` / `depends on ① (parallel with ②)`.

  Diverges from `dep_annotation_text/2` on purpose: the panel mock (canvas
  019e1a16 rev 2) uses the longer "depends on" wording with parens for
  parallels, while the inline board card stays terse with "needs". Returns
  `nil` when the member has no in-stack predecessors so the template can
  suppress the row.

  Parallel detection: members at a different `stack_position` whose
  in-stack dep set is identical to this member's. Same shape as the DAG
  layout's same-level grouping, so the textual annotation and the SVG
  layout never disagree about who is parallel with whom.
  """
  @spec member_dep_annotation(term(), [Task.t()]) :: String.t() | nil
  def member_dep_annotation(%Task{} = member, members) when is_list(members) do
    annotate(member, members, &verbose_phrasing/2)
  end

  def member_dep_annotation(_, _), do: nil

  # Shared body of the two annotation formats. Both compute the same two
  # glyph strings (`deps` and `parallel`) and differ only in how they are
  # worded, so the computation lives here once and the wording is injected.
  defp annotate(%Task{} = member, members, phrasing) do
    member_ids = MapSet.new(members, & &1.id)

    self_deps =
      member
      |> Tasks.dependency_task_ids()
      |> Enum.reject(&(&1 == member.id))
      |> Enum.filter(&MapSet.member?(member_ids, &1))
      |> Enum.uniq()

    case self_deps do
      [] ->
        nil

      _ ->
        deps =
          self_deps
          |> Enum.map(fn dep_id ->
            members
            |> Enum.find(&(&1.id == dep_id))
            |> case do
              nil -> nil
              %Task{stack_position: pos} -> stack_position_glyph(pos)
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" + ")

        parallel =
          members
          |> Enum.filter(fn other ->
            other.id != member.id and
              other.stack_position != member.stack_position and
              dep_set(other, member_ids) == MapSet.new(self_deps) and
              MapSet.size(dep_set(other, member_ids)) > 0
          end)
          |> Enum.map(&stack_position_glyph(&1.stack_position))
          |> Enum.sort()
          |> Enum.join(" + ")

        if deps == "", do: nil, else: phrasing.(deps, parallel)
    end
  end

  defp terse_phrasing(deps, ""), do: "needs #{deps}"
  defp terse_phrasing(deps, parallel), do: "needs #{deps} • parallel with #{parallel}"

  defp verbose_phrasing(deps, ""), do: "depends on #{deps}"
  defp verbose_phrasing(deps, parallel), do: "depends on #{deps} (parallel with #{parallel})"

  # In-stack dep id set for a member (used by `parallel with` detection).
  defp dep_set(%Task{} = task, member_ids_set) do
    task
    |> Tasks.dependency_task_ids()
    |> Enum.reject(&(&1 == task.id))
    |> Enum.filter(&MapSet.member?(member_ids_set, &1))
    |> MapSet.new()
  end
end
