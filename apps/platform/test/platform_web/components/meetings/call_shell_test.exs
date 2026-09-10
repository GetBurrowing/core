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

  defp nodes(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp label_for(id) do
    {^id, label} = Enum.find(CallShell.tabs(), fn {tab, _} -> tab == id end)
    label
  end

  defp tab_ids(html),
    do: html |> nodes(~s([data-role="call-rail-tab"])) |> LazyHTML.attribute("data-tab")

  # The ACCESSIBLE name of every tab, in render order. Only the active tab
  # draws its word; the other three are icon-only, so reading visible text
  # here would report three empty strings and call it a regression.
  defp tab_names(html),
    do: html |> nodes(~s([data-role="call-rail-tab"])) |> LazyHTML.attribute("aria-label")

  defp visible_tab_labels(html) do
    html
    |> nodes(~s([data-role="call-rail-tab-label"]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # A `:chat` slot entry, in the shape `render_component/2` hands a function
  # component. Supplying one is what CREATES the Chat tab as of task 01a084bf
  # stage 4 (`CallShell.served_tabs/1`), so `rail/1` supplies one by default
  # — that is the `/meetings` shape, which every four-up assertion below is
  # about. Pass `chat: []` for the QUICKMEET shape: a caller that serves no
  # chat pane.
  defp chat_slot(body), do: [%{__slot__: :chat, inner_block: fn _, _ -> body end}]

  # THIS FIXTURE IS A GENUINE ALL-TABS CALLER, AND THAT IS WHAT ENTITLES THE
  # LOOPS BELOW TO `CallShell.tabs/0` (task 01a089fe stage 4's census).
  #
  # `chat: chat_slot(...)` is in the DEFAULTS, so unless a case overrides it
  # this rail is handed every slot and `served_tabs/1` returns all four —
  # the derived list and the unfiltered vocabulary are EQUAL here. Several
  # cases below iterate `CallShell.tabs()` to assert a per-tab property
  # (every id has a pane clause, an icon, an aria-label); those are asking
  # what the rail KNOWS ABOUT, which is exactly what that function answers,
  # and they are correct.
  #
  # DROP `chat:` FROM THESE DEFAULTS AND THOSE LOOPS GO WRONG QUIETLY. They
  # would render a rail serving three tabs and then assert `"chat"` has a
  # pane — `data-pane-tab="chat"` would simply not be found, and the failure
  # would read as "the chat pane broke" rather than "the fixture stopped
  # serving chat". Override `chat:` per case, not here.
  defp rail(overrides) do
    render_component(
      &CallShell.call_rail/1,
      Keyword.merge(
        [
          tab_event: "call_rail_tab",
          participants: [human("Harper", "u-1"), agent("Saru", "a-1")],
          agents_by_id: %{},
          meeting: meeting(),
          chat: chat_slot("MOUNTED CHAT PANE")
        ],
        overrides
      )
    )
  end

  describe "the tab strip" do
    test "renders all four tabs in render order, with exactly one active" do
      html = rail(active_tab: "people")

      # ORDER is part of the contract, not just membership: Chat sits
      # second, between People and Canvas (task 01a084bf).
      assert tab_ids(html) == ~w(people chat canvas transcript)
      assert tab_names(html) == ["People", "Chat", "Canvas", "Transcript"]

      assert count(html, ~s([data-role="call-rail-tab"])) == 4

      # Scoped to the tabs. `data-active` is also carried by the two
      # persistent pane wrappers, so an unscoped count of
      # `data-active="true"` measures something else.
      assert count(html, ~s([data-role="call-rail-tab"][data-active="true"])) == 1

      assert count(html, ~s([data-role="call-rail-tab"][data-tab="people"][data-active="true"])) ==
               1
    end

    test "every tab id the strip renders has a pane clause" do
      # The pane `case` has NO catch-all, deliberately, so a tab added to
      # `@tabs` without a branch raises `CaseClauseError` at RUNTIME and
      # compiles clean. This walks the real list rather than a copy of it.
      for {id, label} <- CallShell.tabs() do
        html = rail(active_tab: id)

        assert html =~ ~s(data-pane-tab="#{id}"), label
        assert count(html, ~s([data-role="call-rail-pane"])) == 1, label
      end
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

    test "only the active tab spends width on a word; the other three are icons" do
      # THE MEASURED RULE (task 01a084bf stage 1). Four equal text tabs in a
      # 312px rail give each label a 62px box, and "Transcript" is 60.91px
      # inactive / 62.67px semibold-active — so the active Transcript tab
      # rendered "Transcri…". The brand rule: the active tab keeps its word
      # and takes the leftover width, the rest go icon-only.
      for {active, _} <- CallShell.tabs() do
        html = rail(active_tab: active)

        assert visible_tab_labels(html) == [label_for(active)],
               "exactly one visible label, the active one (#{active})"

        assert count(html, ~s([data-role="call-rail-tab-icon"])) == 3, active

        assert count(
                 html,
                 ~s([data-role="call-rail-tab"][data-active="true"] [data-role="call-rail-tab-icon"])
               ) ==
                 0,
               "the active tab is never reduced to an icon (#{active})"

        # Whatever is selected, the a11y tree still exposes all four words.
        assert tab_names(html) == ["People", "Chat", "Canvas", "Transcript"], active
      end
    end

    test "Transcript is never abbreviated, in any state, anywhere in the markup" do
      # The rule allows dropping a label entirely in favour of an icon. It
      # does NOT allow shortening the word: no "Trans", no "Script", no
      # server-rendered ellipsis. If the strip ever gets tight again the
      # answer is the icon, not a truncated string.
      for {active, _} <- CallShell.tabs() do
        html = rail(active_tab: active)

        assert html =~ ~s(aria-label="Transcript"), active
        refute html =~ ~r/aria-label="Trans(?!cript")/, active
        refute html =~ "Transcr…", active
        refute html =~ "Transcript…", active
      end
    end

    test "each tab id maps to its own icon, and no two share one" do
      icons = for {id, _} <- CallShell.tabs(), do: CallShell.tab_icon(id)

      assert length(Enum.uniq(icons)) == 4, "four tabs, four distinct glyphs: #{inspect(icons)}"
      assert Enum.all?(icons, &String.starts_with?(&1, "hero-"))
      assert CallShell.tab_icon("chat") == "hero-chat-bubble-left-right"
    end

    test "the tab click pushes the event it was given, carrying the tab id" do
      html = rail(active_tab: "people", tab_event: "zzz_fake_tab_event")

      assert html =~ ~s(phx-click="zzz_fake_tab_event")
      assert html =~ ~s(phx-value-tab="canvas")
    end
  end

  # ── The strip is PER-CALLER (ticket 01a089ae, fixed in task 01a084bf
  #    stage 4) ─────────────────────────────────────────────────────────────
  #
  # Stage 1 added `{"chat", "Chat"}` to `@tabs` and the strip rendered off
  # `tabs()`, the module function — so the in-chat quickmeet, which passes NO
  # `:chat` slot because the real discussion is already on screen beside it,
  # grew a Chat tab whose pane was empty. These cases pin the fix as
  # PER-CALLER: the four-up assertions above (which use `rail/1`, i.e. WITH a
  # chat slot) are the other half, and one surface alone cannot tell "the fix
  # worked" from "Chat disappeared everywhere".
  describe "the strip a caller can actually serve" do
    test "no chat slot means no Chat tab — and a chat slot still means four" do
      quickmeet = rail(active_tab: "people", chat: [])
      meeting_surface = rail(active_tab: "people")

      assert tab_ids(quickmeet) == ~w(people canvas transcript)
      assert count(quickmeet, ~s([data-role="call-rail-tab"])) == 3
      assert tab_names(quickmeet) == ["People", "Canvas", "Transcript"]

      # POSITIVE CONTROL on the same selector, in the same assertion pair:
      # a `refute`/`== 0` on a selector that has stopped matching anywhere
      # passes forever.
      assert count(quickmeet, ~s([data-role="call-rail-tab"][data-tab="chat"])) == 0
      assert count(meeting_surface, ~s([data-role="call-rail-tab"][data-tab="chat"])) == 1

      assert tab_ids(meeting_surface) == ~w(people chat canvas transcript)
      assert count(meeting_surface, ~s([data-role="call-rail-tab"])) == 4
    end

    test "a caller with no chat slot gets no empty chat wrapper either" do
      assert count(rail(active_tab: "people", chat: []), ~s([data-role="call-rail-chat-wrap"])) ==
               0

      assert count(rail(active_tab: "people"), ~s([data-role="call-rail-chat-wrap"])) == 1
    end

    test "a slotless caller asking for `chat` lands on People, not on a pane with no button" do
      # THE TRAP THE TICKET DID NOT MENTION. `normalize_tab/1` coerces to
      # `@tabs`, which still contains "chat" — so filtering the strip alone
      # would leave a quickmeet arriving with `active_tab: "chat"` (a stale
      # `?tab=` param, a bookmark, or its own `"meeting_tab_select"` handler,
      # which assigns any binary) sitting on a Chat pane it cannot navigate
      # away from. The pane `case` has no catch-all, so getting this wrong is
      # a `CaseClauseError`, not a cosmetic slip — rendering at all is part
      # of what this asserts.
      quickmeet = rail(active_tab: "chat", chat: [])

      assert quickmeet =~ ~s(data-pane-tab="people")

      assert count(
               quickmeet,
               ~s([data-role="call-rail-tab"][data-tab="people"][data-active="true"])
             ) == 1

      assert count(quickmeet, ~s([data-role="call-rail-tab"][data-active="true"])) == 1

      # POSITIVE CONTROL: the very same `active_tab` DOES select Chat once
      # the caller can serve it, so the fallback above is about the slot and
      # not about the string "chat" being rejected everywhere.
      served = rail(active_tab: "chat")
      assert served =~ ~s(data-pane-tab="chat")

      assert count(served, ~s([data-role="call-rail-tab"][data-tab="chat"][data-active="true"])) ==
               1
    end

    test "normalize_tab/2 answers for the caller's list, and /1 still answers for all four" do
      three = [{"people", "People"}, {"canvas", "Canvas"}, {"transcript", "Transcript"}]

      assert CallShell.normalize_tab("chat") == "chat"
      assert CallShell.normalize_tab("chat", three) == "people"
      assert CallShell.normalize_tab("canvas", three) == "canvas"
      assert CallShell.normalize_tab("nonsense", three) == "people"
      assert CallShell.normalize_tab(nil, three) == "people"

      # The fallback must itself be servable by every caller, or the coercion
      # just moves the unreachable-pane problem.
      assert Enum.any?(three, fn {id, _} -> id == "people" end)
    end

    test "served_tabs/1 reads :chat as a boolean capability, not just a slot list" do
      # Task 01a089fe stage 1. The `/meetings` COLLAPSED 44px icon strip is
      # markup in `meeting_live.html.heex`, not a call to `call_rail/1`, so it
      # holds no slots and cannot state its capability as one. It states it as
      # a boolean and reaches the SAME derivation, which is what stops it
      # looping the unfiltered `tabs/0`.
      ids = fn assigns -> Enum.map(CallShell.served_tabs(assigns), &elem(&1, 0)) end

      assert ids.(%{chat: true}) == ["people", "chat", "canvas", "transcript"]
      assert ids.(%{chat: false}) == ["people", "canvas", "transcript"]

      # DISCRIMINATING, unlike anything that can be asserted against
      # `/meetings` today: that surface supplies `<:chat>` unconditionally, so
      # its derived list is EQUAL to `tabs/0` and no render of it can tell the
      # two apart. Here they must differ, or `served_tabs/1` is not filtering.
      refute ids.(%{chat: false}) == Enum.map(CallShell.tabs(), &elem(&1, 0))

      # The boolean form must agree with the slot form it stands in for —
      # otherwise the strip and the rail derive different lists from the same
      # capability, which is the defect restated.
      assert ids.(%{chat: false}) == ids.(%{})
      assert ids.(%{chat: false}) == ids.(%{chat: []})
      assert ids.(%{chat: true}) == ids.(%{chat: [%{inner_block: nil}]})

      # And the coercion has to follow the filtered list, or a strip with no
      # Chat button can still mark Chat active.
      assert CallShell.normalize_tab("chat", CallShell.served_tabs(%{chat: false})) == "people"
      assert CallShell.normalize_tab("chat", CallShell.served_tabs(%{chat: true})) == "chat"
    end
  end

  # ── The unread dot on the EXPANDED strip (task 01a084bf stage 4, FE-5's
  #    V2 case) ──────────────────────────────────────────────────────────────
  describe "the Chat tab's unread dot" do
    defp dots(html), do: nodes(html, ~s([data-role="call-rail-tab-unread-dot"]))

    test "it is absent while nothing is unread and present when it is" do
      # Transcript active, so Chat is one of the icon-only tabs — the state a
      # viewer is actually in when a dot is raised, since arriving at Chat
      # clears it.
      quiet = rail(active_tab: "transcript", chat_unread: false)
      raised = rail(active_tab: "transcript", chat_unread: true)

      assert Enum.count(dots(quiet)) == 0
      assert Enum.count(dots(raised)) == 1
    end

    test "it rides the Chat tab and no other" do
      html = rail(active_tab: "transcript", chat_unread: true)

      assert count(
               html,
               ~s([data-role="call-rail-tab"][data-tab="chat"] [data-role="call-rail-tab-unread-dot"])
             ) == 1

      for other <- ~w(people canvas transcript) do
        assert count(
                 html,
                 ~s([data-role="call-rail-tab"][data-tab="#{other}"] [data-role="call-rail-tab-unread-dot"])
               ) == 0,
               other
      end
    end

    test "6px, round, `info`, aria-hidden, and it NEVER animates" do
      html = rail(active_tab: "transcript", chat_unread: true)
      node = dots(html)

      assert LazyHTML.attribute(node, "aria-hidden") == ["true"]

      class = node |> LazyHTML.attribute("class") |> List.first()

      # `size-1.5` is 6px at the default root size — the figure the stage
      # names, not a nearby one.
      assert class =~ ~r/\bsize-1\.5\b/, class
      assert class =~ ~r/\brounded-full\b/, class
      assert class =~ ~r/\bbg-info\b/, class

      # `error`, `success` and `warning` are all already spent on this
      # screen; `info` is the one meaning-bearing slot left.
      for spent <- ["bg-error", "bg-success", "bg-warning"] do
        refute class =~ ~r/\b#{spent}\b/, class
      end

      # A blinking dot in peripheral vision during a call is hostile.
      for motion <- ["animate-", "transition", "duration-", "motion-safe:"] do
        refute class =~ motion, "the dot must not animate in any form. Got: #{class}"
      end
    end

    test "the accessible name says so, since the dot itself is aria-hidden" do
      raised = rail(active_tab: "transcript", chat_unread: true)
      quiet = rail(active_tab: "transcript", chat_unread: false)

      assert tab_names(raised) == ["People", "Chat, unread messages", "Canvas", "Transcript"]
      assert tab_names(quiet) == ["People", "Chat", "Canvas", "Transcript"]

      # Only Chat's name moves. "Transcript" in particular is never
      # abbreviated or re-worded, in either state.
      assert raised =~ ~s(aria-label="Transcript")
    end

    test "the dot is inline AFTER the label, so it cannot clip `Transcript`" do
      # Read on the ACTIVE Chat tab, the only state where a label and the dot
      # are in the same button. `shrink-0` is what makes the truncating label
      # give way first rather than the dot being squeezed out of the box.
      html = rail(active_tab: "chat", chat_unread: true)
      class = html |> dots() |> LazyHTML.attribute("class") |> List.first()

      assert class =~ ~r/\bshrink-0\b/, class
      refute class =~ ~r/\babsolute\b/, class

      # Structural, not a class check: the dot is a child of the Chat BUTTON
      # and a following sibling of its label, so it reads after the word.
      assert count(
               html,
               ~s([data-role="call-rail-tab"][data-tab="chat"] > [data-role="call-rail-tab-label"] ~ [data-role="call-rail-tab-unread-dot"])
             ) == 1
    end

    test "a caller that serves no Chat tab cannot be given a dot" do
      # There is nowhere honest to draw it: the pane it points at does not
      # exist on that surface.
      assert Enum.count(dots(rail(active_tab: "people", chat: [], chat_unread: true))) == 0
      assert Enum.count(dots(rail(active_tab: "people", chat_unread: true))) == 1
    end

    test "false is the default, so a caller that forgets the attr under-reports" do
      assert Enum.count(dots(rail(active_tab: "transcript"))) == 0
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

    test "Chat mounts its pane wrapper once, on every tab, and hides it off-tab" do
      # Mirrors the transcript contract above, for a harder case: this
      # wrapper will hold a `live_render` of a nested LiveView. A branch
      # that unmounts it kills the child process, its message stream and
      # the reader's scroll position, so the wrapper is present on EVERY
      # tab (count == 1, never 0) and what flips is `hidden`.
      for tab <- ~w(people chat canvas transcript) do
        html = rail(active_tab: tab)

        assert count(html, ~s([data-role="call-rail-chat-wrap"])) == 1, tab

        assert count(
                 html,
                 ~s([data-role="call-rail-chat-wrap"][data-active="#{tab == "chat"}"])
               ) == 1,
               tab

        hidden = count(html, ~s([data-role="call-rail-chat-wrap"][hidden]))
        assert hidden == if(tab == "chat", do: 0, else: 1), tab
      end
    end

    test "the chat slot's own DOM survives every tab, it is not re-rendered per tab" do
      # The wrapper being present proves nothing on its own — an empty
      # wrapper would pass the test above. This asserts the SLOT CONTENT,
      # the thing whose unmounting is the actual defect.
      for tab <- ~w(people chat canvas transcript) do
        html = rail(active_tab: tab, chat: chat_slot("MOUNTED CHAT PANE"))

        assert html =~ "MOUNTED CHAT PANE", tab
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
      do:
        Regex.scan(
          ~r/(?:\S+:)?text-(?:xs|sm|base|\[\d+(?:\.\d+)?px\])(?![\w\/-])/,
          class
        )

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

    # The tab strip is the one place the rail leaves 11px, and it is a
    # DESIGN RULING rather than drift: 12.5px matches the size the
    # transcript pane already uses for its own utility copy (design canvas
    # 01a084be, "Type"), and the four-up strip was measured at that size
    # rather than at 11px, because the size is what decides whether four
    # labels fit in 312px.
    test "the tab labels are 12.5px, unconditionally, and selection carries weight" do
      html = rail(active_tab: "canvas")

      classes = class_of(html, ~s([data-role="call-rail-tab"]))
      assert length(classes) == 4

      for class <- classes do
        assert size_utilities(class) == [["text-[12.5px]"]], class
        refute class =~ "text-[11px]"
      end

      active = class_of(html, ~s([data-role="call-rail-tab"][data-active="true"]))
      assert length(active) == 1
      assert hd(active) =~ "font-semibold"

      inactive = class_of(html, ~s([data-role="call-rail-tab"][data-active="false"]))
      assert length(inactive) == 3

      for class <- inactive do
        assert class =~ "font-medium"
        refute class =~ "font-semibold"

        # `/40` is the DISABLED treatment on this rail and an inactive tab
        # is not disabled (design canvas 01a084be, "Palette").
        assert class =~ "text-base-content/60"
        refute class =~ "text-base-content/40"
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
