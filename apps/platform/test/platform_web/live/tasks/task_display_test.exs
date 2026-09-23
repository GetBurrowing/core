defmodule PlatformWeb.Tasks.TaskDisplayTest do
  @moduledoc """
  Task 01a0cef1 stage 3: priority badges mark the exception, not the rule.

  The board is ordered by priority, so only `critical` (filled error) and
  `high` (outlined error) carry colour. `medium`, `low`, nil and unknown
  strings such as "urgent" share the neutral ghost badge. `badge-success` is
  the product's success/healthy token and must never read as a priority.

  Exact-string assertions, not substring checks: a substring test on
  "badge-ghost" would pass for a class that carried a colour token as well.
  """
  use ExUnit.Case, async: true

  alias PlatformWeb.Tasks.TaskDisplay

  @expected [
    {"critical", "badge badge-error badge-sm"},
    {"high", "badge badge-error badge-outline badge-sm"},
    {"medium", "badge badge-ghost badge-sm"},
    {"low", "badge badge-ghost badge-sm"},
    {nil, "badge badge-ghost badge-sm"},
    {"urgent", "badge badge-ghost badge-sm"}
  ]

  describe "priority_badge_class/1" do
    for {priority, class} <- @expected do
      test "#{inspect(priority)} maps to #{class}" do
        assert TaskDisplay.priority_badge_class(unquote(priority)) == unquote(class)
      end
    end

    test "no priority maps to a class containing badge-success or badge-warning" do
      for priority <- ["critical", "high", "medium", "low", nil, "urgent", ""] do
        class = TaskDisplay.priority_badge_class(priority)

        refute class =~ "badge-success",
               "#{inspect(priority)} maps to #{class}, which uses the healthy token"

        refute class =~ "badge-warning",
               "#{inspect(priority)} maps to #{class}, which carries warning colour"
      end
    end

    test "only critical and high carry a colour token" do
      coloured =
        for priority <- ["critical", "high", "medium", "low", nil, "urgent"],
            not String.contains?(TaskDisplay.priority_badge_class(priority), "badge-ghost"),
            do: priority

      assert coloured == ["critical", "high"]
    end
  end
end
