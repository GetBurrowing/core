defmodule Platform.Memory.Insights.BriefingsTest do
  @moduledoc """
  Task 01a15ee1 stage 1: a briefing delivered to the Inbox has no canvas, and
  the canvas updates (`settle/3`, `retract/2`, `open_flag_form/2`) skip it
  without raising. `containing/1` still finds it, because
  `Actions.recipient?/2` authorises the Inbox recipient through it.
  """

  use Platform.DataCase, async: false

  import Platform.InsightFixtures
  import Platform.TenancyFixtures

  alias Platform.Memory.Briefing
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Briefings

  setup do
    _root = acme_org_id()
    :ok
  end

  defp inbox_briefing!(person, insight) do
    %Briefing{}
    |> Briefing.changeset(%{
      user_id: person.id,
      digest_date: ~D[2026-10-21],
      items: %{BriefingCard.node_key(insight) => insight.id}
    })
    |> Repo.insert!()
  end

  test "settle/3, retract/2 and open_flag_form/2 skip a briefing with no canvas" do
    person = person!()
    insight = insight!(addressee: person)
    briefing = inbox_briefing!(person, insight)
    assert briefing.canvas_id == nil

    assert :ok = Briefings.settle(insight.id, "Marked as right.")
    assert :ok = Briefings.settle(insight.id, "Marked as right.", flag: true)
    assert :ok = Briefings.retract(insight.id, "wrong person")

    assert {:error, :not_found} =
             Briefings.open_flag_form(briefing, BriefingCard.node_key(insight))

    # The row is untouched and still found for the recipient check.
    assert [%Briefing{id: id, canvas_id: nil}] = Briefings.containing(insight.id)
    assert id == briefing.id
  end
end
