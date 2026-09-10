defmodule PlatformWeb.MeetingLiveRailCollapseTest do
  @moduledoc """
  Task `01a0740d` stage 1 — the meetings right rail's collapse default
  follows what the STAGE is showing, and collapsing it does not silently
  hide that a message arrived.

  Server state only. Stage 1 ships no rendering, so every assertion here
  reads the socket's assigns through `:sys.get_state/1` (the established
  pattern in `chat_live_external_rail_test.exs`, `meeting_hooks_*_test.exs`
  and a dozen others) rather than the DOM. Stage 2 renders these assigns.

  ## The two things this file exists to stop

  **1. The screen-share path shipping half-dead.** There are TWO code paths
  that change `:current_stage_mode`, and only one of them is the one that
  runs on `/meetings`. `PlatformWeb.ChatLive.MeetingHooks.handle_event/3` is
  attached as a `:handle_event` hook and returns `:halt` for
  `"meeting_screen_share_state"`, so `MeetingLive`'s own clause for that
  event is a BACKSTOP THAT NEVER RUNS ON THIS ROUTE. A reassert written only
  in `meeting_live.ex` would pass a unit test of the backstop and do nothing
  at all when somebody actually shares their screen. The screen-share tests
  below therefore drive the event through a real `/meetings/:slug` mount,
  where the hook is attached, and they red if the reassert is removed from
  `meeting_hooks.ex` alone.

  **2. The unread flag being asserted into existence.** A test that assigns
  a truthy value and then reads it back proves nothing. Every unread
  assertion here is driven by a REAL `Platform.Chat.post_message/2` insert,
  whose `publish_message_posted/2` broadcasts `{:new_message, %Message{}}`
  on `chat:space:<id>` — the topic `MeetingLive` already holds via
  `SpaceTopics.hold(socket, meeting.chat_space_id, :meeting)`. The message
  reaches the LiveView the same way a colleague's message does in
  production, or it does not reach it at all.

  Before this ticket `meeting_live.ex` had no `{:new_message, _}` clause and
  every one of these broadcasts fell into the trailing ignore-everything
  `handle_info(_event, socket)`. The clause under test must sit ABOVE that
  catch-all; if it is ever moved below it, these tests red.

  ## Route

  `live_session :meet_member` (`router.ex`), host prefix `meet.`. Reaching
  it needs BOTH the prefix (Phoenix `host:` routing) and the request host to
  equal the configured `:meet_host`, which `PlatformWeb.ExternalSurface`
  fails CLOSED when unset — a forgotten config would exercise the denial
  path and pass vacuously. `@meet_host` and the `setup` block satisfy both,
  mirroring `meeting_live_space_topic_holders_test.exs`.

  `async: false` — the file mutates application env.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.MeetingLive

  @meet_host "meet.example.com"

  # THE CONTRACT, spelled out per mode rather than derived. Gallery is the
  # only mode where the stage is not competing for the pixels, so it is the
  # only one that opens the rail. `:whiteboard` is not named in the ticket;
  # it is a full-stage surface like canvas, so it collapses.
  @rail_default_by_mode %{gallery: false, screen: true, canvas: true, whiteboard: true}

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # A render round-trip drains the LiveView mailbox up to this point, so a
  # broadcast published before it has been handled by the time it returns.
  # Never `Process.sleep/1` — that pins the box's timing, not the ordering.
  defp settle(view) do
    _ = render(view)
    view
  end

  # Put the rail into a known state through the PUBLIC chevron handler, so
  # each mode assertion below is a real transition rather than a value that
  # happened to already be right.
  defp force_collapsed(view, want) do
    if assigns(view).chat_panel_collapsed != want do
      render_click(view, "toggle_meeting_chat_pane", %{})
    end

    assert assigns(view).chat_panel_collapsed == want
    view
  end

  defp set_mode(view, mode) do
    render_click(view, "set_stage_mode", %{"mode" => to_string(mode)})
    view
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_rail_collapse_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  defp create_member!(org, label) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "rail-collapse-#{label}-#{n}@example.com",
        name: "RailCollapse #{label} #{n}",
        oidc_sub: "oidc-rail-collapse-#{label}-#{n}"
      })
      |> Repo.insert!()

    Repo.insert!(%OrgMembership{user_id: user.id, org_id: org.id, role: "member"})

    user
  end

  defp meeting!(org, label) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{name: "Rail Collapse #{label} #{n}", org_id: org.id})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Rail Collapse #{label} #{n}",
        slug: "rail-collapse-#{label}-#{n}"
      })

    meeting
  end

  defp join!(space_id, %User{} = user) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  # A REAL insert on a REAL space. `Chat.post_message/2` ends in
  # `publish_message_posted/2`, which broadcasts `{:new_message, msg}` on
  # `Platform.Chat.PubSub.space_topic(space_id)`. Nothing here hand-crafts a
  # message struct or hand-sends it to the view's pid.
  defp post!(space_id, participant, body) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "text",
        content: body
      })

    msg
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  defp on_meet_host(conn), do: %{conn | host: @meet_host}

  # The SHELL surface (default host, `live_session :authenticated`), where
  # `chrome_mode` falls back to `:shell` and `@shell?` is true. The
  # collapsed strip's Chat affordance and the expanded rail's chevron are
  # both `@shell?`-gated, so `meet.`-host mounts render neither and every
  # assertion about them would pass vacuously there.
  defp open_meeting_shell(conn, user, meeting) do
    {:ok, view, html} = conn |> login(user) |> live("/meetings/#{meeting.slug}")

    assert html =~ meeting.name
    assert :sys.get_state(view.pid).socket.assigns.shell? == true

    settle(view)
  end

  defp open_meeting(conn, user, meeting) do
    {:ok, view, html} =
      conn |> login(user) |> on_meet_host() |> live("/meetings/#{meeting.slug}")

    # ANTI-VACUITY: the room actually rendered. A denial card assigns none
    # of the state under test and would make several assertions below pass
    # for entirely the wrong reason.
    assert html =~ meeting.name

    settle(view)
  end

  setup do
    original_meet = Application.get_env(:platform, :meet_host)
    Application.put_env(:platform, :meet_host, @meet_host)

    original_livekit = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn ->
      Application.put_env(:platform, :livekit, original_livekit)

      case original_meet do
        nil -> Application.delete_env(:platform, :meet_host)
        value -> Application.put_env(:platform, :meet_host, value)
      end
    end)

    org = tenant_org!()
    viewer = create_member!(org, "viewer")

    %{org: org, viewer: viewer}
  end

  # ── (a) the mode -> default table ──────────────────────────────────────────

  describe "collapse default per stage mode" do
    test "the expectation table covers exactly stage_modes/0" do
      # If a fifth mode is added to `@stage_modes`, this reds rather than
      # letting the new mode quietly inherit whatever the walk below happened
      # not to check. `default_rail_collapsed?/1` has no catch-all, so the
      # new mode would also fail to compile — this is the second gate.
      assert MapSet.new(Map.keys(@rail_default_by_mode)) ==
               MapSet.new(MeetingLive.stage_modes()),
             "the per-mode contract in this file has drifted from " <>
               "MeetingLive.stage_modes/0: #{inspect(MeetingLive.stage_modes())}"
    end

    test "every stage mode yields a boolean collapse default, and gallery is the only open one",
         %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "modes")
      view = open_meeting(conn, viewer, meeting)

      for {mode, expected} <- @rail_default_by_mode do
        # Start from the OPPOSITE state so the assertion measures a
        # transition the mode change caused, not a coincidence.
        force_collapsed(view, not expected)
        set_mode(view, mode)

        actual = assigns(view).chat_panel_collapsed

        assert is_boolean(actual),
               "stage mode #{inspect(mode)} left :chat_panel_collapsed as " <>
                 "#{inspect(actual)} — the default table must be total and " <>
                 "must return a boolean for every mode in stage_modes/0"

        assert actual == expected,
               "stage mode #{inspect(mode)} should leave the rail " <>
                 "#{if expected, do: "COLLAPSED", else: "OPEN"} but " <>
                 ":chat_panel_collapsed was #{inspect(actual)}"

        assert assigns(view).current_stage_mode == mode
      end
    end
  end

  # ── (b) reassert, not remember ─────────────────────────────────────────────

  describe "a mode change REASSERTS the default over a manual toggle" do
    test "the manual collapse in gallery is overridden by switching back to gallery",
         %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "reassert-gallery")
      view = open_meeting(conn, viewer, meeting)

      assert assigns(view).current_stage_mode == :gallery
      assert assigns(view).chat_panel_collapsed == false

      # The viewer collapses it by hand.
      render_click(view, "toggle_meeting_chat_pane", %{})
      assert assigns(view).chat_panel_collapsed == true

      # Leaving and returning to gallery REASSERTS open. The manual override
      # is deliberately not remembered across a mode change.
      set_mode(view, :screen)
      assert assigns(view).chat_panel_collapsed == true

      set_mode(view, :gallery)

      assert assigns(view).chat_panel_collapsed == false,
             "switching back to gallery must reassert the rail OPEN — the " <>
               "mode's default wins over the viewer's last manual toggle"
    end

    test "the manual expand in screen mode is overridden by re-entering screen mode",
         %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "reassert-screen")
      view = open_meeting(conn, viewer, meeting)

      set_mode(view, :screen)
      assert assigns(view).chat_panel_collapsed == true

      render_click(view, "toggle_meeting_chat_pane", %{})
      assert assigns(view).chat_panel_collapsed == false

      set_mode(view, :gallery)
      set_mode(view, :screen)

      assert assigns(view).chat_panel_collapsed == true,
             "re-entering screen mode must reassert COLLAPSED"
    end

    test "an unknown mode reasserts nothing and stays a silent no-op",
         %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "unknown-mode")
      view = open_meeting(conn, viewer, meeting)

      # Collapse by hand while in gallery — a state the gallery default
      # would UNDO if an unknown mode wrongly reasserted.
      render_click(view, "toggle_meeting_chat_pane", %{})
      assert assigns(view).chat_panel_collapsed == true

      render_click(view, "set_stage_mode", %{"mode" => "admin_only"})

      assert assigns(view).current_stage_mode == :gallery

      assert assigns(view).chat_panel_collapsed == true,
             "an unknown mode must not reassert: a hand-crafted phx-click " <>
               "cannot be allowed to move the viewer's rail"
    end
  end

  # ── (b) the screen-share path, on the surface that actually runs it ────────

  describe "screen share auto-switch (through MeetingHooks, which halts)" do
    test "starting a share switches to :screen AND collapses the rail",
         %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "share-start")
      view = open_meeting(conn, viewer, meeting)

      assert assigns(view).current_stage_mode == :gallery
      assert assigns(view).chat_panel_collapsed == false

      render_hook(view, "meeting_screen_share_state", %{"enabled" => true})

      # Anti-vacuity: the event was really handled — the share flag moved.
      assert assigns(view).screen_share_enabled == true

      assert assigns(view).current_stage_mode == :screen

      assert assigns(view).chat_panel_collapsed == true,
             "starting a screen share must reassert the rail COLLAPSED. On " <>
               "/meetings this event is halted by " <>
               "PlatformWeb.ChatLive.MeetingHooks, so MeetingLive's own " <>
               "\"meeting_screen_share_state\" clause NEVER RUNS here — the " <>
               "reassert has to exist in meeting_hooks.ex too"

      assert assigns(view).call_rail_animate == false,
             "a share-driven width change must SNAP, not animate"
    end

    test "a share that starts over a manually-expanded rail still collapses it",
         %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "share-over-manual")
      view = open_meeting(conn, viewer, meeting)

      set_mode(view, :canvas)
      render_click(view, "toggle_meeting_chat_pane", %{})
      assert assigns(view).chat_panel_collapsed == false

      render_hook(view, "meeting_screen_share_state", %{"enabled" => true})

      assert assigns(view).current_stage_mode == :screen
      assert assigns(view).chat_panel_collapsed == true
    end

    test "stopping a share leaves the stage and the rail exactly where they were",
         %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "share-stop")
      view = open_meeting(conn, viewer, meeting)

      render_hook(view, "meeting_screen_share_state", %{"enabled" => true})
      assert assigns(view).chat_panel_collapsed == true

      # The viewer expands it by hand mid-share.
      render_click(view, "toggle_meeting_chat_pane", %{})
      assert assigns(view).chat_panel_collapsed == false

      render_hook(view, "meeting_screen_share_state", %{"enabled" => false})

      assert assigns(view).current_stage_mode == :screen,
             "the disable edge deliberately leaves the stage where the user put it"

      assert assigns(view).chat_panel_collapsed == false,
             "stopping a share must not yank the rail back — the disable " <>
               "edge reasserts nothing"
    end
  end

  # ── (c) snap vs animate ────────────────────────────────────────────────────

  describe "call_rail_animate: motion should say \"you\", never \"it\"" do
    test "false at mount, true on a chevron click, false again on a mode change",
         %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "animate")
      view = open_meeting(conn, viewer, meeting)

      assert assigns(view).call_rail_animate == false,
             "a first paint must never animate"

      render_click(view, "toggle_meeting_chat_pane", %{})

      assert assigns(view).call_rail_animate == true,
             "a chevron click is the one width change the viewer asked for"

      set_mode(view, :screen)

      assert assigns(view).call_rail_animate == false,
             "a mode-driven width change must snap: animating it slides a " <>
               "slab of the screen at someone whose attention is on the stage"

      # And it comes back on the next deliberate toggle rather than being
      # latched off.
      render_click(view, "toggle_meeting_chat_pane", %{})
      assert assigns(view).call_rail_animate == true
    end
  end

  # ── (d) the unread flag, driven by a real broadcast ────────────────────────

  describe "call_rail_unread" do
    setup %{org: org, viewer: viewer} do
      meeting = meeting!(org, "unread")
      viewer_participant = join!(meeting.chat_space_id, viewer)

      other = create_member!(org, "other")
      other_participant = join!(meeting.chat_space_id, other)

      %{
        meeting: meeting,
        viewer_participant: viewer_participant,
        other: other,
        other_participant: other_participant
      }
    end

    test "a message arriving while chat is NOT the pane on screen raises the flag",
         %{conn: conn, viewer: viewer, meeting: meeting, other_participant: other_participant} do
      view = open_meeting(conn, viewer, meeting)

      # WAS `chat_panel_open == false`. Task 01a084bf stage 3 deleted the
      # chat drawer and that assign with it; "is the viewer looking at the
      # discussion" is now a question about which rail TAB is active.
      refute assigns(view).active_meeting_tab == "chat"
      assert assigns(view).call_rail_unread == false

      post!(meeting.chat_space_id, other_participant, "did you see this")
      settle(view)

      assert assigns(view).call_rail_unread == true,
             "a real {:new_message, %Message{}} broadcast on this meeting's " <>
               "chat space did not raise the unread flag. Collapsing the rail " <>
               "must not silently hide activity — and note the clause has to " <>
               "sit ABOVE meeting_live.ex's trailing catch-all handle_info/2 " <>
               "or it never runs"
    end

    test "a message arriving while the drawer is OPEN does not raise the flag",
         %{conn: conn, viewer: viewer, meeting: meeting, other_participant: other_participant} do
      view = open_meeting(conn, viewer, meeting)

      # `toggle_chat_panel` now OPENS the rail on the Chat tab rather than
      # toggling a drawer (task 01a084bf stage 3).
      render_click(view, "toggle_chat_panel", %{})
      assert assigns(view).active_meeting_tab == "chat"
      assert assigns(view).chat_panel_collapsed == false

      post!(meeting.chat_space_id, other_participant, "you are looking right at me")
      settle(view)

      assert assigns(view).call_rail_unread == false,
             "a message you are looking at is not unread"

      # DISCRIMINATOR: the very same broadcast, on the very same space, DOES
      # raise the flag once chat is no longer the pane on screen. Without
      # this the assertion above would also pass on a flag that never rises.
      # Driven by LEAVING the tab, since the event no longer toggles.
      render_click(view, "meeting_tab_select", %{"tab" => "people"})
      refute assigns(view).active_meeting_tab == "chat"

      post!(meeting.chat_space_id, other_participant, "and now you are not")
      settle(view)

      assert assigns(view).call_rail_unread == true
    end

    test "a COLLAPSED rail sitting on the Chat tab still raises the flag",
         %{conn: conn, viewer: viewer, meeting: meeting, other_participant: other_participant} do
      view = open_meeting(conn, viewer, meeting)

      # The Chat tab can be the active tab while the viewer can see nothing
      # of it: at `lg` a collapsed rail is a 44px icon strip with no pane in
      # it. Suppressing the dot on the tab alone would hide activity behind
      # a preference the viewer set once — this is the second half of
      # `chat_on_screen?/1` and nothing else in this file covers it.
      render_click(view, "meeting_tab_select", %{"tab" => "chat"})
      force_collapsed(view, true)

      assert assigns(view).active_meeting_tab == "chat"
      assert assigns(view).chat_panel_collapsed == true

      post!(meeting.chat_space_id, other_participant, "behind the strip")
      settle(view)

      assert assigns(view).call_rail_unread == true,
             "a collapsed rail shows no chat, so the message is unread"
    end

    test "opening chat clears the flag; LEAVING the tab does not re-raise it",
         %{conn: conn, viewer: viewer, meeting: meeting, other_participant: other_participant} do
      view = open_meeting(conn, viewer, meeting)

      post!(meeting.chat_space_id, other_participant, "one")
      settle(view)
      assert assigns(view).call_rail_unread == true

      render_click(view, "toggle_chat_panel", %{})
      assert assigns(view).active_meeting_tab == "chat"

      assert assigns(view).call_rail_unread == false,
             "opening the discussion must clear the marker"

      # WAS: a second `toggle_chat_panel` push, asserting that CLOSING did
      # not clear the flag. The event no longer toggles (task 01a084bf stage
      # 3) — asking for chat twice asks for the same thing twice — so the
      # equivalent move is to leave the tab. The property is unchanged and is
      # the one that matters: navigating away must not invent unread messages
      # that never arrived, and must leave the flag ready to count again.
      render_click(view, "meeting_tab_select", %{"tab" => "people"})

      assert assigns(view).call_rail_unread == false,
             "leaving the Chat tab must NOT raise the dot by itself — there " <>
               "is nothing new to read"

      # And it really is ready to count again.
      post!(meeting.chat_space_id, other_participant, "two")
      settle(view)
      assert assigns(view).call_rail_unread == true

      # Selecting the tab directly clears it, exactly as the top-bar control
      # does — the strip's chained push arrives this way.
      render_click(view, "meeting_tab_select", %{"tab" => "chat"})
      assert assigns(view).call_rail_unread == false
    end

    test "the viewer's own message does not mark itself unread",
         %{
           conn: conn,
           viewer: viewer,
           meeting: meeting,
           viewer_participant: viewer_participant,
           other_participant: other_participant
         } do
      view = open_meeting(conn, viewer, meeting)

      post!(meeting.chat_space_id, viewer_participant, "sent by me")
      settle(view)

      assert assigns(view).call_rail_unread == false,
             "a message the viewer sent themselves must not raise their own " <>
               "unread flag (author_user_id is the ADR 0038 identity snapshot)"

      # DISCRIMINATOR: somebody else's message on the same space, with the
      # drawer in the same closed state, DOES raise it.
      post!(meeting.chat_space_id, other_participant, "sent by somebody else")
      settle(view)

      assert assigns(view).call_rail_unread == true
    end

    test "a message in an unrelated space the viewer also holds does not raise the flag",
         %{
           conn: conn,
           org: org,
           viewer: viewer,
           meeting: meeting,
           other_participant: other_participant
         } do
      # A SECOND meeting whose chat space the viewer is a participant of.
      # `ShellLive`'s presence branch subscribes every space in
      # `Chat.list_member_space_ids/1` on THIS SAME PID, so its traffic
      # genuinely arrives at the LiveView under test — this is not an
      # absence assertion over a topic nobody publishes on.
      elsewhere = meeting!(org, "elsewhere")
      _viewer_elsewhere = join!(elsewhere.chat_space_id, viewer)

      stranger = create_member!(org, "stranger")
      stranger_participant = join!(elsewhere.chat_space_id, stranger)

      assert elsewhere.chat_space_id in Chat.list_member_space_ids(viewer.id)

      view = open_meeting(conn, viewer, meeting)

      post!(elsewhere.chat_space_id, stranger_participant, "different room entirely")
      settle(view)

      assert assigns(view).call_rail_unread == false,
             "a message from an unrelated space must not put a dot on THIS " <>
               "meeting's rail"

      # DISCRIMINATOR: the meeting's own space still raises it, so the
      # absence above is a filter working rather than delivery failing.
      post!(meeting.chat_space_id, other_participant, "this room")
      settle(view)

      assert assigns(view).call_rail_unread == true
    end
  end

  # ── Stage 2: the collapsed strip actually renders ──────────────────────────
  #
  # Everything above reads assigns. Everything below reads the DOM, because
  # stage 2's whole claim is that those assigns now change the shape of the
  # screen. Selectors anchor on `data-role` / `data-pane` VALUES, never on
  # position or line number.
  #
  # `LazyHTML.query/2` throughout, never `filter/2`: `filter/2` matches only
  # a fragment's ROOT nodes, so every one of these nested lookups would come
  # back `[]` and read as "the element is not there".

  # RE-POINTED by task 01a084bf stage 2/3. This selector used to be
  # `[data-pane="call-rail"][data-pane-collapsed="true"]`, which encoded two
  # assumptions that stopped being true when the rail was folded into ONE
  # node: that `data-pane="call-rail"` sits on the collapsed strip itself
  # (it is now on the single rail node, of which the strip is a DESCENDANT),
  # and that the strip carries `data-pane-collapsed` (retired in favour of
  # `data-collapsed` on the rail node).
  #
  # Anchored on `data-role="call-rail-collapsed"` instead, which names the
  # strip specifically and cannot be confused with the rail that contains
  # it. Deliberately NOT a bare `[data-collapsed="true"]`:
  # `#meeting-chat-pane-collapse-hook` also carries `data-collapsed`.
  defp strip_html(view) do
    doc = view |> render() |> LazyHTML.from_fragment()

    nodes = LazyHTML.query(doc, ~s([data-pane="call-rail"] [data-role="call-rail-collapsed"]))

    # `LazyHTML.query/2` hands back a `%LazyHTML{}`, NOT a list — a
    # zero-node result is still a truthy struct, so `if result` reads as
    # "found it" for a selector that matched nothing.
    if Enum.empty?(nodes), do: nil, else: nodes
  end

  defp strip!(view) do
    strip = strip_html(view)
    assert strip, "expected the collapsed 44px strip to be in the DOM"
    strip
  end

  defp strip_class(view) do
    strip!(view) |> LazyHTML.attribute("class") |> List.first() || ""
  end

  # The class list of the ONE rail node. The width and its transition live
  # here, not on the strip: after task 01a084bf stage 2 the rail is a single
  # element present in both states, and the animated quantity has to be a
  # property of the element that survives the change. Reading the transition
  # off the strip — which is `:if`-gated and therefore replaced rather than
  # resized — is exactly the measurement that let FE-5's V5 case through.
  defp rail_class(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-pane="call-rail"]))
    |> LazyHTML.attribute("class")
    |> List.first() || ""
  end

  # Drive the rail into COLLAPSED through the chevron, i.e. the one path
  # that is allowed to animate.
  defp collapse_by_chevron(view) do
    force_collapsed(view, true)
    assert assigns(view).call_rail_animate == true
    view
  end

  describe "(a) the collapsed strip is a 44px icon strip, not a 48px dead end" do
    setup %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "strip")
      %{meeting: meeting, view: open_meeting_shell(conn, viewer, meeting)}
    end

    test "it is absent while the rail is expanded", %{view: view} do
      force_collapsed(view, false)
      refute strip_html(view), "the strip must not co-exist with the expanded rail"

      # ANTI-VACUITY. This case is a `refute` on a selector, so it passes
      # for free the moment the selector stops matching anything — which is
      # precisely what happened to its previous form
      # (`[data-pane="call-rail"][data-pane-collapsed="true"]`) when the rail
      # became one node. Two guards against that:
      #
      #   1. the selector must be capable of matching — collapse and see it.
      #   2. a strip-specific marker that cannot be confused with the rail
      #      is separately absent while expanded.
      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="call-rail-strip-icon"]))
             |> Enum.empty?(),
             "no strip button may render while the rail is expanded"

      assert view |> collapse_by_chevron() |> strip_html(),
             "the selector must be able to MATCH, or this test's refute is vacuous"
    end

    test "w-11 (44px), NOT w-12 — and the class is the house spelling", %{view: view} do
      class = view |> collapse_by_chevron() |> strip_class()

      assert class =~ ~r/\bw-11\b/,
             "the strip must be `w-11` (Tailwind 44px). Got: #{class}"

      refute class =~ ~r/\bw-12\b/,
             "`w-12` is 48px and is what this replaced — the 268px stage " <>
               "delta depends on 44. Got: #{class}"
    end

    test "ground is a FLAT base-200 with one base-300 (`edge`) rule and no shadow",
         %{view: view} do
      class = view |> collapse_by_chevron() |> strip_class()

      assert class =~ ~r/\bbg-base-200\b/, class

      refute class =~ ~r/\bbg-base-200\/\d/,
             "the design canvas calls for a flat base-200 ground, not the " <>
               "old `/40` wash: it must read as an edge, not as content"

      assert class =~ ~r/\bborder-l\b/, class
      assert class =~ ~r/\bborder-edge\b/, class

      refute class =~ ~r/\bshadow-/,
             "a shadow implies the rail floats over the stage; it does not"
    end

    test "it stays a `lg:`-only affordance, so the mobile drawer is untouched",
         %{view: view} do
      class = view |> collapse_by_chevron() |> strip_class()

      assert class =~ ~r/\bhidden\b/, class
      assert class =~ ~r/\blg:flex\b/, class
    end

    test "NO TEXT AT ALL — the accessible names carry the whole burden",
         %{view: view} do
      text =
        view
        |> collapse_by_chevron()
        |> strip!()
        |> LazyHTML.text()
        |> String.trim()

      assert text == "",
             "the collapsed state is DEFINED by having no type in it. Got: #{inspect(text)}"
    end
  end

  describe "(b) every glyph is a shortcut, and none of them is a dead end" do
    setup %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "icons")
      view = conn |> open_meeting_shell(viewer, meeting) |> collapse_by_chevron()
      %{meeting: meeting, view: view}
    end

    test "one button per tab, in `CallShell.tabs/0` order", %{view: view} do
      strip = strip!(view)

      # The strip renders one button per entry in `CallShell.tabs/0`, in that
      # order, and every button's `data-tab` is read here regardless of which
      # `data-role` it carries — see the next case for why Chat's differs.
      tabs =
        strip
        |> LazyHTML.query(
          ~s([data-role="call-rail-strip-icon"], [data-role="call-rail-strip-chat"])
        )
        |> LazyHTML.attribute("data-tab")

      assert tabs == Enum.map(PlatformWeb.Components.Meetings.CallShell.tabs(), &elem(&1, 0))
      assert tabs == ["people", "chat", "canvas", "transcript"]
    end

    test "Chat IS in the shared tab list now, and keeps the strip-chat role", %{view: view} do
      # INVERTED by task 01a084bf. This case used to assert that no Chat tab
      # had been "smuggled into" `CallShell.tabs/0`, which was right while
      # Chat was a separate `#meeting-chat-drawer`: a Chat entry would have
      # rendered a tab leading to a surface the rail did not own.
      #
      # Stage 1 of 01a084bf made Chat the rail's FOURTH TAB and stage 3 moved
      # the one `ChatLive.Embedded` mount into it, which is what gave the tab
      # somewhere to lead. The old assertion now pins the defect, so it is
      # inverted rather than deleted.
      assert Enum.any?(
               PlatformWeb.Components.Meetings.CallShell.tabs(),
               fn {id, _} -> id == "chat" end
             ),
             "Chat is a rail tab as of task 01a084bf stage 1"

      strip = strip!(view)

      # 01a0740d shipped a hand-written Chat button beside the three looped
      # icons. Now that the loop yields Chat, a second button would put two
      # chat glyphs in a 44px strip — so the loop's Chat entry CARRIES
      # 01a0740d's role instead. Button count and both role names are
      # unchanged; only which element owns `call-rail-strip-chat` moved.
      assert strip
             |> LazyHTML.query(~s([data-role="call-rail-strip-chat"]))
             |> LazyHTML.attribute("data-tab") == ["chat"]

      icon_tabs =
        strip
        |> LazyHTML.query(~s([data-role="call-rail-strip-icon"]))
        |> LazyHTML.attribute("data-tab")

      refute "chat" in icon_tabs,
             "Chat must not carry BOTH roles — that would double-count the button"

      assert icon_tabs == ["people", "canvas", "transcript"]
    end

    test "every tab icon carries a hero glyph and an aria-label naming its tab",
         %{view: view} do
      strip = strip!(view)

      for {id, label} <- PlatformWeb.Components.Meetings.CallShell.tabs() do
        # Matched on `data-tab` rather than on a role, so the Chat entry —
        # which carries `call-rail-strip-chat` — is covered by this loop
        # exactly like the other three. Every tab must name itself.
        button = LazyHTML.query(strip, ~s([data-tab="#{id}"]))

        assert LazyHTML.attribute(button, "aria-label") == [label]

        glyph =
          button
          |> LazyHTML.query("span[aria-hidden]")
          |> LazyHTML.attribute("class")
          |> Enum.join(" ")

        assert glyph =~ PlatformWeb.Components.Meetings.CallShell.tab_icon(id)
      end
    end

    # M6 lives here. An icon that only expands the rail is the dead end this
    # ticket exists to remove.
    for {tab, _label} <- [{"people", nil}, {"canvas", nil}, {"transcript", nil}] do
      test "clicking the #{tab} icon expands the rail AND selects #{tab}, in one action",
           %{view: view} do
        tab = unquote(tab)

        # Start on a DIFFERENT tab so "it selected it" cannot pass because
        # it was already there.
        other = if tab == "people", do: "transcript", else: "people"
        render_click(view, "meeting_tab_select", %{"tab" => other})
        assert assigns(view).active_meeting_tab == other
        assert assigns(view).chat_panel_collapsed == true

        view
        |> element(~s([data-role="call-rail-strip-icon"][data-tab="#{tab}"]))
        |> render_click()

        assert assigns(view).chat_panel_collapsed == false,
               "the icon must EXPAND the rail"

        assert assigns(view).active_meeting_tab == tab,
               "the icon must SELECT its tab in the same action — expanding " <>
                 "onto the tab the viewer did not ask for is the dead end " <>
                 "this replaced"

        # And the rail it opened really is pointed at that tab.
        assert view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(~s([data-component="call-rail"]))
               |> LazyHTML.attribute("data-active-tab") == [tab]
      end
    end

    test "the chevron survives as `chat-pane-toggle` and reports aria-expanded honestly",
         %{view: view} do
      collapsed =
        view
        |> strip!()
        |> LazyHTML.query(~s([data-role="chat-pane-toggle"]))

      assert LazyHTML.attribute(collapsed, "aria-expanded") == ["false"]

      force_collapsed(view, false)

      # Scoped to the EXPANDED branch specifically. Before the one-node fold
      # the collapsed strip was a SIBLING of `[data-pane="call-rail"]`, so
      # this descendant selector could only ever reach the expanded rail's
      # chevron. Both branches are descendants of the one rail node now, and
      # an unscoped query would return two elements the moment the collapsed
      # branch stopped being `:if`-gated.
      expanded =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="call-rail-expanded"] [data-role="chat-pane-toggle"]))

      assert LazyHTML.attribute(expanded, "aria-expanded") == ["true"]
    end
  end

  describe "(c) the active-tab marker — collapsed is a paused state, not an amnesiac one" do
    setup %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "marker")
      view = conn |> open_meeting_shell(viewer, meeting) |> collapse_by_chevron()
      %{meeting: meeting, view: view}
    end

    defp marked_tabs(view) do
      view
      |> strip!()
      |> LazyHTML.query(~s([data-role="call-rail-strip-icon"]))
      |> Enum.filter(fn node ->
        node
        |> LazyHTML.query(~s([data-role="call-rail-strip-active-marker"]))
        |> Enum.any?()
      end)
      |> Enum.flat_map(&LazyHTML.attribute(&1, "data-tab"))
    end

    test "exactly one marker, on the current tab", %{view: view} do
      assert marked_tabs(view) == ["people"]

      render_click(view, "meeting_tab_select", %{"tab" => "transcript"})
      assert marked_tabs(view) == ["transcript"]

      render_click(view, "meeting_tab_select", %{"tab" => "canvas"})
      assert marked_tabs(view) == ["canvas"]
    end

    test "it is a 2px full-height bar in the `primary` slot on the STAGE-FACING edge",
         %{view: view} do
      class =
        view
        |> strip!()
        |> LazyHTML.query(~s([data-role="call-rail-strip-active-marker"]))
        |> LazyHTML.attribute("class")
        |> List.first()

      # LEFT, because the rail is the right-hand column: the marker points
      # at the content it belongs to.
      assert class =~ ~r/\bleft-0\b/, class
      refute class =~ ~r/\bright-0\b/, class
      assert class =~ ~r/\bw-0\.5\b/, class
      assert class =~ ~r/\binset-y-0\b/, class
      assert class =~ ~r/\bbg-primary\b/, class
    end

    test "a junk active tab marks People, exactly as the expanded pane renders People",
         %{view: view} do
      render_click(view, "meeting_tab_select", %{"tab" => "not-a-tab"})

      assert marked_tabs(view) == ["people"],
             "no marker at all would be the collapsed state claiming to have " <>
               "forgotten a place it has not lost"
    end
  end

  describe "(d)/(e) the unread dot and the names that describe it" do
    setup %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "dot")
      other = create_member!(org, "other")
      other_participant = join!(meeting.chat_space_id, other)
      _viewer_participant = join!(meeting.chat_space_id, viewer)

      view = conn |> open_meeting_shell(viewer, meeting) |> collapse_by_chevron()

      %{meeting: meeting, view: view, other_participant: other_participant}
    end

    defp dot(view) do
      view
      |> strip!()
      |> LazyHTML.query(~s([data-role="call-rail-strip-chat"] [data-role="call-rail-unread-dot"]))
    end

    defp chat_label(view) do
      view
      |> strip!()
      |> LazyHTML.query(~s([data-role="call-rail-strip-chat"]))
      |> LazyHTML.attribute("aria-label")
    end

    test "the node is ABSENT — not transparent — while nothing is unread", %{view: view} do
      assert assigns(view).call_rail_unread == false
      assert dot(view) |> Enum.empty?()
      assert chat_label(view) == ["Chat"]
    end

    test "a real message raises it, opening chat clears it, and the name tracks both",
         %{view: view, meeting: meeting, other_participant: other_participant} do
      post!(meeting.chat_space_id, other_participant, "did you see this")
      settle(view)

      assert Enum.count(dot(view)) == 1

      assert chat_label(view) == ["Chat, unread messages"],
             "a screen-reader user gets no benefit from the space the " <>
               "collapse buys and must lose nothing for it"

      # Clicking Chat in the strip now EXPANDS the rail onto the Chat tab
      # (task 01a084bf stage 3), where 01a0740d's version pushed
      # `toggle_chat_panel` at a drawer that was `lg:!hidden` — it cleared
      # this dot and showed the reader nothing, which 01a0740d reported as a
      # known defect. So the strip is gone after the click, by design, and
      # the assertions move to the surface that replaced it.
      view |> element(~s([data-role="call-rail-strip-chat"])) |> render_click()

      assert assigns(view).call_rail_unread == false,
             "arriving at the Chat tab is reading the messages"

      assert assigns(view).chat_panel_collapsed == false, "the rail must expand"
      assert assigns(view).active_meeting_tab == "chat", "onto the Chat tab"

      refute strip_html(view), "the strip is replaced by the expanded rail"

      html = view |> render() |> LazyHTML.from_fragment()

      # The dot is gone everywhere, not merely gone from the strip…
      assert html |> LazyHTML.query(~s([data-role="call-rail-unread-dot"])) |> Enum.empty?()

      # …and the chat the dot was advertising is on screen and mounted once.
      assert html
             |> LazyHTML.query(~s([data-role="call-rail-chat-wrap"][data-active="true"]))
             |> Enum.count() == 1

      assert html |> LazyHTML.query(~s([data-pane="meeting-chat-panel"])) |> Enum.count() == 1
    end

    test "it is the `info` slot and it NEVER animates",
         %{view: view, meeting: meeting, other_participant: other_participant} do
      post!(meeting.chat_space_id, other_participant, "ping")
      settle(view)

      class = dot(view) |> LazyHTML.attribute("class") |> List.first()

      assert class =~ ~r/\bbg-info\b/, class
      assert class =~ ~r/\brounded-full\b/, class

      # `error`, `success` and `warning` are all already spent on this
      # screen. `info` is the one meaning-bearing slot left.
      for spent <- ["bg-error", "bg-success", "bg-warning"] do
        refute class =~ ~r/\b#{spent}\b/, class
      end

      # A blinking dot in peripheral vision during a call is hostile.
      for motion <- ["animate-", "transition", "duration-", "motion-safe:"] do
        refute class =~ motion,
               "the dot must not animate in any form. Got: #{class}"
      end
    end

    test "the dot rides the Chat affordance, never a tab icon",
         %{view: view, meeting: meeting, other_participant: other_participant} do
      post!(meeting.chat_space_id, other_participant, "ping")
      settle(view)

      all =
        view
        |> strip!()
        |> LazyHTML.query(~s([data-role="call-rail-unread-dot"]))

      assert Enum.count(all) == 1

      assert view
             |> strip!()
             |> LazyHTML.query(
               ~s([data-role="call-rail-strip-icon"] [data-role="call-rail-unread-dot"])
             )
             |> Enum.empty?()
    end
  end

  # ── The EXPANDED strip's unread dot (task 01a084bf stage 4 — FE-5's
  #    unresolved V2 case) ────────────────────────────────────────────────────
  #
  # The block above covers the COLLAPSED 44px strip, which is where 01a0740d
  # put the only dot there was. It is a different element, on a different
  # geometry, and the expanded rail — the state a desktop viewer sits in — had
  # no unread affordance at all. Same assign, so a test that read the assign
  # would pass on both while only one rendered anything.
  #
  # Every raise here is driven by a REAL `Chat.post_message/2`, per this file's
  # moduledoc: nothing hand-sends a `%Message{}` to the view's pid.
  describe "(g) the unread dot on the EXPANDED Chat tab" do
    setup %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "expanded-dot")
      other = create_member!(org, "other")
      other_participant = join!(meeting.chat_space_id, other)
      _viewer_participant = join!(meeting.chat_space_id, viewer)

      view = open_meeting_shell(conn, viewer, meeting)

      # The rail is EXPANDED — the state this block is about. `gallery` is the
      # mount default, so this is an assertion rather than a set-up step.
      assert assigns(view).chat_panel_collapsed == false

      %{meeting: meeting, view: view, other_participant: other_participant}
    end

    defp rail_html(view), do: view |> render() |> LazyHTML.from_fragment()

    defp expanded_dots(view) do
      view
      |> rail_html()
      |> LazyHTML.query(
        ~s([data-role="call-rail-tab"][data-tab="chat"] [data-role="call-rail-tab-unread-dot"])
      )
    end

    defp expanded_chat_name(view) do
      view
      |> rail_html()
      |> LazyHTML.query(~s([data-role="call-rail-tab"][data-tab="chat"]))
      |> LazyHTML.attribute("aria-label")
    end

    test "a real message on another tab raises it, on the Chat TAB and nowhere else",
         %{view: view, meeting: meeting, other_participant: other_participant} do
      # Anti-vacuity: the rail really is expanded with a Chat tab in it, and
      # the dot really is absent first — so the count below is a transition.
      assert view
             |> rail_html()
             |> LazyHTML.query(~s([data-role="call-rail-tab"][data-tab="chat"]))
             |> Enum.count() == 1

      refute assigns(view).active_meeting_tab == "chat"
      assert Enum.empty?(expanded_dots(view))
      assert expanded_chat_name(view) == ["Chat"]

      post!(meeting.chat_space_id, other_participant, "did you see this")
      settle(view)

      assert Enum.count(expanded_dots(view)) == 1

      # Exactly one in the whole document, and it is on Chat. Hanging "there
      # is something to read" on People or Canvas would point the viewer at
      # the wrong pane.
      html = rail_html(view)

      assert html |> LazyHTML.query(~s([data-role="call-rail-tab-unread-dot"])) |> Enum.count() ==
               1

      for other <- ~w(people canvas transcript) do
        assert html
               |> LazyHTML.query(
                 ~s([data-role="call-rail-tab"][data-tab="#{other}"] [data-role="call-rail-tab-unread-dot"])
               )
               |> Enum.empty?(),
               other
      end

      # The dot is `aria-hidden`, so the accessible name carries the state.
      assert expanded_chat_name(view) == ["Chat, unread messages"]
    end

    # THE CLEAR, ON ITS OWN. The raise test above must not be allowed to stand
    # in for this half: a rule that raises and never clears passes a raise
    # test, and a dot that never goes away is the whole reason FE-5's version
    # was reported as a defect rather than shipped.
    test "selecting the Chat TAB clears it, and the chat it advertised is on screen",
         %{view: view, meeting: meeting, other_participant: other_participant} do
      post!(meeting.chat_space_id, other_participant, "unread please")
      settle(view)

      assert Enum.count(expanded_dots(view)) == 1, "nothing to clear — the raise did not happen"

      view
      |> element(~s([data-role="call-rail-tab"][data-tab="chat"]))
      |> render_click()

      assert assigns(view).active_meeting_tab == "chat"

      assert assigns(view).call_rail_unread == false,
             "arriving at the Chat tab is reading the messages"

      html = rail_html(view)

      # Gone everywhere, not merely gone from the Chat tab…
      assert html |> LazyHTML.query(~s([data-role="call-rail-tab-unread-dot"])) |> Enum.empty?()
      assert expanded_chat_name(view) == ["Chat"]

      # …and the pane it was advertising is showing, mounted once.
      assert html
             |> LazyHTML.query(~s([data-role="call-rail-chat-wrap"][data-active="true"]))
             |> Enum.count() == 1

      assert html |> LazyHTML.query(~s([data-pane="meeting-chat-panel"])) |> Enum.count() == 1
    end

    test "the dot never rides `chat-pane-toggle`, whose job is to HIDE the rail",
         %{view: view, meeting: meeting, other_participant: other_participant} do
      post!(meeting.chat_space_id, other_participant, "ping")
      settle(view)

      html = rail_html(view)

      # Anti-vacuity for both refutes: the toggle is on the page and the dot
      # was raised, so a zero count means "not there", not "nothing rendered".
      assert html |> LazyHTML.query(~s([data-role="chat-pane-toggle"])) |> Enum.count() == 1

      assert html |> LazyHTML.query(~s([data-role="call-rail-tab-unread-dot"])) |> Enum.count() ==
               1

      assert html
             |> LazyHTML.query(
               ~s([data-role="chat-pane-toggle"] [data-role="call-rail-tab-unread-dot"])
             )
             |> Enum.empty?(),
             "hanging 'there is something to read' on a control that COLLAPSES " <>
               "the rail passes a render test and points the viewer away from " <>
               "the messages"

      assert html
             |> LazyHTML.query(
               ~s([data-role="chat-pane-toggle"] [data-role="call-rail-unread-dot"])
             )
             |> Enum.empty?()
    end

    test "the expanded strip still renders all FOUR tabs — the meeting surface serves chat",
         %{view: view} do
      # The other half of ticket 01a089ae's fix. The quickmeet's three-up is
      # pinned in `chat/partials_meeting_panel_test.exs`; this pins that the
      # fix is PER-CALLER and did not remove Chat everywhere.
      tabs =
        view
        |> rail_html()
        |> LazyHTML.query(~s([data-component="call-rail"] [data-role="call-rail-tab"]))
        |> LazyHTML.attribute("data-tab")

      assert tabs == ~w(people chat canvas transcript)
    end
  end

  describe "(f) motion asymmetry — the chevron animates, a mode change snaps" do
    setup %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "motion")
      %{meeting: meeting, view: open_meeting_shell(conn, viewer, meeting)}
    end

    @width_transition ~r/transition-\[width\]/

    # READ OFF THE RAIL NODE, NOT THE STRIP (task 01a084bf stage 2). These
    # four cases used `strip_class/1`, because 01a0740d put the gated
    # transition on the collapsed strip. That was the wrong element and the
    # reason FE-5's V5 case filmed a single-frame jump while a class-presence
    # check passed: an `:if`-gated strip is REPLACED, not resized, so no
    # transition on it can ever interpolate. The width and its transition now
    # live on the one rail node, and that is where the assertion must look.
    #
    # `refute` cases are the hazard here — a selector that matches nothing
    # makes them pass for free — so each one is paired with a positive
    # control proving the regex can still fire against this same node.

    test "a chevron collapse carries the width transition", %{view: view} do
      collapse_by_chevron(view)

      assert rail_class(view) =~ @width_transition,
             "motion there confirms *you did that*"
    end

    test "a MODE-DRIVEN collapse renders with no transition class at all", %{view: view} do
      force_collapsed(view, false)
      set_mode(view, :screen)

      assert assigns(view).chat_panel_collapsed == true
      assert assigns(view).call_rail_animate == false

      refute rail_class(view) =~ @width_transition,
             "nobody asked for this width change, the mode switch did — a " <>
               "slab of screen sliding at you every time you change what you " <>
               "are looking at is the app moving furniture mid-sentence"

      # Positive control: the same node, the same regex, after a move the
      # viewer DID ask for. Out AND back, because `force_collapsed/1` is a
      # no-op when the rail is already in the state asked for — and the rail
      # is already collapsed here, so a bare `collapse_by_chevron/1` would
      # never push the chevron and never set `:call_rail_animate`.
      force_collapsed(view, false)
      force_collapsed(view, true)

      assert rail_class(view) =~ @width_transition,
             "the refute above must be capable of failing"
    end

    test "a chevron move AFTER a mode change animates again", %{view: view} do
      set_mode(view, :screen)
      refute rail_class(view) =~ @width_transition

      # Out and back, both by hand.
      force_collapsed(view, false)
      force_collapsed(view, true)

      assert rail_class(view) =~ @width_transition
    end

    test "the first paint never animates", %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "first-paint")
      view = open_meeting_shell(conn, viewer, meeting)

      assert assigns(view).call_rail_animate == false

      # Gallery is the open default, so drive a fresh mount that starts
      # collapsed the only way a mount can: by mode.
      set_mode(view, :canvas)
      refute rail_class(view) =~ @width_transition

      # Positive control, out and back for the same reason as above.
      force_collapsed(view, false)
      force_collapsed(view, true)

      assert rail_class(view) =~ @width_transition,
             "the refute above must be capable of failing"
    end
  end
end
