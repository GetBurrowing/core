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
  alias Platform.Meetings.GuestInvite
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

  # A GUEST mount: `chrome_mode: "none"`, which the router's
  # `:guest_meeting` live_session injects on the `meet.` host scope, so
  # `@shell?` is false and there is a real viewer in the room. This is the
  # only mount that gives the strip/tablist comparison a non-shell caller —
  # `open_meeting/3` above is a signed-in MEMBER on the `meet.` host, which
  # is a different surface again.
  defp open_meeting_guest(conn, meeting) do
    expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
    token = GuestInvite.sign(meeting.slug, expires_at, "Agreement Guest")

    {:ok, view, html} = conn |> on_meet_host() |> live("/#{meeting.slug}/#{token}")

    # ANTI-VACUITY: this is the ROOM, not one of the four guest denial
    # states. `:expired` and `:invalid` render a card with no rail at all,
    # and every strip assertion downstream would then be comparing two
    # empty sets — which is precisely the failure mode that reads as a pass.
    assert html =~ meeting.name
    assert :sys.get_state(view.pid).socket.assigns.state == :in_meeting
    assert :sys.get_state(view.pid).socket.assigns.shell? == false

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

  # Every tab id in the collapsed strip, in render order.
  #
  # BOTH ROLES, DELIBERATELY. The Chat entry carries
  # `data-role="call-rail-strip-chat"` (inherited from task 01a0740d, when
  # Chat was a hand-written button beside the loop) while the other three
  # carry `call-rail-strip-icon`. A selector matching only the latter drops
  # Chat and quietly compares a 3-element list to a 4-element one.
  #
  # `LazyHTML.query/2`, never `filter/2`: these buttons are nested inside the
  # strip, and `filter/2` matches only the fragment's ROOT nodes, so it would
  # return `[]` and read as "the strip has no buttons".
  defp strip_tab_ids(strip) do
    strip
    |> LazyHTML.query(~s([data-role="call-rail-strip-icon"], [data-role="call-rail-strip-chat"]))
    |> LazyHTML.attribute("data-tab")
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

    test "one button per tab THIS SURFACE SERVES, in `served_tabs/1` order",
         %{view: view} do
      strip = strip!(view)

      # Every button's `data-tab` is read here regardless of which `data-role`
      # it carries — see the next case for why Chat's differs. A selector
      # matching only `call-rail-strip-icon` would silently omit Chat and
      # compare the wrong set.
      tabs = strip_tab_ids(strip)

      # RE-POINTED (task 01a089fe stage 1). This compared the strip against
      # `CallShell.tabs/0` — the UNFILTERED vocabulary — which is what the
      # strip used to loop and is the defect stage 1 removes. The strip now
      # derives, so the list it must equal is the DERIVED one.
      #
      # READ THIS BEFORE TRUSTING A GREEN RUN OF THIS FILE. The fixture is
      # `open_meeting_shell`, `@shell?` is true there, and that surface serves
      # all four tabs — so `served_tabs/1` and the unfiltered vocabulary are
      # EQUAL here and this assertion cannot tell a deriving strip from a
      # `CallShell.tabs/0` one. It passed both before and after stage 1. It is
      # re-pointed so it MEANS what its name says, not because it proves
      # anything about stage 1 on its own.
      #
      # STAGE 1 PREDICTED THIS CASE WOULD START DISCRIMINATING "the moment the
      # `<:chat>` slot is gated". IT DID NOT, AND CANNOT. Stage 3 gated that
      # slot on `@shell?`, and this fixture is the surface where `@shell?` is
      # TRUE — a shell mount still serves four, so the two lists are still
      # equal here and this line is still a control. What the gate made
      # discriminating is the GUEST fixture: describe "(h)"'s guest agreement
      # case, and describe "(i)", which is where the four-vs-three difference
      # is actually observable.
      # `serve_canvas_tab: false` since task 01a0693e: this collapsed strip is
      # the DESKTOP rail, and at `lg` the card board is the first-class LEFT rail
      # beside the agents, not a Canvas tab here. `served_meeting_tabs/1` passes
      # the same flag, so the strip derives without Canvas.
      assert tabs ==
               Enum.map(
                 PlatformWeb.Components.Meetings.CallShell.served_tabs(%{
                   chat: true,
                   serve_canvas_tab: false
                 }),
                 &elem(&1, 0)
               )

      assert tabs == ["people", "chat", "transcript"]
    end

    test "the collapsed strip and the expanded tablist render ONE derivation",
         %{view: view} do
      # THE ACTUAL STAGE 1 INVARIANT: two presentations of one rail, one tab
      # list. The strip is markup in `meeting_live.html.heex` and the tablist
      # is `CallShell.call_rail/1`'s own `@rail_tabs`; before stage 1 they
      # reached their lists by different routes (`tabs/0` vs `served_tabs/1`)
      # and agreed only because this surface happens to serve all four.
      #
      # This is what goes red if the strip is ever pointed back at the
      # unfiltered list while the rail's slots say otherwise, which is the
      # regression stage 3 would otherwise ship.
      #
      # READ IN TWO STATES, NOT ONE RENDER. The strip is `:if`-gated on the
      # collapsed branch and the tablist on the expanded one, so they never
      # co-exist in the DOM (see "(a) it is absent while the rail is
      # expanded"). Same view, same socket, same capability — the collapse
      # latch is the only thing that changes between the two reads.
      force_collapsed(view, false)

      expanded_ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="call-rail-tab"]))
        |> LazyHTML.attribute("data-tab")

      force_collapsed(view, true)
      strip_ids = view |> strip!() |> strip_tab_ids()

      # ANTI-VACUITY: neither side may be empty. `LazyHTML.query/2` returning
      # `[]` for a bad selector would otherwise make `[] == []` pass and read
      # as agreement between two things that were never found.
      assert strip_ids != [], "found no collapsed strip buttons to compare"
      assert expanded_ids != [], "found no expanded tablist tabs to compare"

      assert strip_ids == expanded_ids,
             "the collapsed strip and the expanded tablist must render the same " <>
               "derived tab list, in the same order"
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

      # No "canvas" since task 01a0693e — the Canvas tab is gone from the desktop
      # rail (the card board is the LEFT rail now).
      assert icon_tabs == ["people", "transcript"]
    end

    test "every tab icon carries a hero glyph and an aria-label naming its tab",
         %{view: view} do
      strip = strip!(view)

      # The tabs this DESKTOP strip actually serves (task 01a0693e drops Canvas
      # here — the card board is the LEFT rail), not the full vocabulary: a tab
      # the strip does not render has no button to name itself.
      served =
        PlatformWeb.Components.Meetings.CallShell.served_tabs(%{
          chat: true,
          serve_canvas_tab: false
        })

      for {id, label} <- served do
        # Matched on `data-tab` rather than on a role, so the Chat entry —
        # which carries `call-rail-strip-chat` — is covered by this loop
        # exactly like the others. Every tab must name itself.
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
    for {tab, _label} <- [{"people", nil}, {"transcript", nil}] do
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
      |> LazyHTML.query(
        ~s([data-role="call-rail-strip-icon"], [data-role="call-rail-strip-chat"])
      )
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

      # "chat" rather than "canvas": Canvas is no longer a rail tab on desktop
      # (task 01a0693e — the card board is the LEFT rail), so a canvas selection
      # would coerce to People and the strip has no canvas button to mark.
      render_click(view, "meeting_tab_select", %{"tab" => "chat"})
      assert marked_tabs(view) == ["chat"]
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

      for other <- ~w(people transcript) do
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

      # No "canvas" since task 01a0693e — the card board is the LEFT rail now.
      assert tabs == ~w(people chat transcript)
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

  # ── (h) the two presentations of one rail AGREE, per caller ────────────────
  #
  # Task 01a089fe stage 2. Defect 1 is a DISAGREEMENT between two
  # presentations of one rail, not either presentation being wrong on its
  # own. What has to be asserted is therefore EQUALITY of the two sets on
  # the SAME assigns — same ids, same order — and not a count, because
  # different callers legitimately serve different tabs and a count cannot
  # tell "three because this caller serves three" from "three because a
  # button went missing".
  #
  # BOTH SETS COME OUT OF ONE RENDER, and that is a property of the markup
  # rather than a convenience. The collapsed strip is
  # `:if={@chat_panel_collapsed}`, but the expanded branch is NEVER
  # `:if`-gated — it hides with `lg:hidden` precisely so its nested
  # `live_render`, stream and scroll position survive a collapse. While
  # collapsed, both are in the DOM at once, so the two sets can be read
  # without changing a single assign between the reads. Stage 1's own case
  # toggled the collapse latch between its two reads, on the stated belief
  # that the two presentations "never co-exist"; that belief is wrong, and
  # reading both out of one document removes the toggle as a possible
  # explanation for any agreement or disagreement observed.
  #
  # WHICH OF THESE IS A CONTROL AND WHICH IS A GUARD. Read this before
  # trusting a green run of this describe:
  #
  #   * SHELL (`open_meeting_shell`, `@shell?` true) — a CONTROL, and it
  #     cannot be made into anything else. This surface serves every tab,
  #     so the derived list and the unfiltered vocabulary are EQUAL here
  #     and no assertion over this fixture can distinguish them. Its job is
  #     to prove the comparison is reading two real, non-empty, four-long
  #     sets, and to stay GREEN when the strip is reverted to
  #     `CallShell.tabs/0` — a mutation that reds here would mean the
  #     comparison is measuring something other than what it claims.
  #
  #   * GUEST (`open_meeting_guest`, `@shell?` false) — A REAL GUARD, AND IT
  #     NOW DISCRIMINATES IN BOTH DIRECTIONS. Stage 2 wrote this case with
  #     the label "not yet discriminating", correctly: `/meetings` then
  #     supplied `<:chat>` UNCONDITIONALLY, with the `:if={@shell?}` on a div
  #     INSIDE the slot body rather than on the slot, so `served_tabs/1` saw
  #     chat as served for a guest exactly as for the host and this
  #     assertion could not fail on the served-vs-unfiltered axis. That gap
  #     was defect 2, and stage 3 closed it by moving the `:if` onto the
  #     slot. The label is updated rather than left standing, because a case
  #     named "not yet discriminating" is one the next reader will discount.
  #
  #     Stage 3 measured it, one mutation per direction, both on THIS case:
  #     reverting only the strip to `CallShell.tabs()` while the slot stays
  #     gated gives strip 4 vs tablist 3 and reds it; reverting only the slot
  #     gate while the strip keeps deriving gives strip 3 vs tablist 4 and
  #     reds it. It is the guard that catches the half-applied change from
  #     either side, which is the ordering constraint between stages 1 and 3
  #     expressed as an invariant rather than as a sequence.
  #
  # THE THIRD SURFACE OF THIS STAGE, the in-chat quickmeet, is deliberately
  # NOT here: it has no collapsed strip to compare against, because the
  # 44px icon strip is markup private to `meeting_live.html.heex` and the
  # quickmeet's `quickmeet_toggle_rail` shows and hides the whole rail as a
  # bottom sheet instead. Its case lives in
  # `test/platform_web/live/chat/partials_meeting_panel_test.exs`, under
  # "the quickmeet's ONE tab presentation", where the absence of a strip is
  # asserted and where the per-caller discrimination that IS available
  # today (three served tabs against a four-entry vocabulary) is carried.
  describe "(h) the collapsed strip and the expanded tablist agree, per caller" do
    # Every tab id in the EXPANDED presentation, in render order.
    #
    # Scoped INSIDE `data-role="call-rail-expanded"` so the set is
    # unambiguously that branch's own even while it is `lg:hidden` behind
    # the collapsed strip, and so this can never accidentally read the
    # strip's buttons back as though they were the tablist's — which would
    # make the equality assertion compare a list to itself and pass forever.
    #
    # `LazyHTML.query/2`, never `filter/2`: these live several levels below
    # the fragment root, and `filter/2` matches ROOT nodes only, so it would
    # hand back an empty result that reads as "the tablist is not there".
    defp tablist_tab_ids(doc) do
      doc
      |> LazyHTML.query(
        ~s([data-role="call-rail-expanded"] [data-role="call-rail-tabs"] [data-role="call-rail-tab"])
      )
      |> LazyHTML.attribute("data-tab")
    end

    # ONE render, both presentations. See the note above on why they
    # co-exist while collapsed.
    defp both_presentations(view) do
      doc = view |> render() |> LazyHTML.from_fragment()

      strip = LazyHTML.query(doc, ~s([data-pane="call-rail"] [data-role="call-rail-collapsed"]))

      # `LazyHTML.query/2` returns a `%LazyHTML{}` struct even when nothing
      # matched, so a truthiness check here would read as "found it".
      refute Enum.empty?(strip),
             "expected the collapsed 44px strip in the DOM — the rail must be " <>
               "collapsed for this comparison to have two sides"

      {strip_tab_ids(strip), tablist_tab_ids(doc)}
    end

    defp assert_presentations_agree(view, label) do
      {strip_ids, expanded_ids} = both_presentations(view)

      # ANTI-VACUITY, and the reason it is two separate asserts rather than
      # one: `LazyHTML.query/2` on a selector that has stopped matching
      # returns an empty result, and `[] == []` would read as perfect
      # agreement between two sets neither of which was ever found. Each
      # side is checked on its own so the failure names which selector died.
      assert strip_ids != [], "#{label}: found no collapsed strip buttons to compare"
      assert expanded_ids != [], "#{label}: found no expanded tablist tabs to compare"

      assert strip_ids == expanded_ids,
             "#{label}: the collapsed strip and the expanded tablist are two " <>
               "presentations of ONE rail and must render the same derived tab " <>
               "list in the same order — got strip #{inspect(strip_ids)} vs " <>
               "tablist #{inspect(expanded_ids)}"

      strip_ids
    end

    test "SHELL (@shell? true): the two sets are equal — CONTROL, this surface serves every tab",
         %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "agree-shell")
      view = open_meeting_shell(conn, viewer, meeting)

      force_collapsed(view, true)

      ids = assert_presentations_agree(view, "shell")

      # The set named explicitly, so a change that drops the same tab from
      # BOTH presentations at once cannot keep this green on a symmetrically
      # shortened pair. This is the control's other job. No "canvas" since task
      # 01a0693e — the card board is the LEFT rail now.
      assert ids == ["people", "chat", "transcript"]
    end

    test "GUEST (@shell? false): the two sets are equal — DISCRIMINATING, both directions",
         %{conn: conn, org: org, viewer: viewer} do
      _ = viewer
      meeting = meeting!(org, "agree-guest")
      view = open_meeting_guest(conn, meeting)

      # The whole point of this case is the surface where `@shell?` is
      # false. On a shell mount it would silently duplicate the control
      # above.
      assert assigns(view).shell? == false

      # Collapsed the way a GUEST actually gets there. The collapse chevron
      # is `@shell?`-gated, so a guest never has one to click; what
      # collapses their rail is the host starting a screen share, which
      # reasserts the `:screen` mode's rail default. Driving that real
      # event rather than clicking a control this surface does not render —
      # otherwise the fixture would be asserting over a state no guest can
      # reach.
      render_hook(view, "meeting_screen_share_state", %{"enabled" => true})

      assert assigns(view).chat_panel_collapsed == true,
             "the guest's rail must actually be collapsed, or there is only " <>
               "one presentation here and nothing to compare"

      ids = assert_presentations_agree(view, "guest")

      # NO LITERAL LIST HERE, DELIBERATELY. The invariant this case guards
      # is agreement, not a particular membership: pinning the current
      # four-up would make the stage that gates the `<:chat>` slot red for
      # doing exactly the right thing, and pinning three would assert a
      # future that has not happened. What is checked instead is that the
      # agreed list is a sublist of the vocabulary IN VOCABULARY ORDER,
      # which is what `served_tabs/1` guarantees by construction and which
      # catches a reordering that equality alone would miss if both
      # presentations reordered together.
      vocabulary = Enum.map(PlatformWeb.Components.Meetings.CallShell.tabs(), &elem(&1, 0))

      assert ids == Enum.filter(vocabulary, &(&1 in ids)),
             "the derived list must keep the vocabulary's order — got #{inspect(ids)} " <>
               "against #{inspect(vocabulary)}"
    end

    # STAGE 2'S THIRD CASE WAS DELETED HERE, ON ITS OWN INSTRUCTIONS (task
    # 01a089fe stage 3). It was named "DEFECT 2, RECORDED NOT FIXED: the
    # guest is served a Chat tab whose pane never renders" and it asserted
    # `"chat" in tablist_tab_ids(doc)` on a guest mount — the measured
    # current state, written down so the defect was visible in the suite
    # while the stage that owned it had not run yet, and so that the
    # ordering constraint (stage 1's derived strip must land first) was
    # enforced by a failing test rather than by a comment.
    #
    # It did exactly that. Gating the `<:chat>` slot on `@shell?` reds it
    # — measured: `Assertion with in failed / left: "chat" / right:
    # ["people", "canvas", "transcript"]` — which is the gate taking
    # effect, and its own body says the stage that gates the slot must
    # delete it. The coverage did not go anywhere: describe "(i)" below is
    # the same guest surface asserted the other way round, plus the shell
    # positive control that a refutation alone cannot give.
    #
    # The GUEST AGREEMENT CASE above is NOT that case and stays. It pins no
    # literal tab list, so gating the slot leaves it green — and it is
    # the guard that reds if the strip is ever pointed back at the
    # vocabulary while the slot is gated (measured in stage 3: strip
    # reverted to `CallShell.tabs()` gives strip 4 vs tablist 3 on the guest
    # mount, which is the disagreement it exists to catch).
  end

  # ── (i) DEFECT 2: a slot that is SUPPLIED but renders nothing ──────────────
  #
  # Task 01a089fe stage 3. `meeting_live.html.heex` used to pass `<:chat>`
  # unconditionally and put `:if={@shell?}` on a div INSIDE the slot body.
  # `CallShell.served_tabs/1` keys on whether a slot was PASSED, never on
  # whether it renders anything — an `:if` in a slot body is invisible to it
  # (see the note on `tab_served?/2`) — so every `@shell?`-false viewer was
  # served a Chat tab whose pane rendered literally nothing: the pane `case`
  # has no markup on its `"chat"` branch by design, and the
  # `call-rail-chat-wrap` below it was present but empty. The `:if` moved onto
  # the slot, so the slot is genuinely ABSENT for those viewers.
  #
  # WHY THE FIXTURE HAS TO BE A GUEST MOUNT, and why that is the whole
  # load-bearing part of this describe. On the SHELL surface `@shell?` is true,
  # so the slot renders its chat whether or not this change exists and
  # `served_tabs/1` returns all four either way — a case mounted as host
  # CANNOT DISTINGUISH FIXED FROM BROKEN, however correct its assertion looks.
  # `open_meeting_guest/2` (added by stage 2) is the mount where the two
  # states differ. Measured, both directions, on this fixture:
  #
  #   * pre-fix (`:if={@shell?}` on the inner div): the guest's expanded
  #     tablist is `["people", "chat", "canvas", "transcript"]` — stage 2's
  #     own defect-2 case asserted exactly that and passed.
  #   * post-fix (`:if={@shell?}` on the slot): `["people", "canvas",
  #     "transcript"]`, and that same stage 2 case reds with
  #     `left: "chat" / right: ["people", "canvas", "transcript"]`.
  #
  # BOTH HALVES ARE ASSERTED, because a guard that only refutes can be
  # satisfied by breaking chat for everybody: (a) no Chat tab in either
  # presentation for a guest, (b) no blank pane — whatever pane the guest's
  # active tab resolves to has content in it. The SHELL positive control that
  # follows is the other half of that: Chat still served, pane still mounting
  # the embedded chat LiveView.
  #
  # SELECTORS ARE SCOPED PER PRESENTATION. The collapsed strip is
  # `:if={@chat_panel_collapsed}` but the expanded branch is NEVER `:if`-gated
  # (it hides with `lg:hidden` so its nested `live_render` survives a
  # collapse), so while collapsed BOTH are in the DOM. An unscoped
  # `[data-role="call-rail-pane"]` or `[data-role="call-rail-tab"]` can read
  # the wrong branch and hand back a pass or a fail that is about the other
  # presentation. Everything below goes through
  # `[data-role="call-rail-expanded"] …` or the strip container, and every
  # query is `LazyHTML.query/2` — `filter/2` matches the fragment's ROOT nodes
  # only, so on nodes this deep it returns `[]` and reads as "not there".
  describe "(i) the guest's chat slot is ABSENT, so no Chat tab is served" do
    # The pane the expanded rail is currently rendering, scoped to the
    # expanded branch for the reason in the note above.
    defp expanded_pane(doc) do
      LazyHTML.query(
        doc,
        ~s([data-role="call-rail-expanded"] [data-role="call-rail-pane"])
      )
    end

    test "GUEST (@shell? false): NEITHER presentation offers a Chat tab",
         %{conn: conn, org: org} do
      meeting = meeting!(org, "guest-no-chat-tab")
      view = open_meeting_guest(conn, meeting)

      # Collapsed the way a guest actually gets there: the chevron is
      # `@shell?`-gated, so what collapses their rail is the host starting a
      # screen share, which reasserts the `:screen` mode's rail default.
      # Both presentations are in the DOM at once while collapsed, which is
      # what lets one render answer for both.
      render_hook(view, "meeting_screen_share_state", %{"enabled" => true})

      assert assigns(view).chat_panel_collapsed == true,
             "the guest's rail must be collapsed or there is only one " <>
               "presentation here and half the assertion is missing"

      doc = view |> render() |> LazyHTML.from_fragment()
      strip_ids = view |> strip!() |> strip_tab_ids()
      tablist_ids = tablist_tab_ids(doc)

      # ANTI-VACUITY FIRST, and as an equality rather than a `!= []`: a
      # `refute "chat" in …` over a selector that has stopped matching passes
      # for the worst possible reason, and pinning the exact three-up also
      # catches a change that drops MORE than Chat.
      # Since task 01a0693e Canvas is no longer a rail tab on desktop (the card
      # board is the LEFT rail), so a guest — who also serves no Chat tab —
      # serves exactly People and Transcript.
      assert strip_ids == ["people", "transcript"],
             "the guest's collapsed strip should serve exactly the two " <>
               "unconditional non-canvas tabs — got #{inspect(strip_ids)}"

      assert tablist_ids == ["people", "transcript"],
             "the guest's expanded tablist should serve exactly the two " <>
               "unconditional non-canvas tabs — got #{inspect(tablist_ids)}"

      # HALF (a), stated as the refutation it is, in BOTH presentations. The
      # strip is the half that only became possible once stage 1 made it
      # derive; before that this line would have failed on a correct fix.
      refute "chat" in strip_ids
      refute "chat" in tablist_ids

      # …and no active marker for a tab that is not there, in either
      # presentation. This is the defect-1 symptom that gating the slot would
      # have created on a strip still looping the vocabulary.
      assert doc
             |> LazyHTML.query(~s([data-role="call-rail-strip-active-marker"]))
             |> Enum.count() == 1,
             "exactly one strip button may be marked active"

      assert view
             |> strip!()
             |> LazyHTML.query(~s([data-tab="chat"]))
             |> Enum.empty?(),
             "no Chat button may survive in the guest's collapsed strip"

      # THE SLOT REALLY IS ABSENT, not merely tab-less. `call_rail/1` gates
      # the persistent chat wrapper on `@chat != []`, so its absence is the
      # component's own view of the same fact the tab list reports — and the
      # shell's chat panel div, which is what used to render empty here, is
      # gone with it.
      assert doc |> LazyHTML.query(~s([data-role="call-rail-chat-wrap"])) |> Enum.empty?(),
             "a guest whose slot is absent must get no chat wrapper at all"

      assert doc |> LazyHTML.query(~s([data-pane="meeting-chat-panel"])) |> Enum.empty?()
    end

    test "GUEST (@shell? false): no blank pane — the active pane has content",
         %{conn: conn, org: org} do
      meeting = meeting!(org, "guest-no-blank-pane")
      view = open_meeting_guest(conn, meeting)

      # The rail opens expanded for a guest, so this is the pane they land on.
      pane = view |> render() |> LazyHTML.from_fragment() |> expanded_pane()

      refute Enum.empty?(pane), "found no expanded rail pane to measure"
      assert LazyHTML.attribute(pane, "data-pane-tab") == ["people"]

      # HALF (b). "Blank" is measured as the DOM measures it: no element
      # children and no text. Pre-fix, a guest sitting on Chat rendered
      # exactly that — the pane `case` draws nothing on its `"chat"` branch
      # and the chat wrap below it was an empty div — so this is the
      # assertion that would have failed on the old code, not a restatement
      # of half (a).
      refute pane |> LazyHTML.query("*") |> Enum.empty?(),
             "the guest's active pane has no element children — a tab over a " <>
               "blank pane is the defect this stage removes"

      refute pane |> LazyHTML.text() |> String.trim() == "",
             "the guest's active pane renders no text at all"

      # AND A TAB ID THE SURFACE NO LONGER SERVES STILL LANDS ON A REAL PANE.
      # `"chat"` is reachable as an event value even with no button to press
      # it — `?tab=chat` on a member mount, a stale client, the strip's own
      # chained push before this change — and the rail must coerce it to
      # People rather than render the empty branch. `call_rail/1` normalises
      # against `served_tabs/1`, which is the same list the tab loop uses, so
      # this is that coercion observed end to end rather than unit-tested.
      render_click(view, "meeting_tab_select", %{"tab" => "chat"})

      assert assigns(view).active_meeting_tab == "chat",
             "the assign is stored verbatim; the rail coerces on render"

      after_pane = view |> render() |> LazyHTML.from_fragment() |> expanded_pane()

      assert LazyHTML.attribute(after_pane, "data-pane-tab") == ["people"],
             "a tab this surface does not serve must render People, not an " <>
               "empty pane"

      refute after_pane |> LazyHTML.query("*") |> Enum.empty?()
      refute after_pane |> LazyHTML.text() |> String.trim() == ""
    end

    test "MEMBER on the meet host is @shell? false too, and loses the tab with the guest",
         %{conn: conn, org: org, viewer: viewer} do
      # NOT A DUPLICATE OF THE GUEST CASE. The `:meet_member` live_session
      # injects `chrome_mode: "none"` for a SIGNED-IN account, so `@shell?` is
      # false with a real `@user_id` — a different mount clause, a different
      # subscription set, and the surface where the follow-on `normalize_tab/1`
      # call sites are actually live (see `chat_on_screen?/1`). The slot gate
      # is `@shell?`, so the claim "every `@shell?`-false viewer" needs this
      # second surface or it is a claim about one mount.
      meeting = meeting!(org, "member-no-chat-tab")
      view = open_meeting(conn, viewer, meeting)

      assert assigns(view).shell? == false,
             "if this surface is `@shell?` true it is the shell control, not " <>
               "a second gated surface, and this case proves nothing"

      doc = view |> render() |> LazyHTML.from_fragment()
      ids = tablist_tab_ids(doc)

      assert ids == ["people", "transcript"], "got #{inspect(ids)}"
      refute "chat" in ids
      assert doc |> LazyHTML.query(~s([data-pane="meeting-chat-panel"])) |> Enum.empty?()
    end

    test "SHELL (@shell? true) POSITIVE CONTROL: Chat is still served and its pane still renders",
         %{conn: conn, org: org, viewer: viewer} do
      # THE HALF A REFUTATION CANNOT GIVE. Everything above is "no Chat tab
      # here"; deleting the `<:chat>` slot outright, or gating it on
      # something always-false, would satisfy all of it while breaking chat
      # for every host on the product. This case is what makes the pair a
      # specification instead of a demolition order.
      meeting = meeting!(org, "shell-chat-kept")
      view = open_meeting_shell(conn, viewer, meeting)

      assert assigns(view).shell? == true

      doc = view |> render() |> LazyHTML.from_fragment()
      ids = tablist_tab_ids(doc)

      assert ids == ["people", "chat", "transcript"], "got #{inspect(ids)}"
      assert "chat" in ids

      # The slot is supplied here, so the persistent wrapper exists…
      assert doc |> LazyHTML.query(~s([data-role="call-rail-chat-wrap"])) |> Enum.count() == 1

      # …and it holds the real embedded chat, not the no-space placeholder:
      # `meeting!/2` goes through `Meetings.create_meeting/1`, which creates
      # the backing chat space, and `fetch_meeting_for_user/2` preloads it. If
      # this ever reads the placeholder branch instead, the pane is "present"
      # while the discussion is not, which is the blank-pane defect wearing a
      # different mask.
      assert doc |> LazyHTML.query(~s([data-pane="meeting-chat-panel"])) |> Enum.count() == 1

      assert doc
             |> LazyHTML.query(~s([id="meeting-chat-panel-#{meeting.id}"]))
             |> Enum.count() == 1,
             "the shell's Chat pane must still mount the embedded chat LiveView"

      assert doc
             |> LazyHTML.query(~s([data-placeholder="chat-panel-empty"]))
             |> Enum.empty?(),
             "a meeting WITH a bound chat space must not render the no-space " <>
               "placeholder — that would make the assertion above pass over an " <>
               "empty pane"

      # And selecting Chat really shows it: the wrap is the caller's slot and
      # `call_rail/1` flips `hidden` on it rather than unmounting it, so
      # "active" is the observable state here.
      render_click(view, "meeting_tab_select", %{"tab" => "chat"})

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="call-rail-chat-wrap"][data-active="true"]))
             |> Enum.count() == 1,
             "the shell viewer must still be able to reach the discussion"
    end
  end
end
