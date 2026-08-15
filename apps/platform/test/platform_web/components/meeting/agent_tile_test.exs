defmodule PlatformWeb.Components.Meeting.AgentTileTest do
  @moduledoc """
  Stage 2 unit tests for the <.agent_tile> component.

  Task: 019e2475-0037 — Meetings: bottom video strip (humans + agent presence tiles).
  Spec: docs/decisions/0042-meeting-system-with-collaborative-canvas.md (Layout → Bottom strip).

  Verifies the rendered DOM contract: avatar centered on accent-color background
  (or bg-base-200 fallback), activity dot toggles based on activity_state,
  role chip falls back to 'agent' when role is missing, hero icons only.
  Visual end-to-end is covered by the task-level e2e_behavior validations.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.Meeting.AgentTile

  defp agent(overrides \\ %{}) do
    Map.merge(%{id: "agent-helga", name: "Helga"}, overrides)
  end

  describe "agent_tile/1 — base render" do
    test "renders the tile shell with the agent identity wired into data attrs" do
      assigns = %{a: agent()}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} />
        """)

      assert html =~ "meeting-agent-tile"
      assert html =~ ~s(data-agent-tile)
      assert html =~ ~s(data-agent="agent-helga")
      assert html =~ ~s(id="agent-tile-agent-helga")
      assert html =~ ~s(data-activity-state="idle")
      # Role chip defaults to 'agent' when no role supplied.
      assert html =~ ~s(data-role-chip)
      # The shared AVATAR component renders for the avatar slot — the AGENT one.
      # This asserted `"human"` until task 01a00122 stage 5: the tile is an agent
      # by definition, and `human_avatar/1` was giving it two initials over the
      # seeded human palette. See `PlatformWeb.AgentFaceEverywhereTest`.
      assert html =~ ~s(data-avatar-kind="agent")
    end
  end

  describe "agent_tile/1 — accent background" do
    test "falls back to bg-base-200 when accent_color is nil" do
      assigns = %{a: agent()}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} accent_color={nil} />
        """)

      assert html =~ "bg-base-200"
      # No inline style when no accent.
      refute html =~ ~r/style="background-color/
    end

    test "applies the accent_color as an inline background style and drops bg-base-200" do
      assigns = %{a: agent()}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} accent_color="#7c3aed" />
        """)

      assert html =~ ~s(style="background-color: #7c3aed;")
      # Outer tile no longer carries the bg-base-200 fallback class.
      refute html =~ ~r/meeting-agent-tile[^"]*bg-base-200/
    end

    test "ignores invalid accent_color values and keeps the bg-base-200 fallback" do
      assigns = %{a: agent()}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} accent_color="not-a-color" />
        """)

      assert html =~ "bg-base-200"
      refute html =~ ~r/style="background-color/
    end
  end

  describe "agent_tile/1 — activity indicator" do
    test "hides the activity dot when activity_state is :idle" do
      assigns = %{a: agent()}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} activity_state={:idle} />
        """)

      refute html =~ ~s(data-activity-indicator)
      refute html =~ "animate-pulse"
    end

    test "renders a pulsing success dot when activity_state is :typing" do
      assigns = %{a: agent()}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} activity_state={:typing} />
        """)

      assert html =~ ~s(data-activity-indicator)
      assert html =~ "animate-pulse"
      assert html =~ "bg-success"
      assert html =~ "Helga is typing"
      assert html =~ ~s(data-activity-state="typing")
    end

    test "labels other active states (:computing, :listening) on the indicator" do
      assigns = %{a: agent()}

      html_computing =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} activity_state={:computing} />
        """)

      assert html_computing =~ "Helga is computing"
      assert html_computing =~ ~s(data-activity-state="computing")

      html_listening =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} activity_state={:listening} />
        """)

      assert html_listening =~ "Helga is listening"
      assert html_listening =~ ~s(data-activity-state="listening")
    end
  end

  describe "agent_tile/1 — role chip" do
    test "renders the supplied role label inside the chip" do
      assigns = %{a: agent()}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} role="listener" />
        """)

      assert html =~ ~s(data-role-chip)
      assert html =~ ">listener<"
      # Hero icon accompanies the chip; no emoji codepoints permitted.
      assert html =~ "hero-cpu-chip"
    end

    test "falls back to 'agent' when role is nil or blank" do
      assigns = %{a: agent()}

      html_nil =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} role={nil} />
        """)

      assert html_nil =~ ">agent<"

      html_blank =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} role="   " />
        """)

      assert html_blank =~ ">agent<"
    end
  end

  describe "agent_tile/1 — agent field tolerance" do
    test "uses :identity when present and falls back gracefully on sparse maps" do
      assigns = %{a: %{identity: "ag-7"}}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} />
        """)

      assert html =~ ~s(data-agent="ag-7")
      # Name falls back to the identity since :name is absent.
      assert html =~ ~s(id="agent-tile-ag-7")
    end

    test "prefers display_name when name is absent" do
      assigns = %{a: %{id: "ag-9", display_name: "Northwind"}}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} activity_state={:typing} />
        """)

      # Name surfaces via the activity indicator's accessible label.
      assert html =~ "Northwind is typing"
    end
  end

  describe "agent_tile/1 — passthrough" do
    test "merges extra class and global attrs onto the outer element" do
      assigns = %{a: agent()}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} class="w-24" data-testid="strip-agent" />
        """)

      assert html =~ "w-24"
      assert html =~ ~s(data-testid="strip-agent")
    end
  end
end
