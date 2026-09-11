defmodule PlatformWeb.Tasks.BoardDataSearchTest do
  @moduledoc """
  `stack_matches_search?/3` is member-aware (task 01a06df3 stage 1).

  The ticket: a task added to a stack vanished from the board, and two people
  independently concluded a real ticket did not exist after searching for it
  by name. The mechanism is render-time, not query-time — `list_all_tasks/1`
  and `list_stacks_with_members/1` both apply no status filter, so the member
  IS loaded. It was dropped because a stacked member has no column of its own
  (`group_board_items/2` suppresses `stack_id != nil`, and `stack_pending` is
  in neither column-status map), and the parent stack card — the only place a
  member can render — was itself filtered out by a matcher that read only
  `stack.id` and `stack.name`.

  Pure matcher, hand-built structs, no DB and no `DataCase`.
  """
  use ExUnit.Case, async: true

  alias Platform.Tasks.{Stack, Task}
  alias PlatformWeb.Tasks.BoardData

  # A stack whose own name and id carry no trace of the search terms used
  # below, so every `true` in this module has to come from a member.
  defp stack do
    %Stack{
      id: "01a04d10-0000-7001-aaaa-000000000001",
      name: "Meetings stack",
      status: "in_progress"
    }
  end

  defp member(id, title, status) do
    %Task{id: id, title: title, status: status, stack_position: 1}
  end

  defp board_data(members) do
    %{
      members: members,
      member_count: length(members),
      dep_edge_count: 0,
      ready_count: 0
    }
  end

  describe "stack_matches_search?/3 — member titles" do
    test "matches on a stack_pending member's title when the stack's own name does not" do
      parked =
        member(
          "01a05598-0000-7001-bbbb-000000000002",
          "Meeting intent classifier never once predicts interaction_design",
          "stack_pending"
        )

      # Premise of the case: the term is absent from every field the OLD /2
      # matcher could see. If this ever stops holding, the assertion below
      # would pass without the member ever being consulted.
      refute String.contains?(String.downcase(stack().name), "intent classifier")
      refute String.contains?(String.downcase(stack().id), "intent classifier")

      assert BoardData.stack_matches_search?(stack(), board_data([parked]), "intent classifier")
    end

    test "matches on a member's id" do
      parked = member("01a05598-0000-7001-bbbb-000000000002", "Some unrelated title", "backlog")

      assert BoardData.stack_matches_search?(stack(), board_data([parked]), "01a05598")
    end
  end

  describe "stack_matches_search?/3 — negative control" do
    # Required: without this, a matcher hardcoded to `true` — or one that
    # simply returns true whenever the members list is non-empty — passes
    # every case above.
    test "returns false when neither the stack nor any member id or title contains the term" do
      members = [
        member("01a05598-0000-7001-bbbb-000000000002", "Transcript pane follows live", "done"),
        member(
          "01a05599-0000-7001-bbbb-000000000003",
          "People tab invite affordance",
          "stack_pending"
        )
      ]

      refute BoardData.stack_matches_search?(stack(), board_data(members), "intent classifier")
    end

    test "the negative control's query is one the matcher CAN answer true for" do
      # Guards the refute above against being unsatisfiable-by-construction:
      # the same query, against a member that does carry the term, is true.
      hit =
        member(
          "01a05598-0000-7001-bbbb-000000000002",
          "Meeting intent classifier misroutes",
          "stack_pending"
        )

      assert BoardData.stack_matches_search?(stack(), board_data([hit]), "intent classifier")
    end
  end

  describe "stack_matches_search?/3 — missing board data" do
    test "an empty board_data map with a non-matching stack name is false, not a crash" do
      refute BoardData.stack_matches_search?(stack(), %{}, "intent classifier")
    end

    test "an empty board_data map still matches on the stack's own name" do
      assert BoardData.stack_matches_search?(stack(), %{}, "meetings stack")
    end

    test "a nil :members value reads as no members" do
      refute BoardData.stack_matches_search?(stack(), %{members: nil}, "intent classifier")
    end
  end

  describe "stack_matches_search?/3 — empty query fast path" do
    test "an empty query matches every stack, with or without board data" do
      assert BoardData.stack_matches_search?(stack(), %{}, "")
      assert BoardData.stack_matches_search?(stack(), board_data([]), "")
    end
  end
end
