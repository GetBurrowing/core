defmodule PlatformWeb.Components.Meetings.ParticipantRailTest do
  @moduledoc """
  The rail's two sections must each be LABELLED.

  This file exists because of a specific defect: the Agents section
  shipped with a heading and the humans section shipped with none, so
  the People pane opened on an unlabelled column of faces on BOTH
  surfaces. Nothing failed. Every existing test asserted on the rows —
  `data-participant-id`, the mic glyph, the role chip — and a heading
  that is absent leaves no row to assert against.

  So the guards below assert the heading TEXT, not just the section
  element, and assert the humans heading and the agents heading are a
  visible pair (same typography classes). Both were shown to detonate
  by deleting the humans heading `<div>` from `participant_rail.ex`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PlatformWeb.Components.Meetings.ParticipantRail

  @heading_type "text-[11px] font-semibold uppercase tracking-widest text-base-content/50"

  defp human(name, id) do
    %{
      id: id,
      participant_id: id,
      participant_type: "user",
      display_name: name,
      avatar_url: nil,
      attention_config: %{"mic_on" => true}
    }
  end

  defp agent(name, id) do
    %{
      id: "p-" <> id,
      participant_id: id,
      participant_type: "agent",
      display_name: name,
      avatar_url: nil,
      attention_config: %{}
    }
  end

  defp rail(participants) do
    render_component(&ParticipantRail.participant_rail/1,
      participants: participants,
      agents_by_id: %{},
      meeting: %{id: "m-1", host_participant_id: "u-1"}
    )
  end

  defp rail(participants, agent_activity) do
    render_component(&ParticipantRail.participant_rail/1,
      participants: participants,
      agents_by_id: %{},
      meeting: %{id: "m-1", host_participant_id: "u-1"},
      agent_activity: agent_activity
    )
  end

  # One agent per state in ONE rail, which is also the shape the
  # manual-approval gate asks to see.
  @four_states %{
    "a-think" => :computing,
    "a-write" => :typing,
    "a-fail" => :failed,
    "a-idle" => :idle
  }

  defp four_state_rail do
    rail(
      [
        human("Harper", "u-1"),
        agent("Thinker", "a-think"),
        agent("Writer", "a-write"),
        agent("Failer", "a-fail"),
        agent("Idler", "a-idle")
      ],
      @four_states
    )
  end

  defp agent_row(html, agent_id) do
    case Regex.run(~r/<li[^>]*data-participant-id="p-#{agent_id}".*?<\/li>/s, html) do
      [row] -> row
      nil -> flunk("no agent row for #{agent_id} in the rendered rail")
    end
  end

  describe "the humans section heading" do
    test "renders the words 'In this call'" do
      html = rail([human("Harper", "u-1"), agent("Saru", "a-1")])

      assert html =~ "In this call",
             "the humans section rendered with no heading — this is the exact defect " <>
               "the e2e reviewer failed the gate on"
    end

    test "the heading sits inside data-section=\"humans\", not somewhere else on the page" do
      html = rail([human("Harper", "u-1"), agent("Saru", "a-1")])

      humans_section =
        case Regex.run(~r/<section data-section="humans".*?<\/section>/s, html) do
          [section] -> section
          nil -> flunk("no <section data-section=\"humans\"> in the rendered rail")
        end

      assert humans_section =~ "In this call"
    end

    test "is typographically the same kind of thing as the Agents heading" do
      html = rail([human("Harper", "u-1"), agent("Saru", "a-1")])

      # Two headings, same classes: they read as a pair rather than as
      # one labelled section and one accidental line of text.
      assert length(Regex.scan(~r/#{Regex.escape(@heading_type)}/, html)) == 2
      assert html =~ "Agents"
    end

    test "uses a people glyph, not the agents' cpu-chip" do
      html = rail([human("Harper", "u-1")])

      assert html =~ "hero-users"
      refute html =~ "hero-cpu-chip"
    end

    test "still labels the section when nobody has joined yet" do
      # The humans section is unconditional (it carries an empty
      # state), so a heading that hid with the list would leave
      # "No people yet." floating under nothing.
      html = rail([agent("Saru", "a-1")])

      assert html =~ "In this call"
      assert html =~ "No people yet."
    end
  end

  describe "the agent row's three signals" do
    # The defect this closes: the ring was a standalone EMPTY circle at
    # the far end of the row, line 2 under the name was the role chip
    # rendering the literal string "agent", and `:idle` rendered
    # NEITHER — it was gated out and replaced by a bare dot. So on a
    # quiet meeting the row showed a name, the word "agent", and a dot:
    # three of the four cues absent exactly when a reader needs them.
    #
    # Every assertion below renders all four states in ONE rail and
    # checks per-row, so a guard cannot pass on another row's markup.
    test "the state colour is on a ring AROUND the avatar, not a separate circle" do
      html = four_state_rail()

      for {id, _state} <- @four_states do
        row = agent_row(html, id)

        assert row =~ ~s(data-role="agent-activity-avatar"),
               "#{id}: the avatar is not wrapped in the activity construction"

        assert row =~ ~s(data-role="agent-activity-ring")

        refute row =~ ~s(data-role="agent-activity-badge"),
               "#{id}: the standalone badge circle is still in the row"
      end
    end

    test "the ring colour differs per state rather than collapsing to one" do
      html = four_state_rail()

      assert agent_row(html, "a-think") =~ "border-info"
      # Writing shares `info` with Thinking BY DECISION (Saru, canvas
      # 01a05b11-54ff card 6, 2026-09-02): both mean "working, nothing
      # is asked of you", and `warning` is the invite banner's alone.
      # What separates the two rows is the glyph and the motion, which
      # the uniqueness assertion below still holds them to.
      assert agent_row(html, "a-write") =~ "border-info"
      refute agent_row(html, "a-write") =~ "warning"
      assert agent_row(html, "a-write") =~ "animate-pulse"
      refute agent_row(html, "a-think") =~ "animate-pulse"
      assert agent_row(html, "a-fail") =~ "border-error"
      assert agent_row(html, "a-idle") =~ "border-base-content/25"

      # The old dot mapped every non-idle state to one class. Assert the
      # four rows are actually DIFFERENT markup, not just that each
      # contains a token some other row also contains.
      rows = for {id, _} <- @four_states, do: agent_row(html, id)
      assert length(Enum.uniq(rows)) == 4
    end

    test "the three non-idle states carry a corner glyph and idle carries none" do
      html = four_state_rail()

      assert agent_row(html, "a-think") =~ ~s(data-role="agent-activity-glyph")
      assert agent_row(html, "a-think") =~ "◐"
      assert agent_row(html, "a-write") =~ "✎"
      assert agent_row(html, "a-fail") =~ ~s(data-role="agent-activity-glyph")

      refute agent_row(html, "a-idle") =~ ~s(data-role="agent-activity-glyph"),
             "idle drew a glyph — the mockup's idle row has a ring and a word and no badge"
    end

    test "the line under the name is the STATE WORD, not the 'agent' role chip" do
      html = four_state_rail()

      assert agent_row(html, "a-think") =~ "Thinking"
      assert agent_row(html, "a-write") =~ "Writing"
      assert agent_row(html, "a-fail") =~ "Couldn&#39;t"

      for {id, _} <- @four_states do
        row = agent_row(html, id)

        assert row =~ ~s(data-role="agent-activity-word"),
               "#{id}: no state word under the name"

        refute row =~ ~s(data-role="agent-role-chip"),
               "#{id}: the role chip is still occupying line 2"
      end
    end

    # `:idle` is drawn because it has a real producer:
    # `AgentActivity.for_agent/2` computes it from live data. It is NOT
    # the `Listening` case, which is asserted separately below.
    test "idle renders as a full row with the word Idle, not as a bare dot" do
      row = agent_row(four_state_rail(), "a-idle")

      assert row =~ "Idle"
      assert row =~ ~s(data-role="agent-activity-avatar")
      assert row =~ "opacity-45", "the idle face is not dimmed"
    end

    # A DIFFERENT fact from the activity: is this agent connected. It
    # moved to the row's trailing edge when the ring took over the
    # avatar, and must not have been dropped in the move.
    test "the reachability dot survives, on every state and not only idle" do
      html = four_state_rail()

      for {id, _} <- @four_states do
        assert agent_row(html, id) =~ ~s(data-role="agent-status-dot"),
               "#{id}: the reachability dot was dropped"
      end
    end

    # The one state with no producer. Nothing in the system can set
    # `:listening`, so drawing it would put a caption on screen that is
    # always false. Asserted against a rail where every OTHER state is
    # resolved, so this cannot pass merely because the rail is empty.
    test "'Listening' appears nowhere, with every real state resolved" do
      html = four_state_rail()

      refute html =~ "Listening"

      listening = rail([agent("Saru", "a-1")], %{"a-1" => :listening})
      refute listening =~ "Listening"
      assert listening =~ "Idle", "an unsettable state must present as idle, not as itself"
    end
  end
end
