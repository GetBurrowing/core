defmodule PlatformWeb.Components.Meeting.CohostFaceTest do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.Meeting.AgentTile

  test "only actual voice participants get a performance view bound to their identity" do
    for voice? <- [false, true] do
      assigns = %{voice?: voice?, agent: %{id: "face-fixture", name: "Show cohost"}}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@agent} voice?={@voice?} />
        """)

      faces = html |> Floki.parse_fragment!() |> Floki.find("[phx-hook=MeetingCohostFace]")
      assert length(faces) == if(voice?, do: 1, else: 0)

      if voice? do
        assert Floki.attribute(hd(faces), "data-identity") == ["face-fixture"]
        assert length(Floki.find(faces, "dialog [data-face-mouth]")) == 1
        assert Floki.find(faces, "audio, video") == []
      end
    end
  end
end
