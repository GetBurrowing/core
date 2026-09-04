defmodule PlatformWeb.Chat.PartialsMeetingPanelTest do
  @moduledoc """
  Tests for the `meeting_panel/1` and screen-share button wiring in
  `PlatformWeb.Chat.Partials` (task 019e420f stages 2 + 3).

  These cover the chat-surface Quick Meet panel only — the dedicated
  `/meetings/:slug` LiveView is covered by `PlatformWeb.MeetingLiveTest`.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PlatformWeb.ChatLive.Partials

  defp render_panel(assigns) do
    assigns =
      Map.merge(
        %{
          in_meeting: true,
          active_space: %{name: "Test Space"},
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false,
          meeting_participants: [],
          active_meeting_tab: "people",
          rail_open: false,
          meeting: nil,
          agents_by_id: %{},
          agent_activity: nil,
          candidates: [],
          candidates_closed: [],
          candidate_events: %{},
          candidate_error: nil,
          captions_available: true,
          invite_rows: []
        },
        assigns
      )

    ~H"""
    <Partials.meeting_panel
      in_meeting={@in_meeting}
      active_space={@active_space}
      mic_enabled={@mic_enabled}
      camera_enabled={@camera_enabled}
      screen_share_enabled={@screen_share_enabled}
      meeting_participants={@meeting_participants}
      active_meeting_tab={@active_meeting_tab}
      rail_open={@rail_open}
      meeting={@meeting}
      agents_by_id={@agents_by_id}
      agent_activity={@agent_activity}
      candidates={@candidates}
      candidates_closed={@candidates_closed}
      candidate_events={@candidate_events}
      candidate_error={@candidate_error}
      captions_available={@captions_available}
      invite_rows={@invite_rows}
    />
    """
    |> rendered_to_string()
  end

  describe "screen-share button wiring (stage 2)" do
    test "desktop share button uses MeetingShareButton hook, not phx-click" do
      html = render_panel(%{})

      # The desktop variant carries the stable id + hook attribute. The
      # JS hook handles the click client-side so the user-activation
      # gesture survives the call into `getDisplayMedia()`.
      assert html =~ ~s(id="meeting-share-btn-desktop")
      assert html =~ ~s(phx-hook="MeetingShareButton")

      # The old `phx-click="meeting_toggle_screen_share"` MUST NOT live
      # on this button anymore — a phx-click would race the hook and
      # double-toggle, and worse the round-trip would kill the gesture.
      refute html =~
               ~r/id="meeting-share-btn-desktop"[^>]*phx-click="meeting_toggle_screen_share"/
    end

    test "mobile share button uses MeetingShareButton hook" do
      html = render_panel(%{})

      assert html =~ ~s(id="meeting-share-btn-mobile")

      # Both share buttons have a `data-role` so JS / tests can find
      # them by intent rather than chrome-specific selectors.
      assert html =~ ~s(data-role="meeting-share-button")
    end

    test "mic + camera + leave buttons still use phx-click (only share moved)" do
      html = render_panel(%{})

      # We're isolating ONE button-class change. The neighbors must
      # still be server-driven (no gesture concerns there).
      assert html =~ ~s(phx-click="meeting_toggle_mic")
      assert html =~ ~s(phx-click="meeting_toggle_camera")
      assert html =~ ~s(phx-click="meeting_leave")
    end
  end

  describe "screen-share preview slot (stage 3)" do
    test "renders desktop screen-share preview slot above the participants grid" do
      html = render_panel(%{})

      # The slot is the dedicated render target for incoming screen-
      # share tracks (`meeting_client.js` `_attachScreenShareTrack`). It
      # must be present so the JS hook has somewhere to attach the
      # `<video>` element instead of jamming it into a participant tile.
      assert html =~ ~s(data-quickmeet-screen-share-slot)
      assert html =~ ~s(data-pane="desktop")
      assert html =~ ~s(id="meeting-screen-share-slot-desktop")

      # `phx-update="ignore"` so the LV doesn't blow away the live
      # `<video>` element on re-render — JS owns those children.
      assert html =~
               ~r/data-quickmeet-screen-share-slot[^>]*phx-update="ignore"|phx-update="ignore"[^>]*data-quickmeet-screen-share-slot/

      # Starts hidden (no active share). The hook clears `hidden` when
      # it attaches a track.
      assert html =~
               ~r/data-quickmeet-screen-share-slot[^>]*class="[^"]*hidden/
    end

    test "renders mobile screen-share preview slot" do
      html = render_panel(%{})

      assert html =~ ~s(id="meeting-screen-share-slot-mobile")
      assert html =~ ~s(data-pane="mobile")
    end

    test "renders the sharer-name label slot for each preview" do
      html = render_panel(%{})

      # JS writes the sharer's display name here when the track lands.
      assert html =~ ~s(data-quickmeet-screen-share-sharer)
    end

    test "screen-share slots only render when in a meeting" do
      html = render_panel(%{in_meeting: false})

      # The whole panel disappears when not in a meeting; the screen-
      # share slot follows. (`:if={@in_meeting}` gate on the panel root.)
      refute html =~ ~s(data-quickmeet-screen-share-slot)
    end
  end

  describe "local self-view parking slot + dock (v4 stage 2)" do
    test "renders the desktop local self-view parking slot with a DISTINCT id" do
      html = render_panel(%{})

      # The page-level MeetingClient hook births the persistent local
      # <video> in `[data-role="local-self-view"]`. The quick-meet panel
      # must carry a parking slot (was absent → local <video> orphaned).
      assert html =~ ~s(id="quickmeet-local-self-view")
      assert html =~ ~s(data-role="local-self-view")

      # DISTINCT from MeetingLive's `meeting-local-self-view` so the two
      # surfaces never collide on a duplicate id when both are in the DOM.
      refute html =~ ~s(id="meeting-local-self-view")

      # phx-update="ignore" so the LV patch never wipes the hook's <video>.
      assert html =~
               ~r/id="quickmeet-local-self-view"[^>]*phx-update="ignore"|phx-update="ignore"[^>]*id="quickmeet-local-self-view"/
    end

    test "renders the desktop gallery dock the hook reparents the <video> into" do
      html = render_panel(%{})

      # The quick-meet panel is single-layout (no MeetingLive stage modes),
      # so it gets ONE dock with data-dock-mode="gallery" — the mode
      # `_currentStageMode()` defaults to when no center-stage is present.
      assert html =~ ~s(id="quickmeet-local-video-dock")
      assert html =~ ~s(data-local-video-dock)
      assert html =~ ~s(data-dock-mode="gallery")
    end

    test "renders the mobile parking slot + dock with mobile pane markers" do
      html = render_panel(%{})

      # Both desktop and mobile quick-meet variants coexist in the DOM;
      # the hook picks the visible pane via data-pane + matchMedia.
      assert html =~ ~s(id="quickmeet-local-self-view-mobile")
      assert html =~ ~s(id="quickmeet-local-video-dock-mobile")
      assert html =~ ~s(data-pane="mobile")
      assert html =~ ~s(data-pane="desktop")
    end

    test "parking slot + dock only render when in a meeting" do
      html = render_panel(%{in_meeting: false})

      refute html =~ ~s(id="quickmeet-local-self-view")
      refute html =~ ~s(data-local-video-dock)
    end
  end

  # ── The shared call rail (task 01a05b14 stage 6) ──────────────────────
  #
  # The hand-rolled `meeting_roster` is GONE. The People pane of
  # `CallShell.call_rail/1` — the same component `/meetings` renders —
  # is the quickmeet's participant surface now, which is the whole
  # point of the stage: one screen, two surfaces.
  #
  # Every assertion below is SCOPED to `[data-component="call-rail"]`.
  # `participant_rail.ex` and the meeting bottom strip both emit
  # `[data-section="agents"]`, so a document-wide query proves nothing
  # about which surface it found.
  describe "call rail — People pane (stage 6)" do
    defp within(html, selector) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
    end

    defp count(html, selector), do: html |> within(selector) |> Enum.count()

    defp text(html, selector), do: html |> within(selector) |> LazyHTML.text()

    test "renders each human participant by REAL display_name, never the literal 'User'" do
      participants = [
        %{
          id: Ecto.UUID.generate(),
          participant_id: Ecto.UUID.generate(),
          participant_type: "user",
          display_name: "Dev Alice",
          avatar_url: nil
        },
        %{
          id: Ecto.UUID.generate(),
          participant_id: Ecto.UUID.generate(),
          participant_type: "user",
          display_name: "Dev Bob",
          avatar_url: nil
        }
      ]

      html = render_panel(%{meeting_participants: participants})

      names =
        text(
          html,
          ~s([data-component="call-rail"] [data-section="humans"] [data-role="participant-name"])
        )

      assert names =~ "Dev Alice"
      assert names =~ "Dev Bob"
      refute html =~ ">User<"
    end

    test "humans AND agents both surface, in their own sections" do
      agent_id = Ecto.UUID.generate()

      participants = [
        %{
          id: Ecto.UUID.generate(),
          participant_id: Ecto.UUID.generate(),
          participant_type: "user",
          display_name: "Dev Alice",
          avatar_url: nil
        },
        %{
          id: Ecto.UUID.generate(),
          participant_id: agent_id,
          participant_type: "agent",
          display_name: "Higgins",
          avatar_url: nil
        }
      ]

      html = render_panel(%{meeting_participants: participants})

      assert count(
               html,
               ~s([data-component="call-rail"] [data-section="humans"] li[data-participant-type="user"])
             ) == 1

      assert count(
               html,
               ~s([data-component="call-rail"] [data-section="agents"] li[data-participant-type="agent"])
             ) == 1

      assert text(html, ~s([data-component="call-rail"] [data-section="agents"])) =~ "Higgins"
    end

    test "an unresolved identity falls through to 'Unknown participant', not 'User'" do
      participants = [
        %{
          id: Ecto.UUID.generate(),
          participant_id: nil,
          participant_type: "user",
          display_name: nil,
          avatar_url: nil
        }
      ]

      html = render_panel(%{meeting_participants: participants})

      assert html =~ "Unknown participant"
      refute html =~ ">User<"
    end

    test "the JS-owned media grid still renders alongside the rail (coexistence)" do
      html = render_panel(%{meeting_participants: []})

      assert count(html, ~s([data-component="call-rail"])) == 1
      assert html =~ ~s(id="meeting-participants")
    end

    test "the rail only renders when in a meeting" do
      html = render_panel(%{in_meeting: false, meeting_participants: []})

      assert count(html, ~s([data-component="call-rail"])) == 0
    end
  end

  # EXACTLY ONE rail across BOTH breakpoint subtrees. Same shape as the
  # caption-host count below and for the same reason: the `hidden
  # lg:flex` desktop panel and the `lg:hidden` mobile overlay are both
  # in the document at once, so a rail authored inside each would give
  # two `#quickmeet-call-rail`s, two `MeetingTranscript` hooks and two
  # sets of candidate buttons.
  describe "one rail, hoisted out of both breakpoint subtrees (stage 6)" do
    test "renders exactly one call rail even though both panes are present" do
      html = render_panel(%{})

      # Anti-vacuity: both subtrees really are emitted, so a count of 1
      # is a hoist and not a missing panel.
      assert html =~ ~s(id="meeting-share-btn-desktop")
      assert html =~ ~s(id="meeting-share-btn-mobile")

      assert count(html, ~s([data-component="call-rail"])) == 1
      assert count(html, ~s(#quickmeet-call-rail)) == 1
    end

    # The Transcript pane's `MeetingTranscript` hook writes committed
    # caption lines into a `phx-update="ignore"` log. TWO of them across
    # the two breakpoint subtrees would mean one utterance rendered into
    # two logs, half of them off-screen — the exact defect the caption
    # host was hoisted to fix in task 019ff712.
    test "the Transcript pane hosts exactly one MeetingTranscript hook" do
      html = render_panel(%{active_meeting_tab: "transcript"})

      assert count(html, ~s([data-component="call-rail"] [phx-hook="MeetingTranscript"])) == 1
      assert count(html, ~s([phx-hook="MeetingTranscript"][phx-update="ignore"])) == 1
      assert count(html, ~s([data-role="meeting-transcript"])) == 1
    end

    # Task 01a06524 stage 1. The host is present on EVERY tab, not only
    # Transcript — this REPLACES the "toggling adds/removes the host"
    # contract on purpose. A host that leaves the DOM on People is a hook
    # LiveView destroys, and a destroyed hook is a lost buffer. What flips
    # is `hidden` on the outer wrap LiveView owns; under
    # `phx-update="ignore"` a flip on the host itself never reaches the
    # DOM. `mix test` sees the markup; that the browser keeps the lines
    # across the flip is the e2e's to prove.
    test "the transcript host persists on the People tab, hidden by the wrap" do
      for tab <- ~w(people canvas transcript) do
        html = render_panel(%{active_meeting_tab: tab})

        assert count(html, ~s([data-role="meeting-transcript"])) == 1, tab
        assert count(html, ~s([phx-hook="MeetingTranscript"])) == 1, tab
        assert count(html, ~s([data-role="meeting-transcript-wrap"])) == 1, tab

        expected_hidden = if(tab == "transcript", do: 0, else: 1)

        assert count(html, ~s([data-role="meeting-transcript-wrap"][hidden])) == expected_hidden,
               tab

        assert count(
                 html,
                 ~s([data-role="meeting-transcript-wrap"][data-active="#{tab == "transcript"}"])
               ) == 1,
               tab
      end
    end

    test "the rail carries the three tabs, People active by default" do
      html = render_panel(%{})

      labels = text(html, ~s([data-component="call-rail"] [data-role="call-rail-tab"]))
      assert labels =~ "People"
      assert labels =~ "Canvas"
      assert labels =~ "Transcript"
      assert count(html, ~s([data-component="call-rail"] [data-role="call-rail-tab"])) == 3

      assert count(
               html,
               ~s([data-component="call-rail"] [data-role="call-rail-tab"][data-active="true"])
             ) == 1

      assert count(html, ~s([data-component="call-rail"] [data-tab="people"][data-active="true"])) ==
               1
    end

    test "tab clicks push the SAME event name /meetings pushes" do
      html = render_panel(%{})

      assert count(html, ~s([data-role="call-rail-tab"][phx-click="meeting_tab_select"])) == 3
    end

    test "the Canvas tab renders a seeded candidate rather than the People pane" do
      candidate = %Platform.Meetings.MeetingCandidate{
        id: Ecto.UUID.generate(),
        state: :shaping,
        evidence_quote: "Someone should write the migration guide",
        classified_intent: "action_item",
        transcript_chunk_ids: [Ecto.UUID.generate()],
        acts_at: nil,
        inserted_at: DateTime.utc_now()
      }

      html = render_panel(%{active_meeting_tab: "canvas", candidates: [candidate]})

      assert count(html, ~s([data-component="call-rail"] [data-pane-tab="canvas"])) == 1
      assert count(html, ~s([data-component="call-rail"] [data-section="humans"])) == 0
      assert html =~ "Someone should write the migration guide"
    end
  end

  # The mobile overlay's JS-owned regions are `meeting_client.js`'s
  # reparent contract: it picks the VISIBLE pane via matchMedia, so the
  # mobile ids must survive the shell move byte-for-byte. Asserted one
  # id at a time — a single combined assertion would let four of the
  # five vanish while still passing.
  describe "mobile overlay keeps every phx-update=ignore id (stage 6)" do
    for id <- [
          "meeting-participants",
          "meeting-participants-mobile",
          "meeting-media",
          "meeting-screen-share-slot-desktop",
          "meeting-screen-share-slot-mobile"
        ] do
      test "##{id} survives with phx-update=ignore" do
        html = render_panel(%{})

        assert count(html, ~s(##{unquote(id)}[phx-update="ignore"])) == 1
      end
    end

    for id <- [
          "quickmeet-local-video-dock",
          "quickmeet-local-video-dock-mobile"
        ] do
      test "##{id} survives as a data-local-video-dock" do
        html = render_panel(%{})

        assert count(html, ~s(##{unquote(id)}[data-local-video-dock][phx-update="ignore"])) == 1
      end
    end
  end

  # ── Task 01a05b14 stage 3: the quickmeet tile grid fills its panel ──
  #
  # HARD CONSTRAINT, and the reason these assertions look thin: both
  # `#meeting-participants` grids are `phx-update="ignore"` and their
  # CHILDREN are built by `meeting_client.js`. So every layout rule has to
  # live on the CONTAINER, and the container is all a server render can
  # see -- there are zero tiles here, and zero is CORRECT, not a failure.
  # `meeting_client.js` was NOT edited by this stage; the column rule is
  # CSS keyed off child count with `:has()` precisely so it need not be.
  describe "quickmeet participant grid (stage 3)" do
    for id <- ["meeting-participants", "meeting-participants-mobile"] do
      test "##{id} keeps its grid class on the ignored container, full width" do
        html = render_panel(%{})

        el = within(html, ~s(##{unquote(id)}))
        [class] = LazyHTML.attribute(el, "class")

        # The class the CSS column rules hang off.
        assert class =~ "meeting-participant-grid"
        # Fill the panel rather than sitting in it. The pre-stage-3 CSS
        # clamped a lone tile to a centred 480px, which is the same
        # "floating card" defect /meetings had.
        assert class =~ "w-full"
        # The canvas's 10px gutter.
        assert class =~ "gap-2.5"

        # Still JS-owned, still ignored.
        assert count(html, ~s(##{unquote(id)}[phx-update="ignore"])) == 1
      end
    end
  end

  # ── Task 01a05b14 stage 2: the control bar, and Leave not clipped ──
  #
  # The shipped 1280 capture showed Leave cut off by the `w-80` panel's
  # right edge. Four labelled pills do not fit a ~288px content box, so
  # the bar degrades by dropping label TEXT rather than by pushing a
  # control out of the box -- a CONTAINER query in app.css keyed on the
  # bar's own width, since one viewport gives this component a 712px
  # bar on /meetings and a 319px one here.
  #
  # WHAT THESE TESTS CAN AND CANNOT SEE, stated rather than implied: a
  # LiveViewTest render has no layout engine, so it can pin that every
  # label is a `.call-control-label` (the hook the CSS needs) and that
  # `aria-label` survives -- and it CANNOT pin that the label is
  # actually hidden or that Leave fits. That is measured by DOM probe
  # at capture time and is in the stage evidence, not here.
  describe "quickmeet control bar (stage 2)" do
    test "the desktop bar is a centred 46px row whose labels can collapse" do
      html = render_panel(%{})

      bar =
        ~s([id="meeting-panel"] [data-component="call-controls"])

      assert count(html, bar) == 1

      el = within(html, bar)
      [class] = LazyHTML.attribute(el, "class")
      assert class =~ "h-[46px]"
      assert class =~ "justify-center"

      # The degradation hides the LABEL, never the button: every role
      # and the accessible name survive, which is the whole point of
      # degrading this way instead of overflowing.
      assert count(html, ~s(#{bar} [data-role="meeting-leave"])) == 1
      assert count(html, ~s(#{bar} [data-role="meeting-mic"])) == 1
      assert count(html, ~s(#{bar} [data-role="meeting-camera"])) == 1
      assert count(html, ~s(#{bar} [data-role="meeting-share-button"])) == 1

      leave = within(html, ~s(#{bar} [data-role="meeting-leave"]))
      assert LazyHTML.attribute(leave, "aria-label") == ["Leave the call"]

      # Every label carries the class the container query keys on. If
      # this drifts the CSS silently stops applying and Leave is
      # clipped again, with nothing else failing.
      assert count(html, ~s(#{bar} .call-control-label)) == 4
    end

    test "the mobile overlay keeps its labels and its safe-area clearance" do
      html = render_panel(%{})

      bar = ~s([data-role="meeting-share-button"][id="meeting-share-btn-mobile"])
      assert count(html, bar) == 1

      mobile =
        html
        |> within(~s([data-component="call-controls"]))
        |> LazyHTML.attribute("class")
        |> Enum.find(&(&1 =~ "safe-area-bottom"))

      assert mobile =~ "justify-center"
      assert mobile =~ "min-h-[46px]"
    end

    # The Share button's identity is what a hook `pushEvent` resolves
    # against, and `pushEvent` ignores `phx-target`. Both panes keep
    # their own stable id and the hook.
    test "both share buttons keep their id and hook after the move" do
      html = render_panel(%{})

      for id <- ~w(meeting-share-btn-desktop meeting-share-btn-mobile) do
        el = within(html, ~s(##{id}))
        assert LazyHTML.attribute(el, "phx-hook") == ["MeetingShareButton"]
        assert LazyHTML.attribute(el, "data-role") == ["meeting-share-button"]
      end
    end
  end

  # TASK 01a064fa STAGE 1. The quickmeet's stage column and tile grid
  # were both anonymous divs, so the geometric gate had nothing to
  # measure. The grid marker goes on `#meeting-participants` /
  # `#meeting-participants-mobile` — the `phx-update="ignore"`
  # CONTAINER, which LiveView still renders — and NEVER on a child,
  # because meeting_client.js owns the children and a server-rendered
  # child inside an ignored node never survives.
  #
  # Asserted as a DESCENDANT selector rather than two presence checks:
  # a grid that renders outside its stage column is the
  # wired-into-the-wrong-parent defect this task exists to catch, and
  # two independent presence checks pass on it.
  describe "call-stage / call-tile-grid markers (task 01a064fa)" do
    defp sel_count(html, selector) do
      html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
    end

    test "both panes carry one stage column and one tile grid, grid inside stage" do
      html = render_panel(%{})

      # Two panes are in the document at once (one hidden by CSS at the
      # lg breakpoint), so two of each is the correct count here — the
      # browser-side helper disambiguates by rect, which is why it must
      # never fall back to `.first()`.
      assert sel_count(html, ~s([data-role="call-stage"])) == 2
      assert sel_count(html, ~s([data-role="call-tile-grid"])) == 2

      assert sel_count(html, ~s([data-role="call-stage"] [data-role="call-tile-grid"])) == 2,
             "a tile grid renders outside its stage column"
    end

    test "each pane's stage and grid are the pane's own, not the other's" do
      html = render_panel(%{})

      for pane <- ~w(desktop mobile) do
        assert sel_count(html, ~s([data-role="call-stage"][data-pane="#{pane}"])) == 1
      end

      assert sel_count(
               html,
               ~s([data-role="call-stage"][data-pane="desktop"] #meeting-participants[data-role="call-tile-grid"])
             ) == 1

      assert sel_count(
               html,
               ~s([data-role="call-stage"][data-pane="mobile"] #meeting-participants-mobile[data-role="call-tile-grid"])
             ) == 1
    end

    # The marker is on the ignored CONTAINER. If a future stage moves it
    # to a child it would stop rendering entirely, and a presence check
    # on the container would keep passing.
    test "the grid marker sits on the phx-update=ignore container itself" do
      html = render_panel(%{})

      assert sel_count(html, ~s([phx-update="ignore"][data-role="call-tile-grid"])) == 2
    end

    # `data-component="call-controls"` already exists on the shared
    # component and is the marker the placement assertion uses. Pinned
    # so nobody adds a second spelling: two spellings for one thing means
    # the harness starts passing on whichever happens to be present.
    test "the controls marker is the existing data-component, singular per pane" do
      html = render_panel(%{})

      assert sel_count(html, ~s([data-component="call-controls"])) == 2
      assert sel_count(html, ~s([data-role="call-controls"])) == 0
    end
  end

  # The badge WORD, not a colour and not a class. `AgentActivityBadge`'s
  # contract is ring + glyph + word.
  describe "agent activity reaches the quickmeet People pane (stage 6)" do
    test "an agent with a :computing signal renders the Thinking word in the rail" do
      agent_id = Ecto.UUID.generate()

      participants = [
        %{
          id: Ecto.UUID.generate(),
          participant_id: agent_id,
          participant_type: "agent",
          display_name: "Higgins",
          avatar_url: nil
        }
      ]

      idle = render_panel(%{meeting_participants: participants})

      # Anti-vacuity. The word is now present on EVERY row — `:idle` is a
      # resolved state with a real producer and the rail draws it — so
      # "the element exists" no longer distinguishes a signal from its
      # absence. The stronger form is asserted instead: with no activity
      # the word reads "Idle", so the assertion below is about the
      # SIGNAL and not about the agent merely being seated.
      assert text(idle, ~s([data-component="call-rail"] [data-role="agent-activity-word"])) =~
               "Idle"

      refute text(idle, ~s([data-component="call-rail"] [data-role="agent-activity-word"])) =~
               "Thinking"

      activity =
        Platform.Meetings.AgentActivity.put(
          Platform.Meetings.AgentActivity.new(),
          :computing,
          agent_id,
          true
        )

      busy = render_panel(%{meeting_participants: participants, agent_activity: activity})

      assert text(busy, ~s([data-component="call-rail"] [data-role="agent-activity-word"])) =~
               "Thinking"
    end
  end

  # Task 019ff712 stage 2 — ONE caption host per panel render.
  #
  # `render_panel/1` renders `meeting_panel/1` in its PRODUCTION shape:
  # both breakpoint subtrees are emitted into the same document (one is
  # hidden by CSS at any given width), which is exactly the condition
  # that used to produce two `MeetingCaptions` hosts. A cut-down render
  # of a single container would pass against the two-host markup too and
  # would prove nothing.
  #
  # Task 01a05b14 stage 5, round 2. At 390px the COLLAPSED rail sheet
  # peeked `--bottom-nav-height` (56px) into the viewport and painted
  # over the mobile overlay's control bar: `translate-y-full` shifts the
  # sheet by its own height only, and the sheet's bottom edge already
  # sits `nav + safe-area` above the viewport's. `elementFromPoint` on
  # Leave answered the Transcript tab. These assert the CLASS CONTRACT —
  # geometry is not available to a LiveView test, so the pixel proof is
  # the e2e case (01a064de-9649-700e); what a unit test can pin is that
  # the transform the e2e measures is the one in the markup.
  describe "collapsed rail sheet clears the control bar (stage 5 round 2)" do
    @collapsed_transform "translate-y-[calc(100%+env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))]"

    defp host_class(html) do
      [class] = html |> within("#quickmeet-call-rail-host") |> LazyHTML.attribute("class")
      class
    end

    test "collapsed: the sheet is offset by its height PLUS the nav + safe-area it sits on" do
      html = render_panel(%{rail_open: false})
      class = host_class(html)

      assert class =~ @collapsed_transform
      # The offset is computed from the same clearance the sheet's
      # bottom edge uses, so the two cannot drift apart.
      assert class =~ "bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))]"
      # `translate-y-full` is the exact class that produced the peek.
      refute class =~ "translate-y-full"
      # Belt for the brace: nothing under the collapsed sheet is
      # intercepted even mid-transition, and the desktop column — where
      # the sheet is in flow and `rail_open` is meaningless — gets its
      # clicks back.
      assert class =~ "pointer-events-none"
      assert class =~ "lg:pointer-events-auto"
      assert class =~ "lg:translate-y-0"

      [open] = html |> within("#quickmeet-call-rail-host") |> LazyHTML.attribute("data-rail-open")
      assert open == "false"
    end

    test "open: the sheet slides to its resting place and takes pointer events again" do
      html = render_panel(%{rail_open: true})
      class = host_class(html)

      assert class =~ "translate-y-0"
      refute class =~ @collapsed_transform
      refute class =~ "pointer-events-none"

      [open] = html |> within("#quickmeet-call-rail-host") |> LazyHTML.attribute("data-rail-open")
      assert open == "true"
    end

    test "the sheet is a sibling of the mobile overlay, not a child of the control bar's tree" do
      html = render_panel(%{rail_open: false})

      overlay = ~s([data-role="quickmeet-mobile-overlay"])
      assert count(html, overlay) == 1

      # Positive control for the descendant selector: the mobile Leave
      # button IS inside the overlay. Without this the zero below could
      # be a selector that matches nothing.
      assert count(html, ~s(#{overlay} [data-role="meeting-leave"])) == 1
      assert count(html, ~s(#{overlay} [data-role="quickmeet-rail-toggle"])) == 1

      # The host is hoisted out of both breakpoint subtrees — it does not
      # share the overlay's stacking context, so its `z-[55]` and its
      # transform are the only things deciding whether it sits over the
      # bar. That is what makes the collapsed offset above sufficient.
      assert count(html, ~s(#{overlay} #quickmeet-call-rail-host)) == 0
      assert count(html, ~s(#quickmeet-call-rail-host [data-role="meeting-leave"])) == 0
      assert count(html, "#quickmeet-call-rail-host") == 1

      # And the toggle that opens the sheet stays outside it, so a
      # collapsed, pointer-inert sheet can still be opened.
      assert count(html, ~s(#quickmeet-call-rail-host [data-role="quickmeet-rail-toggle"])) == 0
    end
  end

  # Counted with LazyHTML, not with `=~`: `LazyHTML.query/2` returns a
  # struct and is NEVER falsy, so `if result do` and `result == []` are
  # both wrong — the nodes have to be counted.
  # ── The invite section reaches the quickmeet (task 01a0691d stage 2) ───
  #
  # The quickmeet used to pass no `invite_event`, which removed the block
  # entirely. It now renders `CallShell.invite_section/1` against
  # `quickmeet_invite_agent` — unconditionally, so a space with no agents
  # still shows the heading and the line explaining the emptiness.
  describe "the invite section on the quickmeet" do
    defp invite_row(id, state, capability) do
      %{
        agent: %{id: id, name: "Agent " <> id, slug: "agent-" <> id},
        state: state,
        capability: capability
      }
    end

    test "renders in the rail with the empty line when there are no rows" do
      html = render_panel(%{invite_rows: []})

      assert count(html, ~s(#quickmeet-call-rail [data-role="meeting-agent-invite"])) == 1

      assert text(html, ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-empty"]))
             |> String.replace(~r/\s+/, " ")
             |> String.trim() ==
               "No agents in this space yet. Add one to the space and it appears here, without a reload."

      refute html =~ ~s(data-role="meeting-agent-invite-row")
    end

    test "an invitable row offers the quickmeet's own invite event" do
      html = render_panel(%{invite_rows: [invite_row("a-1", :invitable, :capable)]})

      buttons =
        within(html, ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-button"]))

      assert LazyHTML.attribute(buttons, "phx-click") == ["quickmeet_invite_agent"]
      assert LazyHTML.attribute(buttons, "phx-value-agent-id") == ["a-1"]
      refute html =~ ~s(data-role="meeting-agent-invite-empty")
    end

    test "a disabled row is listed with its reason and no control" do
      html = render_panel(%{invite_rows: [invite_row("a-2", :incapable, :incapable)]})

      selector =
        ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-row"][data-agent-id="a-2"])

      assert count(html, selector) == 1
      assert count(html, selector <> ~s([data-invite-state="incapable"])) == 1

      assert text(html, selector <> ~s( [data-role="meeting-agent-invite-reason"]))
             |> String.trim() ==
               "No voice runtime online"

      row = html |> within(selector) |> LazyHTML.to_html()
      refute row =~ "<button"
      refute row =~ "phx-click"
    end

    test "the section is absent when not in a meeting, like the rest of the rail" do
      html = render_panel(%{in_meeting: false, invite_rows: []})
      refute html =~ ~s(data-role="meeting-agent-invite")
    end
  end

  describe "single caption host (stage 2)" do
    defp caption_hosts(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([phx-hook="MeetingCaptions"]))
      |> Enum.count()
    end

    test "renders exactly one MeetingCaptions host across both breakpoint subtrees" do
      html = render_panel(%{})

      # Anti-vacuity: the production shape really does emit both
      # subtrees, so a count of 1 is a collapse and not a missing panel.
      assert html =~ ~s(id="meeting-share-btn-desktop")
      assert html =~ ~s(id="meeting-share-btn-mobile")

      assert caption_hosts(html) == 1
      assert html =~ ~s(id="meeting-captions")
      assert html =~ ~s(data-role="meeting-captions")
    end

    test "the single host is hoisted out of the breakpoint-scoped subtrees" do
      html = render_panel(%{})

      # The old per-breakpoint host lived inside the desktop rail /
      # mobile overlay. The hoisted one is a fixed-position sibling of
      # both, so it is legible at either width rather than swapping.
      host =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-captions"]))

      assert Enum.count(host) == 1

      classes = host |> LazyHTML.attribute("class") |> List.first()
      assert classes =~ "fixed"
      # ONE bottom offset, unprefixed, so the host clears the control row
      # at both widths — measured over CDP against both control rows.
      assert classes =~ "bottom-32"
      refute classes =~ "lg:bottom-"
      # Pinned inside the w-96 desktop rail at lg, full-bleed below it.
      assert classes =~ "lg:right-3"
      assert classes =~ "inset-x-4"
    end

    test "the host carries phx-update=ignore so a patch cannot wipe committed lines" do
      html = render_panel(%{})

      update =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-captions"]))
        |> LazyHTML.attribute("phx-update")

      assert update == ["ignore"]
    end

    test "no caption host at all when not in a meeting" do
      html = render_panel(%{in_meeting: false})

      assert caption_hosts(html) == 0
      refute html =~ ~s(data-role="meeting-captions")
    end
  end
end
