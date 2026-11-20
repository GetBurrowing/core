defmodule Platform.Meetings.IntentContextAckPreambleTest do
  @moduledoc """
  `IntentContext.ack_preamble/1` is composed onto the front of every native
  `meetings.*` intent prompt. Task 01a1f53c-1825 made `intent_ack` accept
  `rejected` with no `subagent_id`; the preamble already showed a rejected
  call without one but never said that was allowed, so a recipient could
  still read it as an omission and spawn a subagent just to decline.
  """

  use ExUnit.Case, async: true

  alias Platform.Meetings.IntentContext

  @intent_id "01a1f53c-0000-7000-8000-000000000001"

  defp line_for(preamble, status) do
    preamble
    |> String.split("\n")
    |> Enum.find(&String.contains?(&1, ~s|status: "#{status}"|))
  end

  test "the rejected line says no subagent and no subagent_id are needed" do
    preamble = IntentContext.ack_preamble(%{intent_id: @intent_id})

    line = line_for(preamble, "rejected")
    assert line, "the preamble must carry a rejected ack line"

    assert line =~ ~s|intent_ack(intent_id: "#{@intent_id}", status: "rejected")|
    assert line =~ "No subagent and no `subagent_id` are needed to reject"
    refute line =~ "subagent_id:", "the rejected call must not carry a subagent_id argument"
  end

  test "the working and completed lines are unchanged and carry no invented id" do
    preamble = IntentContext.ack_preamble(%{intent_id: @intent_id})

    assert line_for(preamble, "working") ==
             ~s|- Starting work? `intent_ack(intent_id: "#{@intent_id}", status: "working")`. Send it before you begin, not after.|

    assert line_for(preamble, "completed") ==
             ~s|- Finished? `intent_ack(intent_id: "#{@intent_id}", status: "completed")`.|
  end

  test "no intent_id means no preamble" do
    assert IntentContext.ack_preamble(%{}) == ""
    assert IntentContext.ack_preamble(nil) == ""
  end
end
