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

    test "a message arriving while the discussion drawer is CLOSED raises the flag",
         %{conn: conn, viewer: viewer, meeting: meeting, other_participant: other_participant} do
      view = open_meeting(conn, viewer, meeting)

      assert assigns(view).chat_panel_open == false
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

      render_click(view, "toggle_chat_panel", %{})
      assert assigns(view).chat_panel_open == true

      post!(meeting.chat_space_id, other_participant, "you are looking right at me")
      settle(view)

      assert assigns(view).call_rail_unread == false,
             "a message you are looking at is not unread"

      # DISCRIMINATOR: the very same broadcast, on the very same space, DOES
      # raise the flag once the drawer is closed. Without this the assertion
      # above would also pass on a flag that never rises at all.
      render_click(view, "toggle_chat_panel", %{})
      assert assigns(view).chat_panel_open == false

      post!(meeting.chat_space_id, other_participant, "and now you are not")
      settle(view)

      assert assigns(view).call_rail_unread == true
    end

    test "opening the drawer clears the flag; closing it does not",
         %{conn: conn, viewer: viewer, meeting: meeting, other_participant: other_participant} do
      view = open_meeting(conn, viewer, meeting)

      post!(meeting.chat_space_id, other_participant, "one")
      settle(view)
      assert assigns(view).call_rail_unread == true

      render_click(view, "toggle_chat_panel", %{})
      assert assigns(view).chat_panel_open == true

      assert assigns(view).call_rail_unread == false,
             "opening the discussion must clear the marker"

      render_click(view, "toggle_chat_panel", %{})
      assert assigns(view).chat_panel_open == false

      assert assigns(view).call_rail_unread == false,
             "closing must NOT clear: clearing on close would wipe the dot " <>
               "at the exact moment it should start counting again"
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

  defp strip_html(view) do
    doc = view |> render() |> LazyHTML.from_fragment()

    nodes = LazyHTML.query(doc, ~s([data-pane="call-rail"][data-pane-collapsed="true"]))

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

    test "one icon per REAL tab, in `CallShell.tabs/0` order", %{view: view} do
      tabs =
        view
        |> strip!()
        |> LazyHTML.query(~s([data-role="call-rail-strip-icon"]))
        |> LazyHTML.attribute("data-tab")

      assert tabs == Enum.map(PlatformWeb.Components.Meetings.CallShell.tabs(), &elem(&1, 0))
      assert tabs == ["people", "canvas", "transcript"]
    end

    test "NO Chat tab was smuggled into the shared tab list", %{view: view} do
      tabs =
        view
        |> strip!()
        |> LazyHTML.query(~s([data-role="call-rail-strip-icon"]))
        |> LazyHTML.attribute("data-tab")

      refute "chat" in tabs

      refute Enum.any?(
               PlatformWeb.Components.Meetings.CallShell.tabs(),
               fn {id, _} -> id == "chat" end
             ),
             "`CallShell.tabs/0` feeds the in-chat quickmeet rail too"
    end

    test "every tab icon carries a hero glyph and an aria-label naming its tab",
         %{view: view} do
      strip = strip!(view)

      for {id, label} <- PlatformWeb.Components.Meetings.CallShell.tabs() do
        button = LazyHTML.query(strip, ~s([data-role="call-rail-strip-icon"][data-tab="#{id}"]))

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

      expanded =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-pane="call-rail"] [data-role="chat-pane-toggle"]))

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

      view |> element(~s([data-role="call-rail-strip-chat"])) |> render_click()

      assert assigns(view).call_rail_unread == false
      assert dot(view) |> Enum.empty?()
      assert chat_label(view) == ["Chat"]
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

  describe "(f) motion asymmetry — the chevron animates, a mode change snaps" do
    setup %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "motion")
      %{meeting: meeting, view: open_meeting_shell(conn, viewer, meeting)}
    end

    @width_transition ~r/transition-\[width\]/

    test "a chevron collapse carries the width transition", %{view: view} do
      collapse_by_chevron(view)

      assert strip_class(view) =~ @width_transition,
             "motion there confirms *you did that*"
    end

    test "a MODE-DRIVEN collapse renders with no transition class at all", %{view: view} do
      force_collapsed(view, false)
      set_mode(view, :screen)

      assert assigns(view).chat_panel_collapsed == true
      assert assigns(view).call_rail_animate == false

      refute strip_class(view) =~ @width_transition,
             "nobody asked for this width change, the mode switch did — a " <>
               "slab of screen sliding at you every time you change what you " <>
               "are looking at is the app moving furniture mid-sentence"
    end

    test "a chevron move AFTER a mode change animates again", %{view: view} do
      set_mode(view, :screen)
      refute strip_class(view) =~ @width_transition

      # Out and back, both by hand.
      force_collapsed(view, false)
      force_collapsed(view, true)

      assert strip_class(view) =~ @width_transition
    end

    test "the first paint never animates", %{conn: conn, org: org, viewer: viewer} do
      meeting = meeting!(org, "first-paint")
      view = open_meeting_shell(conn, viewer, meeting)

      assert assigns(view).call_rail_animate == false

      # Gallery is the open default, so drive a fresh mount that starts
      # collapsed the only way a mount can: by mode.
      set_mode(view, :canvas)
      refute strip_class(view) =~ @width_transition
    end
  end
end
