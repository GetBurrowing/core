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
      # FE-19 (01a07486-7985-7001-87ce-277681791f52): `hero-microphone-slash`
      # generates NO CSS — Heroicons ships no `microphone-slash.svg`, and
      # `assets/vendor/heroicons.js` emits one class per file it finds. The
      # class is in the markup and this assertion would pass on a blank
      # circle, so the two channels that DO reach a viewer today are
      # asserted alongside it: the red well and the words.
      row = row_for(media_rail([human("Mariah", "u-1")], muted: ["user:u-1"]), "user:u-1")
      mic = slot(row, "mic-indicator")

      assert attr(mic, "class") =~ "bg-error/15"
      assert attr(mic, "aria-label") == "Microphone muted"
      assert row =~ "hero-microphone-slash"
      assert row =~ "Mariah, muted, camera on"
    end

    test "the camera's slashed glyph is real, unlike the mic's" do
      # `video-camera-slash.svg` DOES ship, in all four Heroicons sizes,
      # so the camera-off state gets all three channels for real. Asserted
      # separately from the mic so the two are not assumed to share a fate.
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
end
