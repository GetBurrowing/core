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

  Verifies the rendered DOM contract: the tile carries the agent's identity
  slot (`data-agent-slot`, task 01a1557a rung 3 stage 3) and no inline colour,
  activity dot toggles based on activity_state, the chip shows `<name> · <role>`
  with the role falling back to 'agent', hero icons only.
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

  # Task 01a1557a rung 3 stage 3: the dead free-form hex `accent_color` path is
  # gone (no caller ever passed it); the tile reads only its slot.
  describe "agent_tile/1 — identity slot" do
    test "carries data-agent-slot for every stored ColorPalette colour" do
      for id <- Platform.Agents.ColorPalette.ids() do
        assigns = %{a: agent(), slot: id}

        html =
          rendered_to_string(~H"""
          <.agent_tile agent_participant={@a} slot={@slot} />
          """)

        assert [tile] = html |> Floki.parse_fragment!() |> Floki.find("[data-agent-tile]")
        assert Floki.attribute(tile, "data-agent-slot") == [id]
      end
    end

    test "nil, blank or unknown colour is the blue slot" do
      for slot <- [nil, "", "chartreuse"] do
        assigns = %{a: agent(), slot: slot}

        html =
          rendered_to_string(~H"""
          <.agent_tile agent_participant={@a} slot={@slot} />
          """)

        assert html =~ ~s(data-agent-slot="blue"), inspect(slot)
      end
    end

    test "no inline colour and no bg-base-200: the ground is the slot tint from app.css" do
      assigns = %{a: agent()}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} slot="rose" />
        """)

      refute html =~ "style=\"background"
      refute html =~ "bg-base-200"
      refute Regex.match?(~r/(class|style)="[^"]*#[0-9a-fA-F]{3,6}/, html)
    end

    test "accent_color is no longer an attribute" do
      refute Enum.any?(
               PlatformWeb.Components.Meeting.AgentTile.__components__().agent_tile.attrs,
               &(&1.name == :accent_color)
             )
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

    test "the chip shows the agent's NAME before the role, the name truncating last" do
      assigns = %{a: agent()}

      html =
        rendered_to_string(~H"""
        <.agent_tile agent_participant={@a} role="designer" />
        """)

      doc = Floki.parse_fragment!(html)
      assert [name] = Floki.find(doc, "[data-name-chip]")
      assert Floki.text(name) == "Helga"
      assert Floki.attribute(name, "class") |> hd() =~ "truncate"
      assert [role] = Floki.find(doc, "[data-role-chip]")
      assert Floki.text(role) == "designer"
      # Name first, then "· role".
      chip_text = doc |> Floki.find(".agent-tile-chip") |> Floki.text() |> String.trim()
      assert chip_text =~ ~r/^Helga\s*· designer$/

      # The role's wrapper shrinks 999x faster than the name, so it truncates
      # first; the name keeps the default shrink of 1.
      role_wrap =
        doc
        |> Floki.find(".agent-tile-chip span")
        |> Enum.find(&(Floki.attribute(&1, "class") |> List.first("") =~ "shrink-[999]"))

      assert role_wrap && Floki.find(role_wrap, "[data-role-chip]") != []
      refute Floki.attribute(name, "class") |> hd() =~ "shrink-["
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

  # Task 01a1117f stage 4: a voice agent has no camera and is not a person,
  # so the promoted tile shows the voice waveform where the avatar sat.
  describe "agent_tile/1 — voice waveform" do
    defp voice_tile(voice?, overrides \\ %{}) do
      assigns = %{
        a: agent(Map.merge(%{identity: "agent:0000-burrow", name: "Burrow"}, overrides)),
        voice?: voice?
      }

      rendered_to_string(~H"""
      <.agent_tile
        id_prefix="gallery-agent-tile"
        agent_participant={@a}
        slot="purple"
        voice?={@voice?}
      />
      """)
    end

    defp waveforms(html),
      do: html |> Floki.parse_fragment!() |> Floki.find("[data-voice-waveform]")

    test "a voice-present agent renders the 8-bar tile waveform and no avatar" do
      html = voice_tile(true)

      assert [wave] = waveforms(html)
      assert Floki.attribute(wave, "data-size") == ["tile"]
      assert Floki.attribute(wave, "data-identity") == ["agent:0000-burrow"]
      assert length(Floki.find(wave, "[data-wave-bar]")) == 8

      # The hook lives on the outer, ignored element; the glyph inside it
      # carries the JS-owned state (see VoiceWaveform's moduledoc).
      assert [root] = html |> Floki.parse_fragment!() |> Floki.find("[data-voice-waveform-root]")
      assert Floki.attribute(root, "phx-hook") == ["MeetingVoiceWaveform"]
      assert Floki.attribute(root, "phx-update") == ["ignore"]
      assert Floki.attribute(root, "id") == ["gallery-agent-tile-wave-agent:0000-burrow"]
      assert Floki.attribute(root, "data-identity") == ["agent:0000-burrow"]
      # Never server-render the state: LiveView would strip the hook's value
      # off the ignored root on every patch.
      refute html =~ "data-wave-state"

      refute html =~ ~s(data-avatar-kind)
      refute html =~ "<img"
    end

    test "the voice tile takes the slot like an avatar tile, and carries no raw hex" do
      html = voice_tile(true)

      assert html =~ ~s(data-agent-slot="purple")
      refute html =~ "bg-base-200"
      refute html =~ "background-color:"
      refute Regex.match?(~r/(class|style)="[^"]*#[0-9a-fA-F]{3,6}/, html)
    end

    test "never primary on the glyph: the only primary is the speaking ring" do
      html =
        voice_tile(true)
        |> Floki.parse_fragment!()
        |> Floki.find("[data-voice-waveform]")
        |> Floki.raw_html()

      refute html =~ "primary"
    end

    test "a pending (non-voice) agent keeps its avatar and renders no waveform" do
      html = voice_tile(false)

      assert waveforms(html) == []
      assert html =~ ~s(data-avatar-kind="agent")
      # Same slot as the voice tile: voice changes the face, never the colour.
      assert html =~ ~s(data-agent-slot="purple")
    end
  end
end
