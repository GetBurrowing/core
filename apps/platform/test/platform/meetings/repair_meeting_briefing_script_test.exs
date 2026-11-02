defmodule Platform.Meetings.RepairMeetingBriefingScriptTest do
  use ExUnit.Case, async: true

  setup_all do
    Code.require_file(Path.expand("../../../priv/scripts/repair_meeting_briefing.exs", __DIR__))
    :ok
  end

  test "usage documents dry run and confirmed apply" do
    usage = MeetingBriefingRepair.usage()
    assert usage =~ ~s|run("<meeting-uuid>", [])|
    assert usage =~ ~s|apply: true, confirm: "<meeting-uuid>"|
  end

  test "check_confirm!/2 passes for dry run and matching confirm" do
    assert :ok = MeetingBriefingRepair.check_confirm!("m1", [])
    assert :ok = MeetingBriefingRepair.check_confirm!("m1", apply: true, confirm: "m1")
  end

  test "check_confirm!/2 raises when applying without a matching confirm" do
    assert_raise ArgumentError, ~r/refusing to apply/, fn ->
      MeetingBriefingRepair.check_confirm!("m1", apply: true)
    end

    assert_raise ArgumentError, ~r/refusing to apply/, fn ->
      MeetingBriefingRepair.check_confirm!("m1", apply: true, confirm: "other")
    end
  end
end
