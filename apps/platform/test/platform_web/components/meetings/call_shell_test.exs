defmodule PlatformWeb.Components.Meetings.CallShellTest do
  @moduledoc """
  The shared call shell — the 312px right rail and the call controls.

  Two of these tests exist because of specific ways this component
  could be wrong while looking right:

    * `call_controls/1` is only shareable if it emits the event names
      it was GIVEN. A test that passes the surface's real names cannot
      tell a parameterised component from a hardcoded one, so the
      controls tests pass deliberately fake names and assert the real
      vocabularies are ABSENT.

    * The rail must not render a `Listening` row.
      `Platform.Meetings.AgentActivity` declares `:listening` and
      nothing can set it. The guard below was shown to detonate: a
      temporary `meta(:listening)` row giving it a word made it fail
      before being reverted.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PlatformWeb.Components.Meetings.CallShell

  defp human(name, id) do
    %{
      id: id,
      participant_id: id,
      participant_type: "user",
      display_name: name,
      avatar_url: nil,
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
      attention_config: %{}
    }
  end

  defp meeting, do: %{id: "m-1", host_participant_id: "u-1"}

  defp count(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  defp rail(overrides) do
    render_component(
      &CallShell.call_rail/1,
      Keyword.merge(
        [
          tab_event: "call_rail_tab",
          participants: [human("Harper", "u-1"), agent("Saru", "a-1")],
          agents_by_id: %{},
          meeting: meeting()
        ],
        overrides
      )
    )
  end

  describe "the tab strip" do
    test "renders all three tabs with exactly one active" do
      html = rail(active_tab: "people")

      assert html =~ ">People<" or html =~ "People"
      assert html =~ "Canvas"
      assert html =~ "Transcript"

      assert length(Regex.scan(~r/data-role="call-rail-tab"/, html)) == 3
      assert length(Regex.scan(~r/data-active="true"/, html)) == 1
      assert html =~ ~s(data-tab="people" data-active="true")
    end

    test "the active marker moves with active_tab" do
      people = rail(active_tab: "people")
      canvas = rail(active_tab: "canvas")

      assert people =~ ~s(data-tab="people" data-active="true")
      assert canvas =~ ~s(data-tab="canvas" data-active="true")
      refute canvas =~ ~s(data-tab="people" data-active="true")
    end

    test "an unrecognised tab falls back to People rather than an empty pane" do
      html = rail(active_tab: "nonsense")

      assert html =~ ~s(data-pane-tab="people")
      assert html =~ ~s(data-tab="people" data-active="true")
    end

    test "the tab click pushes the event it was given, carrying the tab id" do
      html = rail(active_tab: "people", tab_event: "zzz_fake_tab_event")

      assert html =~ ~s(phx-click="zzz_fake_tab_event")
      assert html =~ ~s(phx-value-tab="canvas")
    end
  end

  describe "the panes" do
    test "People renders both participant sections" do
      html = rail(active_tab: "people")

      assert html =~ ~s(data-section="humans")
      assert html =~ ~s(data-section="agents")
      assert html =~ "Harper"
      assert html =~ "Saru"
    end

    test "switching active_tab swaps the pane content, it does not just restyle" do
      people = rail(active_tab: "people")
      canvas = rail(active_tab: "canvas")
      transcript = rail(active_tab: "transcript")

      assert people =~ ~s(data-section="humans")
      refute canvas =~ ~s(data-section="humans")
      refute transcript =~ ~s(data-section="humans")

      # The transcript pane is NOT swapped — it persists and is hidden
      # (see the next test). What swaps is the wrap's visibility.
      assert count(transcript, ~s([data-role="meeting-transcript-wrap"][data-active="true"])) == 1
      assert count(people, ~s([data-role="meeting-transcript-wrap"][data-active="false"])) == 1
    end

    # Task 01a05b14 stage 5. `candidate_rail` renders nothing at all with
    # no open card, no closed card and no error, so the quickmeet's Canvas
    # tab was a blank tabpanel (0 children) that read as "loading". The
    # pane now names its condition; the wording depends on whether a
    # `meetings` row exists, because a call without one can never form a
    # card and saying "no cards yet" there would promise something.
    test "Canvas with no cards names why it is empty instead of a blank pane" do
      live_meeting = rail(active_tab: "canvas")

      assert live_meeting =~ ~s(data-role="call-rail-canvas-empty")
      assert live_meeting =~ "No cards in this call yet"
      refute live_meeting =~ "no meeting record"

      adhoc = rail(active_tab: "canvas", meeting: nil)

      assert adhoc =~ ~s(data-role="call-rail-canvas-empty")
      assert adhoc =~ "This call has no meeting record, so no cards can form from it."
      refute adhoc =~ "No cards in this call yet"

      # Neither wording is the always-on lie the `Listening` refusal exists
      # to prevent, and the line belongs to the Canvas pane only.
      refute live_meeting =~ ~r/listening/i
      refute adhoc =~ ~r/listening/i
      refute rail(active_tab: "people") =~ ~s(call-rail-canvas-empty)
      refute rail(active_tab: "transcript") =~ ~s(call-rail-canvas-empty)
    end

    test "the Canvas empty state yields to a card and to an error" do
      card = %Platform.Meetings.MeetingCandidate{
        id: Ecto.UUID.generate(),
        evidence_quote: "we should rotate the staging secrets",
        state: :shaping,
        classified_intent: "action_item",
        transcript_chunk_ids: [Ecto.UUID.generate()],
        acts_at: nil,
        inserted_at: ~U[2026-09-01 12:00:00.000000Z]
      }

      with_card = rail(active_tab: "canvas", candidates: [card])
      assert with_card =~ ~s(data-role="meeting-candidate-card")
      refute with_card =~ ~s(call-rail-canvas-empty)

      with_error = rail(active_tab: "canvas", candidate_error: "could not load cards")
      assert with_error =~ ~s(data-role="meeting-candidate-error")
      refute with_error =~ ~s(call-rail-canvas-empty)
    end

    test "Transcript mounts the JS-owned pane with phx-update=ignore, once, on every tab" do
      # `meeting:caption` is a client-side DOM CustomEvent that never
      # reaches the server, so the lines are appended by the
      # `MeetingTranscript` hook. Without `phx-update="ignore"` the next
      # LiveView patch would morphdom them away mid-call.
      #
      # And the host is present on EVERY tab (count == 1, never 0). This
      # replaces the earlier "toggling adds/removes the host" contract on
      # purpose: a removed host is a destroyed hook, and a destroyed hook
      # is a lost buffer. The People tab must not cost the reader their
      # scrollback. What flips is `hidden` on the OUTER wrap LiveView
      # owns, because under `phx-update="ignore"` a class or `hidden`
      # change on the host itself never reaches the DOM (task 01a06524).
      for tab <- ~w(people canvas transcript) do
        html = rail(active_tab: tab)

        assert count(html, ~s([data-role="meeting-transcript"])) == 1, tab

        assert count(
                 html,
                 ~s([data-role="meeting-transcript"][phx-hook="MeetingTranscript"][phx-update="ignore"])
               ) == 1,
               tab

        assert count(html, ~s([phx-hook="MeetingTranscript"])) == 1, tab
        assert count(html, ~s([data-role="meeting-transcript-wrap"])) == 1, tab

        hidden = count(html, ~s([data-role="meeting-transcript-wrap"][hidden]))
        assert hidden == if(tab == "transcript", do: 0, else: 1), tab
      end
    end

    test "the empty state names the condition and cannot be read as 'transcription is running'" do
      html = rail(active_tab: "transcript")

      assert html =~ "No speech yet. Lines appear here as people talk."

      # The refusal, stated as a test rather than a comment: this pane
      # must never imply a transcriber is attached when none is. Those
      # words are the always-on lie the `Listening` refusal exists to
      # prevent, and a future edit that reaches for them fails here.
      refute html =~ ~r/listening/i
      refute html =~ ~r/transcribing/i
      refute html =~ "Waiting for speech"
    end

    test "says captions are unavailable rather than implying none have arrived yet" do
      available = rail(active_tab: "transcript", captions_available: true)
      unavailable = rail(active_tab: "transcript", captions_available: false)

      # DIRECTION CONTROL: the two branches are genuinely different text,
      # so the assertion below is about the flag and not about a string
      # that is present either way.
      assert available =~ "No speech yet. Lines appear here as people talk."
      refute available =~ "Captions are unavailable for this meeting"

      assert unavailable =~ "Captions are unavailable for this meeting"
      refute unavailable =~ "No speech yet."
    end

    test "an explicit transcript slot wins over the JS-owned pane" do
      html =
        render_component(
          &CallShell.call_rail/1,
          id: "rail",
          tab_event: "call_rail_tab",
          active_tab: "transcript",
          participants: [],
          agents_by_id: %{},
          meeting: meeting(),
          transcript: [
            %{inner_block: fn _, _ -> "ARCHIVED TRANSCRIPT" end, __slot__: :transcript}
          ]
        )

      assert html =~ "ARCHIVED TRANSCRIPT"
      assert html =~ ~s(data-role="call-rail-transcript")
      refute html =~ ~s(phx-hook="MeetingTranscript")
      refute html =~ ~s(data-role="meeting-transcript-wrap")
    end
  end

  # ── The invite section (task 01a0691d stage 2) ─────────────────────────
  #
  # The rows are the server's (`MeetingLive.invite_rows/2`); the component
  # is handed `%{agent, state, capability}` maps and must draw exactly what
  # the design canvas says for each. Fake event name throughout, so a
  # component that hardcoded either surface's literal would fail here.

  defp invite_row(id, state, capability \\ :capable) do
    %{
      agent: %{id: id, name: "Agent " <> id, slug: "agent-" <> id},
      state: state,
      capability: capability
    }
  end

  defp four_rows do
    [
      invite_row("a-free", :invitable),
      invite_row("a-pend", :pending),
      invite_row("a-off", :incapable, :incapable),
      invite_row("a-here", :in_call)
    ]
  end

  defp invite_rail(rows),
    do: rail(active_tab: "people", invite_event: "zzz_fake_invite", invite_rows: rows)

  defp section(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(~s([data-role="meeting-agent-invite"]))
  end

  defp invite_row_html(html, id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="meeting-agent-invite-row"][data-agent-id="#{id}"]))
    |> LazyHTML.to_html()
  end

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  describe "the invite section" do
    test "is present with the heading and the empty line when there are no rows" do
      html = invite_rail([])

      sect = section(html)
      assert Enum.count(sect) == 1
      assert LazyHTML.text(sect) =~ "Invite an agent"

      empty = LazyHTML.query(sect, ~s([data-role="meeting-agent-invite-empty"]))
      assert Enum.count(empty) == 1

      assert squish(LazyHTML.text(empty)) ==
               "No active agents yet. Every active agent appears here, whether or not it is already in this space."

      refute html =~ ~s(data-role="meeting-agent-invite-row")
    end

    test "is absent when no invite_event is supplied, rows or not" do
      refute rail(active_tab: "people") =~ ~s(data-role="meeting-agent-invite")

      refute rail(active_tab: "people", invite_rows: four_rows()) =~
               ~s(data-role="meeting-agent-invite")
    end

    test "renders the four states in the order given, each with its exact reason" do
      html = invite_rail(four_rows())

      rows =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-agent-invite-row"]))

      assert LazyHTML.attribute(rows, "data-invite-state") ==
               ["invitable", "pending", "incapable", "in_call"]

      assert LazyHTML.attribute(rows, "data-agent-id") == ["a-free", "a-pend", "a-off", "a-here"]

      reasons =
        rows
        |> LazyHTML.query(~s([data-role="meeting-agent-invite-reason"]))
        |> Enum.map(&squish(LazyHTML.text(&1)))

      assert reasons == [
               "Voice runtime online",
               "Invite sent, no answer yet",
               "No voice runtime online",
               "Already in the call"
             ]

      # Rows present: the empty line is not.
      refute html =~ ~s(data-role="meeting-agent-invite-empty")
    end

    # Task 01a05553 — the rows are the active roster now, so membership of
    # the meeting's space is a fact ON the row instead of the filter that
    # decided whether the row existed. It is drawn as INFORMATION beside the
    # name: the button on a non-member row still works, and nothing about it
    # reads as a permissions rule.
    test "a non-member row is marked beside the name and still gets its button" do
      html =
        invite_rail([
          Map.put(invite_row("a-out", :invitable), :in_space?, false),
          Map.put(invite_row("a-in", :invitable), :in_space?, true)
        ])

      out_row = invite_row_html(html, "a-out")
      in_row = invite_row_html(html, "a-in")

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(
               ~s([data-role="meeting-agent-invite-row"][data-agent-id="a-out"] ) <>
                 ~s([data-role="meeting-agent-invite-membership"])
             )
             |> LazyHTML.text()
             |> squish() == "not in space"

      # Marked, not blocked.
      assert out_row =~ "zzz_fake_invite"
      assert out_row =~ ~s(phx-value-agent-id="a-out")

      # And the member row carries no marker at all, so the assertion above
      # cannot be passing against a build that stamps every row.
      refute in_row =~ "meeting-agent-invite-membership"
    end

    # The flag arrived after this component did. A caller still passing the
    # old three-key row must render the row it always rendered rather than
    # sprout a label about a space it never said anything about.
    test "a row with no membership key draws no marker" do
      html = invite_rail([invite_row("a-legacy", :invitable)])

      refute invite_row_html(html, "a-legacy") =~ "meeting-agent-invite-membership"
    end

    test "blocked rows are plain items: no button, no phx-click" do
      html = invite_rail(four_rows())

      for id <- ["a-off", "a-here"] do
        row = invite_row_html(html, id)
        assert row =~ ~s(data-agent-id="#{id}")
        refute row =~ "<button", id
        refute row =~ "phx-click", id
        refute row =~ "zzz_fake_invite", id
      end
    end

    test "invitable and pending rows offer the button against the given event" do
      html = invite_rail(four_rows())

      buttons =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-agent-invite-button"]))

      assert LazyHTML.attribute(buttons, "phx-click") == ["zzz_fake_invite", "zzz_fake_invite"]
      assert LazyHTML.attribute(buttons, "phx-value-agent-id") == ["a-free", "a-pend"]
      assert LazyHTML.attribute(buttons, "data-agent-id") == ["a-free", "a-pend"]
    end

    # The #883 honesty rule, re-tokened: an invite whose join reached no
    # subscriber is re-offered AND labelled — in `info`, because warning on
    # this rail means a human is being asked for something.
    test "a pending row keeps the button, says Waiting in the info token, never warning" do
      html = invite_rail(four_rows())

      pending = invite_row_html(html, "a-pend")
      assert pending =~ ~s(data-role="meeting-agent-invite-button")
      assert pending =~ ~s(data-invite-pending="true")
      assert pending =~ "Waiting"
      refute pending =~ "text-warning"

      label =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-agent-invite-pending"]))

      assert [class] = LazyHTML.attribute(label, "class")
      assert class =~ "text-info"
      assert squish(LazyHTML.text(label)) == "Waiting"

      fresh = invite_row_html(html, "a-free")
      refute fresh =~ "data-invite-pending"
      refute fresh =~ "Waiting"
      assert fresh =~ "Invite"
    end

    test "an agent of unknown capability gets the button and no reason line at all" do
      html = invite_rail([invite_row("a-unk", :invitable, :unknown)])

      row = invite_row_html(html, "a-unk")
      assert row =~ ~s(data-role="meeting-agent-invite-button")
      refute row =~ "meeting-agent-invite-reason"
    end

    test "the section carries no warning or error token and never says listening or hidden" do
      for rows <- [four_rows(), []] do
        sect = rows |> invite_rail() |> section() |> LazyHTML.to_html()

        refute sect =~ "warning"
        refute sect =~ "error"
        refute sect =~ ~r/listening/i
        refute sect =~ ~r/hidden/i
      end
    end
  end

  describe "agent activity in the rail" do
    # This is the assertion stage 1 could not make. `agent_tile/1`
    # applies `.agent-tile-activity`, whose app.css rule sets
    # `display:none` on `[data-role="agent-activity-word"]` — so on the
    # gallery strip the word was in the DOM and invisible. DOM presence
    # therefore proves nothing on its own; the suppressing class must
    # also be absent.
    test "the activity WORD renders and is not CSS-suppressed" do
      html =
        rail(
          active_tab: "people",
          agent_activity: %{"a-1" => :computing}
        )

      assert html =~ "Thinking"
      assert html =~ ~s(data-role="agent-activity-word")
      refute html =~ "agent-tile-activity"
    end

    test "each real state renders its own word" do
      assert rail(active_tab: "people", agent_activity: %{"a-1" => :computing}) =~ "Thinking"
      assert rail(active_tab: "people", agent_activity: %{"a-1" => :typing}) =~ "Writing"
      assert rail(active_tab: "people", agent_activity: %{"a-1" => :failed}) =~ "Couldn&#39;t"
    end

    # THE REFUSAL. `:listening` has no producer, and drawing it would
    # put a caption on screen that nothing can ever make true.
    test "no state, real or declared-but-unproducible, renders Listening" do
      for state <- [:computing, :typing, :failed, :idle, :listening] do
        html = rail(active_tab: "people", agent_activity: %{"a-1" => state})
        refute html =~ "Listening"
      end
    end
  end

  describe "the agent row's construction, through the shell" do
    # The rail is reached here through `call_shell/1` rather than
    # directly, so these assert what the SHELL actually puts on screen
    # on both surfaces — the quickmeet and /meetings render the same
    # shell, which is why one file can speak for both.
    test "the state is drawn ON the avatar, ring plus corner glyph" do
      html = rail(active_tab: "people", agent_activity: %{"a-1" => :computing})

      assert html =~ ~s(data-role="agent-activity-avatar")
      assert html =~ ~s(data-role="agent-activity-ring")
      assert html =~ ~s(data-role="agent-activity-glyph")
      assert html =~ "border-info"
    end

    test "the role chip no longer occupies the line under the name" do
      html = rail(active_tab: "people", agent_activity: %{"a-1" => :computing})

      refute html =~ ~s(data-role="agent-role-chip")
      assert html =~ ~s(data-role="agent-activity-word")
    end

    # The state a quiet meeting spends nearly all of its time in, and
    # the one the old rail drew as a bare dot with the literal word
    # "agent" beside it.
    test "idle is a drawn state: muted ring, dimmed face, the word Idle" do
      html = rail(active_tab: "people", agent_activity: %{"a-1" => :idle})

      assert html =~ "Idle"
      assert html =~ ~s(data-role="agent-activity-avatar")
      assert html =~ "border-base-content/25"
      assert html =~ "opacity-45"
      refute html =~ ~s(data-role="agent-activity-glyph")
    end

    test "the reachability dot is not lost when the ring takes the avatar" do
      for state <- [:computing, :typing, :failed, :idle] do
        html = rail(active_tab: "people", agent_activity: %{"a-1" => state})

        assert html =~ ~s(data-role="agent-status-dot"),
               "#{state}: the reachability dot — a different fact from activity — was dropped"
      end
    end
  end

  describe "call_controls/1" do
    defp controls(overrides \\ []) do
      render_component(
        &CallShell.call_controls/1,
        Keyword.merge(
          [
            mic_event: "zzz_fake_mic",
            camera_event: "zzz_fake_camera",
            share_event: "zzz_fake_share",
            leave_event: "zzz_fake_leave"
          ],
          overrides
        )
      )
    end

    # The load-bearing one. A hardcoded component passes any test that
    # feeds it a real event name, so this feeds it names no surface
    # uses and asserts BOTH real vocabularies are absent.
    test "emits the event names it was given, not either surface's literals" do
      html = controls()

      assert html =~ ~s(phx-click="zzz_fake_mic")
      assert html =~ ~s(phx-click="zzz_fake_camera")
      assert html =~ ~s(phx-click="zzz_fake_share")
      assert html =~ ~s(phx-click="zzz_fake_leave")

      refute html =~ "meeting_toggle_mic"
      refute html =~ "meeting_toggle_camera"
      refute html =~ "meeting_leave"
      refute html =~ "meeting_start_screen_share"
      refute html =~ "meeting_toggle_screen_share"
    end

    # THE VISIBLE LABEL IS READ OUT OF THE SPAN, NEVER OFF THE PAGE.
    #
    # `assert off =~ "Unmute"` is a substring over the whole render and
    # `aria-label="Unmute microphone"` satisfies it, so the assertion
    # that shipped could not tell the visible word from the accessible
    # name and would have gone green on a change that deleted the
    # thing it exists to protect. Since task 01a0773e it cannot tell
    # them from the HIDDEN word either: both words are now in the
    # markup at all times, the inactive one held there by
    # `visibility: hidden` so the control reserves its widest label
    # and stops changing width when pressed.
    #
    # `[data-shown="true"]` is the only reading that distinguishes all
    # three. It resolves to nothing, and fails, if the label span goes
    # away.
    defp shown_label(html, role),
      do: label_word(html, role, "true")

    # The reserved word: present, laid out, not shown. Asserted
    # explicitly because it is the whole fix — a render carrying only
    # the current word looks correct in a snapshot and moves the row.
    defp reserved_label(html, role),
      do: label_word(html, role, "false")

    defp label_word(html, role, shown) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="#{role}"] .call-control-label [data-shown="#{shown}"]))
      |> LazyHTML.text()
      |> String.trim()
    end

    test "the mic button says what the click will DO, not what is true now" do
      on = controls(mic_on: true)
      off = controls(mic_on: false)

      assert shown_label(on, "call-control-mic") == "Mute"
      assert shown_label(off, "call-control-mic") == "Unmute"

      assert on =~ ~s(size-4 hero-microphone")
      refute on =~ "hero-microphone-slash"
      assert off =~ "hero-microphone-slash"
    end

    # Each control reserves its OWN widest word, so the row does not
    # reflow when one is pressed. Both pairs are asserted because they
    # have DIFFERENT wider words — "Unmute" for mic, "Stop sharing" for
    # share — which is exactly why a single tuned `min-width` cannot
    # fix this row and why a mic-only test would go green on a fix
    # that leaves share broken.
    test "a toggling control carries both of its words in every state" do
      for {role, on_key, when_on, when_off} <- [
            {"call-control-mic", :mic_on, "Mute", "Unmute"},
            {"call-control-share", :sharing, "Stop sharing", "Share"}
          ] do
        on = controls([{on_key, true}])
        off = controls([{on_key, false}])

        assert shown_label(on, role) == when_on
        assert reserved_label(on, role) == when_off
        assert shown_label(off, role) == when_off
        assert reserved_label(off, role) == when_on
      end
    end

    # The class the narrow-bar container query keys on stays ONE PER
    # CONTROL. The words are nested inside it, not siblings of it: a
    # second span carrying `.call-control-label` per control would take
    # the quickmeet bar's count from four to six and break
    # `partials_meeting_panel_test.exs`, which asserts that number
    # because a drifting class silently stops the CSS applying and
    # re-clips Leave.
    test "four labels on the row, whatever state the toggles are in" do
      for opts <- [
            [mic_on: true, sharing: false],
            [mic_on: false, sharing: true]
          ] do
        assert count(controls(opts), ".call-control-label") == 4
      end
    end

    test "Leave carries the error slot, and nothing else does" do
      html = controls()

      assert html =~ ~s(data-role="call-control-leave")
      assert html =~ "text-error"
      refute html =~ "hero-x-mark"
    end

    # Same correction as the mic test above: `assert live =~ "Stop
    # sharing"` was satisfied by `aria-label="Stop sharing your
    # screen"` in EVERY state, including the idle one, so it was
    # asserting nothing about what the button says.
    test "share reflects whether a share is already running" do
      idle = controls(sharing: false)
      live = controls(sharing: true)

      assert shown_label(idle, "call-control-share") == "Share"
      assert shown_label(live, "call-control-share") == "Stop sharing"
      assert idle =~ ~s(data-on="false")
    end
  end

  describe "the rail's type scale (task 01a05b14 stage 5)" do
    # The approved target draws the rail at 12px name / 11px sub-line /
    # 11px uppercase heading at EVERY width: the sub-`lg` drawer is the
    # same rail narrowed, not a different screen. The rows used to say
    # `text-sm` and let the name inherit the shell's body scale. These
    # tests read the CLASS LIST of each node, not a substring of the
    # page, and refute any breakpoint prefix on the size utility.
    defp class_of(html, selector) do
      classes =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(selector)
        |> LazyHTML.attribute("class")

      assert classes != [], "no element matched #{selector}"
      classes
    end

    # `text-base-content/90` is a COLOUR, not a size — the lookahead
    # stops `text-base` matching inside it.
    defp size_utilities(class),
      do: Regex.scan(~r/(?:\S+:)?text-(?:xs|sm|base|\[\d+px\])(?![\w\/-])/, class)

    test "participant names are pinned to text-xs with no breakpoint variant" do
      html =
        rail(
          active_tab: "people",
          participants: [human("Harper", "u-1"), agent("Saru", "a-1")],
          agent_activity: %{"a-1" => :computing}
        )

      names = class_of(html, ~s([data-role="participant-name"]))
      assert length(names) == 2, "one name per row, human and agent alike"

      for class <- names do
        assert class =~ "text-xs"
        refute class =~ "text-sm"

        assert size_utilities(class) == [["text-xs"]],
               "the name's size must be one bare utility, got: #{class}"
      end
    end

    test "the sub-line and the section headings are 11px, unconditionally" do
      html =
        rail(
          active_tab: "people",
          participants: [human("Harper", "u-1"), agent("Saru", "a-1")],
          agent_activity: %{"a-1" => :computing}
        )

      [word] = class_of(html, ~s([data-role="agent-activity-word"]))
      assert size_utilities(word) == [["text-[11px]"]]

      headings =
        class_of(html, ~s([data-section] > div > span.uppercase))

      assert length(headings) == 2, "In this call + Agents"

      for class <- headings do
        assert size_utilities(class) == [["text-[11px]"]]
      end
    end

    test "the tab labels match the rail's 11px scale" do
      for class <- class_of(rail(active_tab: "people"), ~s([data-role="call-rail-tab"])) do
        assert size_utilities(class) == [["text-[11px]"]]
      end
    end

    # The row itself carries the size too, so anything inside it that
    # forgets its own utility inherits 12px rather than the shell's 14px.
    test "the rows themselves set text-xs rather than inheriting" do
      html = rail(active_tab: "people")

      for class <- class_of(html, ~s([data-participant-id])) do
        assert size_utilities(class) == [["text-xs"]], class
      end
    end
  end
end
