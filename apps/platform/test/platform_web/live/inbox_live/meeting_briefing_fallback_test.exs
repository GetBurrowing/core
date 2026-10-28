defmodule PlatformWeb.InboxLive.MeetingBriefingFallbackTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  alias PlatformWeb.InboxLive.MeetingBriefingComponent

  defp render_state(summary, missing) do
    view = %{
      meeting: %{
        id: Ecto.UUID.generate(),
        name: "Meeting review",
        ended_at: ~U[2026-10-28 15:00:00Z]
      },
      summary: summary,
      missing_prerequisites: missing,
      counts: %{total: 0, open: 0},
      open:
        if(summary,
          do: [
            %{
              key: "filed",
              kind: "task",
              title: "Prepare the follow-up",
              receipt: nil,
              availability: nil,
              actions: []
            }
          ],
          else: []
        ),
      resolved: [],
      open_questions: [],
      unfiled_action_items: [],
      transcript_url: "/meetings/review"
    }

    MeetingBriefingComponent.render(%{
      __changed__: nil,
      id: "briefing",
      view: view,
      time_zone: "UTC",
      myself: nil,
      asking: MapSet.new(),
      blank: MapSet.new(),
      errors: %{}
    })
    |> rendered_to_string()
  end

  test "deadline lists absent parts, with synthesis only when registered" do
    html = render_state(nil, ["summary", "triage filing"])
    assert html =~ "Summary unavailable"
    assert html =~ "Task filing incomplete"
    refute html =~ "Synthesis incomplete"
    assert render_state(nil, ["summary", "synthesis"]) =~ "Synthesis incomplete"
    refute html =~ "Summary is being written"
  end

  test "complete delivery displays summary with no incomplete copy" do
    html = render_state("Decisions and outcomes are ready.", [])
    assert html =~ "Decisions and outcomes are ready."
    assert html =~ "Task filed"
    assert html =~ "Prepare the follow-up"
    refute html =~ "Summary unavailable"
    refute html =~ "incomplete"
    refute html =~ "Summary is being written"
  end
end
