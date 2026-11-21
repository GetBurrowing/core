defmodule Platform.Social.ApprovalDeadlineClockTest do
  use ExUnit.Case, async: true
  alias Platform.Social.{ApprovalDeadline, Post}

  test "the exact boundary is missed, the preceding microsecond is not" do
    at = ~U[2026-11-21 12:00:00.000000Z]
    post = %Post{status: "needs_approval", scheduled_at: at}
    refute ApprovalDeadline.missed?(post, DateTime.add(at, -1, :microsecond))
    assert ApprovalDeadline.missed?(post, at)
    assert ApprovalDeadline.missed?(post, DateTime.add(at, 1, :microsecond))
    assert :ok = ApprovalDeadline.check_approval(post, DateTime.add(at, -1, :microsecond))
    assert {:error, :slot_passed} = ApprovalDeadline.check_approval(post, at)
  end

  test "untimed, vendor-failed, approved and Studio posts are not approval misses" do
    now = ~U[2026-11-21 12:00:00Z]
    refute ApprovalDeadline.missed?(%Post{status: "needs_approval"}, now)
    assert :ok = ApprovalDeadline.check_approval(%Post{status: "needs_approval"}, now)

    for status <- ~w(approved scheduled published failed) do
      refute ApprovalDeadline.missed?(%Post{status: status, scheduled_at: now}, now)
    end

    refute ApprovalDeadline.missed?(
             %Post{flow: "studio", status: "needs_approval", scheduled_at: now},
             now
           )
  end
end
