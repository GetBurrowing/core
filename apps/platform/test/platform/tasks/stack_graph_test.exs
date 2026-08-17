defmodule Platform.Tasks.StackGraphTest do
  @moduledoc """
  Pure unit tests for the stack dependency DAG.

  Deliberately `async: true` with NO `DataCase` and NO database: every
  function under test takes plain `%Task{}` structs and returns plain data.
  This is the first Tasks logic that is unit-testable without mounting a
  LiveView, and these tests assert things a rendered-HTML test cannot —
  exact pixel coordinates, exact level assignment, and cycle detection on a
  graph the UI would never let you build.
  """
  use ExUnit.Case, async: true

  alias Platform.Tasks.StackGraph
  alias Platform.Tasks.Task

  # Build a bare member struct. `deps` are ids this member DEPENDS ON.
  defp member(id, pos, deps \\ [], opts \\ []) do
    %Task{
      id: id,
      title: Keyword.get(opts, :title, "Task #{id}"),
      status: Keyword.get(opts, :status, "backlog"),
      stack_position: pos,
      dependencies: Enum.map(deps, &%{"task_id" => &1})
    }
  end

  # a → b → c → d, each depending on the previous.
  defp linear_chain do
    [
      member("a", 1),
      member("b", 2, ["a"]),
      member("c", 3, ["b"]),
      member("d", 4, ["c"])
    ]
  end

  #      a
  #     / \
  #    b   c
  #     \ /
  #      d
  defp diamond do
    [
      member("a", 1),
      member("b", 2, ["a"]),
      member("c", 3, ["a"]),
      member("d", 4, ["b", "c"])
    ]
  end

  describe "edges/1" do
    test "keeps only in-stack sibling edges" do
      members = [
        member("a", 1, ["outside-the-stack"]),
        member("b", 2, ["a", "also-outside"])
      ]

      assert StackGraph.edges(members) == [{"b", "a"}]
    end

    test "drops self-edges and de-duplicates" do
      members = [member("a", 1, ["a"]), member("b", 2, ["a", "a"])]
      assert StackGraph.edges(members) == [{"b", "a"}]
    end

    test "is empty for an empty member list" do
      assert StackGraph.edges([]) == []
    end
  end

  describe "acyclic?/2" do
    test "true for a linear chain" do
      members = linear_chain()
      assert StackGraph.acyclic?(MapSet.new(members, & &1.id), StackGraph.edges(members))
    end

    test "true for a diamond" do
      members = diamond()
      assert StackGraph.acyclic?(MapSet.new(members, & &1.id), StackGraph.edges(members))
    end

    test "FALSE for a cycle" do
      # a → b → c → a
      members = [
        member("a", 1, ["c"]),
        member("b", 2, ["a"]),
        member("c", 3, ["b"])
      ]

      refute StackGraph.acyclic?(MapSet.new(members, & &1.id), StackGraph.edges(members))
    end

    test "FALSE for a two-node mutual dependency" do
      members = [member("a", 1, ["b"]), member("b", 2, ["a"])]
      refute StackGraph.acyclic?(MapSet.new(members, & &1.id), StackGraph.edges(members))
    end

    test "true for an acyclic graph that merely contains a diamond plus an isolate" do
      members = diamond() ++ [member("e", 5)]
      assert StackGraph.acyclic?(MapSet.new(members, & &1.id), StackGraph.edges(members))
    end

    test "true for the empty graph" do
      assert StackGraph.acyclic?(MapSet.new(), [])
    end
  end

  describe "dep_edge_summary/1" do
    test "reports a valid DAG with the edge count" do
      assert %{count: 3, valid?: true, text: "3 · valid DAG"} =
               StackGraph.dep_edge_summary(linear_chain())
    end

    test "reports a detected cycle" do
      members = [member("a", 1, ["b"]), member("b", 2, ["a"])]

      assert %{count: 2, valid?: false, text: "2 · cycle detected"} =
               StackGraph.dep_edge_summary(members)
    end

    test "empty member list is a zero-edge valid DAG" do
      assert %{count: 0, valid?: true, text: "0 · valid DAG"} = StackGraph.dep_edge_summary([])
    end
  end

  describe "dag_levels/2" do
    test "linear chain assigns one level per step" do
      members = linear_chain()
      levels = StackGraph.dag_levels(members, StackGraph.edges(members))

      assert levels == %{"a" => 0, "b" => 1, "c" => 2, "d" => 3}
    end

    test "diamond puts the parallel siblings on the same level and the join below both" do
      members = diamond()
      levels = StackGraph.dag_levels(members, StackGraph.edges(members))

      assert levels["a"] == 0
      assert levels["b"] == 1
      assert levels["c"] == 1
      # longest path from the root, not shortest
      assert levels["d"] == 2
    end

    test "a node with a long and a short path lands at the LONGEST depth" do
      # a → b → c, and a → c directly. c must be level 2, not level 1.
      members = [
        member("a", 1),
        member("b", 2, ["a"]),
        member("c", 3, ["a", "b"])
      ]

      levels = StackGraph.dag_levels(members, StackGraph.edges(members))
      assert levels["c"] == 2
    end

    test "every member of a dependency-free stack is a root at level 0" do
      members = [member("a", 1), member("b", 2), member("c", 3)]
      levels = StackGraph.dag_levels(members, StackGraph.edges(members))

      assert levels == %{"a" => 0, "b" => 0, "c" => 0}
    end

    test "a fully cyclic graph yields no levels rather than looping forever" do
      members = [member("a", 1, ["b"]), member("b", 2, ["a"])]
      assert StackGraph.dag_levels(members, StackGraph.edges(members)) == %{}
    end
  end

  describe "stack_dag_layout/1" do
    test "empty member list returns an empty layout" do
      assert StackGraph.stack_dag_layout([]) == %{nodes: [], edges: [], viewbox: {0, 0}}
    end

    test "linear chain stacks one node per row in a single column" do
      layout = StackGraph.stack_dag_layout(linear_chain())

      assert length(layout.nodes) == 4
      by_id = Map.new(layout.nodes, &{&1.id, &1})

      assert Enum.map(~w(a b c d), &by_id[&1].level) == [0, 1, 2, 3]
      assert Enum.map(~w(a b c d), &by_id[&1].col) == [0, 0, 0, 0]
      # every node in column 0 shares an x
      assert by_id["a"].x == by_id["d"].x
      # rows are 76px apart
      assert by_id["b"].y - by_id["a"].y == 76
      # one column wide: 1 * 160 + 2 * 8
      assert layout.viewbox == {176, 288}
    end

    test "diamond places the two middle members side by side on row 1" do
      layout = StackGraph.stack_dag_layout(diamond())
      by_id = Map.new(layout.nodes, &{&1.id, &1})

      assert by_id["b"].level == 1
      assert by_id["c"].level == 1
      assert by_id["b"].y == by_id["c"].y
      # ordered by stack_position within the row
      assert by_id["b"].col == 0
      assert by_id["c"].col == 1
      assert by_id["c"].x - by_id["b"].x == 160
      # two columns wide: 2 * 160 + 2 * 8
      assert elem(layout.viewbox, 0) == 336
    end

    test "edges anchor source bottom-centre to target top-centre" do
      layout = StackGraph.stack_dag_layout([member("a", 1), member("b", 2, ["a"])])
      by_id = Map.new(layout.nodes, &{&1.id, &1})

      assert [edge] = layout.edges
      assert edge.from_id == "b"
      assert edge.to_id == "a"
      assert edge.y1 == by_id["a"].y + by_id["a"].h
      assert edge.y2 == by_id["b"].y
      assert edge.x1 == by_id["a"].x + div(by_id["a"].w, 2)
    end

    test "nodes carry the position glyph and the raw status and title" do
      layout =
        StackGraph.stack_dag_layout([member("a", 2, [], status: "in_review", title: "Ship it")])

      assert [node] = layout.nodes
      assert node.num == "②"
      assert node.status == "in_review"
      assert node.label == "Ship it"
    end

    test "a cyclic stack still lays out rather than crashing" do
      members = [member("a", 1, ["b"]), member("b", 2, ["a"])]
      layout = StackGraph.stack_dag_layout(members)

      # both fall back to level 0 (dep_edge_summary/1 reports the cycle)
      assert Enum.map(layout.nodes, & &1.level) == [0, 0]
      assert length(layout.edges) == 2
    end

    test "layout is deterministic — same input, byte-identical output" do
      members = diamond()
      assert StackGraph.stack_dag_layout(members) == StackGraph.stack_dag_layout(members)
    end

    test "node placement is independent of input order (edge ORDER is not)" do
      members = diamond()
      a = StackGraph.stack_dag_layout(members)
      b = StackGraph.stack_dag_layout(Enum.reverse(members))

      # Nodes are sorted by id, so placement is order-independent.
      assert a.nodes == b.nodes
      assert a.viewbox == b.viewbox
      # Edge records follow the input's edge order, so only the SET matches.
      # Callers must not depend on edge ordering.
      assert Enum.sort(a.edges) == Enum.sort(b.edges)
    end
  end

  describe "stack_position_glyph/1" do
    test "1..10 map to circled digits" do
      assert StackGraph.stack_position_glyph(1) == "①"
      assert StackGraph.stack_position_glyph(10) == "⑩"
    end

    test "11+ falls back to parenthesised digits" do
      assert StackGraph.stack_position_glyph(11) == "(11)"
    end

    test "nil / non-integer is the unknown glyph" do
      assert StackGraph.stack_position_glyph(nil) == "(?)"
      assert StackGraph.stack_position_glyph("2") == "(?)"
    end
  end

  describe "dep_annotation_text/2 (terse, board-card format)" do
    test "ZERO deps renders no annotation at all" do
      members = diamond()
      assert StackGraph.dep_annotation_text(hd(members), members) == nil
    end

    test "ONE dep reads 'needs <glyph>'" do
      members = linear_chain()
      b = Enum.find(members, &(&1.id == "b"))

      assert StackGraph.dep_annotation_text(b, members) == "needs ①"
    end

    test "MULTIPLE deps join with a plus" do
      members = diamond()
      d = Enum.find(members, &(&1.id == "d"))

      assert StackGraph.dep_annotation_text(d, members) == "needs ② + ③"
    end

    test "siblings with an identical dep set are reported as parallel" do
      members = diamond()
      b = Enum.find(members, &(&1.id == "b"))

      assert StackGraph.dep_annotation_text(b, members) == "needs ① • parallel with ③"
    end

    test "out-of-stack deps are ignored entirely" do
      members = [member("a", 1, ["somewhere-else"]), member("b", 2)]
      assert StackGraph.dep_annotation_text(hd(members), members) == nil
    end

    test "non-Task input returns nil rather than raising" do
      assert StackGraph.dep_annotation_text(nil, []) == nil
      assert StackGraph.dep_annotation_text(%{id: "a"}, []) == nil
    end
  end

  describe "member_dep_annotation/2 (verbose, stack detail format)" do
    test "ZERO deps renders no annotation" do
      members = diamond()
      assert StackGraph.member_dep_annotation(hd(members), members) == nil
    end

    test "ONE dep reads 'depends on <glyph>'" do
      members = linear_chain()
      c = Enum.find(members, &(&1.id == "c"))

      assert StackGraph.member_dep_annotation(c, members) == "depends on ②"
    end

    test "MULTIPLE deps join with a plus" do
      members = diamond()
      d = Enum.find(members, &(&1.id == "d"))

      assert StackGraph.member_dep_annotation(d, members) == "depends on ② + ③"
    end

    test "parallel siblings are parenthesised, not bulleted" do
      members = diamond()
      c = Enum.find(members, &(&1.id == "c"))

      assert StackGraph.member_dep_annotation(c, members) == "depends on ① (parallel with ②)"
    end

    test "the two formats deliberately disagree on wording for the same member" do
      members = diamond()
      c = Enum.find(members, &(&1.id == "c"))

      assert StackGraph.dep_annotation_text(c, members) == "needs ① • parallel with ②"
      assert StackGraph.member_dep_annotation(c, members) == "depends on ① (parallel with ②)"
    end

    test "non-Task input returns nil" do
      assert StackGraph.member_dep_annotation(nil, []) == nil
    end
  end
end
