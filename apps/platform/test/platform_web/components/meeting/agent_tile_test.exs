defmodule PlatformWeb.Components.Meeting.AgentTileTest do
  @moduledoc """
  Stage 2 unit tests for the <.agent_tile> component.

  Task: 019e2475-0037 — Meetings: bottom video strip (humans + agent presence tiles).
  Meeting system: docs/decisions/0030-meetings-livekit-voice-video.md.

  The bottom-strip layout itself is NOT specified in any ADR. A grep for
  "bottom strip" across docs/ returns nothing -- the phrase lives only in
  code. This module and its tests ARE the specification. The citation this
  line previously carried named a file that has never existed in the repo,
  and 0042 is a duplicated ADR number besides (01a04a5e-c28f), so it was
  ambiguous as well as dangling.

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

    # `info`, not `warning`, since Saru's ruling (canvas 01a05b11-54ff
    # card 6, 2026-09-02; applied in task 01a05b14 stage 5): Writing and
    # Thinking share the working slot and `warning` belongs to the invite
    # banner alone. Motion is what separates Writing from Thinking.
    test "renders the typing badge — info ring, pen glyph, name — when activity_state is :typing" do
      assigns = %{a: agent()}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} activity_state={:typing} />
        """)

      assert html =~ ~s(data-activity-indicator)
      assert html =~ ~s(data-role="agent-activity-badge")
      assert html =~ "animate-pulse"
      assert html =~ "border-info"
      refute html =~ "border-warning"
      assert html =~ "Helga is Writing"
      assert html =~ ~s(data-activity-state="typing")

      # The one green dot for every non-idle state is gone. It is the
      # reason a failed agent read as healthy.
      refute html =~ "bg-success"
    end

    test "a :failed agent is NOT a green pulsing dot" do
      # THE BUG. `meeting_live.ex` resolves :failed and the strip passed
      # it straight into a tile whose indicator was `bg-success
      # animate-pulse` for ANY non-idle state — a failed agent rendered
      # as a healthy, working one, with the word only in a `title=`.
      assigns = %{a: agent()}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} activity_state={:failed} />
        """)

      refute html =~ "bg-success"
      # No pulse either: a pulse reads as "still going", the opposite of
      # what this state says.
      refute html =~ "animate-pulse"

      assert html =~ ~s(data-activity-state="failed")
      assert html =~ ~s(data-role="agent-activity-ring")
      assert html =~ "border-error"
      assert html =~ "Helga is Couldn&#39;t"
    end

    test ":failed and :computing do not render the same indicator" do
      # ANTI-VACUITY for the assertion above: prove the tile can render a
      # DIFFERENT ring, so `border-error` is a distinction and not just a
      # class the tile always emits.
      assigns = %{a: agent()}

      failed =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} activity_state={:failed} />
        """)

      computing =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} activity_state={:computing} />
        """)

      # `border-info`, not `border-secondary`: task 01a05b14 stage 2
      # moved "Thinking" onto the `info` slot per Saru's
      # design-direction canvas, which does not list `secondary` at
      # all. The assertion that matters is unchanged — computing and
      # failed must not share a ring colour.
      assert computing =~ "border-info"
      refute computing =~ "border-error"
      refute failed =~ "border-info"
    end

    test "labels other active states (:computing, :listening) on the indicator" do
      assigns = %{a: agent()}

      html_computing =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} activity_state={:computing} />
        """)

      assert html_computing =~ "Helga is Thinking"
      assert html_computing =~ ~s(data-activity-state="computing")

      html_listening =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} activity_state={:listening} />
        """)

      # `:listening` has no producer in `AgentActivity` — the badge
      # deliberately refuses to give it a word rather than print a
      # caption nothing can ever set. The tile still marks the state.
      assert html_listening =~ ~s(data-activity-state="listening")
      assert html_listening =~ "Helga is idle"
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
      assert html =~ "Northwind is Writing"
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
