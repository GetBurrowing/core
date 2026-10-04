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
  element, for both headings (the Agents one is now the Ask mockup's
  `.sec`). They were shown to detonate by deleting the humans heading
  `<div>` from `participant_rail.ex`.
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

  # The Agents section's stylesheet and the mockup it ports verbatim.
  defp ask_css, do: File.read!(Path.join([File.cwd!(), "assets", "css", "meeting_ask.css"]))

  defp ask_mockup,
    do:
      File.read!(
        Path.join([File.cwd!(), "test", "support", "fixtures", "meeting_ask_mockup.html"])
      )

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

    # Both sections are labelled. The humans heading keeps its utility
    # type; the Agents heading is the mockup's `.sec` (12px uppercase from
    # `meeting_ask.css`), so the two are no longer one class string.
    test "both sections carry a heading: humans in utility type, agents as the mockup's .sec" do
      html = rail([human("Harper", "u-1"), agent("Saru", "a-1")])
      doc = Floki.parse_fragment!(html)

      assert length(Regex.scan(~r/#{Regex.escape(@heading_type)}/, html)) == 1

      [sec] = Floki.find(doc, ~s(section[data-section="agents"] > div.sec))
      assert Floki.text(sec) |> String.trim() == "Agents"
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
    # The defect this closed: line 2 under the name was the role chip
    # rendering the literal string "agent", and `:idle` rendered nothing
    # but a bare dot. The verbatim port of the Ask mockup
    # (`test/support/fixtures/meeting_ask_mockup.html`) keeps the three
    # signals as: the `.av` initial circle (carrying `data-activity-state`
    # and the `.avs` reachability badge), the name, and the state word in
    # `.st .i`. The old ring/corner glyph around the face is gone ON
    # PURPOSE — the mockup draws neither.
    #
    # Every assertion below renders all four states in ONE rail and
    # checks per-row, so a guard cannot pass on another row's markup.
    test "the avatar is the mockup's initial circle, carrying the state as data, with no ring or glyph" do
      html = four_state_rail()

      for {id, state} <- @four_states do
        row = Floki.parse_fragment!(agent_row(html, id))

        [av] = Floki.find(row, ~s(div.av[data-role="agent-activity-avatar"]))

        assert Floki.attribute(av, "data-activity-state") == [to_string(state)]

        # One uppercase initial, drawn as the circle's text (aria-hidden:
        # the activity sentence beside it is what a screen reader hears).
        assert av |> Floki.find(~s(span[aria-hidden="true"])) |> Floki.text() |> String.trim() =~
                 ~r/^[A-Z]$/

        for gone <-
              ~w(agent-activity-ring agent-activity-glyph agent-activity-face agent-activity-badge) do
          assert Floki.find(row, ~s([data-role="#{gone}"])) == [],
                 "#{id}: #{gone} is back in the rail row"
        end
      end
    end

    test "each state reads its own word, and the four rows are different markup" do
      html = four_state_rail()

      assert primary_word(agent_row(html, "a-think")) =~ ~r/^Thinking( · \d+s)?$/
      assert primary_word(agent_row(html, "a-write")) =~ ~r/^Writing( · \d+s)?$/
      assert primary_word(agent_row(html, "a-fail")) =~ "Couldn"
      assert primary_word(agent_row(html, "a-idle")) == "Idle"

      rows = for {id, _} <- @four_states, do: agent_row(html, id)
      assert length(Enum.uniq(rows)) == 4
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
      parsed = Floki.parse_fragment!(row)

      assert primary_word(row) == "Idle"
      assert Floki.find(parsed, ~s(.who > .nm[data-role="participant-name"])) != []
      assert Floki.find(parsed, ~s(div.av[data-role="agent-activity-avatar"])) != []
    end

    # The word's colour now comes from the mockup's `.st{color:var(--m)}`
    # (asserted in the stylesheet guard below), so the node carries no
    # Tailwind colour of its own that could drift from it.
    test "the state line is the mockup's .st, with no utility colour of its own" do
      row = agent_row(four_state_rail(), "a-idle")

      [word_node] =
        row
        |> Floki.parse_fragment!()
        |> Floki.find(~s([data-role="agent-activity-word"]))

      assert Floki.attribute(word_node, "class") == ["st"]
    end

    # A DIFFERENT fact from the activity: is this agent connected. It is
    # now the mockup-coloured `.avs` badge on the avatar's corner.
    test "the reachability dot survives, on every state and not only idle" do
      html = four_state_rail()

      for {id, _} <- @four_states do
        [dot] =
          html
          |> agent_row(id)
          |> Floki.parse_fragment!()
          |> Floki.find(~s(.av > span.avs[data-role="agent-status-dot"]))

        assert Floki.attribute(dot, "data-tone") in [["ok"], ["m"]],
               "#{id}: the reachability badge has no tone"
      end
    end

    # The one state with no producer. Nothing in the system can set
    # `:listening`, so drawing it as a STATE would put a caption on screen
    # that is always false. The mockup's `.st .l` "Listening…" is not a
    # state: it is the held-row crossfade (opacity 0 until
    # `.row[data-held="true"]`), so the guard reads the state half, `.i`.
    test "'Listening' is never the state word, with every real state resolved" do
      html = four_state_rail()

      state_text = fn h ->
        h |> Floki.parse_fragment!() |> Floki.find(".st .i") |> Floki.text()
      end

      assert length(Floki.find(Floki.parse_fragment!(html), ".st .i")) == 4
      refute state_text.(html) =~ "Listening"

      listening = rail([agent("Saru", "a-1")], %{"a-1" => :listening})
      refute state_text.(listening) =~ "Listening"
      assert primary_word(listening) == "Idle", "an unsettable state must present as idle"
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

      # The AVATAR carries the heard reading (as data; the mockup draws no
      # ring for it)...
      assert row =~ ~s(data-activity-state="heard")

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

    test "a live :speaking row reads Speaking, with the state on the avatar" do
      meeting_id = "m-speaking-#{System.unique_integer([:positive])}"
      {:ok, _entry} = AgentActivity.mark_speaking(meeting_id, "a-1", "utt-1")

      row =
        [agent("Talker", "a-1")]
        |> rail_for_meeting(meeting_id, now: DateTime.utc_now())
        |> agent_row("a-1")

      assert row =~ ~s(data-activity-state="speaking")
      assert primary_word(row) == "Speaking"
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

    # ── The delayed reason ──────────────────────────────────────────────
    #
    # The mockup's `.st` is ONE 17px line, so `:delayed` no longer earns a
    # second line: its reason is its own node AFTER the word inside `.st
    # .i`, and the full text also rides on `.st`'s `title`, so an
    # ellipsised line still exposes it.
    test ":delayed puts its reason in its own node after the word, and on the line's title" do
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

      # Its own node, inside the state half of the one `.st` line.
      [reason_node] = Floki.find(parsed, ~s(.st .i [data-role="agent-activity-delay-reason"]))
      assert Floki.text([reason_node]) |> String.trim() == "· waiting on GitHub"

      [st] = Floki.find(parsed, ~s([data-role="agent-activity-word"]))
      assert Floki.attribute(st, "title") == ["waiting on GitHub"]
    end

    # The row is the mockup's grid (`36px 1fr auto`, `align-items:center`)
    # in EVERY state: with one-line `.st` no state can grow the row, so
    # the old per-state `items-start`/`items-center` switch is gone and the
    # `<li>` carries no layout utilities at all.
    test "every agent row is the mockup's bare .row, delayed or not" do
      t0 = ~U[2026-01-01 00:00:00Z]
      activity = AgentActivity.put_at(AgentActivity.new(), :computing, "a-1", true, t0)

      delayed =
        [agent("Octavius", "a-1")]
        |> rail_for_meeting("m-delayed-align-#{System.unique_integer([:positive])}",
          agent_activity: activity,
          now: DateTime.add(t0, 12, :second),
          delays: %{"a-1" => Delayed.new!("waiting on GitHub")}
        )
        |> agent_row("a-1")

      for row <- [delayed, agent_row(four_state_rail(), "a-think")] do
        [opening_tag] = Regex.run(~r/<li\b[^>]*>/, row)
        assert opening_tag =~ ~s(class="row")
        refute opening_tag =~ "items-"
      end
    end

    # "The reason is the point." It can no longer wrap (one-line `.st`), so
    # what is held is that none of it is lost.
    test "a long reason survives in full, in its node and in the line's title" do
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

      # The mockup's `.st` line ellipsises (one 17px line, by design), so
      # the full reason must survive somewhere a reader can reach: the node
      # itself (screen readers read past the clip) and `.st`'s `title`.
      assert Floki.text(Floki.find(parsed, ~s([data-role="agent-activity-delay-reason"]))) =~ long

      [st] = Floki.find(parsed, ~s([data-role="agent-activity-word"]))
      assert Floki.attribute(st, "title") == [long]

      [name] = Floki.find(parsed, ~s(.who > .nm[data-role="participant-name"]))
      assert Floki.text(name) =~ "Octavius Bartholomew Winterbourne III"
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
      assert [sr_node] =
               row
               |> Floki.parse_fragment!()
               |> Floki.find(".sr-only")
               |> Enum.reject(
                 &(Floki.attribute([&1], "data-role") in [
                     ["participant-state-summary"],
                     ["mic-indicator"]
                   ])
               )

      # The verbatim port must still render this sentence (it was carried
      # by `agent_activity_avatar`'s label, which the rail no longer uses).
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

    test "both slots are present on every human row in every state; agent rows keep the mic" do
      html =
        media_rail(
          [human("Mariah", "u-1"), human("Harper", "u-2"), agent("Saru", "a-1")],
          muted: ["user:u-2"],
          camera_off: ["user:u-2"]
        )

      parsed = Floki.parse_fragment!(html)

      # An indicator that vanishes in one of its states is
      # indistinguishable from one that failed to render, which is the
      # whole reason the slots are fixed. Agent rows (the Ask mockup) have
      # no camera well by design; their mic state is the sr-only
      # indicator plus the `.avs` badge.
      assert length(Floki.find(parsed, "li[data-participant-identity]")) == 3
      assert length(Floki.find(parsed, ~s([data-role="mic-indicator"]))) == 3
      assert length(Floki.find(parsed, ~s([data-role="camera-indicator"]))) == 2

      assert Floki.find(
               parsed,
               ~s(li[data-participant-type="agent"] [data-role="camera-indicator"])
             ) == []
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

    # The agent row has no camera well (the mockup draws none), but its
    # state still never claims "camera off": the summary says "no camera".
    test "an agent's camera reads as UNAVAILABLE, not off" do
      html = media_rail([human("Mariah", "u-1"), agent("Saru", "a-1")], camera_off: ["user:u-1"])

      agent_row = row_for(html, "agent:a-1")

      assert Floki.find(Floki.parse_fragment!(agent_row), ~s([data-role="camera-indicator"])) ==
               []

      assert Floki.text(slot(agent_row, "participant-state-summary")) =~
               "Saru, unmuted, no camera"

      refute agent_row =~ "camera off"

      human_cam = slot(row_for(html, "user:u-1"), "camera-indicator")
      assert attr(human_cam, "aria-label") == "Camera off"
      assert attr(human_cam, "class") =~ "bg-error/15"
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

  defp activity_word(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(~s([data-role="agent-activity-word"]))
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

      # The mockup's key: exactly `class="ask"`, every look in
      # `meeting_ask.css` (structure asserted in its own test below).
      assert Floki.attribute(control, "class") == ["ask"]
    end

    # The mockup's Ask key, verbatim: `.ring`, four `.bars i` (animated by
    # CSS while `data-held`), and `.lbl` with `.off` "Ask" / `.on` "Listen".
    test "the Ask key carries the mockup's structure: .ring, four .bars i, .lbl .off/.on" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      [control] = hold_controls(html)

      assert length(Floki.find(control, "span.ring")) == 1
      assert length(Floki.find(control, "span.bars > i")) == 4

      [off] = Floki.find(control, ".lbl > span.off")
      [on] = Floki.find(control, ".lbl > span.on")
      assert Floki.text(off) |> String.trim() == "Ask"
      assert Floki.text(on) |> String.trim() == "Listen"
      assert Floki.attribute(on, "aria-hidden") == ["true"]

      # The retired affordances stay retired.
      assert Floki.find(control, "[data-ptt-bar]") == []
      assert Floki.find(control, ~s([data-role="meeting-agent-hold-underline"])) == []
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
    # b61e0b1e7499, "1c" in his test matrix) FIRST shipped as a reserved
    # extra flex column (an invisible sizer slot, present in every state so
    # the row's width never changed when the cue did). PR #1178's own live
    # re-check (Dalton, canvas 01a101c3-b10f) found THAT fix had its own
    # bug: the reserved column was too wide for the rail, so the row
    # OVERFLOWED permanently — a 370px row inside a 255px rail, the kick ✕
    # pushed off the edge entirely. Round 5 removes the reserved column
    # altogether, per the mockup's own structure: there never was a second
    # box to reserve. `.st` in the mockup is ONE element, the same one that
    # shows "Idle", with the pressed/held wording layered on top of it in
    # place. This test proves THAT shape — the cue and the ordinary
    # activity word share the exact same node, so there is no second
    # column for a measurement to ever find too wide again.
    #
    # Lower-confidence than a real browser measurement, same caveat as
    # before: this suite renders HEEx with no layout engine, so it proves
    # the STRUCTURAL shape the fix depends on, not a pixel count.
    test "the held/held-by cues render INSIDE the activity-word line, not as a separate slot" do
      idle_html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)

      talking_html =
        hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true, pressed_agent_id: "oct-1")

      held_by_other_html =
        hold_rail([agent("Octavius", "oct-1")],
          hold_to_talk?: true,
          pressed_agent_id: "someone-else",
          ask_floor_holders: %{"oct-1" => "Saru"}
        )

      # The old reserved-column markup is gone outright in every state —
      # not merely unused, ABSENT. A test that only checked "the cue shows
      # the right text" could pass while a second, now-pointless slot still
      # sat in the DOM claiming width.
      refute idle_html =~ "meeting-agent-status-chip-slot"
      refute talking_html =~ "meeting-agent-status-chip-slot"
      refute held_by_other_html =~ "meeting-agent-status-chip-slot"
      refute idle_html =~ "meeting-agent-status-chip-sizer"

      # Exactly ONE activity-word line per row in every state — the cue
      # replaces its content, it is never a flex SIBLING of it.
      [idle_word] = activity_word(idle_html)
      [talking_word] = activity_word(talking_html)
      [held_by_word] = activity_word(held_by_other_html)

      # The "Talking" cue (now worded "Listening…", item 4) renders INSIDE
      # that one word line, not beside it.
      assert Floki.find(talking_word, ~s([data-role="meeting-agent-talking"])) != []
      assert Floki.text(talking_word) =~ "Listening…"
      assert Floki.find(idle_word, ~s([data-role="meeting-agent-talking"])) == []

      assert Floki.find(held_by_word, ~s([data-role="meeting-agent-held-by"])) != []
      assert Floki.text(held_by_word) =~ "Held by Saru"
    end

    # Same regression — the defensive second layer. Even with the slot
    # above reserved, the name column's own `min-w-0` gave it no floor of
    # its own, which is what let it collapse to literal 0px in Dalton's
    # measurement rather than just truncating further. Asserted by class,
    # not by rendered width, for the same reason as the slot test above.
    # The row is the mockup's three-column grid (`36px 1fr auto`): the
    # avatar, the name/state column, the tools. The name column is the
    # `1fr` track, so it is the one that yields, and the tools never leave
    # the row (the grid has no wrap).
    test "the row's children are the mockup's .av, .who, .tools, in that order" do
      html =
        hold_rail([agent("Octavius", "oct-1")],
          hold_to_talk?: true,
          pressed_agent_id: "oct-1",
          can_remove_agents?: true
        )

      [row] = Floki.find(Floki.parse_fragment!(html), ~s(li.row[data-participant-type="agent"]))
      {"li", _attrs, children} = row

      grid_cells =
        for {_tag, attrs, _} <- children,
            class = :proplists.get_value("class", attrs, ""),
            class in ["av", "who", "tools"],
            do: class

      assert grid_cells == ["av", "who", "tools"]

      [who] = Floki.find(row, ".who")
      assert Floki.find(who, ~s(.nm[data-role="participant-name"])) != []
      assert Floki.find(who, ~s(.st[data-role="agent-activity-word"] > span.i)) != []
      assert Floki.find(who, ~s(.st[data-role="agent-activity-word"] > span.l)) != []
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
      assert Floki.attribute(label_node, "class") == ["off"]
    end

    # `MeetingPushToTalk` flips both client-side (`data-held` at PRESS for
    # the visual; the 380ms threshold still gates the send). The server
    # always renders them false.
    test "the control starts with data-pressed and data-held both false" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      [control] = hold_controls(html)

      assert Floki.attribute(control, "data-pressed") == ["false"]
      assert Floki.attribute(control, "data-held") == ["false"]
    end

    # Every held-state look keys off `data-held` (the mockup's `:active`),
    # never `data-pressed`: the label swap, the bars and the ring all live
    # under `.ask[data-held="true"]` in the stylesheet.
    test "the held look keys off data-held, not data-pressed" do
      css = ask_css()

      assert css =~ ~s(.meeting-ask .ask[data-held="true"] .lbl .off{opacity:0})
      assert css =~ ~s(.meeting-ask .ask[data-held="true"] .lbl .on{opacity:1})
      assert css =~ ~s(.meeting-ask .ask[data-held="true"] .bars i{animation:bar)
      assert css =~ ~s(.meeting-ask .ask[data-held="true"] .ring{animation:ring)
      refute css =~ "data-pressed"
    end

    # Disabled (the id-fallback path from stage 1): dimmed by the
    # stylesheet's `.ask:disabled`, and the "Ask" word never disappears.
    test "a disabled control keeps its label and is dimmed by the stylesheet" do
      html = hold_rail([agent_with_unresolved_id("Ghost")], hold_to_talk?: true)
      [control] = hold_controls(html)

      assert Floki.attribute(control, "disabled") == ["disabled"]

      [label_node] = Floki.find(control, ~s([data-role="meeting-agent-hold-label"]))
      assert Floki.text(label_node) |> String.trim() == "Ask"

      assert ask_css() =~ ".meeting-ask .ask:disabled{cursor:default;opacity:.5}"
    end

    # Same disabled treatment on the OTHER boundary that disables the
    # control — another viewer already holds this agent's floor — so the
    # colour rule is not accidentally coupled to the id-fallback path alone.
    test "a control held by another viewer is disabled, unpressable, and says who holds it" do
      html =
        hold_rail([agent("Octavius", "oct-1")],
          hold_to_talk?: true,
          pressed_agent_id: "someone-else",
          ask_floor_holders: %{"oct-1" => "Dalton"}
        )

      [control] = hold_controls(html)

      assert Floki.attribute(control, "disabled") == ["disabled"]

      # The wrapper (not phx-update="ignore") blocks the press; the state
      # line names who holds it.
      [wrap] = Floki.find(Floki.parse_fragment!(html), ~s([data-role="meeting-agent-hold-wrap"]))
      assert Floki.attribute(wrap, "class") |> hd() =~ "pointer-events-none"

      [held_by] =
        Floki.find(Floki.parse_fragment!(html), ~s(.st .i [data-role="meeting-agent-held-by"]))

      assert Floki.text(held_by) |> String.trim() == "Held by Dalton"
    end

    # ── Item 3a (task 01a0f324 stage 3): fixed-frame button ────────────────
    #
    # The production bug: the waveform widened the key on press and pushed
    # into neighbouring row content. The invariant that makes it impossible
    # now: the key's class list is exactly `ask` in every state the server
    # renders (so no state-conditional utility can size it), its size is
    # the mockup's fixed `width:96px;height:40px`, and no state rule in the
    # stylesheet touches width or height.
    test "the Ask key is one fixed 96x40 frame in every state" do
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
        assert Floki.attribute(control, "class") == ["ask"]
      end

      css = ask_css()
      assert css =~ ".meeting-ask .ask{position:relative;width:96px;height:40px;"

      state_rules =
        Regex.scan(~r/\.meeting-ask \.ask(?:\[data-held="true"\]|:disabled|:hover)\{[^}]*\}/, css)
        |> List.flatten()

      assert state_rules != []

      for rule <- state_rules do
        refute rule =~ ~r/(?<![-\w])(width|height):/, "a state rule resizes the key: #{rule}"
      end
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

    # Positioned by the mockup's `.row{position:relative}`, lifted by the
    # held-row rule the hook's `data-held` switches on.
    test "an agent row is positioned and its held state sits above the veil's z-50" do
      html = hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true)
      row = agent_row(html)

      assert Floki.attribute(row, "class") == ["row"]

      css = ask_css()
      assert css =~ ".meeting-ask .row{position:relative;"
      assert css =~ ~s(.meeting-ask .row[data-held="true"]{z-index:60})
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
      # `.fb` spans the row's grid; its text colour is the section's own.
      assert "fb" in class_list
      refute Enum.any?(class_list, &(&1 =~ ~r/^text-(error|warning|success|info)$/))
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

  # The floating heard overlay (`meeting-ask-heard-*`) is RETIRED: the
  # mockup's per-row `.tr.live` / `.tr.sent` popovers replace it.
  describe "the per-row transcript popovers" do
    test "are present iff the row has a hold-to-talk producer, and the old overlay is gone" do
      without = Floki.parse_fragment!(hold_rail([agent("Octavius", "oct-1")], []))
      assert Floki.find(without, ".tr") == []

      with_hold =
        Floki.parse_fragment!(
          hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true, id_prefix: "left")
        )

      [live] = Floki.find(with_hold, ~s(li.row div.tr.live[data-role="meeting-ask-live"]))
      [sent] = Floki.find(with_hold, ~s(li.row div.tr.sent[data-role="meeting-ask-sent"]))

      # The hook owns both (it writes the transcript and sizes `.vp`/`.tx`),
      # so a re-render must not wipe them; ids carry the caller's prefix.
      assert Floki.attribute(live, "phx-update") == ["ignore"]
      assert Floki.attribute(sent, "phx-update") == ["ignore"]
      assert Floki.attribute(live, "id") == ["left-oct-1-live"]
      assert Floki.attribute(sent, "id") == ["left-oct-1-sent"]

      assert Floki.find(live, ~s(.vp > .tx > p[data-role="meeting-ask-live-text"])) != []
      assert Floki.find(live, ".hd > span.dot") != []
      assert Floki.text(Floki.find(sent, ".hd")) |> String.trim() == "✓ Sent to Octavius"
      assert Floki.find(sent, ~s(.sum[data-role="meeting-ask-sent-summary"])) != []

      html = Floki.raw_html(with_hold)
      refute html =~ "meeting-ask-heard-"
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

      assert Floki.attribute(button, "title") == ["Remove Burrow from this call"]
      assert Floki.attribute(button, "disabled") == []

      # The mockup's `.kick`: always visible, neutral at rest (`--m`), the
      # `--bad` tint only on hover — both from the stylesheet, so the
      # markup carries no colour or visibility utility at all.
      assert Floki.attribute(button, "class") == ["kick"]
      assert Floki.text(button) |> String.trim() == "✕"

      css = ask_css()

      assert css =~
               ".meeting-ask .kick{width:32px;height:32px;border-radius:8px;border:1px solid var(--b);background:transparent;color:var(--m);"

      assert css =~ ".meeting-ask .kick:hover{color:var(--bad);"
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

      # `data-kick="confirm"` on ITS OWN row only — the stylesheet shows
      # `.confirm` (absolutely positioned over the row) off that attribute.
      assert Floki.attribute(burrow_row, "data-kick") == ["confirm"]
      assert Floki.attribute(saru_row, "data-kick") == ["none"]
      assert ask_css() =~ ~s(.meeting-ask .row[data-kick="confirm"] .confirm{display:flex})

      [confirm] = kick_confirms(burrow_row)
      assert Floki.attribute(confirm, "class") == ["confirm"]
      assert Floki.text(confirm) =~ "Remove Burrow?"

      [cancel] = Floki.find(confirm, ~s([data-role="meeting-agent-kick-cancel"]))
      assert Floki.attribute(cancel, "phx-click") == ["kick_confirm_close"]
      assert Floki.attribute(cancel, "class") == ["mbtn"]

      # The ONE call that ever actually removes anyone — same event, same
      # row id, `can_remove_agents?`'s original bare button always posted
      # to. No second, parallel removal path exists.
      [confirm_remove] = kick_remove_buttons(confirm)
      assert Floki.attribute(confirm_remove, "class") == ["mbtn danger"]
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

      # The mockup's gone state: its own `.row[data-kick="gone"]` in the
      # agents list, whose visible content is `.gone`.
      [gone] =
        Floki.find(
          doc,
          ~s(section[data-section="agents"] li.row[data-kick="gone"][data-role="meeting-agent-left"])
        )

      [gone_line] = Floki.find(gone, "div.gone")
      assert Floki.text(gone_line) =~ "Burrow left the call"

      [undo] = Floki.find(gone_line, ~s(button.mbtn[data-role="meeting-agent-left-undo"]))
      assert Floki.attribute(undo, "phx-click") == ["undo_remove_agent"]

      # The hidden replicas keep the row's geometry but are inert.
      for cell <- Floki.find(gone, ".av, .who, .tools") do
        assert Floki.attribute(cell, "aria-hidden") == ["true"]
      end

      assert Floki.find(gone, "[phx-click]") == [undo]
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

      [word] = Floki.find(leaving_row, ~s(.st .i [data-role="meeting-agent-leaving"]))
      assert Floki.text(word) |> String.trim() == "Leaving…"
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
      # the AA floor, so the colour signal lives only on the rule and the
      # icon — the sentence is the section's own text colour, never
      # `text-error`. `fb` spans the row's grid.
      class_list = String.split(class, " ")
      assert "fb" in class_list
      assert "border-error" in class_list
      refute "text-error" in class_list
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

  # ── Desktop LEFT rail: Ask key + kick ✕ together ──────────────────────
  #
  # Found by CDP re-check of #1181: on the desktop LEFT rail the Ask key
  # and the kick ✕ render on one row, and the old flex row pushed the ✕
  # past the rail's edge. The verbatim port puts every control in the
  # mockup's `.tools` cell (the grid's `auto` column), so the controls are
  # one unit the name column yields to. `mix test` has no layout engine;
  # this holds the markup shape, the 340px rail is checked in a browser.
  describe "the Ask key and the kick button on the same row (desktop left rail)" do
    test ".tools holds Ask, mute, then kick, in document order; status lives on the avatar" do
      html =
        remove_rail([agent("Burrow", "ma-1")],
          can_remove_agents?: true,
          hold_to_talk?: true
        )

      [row] = Floki.find(Floki.parse_fragment!(html), ~s(li[data-participant-id="p-ma-1"]))
      [tools] = Floki.find(row, "div.tools")

      roles =
        tools
        |> Floki.find("button")
        |> Enum.map(&(Floki.attribute(&1, "data-role") |> List.first()))

      assert roles == ["meeting-agent-hold-to-talk", "meeting-agent-mute", "meeting-agent-kick"]

      # The reachability badge moved from the trailing cluster onto `.av`.
      assert Floki.find(tools, ~s([data-role="agent-status-dot"])) == []
      assert Floki.find(row, ~s(.av [data-role="agent-status-dot"])) != []
      # The old flex-wrap cluster and media wells are gone from agent rows.
      assert Floki.find(row, ~s([data-role="meeting-agent-kick-wrap"])) == []
      assert Floki.find(row, ~s([data-role="media-slots"])) == []
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
      # The host mute wears the mockup's `.kick` look, in `.tools`.
      assert Floki.attribute(button, "class") == ["kick"]
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
      # The pressed colour is the mockup's `--t`, from the stylesheet.
      refute class =~ "error"
      refute class =~ "text-"
      assert ask_css() =~ ~s|.meeting-ask .kick[aria-pressed="true"]{color:var(--t)}|
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
      class_list = String.split(class, " ")
      assert "fb" in class_list
      assert "border-error" in class_list
      refute "text-error" in class_list
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

      # The mockup's quiet `.btn` (spelled `.mbtn`), inside the Agents
      # section, after the list.
      assert Floki.attribute(button, "class") == ["mbtn leave"]
      refute html =~ "Kick"

      [section] = Floki.find(doc, ~s(section[data-section="agents"]))
      assert Floki.find(section, ~s([data-role="meeting-ask-agent-leave"])) == [button]

      section_html = Floki.raw_html(section)
      {list_end, _} = :binary.match(section_html, "</ul>")
      {leave_at, _} = :binary.match(section_html, "meeting-ask-agent-leave")
      assert leave_at > list_end

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

  # ── The stylesheet IS the mockup (verbatim port) ──────────────────────
  #
  # `meeting_ask.css` claims to copy the mockup's rules with only the
  # `.meeting-ask` scope and the pseudo-state -> data-attribute mapping
  # changed. These hold the values a "tidy-up" would most likely drift.
  describe "meeting_ask.css against the mockup fixture" do
    test "every :root custom property in the mockup is declared identically" do
      [root] = Regex.run(~r/:root\{([^}]*)\}/, ask_mockup(), capture: :all_but_first)

      props =
        root
        |> String.split(";", trim: true)
        |> Enum.map(&String.trim/1)

      # Positive control: the fixture really has the palette.
      assert length(props) == 11
      assert "--a:#22c3dc" in props

      css = ask_css()

      for prop <- props do
        assert css =~ prop, "meeting_ask.css lost or changed the mockup's #{prop}"
      end
    end

    test "the key layout, shadow and keyframe values are copied verbatim" do
      css = ask_css()
      mockup = ask_mockup()

      for value <- [
            "grid-template-columns:36px 1fr auto",
            "width:96px;height:40px",
            "box-shadow:0 3px 0 #0e7f90,0 4px 12px rgba(34,195,220,.15)",
            "@keyframes sent{0%,80%{opacity:1;transform:none}100%{opacity:0}}",
            "@keyframes ring{0%{opacity:.75;transform:scale(1)}100%{opacity:0;transform:scale(1.28)}}",
            "@keyframes bar{from{height:4px}to{height:16px}}"
          ] do
        assert mockup =~ value, "the fixture no longer contains #{value}; update this guard"
        assert css =~ value, "meeting_ask.css drifted from the mockup at #{value}"
      end

      # The mockup's `.row:has(.ask:active)` becomes the hook-driven
      # `data-held` on the row.
      assert css =~ ~s(.meeting-ask .row[data-held="true"] .st .i{opacity:0})
      assert css =~ ~s(.meeting-ask .row[data-held="true"] .st .l{opacity:1})
    end

    # `a, b` splits; `:not(.x, .y)` does not.
    defp split_top_level_commas(selector_list) do
      {parts, current, _depth} =
        selector_list
        |> String.graphemes()
        |> Enum.reduce({[], "", 0}, fn
          "(", {acc, cur, d} -> {acc, cur <> "(", d + 1}
          ")", {acc, cur, d} -> {acc, cur <> ")", d - 1}
          ",", {acc, cur, 0} -> {[cur | acc], "", 0}
          ch, {acc, cur, d} -> {acc, cur <> ch, d}
        end)

      Enum.reverse([current | parts])
    end

    test "every rule is scoped under .meeting-ask" do
      css = Regex.replace(~r|/\*.*?\*/|s, ask_css(), "")

      selectors =
        Regex.scan(~r/(?:^|\})\s*([^{}@]+?)\{/, css, capture: :all_but_first)
        |> List.flatten()
        |> Enum.reject(&(&1 =~ ~r/^\s*(from|to|\d+%)/))
        |> Enum.flat_map(&split_top_level_commas/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or &1 =~ ~r/^(from|to|\d+%)$/))

      assert selectors != []

      for sel <- selectors do
        assert String.starts_with?(sel, ".meeting-ask"), "unscoped selector leaks: #{sel}"
      end
    end
  end

  # ── Text the eye never sees must not reach a screen reader either ──────
  #
  # `.st .l` ("Listening…"), `.tr.live` and `.tr.sent` ("✓ Sent to …") are
  # ALWAYS in the DOM and shown only by CSS opacity while held / just sent.
  # Opacity does not remove text from the accessibility tree, so unless
  # these are aria-hidden a screen reader hears "Listening…" as every
  # agent's state and "Sent to <name>" for a message never sent. (The held
  # state is already announced by `meeting-ptt-live-region`.)
  test "the opacity-hidden held/sent text is hidden from assistive tech" do
    doc =
      Floki.parse_fragment!(hold_rail([agent("Octavius", "oct-1")], hold_to_talk?: true))

    for sel <- [".st .l", ".tr.live", ".tr.sent"] do
      assert [node] = Floki.find(doc, ~s(li[data-participant-type="agent"] #{sel}))

      assert Floki.attribute(node, "aria-hidden") == ["true"],
             "#{sel} is exposed to assistive tech while visually hidden"
    end
  end
end
