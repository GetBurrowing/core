defmodule PlatformWeb.Tasks.StatusLabelsTest do
  # Pure functions — no DB, no DataCase.
  use ExUnit.Case, async: true

  alias PlatformWeb.Tasks.StatusLabels

  describe "status_label/1" do
    test "maps every status reachable on the Tasks surface to a human label" do
      assert StatusLabels.status_label("backlog") == "Backlog"
      assert StatusLabels.status_label("planning") == "Planning"
      assert StatusLabels.status_label("in_progress") == "In Progress"
      assert StatusLabels.status_label("in_review") == "In Review"
      assert StatusLabels.status_label("deploying") == "Deploying"
      assert StatusLabels.status_label("done") == "Done"
      assert StatusLabels.status_label("blocked") == "Blocked"
      assert StatusLabels.status_label("stack_pending") == "Waiting"
      assert StatusLabels.status_label("cancelled") == "Cancelled"
      assert StatusLabels.status_label("forming") == "Forming"
      assert StatusLabels.status_label("abandoned") == "Abandoned"
      assert StatusLabels.status_label("unknown") == "Unknown"
    end

    test "raises for a status no clause covers instead of laundering it" do
      assert_raise ArgumentError, ~r/no clause for/, fn ->
        StatusLabels.status_label("status_with_no_clause")
      end
    end
  end
end
