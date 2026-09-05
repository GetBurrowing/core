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

  alias Platform.Meetings.AgentActivity
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

  # `now` explicit, for task 01a06e07 stage 3: the ceiling and the age
  # counter are both pure functions of `entered_at` and `now`, so a test
  # proves them by choosing both `DateTime`s — no clock, no timer, no
  # `Process.sleep/1` (`AgentActivity.resolve_at/2`'s own moduledoc makes
  # the same claim; this is that claim exercised through the component).
  defp rail(participants, agent_activity, now) do
    render_component(&ParticipantRail.participant_rail/1,
      participants: participants,
      agents_by_id: %{},
      meeting: %{id: "m-1", host_participant_id: "u-1"},
      agent_activity: agent_activity,
      now: now
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

    # WHY A MARKER ON THE FACE (task 01a064fa stage 1). The geometric
    # gate has to ask "does the ring wrap THE AVATAR", and the avatar
    # itself had nothing to hang on — only the CSS class `agent-avatar`.
    # A class-name lookup is the same species of check as the presence
    # check that let three rejected rounds through, so the face gets a
    # `data-role` and the browser assertion resolves through DOM
    # ancestry instead.
    #
    # Asserted as ANCESTRY over the parsed subtree, not as `row =~`: a
    # string containment check passes on a document where the face was
    # moved out of the avatar wrapper to sit beside it, which is
    # precisely the defect shape being guarded against.
    test "the face carries a marker and sits INSIDE the activity avatar wrapper" do
      html = four_state_rail()

      for {id, _state} <- @four_states do
        row = Floki.parse_fragment!(agent_row(html, id))

        wrappers = Floki.find(row, ~s([data-role="agent-activity-avatar"]))

        assert length(wrappers) == 1,
               "#{id}: expected exactly one activity avatar wrapper, got #{length(wrappers)}"

        assert Floki.find(row, ~s([data-role="agent-activity-face"])) != [],
               "#{id}: the avatar has no data-role=\"agent-activity-face\" marker"

        # The face found ANYWHERE in the row must be the same node as
        # the face found under the wrapper — that equality is what
        # fails when the face is hoisted out to be the wrapper's
        # sibling while still rendering somewhere in the row.
        assert Floki.find(wrappers, ~s([data-role="agent-activity-face"])) ==
                 Floki.find(row, ~s([data-role="agent-activity-face"])),
               "#{id}: the face is in the row but NOT inside the activity avatar wrapper"

        # The ring is co-located with the face in the same wrapper, so
        # ring and face are one object rather than two things a reader
        # is asked to associate across a row.
        assert Floki.find(wrappers, ~s([data-role="agent-activity-ring"])) != [],
               "#{id}: the ring is not inside the wrapper the face lives in"
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

  # Task 01a06e07 stage 3. Stage 1 (`61d4e616`) shipped
  # `AgentActivity.resolve_at/2`'s 120s ceiling unit-tested but never
  # called from any render path — `participant_rail.ex` called
  # `for_agent/2`, which has no ceiling, so a stuck agent read `Thinking`
  # forever on screen even though `resolve_at/2` would have said
  # `:failed`. These tests pin the render path onto `resolve_at/2`
  # (through `AgentActivity.resolve_for_render/2`), asserted THROUGH the
  # component — not only through the struct, which stage 1's own tests
  # already covered and which this stage is explicit is not enough on its
  # own.
  describe "the ceiling and the age, on the render path" do
    test "an agent computing for over 120s renders Couldn't, capped by resolve_at/2" do
      t0 = ~U[2026-01-01 00:00:00Z]
      past_ceiling = DateTime.add(t0, AgentActivity.ceiling_seconds() + 1, :second)

      activity = AgentActivity.put_at(AgentActivity.new(), :computing, "a-1", true, t0)

      html = rail([agent("Stuck", "a-1")], activity, past_ceiling)
      row = agent_row(html, "a-1")

      assert row =~ ~s(data-activity-state="failed")
      assert row =~ "Couldn&#39;t"
      assert row =~ "no response for 2m"
      # Not a bare counter — the stage spec: "carries its reason, not a
      # counter."
      refute row =~ "Couldn&#39;t · 121s"
    end

    test "an agent still under the ceiling keeps reading Thinking, with its real age" do
      t0 = ~U[2026-01-01 00:00:00Z]
      still_working = DateTime.add(t0, AgentActivity.ceiling_seconds() - 1, :second)

      activity = AgentActivity.put_at(AgentActivity.new(), :computing, "a-1", true, t0)

      html = rail([agent("Working", "a-1")], activity, still_working)
      row = agent_row(html, "a-1")

      assert row =~ ~s(data-activity-state="computing")
      assert row =~ "Thinking"
      assert row =~ "119s"
      refute row =~ "Couldn&#39;t"
    end

    test "the SAME struct renders a DIFFERENT age as `now` moves — no tick, no timer, just the clock handed in" do
      t0 = ~U[2026-01-01 00:00:00Z]
      activity = AgentActivity.put_at(AgentActivity.new(), :computing, "a-1", true, t0)

      early = rail([agent("Thinker", "a-1")], activity, DateTime.add(t0, 3, :second))
      later = rail([agent("Thinker", "a-1")], activity, DateTime.add(t0, 47, :second))

      assert agent_row(early, "a-1") =~ "Thinking · 3s"
      assert agent_row(later, "a-1") =~ "Thinking · 47s"

      # Every state is still correct even if a tick was MISSED — the
      # stage spec's own requirement — because nothing here is derived
      # from how many ticks fired, only from `t0` and whatever `now` this
      # particular render was handed.
      refute agent_row(early, "a-1") == agent_row(later, "a-1")
    end

    test "Heard renders with no counter, then resolves to Thinking once it decays" do
      t0 = ~U[2026-01-01 00:00:00Z]

      heard_only = AgentActivity.put_at(AgentActivity.new(), :heard, "a-1", true, t0)

      just_heard = rail([agent("Listener", "a-1")], heard_only, DateTime.add(t0, 1, :second))
      row = agent_row(just_heard, "a-1")

      assert row =~ ~s(data-activity-state="heard")
      assert row =~ "Heard"
      # No counter on Heard, per the stage spec — "Heard and Idle carry
      # NO counter."
      refute row =~ "Heard ·"

      # Heard AND computing at once: once the 2s heard window decays,
      # `resolve_at/2` falls through to the still-live `:computing` signal
      # underneath it, and the row picks that up on the very next render
      # — no special-casing needed on this side, since the render always
      # re-derives from scratch.
      both =
        AgentActivity.new()
        |> AgentActivity.put_at(:computing, "a-1", true, t0)
        |> AgentActivity.put_at(:heard, "a-1", true, t0)

      decayed = rail([agent("Listener", "a-1")], both, DateTime.add(t0, 3, :second))
      decayed_row = agent_row(decayed, "a-1")

      assert decayed_row =~ ~s(data-activity-state="computing")
      assert decayed_row =~ "Thinking · 3s"
      refute decayed_row =~ "Heard"
    end

    # `AgentActivityBadge`'s ONE table, extended rather than duplicated —
    # the stage's own constraint ("add rows to that ONE table"). `:heard`
    # sits on the same `--color-info` slot Thinking/Writing use (working
    # FOR you, nothing asked OF you), and its ring pulses — the shipped
    # motion vocabulary has no "single pulse" utility, and the stamp only
    # lives 2s regardless.
    test "Heard sits on the info slot and pulses, matching Thinking/Writing's colour family" do
      t0 = ~U[2026-01-01 00:00:00Z]
      activity = AgentActivity.put_at(AgentActivity.new(), :heard, "a-1", true, t0)

      row =
        agent_row(rail([agent("Listener", "a-1")], activity, DateTime.add(t0, 1, :second)), "a-1")

      assert row =~ "border-info"
      assert row =~ "text-info"
      assert row =~ "animate-pulse"
      refute row =~ "warning"
    end

    # TRUNCATION (the stage spec): "the word never truncates and the age
    # never truncates; the reason clause WRAPS to a second line rather
    # than clipping. The node currently carries `truncate` — that class
    # must not be allowed to clip a reason." A generic (no linked Agent)
    # delay clause is enough to prove the node's OWN class list, without
    # needing a DB-backed Agent/Room — `AgentDelayReason`'s default
    # clause shows once `age_s` reaches its own threshold regardless of
    # who is asking.
    test "the word node does not truncate, and a present reason gets its own wrappable node" do
      t0 = ~U[2026-01-01 00:00:00Z]
      delayed = DateTime.add(t0, 15, :second)

      activity = AgentActivity.put_at(AgentActivity.new(), :computing, "a-1", true, t0)
      html = rail([agent("Slow", "a-1")], activity, delayed)

      parsed = Floki.parse_fragment!(agent_row(html, "a-1"))
      [word_node] = Floki.find(parsed, ~s([data-role="agent-activity-word"]))

      refute Floki.attribute([word_node], "class") |> List.first() =~ "truncate",
             "the word node still carries `truncate`, which can clip the reason clause"

      assert Floki.find(parsed, ~s([data-role="agent-activity-primary"])) != []
      assert Floki.find(parsed, ~s([data-role="agent-activity-reason"])) != []
      assert agent_row(html, "a-1") =~ "still running a tool"
    end
  end
end
