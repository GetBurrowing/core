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

  # `/60`, not `/50` — task 01a0cf5d stage 3 raised both headings' label
  # opacity together after a CDP-measured contrast failure (3.89:1 against
  # the rail's actual painted background in the light theme, under the
  # 4.5:1 AA floor for 11px text). See `participant_rail.ex`'s comment at
  # the humans heading for the measurement.
  @heading_type "text-[11px] font-semibold uppercase tracking-widest text-base-content/60"

  defp human(name, id) do
    %{
      id: id,
      participant_id: id,
      participant_type: "user",
      display_name: name,
      avatar_url: nil,
      # An EXPLICIT LiveKit identity, so the slot tests name the key by
      # hand instead of asking `gallery_identity/1` what it would have
      # produced — a fixture that computes its own expected value with
      # the code under test cannot fail when that code is wrong. Same
      # string the fallback clause yields, so no existing assertion moves.
      identity: "user:" <> id,
      # No `attention_config` content. Nothing in production writes
      # `"mic_on"` — `MeetingLive` builds every live presence row with
      # `attention_config: %{}` — so a fixture that seeded it was testing a
      # branch the app cannot reach. Task 01a0740c moved per-identity mic
      # state onto `:muted_identities`, fed from LiveKit; `mic_on?/1` and
      # its rail read are retired in stage 3.
      attention_config: %{}
    }
  end

  defp agent(name, id) do
    %{
      id: "p-" <> id,
      participant_id: id,
      participant_type: "agent",
      display_name: name,
      avatar_url: nil,
      # `Meetings` mints an agent's LiveKit identity as `"agent:" <> slug`
      # (`meetings.ex:5020`). The rail does not care what the string means
      # — it is a map key — but a realistic one keeps the human and agent
      # key spaces from silently overlapping in a fixture.
      identity: "agent:" <> id,
      attention_config: %{}
    }
  end

  # An agent row `agent_id_of/1` cannot resolve to a binary id (task
  # 01a0d3cd stage 1). `MeetingLive.meeting_participant_view_model/1`
  # never actually produces this shape for a real live participant — every
  # branch that sets `participant_type: "agent"` also sets a binary
  # `participant_id` — so this fixture exists only to prove the DEFENSIVE
  # side of the fix: an agent row this malformed still renders in the
  # roster (it is not filtered out — see `agent_row_info/2`'s `absent`
  # default), and per Saru's canvas 01a0d3cf-a424 finding 2, its hold
  # control must render disabled rather than vanish.
  defp agent_with_unresolved_id(name) do
    %{
      id: "p-unresolved",
      participant_id: nil,
      participant_type: "agent",
      display_name: name,
      avatar_url: nil,
      identity: nil,
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

  # The state word as rendered, with the age clause it shares its node with
  # — `"Thinking · 3s"`, `"Idle"`, `"Delayed"`. Read off the node rather
  # than by `=~` on the whole row, because "Heard" appearing ANYWHERE in the
  # row (a class, an aria string, the second line) would satisfy `=~` while
  # the word itself said something else entirely, which is the exact
  # confusion this stage exists to remove.
  defp primary_word(row_html) do
    row_html
    |> Floki.parse_fragment!()
    |> Floki.find(~s([data-role="agent-activity-primary"]))
    |> Floki.text()
    |> String.trim()
  end

  # A rail carrying the two per-identity MapSets (task 01a0740c stage 3).
  # `:muted` / `:camera_off` are lists of LITERAL identity strings.
  defp media_rail(participants, opts \\ []) do
    render_component(&ParticipantRail.participant_rail/1,
      participants: participants,
      agents_by_id: %{},
      meeting: %{id: "m-1", host_participant_id: "u-1"},
      muted_identities: MapSet.new(Keyword.get(opts, :muted, [])),
      camera_off_identities: MapSet.new(Keyword.get(opts, :camera_off, []))
    )
  end

  defp row_for(html, identity) do
    case Regex.run(
           ~r/<li[^>]*data-participant-identity="#{Regex.escape(identity)}".*?<\/li>/s,
           html
         ) do
      [row] -> row
      nil -> flunk("no roster row for identity #{identity}")
    end
  end

  defp slot(row, role) do
    case row |> Floki.parse_fragment!() |> Floki.find(~s([data-role="#{role}"])) do
      [node] -> node
      other -> flunk("expected exactly one #{role} in the row, got #{length(other)}")
    end
  end

  defp attr(node, name), do: node |> Floki.attribute(name) |> List.first()

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

    # task 01a0cf5d stage 3: same measured failure as the section
    # headings — `/50` on this rendered 11px sub-line is 3.89:1 in the
    # light theme against the rail's actual painted background, under
    # the 4.5:1 AA floor. `/60` clears both themes.
    test "the guest sub-line is /60, not the failing /50" do
      html = rail([human("Priyanka (guest)", "u-1")])

      assert html =~ "via guest link"

      [node] =
        html
        |> Floki.parse_fragment!()
        |> Floki.find(~s([data-role="participant-via-guest-link"]))

      class = node |> Floki.attribute("class") |> List.first()

      assert class =~ "text-base-content/60"
      refute class =~ "text-base-content/50"
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

    # task 01a0cf5d stage 3: Idle is the state most agent rows sit in most
    # of the time (the moduledoc calls it "the common case"), and its word
    # was the one place `/50` sat on rendered TEXT rather than a ring or a
    # glyph. Measured against the rail's actual painted background, `/50`
    # is 3.89:1 in the light theme at 11px — under the 4.5:1 AA floor for
    # text this size. `/60` clears both themes.
    test "the idle word is /60, not the failing /50" do
      row = agent_row(four_state_rail(), "a-idle")

      [word_node] =
        row
        |> Floki.parse_fragment!()
        |> Floki.find(~s([data-role="agent-activity-word"]))

      class = word_node |> Floki.attribute("class") |> List.first()

      assert class =~ "text-base-content/60"
      refute class =~ "text-base-content/50"
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

    # CHANGED in task 01a07400 stage 3. This test used to assert
    # `row =~ "Heard"` — that a heard receipt REPLACED the state word. Saru's
    # design direction (canvas 01a07402-99e3) rules that out explicitly, and
    # names this rail as "the one that is currently drawn wrong":
    #
    #   "`heard` must not swap the word. … If a 2s state replaces the word, a
    #    rail of four agents strobes through Heard/Idle/Heard and becomes
    #    unreadable exactly when the room is busiest. Draw it as a single
    #    ring flash and leave the word alone."
    #
    # The DECAY itself is untouched and still asserted below, and the unit
    # test that pins it (`agent_activity_test.exs`) is not modified by this
    # stage at all. What changed is only which of the row's three channels
    # the receipt is allowed to paint.
    test "Heard flashes the ring and leaves the word alone, then the flash decays" do
      t0 = ~U[2026-01-01 00:00:00Z]

      heard_only = AgentActivity.put_at(AgentActivity.new(), :heard, "a-1", true, t0)

      just_heard = rail([agent("Listener", "a-1")], heard_only, DateTime.add(t0, 1, :second))
      row = agent_row(just_heard, "a-1")

      # The RING is the heard reading...
      assert row =~ ~s(data-activity-state="heard")
      assert row =~ "○"

      # ...and the WORD is the state underneath it, which for an agent with
      # no other signal is idle. Not "Heard".
      assert primary_word(row) == "Idle"

      # An agent that is WORKING keeps saying so through the flash. This is
      # the case the ruling is actually about: a human talking over a
      # working agent delivers a segment to it, and the rail must not blank
      # what it was doing for two seconds because of that.
      both =
        AgentActivity.new()
        |> AgentActivity.put_at(:computing, "a-1", true, t0)
        |> AgentActivity.put_at(:heard, "a-1", true, t0)

      during =
        agent_row(rail([agent("Listener", "a-1")], both, DateTime.add(t0, 1, :second)), "a-1")

      assert during =~ ~s(data-activity-state="heard"), "the ring should carry the flash"
      assert primary_word(during) == "Thinking · 1s", "the word must survive the flash"

      # Once the 2s window decays the ring falls back too, and the row is
      # exactly what it would have been if nothing had been heard.
      decayed = rail([agent("Listener", "a-1")], both, DateTime.add(t0, 3, :second))
      decayed_row = agent_row(decayed, "a-1")

      assert decayed_row =~ ~s(data-activity-state="computing")
      assert primary_word(decayed_row) == "Thinking · 3s"
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

  # ── task 01a07400 stage 3: the two states core produces, on the rail ──────
  #
  # Stage 1 gave the AGENT two states it can declare; stage 2 gave CORE two
  # it can assert. Neither had a pixel. This is the half that draws them,
  # following Saru's design direction (canvas 01a07402-99e3).
  describe "Speaking and Delayed" do
    alias Platform.Meetings.AgentActivity.Delayed

    # `:speaking` lives in an ETS table keyed by MEETING id, not in the
    # struct, so it is only reachable through `resolve_at/3` — which is what
    # this stage wires the rail onto. A unique meeting id per test keeps the
    # shared table safe for `async: true`.
    defp rail_for_meeting(participants, meeting_id, opts) do
      render_component(
        &ParticipantRail.participant_rail/1,
        [
          participants: participants,
          agents_by_id: %{},
          meeting: %{id: meeting_id, host_participant_id: "u-1"},
          agent_activity: AgentActivity.new()
        ] ++ opts
      )
    end

    test "a live :speaking row reads Speaking, on success, with the amplitude ring" do
      meeting_id = "m-speaking-#{System.unique_integer([:positive])}"
      {:ok, _entry} = AgentActivity.mark_speaking(meeting_id, "a-1", "utt-1")

      row =
        [agent("Talker", "a-1")]
        |> rail_for_meeting(meeting_id, now: DateTime.utc_now())
        |> agent_row("a-1")

      assert row =~ ~s(data-activity-state="speaking")
      assert primary_word(row) == "Speaking"
      assert row =~ "border-success"
      assert row =~ "agent-activity-ring-speaking"
      refute row =~ "warning"
    end

    # The state is store-backed and read at render time, so an agent with no
    # row reads exactly as it did before this stage. Without this the test
    # above would pass against a rail that painted every agent Speaking.
    test "an agent with no speaking row is untouched by the state existing" do
      meeting_id = "m-quiet-#{System.unique_integer([:positive])}"
      {:ok, _entry} = AgentActivity.mark_speaking(meeting_id, "a-1", "utt-1")

      row =
        [agent("Talker", "a-1"), agent("Listener", "a-2")]
        |> rail_for_meeting(meeting_id, now: DateTime.utc_now())
        |> agent_row("a-2")

      refute row =~ ~s(data-activity-state="speaking")
      assert primary_word(row) == "Idle"
    end

    # ── The two-line row ────────────────────────────────────────────────
    #
    # "The row never changes shape as an agent works, EXCEPT for `delayed`,
    # which earns a second line because it is the only state carrying
    # information the first line cannot hold."
    test ":delayed puts its reason on its own second line, below the word" do
      t0 = ~U[2026-01-01 00:00:00Z]
      activity = AgentActivity.put_at(AgentActivity.new(), :computing, "a-1", true, t0)

      row =
        [agent("Octavius", "a-1")]
        |> rail_for_meeting("m-delayed-#{System.unique_integer([:positive])}",
          agent_activity: activity,
          now: DateTime.add(t0, 12, :second),
          delays: %{"a-1" => Delayed.new!("waiting on GitHub")}
        )
        |> agent_row("a-1")

      parsed = Floki.parse_fragment!(row)

      assert row =~ ~s(data-activity-state="delayed")

      # Line one: the word, and NOT the reason. The canvas's delayed wire
      # carries no elapsed figure either.
      assert primary_word(row) == "Delayed"
      refute primary_word(row) =~ "waiting on GitHub"
      refute primary_word(row) =~ "12s"

      # Line two: its own node, carrying the reason.
      [reason_node] = Floki.find(parsed, ~s([data-role="agent-activity-delay-reason"]))
      assert Floki.text([reason_node]) |> String.trim() == "waiting on GitHub"
    end

    # ── Avatar stays pinned to the name, however tall the row grows ──────
    #
    # task 01a0cf5d stage 3: a CDP capture with a realistic long `:delayed`
    # reason (the kind `AgentDelayReason` actually produces) showed the
    # row's `items-center` centering the 28px avatar in the whole grown
    # row — 45px away from the name at 312px, not beside it. `:delayed` is
    # the only state whose reason line is unbounded (it deliberately never
    # truncates), so it is the only row whose opening `<li>` tag now
    # carries `items-start`; every other state's row is short enough that
    # centering never mattered and stays as it was.
    test ":delayed opens its <li> with items-start, not items-center" do
      t0 = ~U[2026-01-01 00:00:00Z]
      activity = AgentActivity.put_at(AgentActivity.new(), :computing, "a-1", true, t0)

      row =
        [agent("Octavius", "a-1")]
        |> rail_for_meeting("m-delayed-align-#{System.unique_integer([:positive])}",
          agent_activity: activity,
          now: DateTime.add(t0, 12, :second),
          delays: %{"a-1" => Delayed.new!("waiting on GitHub")}
        )
        |> agent_row("a-1")

      [opening_tag] = Regex.run(~r/<li\b[^>]*>/, row)

      assert opening_tag =~ "items-start"
      refute opening_tag =~ "items-center"
    end

    test "an ordinary (non-delayed) row keeps items-center" do
      row = four_state_rail() |> agent_row("a-think")

      [opening_tag] = Regex.run(~r/<li\b[^>]*>/, row)

      assert opening_tag =~ "items-center"
      refute opening_tag =~ "items-start"
    end

    # TRUNCATION ORDER — "the reason is the point, so it truncates LAST".
    # Implemented as the reason not truncating at all while the NAME keeps
    # its `truncate`, which is that ordering in its strongest form. Asserted
    # as a comparison between the two nodes, because asserting only that the
    # reason lacks `truncate` would pass on a row whose name lacked it too —
    # i.e. on a layout with no ordering at all.
    test "the reason line never truncates, and the name is what yields first" do
      t0 = ~U[2026-01-01 00:00:00Z]
      activity = AgentActivity.put_at(AgentActivity.new(), :computing, "a-1", true, t0)

      long =
        "waiting on GitHub for a workflow run that has been queued for several minutes now"

      parsed =
        [agent("Octavius Bartholomew Winterbourne III", "a-1")]
        |> rail_for_meeting("m-trunc-#{System.unique_integer([:positive])}",
          agent_activity: activity,
          now: DateTime.add(t0, 12, :second),
          delays: %{"a-1" => Delayed.new!(long)}
        )
        |> agent_row("a-1")
        |> Floki.parse_fragment!()

      reason_class =
        parsed
        |> Floki.find(~s([data-role="agent-activity-delay-reason"]))
        |> Floki.attribute("class")
        |> List.first()

      name_class =
        parsed
        |> Floki.find(~s([data-role="participant-name"]))
        |> Floki.attribute("class")
        |> List.first()

      refute reason_class =~ "truncate",
             "the reason must not clip — it is the most meaningful thing on the row"

      assert reason_class =~ "break-words", "a long reason has to wrap rather than overflow"

      assert name_class =~ "truncate",
             "the name must yield before the reason does, or there is no ordering at all"

      # And the reason survives intact, in full.
      assert Floki.text(Floki.find(parsed, ~s([data-role="agent-activity-delay-reason"]))) =~ long
    end

    # "The `sr-only` line already present must carry the reason too:
    # 'Octavius is delayed, waiting on GitHub', not just 'delayed'." This is
    # the reduced-motion half of the design reaching a reader who gets no
    # visual channel at all.
    test "the accessible sentence carries the reason, not just the word" do
      t0 = ~U[2026-01-01 00:00:00Z]
      activity = AgentActivity.put_at(AgentActivity.new(), :computing, "a-1", true, t0)

      row =
        [agent("Octavius", "a-1")]
        |> rail_for_meeting("m-sr-#{System.unique_integer([:positive])}",
          agent_activity: activity,
          now: DateTime.add(t0, 12, :second),
          delays: %{"a-1" => Delayed.new!("waiting on GitHub")}
        )
        |> agent_row("a-1")

      # MERGE NOTE (main @ 0da01c45, task 01a0740c stage 3): the row now
      # carries a SECOND `sr-only` sentence — the mic/camera state summary,
      # tagged `data-role="participant-state-summary"`. Selecting on
      # `span.sr-only` alone therefore returns both nodes and concatenates
      # their text. Reject the tagged one so this stays an equality on a
      # single node; the `[sr_node] =` match also asserts there is exactly
      # one activity sentence, which a substring match would not.
      [sr_node] =
        row
        |> Floki.parse_fragment!()
        |> Floki.find("span.sr-only")
        |> Enum.reject(&(Floki.attribute([&1], "data-role") == ["participant-state-summary"]))

      sr = [sr_node] |> Floki.text() |> String.trim()

      assert sr == "Octavius is Delayed, waiting on GitHub"
    end

    # The hard-won rule: `warning` means a human is being asked for
    # something, and a blocked agent asks nothing of anyone.
    test ":delayed does not spend the warning slot, and does not spin" do
      t0 = ~U[2026-01-01 00:00:00Z]
      activity = AgentActivity.put_at(AgentActivity.new(), :computing, "a-1", true, t0)

      row =
        [agent("Octavius", "a-1")]
        |> rail_for_meeting("m-warn-#{System.unique_integer([:positive])}",
          agent_activity: activity,
          now: DateTime.add(t0, 12, :second),
          delays: %{"a-1" => Delayed.new!("agent went offline")}
        )
        |> agent_row("a-1")

      refute row =~ "warning"
      refute row =~ "animate-pulse"
      refute row =~ "animate-spin"
    end

    # A delay only qualifies a WORKING state. An idle agent is not blocked,
    # it is idle — so an injected delay must be ignored rather than drawn.
    # Without this, `apply_delays/2`'s guard could be deleted and every test
    # above would stay green.
    test "an idle agent is never delayed, even when a delay is handed to the row" do
      row =
        [agent("Nobody", "a-1")]
        |> rail_for_meeting("m-idle-#{System.unique_integer([:positive])}",
          now: DateTime.utc_now(),
          delays: %{"a-1" => Delayed.new!("waiting on GitHub")}
        )
        |> agent_row("a-1")

      assert primary_word(row) == "Idle"
      refute row =~ "waiting on GitHub"

      assert Floki.find(Floki.parse_fragment!(row), ~s([data-role="agent-activity-delay-reason"])) ==
               []
    end
  end

  describe "mic and camera slots (task 01a0740c stage 3)" do
    # THE DEFECT THIS REPLACES: the rail read `MeetingLive.mic_on?/1`,
    # which read `attention_config["mic_on"]`, which `MeetingLive`
    # hardcoded to `%{}` on every live presence row — so every row read
    # "Microphone off" for everyone, always. A test that hands the
    # component a muted identity and asserts a muted glyph would have
    # PASSED against that code. Every assertion below therefore names two
    # participants and asserts they differ.

    test "only the identity in the muted set reads muted" do
      html =
        media_rail(
          [human("Mariah", "u-1"), human("Harper", "u-2")],
          muted: ["user:u-2"]
        )

      assert attr(slot(row_for(html, "user:u-2"), "mic-indicator"), "data-mic-state") == "off"
      assert attr(slot(row_for(html, "user:u-1"), "mic-indicator"), "data-mic-state") == "on"
    end

    test "only the identity in the camera-off set reads camera off" do
      html =
        media_rail(
          [human("Mariah", "u-1"), human("Harper", "u-2")],
          camera_off: ["user:u-1"]
        )

      assert attr(slot(row_for(html, "user:u-1"), "camera-indicator"), "data-camera-state") ==
               "off"

      assert attr(slot(row_for(html, "user:u-2"), "camera-indicator"), "data-camera-state") ==
               "on"
    end

    test "the two axes are independent: muted does not imply camera off" do
      html = media_rail([human("Mariah", "u-1")], muted: ["user:u-1"])
      row = row_for(html, "user:u-1")

      assert attr(slot(row, "mic-indicator"), "data-mic-state") == "off"
      assert attr(slot(row, "camera-indicator"), "data-camera-state") == "on"
    end

    test "both slots are present on every row in every state" do
      html =
        media_rail(
          [human("Mariah", "u-1"), human("Harper", "u-2"), agent("Saru", "a-1")],
          muted: ["user:u-2"],
          camera_off: ["user:u-2"]
        )

      parsed = Floki.parse_fragment!(html)

      # THREE rows, THREE mic slots, THREE camera slots. An indicator that
      # vanishes in one of its states is indistinguishable from one that
      # failed to render, which is the whole reason the slots are fixed.
      assert length(Floki.find(parsed, "li[data-participant-identity]")) == 3
      assert length(Floki.find(parsed, ~s([data-role="mic-indicator"]))) == 3
      assert length(Floki.find(parsed, ~s([data-role="camera-indicator"]))) == 3
    end

    test "off is carried by the well and the accessible label, not by the glyph alone" do
      # FE-19 (01a07486-7985-7001-87ce-277681791f52) added
      # `assets/icons/24/outline/microphone-slash.svg` and taught
      # `assets/vendor/heroicons.js` to read that repo-owned root alongside
      # the vendored Heroicons set, so `hero-microphone-slash` now generates
      # CSS and the slashed glyph draws for real. It is still one channel of
      # three, and this assertion cannot tell you the mask resolved: the
      # class string sits in the markup whether or not any CSS exists for
      # it. So the two channels that do not depend on the icon set, the red
      # well and the words, stay asserted beside it. Whether the mask
      # resolves is a browser question, checked by computed `mask-image`.
      row = row_for(media_rail([human("Mariah", "u-1")], muted: ["user:u-1"]), "user:u-1")
      mic = slot(row, "mic-indicator")

      assert attr(mic, "class") =~ "bg-error/15"
      assert attr(mic, "aria-label") == "Microphone muted"
      assert row =~ "hero-microphone-slash"
      assert row =~ "Mariah, muted, camera on"
    end

    test "the camera's slashed glyph is asserted separately from the mic's" do
      # `video-camera-slash.svg` ships in all four Heroicons sizes, so the
      # camera-off state has always had all three channels. The mic's glyph
      # now draws too, from `assets/icons/24/outline/microphone-slash.svg`
      # (FE-19, 01a07486-7985-7001-87ce-277681791f52), but the two resolve
      # through DIFFERENT roots: the camera through `deps/heroicons`, the
      # mic through our own `assets/icons`. So they are still asserted
      # separately rather than assumed to share a fate.
      row = row_for(media_rail([human("Mariah", "u-1")], camera_off: ["user:u-1"]), "user:u-1")
      cam = slot(row, "camera-indicator")

      assert attr(cam, "class") =~ "bg-error/15"
      assert attr(cam, "aria-label") == "Camera off"
      assert row =~ "hero-video-camera-slash"
      assert row =~ "Mariah, unmuted, camera off"
    end

    test "an agent's camera slot is UNAVAILABLE, not off" do
      html = media_rail([human("Mariah", "u-1"), agent("Saru", "a-1")], camera_off: ["user:u-1"])

      agent_cam = slot(row_for(html, "agent:a-1"), "camera-indicator")
      human_cam = slot(row_for(html, "user:u-1"), "camera-indicator")

      # DIFFERENT ACCESSIBLE TEXT. "Off" implies it could be on; a roster
      # that said "camera off" on every agent row would read as every
      # agent having disabled their video.
      assert attr(agent_cam, "aria-label") == "No camera"
      assert attr(human_cam, "aria-label") == "Camera off"

      # DIFFERENT CLASS, on both the well and the glyph — greyed and
      # neutral against red and tinted — so the two are not separable only
      # by their labels.
      assert attr(agent_cam, "data-camera-state") == "unavailable"
      assert attr(agent_cam, "class") =~ "bg-base-300"
      refute attr(agent_cam, "class") =~ "bg-error"
      assert attr(human_cam, "class") =~ "bg-error/15"

      # DIFFERENT GLYPH: `hero-minus` reads as not-applicable and is not a
      # camera at all, so the distinction survives a viewer who cannot
      # separate the two hues.
      assert row_for(html, "agent:a-1") =~ "hero-minus"
      refute row_for(html, "agent:a-1") =~ "hero-video-camera"
    end

    test "an agent's camera slot is non-interactive" do
      cam = slot(row_for(media_rail([agent("Saru", "a-1")]), "agent:a-1"), "camera-indicator")

      assert attr(cam, "class") =~ "pointer-events-none"
      # No `title`: `pointer-events-none` means a tooltip could never
      # appear, and an attribute whose behaviour is suppressed reads as a
      # working one.
      assert attr(cam, "title") == nil
    end

    test "an agent's MIC slot is live, keyed the same way a human's is" do
      # Agents publish audio, and `meeting_client.js` reports an agent that
      # has published no mic at all as muted ("no publication reads as
      # off"), so this slot is a real signal rather than decoration.
      html = media_rail([agent("Saru", "a-1"), agent("Orion", "a-2")], muted: ["agent:a-2"])

      assert attr(slot(row_for(html, "agent:a-2"), "mic-indicator"), "data-mic-state") == "off"
      assert attr(slot(row_for(html, "agent:a-1"), "mic-indicator"), "data-mic-state") == "on"
    end

    test "every row carries an sr-only line naming the participant and both states" do
      html =
        media_rail(
          [human("Mariah", "u-1"), human("Harper", "u-2"), agent("Saru", "a-1")],
          muted: ["user:u-2"],
          camera_off: ["user:u-2"]
        )

      # The icons are the entire payload of this feature: a screen reader
      # that only gets the name gets nothing.
      assert row_for(html, "user:u-1") =~ "Mariah, unmuted, camera on"
      assert row_for(html, "user:u-2") =~ "Harper, muted, camera off"
      assert row_for(html, "agent:a-1") =~ "Saru, unmuted, no camera"

      summaries =
        html |> Floki.parse_fragment!() |> Floki.find(~s([data-role="participant-state-summary"]))

      assert length(summaries) == 3

      # `sr-only`, not visible text: a roster spelling out "unmuted, camera
      # on" for five people is a wall of words saying nothing happened.
      for node <- summaries, do: assert(attr([node], "class") =~ "sr-only")
    end

    test "the slots use the error/base tokens and neither warning nor success" do
      html =
        media_rail(
          [human("Mariah", "u-1"), human("Harper", "u-2"), agent("Saru", "a-1")],
          muted: ["user:u-2"],
          camera_off: ["user:u-2"]
        )

      slots =
        html
        |> Floki.parse_fragment!()
        |> Floki.find(~s([data-role="media-slots"]))
        |> Floki.raw_html()

      # `text-success` is reserved for SPEAKING and the mic-on state used
      # to take it — that was the violation this stage removes.
      refute slots =~ "success"

      # `warning` on this screen means "a human is being asked for
      # something". Being muted asks nothing of anyone.
      refute slots =~ "warning"

      assert slots =~ "text-error"
      assert slots =~ "bg-base-300"
    end

    test "with no sets supplied nobody is muted, rather than everybody" do
      # The nil-normalising default. `MeetingLive` used to make this
      # component claim every participant was muted forever; the fallback
      # for "the room has told us nothing yet" must be the quiet state.
      html = media_rail([human("Mariah", "u-1")])
      row = row_for(html, "user:u-1")

      assert attr(slot(row, "mic-indicator"), "data-mic-state") == "on"
      assert attr(slot(row, "camera-indicator"), "data-camera-state") == "on"
      assert row =~ "hero-microphone"
      refute row =~ "hero-microphone-slash"
    end
  end

  # Per-agent hold-to-talk (per the prototype). The control renders on
  # each agent row when the caller opts in, carries the agent id it
  # addresses, and is keyboard- and screen-reader-reachable.
  defp hold_rail(participants, opts) do
    render_component(
      &ParticipantRail.participant_rail/1,
      [
        participants: participants,
        agents_by_id: %{},
        meeting: %{id: "m-1", host_participant_id: "u-1"}
      ] ++ opts
    )
  end

  defp hold_controls(html) do
    html |> Floki.parse_fragment!() |> Floki.find(~s([data-role="meeting-agent-hold-to-talk"]))
  end

  defp status_chip_slot(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(~s([data-role="meeting-agent-status-chip-slot"]))
  end

  describe "per-agent hold-to-talk control" do
    test "is absent by default — a surface with no push-to-talk producer gets no control" do
      html = hold_rail([agent("Octavius", "oct-1")], [])
      assert hold_controls(html) == []
    end

    test "renders one control per agent, wired to the hook and carrying the agent id" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)

      [control] = hold_controls(html)

      assert Floki.attribute(control, "phx-hook") == ["MeetingPushToTalk"]
      # The hook owns the waveform transforms; a re-render on the next
      # activity tick must not wipe them mid-press.
      assert Floki.attribute(control, "phx-update") == ["ignore"]
      # The id the server reads from `push_to_talk_press` to know WHO the
      # press is addressed to, up front.
      assert Floki.attribute(control, "data-agent-id") == ["oct-1"]

      # Keyboard- and screen-reader-reachable, and named for the agent.
      assert Floki.attribute(control, "type") == ["button"]
      [label] = Floki.attribute(control, "aria-label")
      assert label =~ "Octavius"

      # Twelve bars for the hook to paint, like the retired single button.
      bars =
        html
        |> Floki.parse_fragment!()
        |> Floki.find(~s([data-role="meeting-agent-hold-to-talk"] [data-ptt-bar]))

      assert Enum.count(bars) == 12

      # The shared touch utility and the refused-press slot survive the move.
      [classes] = Floki.attribute(control, "class")
      assert classes =~ "meeting-hold-target"
      assert classes =~ "min-h-11"
      assert classes =~ "data-[rejected=pointer-lost]:text-error"
    end

    test "the control id carries the caller's prefix, so two rosters never collide" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true, id_prefix: "left")
      [control] = hold_controls(html)
      assert Floki.attribute(control, "id") == ["left-oct-1"]
    end

    test "the held agent shows a Talking cue and the live region names it" do
      html =
        hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true, pressed_agent_id: "oct-1")

      frag = Floki.parse_fragment!(html)
      assert Floki.find(frag, ~s([data-role="meeting-agent-talking"])) != []

      region = Floki.find(frag, ~s([data-role="meeting-ptt-live-region"]))
      assert Floki.text(region) =~ "Talking to Octavius"
    end

    test "a NON-held agent shows no cue and an empty live region" do
      html =
        hold_rail([agent("Octavius", "oct-1")],
          hold_to_talk?: true,
          pressed_agent_id: "someone-else"
        )

      frag = Floki.parse_fragment!(html)
      assert Floki.find(frag, ~s([data-role="meeting-agent-talking"])) == []

      region = Floki.find(frag, ~s([data-role="meeting-ptt-live-region"]))
      assert Floki.text(region) |> String.trim() == ""
    end

    # Task 01a0febf stage 6 — Dalton's layout-shift bug (canvases
    # 01a0febf-652b-7001-83da-c15b1c4ea846 and 01a0ff1c-37ab-7001-a91c-
    # b61e0b1e7499, "1c" in his test matrix): real headless-Chromium
    # measurement on two separate builds (PR #1174, then its fix PR #1176,
    # which deliberately left this ONE bug alone) found that pressing Ask
    # inserted the "Talking…" cue as a bare extra flex item with no width
    # reserved ahead of time. The name column collapsed to 0, and the
    # overflow moved the kick button on desktop and the Ask button itself
    # on phone — a horizontal scrollbar on desktop, text covering the
    # name on phone.
    #
    # This component test is a LOWER-CONFIDENCE check than Dalton's real
    # browser measurement, not a replacement for it: this suite renders
    # HEEx with no layout engine behind it, so it cannot measure a single
    # pixel. What it CAN prove is the structural shape the fix depends
    # on — a slot that exists, and is the same size, in BOTH states. That
    # shape is necessary for the live measurement to come out flat; it is
    # not sufficient on its own, which is why the PR this guards also
    # carries a live CDP measurement where one was reachable.
    test "the status-chip slot is reserved — present and the same size whether or not a cue is showing" do
      idle_html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)

      talking_html =
        hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true, pressed_agent_id: "oct-1")

      held_by_other_html =
        hold_rail([agent("Octavius", "oct-1")],
          hold_to_talk?: true,
          pressed_agent_id: "someone-else",
          ask_floor_holders: %{"oct-1" => "Saru"}
        )

      idle_slot = status_chip_slot(idle_html)
      talking_slot = status_chip_slot(talking_html)
      held_by_slot = status_chip_slot(held_by_other_html)

      # The slot exists in ALL THREE renders — idle, this viewer talking,
      # and someone else holding the floor — not only when a cue happens
      # to be active. Before this fix there was no slot at all: the cue
      # was a bare `<span>` that only existed in the DOM while its `:if`
      # was true, so the row's own content width changed with it.
      assert idle_slot != []
      assert talking_slot != []
      assert held_by_slot != []

      # Its OWN classes — the ones that give it a footprint, not whatever
      # cue is painted inside it — are identical across all three, so the
      # row's total flex width is a function of this slot's markup alone,
      # never of which cue (if any) is currently rendered inside it.
      [idle_classes] = Floki.attribute(idle_slot, "class")
      [talking_classes] = Floki.attribute(talking_slot, "class")
      [held_by_classes] = Floki.attribute(held_by_slot, "class")
      assert idle_classes == talking_classes
      assert idle_classes == held_by_classes

      # The invisible sizer — what actually establishes the slot's width
      # — renders in every state too, and carries `invisible` (occupies
      # layout space, paints nothing) rather than `hidden` (which would
      # occupy none and defeat the whole reservation).
      [sizer_classes] =
        idle_html
        |> Floki.parse_fragment!()
        |> Floki.find(~s([data-role="meeting-agent-status-chip-sizer"]))
        |> Floki.attribute("class")

      assert sizer_classes =~ "invisible"
    end

    # Same regression — the defensive second layer. Even with the slot
    # above reserved, the name column's own `min-w-0` gave it no floor of
    # its own, which is what let it collapse to literal 0px in Dalton's
    # measurement rather than just truncating further. Asserted by class,
    # not by rendered width, for the same reason as the slot test above.
    test "the agent name column keeps a non-zero min-width floor" do
      html =
        hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true, pressed_agent_id: "oct-1")

      # The immediate wrapper around `participant-name` — found by its
      # position in the markup, not a bare substring search, since
      # several OTHER feedback-text nodes in this same row legitimately
      # carry `min-w-0 flex-1` for an unrelated reason (the hold-to-talk
      # coach line, the remove/mute error sentences) and a loose `=~`
      # would false-positive on those.
      [[name_wrapper_class]] =
        Regex.scan(
          ~r/<div class="([^"]*)">\s*<div class="truncate text-xs font-medium text-base-content\/90" data-role="participant-name"/,
          html,
          capture: :all_but_first
        )

      # `min-w-[32px]`, not `min-w-0` — the regression this guards is the
      # name column having NO floor at all, which is what let it collapse
      # to literal 0px once the status-chip slot (tested above) claimed
      # width it previously got for free.
      assert name_wrapper_class == "min-w-[32px] flex-1"
    end

    # Task 01a0d3cd stage 1 — Harper's "I still don't see the ASK button"
    # report. The gate used to be `@hold_to_talk? and is_binary(aid)`, so an
    # agent row `agent_id_of/1` could not resolve dropped the control with
    # ZERO trace: no disabled button, no DOM node, nothing a viewer or a
    # test could tell apart from the control never having been built at
    # all. Saru's canvas 01a0d3cf-a424 (finding 2) rules that a persistent
    # control must render disabled at a boundary, never absent — this is
    # the regression test for that rule, not for an achievable production
    # state (see `agent_with_unresolved_id/1`'s comment: real agent rows
    # always carry a binary id).
    test "an agent row with no resolvable id still renders its hold control, disabled" do
      html = hold_rail([agent_with_unresolved_id("Ghost")], hold_to_talk?: true)

      [control] = hold_controls(html)

      assert Floki.attribute(control, "disabled") == ["disabled"]
      # No id to address a press to — the attribute is omitted rather than
      # sent as the literal string "" (same nil-drops-the-attribute
      # convention `camera_title(:unavailable)` uses elsewhere in this
      # component).
      assert Floki.attribute(control, "data-agent-id") == []
      # Still keyboard-reachable in principle and still named for the
      # agent — a screen reader hitting a disabled control is a
      # legitimate outcome; hitting nothing at all is the bug.
      [label] = Floki.attribute(control, "aria-label")
      assert label =~ "Ghost"
    end

    test "a resolvable agent's control is never disabled by the id-fallback path" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      [control] = hold_controls(html)
      assert Floki.attribute(control, "disabled") == []
    end

    # Task 01a0d3cd stage 2 — Saru's canvas 01a0d3cf-a424, finding 1: "Label
    # the button ... the word is the fix". An icon-only ghost button reads
    # as a status glyph, not a control; the visible word is what makes it
    # legible as one.
    test "the control carries a visible 'Ask' label, not an icon alone" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      [control] = hold_controls(html)

      [label_node] = Floki.find(control, ~s([data-role="meeting-agent-hold-label"]))
      assert Floki.text(label_node) |> String.trim() == "Ask"

      [label_classes] = Floki.attribute(label_node, "class")
      assert label_classes =~ "whitespace-nowrap"
      assert label_classes =~ "shrink-0"
    end

    # Canvas palette table: rest state is `--color-primary` fill with a
    # BLACK label (`text-primary-content`, pinned black in both themes —
    # never `text-base-content`, which flips to near-white in dark and
    # would be exactly the white-on-cyan the canvas rules out).
    test "an enabled control's rest state is filled primary, black label, no ghost" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      [control] = hold_controls(html)

      [classes] = Floki.attribute(control, "class")
      assert classes =~ "bg-primary"
      assert classes =~ "text-primary-content"
      refute classes =~ "btn-ghost"
    end

    # ── Item 1 (task 01a0f842 stage 1, canvas 01a0f846-cfb1), STRENGTHENED
    # round 3 (task 01a0fa7e-afd7) ──────────────────────────────────────────
    #
    # The round-2 regression: pressed used to repaint the SAME colours as
    # rest (`bg-primary text-primary-content` both times) — "doesn't feel
    # tactile" because nothing visibly changed. This checks the fix is a
    # real inversion, not a second coat of the same paint: black fill,
    # cyan label, and a cyan ring that moved onto the key itself (the row
    # lost its own ring — see the agent-row test above). Round 3 widened
    # the ring to 3px with an offset (Harper's round-3 report that the
    # round-2 fix "performs the same way" — see `app.css`'s own comment
    # on the `transition-duration` cascade bug that silently zeroed the
    # press-scale's animation).
    test "pressed state inverts to black fill, cyan label, and an offset cyan ring on the key" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      [control] = hold_controls(html)

      [classes] = Floki.attribute(control, "class")
      class_list = String.split(classes, " ")

      assert "data-[pressed=true]:bg-primary-content" in class_list
      assert "data-[pressed=true]:text-primary" in class_list
      assert "data-[pressed=true]:ring-[3px]" in class_list
      assert "data-[pressed=true]:ring-primary" in class_list
      assert "data-[pressed=true]:ring-offset-2" in class_list

      # The old identical-repaint bug, named explicitly so a future edit
      # that reintroduces it fails loudly here instead of only "feeling"
      # wrong again.
      refute "data-[pressed=true]:bg-primary" in class_list
      refute "data-[pressed=true]:text-primary-content" in class_list
    end

    # `data-held` is the separate, LATER signal (flips true only once
    # `MeetingPushToTalk`'s 380ms hold threshold fires) that the
    # glyph-to-waveform swap and the hold-threshold underline key off —
    # both must land at 380ms, not at press (0ms, where `data-pressed`
    # already flips). The control starts with both false.
    test "the control starts with data-pressed and data-held both false, and renders the hold-threshold underline" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      [control] = hold_controls(html)

      assert Floki.attribute(control, "data-pressed") == ["false"]
      assert Floki.attribute(control, "data-held") == ["false"]

      assert Floki.find(control, ~s([data-role="meeting-agent-hold-underline"])) != []
    end

    # The glyph-to-waveform swap (task 01a0f324 stage 3) used to key off
    # `data-pressed`, which flips at 0ms — so the waveform replaced the
    # glyph the instant the pointer went down, not at the 380ms hold
    # threshold the canvas specifies. This checks both halves of the swap
    # moved to `data-held`, and that neither still reads `data-pressed`.
    test "the glyph-to-waveform swap keys off data-held, not data-pressed" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      [control] = hold_controls(html)

      [glyph] = Floki.find(control, ~s([data-role="meeting-agent-hold-indicator"] .hero-signal))
      [glyph_classes] = Floki.attribute(glyph, "class")
      assert glyph_classes =~ "group-data-[held=true]/ptt:opacity-0"
      refute glyph_classes =~ "group-data-[pressed=true]/ptt:opacity-0"

      [waveform] = Floki.find(control, ~s([data-role="meeting-agent-hold-waveform"]))
      [waveform_classes] = Floki.attribute(waveform, "class")
      assert waveform_classes =~ "group-data-[held=true]/ptt:opacity-100"
      refute waveform_classes =~ "group-data-[pressed=true]/ptt:opacity-100"
    end

    # Canvas palette table: disabled drops to `--color-base-300` fill /
    # `--color-neutral` label, and the "Ask" word never disappears — this is
    # the id-fallback disabled path from stage 1, now checked for colour too.
    test "a disabled control drops to base-300/neutral fill and keeps its label" do
      html = hold_rail([agent_with_unresolved_id("Ghost")], hold_to_talk?: true)
      [control] = hold_controls(html)

      [classes] = Floki.attribute(control, "class")
      class_list = String.split(classes, " ")
      assert "bg-base-300" in class_list
      assert "text-neutral" in class_list
      # The base fill is base-300, not primary — the only `bg-primary` on
      # the disabled control is the pressed-state variant, which never
      # fires because the button is `disabled`.
      refute "bg-primary" in class_list

      [label_node] = Floki.find(control, ~s([data-role="meeting-agent-hold-label"]))
      assert Floki.text(label_node) |> String.trim() == "Ask"
    end

    # Same disabled treatment on the OTHER boundary that disables the
    # control — another viewer already holds this agent's floor — so the
    # colour rule is not accidentally coupled to the id-fallback path alone.
    test "a control held by another viewer also drops to the disabled fill" do
      html =
        hold_rail([agent("Octavius", "oct-1")],
          hold_to_talk?: true,
          pressed_agent_id: "someone-else",
          ask_floor_holders: %{"oct-1" => "Dalton"}
        )

      [control] = hold_controls(html)

      assert Floki.attribute(control, "disabled") == ["disabled"]

      [classes] = Floki.attribute(control, "class")
      assert classes =~ "bg-base-300"
      assert classes =~ "text-neutral"
    end

    # ── Item 3a (task 01a0f324 stage 3): fixed-frame button ────────────────
    #
    # The production bug: the waveform widened `w-0` -> `w-9` on press
    # inside a button with no width of its own, so the whole control grew
    # ~36px into neighbouring row content. The server only ever renders
    # `data-pressed="false"` (the hook flips it client-side on a
    # `phx-update="ignore"` node), so a LiveView test cannot literally
    # press the button and diff a re-render. What it CAN prove statically
    # is the invariant that makes the bug structurally impossible: the
    # button's class list carries a FIXED width/height utility, and NO
    # utility anywhere in that same list is conditioned on `pressed` or
    # `rejected` and touches width or height — across every state this
    # component renders a control in (idle, disabled, held-by-other).
    test "the Ask button carries a fixed width/height class with no pressed- or rejected-conditional sizing" do
      idle_html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      disabled_html = hold_rail([agent_with_unresolved_id("Ghost")], hold_to_talk?: true)

      held_by_other_html =
        hold_rail([agent("Octavius", "oct-1")],
          hold_to_talk?: true,
          pressed_agent_id: "someone-else",
          ask_floor_holders: %{"oct-1" => "Dalton"}
        )

      for html <- [idle_html, disabled_html, held_by_other_html] do
        [control] = hold_controls(html)
        [classes] = Floki.attribute(control, "class")
        class_list = String.split(classes, " ")

        assert "w-[88px]" in class_list
        assert "h-11" in class_list

        refute Enum.any?(class_list, fn class ->
                 (class =~ "pressed" or class =~ "rejected") and
                   (class =~ ~r/:w-/ or class =~ ~r/:h-/)
               end)
      end
    end

    test "the Ask button's frame is identical (same width/height classes) across idle, disabled, and held-by-other" do
      idle_html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      disabled_html = hold_rail([agent_with_unresolved_id("Ghost")], hold_to_talk?: true)

      held_by_other_html =
        hold_rail([agent("Octavius", "oct-1")],
          hold_to_talk?: true,
          pressed_agent_id: "someone-else",
          ask_floor_holders: %{"oct-1" => "Dalton"}
        )

      frame_classes =
        for html <- [idle_html, disabled_html, held_by_other_html] do
          [control] = hold_controls(html)
          [classes] = Floki.attribute(control, "class")

          classes
          |> String.split(" ")
          |> Enum.filter(&(&1 == "w-[88px]" or &1 == "h-11" or &1 == "overflow-hidden"))
          |> Enum.sort()
        end

      assert Enum.uniq(frame_classes) == [["h-11", "overflow-hidden", "w-[88px]"]]
    end

    # ── Item 3b (task 01a0f324 stage 3): the held row clears the veil ──────
    #
    # The veil is `fixed inset-0 z-50` and dims everything under it; the
    # button being held carried no z-index at all, so the veil painted
    # over the exact control the presser's finger was on. `z-[60]` only
    # takes effect on a POSITIONED box, so `relative` has to travel with
    # it or the z-index is a no-op — this checks both together.
    #
    # Item 1 (task 01a0f842 stage 1, canvas 01a0f846-cfb1) removed the
    # row's OWN ring: "one ring only, on the key under the finger." See
    # `hold_control_class_list/1`'s own test below for the ring that
    # replaced it, on the Ask key itself.
    defp agent_row(html) do
      [row] = Floki.parse_fragment!(html) |> Floki.find(~s(li[data-participant-type="agent"]))
      row
    end

    test "an agent row is positioned and carries a pressed-state z-index above the veil's z-50, with no ring of its own" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      row = agent_row(html)

      assert Floki.attribute(row, "data-pressed") == ["false"]

      [classes] = Floki.attribute(row, "class")
      class_list = String.split(classes, " ")

      assert "relative" in class_list
      assert "data-[pressed=true]:z-[60]" in class_list
      refute "data-[pressed=true]:ring-2" in class_list
      refute "data-[pressed=true]:ring-base-content" in class_list
    end

    test "a row with no hold-to-talk control carries no pressed-state z-index class" do
      html = hold_rail([agent("Octavius", "oct-1")], [])
      row = agent_row(html)

      [classes] = Floki.attribute(row, "class")
      refute classes =~ "z-[60]"
    end

    # ── Item 4 (task 01a0f324 stage 3): the feedback line never truncates ──
    #
    # The old surface was a floating tooltip, `max-w-56` + no wrapping
    # guarantee, which clipped copy longer than the early-release nudge
    # ("Couldn't hear you. Check that your microphone is on, then hold
    # Ask." and "Burrow went offline. It will rejoin when it reconnects."
    # both overflow 56 Tailwind units of width). The replacement is a
    # plain block under the row: no `fixed`, no `max-w-*`, no `truncate`,
    # `break-words` so long copy wraps instead of clipping. The sentence
    # itself stays `text-base-content` — the colour signal is only on the
    # icon and the left rule (`data-tone`), never on the text run.
    defp hold_feedback(html) do
      [feedback] =
        Floki.parse_fragment!(html) |> Floki.find(~s([data-role="meeting-agent-hold-feedback"]))

      feedback
    end

    test "the feedback line carries no truncate or max-w clamp, wraps, and starts hidden" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      feedback = hold_feedback(html)

      [classes] = Floki.attribute(feedback, "class")
      class_list = String.split(classes, " ")

      refute "truncate" in class_list
      refute Enum.any?(class_list, &(&1 =~ ~r/^max-w-/))
      assert "w-full" in class_list
      assert "text-base-content" in class_list
      assert Floki.attribute(feedback, "data-open") == ["false"]

      text_node =
        Floki.find(feedback, ~s([data-role="meeting-agent-hold-feedback-text"]))

      assert [text_classes] = Floki.attribute(text_node, "class")
      text_class_list = String.split(text_classes, " ")
      refute "truncate" in text_class_list
      refute Enum.any?(text_class_list, &(&1 =~ ~r/^max-w-/))
      assert "break-words" in text_class_list
      # No colour token anywhere on the text run itself — the tone lives
      # on the icon/rule only (canvas self-critique: small coloured text
      # fails the AA floor on base-200).
      refute Enum.any?(text_class_list, &(&1 =~ ~r/text-(error|warning|success|info)\b/))
    end

    test "the feedback line is absent when the row has no hold-to-talk control" do
      html = hold_rail([agent("Octavius", "oct-1")], [])

      assert Floki.parse_fragment!(html)
             |> Floki.find(~s([data-role="meeting-agent-hold-feedback"])) ==
               []
    end
  end

  # Task 01a0fa7e-afd7 (design canvas 01a0fa80-da74, "Burrow round 3:
  # floating heard text and hittable rail"). Round 2's dashed "HEARD box"
  # (canvas 01a0e47d-3005) is RETIRED as a heard-text holder: it grew
  # with every transcript word, and because it sat inside the CENTRED
  # veil card, that growth visibly reflowed the whole stage — the exact
  # defect Harper's round-3 report named. The live text now lives in its
  # own fixed-size, absolutely-positioned overlay, never a sibling in the
  # veil card's layout flow.
  describe "the ask-veil's card, post round-3" do
    test "no longer hosts a heard box, step label, or transcript node" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      parsed = Floki.parse_fragment!(html)

      assert Floki.find(parsed, ~s([data-role="meeting-ask-heard-box"])) == []
      assert Floki.find(parsed, ~s([data-role="meeting-ask-step"])) == []
      assert Floki.find(parsed, ~s([data-role="meeting-ask-transcript"])) == []
    end

    test "still carries the label and the live mic-level meter directly" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      parsed = Floki.parse_fragment!(html)

      assert Floki.find(parsed, ~s([data-role="meeting-ask-label"])) != []
      assert Floki.find(parsed, ~s([data-role="meeting-ask-meter"])) != []
    end
  end

  # The floating heard overlay itself — the new holder for the live
  # transcript text, out of everyone's layout flow.
  describe "the floating heard overlay" do
    test "is absent when the row has no hold-to-talk producer, present when it does" do
      without = hold_rail([agent("Octavius", "oct-1")], [])

      assert Floki.parse_fragment!(without)
             |> Floki.find(~s([data-role="meeting-ask-heard-overlay"])) == []

      with_hold = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)

      [overlay] =
        Floki.parse_fragment!(with_hold)
        |> Floki.find(~s([data-role="meeting-ask-heard-overlay"]))

      [classes] = Floki.attribute(overlay, "class")
      class_list = String.split(classes, " ")

      # Out of flow, always: `fixed`, never a static/relative box that
      # could push a sibling.
      assert "fixed" in class_list
      # Read-only, per the canvas ("pointer-events none on the whole
      # overlay"): on the container itself, not just inherited.
      assert "pointer-events-none" in class_list
      assert Floki.attribute(overlay, "data-open") == ["false"]
      assert Floki.attribute(overlay, "phx-update") == ["ignore"]
      assert Floki.attribute(overlay, "aria-hidden") == ["true"]
    end

    test "carries the fixed-size status line and the ~7-line, scrollable text window (round 4)" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      parsed = Floki.parse_fragment!(html)

      [overlay] = Floki.find(parsed, ~s([data-role="meeting-ask-heard-overlay"]))

      [status] = Floki.find([overlay], ~s([data-role="meeting-ask-heard-status"]))
      assert Floki.text(status) |> String.trim() == "Listening while you hold"

      # Round 4 (canvas 01a0fdf2-804d): grows up to ~7 lines (168px at the
      # 24px/line `leading-6` below), THEN scrolls — `overflow-y-auto`,
      # not the old hard `h-[72px]`/`overflow-hidden` pair, so the viewer
      # can scroll back up inside it while still holding (the hook owns
      # the actual scroll-position management; see its moduledoc).
      [window] = Floki.find([overlay], ~s([data-role="meeting-ask-heard-window"]))
      [window_classes] = Floki.attribute(window, "class")
      window_class_list = String.split(window_classes, " ")
      assert "max-h-[168px]" in window_class_list
      assert "overflow-y-auto" in window_class_list
      refute "overflow-hidden" in window_class_list

      [text_node] = Floki.find([window], ~s([data-role="meeting-ask-heard-text"]))
      assert Floki.text(text_node) |> String.trim() == ""
    end

    test "is a SIBLING of the veil, never nested inside its card — so it can never be pushed by the card's own content" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      parsed = Floki.parse_fragment!(html)

      [veil] = Floki.find(parsed, ~s([data-role="meeting-ask-veil"]))
      assert Floki.find([veil], ~s([data-role="meeting-ask-heard-overlay"])) == []
    end
  end

  # ── Remove from meeting (task 01a0e906 stage 3) ──────────────────────────
  #
  # Saru's canvas 01a0e99d-2af5: one neutral, always-visible icon button per
  # AGENT row for the host, none on any human row (the host's included).
  # Every "zero buttons" assertion below sits next to a rendered human row or
  # a rendered agent row, so an empty find cannot pass on an empty rail.

  defp remove_rail(participants, opts) do
    render_component(
      &ParticipantRail.participant_rail/1,
      [
        participants: participants,
        agents_by_id: %{},
        meeting: %{id: "m-1", host_participant_id: "u-1"}
      ] ++ opts
    )
  end

  # Round 4 (canvas 01a0fdf2-804d): the bare "Remove from meeting" button
  # is now the Kick ✕ that OPENS an inline confirm rather than removing
  # directly — `remove_buttons/1` keeps its name (every existing presence/
  # gating assertion below still holds unchanged against it) but now finds
  # `meeting-agent-kick`.
  defp remove_buttons(nodes), do: Floki.find(nodes, ~s([data-role="meeting-agent-kick"]))

  defp kick_confirms(nodes), do: Floki.find(nodes, ~s([data-role="meeting-agent-kick-confirm"]))

  defp kick_remove_buttons(nodes),
    do: Floki.find(nodes, ~s([data-role="meeting-agent-kick-remove"]))

  defp remove_roster do
    [
      human("Marlowe", "u-1"),
      human("Rowan", "u-2"),
      agent("Burrow", "ma-1"),
      agent("Saru", "saru-1")
    ]
  end

  describe "remove-from-meeting button" do
    test "renders exactly one per agent row and none in the humans section" do
      html = remove_rail(remove_roster(), can_remove_agents?: true)
      doc = Floki.parse_fragment!(html)

      agent_rows = Floki.find(doc, ~s(li[data-participant-type="agent"]))
      human_rows = Floki.find(doc, ~s(li[data-participant-type="user"]))

      # Positive controls: both sections actually rendered their rows,
      # including the host's own.
      assert length(agent_rows) == 2
      assert length(human_rows) == 2
      assert Floki.find(doc, ~s([data-role="host-badge"])) != []

      for row <- agent_rows do
        assert length(remove_buttons([row])) == 1
      end

      assert remove_buttons(human_rows) == []
      assert remove_buttons(Floki.find(doc, ~s(section[data-section="humans"]))) == []
      assert length(remove_buttons(doc)) == 2
    end

    test "is wired to open the inline confirm, named for the agent, neutral at rest" do
      html = remove_rail([agent("Burrow", "ma-1")], can_remove_agents?: true)
      [button] = html |> Floki.parse_fragment!() |> remove_buttons()

      assert Floki.attribute(button, "type") == ["button"]
      # Round 4: the ✕ opens the inline confirm — it never calls
      # `remove_agent_from_call` itself. That only ever fires from the
      # confirm's own "Remove" choice, asserted below.
      assert Floki.attribute(button, "phx-click") == ["kick_confirm_open"]
      # The meeting_participants ROW id (`p.id`), not the agent id.
      assert Floki.attribute(button, "phx-value-participant-id") == ["p-ma-1"]

      assert Floki.attribute(button, "aria-label") == [
               "Remove Burrow from the meeting"
             ]

      assert Floki.attribute(button, "title") == ["Remove from meeting"]
      assert Floki.attribute(button, "disabled") == []

      [class] = Floki.attribute(button, "class")
      assert class =~ "btn-ghost"
      assert class =~ "text-base-content/60"
      assert class =~ "max-sm:min-h-11"
      assert class =~ "max-sm:min-w-11"
      # Always visible, and neutral AT REST — the error tint is now a
      # deliberate HOVER/FOCUS-only cue (canvas 01a0fdf2-804d's own
      # mockup CSS: ".kick:hover{color:var(--bad)...}"), not a rest-state
      # colour, so the broad round-3 "neutral" ruling narrows to "neutral
      # at rest" rather than disappearing. Checked by SPLITTING the class
      # list rather than a substring match: `"text-error"` is itself a
      # substring of `"hover:text-error"`, so `=~` cannot tell "present at
      # rest" apart from "present only behind a variant prefix".
      class_list = String.split(class, " ")
      refute "bg-error" in class_list
      refute "text-error" in class_list
      assert "hover:text-error" in class_list
      assert "focus-visible:text-error" in class_list
      refute class =~ "opacity-0"
      refute class =~ "group-hover"

      assert Floki.find(button, ".hero-x-mark") != []
    end

    test "the confirm opens for the matching row, with Cancel and Remove wired to the existing handlers" do
      html =
        remove_rail([agent("Burrow", "ma-1"), agent("Saru", "saru-1")],
          can_remove_agents?: true,
          kick_confirm_id: "p-ma-1"
        )

      doc = Floki.parse_fragment!(html)
      burrow_row = Floki.find(doc, ~s(li[data-participant-id="p-ma-1"]))
      saru_row = Floki.find(doc, ~s(li[data-participant-id="p-saru-1"]))

      # The ✕ is replaced by the confirm on ITS OWN row only.
      assert remove_buttons(burrow_row) == []
      [confirm] = kick_confirms(burrow_row)
      assert Floki.text(confirm) =~ "Remove Burrow?"

      [cancel] = Floki.find(confirm, ~s([data-role="meeting-agent-kick-cancel"]))
      assert Floki.attribute(cancel, "phx-click") == ["kick_confirm_close"]

      # The ONE call that ever actually removes anyone — same event, same
      # row id, `can_remove_agents?`'s original bare button always posted
      # to. No second, parallel removal path exists.
      [confirm_remove] = kick_remove_buttons(confirm)
      assert Floki.attribute(confirm_remove, "phx-click") == ["remove_agent_from_call"]
      assert Floki.attribute(confirm_remove, "phx-value-participant-id") == ["p-ma-1"]

      # The other row is untouched: still its ✕, no confirm.
      assert kick_confirms(saru_row) == []
      assert length(remove_buttons(saru_row)) == 1
    end

    test "renders '<name> left the call' with Undo wired to undo_remove_agent, only when set" do
      html =
        remove_rail(remove_roster(),
          can_remove_agents?: true,
          agent_removal_undo: %{
            agent_id: "burrow-agent-id",
            agent_name: "Burrow",
            ref: make_ref()
          }
        )

      doc = Floki.parse_fragment!(html)
      [gone] = Floki.find(doc, ~s([data-role="meeting-agent-left"]))
      assert Floki.text(gone) =~ "Burrow left the call"

      [undo] = Floki.find(gone, ~s([data-role="meeting-agent-left-undo"]))
      assert Floki.attribute(undo, "phx-click") == ["undo_remove_agent"]
    end

    test "renders nothing when there is no removal to undo" do
      html = remove_rail(remove_roster(), can_remove_agents?: true, agent_removal_undo: nil)
      doc = Floki.parse_fragment!(html)

      assert Floki.find(doc, ~s([data-role="meeting-agent-left"])) == []
    end

    test "is absent by default, with the agent row still rendered" do
      html = remove_rail(remove_roster(), [])
      doc = Floki.parse_fragment!(html)

      assert length(Floki.find(doc, ~s(li[data-participant-type="agent"]))) == 2
      assert remove_buttons(doc) == []
    end

    test "a row in removing_ids reads Leaving… with its button disabled; the others do not" do
      html =
        remove_rail(remove_roster(),
          can_remove_agents?: true,
          removing_ids: MapSet.new(["p-ma-1"])
        )

      doc = Floki.parse_fragment!(html)
      leaving_row = Floki.find(doc, ~s(li[data-participant-id="p-ma-1"]))
      other_row = Floki.find(doc, ~s(li[data-participant-id="p-saru-1"]))

      [word] = Floki.find(leaving_row, ~s([data-role="meeting-agent-leaving"]))
      assert Floki.text(word) |> String.trim() == "Leaving…"
      assert Floki.attribute(word, "class") |> hd() =~ "text-base-content/60"
      assert Floki.find(leaving_row, ~s([data-role="agent-activity-primary"])) == []

      [button] = remove_buttons(leaving_row)
      assert Floki.attribute(button, "disabled") != []

      assert Floki.find(other_row, ~s([data-role="meeting-agent-leaving"])) == []
      assert Floki.find(other_row, ~s([data-role="agent-activity-primary"])) != []
      [other_button] = remove_buttons(other_row)
      assert Floki.attribute(other_button, "disabled") == []
    end

    test "a row in removal_errors shows the shared feedback line with a Try again retry" do
      html =
        remove_rail(remove_roster(),
          can_remove_agents?: true,
          removal_errors: %{"p-ma-1" => "Couldn't remove Burrow."}
        )

      doc = Floki.parse_fragment!(html)
      failed_row = Floki.find(doc, ~s(li[data-participant-id="p-ma-1"]))

      [line] = Floki.find(failed_row, ~s([data-role="meeting-agent-remove-error"]))
      [class] = Floki.attribute(line, "class")
      # Task 01a0f842 stage 5, canvas 01a0f846-cfb1: small red TEXT fails
      # the 4.5:1 AA floor on this rail's light theme, so the colour
      # signal now lives only on the rule and the icon — the sentence
      # itself is `text-base-content`, never `text-error`.
      assert class =~ "border-error"
      refute class =~ "text-error"
      assert class =~ "text-base-content"
      assert Floki.text(line) =~ "Couldn't remove Burrow."

      [retry] = Floki.find(failed_row, ~s([data-role="meeting-agent-remove-retry"]))
      assert Floki.text(retry) |> String.trim() == "Try again"
      assert Floki.attribute(retry, "phx-click") == ["remove_agent_from_call"]
      assert Floki.attribute(retry, "phx-value-participant-id") == ["p-ma-1"]

      [button] = remove_buttons(failed_row)
      assert Floki.attribute(button, "disabled") == []

      # Only that row.
      assert length(Floki.find(doc, ~s([data-role="meeting-agent-remove-error"]))) == 1
    end
  end

  # ── Mute an agent (task 01a0f842 stage 5, canvas 01a0f846-cfb1) ──────────
  #
  # NET-NEW: no agent mute control exists anywhere on main before this
  # stage. Same host gate (`can_remove_agents?`) the remove button above
  # uses, reusing `remove_rail/2` and `remove_roster/0` verbatim.

  defp mute_buttons(nodes), do: Floki.find(nodes, ~s([data-role="meeting-agent-mute"]))

  describe "mute-agent button" do
    test "renders for the host, one per agent row, idle/unmuted by default" do
      html = remove_rail(remove_roster(), can_remove_agents?: true)
      doc = Floki.parse_fragment!(html)

      agent_rows = Floki.find(doc, ~s(li[data-participant-type="agent"]))
      human_rows = Floki.find(doc, ~s(li[data-participant-type="user"]))

      for row <- agent_rows do
        assert length(mute_buttons([row])) == 1
      end

      # Never on a human row — the host's own included.
      assert mute_buttons(human_rows) == []

      [button] = mute_buttons(Floki.find(doc, ~s(li[data-participant-id="p-ma-1"])))
      assert Floki.attribute(button, "type") == ["button"]
      assert Floki.attribute(button, "phx-click") == ["toggle_agent_mute"]
      assert Floki.attribute(button, "phx-value-participant-id") == ["p-ma-1"]
      assert Floki.attribute(button, "data-mute-state") == ["unmuted"]
      assert Floki.attribute(button, "aria-pressed") == ["false"]
      assert Floki.attribute(button, "aria-label") == ["Mute Burrow"]
      assert Floki.attribute(button, "disabled") == []

      assert Floki.find(button, ".hero-microphone") != []
      assert Floki.find(button, ".hero-microphone-slash") == []
    end

    test "is absent for a non-host; the row keeps its read-only mic glyph" do
      html = remove_rail(remove_roster(), [])
      doc = Floki.parse_fragment!(html)

      agent_row = Floki.find(doc, ~s(li[data-participant-id="p-ma-1"]))
      assert mute_buttons(agent_row) == []
      assert Floki.find(agent_row, ~s([data-role="mic-indicator"])) != []
    end

    test "a row with a true target in muting_ids reads Muting… with a disabled, spinning button" do
      html =
        remove_rail(remove_roster(),
          can_remove_agents?: true,
          muting_ids: %{"p-ma-1" => true}
        )

      doc = Floki.parse_fragment!(html)
      row = Floki.find(doc, ~s(li[data-participant-id="p-ma-1"]))

      [word] = Floki.find(row, ~s([data-role="meeting-agent-muting"]))
      assert Floki.text(word) |> String.trim() == "Muting…"

      [button] = mute_buttons(row)
      assert Floki.attribute(button, "disabled") != []
      assert Floki.attribute(button, "data-mute-state") == ["muting"]
      assert Floki.attribute(button, "aria-label") == ["Muting Burrow…"]
      assert Floki.find(button, ~s(.loading-spinner)) != []
    end

    test "a row with a false target in muting_ids reads Unmuting…" do
      html =
        remove_rail(remove_roster(),
          can_remove_agents?: true,
          muting_ids: %{"p-ma-1" => false}
        )

      doc = Floki.parse_fragment!(html)
      row = Floki.find(doc, ~s(li[data-participant-id="p-ma-1"]))

      [word] = Floki.find(row, ~s([data-role="meeting-agent-muting"]))
      assert Floki.text(word) |> String.trim() == "Unmuting…"

      [button] = mute_buttons(row)
      assert Floki.attribute(button, "data-mute-state") == ["unmuting"]
      assert Floki.attribute(button, "aria-label") == ["Unmuting Burrow…"]
    end

    test "a row in muted_agent_ids reads Muted with aria-pressed true and a slashed, uncoloured glyph" do
      html =
        remove_rail(remove_roster(),
          can_remove_agents?: true,
          muted_agent_ids: MapSet.new(["p-ma-1"])
        )

      doc = Floki.parse_fragment!(html)
      row = Floki.find(doc, ~s(li[data-participant-id="p-ma-1"]))

      [word] = Floki.find(row, ~s([data-role="meeting-agent-muted"]))
      assert Floki.text(word) |> String.trim() == "Muted"
      assert Floki.find(row, ~s([data-role="agent-activity-primary"])) == []

      [button] = mute_buttons(row)
      assert Floki.attribute(button, "data-mute-state") == ["muted"]
      assert Floki.attribute(button, "aria-pressed") == ["true"]
      assert Floki.attribute(button, "aria-label") == ["Unmute Burrow"]
      assert Floki.attribute(button, "disabled") == []

      [glyph] = Floki.find(button, ".hero-microphone-slash")
      [class] = Floki.attribute(glyph, "class")
      # "No colour: muted is a setting, not an error" (canvas states table).
      refute class =~ "error"
      assert class =~ "text-base-content"
      refute class =~ "text-base-content/60"
    end

    test "a row in mute_errors shows the shared feedback line and reverts the button to unmuted" do
      html =
        remove_rail(remove_roster(),
          can_remove_agents?: true,
          mute_errors: %{"p-ma-1" => "Couldn't mute Burrow."}
        )

      doc = Floki.parse_fragment!(html)
      row = Floki.find(doc, ~s(li[data-participant-id="p-ma-1"]))

      [line] = Floki.find(row, ~s([data-role="meeting-agent-mute-error"]))
      [class] = Floki.attribute(line, "class")
      assert class =~ "border-error"
      refute class =~ "text-error"
      assert class =~ "text-base-content"
      assert Floki.text(line) =~ "Couldn't mute Burrow."

      [retry] = Floki.find(row, ~s([data-role="meeting-agent-mute-retry"]))
      assert Floki.text(retry) |> String.trim() == "Try again"
      assert Floki.attribute(retry, "phx-click") == ["toggle_agent_mute"]
      assert Floki.attribute(retry, "phx-value-participant-id") == ["p-ma-1"]

      # Reverted: same idle/unmuted look the default-state test asserts.
      [button] = mute_buttons(row)
      assert Floki.attribute(button, "data-mute-state") == ["unmuted"]
      assert Floki.attribute(button, "disabled") == []

      # Only that row.
      assert length(Floki.find(doc, ~s([data-role="meeting-agent-mute-error"]))) == 1
    end
  end

  # ── Ask Burrow to leave (task 01a0f31d stage 4) ──────────────────────────
  #
  # A second, more discoverable entry point into the SAME remove-agent
  # action the tests above already cover (same event, same handler). Visible
  # only for the host, and only when exactly one agent is active — the
  # ambiguous 0/2+ cases hide the control outright rather than building a
  # picker, leaving the per-row icons (asserted above) as the only removal
  # path in that case.

  defp leave_control(nodes), do: Floki.find(nodes, ~s([data-role="meeting-ask-agent-leave"]))

  describe "Ask Burrow to leave (lower-left control)" do
    test "renders for the host with exactly one active agent" do
      html =
        remove_rail(
          [human("Marlowe", "u-1"), agent("Burrow", "ma-1")],
          can_remove_agents?: true
        )

      doc = Floki.parse_fragment!(html)
      [button] = leave_control(doc)

      assert Floki.text(button) |> String.trim() == "Ask Burrow to leave"
      assert Floki.attribute(button, "type") == ["button"]
      assert Floki.attribute(button, "phx-click") == ["remove_agent_from_call"]
      assert Floki.attribute(button, "phx-value-participant-id") == ["p-ma-1"]
      assert Floki.attribute(button, "disabled") == []

      [class] = Floki.attribute(button, "class")
      refute class =~ "error"
      refute class =~ "btn-error"
      refute html =~ "Kick"

      # Joins the per-row icon rather than replacing it.
      assert length(remove_buttons(doc)) == 1
    end

    test "is absent for a non-host, even with exactly one active agent" do
      html = remove_rail([human("Marlowe", "u-1"), agent("Burrow", "ma-1")], [])
      doc = Floki.parse_fragment!(html)

      assert leave_control(doc) == []
      # Positive control: the agent row itself rendered.
      assert length(Floki.find(doc, ~s(li[data-participant-type="agent"]))) == 1
    end

    test "is absent with zero active agents" do
      html = remove_rail([human("Marlowe", "u-1")], can_remove_agents?: true)
      doc = Floki.parse_fragment!(html)

      assert leave_control(doc) == []
    end

    test "is absent with two-or-more active agents, and the per-row icons remain" do
      html =
        remove_rail(
          [human("Marlowe", "u-1"), agent("Burrow", "ma-1"), agent("Saru", "saru-1")],
          can_remove_agents?: true
        )

      doc = Floki.parse_fragment!(html)

      assert leave_control(doc) == []
      assert length(remove_buttons(doc)) == 2
    end

    test "disables while the single agent's removal is in flight" do
      html =
        remove_rail(
          [human("Marlowe", "u-1"), agent("Burrow", "ma-1")],
          can_remove_agents?: true,
          removing_ids: MapSet.new(["p-ma-1"])
        )

      doc = Floki.parse_fragment!(html)
      [button] = leave_control(doc)
      assert Floki.attribute(button, "disabled") != []
    end
  end

  describe "section order (task 01a0f31d stage 2: Agents above People)" do
    # Per the approved design canvas ("Burrow meeting controls: design
    # direction", 01a0f31f-46e8), the Agents section must render FIRST,
    # above the humans section, on both surfaces `participant_rail/1`
    # backs (the desktop left rail and the phone People tab via
    # `CallShell.call_rail/1` — both call this same component, so a
    # template-level reorder covers both without a second fix).
    #
    # Asserted on BYTE OFFSET of the two `<section data-section="...">`
    # tags rather than on `MeetingLive.partition_participants/1`'s
    # returned tuple order, which stays `{humans, agents}` and is out of
    # scope for this stage (other callers — the "N people · M agents" bar
    # text — depend on that order).
    test "the Agents section's DOM node precedes the Humans section's DOM node" do
      html = rail([human("Harper", "u-1"), agent("Saru", "a-1")])

      agents_index =
        case :binary.match(html, ~s(data-section="agents")) do
          {index, _len} -> index
          :nomatch -> flunk("no <section data-section=\"agents\"> in the rendered rail")
        end

      humans_index =
        case :binary.match(html, ~s(data-section="humans")) do
          {index, _len} -> index
          :nomatch -> flunk("no <section data-section=\"humans\"> in the rendered rail")
        end

      assert agents_index < humans_index,
             "expected the Agents section to render before the Humans section, " <>
               "but Agents was at byte #{agents_index} and Humans at byte #{humans_index}"
    end

    test "still holds when many humans and many agents are present" do
      html =
        rail([
          human("Harper", "u-1"),
          human("Priya", "u-2"),
          agent("Saru", "a-1"),
          agent("Burrow", "a-2")
        ])

      {agents_index, _} = :binary.match(html, ~s(data-section="agents"))
      {humans_index, _} = :binary.match(html, ~s(data-section="humans"))

      assert agents_index < humans_index
    end

    # Task 01a0f31d's e2e review (case 3): Burrow's resolved name must
    # reach the row as plain text, a nameless/orphaned agent row must
    # fall back to the literal word "Agent" (never blank, never the old
    # "Unknown participant" copy, never a crash), and both must sit
    # inside the Agents section, which still renders above Humans.
    test "Burrow's name renders, a nameless agent falls back to 'Agent', and both sit above Humans" do
      html =
        rail([
          human("Harper", "u-1"),
          agent("Burrow", "a-1"),
          agent(nil, "a-2")
        ])

      name_text = fn row_html ->
        row_html
        |> Floki.parse_fragment!()
        |> Floki.find(~s([data-role="participant-name"]))
        |> Floki.text()
        |> String.trim()
      end

      assert agent_row(html, "a-1") |> name_text.() == "Burrow"

      nameless_name = agent_row(html, "a-2") |> name_text.()
      assert nameless_name == "Agent"
      refute nameless_name == ""
      refute nameless_name =~ "Unknown participant"

      {agents_index, _} = :binary.match(html, ~s(data-section="agents"))
      {humans_index, _} = :binary.match(html, ~s(data-section="humans"))
      assert agents_index < humans_index
    end
  end
end
