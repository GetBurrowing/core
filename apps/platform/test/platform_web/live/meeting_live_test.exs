defmodule PlatformWeb.MeetingLiveTest do
  @moduledoc """
  Tests for `PlatformWeb.MeetingLive` (ADR 0042).

  ## Embedded chat surface

  Stage 5 of task 019e2d1a swapped the original `MeetingChatPanelLive`
  stub for the real `PlatformWeb.ChatLive` surface in its `:embedded`
  mode (full mentions / attachments / reactions / threading / edit
  support). These tests pin the embed contract: the chat pane in a
  meeting renders the real `<.chat_message>` component, the composer
  form, the mention dropdown trigger, the attachment-upload affordance,
  and the meeting name in the pane header. The
  `data-intent-panel-host="true"` marker survives on the wrapping
  `<div>` for the future intent-panel migration's greppable hook.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias Platform.{Chat, Meetings, Repo}
  alias Platform.Accounts.User
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings.CalendarLink
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.IntentCorrections
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.SenderSeed
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.Meetings.IntentsCollapse
  alias PlatformWeb.Components.Meetings.MeetingDetail

  # Org plumbing (task 019f9b14 stage 2): `/meetings/:slug` now resolves
  # through `Meetings.fetch_meeting_for_user/2`, which requires the viewer to
  # hold an `org_memberships` row in the meeting's org. Real users always have
  # one — `Accounts.find_or_create_from_oidc/1` inserts a Fabrikam-root membership
  # on signup — so the fixture mirrors that shape. `@example.com` keeps
  # `derive_role_from_email/1` at `:member`; a `@example.com` address would
  # derive admin and blanket-bypass the check these tests rely on.
  defp authenticated_conn(conn, user \\ nil) do
    user =
      user ||
        Repo.insert!(%User{
          email: "meeting_test_#{System.unique_integer([:positive])}@example.com",
          name: "Meeting Test User",
          oidc_sub: "oidc-meeting-test-#{System.unique_integer([:positive])}"
        })

    member!(user, Platform.TenancyFixtures.fabrikam_org_id())

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp member!(user, org_id, role \\ "member") do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Meeting Space #{System.unique_integer([:positive])}",
        slug: "meeting-space-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp create_project do
    # ADR 0042: projects require an org_id. Default to the root Fabrikam org so
    # legacy fixtures (which never named an org) keep working untouched.
    create_project(Platform.TenancyFixtures.fabrikam_org_id())
  end

  defp create_project(org_id) do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Meeting Project #{System.unique_integer([:positive])}",
        slug: "meeting-project-#{System.unique_integer([:positive])}",
        org_id: org_id
      })
      |> Repo.insert()

    project
  end

  # Returns just the opening tag of `#meeting-whiteboard-host`, so a
  # `refute ... =~ "data-active"` is scoped to that node instead of matching
  # any of the several `data-active` attributes elsewhere on the page (the
  # stage-mode buttons all carry one).
  defp host_element(html) do
    case Regex.run(~r/<div[^>]*id="meeting-whiteboard-host"[^>]*>/, html) do
      [tag] -> tag
      nil -> flunk("no #meeting-whiteboard-host element in the rendered page")
    end
  end

  defp create_meeting(attrs) do
    space = Map.get_lazy(attrs, :space, fn -> create_space() end)
    project = Map.get_lazy(attrs, :project, fn -> create_project() end)
    meeting_id = Platform.Types.UUIDv7.generate()

    creator_attrs = %{
      project_id: project.id,
      chat_space_id: space.id,
      slug: Map.get(attrs, :slug, "kickoff-#{System.unique_integer([:positive])}"),
      name: Map.get(attrs, :name, "Kickoff"),
      livekit_room_name: "meeting-#{meeting_id}",
      host_participant_id: Map.get(attrs, :host_participant_id)
    }

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(creator_attrs)
      |> Repo.insert()

    {meeting, space}
  end

  # Seed a LIVE meeting presence participant for `space` (task 019e4b3e:
  # the rail/gallery now source from `Meetings.active_participants_for_space/1`,
  # not durable chat membership). Ensures+activates the room, then inserts a
  # `Meetings.Participant`. For `"user"` it creates a backing User so the
  # preloaded identity resolves to a real name; for `"agent"` it creates a
  # backing Agent. Returns the user/agent id used as the LiveKit identity.
  defp seed_meeting_presence(space, participant_type, display_name) do
    {:ok, room} = Platform.Meetings.ensure_room(space.id)
    {:ok, room} = Platform.Meetings.activate_room(room)

    attrs =
      case participant_type do
        "agent" ->
          agent =
            Repo.insert!(%Platform.Agents.Agent{
              slug: "agent-#{System.unique_integer([:positive])}",
              name: display_name,
              status: "active"
            })

          %{agent_id: agent.id, display_name: display_name}

        _ ->
          user =
            Repo.insert!(%User{
              email: "seed_#{System.unique_integer([:positive])}@example.com",
              name: display_name,
              oidc_sub: "oidc-seed-#{System.unique_integer([:positive])}"
            })

          %{user_id: user.id, display_name: display_name}
      end

    {:ok, participant} = Platform.Meetings.participant_joined(room, attrs)
    {participant, attrs[:user_id] || attrs[:agent_id]}
  end

  defp seed_message(space, display_name, content) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    {participant, message}
  end

  # Isolate the caption-bar OUTER shell's opening tag from the rest of
  # the rendered HTML so class/attribute assertions in the caption-bar
  # describe block don't false-match the center stage's `data-stage-mode`
  # attribute (emitted at ~line 455 of meeting_live.html.heex on the
  # main video pane wrapper) or the inner `#meeting-captions` hook host
  # (which has `phx-update="ignore"` and stable attributes). The shell
  # is where the dynamic `hidden` class + `data-stage-mode` mirror live.
  defp caption_bar_shell_open_tag(html) do
    case Regex.run(~r/<div[^>]*data-role="meeting-captions-shell"[^>]*>/, html) do
      [tag] -> tag
      nil -> nil
    end
  end

  # The caption shell's `class` attribute, parsed rather than regexed, so an
  # assertion about a class is an assertion about the CLASS LIST and not about
  # a substring that happens to appear anywhere in the opening tag. Raises
  # when the shell is absent — a nil class list would make every `refute`
  # below it vacuously true.
  # The `[data-pane="bottom-strip"]` footer's class attribute, as one
  # string. Used only to pin which `@shell?` branch the template selected;
  # see the block comment on the safe-area describe below for why a class
  # string proves nothing about geometry.
  defp bottom_strip_class(html) do
    [class] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-pane="bottom-strip"]))
      |> LazyHTML.attribute("class")

    class
  end

  defp caption_bar_shell_class(html) do
    [class] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="meeting-captions-shell"]))
      |> LazyHTML.attribute("class")

    class
  end

  describe "route resolution" do
    test "/meetings/:slug resolves and mounts the meeting shell", %{conn: conn} do
      {meeting, _space} = create_meeting(%{slug: "kickoff-route", name: "Kickoff"})
      {conn, _user} = authenticated_conn(conn)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ meeting.name
    end

    test "/meetings index route resolves with a placeholder", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)

      {:ok, _view, html} = live(conn, ~p"/meetings")

      assert html =~ "Meetings"
    end

    test "unknown slug redirects to /meetings without crashing", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)

      assert {:error, {:live_redirect, %{to: "/meetings"}}} =
               live(conn, ~p"/meetings/does-not-exist")
    end
  end

  describe "route authorization (:show)" do
    # The gate is `Meetings.fetch_meeting_for_user/2`, keyed off
    # `:current_user_record` (the real User with `:org_memberships`), NOT the
    # `:user_id` assign — `mount/3` fabricates a UUID for sessionless mounts,
    # so `:user_id` is a canvas-author placeholder and never an authz subject.

    test "a viewer with no membership in the meeting's org is redirected away", %{conn: conn} do
      project = create_project(Platform.TenancyFixtures.tenant_org_id("soylent"))
      {meeting, _space} = create_meeting(%{project: project, name: "Soylent Only"})

      # Fabrikam-root membership at :member level — the shape every OIDC signup
      # has, and not a membership in the meeting's org.
      {conn, _user} = authenticated_conn(conn)

      assert {:error, {:live_redirect, %{to: "/meetings"}}} =
               live(conn, ~p"/meetings/#{meeting.slug}")
    end

    test "denial is indistinguishable from a genuinely absent slug", %{conn: conn} do
      project = create_project(Platform.TenancyFixtures.tenant_org_id("soylent"))
      {meeting, _space} = create_meeting(%{project: project, name: "Oracle Probe"})
      {conn, _user} = authenticated_conn(conn)

      assert {:error, {:live_redirect, %{to: "/meetings", flash: denied}}} =
               live(conn, ~p"/meetings/#{meeting.slug}")

      assert {:error, {:live_redirect, %{to: "/meetings", flash: absent}}} =
               live(conn, ~p"/meetings/no-such-meeting-at-all")

      assert denied["error"] == "Meeting not found."
      assert denied == absent
    end

    test "a denied mount subscribes to none of the meeting's topics", %{conn: conn} do
      project = create_project(Platform.TenancyFixtures.tenant_org_id("wayne_tech"))
      {meeting, space} = create_meeting(%{project: project, name: "No Side Effects"})
      {conn, _user} = authenticated_conn(conn)

      # The test process joins the topics the success body would have
      # subscribed the viewer to, so a broadcast proves they are live.
      ChatPubSub.subscribe(space.id)
      MeetingsPubSub.subscribe_presence(space.id)

      assert {:error, {:live_redirect, %{to: "/meetings"}}} =
               live(conn, ~p"/meetings/#{meeting.slug}")

      # `:auto_join` mints a LiveKit token and flips a scheduled meeting to
      # live. A denied mount must never reach it.
      assert Repo.get!(Meeting, meeting.id).status == "scheduled"
      assert Meetings.active_participants_for_space(space.id) == []
    end

    test "a member of the meeting's org mounts normally", %{conn: conn} do
      org_id = Platform.TenancyFixtures.tenant_org_id("soylent")
      project = create_project(org_id)
      {meeting, _space} = create_meeting(%{project: project, name: "Soylent Standup"})
      {conn, user} = authenticated_conn(conn)
      member!(user, org_id)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ meeting.name
      assert html =~ ~s(data-intent-panel-host="true")
    end

    test "a slug matching meetings in two of the viewer's orgs gets the ambiguity flash",
         %{conn: conn} do
      soylent_id = Platform.TenancyFixtures.tenant_org_id("soylent")
      wayne_tech_id = Platform.TenancyFixtures.tenant_org_id("wayne_tech")

      {meeting, _space} =
        create_meeting(%{project: create_project(soylent_id), slug: "standup", name: "A"})

      {_other, _space} =
        create_meeting(%{project: create_project(wayne_tech_id), slug: "standup", name: "B"})

      {conn, user} = authenticated_conn(conn)
      member!(user, soylent_id)
      member!(user, wayne_tech_id)

      # Notably this does NOT raise Ecto.MultipleResultsError, which the
      # unscoped `Repo.get_by(Meeting, slug: slug)` read did.
      assert {:error, {:live_redirect, %{to: "/meetings", flash: flash}}} =
               live(conn, ~p"/meetings/#{meeting.slug}")

      assert flash["error"] ==
               "That link matches more than one meeting. Open it from the Meetings list."
    end
  end

  describe "meeting lifecycle (start on auto-join)" do
    test "auto-joining a scheduled meeting transitions it to live", %{conn: conn} do
      {meeting, _space} = create_meeting(%{slug: "lifecycle-start", name: "Lifecycle Start"})
      {conn, _user} = authenticated_conn(conn)

      assert meeting.status == "scheduled"
      assert is_nil(meeting.started_at)

      # Connected mount fires `:auto_join`, which now flips a scheduled
      # meeting to live before delegating to MeetingHooks.join/1.
      {:ok, _view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      started = Repo.get!(Meeting, meeting.id)
      assert started.status == "live"
      refute is_nil(started.started_at)
    end

    test "opening with ?no_autojoin=true leaves a scheduled meeting scheduled", %{conn: conn} do
      {meeting, _space} = create_meeting(%{slug: "lifecycle-noauto", name: "Lifecycle No Auto"})
      {conn, _user} = authenticated_conn(conn)

      {:ok, _view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      still = Repo.get!(Meeting, meeting.id)
      assert still.status == "scheduled"
    end
  end

  describe "shell skeleton (:show)" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "kickoff-shell", name: "Kickoff Sync"})
      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "renders the placeholder panes", %{conn: conn, meeting: meeting} do
      # Gallery-default reframe (stage 3, task 019e2d1a): the bottom
      # strip is hidden in gallery mode (the grid is the full face-grid),
      # so on default mount it's absent. We assert its presence here by
      # switching to canvas mode first — the test guarantees the strip
      # *can* render, not that it's always present.
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-pane="call-rail")
      assert html =~ ~s(data-pane="center-stage")
      # `data-pane="chat-panel"` was the chat DRAWER, deleted in task
      # 01a084bf stage 3. The pane it hosted is now the rail's Chat tab, so
      # the skeleton's third pane is the chat BODY inside the rail.
      assert html =~ ~s(data-pane="meeting-chat-panel")
      # On default-gallery mount, the strip is intentionally hidden.
      refute html =~ ~s(data-pane="bottom-strip")

      # Flip to canvas mode and the strip reappears as the compact
      # "who's here" footer.
      canvas_html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      assert canvas_html =~ ~s(data-pane="bottom-strip")
    end

    test "center stage carries data-stage-mode='gallery' by default", %{
      conn: conn,
      meeting: meeting
    } do
      # Gallery-default reframe (stage 3, task 019e2d1a): the meeting
      # opens face-first. Previously canvas was the default; the bottom
      # strip is now hidden in gallery so the grid owns the full
      # vertical area, and switching to canvas/screen/whiteboard reveals
      # the strip as the compact "who's here" footer.
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-stage-mode="gallery")
    end

    test "top bar shows the meeting name", %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ "Kickoff Sync"
    end

    test "top bar renders 4 segmented-control buttons with hero-icon classes", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ "hero-rectangle-stack"
      assert html =~ "hero-computer-desktop"
      assert html =~ "hero-squares-2x2"
      assert html =~ "hero-pencil-square"
    end

    test "renders without forcing a local data-theme override (inherits shell theme)",
         %{conn: conn, meeting: meeting} do
      # Task 019e40ed: meetings used to hardcode `data-theme="light"` on
      # the LV root, overriding the shell's dark mode. The wrapper must
      # rely on the `data-theme` attribute set on `<html>` by the layout
      # in `root.html.heex` instead — so neither "light" nor "dark"
      # should appear as a local LV-rendered override.
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      refute html =~ ~s(data-theme="light")
      refute html =~ ~s(data-theme="dark")
    end
  end

  describe "chat-panel framing — the drawer's, re-pointed at the rail (stage 2, task 01a084bf)" do
    # These four cases pinned the framing of `<aside id="meeting-chat-drawer">`:
    # a `w-80` desktop column and a `data-pane-section="header"` naming the
    # meeting. Task 01a084bf stage 3 DELETED that aside and moved its single
    # `live_render` into the call rail's Chat pane, so the framing they
    # described is now the RAIL's framing. They are re-pointed rather than
    # dropped: each one still asserts the property it was written to protect,
    # against the element that now owns it.

    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{slug: "kickoff-header", name: "Stage Two Header"})

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "the chat pane is the rail's 312px column, and the 320px drawer is gone", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # WAS: `data-pane="chat-panel"` co-occurring with `w-80`, pinning the
      # drawer's ~320px desktop framing. That aside no longer exists, and a
      # bare `refute` on `w-80` would pass for the wrong reason the moment
      # anything else on this screen used that utility — so assert the
      # POSITIVE replacement too.
      refute html =~ ~s(data-pane="chat-panel")
      refute html =~ ~r/data-pane="chat-panel"[^>]*w-80|w-80[^>]*data-pane="chat-panel"/

      # The chat body is now a DESCENDANT of the one call-rail node, whose
      # expanded desktop width is 312px.
      assert count(
               html,
               ~s([data-pane="call-rail"] [data-pane="meeting-chat-panel"])
             ) == 1

      [rail_class] =
        html |> within(~s([data-pane="call-rail"])) |> LazyHTML.attribute("class")

      assert "lg:w-[312px]" in String.split(rail_class)
    end

    test "the pane is identified by the rail's Chat tab, not by a drawer header", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # WAS: `data-pane-section="header"` + the meeting name, i.e. the
      # drawer's own titled header. The rail names its panes with a tab
      # strip, so a second header inside one pane would be redundant chrome
      # in a 312px column. What must still hold is that the pane is
      # IDENTIFIED at all.
      assert count(html, ~s([data-role="call-rail-tab"][data-tab="chat"])) == 1

      # The meeting name is still on the page — it moved nowhere, the top
      # bar has always carried it. This is what the original assertion was
      # really checking once the header it named is gone.
      assert html =~ "Stage Two Header"
    end

    test "the 'placeholder for intent panel' caption is still gone (stage 5 swap)",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Unchanged by the move, and deliberately kept: stage 5 of 019e2d1a
      # replaced the stub `MeetingChatPanelLive` with the real ChatLive
      # embed, and this refutation is what stops the stub's caption coming
      # back. The greppable migration hook is the
      # `data-intent-panel-host` attribute, which travelled with the body.
      refute html =~ "placeholder for intent panel"
      assert html =~ ~s(data-intent-panel-host="true")
    end

    test "the chat glyph is a hero-icon, never an emoji", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Unchanged in substance: the glyph now appears on the top-bar
      # control and on the rail's Chat tab rather than in a drawer header,
      # and the no-emoji rule is a whole-chrome rule either way.
      assert html =~ "hero-chat-bubble-left-right"
      refute html =~ "💬"
      refute html =~ "💭"
    end
  end

  describe "embedded chat panel — render path (stage 5: real ChatLive embed)" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "kickoff-chat", name: "Kickoff Chat"})
      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "wrapping pane root carries data-intent-panel-host=\"true\" (migration marker)",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # The marker moved off the (now-deleted) stub root onto the
      # wrapping `<div>` around the `live_render`. The data-pane
      # marker co-locates so a future grep lands on the swap-out site.
      assert html =~ ~s(data-intent-panel-host="true")
      assert html =~ ~s(data-pane="meeting-chat-panel")
    end

    test "panel renders the meeting's chat-space messages via the real <.chat_message> component",
         %{conn: conn, meeting: meeting, space: space} do
      {_p1, _m1} = seed_message(space, "Alice", "first message")
      {_p2, _m2} = seed_message(space, "Bob", "second message")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      panel_view = find_live_child(view, "meeting-chat-panel-#{meeting.id}")
      panel_html = render(panel_view)

      assert panel_html =~ "first message"
      assert panel_html =~ "second message"
      assert panel_html =~ "Alice"
      assert panel_html =~ "Bob"

      # The real chat_message component emits `data-message-id` on
      # every rendered bubble — the grep marker the stage 5 spec calls
      # for to confirm the embed uses the canonical component (rather
      # than a re-implementation).
      assert panel_html =~ ~s(data-message-id=)

      # The stream container the canonical component renders into.
      assert panel_html =~ ~s(id="message-list")
    end

    test "messages from a *different* space do NOT bleed into the panel", %{
      conn: conn,
      meeting: meeting
    } do
      other_space = create_space()
      seed_message(other_space, "Eve", "this should not appear")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      panel_view = find_live_child(view, "meeting-chat-panel-#{meeting.id}")
      panel_html = render(panel_view)

      refute panel_html =~ "this should not appear"
    end

    test "panel exposes the canonical compose-form with the @mention-aware textarea",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      panel_view = find_live_child(view, "meeting-chat-panel-#{meeting.id}")
      panel_html = render(panel_view)

      # The real composer form id + name. ChatLive's textarea is
      # named `compose[text]` (not the stub's `composer[text]`), so a
      # passing test here also proves we're rendering the embedded
      # ChatLive, not a remnant stub.
      assert panel_html =~ ~s(id="compose-form")
      assert panel_html =~ ~s(name="compose[text]")
    end

    test "panel exposes the attachment-upload affordance (real upload pipeline)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      panel_view = find_live_child(view, "meeting-chat-panel-#{meeting.id}")
      panel_html = render(panel_view)

      # ChatLive's compose-attach button + the DragDropUpload drop-zone
      # hook. The stub had neither.
      assert panel_html =~ ~s(id="compose-attach-button")
      assert panel_html =~ ~s(phx-hook="DragDropUpload")
    end

    test "submitting the composer persists a message to the chat space when viewer is a participant",
         %{conn: conn, meeting: meeting, space: space} do
      {conn, user} = authenticated_conn(conn)

      {:ok, _participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: "Composer Author",
          joined_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      panel_view = find_live_child(view, "meeting-chat-panel-#{meeting.id}")

      panel_view
      |> form("form#compose-form", compose: %{text: "hello from composer"})
      |> render_submit()

      messages = Chat.list_messages(space.id, top_level_only: true)
      assert Enum.any?(messages, &(&1.content == "hello from composer"))
    end

    test "typing '@' in the composer surfaces the mention dropdown", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      # Seed an agent participant so there is a mention target. ChatLive's
      # mention pipeline only lists agent-typed participants in the
      # dropdown by default.
      {:ok, _agent} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Mention Bot",
          joined_at: DateTime.utc_now()
        })

      {conn, user} = authenticated_conn(conn)

      {:ok, _participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: "Mention Author",
          joined_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      panel_view = find_live_child(view, "meeting-chat-panel-#{meeting.id}")

      # ChatLive's mention pipeline is wired to the JS-side ComposeInput
      # hook, which pushes `mention_query` when the user types `@<query>`.
      # Simulate that event directly — the server-side handler scans
      # `:participants_map`, populates `:mention_suggestions`, and the
      # template renders the dropdown with
      # `data-mention-suggestion="first"` on the first hit.
      render_hook(panel_view, "mention_query", %{"query" => "", "source" => "compose-form"})

      panel_html = render(panel_view)

      assert panel_html =~ ~s(data-mention-suggestion="first"),
             "expected mention dropdown to render after `mention_query` event"

      # And the agent we seeded is in the dropdown.
      assert panel_html =~ "Mention Bot"
    end

    test "panel updates in real time when a message is broadcast on the space topic", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      task =
        Task.async(fn ->
          {:ok, p} =
            Chat.add_participant(space.id, %{
              participant_type: "user",
              participant_id: Ecto.UUID.generate(),
              display_name: "Outside Process",
              joined_at: DateTime.utc_now()
            })

          {:ok, msg} =
            Chat.post_message(%{
              space_id: space.id,
              participant_id: p.id,
              content_type: "text",
              content: "real-time delivery"
            })

          msg
        end)

      _msg = Task.await(task)

      _ = render(view)

      panel_view = find_live_child(view, "meeting-chat-panel-#{meeting.id}")
      panel_html = render(panel_view)

      assert panel_html =~ "real-time delivery"
    end
  end

  describe "chat opens in the rail (was: mobile drawer + toggle, stage 3)" do
    # Task 01a084bf stage 3 deleted `<aside id="meeting-chat-drawer">`, its
    # `data-role="chat-panel-backdrop"`, its `data-role="chat-panel-close"`
    # and the `:chat_panel_open` assign the three of them shared. The one
    # `PlatformWeb.ChatLive.Embedded` `live_render` MOVED into the call
    # rail's Chat pane; `"toggle_chat_panel"` survives as the event the top
    # bar pushes and now OPENS that rail on the Chat tab.
    #
    # Every case below is the original re-pointed at whatever now owns the
    # property it was protecting. None was deleted to make the suite green,
    # and each names what it used to assert.

    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{slug: "kickoff-drawer", name: "Drawer Meeting"})

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "mounts with chat NOT the active pane, and no drawer anywhere", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # WAS: `data-chat-panel-open="false"`, read off the drawer aside as a
      # proxy for the `:chat_panel_open` assign. Both are gone. The
      # equivalent default is that the rail does not open ON Chat.
      refute html =~ ~s(id="meeting-chat-drawer")
      refute html =~ ~s(data-chat-panel-open)

      assert count(html, ~s([data-role="call-rail-chat-wrap"][data-active="false"])) == 1

      [tab_attrs] =
        html
        |> within(~s([data-role="call-rail-tab"][data-tab="chat"]))
        |> LazyHTML.attribute("aria-selected")

      assert tab_attrs == "false"
    end

    test "the top-bar chat control survives, is no longer lg-hidden, and points at the rail",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-role="chat-panel-toggle")
      assert html =~ ~s(phx-click="toggle_chat_panel")
      assert html =~ "hero-chat-bubble-left-right"
      refute html =~ "💬"

      [toggle_class] =
        html |> within(~s([data-role="chat-panel-toggle"])) |> LazyHTML.attribute("class")

      # WAS: an assertion that this button carries `lg:hidden`, on the
      # reasoning that the desktop right column was always visible. That was
      # the defect — the drawer it opened was `lg:!hidden`, so from `lg` up
      # the click had nowhere to land. It must NOT be `lg:hidden` now.
      refute "lg:hidden" in String.split(toggle_class)

      # And it names the surface it actually controls.
      [controls] =
        html |> within(~s([data-role="chat-panel-toggle"])) |> LazyHTML.attribute("aria-controls")

      assert controls == "meeting-call-rail-pane"
      assert count(html, "#meeting-call-rail-pane") == 1
    end

    test "clicking the top-bar control opens the rail ON the Chat tab, expanded", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # WAS: "flips :chat_panel_open and renders the backdrop". The backdrop
      # is deleted with the drawer, so the observable is the rail's state.
      refute html =~ ~s(data-role="chat-panel-backdrop")

      opened = view |> element(~s([data-role="chat-panel-toggle"])) |> render_click()

      # The Chat pane is the one on screen…
      assert count(opened, ~s([data-role="call-rail-chat-wrap"][data-active="true"])) == 1

      # …the rail is expanded rather than the 44px strip (the desktop half
      # of the fix: a click that lands on a collapsed rail would be another
      # invisible surface)…
      [rail_attrs] = call_rail_panes(opened)
      assert rail_attrs["data-collapsed"] == "false"

      # …and the `<lg` drawer is latched open (the mobile half).
      assert rail_attrs["data-call-rail-open"] == "true"

      # The chat backdrop never comes back.
      refute opened =~ ~s(data-role="chat-panel-backdrop")
    end

    test "below lg the rail SHEET's backdrop is what dismisses chat now", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # WAS: "backdrop click also toggles the drawer closed", driven through
      # `data-role="chat-panel-backdrop"`, then re-pointed at the rail
      # drawer's `call-rail-backdrop`. Task 01a07410 stage 3 retired that
      # drawer: below `lg` the rail lives in a `PlatformWeb.Components.Sheet`
      # (see `meeting_live_mobile_sheets_test.exs`), so the ONE backdrop is
      # the sheet's own, and it dismisses to `close_call_rail`.
      _ = render_hook(view, "meeting_viewport", %{"below" => true})
      opened = view |> element(~s([data-role="chat-panel-toggle"])) |> render_click()

      refute opened =~ ~s(data-role="chat-panel-backdrop")
      refute opened =~ ~s(data-role="call-rail-backdrop")
      assert count(opened, "#meeting-rail-sheet .sheet-backdrop") == 1
      assert count(opened, ~s(#meeting-rail-sheet[data-open="true"])) == 1

      closed = view |> element("#meeting-rail-sheet .sheet-backdrop") |> render_click()

      [rail_attrs] = call_rail_panes(closed)
      assert rail_attrs["data-call-rail-open"] == "false"
      assert count(closed, ~s(#meeting-rail-sheet[data-open="false"])) == 1
    end

    test "the sheet's own close button replaces the in-drawer close", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # WAS: `data-role="chat-panel-close"` inside the drawer header, then
      # the rail drawer's `call-rail-close` bar. Both are gone (task
      # 01a07410 stage 3): the sheet carries the close, and a second close
      # inside the pane would be two ways to do one thing.
      _ = render_hook(view, "meeting_viewport", %{"below" => true})
      opened = view |> element(~s([data-role="chat-panel-toggle"])) |> render_click()
      refute opened =~ ~s(data-role="chat-panel-close")
      refute opened =~ ~s(data-role="call-rail-close")

      closed =
        view
        |> element(~s(#meeting-rail-sheet .sheet-header button[aria-label="Close"]))
        |> render_click()

      [rail_attrs] = call_rail_panes(closed)
      assert rail_attrs["data-call-rail-open"] == "false"
    end

    @tag :single_mount_guard
    test "EXACTLY ONE ChatLive.Embedded mount in the document — never two, never none", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # THE SINGLE-MOUNT GUARD (task 01a084bf stage 3). The move is only
      # correct if it was a MOVE: chat rendered twice passes a screenshot
      # review and then loses someone's scroll position in a real call,
      # because two `live_render`s of one child id collide.
      #
      # `== 1`, never `>= 1`: the whole failure this guards is a SECOND
      # mount, and `>=` cannot see it. Counted two independent ways, since
      # the wrapper attribute and the child LiveView's own root id are
      # separate things that a bad edit can desync.
      #
      # `LazyHTML.query/2`, never `filter/2`: `filter/2` matches only the
      # fragment's ROOT nodes, and both of these are deeply nested inside
      # the rail — it would return `[]` and read as "not there".
      assert count(html, ~s([data-pane="meeting-chat-panel"])) == 1
      assert count(html, ~s([id^="meeting-chat-panel"])) == 1

      # The id-prefix count must be the child LiveView itself, not the
      # wrapper matched twice under two selectors.
      [embed_id] =
        html |> within(~s([id^="meeting-chat-panel"])) |> LazyHTML.attribute("id")

      assert embed_id == "meeting-chat-panel-#{meeting.id}"
      assert find_live_child(view, embed_id)

      # And it holds on the OTHER tabs too, which is the mount-once rule:
      # the wrapper is a persistent sibling of the tab `case`, so switching
      # tabs hides it rather than unmounting it. A `case` branch would make
      # both counts 0 here.
      # No "canvas" here since task 01a0693e: the desktop right rail drops the
      # Canvas tab (the card board is the first-class LEFT rail now), so there is
      # no canvas tab to switch to on this surface.
      for tab <- ["people", "transcript", "chat"] do
        switched =
          view
          |> element(~s([data-role="call-rail-tab"][data-tab="#{tab}"]))
          |> render_click()

        assert count(switched, ~s([data-pane="meeting-chat-panel"])) == 1,
               "chat pane vanished on the #{tab} tab — the mount-once rule was broken"

        assert count(switched, ~s([id^="meeting-chat-panel"])) == 1,
               "chat mount count wrong on the #{tab} tab"
      end
    end

    test "the in-flow rail carries NO viewport-anchored geometry — the `<lg` surface is the sheet",
         %{conn: conn, meeting: meeting} do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # WAS: asserted the drawer's safe-area + bottom-nav bottom offset on
      # the rail. Task 01a07410 stage 3 retired the drawer; below `lg` the
      # rail is inside `PlatformWeb.Components.Sheet`, whose panel geometry
      # (and the shut sheet's peek offset above the bottom nav) lives in
      # app.css. The column frame is in-flow at `lg` and `hidden` below it,
      # and must carry none of the old fixed geometry.
      [rail_class] =
        html |> within(~s([data-pane="call-rail"])) |> LazyHTML.attribute("class")

      tokens = String.split(rail_class)
      assert "hidden" in tokens
      assert "lg:flex" in tokens
      refute "fixed" in tokens
      refute Enum.any?(tokens, &String.starts_with?(&1, "bottom-["))
      refute Enum.any?(tokens, &String.starts_with?(&1, "translate-x"))

      below = render_hook(view, "meeting_viewport", %{"below" => true})
      assert count(below, "#meeting-rail-sheet #meeting-call-rail") == 1
    end

    test "chat is reachable at EVERY width — nothing hides it at lg", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # WAS: "drawer aside keeps its slide-in shape and is drawer-only at
      # lg", which asserted `lg:!hidden` — i.e. it PINNED the defect this
      # task exists to remove. Inverted: the element hosting chat must not
      # be hidden at `lg`, and the rail keeps its `<lg` slide-in shape.
      opened = view |> element(~s([data-role="chat-panel-toggle"])) |> render_click()

      [rail_class] =
        opened |> within(~s([data-pane="call-rail"])) |> LazyHTML.attribute("class")

      rail_classes = String.split(rail_class)

      refute "lg:!hidden" in rail_classes
      # The column frame is flex AT `lg` (task 01a07410 stage 3 replaced the
      # drawer's `translate-x-0` / `lg:static` pair with `hidden lg:flex`;
      # below `lg` chat is reached through the rail sheet instead).
      assert "lg:flex" in rail_classes

      # No ancestor of the chat body may be display:none at lg. The wrap is
      # `hidden`-flipped by tab only, and Chat is the active tab here.
      assert count(opened, ~s([data-role="call-rail-chat-wrap"][data-active="true"])) == 1

      assert count(
               opened,
               ~s([data-role="call-rail-expanded"] [data-pane="meeting-chat-panel"])
             ) == 1
    end

    test "aria-expanded on the top-bar control reports whether chat is the pane on screen", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # WAS: reflected `:chat_panel_open`. That assign is retired; the
      # honest reading is now "is Chat the pane on screen", which is the
      # tab plus the desktop collapse state.
      [before_click] =
        html |> within(~s([data-role="chat-panel-toggle"])) |> LazyHTML.attribute("aria-expanded")

      assert before_click == "false"

      opened = view |> element(~s([data-role="chat-panel-toggle"])) |> render_click()

      [after_click] =
        opened
        |> within(~s([data-role="chat-panel-toggle"]))
        |> LazyHTML.attribute("aria-expanded")

      assert after_click == "true"

      # Leaving the Chat tab makes it false again without touching the rail.
      moved =
        view
        |> element(~s([data-role="call-rail-tab"][data-tab="people"]))
        |> render_click()

      [after_move] =
        moved
        |> within(~s([data-role="chat-panel-toggle"]))
        |> LazyHTML.attribute("aria-expanded")

      assert after_move == "false"
    end
  end

  describe "consolidation pass (stage 5 swap audit)" do
    # Stage 5 (019e2d1a) swapped the MeetingChatPanelLive stub for the
    # real ChatLive embed. The stub-specific defensive paths (root id
    # encoding the chat space, empty-state sentinel id, caption count)
    # are gone; this describe block consolidates the *new* surface
    # contracts: the wrapping div carries the migration marker, the
    # placeholder caption is gone, and the mobile-drawer toggle assign
    # flip stays idempotent.

    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{slug: "kickoff-stage4", name: "Stage Four Audit"})

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "data-intent-panel-host and data-pane='meeting-chat-panel' co-locate on the wrapping div",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # The marker (and the pane-id) live on the wrapping `<div>` around
      # the `live_render` of the embedded ChatLive, not on the embed's
      # own root. Co-locating both attributes on a single element keeps
      # the future-Rowan grep pivot intact.
      assert html =~
               ~r/data-intent-panel-host="true"[^>]*data-pane="meeting-chat-panel"|data-pane="meeting-chat-panel"[^>]*data-intent-panel-host="true"/
    end

    test "placeholder caption is gone (stage 5 contract)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # The stub's "Discussion · placeholder for intent panel (ADR 0042)"
      # caption is removed in the swap. The migration marker moved to
      # the wrapping div's data attributes.
      refute html =~ "placeholder for intent panel"
      refute html =~ "Discussion · placeholder"
    end

    test "asking for chat repeatedly is idempotent (no drift across cycles)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # WAS: three open/CLOSE cycles on `toggle_chat_panel`, guarding against
      # state drift between the assign and the rendered attribute.
      #
      # `"toggle_chat_panel"` no longer toggles (task 01a084bf stage 3): its
      # target is one tab among four rather than a drawer that owned the
      # viewport, so a second click that closed the rail or deselected Chat
      # would leave the viewer on no tab at all. Asking for chat twice asks
      # for the same thing twice. The drift this case exists to catch is
      # therefore tested as IDEMPOTENCE, and the round trip through another
      # tab is what proves the handler still re-selects rather than sticking.
      for _ <- 1..3 do
        opened = view |> element(~s([data-role="chat-panel-toggle"])) |> render_click()

        assert count(opened, ~s([data-role="call-rail-chat-wrap"][data-active="true"])) == 1
        assert count(opened, ~s([data-pane="meeting-chat-panel"])) == 1

        # Pushing it AGAIN must not close, deselect or collapse anything.
        again = view |> element(~s([data-role="chat-panel-toggle"])) |> render_click()

        assert count(again, ~s([data-role="call-rail-chat-wrap"][data-active="true"])) == 1
        assert count(again, ~s([data-pane="meeting-chat-panel"])) == 1

        [rail_attrs] = call_rail_panes(again)
        assert rail_attrs["data-collapsed"] == "false"

        # Leave the tab so the next iteration is a real re-open.
        _ =
          view
          |> element(~s([data-role="call-rail-tab"][data-tab="people"]))
          |> render_click()
      end
    end

    # NOTE: an "empty chat_space binding falls through to the placeholder"
    # test used to live here; it required a meeting row with
    # `chat_space_id: nil`, which the schema's required-field validation
    # now rejects. The template's defensive `:if @meeting.chat_space &&
    # @meeting.chat_space.slug do` branch is still in place as belt-and-
    # suspenders defense (a chat_space row deleted out from under a
    # meeting would fail the preload), but the regression test is gone
    # since the persistence layer now enforces the invariant.
  end

  describe "PubSub topic shape (regression)" do
    test "ChatPubSub.subscribe(space_id) is the topic the embed listens on", %{conn: conn} do
      # Sanity check that ChatPubSub is the public surface the embed
      # binds against — guards against a future refactor that splits
      # the chat topic and forgets to update the embed.
      {meeting, space} = create_meeting(%{slug: "kickoff-pubsub"})
      {conn, _user} = authenticated_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # If the embed isn't subscribed, the broadcast just no-ops; if
      # it IS subscribed, the message lands in the panel HTML.
      ChatPubSub.broadcast(space.id, {:new_message, build_test_message(space.id)})

      _ = render(view)
      panel_view = find_live_child(view, "meeting-chat-panel-#{meeting.id}")
      panel_html = render(panel_view)

      assert panel_html =~ "topic-probe"
    end

    defp build_test_message(space_id) do
      %Platform.Chat.Message{
        id: Platform.Types.UUIDv7.generate(),
        space_id: space_id,
        content: "topic-probe",
        content_type: "text",
        author_display_name: "Probe",
        inserted_at: DateTime.utc_now()
      }
    end
  end

  # ── Stage-mode switcher (task 019e2474-bc7c) ───────────────────────────────

  describe "stage-mode segmented control (set_stage_mode)" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "stage-mode-seg", name: "Stage Mode Sync"})
      {conn, _user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space}
    end

    test "defaults to gallery mode with the gallery button active", %{
      conn: conn,
      meeting: meeting
    } do
      # Gallery-default reframe (stage 3, task 019e2d1a): the meeting
      # opens face-first — gallery is the default mode.
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-stage-mode-button="gallery")
      # The gallery button is active; the others are not.
      assert html =~ ~r/data-stage-mode-button="gallery"[^>]*data-active="true"/
      assert html =~ ~r/data-stage-mode-button="canvas"[^>]*data-active="false"/
      assert html =~ ~r/data-stage-mode-button="screen"[^>]*data-active="false"/
    end

    test "the shelf renders one button per stage mode, each list-driven from stage_modes/0",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Every mode in the single source of truth renders a button; nothing
      # else does — so a new mode is one list entry, not hand-copied markup.
      modes = PlatformWeb.MeetingLive.stage_modes()
      assert modes == [:canvas, :screen, :gallery, :whiteboard]

      for mode <- modes do
        assert has_element?(
                 view,
                 ~s([data-stage-mode-control='active'] [data-stage-mode-button='#{mode}'])
               )
      end
    end

    test "each stage-mode entry carries a distinct hero-icon and an aria-label naming it",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Whiteboard and the rest each read as a first-class, iconned entry in
      # the shelf — icon glyph inside the button, aria-label naming the mode.
      expected = [
        {"gallery", "Gallery", "hero-squares-2x2"},
        {"screen", "Screen", "hero-computer-desktop"},
        {"canvas", "Canvas", "hero-rectangle-stack"},
        {"whiteboard", "Whiteboard", "hero-pencil-square"}
      ]

      for {mode, label, icon} <- expected do
        assert has_element?(
                 view,
                 ~s([data-stage-mode-button='#{mode}'][aria-label='#{label}'] .#{icon})
               )
      end
    end

    test "clicking a mode button assigns that mode and flips the active class", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      for mode <- ~w(screen gallery whiteboard canvas) do
        html =
          view
          |> element(~s([data-stage-mode-button="#{mode}"]))
          |> render_click()

        # The clicked button is now active; the center stage's
        # data-stage-mode attribute follows.
        assert html =~ ~r/data-stage-mode-button="#{mode}"[^>]*data-active="true"/
        assert html =~ ~s(data-stage-mode="#{mode}")

        # Exactly one button is active at a time.
        active_count =
          Regex.scan(~r/data-stage-mode-button="[a-z]+"[^>]*data-active="true"/, html)
          |> length()

        assert active_count == 1
      end
    end

    test "starting a screen share auto-switches the stage to Screen mode", %{
      conn: conn,
      meeting: meeting
    } do
      # Screen-share-not-displaying fix: the top-bar share button lives in
      # every stage mode, but the share track only has a render target
      # (`[data-screen-share-slot]` + the `MeetingScreenShare` hook) in Screen
      # mode. A sharer in the default Gallery mode published the track into a
      # slot that wasn't mounted and saw nothing. The `MeetingShareButton` hook
      # mirrors the post-toggle state via `meeting_screen_share_state`; on
      # enable we flip the stage to Screen so the slot is in the DOM.
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert html =~ ~s(data-stage-mode="gallery")

      html = render_hook(view, "meeting_screen_share_state", %{"enabled" => true})

      assert html =~ ~s(data-stage-mode="screen"),
             "starting a share must switch the center stage to Screen mode"

      assert html =~ ~r/data-stage-mode-button="screen"[^>]*data-active="true"/
      # The screen-share render target is now mounted.
      assert html =~ "data-screen-share-slot"
    end

    test "stopping a screen share leaves the stage where the user put it", %{
      conn: conn,
      meeting: meeting
    } do
      # On disable we deliberately do NOT yank the stage back — a jarring jump
      # away from whatever the user navigated to. We only auto-switch on the
      # start (enable) edge.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Park the user in Canvas mode.
      view
      |> element(~s([data-stage-mode-button="canvas"]))
      |> render_click()

      html = render_hook(view, "meeting_screen_share_state", %{"enabled" => false})

      assert html =~ ~s(data-stage-mode="canvas"),
             "stopping a share must not move the stage off the user's chosen mode"
    end

    test "an unknown mode value is ignored — no crash, mode unchanged", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Switch to gallery first so we can prove the bogus event is a no-op.
      view
      |> element(~s([data-stage-mode-button="gallery"]))
      |> render_click()

      # A hand-crafted phx-click with an out-of-allow-list mode.
      html = render_click(view, "set_stage_mode", %{"mode" => "admin_only"})

      # Still gallery — the unknown mode was clamped away, no FunctionClauseError.
      assert html =~ ~s(data-stage-mode="gallery")
      assert html =~ ~r/data-stage-mode-button="gallery"[^>]*data-active="true"/
    end

    test "switching modes keeps the sibling panes mounted", %{
      conn: conn,
      meeting: meeting
    } do
      # Gallery-default reframe (stage 3, task 019e2d1a): the bottom
      # strip is intentionally hidden in gallery mode (the grid is the
      # face-grid), so we switch to canvas here to assert the strip is
      # re-mountable post-flip. Left rail is mode-independent on every
      # mode.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      # Call rail + bottom strip are presentation-independent of the
      # non-gallery stage modes — they must survive a mode switch.
      assert html =~ ~s(data-pane="call-rail")
      assert html =~ ~s(data-pane="bottom-strip")
    end

    test "walking all 4 modes flips data-stage-mode each click and never unmounts siblings",
         %{conn: conn, meeting: meeting} do
      # Stage 4 consolidation: a single end-to-end traversal that exercises
      # the per-click center-stage swap *and* the sibling-pane invariant
      # together, matching the e2e_behavior script in the planner payload
      # ("Click each segmented button in order: Canvas, Screen, Gallery,
      # Whiteboard."). Doing this in one test guards against silent
      # ordering-dependent regressions where, say, switching out of Canvas
      # mode tears down the participant rail.
      #
      # Gallery-default reframe (stage 3, task 019e2d1a): the bottom
      # strip is HIDDEN in gallery mode — the grid is the full face-grid
      # and the strip is redundant. The strip must still be present on
      # canvas / screen / whiteboard.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      for mode <- ~w(canvas screen gallery whiteboard) do
        html =
          view
          |> element(~s([data-stage-mode-button="#{mode}"]))
          |> render_click()

        # Center stage's data-stage-mode swaps to the clicked mode…
        assert html =~ ~s(data-stage-mode="#{mode}"),
               "expected center stage to swap to data-stage-mode=\"#{mode}\""

        # …its segmented-control button is the unique active one…
        assert html =~ ~r/data-stage-mode-button="#{mode}"[^>]*data-active="true"/,
               "expected #{mode} button to be the active one"

        active_count =
          Regex.scan(~r/data-stage-mode-button="[a-z]+"[^>]*data-active="true"/, html)
          |> length()

        assert active_count == 1,
               "expected exactly one active button after clicking #{mode}, got #{active_count}"

        # …and the mode-independent panes (left rail, participant rail
        # placeholder) remain mounted on every click.
        assert html =~ ~s(data-pane="call-rail"),
               "call rail unmounted after switching to #{mode}"

        assert html =~ ~s(data-component="participant-rail"),
               "participant rail unmounted after switching to #{mode}"

        # Bottom strip is present in canvas/screen/whiteboard, hidden in
        # gallery (the grid owns the full vertical area there).
        if mode == "gallery" do
          refute html =~ ~s(data-pane="bottom-strip"),
                 "bottom strip should be hidden in gallery mode"
        else
          assert html =~ ~s(data-pane="bottom-strip"),
                 "bottom strip unmounted after switching to #{mode}"
        end
      end
    end

    # ── Whiteboard host (task 019fcfcf stage 3) ──────────────────────────
    # The Excalidraw React root holds the ONLY copy of an in-progress
    # drawing — there is no `window.__livekit_room` equivalent to re-attach
    # from. So the host div must be rendered for every stage mode and never
    # removed; if it were inside the mode `cond`, switching to Gallery would
    # destroy the hook and the strokes with it.
    test "the whiteboard host is rendered in gallery mode, outside the stage-mode cond", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Default mode is gallery — the host is present anyway.
      assert html =~ ~s(data-stage-mode="gallery")
      assert html =~ ~s(id="meeting-whiteboard-host")

      # Negative twin. Without this, "the host is in the DOM" would pass for
      # a page that renders every mode's markup unconditionally: the
      # whiteboard-mode-only fallback must NOT be present in gallery, and
      # must appear once we switch.
      refute html =~ "data-whiteboard-fallback"

      whiteboard_html =
        view
        |> element(~s([data-stage-mode-button="whiteboard"]))
        |> render_click()

      assert whiteboard_html =~ "data-whiteboard-fallback"
      assert whiteboard_html =~ ~s(id="meeting-whiteboard-host")
    end

    test "the whiteboard host survives a walk through every stage mode", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      for mode <- ~w(whiteboard gallery screen whiteboard canvas) do
        html =
          view
          |> element(~s([data-stage-mode-button="#{mode}"]))
          |> render_click()

        assert html =~ ~s(id="meeting-whiteboard-host"),
               "whiteboard host disappeared in #{mode} mode — the React root would be destroyed"
      end
    end

    test "the whiteboard host does not carry a server-rendered active attribute", %{
      conn: conn,
      meeting: meeting
    } do
      # #664: LiveView merges attributes onto a node even under
      # `phx-update="ignore"`, so a stale server-rendered flag can be stamped
      # back over hook-owned state. Visibility here is client-side truth,
      # toggled from the `meeting_stage_mode_changed` push_event.
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      host = host_element(html)
      assert host =~ ~s(phx-update="ignore")
      assert host =~ ~s(phx-hook="MeetingWhiteboard")
      refute host =~ "data-active"

      whiteboard_html =
        view
        |> element(~s([data-stage-mode-button="whiteboard"]))
        |> render_click()

      refute host_element(whiteboard_html) =~ "data-active"
    end

    test "whiteboard mode no longer renders the coming-soon placeholder", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html = render_click(view, "set_stage_mode", %{"mode" => "whiteboard"})

      assert html =~ ~s(data-stage-mode="whiteboard")
      refute html =~ ~s(data-coming-soon="whiteboard")
    end

    # v2 (task 019e42f6): the server must emit a race-free relocation signal
    # so the page-level MeetingClient hook can reparent the persistent local
    # <video> into the now-active mode's dock. The bare assign alone gave JS
    # no trigger — these tests pin the SERVER half of the contract (the JS
    # reparent is covered by vitest + the e2e_behavior gate).
    test "clicking a mode button pushes meeting_stage_mode_changed with the mode", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      for mode <- ~w(canvas screen whiteboard gallery) do
        view
        |> element(~s([data-stage-mode-button="#{mode}"]))
        |> render_click()

        assert_push_event(view, "meeting_stage_mode_changed", %{mode: ^mode})
      end
    end

    test "an unknown mode pushes no relocation event", %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # A hand-crafted phx-click with an out-of-allow-list mode hits the
      # `:error` branch — no assign change AND no push_event.
      render_click(view, "set_stage_mode", %{"mode" => "admin_only"})

      refute_push_event(view, "meeting_stage_mode_changed", %{})
    end
  end

  describe "Canvas mode renderer" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "stage-mode-canvas", name: "Canvas Stage"})
      {conn, _user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space}
    end

    test "renders the create-canvas empty-state CTA when no canvas exists", %{
      conn: conn,
      meeting: meeting
    } do
      # Gallery-default reframe (stage 3, task 019e2d1a): the meeting
      # opens in gallery mode, so we switch to canvas first to exercise
      # the empty-state CTA.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      assert html =~ ~s(data-empty-state="canvas")
      assert html =~ "No canvas yet"
      assert html =~ ~s(phx-click="create_meeting_canvas")
      assert html =~ ~s(data-action="create-meeting-canvas")
      # The CTA's icon is the canvas hero glyph (matches the segmented control).
      assert html =~ "hero-rectangle-stack"
    end

    test "renders the most-recently-created canvas when one exists", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Canvas Author",
          joined_at: DateTime.utc_now()
        })

      {:ok, older} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Older canvas"
        })

      {:ok, newer} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Newer canvas"
        })

      # Gallery-default reframe (stage 3, task 019e2d1a): switch to
      # canvas mode so the canvas renderer takes the center stage.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      # The data-canvas-id attribute on the CENTER STAGE points at the
      # newer canvas — older canvases lose to insertion-order tail.
      #
      # Scoped to the stage container as of stage 3 (task 019ff704). The
      # bare `refute html =~ data-canvas-id="<older>"` was correct while
      # the stage was the only element carrying that attribute; the canvas
      # picker now lists every canvas in the space, each row carrying its
      # own `data-canvas-id`, so the unscoped refute was asserting "the
      # older canvas is not offered anywhere", which is not what this test
      # is about and is no longer true by design.
      assert shown_canvas_id(html) == newer.id
      refute shown_canvas_id(html) == older.id

      # The older canvas is still REACHABLE — it is in the picker. This is
      # the other half of the scoping: it pins what replaced the old
      # refute rather than just deleting an assertion.
      assert count(html, ~s([data-role="canvas-picker-option"][data-canvas-id="#{older.id}"])) ==
               1

      # Empty-state CTA does NOT render when a canvas is present.
      refute html =~ "No canvas yet"
    end

    test "clicking the CTA creates a canvas and renders it when viewer is already a participant",
         %{conn: conn, meeting: meeting, space: space} do
      # Stage 1 (019e2d1a): create_meeting_canvas no longer side-effects a
      # join. The viewer must already have a participant row in the
      # meeting's chat space — set one up before clicking the CTA.
      {conn, user} = authenticated_conn(conn)

      {:ok, _participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: "Already Joined",
          joined_at: DateTime.utc_now()
        })

      # Gallery-default reframe (stage 3, task 019e2d1a): switch to
      # canvas mode so the empty-state CTA is reachable.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      assert html =~ "No canvas yet"

      html =
        view
        |> element(~s(button[data-action="create-meeting-canvas"]))
        |> render_click()

      # The empty-state copy is gone and a canvas is now anchored in the stage.
      refute html =~ "No canvas yet"
      assert html =~ ~s(data-canvas-id=)
      assert html =~ "data-stage-mode=\"canvas\""

      # And exactly one new canvas exists in the meeting's space.
      assert [%Platform.Chat.Canvas{}] = Chat.list_canvases(space.id)
    end

    test "clicking the CTA when viewer has no participant row flashes a hint and does NOT create a canvas",
         %{conn: conn, meeting: meeting, space: space} do
      # Stage 1 (019e2d1a): the wrong-trigger participant model is gone.
      # Canvas creation must NOT insert the viewer into the meeting's chat
      # space participants. Refuse the create + flash a hint.
      #
      # Stage 3 (019e2d1a): meeting opens in gallery — switch to canvas
      # mode first so the empty-state CTA is reachable.
      #
      # Stage 4 bugfix (019e2d1a): the auto-join NOW inserts via the
      # Membership bridge, so we use `?no_autojoin=true` to keep the
      # stage-1 negative contract testable in isolation — canvas
      # creation by itself MUST NOT trigger an insert.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      assert html =~ "No canvas yet"

      # Sanity: no participants yet.
      assert Chat.list_participants(space.id) == []

      html =
        view
        |> element(~s(button[data-action="create-meeting-canvas"]))
        |> render_click()

      # Flash hint surfaced + no canvas + no participant row inserted.
      assert html =~ "Join the meeting to create a canvas."
      assert html =~ "No canvas yet"
      assert Chat.list_canvases(space.id) == []
      assert Chat.list_participants(space.id) == []
    end

    test "mount + create_meeting_canvas click leave participants empty when viewer hasn't joined",
         %{conn: conn, meeting: meeting, space: space} do
      # Stage 1 (019e2d1a) contract: neither MeetingLive.mount nor the
      # create_meeting_canvas handler may insert the viewer as a
      # participant in the meeting's chat space. The explicit join lives
      # in the meeting bar / livekit hook in a sibling stage.
      #
      # Stage 3 (019e2d1a): meeting opens in gallery; switch to canvas
      # mode so the CTA button is in the DOM to click.
      #
      # Stage 4 bugfix (019e2d1a): same `?no_autojoin=true` rationale —
      # this test polices the "neither mount nor canvas-create inserts"
      # contract, so we silence the auto-join to isolate the assertion.
      assert Chat.list_participants(space.id) == []

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # After mount: still no participants.
      assert Chat.list_participants(space.id) == []

      view
      |> element(~s([data-stage-mode-button="canvas"]))
      |> render_click()

      # After clicking the CTA: STILL no participants (the click flashes
      # an error rather than inserting one on the fly).
      view
      |> element(~s(button[data-action="create-meeting-canvas"]))
      |> render_click()

      assert Chat.list_participants(space.id) == []
    end

    test "live :canvas_created broadcast on the meeting's space latches the canvas", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      # Gallery-default reframe (stage 3, task 019e2d1a): switch to
      # canvas mode so the empty-state CTA / canvas pane is visible
      # before the broadcast lands and the renderer takes over.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      assert html =~ "No canvas yet"

      {:ok, peer} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Peer",
          joined_at: DateTime.utc_now()
        })

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => peer.id,
          "title" => "Peer canvas"
        })

      # The PubSub broadcast fired by create_canvas/1 should have been
      # delivered to the LV; render to flush.
      html = render(view)

      assert html =~ ~s(data-canvas-id="#{canvas.id}")
      refute html =~ "No canvas yet"
    end
  end

  describe "Whiteboard mode renderer" do
    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{slug: "stage-mode-whiteboard", name: "Whiteboard Stage"})

      {conn, _user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space}
    end

    # Task 019fcfcf stage 3 replaced the "coming soon" card with a real
    # Excalidraw surface. What the server renders in whiteboard mode is now
    # the loading fallback that shows underneath the hook-owned host until
    # the island bundle resolves — the "coming soon" marker is gone, and its
    # absence is asserted here so the placeholder cannot creep back.
    test "renders the loading fallback, not a 'coming soon' card", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="whiteboard"]))
        |> render_click()

      assert html =~ ~s(data-stage-mode="whiteboard")
      assert html =~ "data-whiteboard-fallback"
      assert html =~ "hero-pencil-square"
      refute html =~ ~s(data-coming-soon="whiteboard")
      refute html =~ "Coming soon"
      # And the empty-state canvas CTA is NOT visible in whiteboard mode.
      refute html =~ ~s(data-empty-state="canvas")
    end

    test "mounts the Excalidraw host with a stable id and phx-update=ignore", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="whiteboard"]))
        |> render_click()

      host = host_element(html)
      assert host =~ ~s(id="meeting-whiteboard-host")
      assert host =~ ~s(phx-hook="MeetingWhiteboard")
      assert host =~ ~s(phx-update="ignore")
    end
  end

  describe "whiteboard persistence (task 019fcfcf stage 4)" do
    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{slug: "whiteboard-persist", name: "Whiteboard Persist"})

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space, user: user}
    end

    # The save path authorises with the SAME participant lookup
    # `create_meeting_canvas` uses — whiteboard access rides on the
    # permission model of the chat space the meeting lives in.
    defp wb_join!(space, user, name \\ "Board Editor") do
      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: name,
          joined_at: DateTime.utc_now()
        })

      participant
    end

    defp scene(n),
      do: %{"elements" => [%{"id" => "el-#{n}"}], "appState_subset" => %{}, "files" => %{}}

    test "a participant's save writes; a non-participant's save writes nothing", %{
      conn: conn,
      meeting: meeting,
      space: space,
      user: user
    } do
      # ── Negative half: the viewer is NOT a participant of the space. ──
      # `?no_autojoin=true` matters — a plain mount auto-joins and would
      # hand the viewer the very participant row this half is testing the
      # absence of, making the assertion unfalsifiable.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      refute Enum.any?(Chat.list_participants(space.id), fn p ->
               p.participant_type == "user" and p.participant_id == user.id
             end)

      render_hook(view, "whiteboard_save", %{
        "scene" => scene("intruder"),
        "expected_version" => 0
      })

      assert Meetings.get_whiteboard(meeting.id) == nil
      assert render(view) =~ "Join the meeting to edit the whiteboard"

      # ── Positive control, same test run. Without it, this test would pass
      # for a handler that refuses EVERYONE — including the people the
      # feature exists for. ──
      wb_join!(space, user)
      {:ok, member_view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      render_hook(member_view, "whiteboard_save", %{
        "scene" => scene("member"),
        "expected_version" => 0
      })

      stored = Meetings.get_whiteboard(meeting.id)
      assert stored.scene_version == 1
      assert stored.scene["elements"] == [%{"id" => "el-member"}]
      assert stored.last_edited_by_user_id == user.id
      assert_push_event(member_view, "whiteboard_saved", %{scene_version: 1})
    end

    test "a stale expected_version leaves the stored scene byte-identical", %{
      conn: conn,
      meeting: meeting,
      space: space,
      user: user
    } do
      wb_join!(space, user)

      # Someone else got there first: the board is at version 1.
      {:ok, _wb} =
        Meetings.upsert_whiteboard_scene(meeting.id, nil, scene("winner"), 0)

      before = Meetings.get_whiteboard(meeting.id)
      before_bytes = Jason.encode!(before.scene)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      render_hook(view, "whiteboard_save", %{
        "scene" => scene("loser"),
        "expected_version" => 0
      })

      # Re-read the ROW and compare the encoded scene. Asserting only that an
      # error tuple came back would stay green for a handler that answered
      # `:stale_version` and wrote anyway.
      after_row = Meetings.get_whiteboard(meeting.id)
      assert Jason.encode!(after_row.scene) == before_bytes
      assert after_row.scene_version == 1
      assert after_row.updated_at == before.updated_at

      assert_push_event(view, "whiteboard_stale", %{scene_version: 1})
      refute_push_event(view, "whiteboard_saved", %{})

      # Exactly one message. The hook draws its own notice on
      # `whiteboard_stale`; the server badge must not ALSO come up, or the two
      # render on top of each other at the same `top-0` overlay position —
      # which is what the stage-4 screenshots caught.
      refute render(view) =~ "data-whiteboard-remote-notice"
    end

    test "whiteboard_load replies with the stored scene and its version", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Empty board: the ordinary starting state, answered as version 0
      # rather than as an error.
      render_hook(view, "whiteboard_load", %{})
      assert_push_event(view, "whiteboard_loaded", %{scene: %{}, scene_version: 0})

      {:ok, _wb} = Meetings.upsert_whiteboard_scene(meeting.id, nil, scene("stored"), 0)

      {:ok, reloaded, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      render_hook(reloaded, "whiteboard_load", %{})

      assert_push_event(reloaded, "whiteboard_loaded", %{
        scene: %{"elements" => [%{"id" => "el-stored"}]},
        scene_version: 1
      })
    end

    test "a save by A badges B's view and not A's own", %{
      conn: conn,
      meeting: meeting,
      space: space,
      user: user_a
    } do
      wb_join!(space, user_a, "User A")

      {conn_b, user_b} = authenticated_conn(Phoenix.ConnTest.build_conn())
      wb_join!(space, user_b, "User B")

      {:ok, view_a, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      {:ok, view_b, _html} = live(conn_b, ~p"/meetings/#{meeting.slug}")

      # Both are looking at the board — the badge is whiteboard-mode only.
      render_click(view_a, "set_stage_mode", %{"mode" => "whiteboard"})
      render_click(view_b, "set_stage_mode", %{"mode" => "whiteboard"})

      render_hook(view_a, "whiteboard_save", %{
        "scene" => scene("from-a"),
        "expected_version" => 0
      })

      # Both halves, or a handler that never badges anyone passes the second.
      assert render(view_b) =~ "data-whiteboard-remote-notice"
      assert render(view_b) =~ "Whiteboard updated by someone else"
      refute render(view_a) =~ "data-whiteboard-remote-notice"

      # And it is passive: B is TOLD, never re-scened.
      refute_push_event(view_b, "whiteboard_loaded", %{})
      refute_push_event(view_b, "whiteboard_saved", %{})

      # Dismissible.
      view_b
      |> element(~s([data-action="whiteboard-dismiss-remote"]))
      |> render_click()

      refute render(view_b) =~ "data-whiteboard-remote-notice"
    end

    # Isolates the `by_user_id` half of the badge guard from the version
    # half. In the test above, A's own socket is ALSO protected by
    # `version <= whiteboard_version` — deleting the `by_user_id` check
    # leaves that test green, so on its own it does not test this guard at
    # all. A second tab of the SAME user holds version 0, so only the
    # `by_user_id` comparison can suppress the badge there.
    test "a user's own save does not badge their other session", %{
      conn: conn,
      meeting: meeting,
      space: space,
      user: user
    } do
      wb_join!(space, user)

      {:ok, tab_one, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      {:ok, tab_two, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      render_click(tab_two, "set_stage_mode", %{"mode" => "whiteboard"})

      render_hook(tab_one, "whiteboard_save", %{
        "scene" => scene("same-user"),
        "expected_version" => 0
      })

      refute render(tab_two) =~ "data-whiteboard-remote-notice"
    end

    # The version half of the same guard, isolated the other way: the
    # broadcast comes from a DIFFERENT user, so only `scene_version >
    # whiteboard_version` can decide. A redelivery of a version this client
    # already holds is not news; the very next version is.
    test "a replayed broadcast raises no badge, the next version does", %{
      conn: conn,
      meeting: meeting,
      space: space,
      user: user
    } do
      wb_join!(space, user)
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      render_click(view, "set_stage_mode", %{"mode" => "whiteboard"})

      render_hook(view, "whiteboard_save", %{
        "scene" => scene("v1"),
        "expected_version" => 0
      })

      other_user_id = Ecto.UUID.generate()

      MeetingsPubSub.broadcast_whiteboard_scene_saved(meeting.id, 1, other_user_id)
      assert render(view) =~ ~s(data-stage-mode="whiteboard")
      refute render(view) =~ "data-whiteboard-remote-notice"

      # Positive control: without it, this passes for a view that badges
      # nobody ever.
      MeetingsPubSub.broadcast_whiteboard_scene_saved(meeting.id, 2, other_user_id)
      assert render(view) =~ "data-whiteboard-remote-notice"
    end

    test "the remote badge lives outside the ignored host node", %{
      conn: conn,
      meeting: meeting
    } do
      # Nothing server-rendered may go INSIDE `#meeting-whiteboard-host`
      # (#664: attributes and content on an ignored node are hazards). The
      # host's opening tag is immediately followed by its closing tag.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      html = render_click(view, "set_stage_mode", %{"mode" => "whiteboard"})

      [inner] =
        Regex.run(
          ~r/<div[^>]*id="meeting-whiteboard-host"[^>]*>(.*?)<\/div>/s,
          html,
          capture: :all_but_first
        )

      assert String.trim(inner) == ""
    end
  end

  describe "Screen mode renderer" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "stage-mode-screen", name: "Screen Stage"})
      {conn, _user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space}
    end

    test "renders the empty-state placeholder + Start sharing CTA when no track exists", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="screen"]))
        |> render_click()

      assert html =~ ~s(data-stage-mode="screen")
      # The hook target carries phx-hook + the data-screen-share-active flag
      # the JS side toggles when a track attaches.
      assert html =~ ~s(phx-hook="MeetingScreenShare")
      assert html =~ ~s(data-screen-share-active="false")
      assert html =~ ~s(data-screen-share-slot)
      assert html =~ ~s(data-screen-share-empty)
      # Empty-state copy + CTA.
      assert html =~ "No active screen-share"
      assert html =~ "Start sharing"
      # Stage 2 (task 019e420f): the CTA is now owned by the
      # `MeetingShareButton` JS hook so the click gesture reaches
      # `getDisplayMedia()` without a server round-trip. The old
      # `phx-click="meeting_start_screen_share"` is gone — a round-trip
      # would kill the browser's user-activation flag.
      assert html =~ ~s(id="meeting-share-btn-screen-cta")
      assert html =~ ~s(phx-hook="MeetingShareButton")
      assert html =~ ~s(data-action="start-screen-share")

      refute html =~
               ~r/id="meeting-share-btn-screen-cta"[^>]*phx-click="meeting_start_screen_share"/

      # Hero icons only — no emoji.
      assert html =~ "hero-computer-desktop"
      assert html =~ "hero-arrow-up-tray"
      # Whiteboard / canvas-empty markers do NOT bleed in.
      refute html =~ ~s(data-coming-soon="whiteboard")
      refute html =~ ~s(data-empty-state="canvas")
    end

    test "Start sharing CTA is wired client-side via MeetingShareButton (no phx-click round-trip)",
         %{
           conn: conn,
           meeting: meeting
         } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="screen"]))
        |> render_click()

      # Stage 2 (task 019e420f): the CTA no longer pushes
      # `meeting_start_screen_share` to the server. `getDisplayMedia()`
      # is gesture-gated — the click must reach LiveKit *inside* the
      # event handler, so `MeetingShareButton` owns it client-side and
      # calls `setScreenShareEnabled` directly, then mirrors state back
      # via `meeting_screen_share_state`.
      assert html =~ ~s(button[^>]*data-action="start-screen-share") or
               html =~ ~s(data-action="start-screen-share")

      assert html =~ ~s(id="meeting-share-btn-screen-cta")
      assert html =~ ~s(phx-hook="MeetingShareButton")

      # The CTA must NOT carry the legacy phx-click anymore.
      refute html =~
               ~r/data-action="start-screen-share"[^>]*phx-click="meeting_start_screen_share"|phx-click="meeting_start_screen_share"[^>]*data-action="start-screen-share"/
    end
  end

  describe "Gallery mode renderer" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "stage-mode-gallery", name: "Gallery Stage"})
      {conn, _user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space}
    end

    test "renders the no-participants empty state when nobody has joined", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      # Stage 1 (019e2d1a) dropped the eager participant-add side effect
      # from MeetingChatPanelLive.mount and MeetingLive.create_meeting_canvas,
      # so a fresh mount with no prior participants leaves the roster
      # empty. The gallery empty-state should render directly with no
      # setup teardown required.
      #
      # Stage 4 bugfix (019e2d1a): the auto-join now inserts via the
      # Membership bridge, which would change the empty-state into a
      # one-tile state and steal what this test is policing. Suppress
      # auto-join with `?no_autojoin=true` so the gallery empty state
      # is observable.
      assert Chat.list_participants(space.id) == []

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # Belt-and-suspenders: confirm mount did NOT insert anyone.
      assert Chat.list_participants(space.id) == []

      html =
        view
        |> element(~s([data-stage-mode-button="gallery"]))
        |> render_click()

      assert html =~ ~s(data-stage-mode="gallery")
      assert html =~ ~s(data-gallery-tile-count="0")
      assert html =~ "No participants yet"
      # Hero icon only.
      assert html =~ "hero-squares-2x2"
      # The grid wrapper is NOT rendered in the empty state.
      refute html =~ ~s(data-gallery-grid)
    end

    # TASK 01a064fa STAGE 1. The geometric gate measures "does the tile
    # grid fill the stage column", which needs both boxes to be
    # addressable. Neither was: the stage column carried only
    # `data-pane` and the grid only `data-gallery-grid`, and the
    # geometry harness is deliberately forbidden from locating anything
    # by class name — a class-name lookup is the same species of check
    # as the presence check that let three rejected rounds through.
    #
    # Asserted as ANCESTRY over the parsed document, not as two
    # independent `=~` presence checks: the grid being SOMEWHERE on the
    # page while sitting outside the stage column is exactly the
    # wired-into-the-wrong-parent defect this task exists to catch.
    test "the stage column and the tile grid are addressable, and the grid is inside the stage",
         %{conn: conn, meeting: meeting, space: space} do
      {_ada, _} = seed_meeting_presence(space, "user", "Ada Lovelace")
      {_grace, _} = seed_meeting_presence(space, "user", "Grace Hopper")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      html =
        view
        |> element(~s([data-stage-mode-button="gallery"]))
        |> render_click()

      doc = Floki.parse_document!(html)

      stages = Floki.find(doc, ~s([data-role="call-stage"]))

      assert length(stages) == 1,
             "expected exactly one [data-role=\"call-stage\"], got #{length(stages)} — " <>
               "the geometry harness fails loudly on an ambiguous selector"

      grids = Floki.find(doc, ~s([data-role="call-tile-grid"]))
      assert length(grids) == 1

      assert Floki.find(stages, ~s([data-role="call-tile-grid"])) == grids,
             "the tile grid renders but is NOT inside the stage column"

      # The grid is the element that DIRECTLY parents the cells — if the
      # marker drifted onto an outer wrapper the fill measurement would
      # silently be measuring the wrong box.
      assert Floki.find(grids, ~s([data-gallery-cell])) != []
      assert Floki.find(grids, ~s([data-gallery-grid])) == grids
    end

    # The markers are ATTRIBUTES on nodes LiveView already renders. The
    # seven `phx-update="ignore"` ids below have JS-owned children
    # (meeting_client.js, MeetingWhiteboard), so a marker placed on a
    # CHILD would be wiped or never rendered — and a change of id would
    # break the hooks' lookups without any test noticing. Pinned here so
    # the next marker-adding stage cannot quietly reach into the
    # JS-owned region.
    test "the JS-owned phx-update=ignore ids are unchanged", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # Rendered for every stage mode, unconditionally.
      for id <- ~w(meeting-media meeting-whiteboard-host) do
        assert html =~ ~s(id="#{id}"), "the phx-update=ignore node #{id} is gone or renamed"
      end

      # The screen-share slot lives inside the stage-mode `cond`, so it
      # is only in the document in :screen mode. Asserting it on the
      # gallery mount is how the first cut of this guard failed — worth
      # keeping the distinction visible rather than dropping the id.
      screen_html =
        view
        |> element(~s([data-stage-mode-button="screen"]))
        |> render_click()

      assert screen_html =~ ~s(id="meeting-screen-share-slot"),
             "the phx-update=ignore node meeting-screen-share-slot is gone or renamed"
    end

    test "renders one VideoTile per human participant in a grid", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      # Two humans + one agent. Only the humans should tile; the agent
      # is excluded from gallery mode (presence lives in the bottom strip).
      #
      # Stage 4 bugfix (019e2d1a): auto-join now inserts the viewer too,
      # which would add a 3rd human tile and skew the count assertion.
      # `?no_autojoin=true` keeps the test scoped to the seeded humans.
      {_ada, _} = seed_meeting_presence(space, "user", "Ada Lovelace")
      {_grace, _} = seed_meeting_presence(space, "user", "Grace Hopper")
      {_bot, _} = seed_meeting_presence(space, "agent", "Bot McBotface")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      html =
        view
        |> element(~s([data-stage-mode-button="gallery"]))
        |> render_click()

      assert html =~ ~s(data-stage-mode="gallery")
      # Stage 1 (019e2d1a) dropped the chat-panel auto-add side effect,
      # so the gallery shows exactly the two seeded humans. The agent is
      # omitted from the gallery grid.
      assert html =~ ~s(data-gallery-tile-count="2")
      assert html =~ ~s(data-gallery-grid)
      # Task 01a05b14 stage 3: the grid shape is participant-count-driven
      # and 2 humans yields TWO COLUMNS. The cells stretch and the tile
      # fills the cell, so the pair sits side by side filling the stage
      # instead of stacking as a centred 520px column inside a 744px
      # stage (the 224px dead-margin defect the sponsor rejected).
      assert html =~ ~s(data-gallery-grid-shape="grid-cols-2")
      # Two cells is already a rectangle — no ghost.
      refute html =~ ~s(data-gallery-ghost-cell)

      # Two video tiles, one per human; agent is omitted from the
      # gallery grid. Scope the count to the gallery section: the
      # bottom strip (sibling 019e2475-0037) also renders MeetingVideoTile
      # hooks, so a global count would over-report. Task 019e412a added
      # a sibling `data-gallery-grid-shape` attr, so the split anchor
      # uses a regex word boundary to land ONLY on the bare attribute.
      gallery_section =
        case Regex.split(~r/data-gallery-grid(?![-\w])/, html, parts: 2) do
          [_, after_grid] ->
            case String.split(after_grid, ~s(data-pane="bottom-strip")) do
              [grid_html | _] -> grid_html
              _ -> after_grid
            end

          _ ->
            ""
        end

      tile_count =
        Regex.scan(~r/phx-hook="MeetingVideoTile"/, gallery_section)
        |> length()

      assert tile_count == 2

      # Task 019e412a (stage 2 fix v3): each tile is wrapped in a
      # `[data-gallery-cell]` size container. The container query in
      # `assets/css/app.css` picks the binding axis per cell aspect
      # ratio. We pin the wrapper count and presence here; the
      # outer-tile-class invariants live in video_tile_test.exs.
      cell_count =
        Regex.scan(~r/data-gallery-cell(?![-\w])/, gallery_section)
        |> length()

      assert cell_count == 2

      # The grid container itself must still own the full center-stage
      # area. Pull it out of the full html with a class regex (it's a
      # unique element keyed by data-gallery-grid).
      #
      # Task 01a05b14 stage 3 changed HOW it owns that area. It used to
      # be `h-full ... place-items-center`: full height, but every cell
      # centring a 16:9 tile inside itself, which measured 520px of grid
      # in a 744px stage. It is now `flex-1` (it is the growing child of
      # the stage column, which the control bar shares) with the cells
      # STRETCHED -- `place-items-center` is asserted GONE, because
      # re-adding it silently restores the floating-card layout with
      # nothing else failing.
      [_, grid_class] =
        Regex.run(~r/class="([^"]*)"\s+data-gallery-grid(?![-\w])/, html)

      grid_tokens = String.split(grid_class)

      assert "flex-1" in grid_tokens
      assert "min-h-0" in grid_tokens
      assert "w-full" in grid_tokens
      assert "auto-rows-fr" in grid_tokens
      assert "gap-2.5" in grid_tokens
      refute "place-items-center" in grid_tokens
    end

    test "Screen → Gallery → Canvas preserves the canvas state in the LV assigns", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      # Seed a canvas so Canvas mode has content to preserve.
      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Author",
          joined_at: DateTime.utc_now()
        })

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Persistent canvas"
        })

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Walk modes: screen → gallery → canvas. The canvas must still
      # render at the end (proves :meeting_canvas survived flips).
      for mode <- ~w(screen gallery canvas) do
        view
        |> element(~s([data-stage-mode-button="#{mode}"]))
        |> render_click()
      end

      html = render(view)
      assert html =~ ~s(data-canvas-id="#{canvas.id}")
    end
  end

  # ── Bottom-strip safe-area branch (task 01a0776a-4c11-7001-ae00-507fadebf462, stage 1)
  #
  # WHAT THESE TWO TESTS PROVE, AND WHAT THEY DO NOT PROVE.
  #
  # They pin WHICH BRANCH of the footer's `@shell?` conditional the
  # template selects, and nothing beyond that. A class-string assertion
  # passes on any build that emits the string: it cannot tell you that a
  # 96px border-box minus the inset leaves a 45px content box, that the
  # `aspect-video` tile then narrows to 80px, that the 120px container
  # query fires and hides the participant names, or that a dead band opens
  # between the strip and the mobile bottom nav. None of that is checked
  # here and none of it can be. Server-side rendering has no viewport, and
  # headless Chromium resolves `env(safe-area-inset-bottom)` to 0 anyway,
  # so even a rendered check at this layer would measure the un-inset case
  # and pass on the broken build.
  #
  # The arithmetic is measured in `e2e/tests/meeting_layout_geometry.spec.ts`
  # against a real 34px inset injected over CDP
  # (`Emulation.setSafeAreaInsetsOverride`). That is the gate. Do not cite
  # the assertions below as evidence about layout.

  describe "bottom-strip safe-area branch selection (task 01a0776a stage 1)" do
    setup do
      put_guest_livekit_env()
      :ok
    end

    test "shell surface: no inset below lg, inset ADDED to the height at lg",
         %{conn: conn} do
      {meeting, _space} = create_meeting(%{slug: "strip-safe-area-shell"})
      {conn, _user} = authenticated_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Gallery is the default stage mode and the footer is gated
      # `:if={@current_stage_mode != :gallery}`, so it is not in the DOM
      # until canvas is selected. Without this click the class query below
      # would raise on an empty match rather than silently pass, but the
      # click is what makes the case meaningful at all.
      html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.shell? == true

      class = bottom_strip_class(html)
      tokens = String.split(class)

      # Below lg the shell's own `<.bottom_rail>` is the bottom-most
      # element and `.bottom-nav` already carries the inset as padding
      # (`app.css:3441`). Reserving it here as well would double it.
      assert "pb-2" in tokens, "expected an un-inset pb-2 below lg; class was: #{class}"
      assert "h-[96px]" in tokens, "expected a flat h-[96px] below lg; class was: #{class}"

      refute "pb-[calc(0.5rem+env(safe-area-inset-bottom))]" in tokens,
             "unprefixed inset padding on the shell is the defect being fixed; class was: #{class}"

      refute "h-[calc(96px+env(safe-area-inset-bottom))]" in tokens,
             "the shell footer must not grow below lg, where the rail owns the inset; class was: #{class}"

      # At lg the rail is `display:none` (`app.css:3448-3452`), so the
      # footer is bottom-most and the inset extends it.
      assert "lg:pb-[calc(0.5rem+env(safe-area-inset-bottom))]" in tokens,
             "expected the lg padding to carry the inset; class was: #{class}"

      assert "lg:h-[calc(120px+env(safe-area-inset-bottom))]" in tokens,
             "expected the lg height to ADD the inset rather than absorb it; class was: #{class}"

      refute "lg:h-[120px]" in tokens,
             "a flat lg height absorbs the inset out of the tiles; class was: #{class}"
    end

    test "guest surface: the inset is carried in the padding AND the height at both breakpoints",
         %{conn: conn} do
      {meeting, token} = create_guest_meeting()

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert :sys.get_state(view.pid).socket.assigns.shell? == false

      html = render_click(view, "set_stage_mode", %{"mode" => "canvas"})

      class = bottom_strip_class(html)
      tokens = String.split(class)

      # No shell chrome exists on `meet.`, so this footer is bottom-most at
      # every width and the inset applies at both breakpoints.
      assert "pb-[calc(0.5rem+env(safe-area-inset-bottom))]" in tokens,
             "expected the guest padding to carry the inset; class was: #{class}"

      assert "h-[calc(96px+env(safe-area-inset-bottom))]" in tokens,
             "expected the guest base height to ADD the inset; class was: #{class}"

      assert "lg:h-[calc(120px+env(safe-area-inset-bottom))]" in tokens,
             "expected the guest lg height to ADD the inset; class was: #{class}"

      refute "h-[96px]" in tokens, "flat base height absorbs the inset; class was: #{class}"
      refute "lg:h-[120px]" in tokens, "flat lg height absorbs the inset; class was: #{class}"
      refute "pb-2" in tokens, "guest must not take the shell branch; class was: #{class}"

      # `--bottom-nav-height` is shell-only and the chrome-escape test in
      # this file refutes the substring `bottom-nav` in a guest document.
      # Keep the guest branch free of it.
      refute class =~ "bottom-nav",
             "guest branch must not reference shell chrome; class was: #{class}"
    end
  end

  # ── Gallery-default reframe (stage 3, task 019e2d1a) ──────────────────────
  #
  # The meeting opens face-first: gallery is the default stage mode and
  # the bottom strip is hidden in gallery so the grid owns the full
  # vertical space. Switching to canvas/screen/whiteboard reveals the
  # strip as the compact "who's here" footer. Identity strings are
  # deliberately aligned (`"user:" <> pid` in BOTH the gallery grid and
  # the bottom strip) so the MeetingVideoTile hook reuses the same DOM
  # node across mode flips and the LiveKit track stays attached.

  describe "gallery-default reframe (stage 3)" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "gallery-default", name: "Gallery Default"})
      {conn, _user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space}
    end

    test "mount → :current_stage_mode is :gallery and the center stage carries data-stage-mode=\"gallery\"",
         %{conn: conn, meeting: meeting} do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-stage-mode="gallery")
      assert :sys.get_state(view.pid).socket.assigns.current_stage_mode == :gallery
    end

    test "mount → no data-pane=\"bottom-strip\" element renders (gallery hides the strip)",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      refute html =~ ~s(data-pane="bottom-strip")
    end

    test "render_click Canvas → center stage swaps to canvas renderer AND bottom strip reappears",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      # Center stage now renders the canvas mode (empty-state CTA since
      # no canvas seeded) and the data-stage-mode attribute follows.
      assert html =~ ~s(data-stage-mode="canvas")
      assert html =~ ~s(data-empty-state="canvas")
      # And the bottom strip is now present.
      assert html =~ ~s(data-pane="bottom-strip")
    end

    test "render_click Gallery after Canvas → bottom strip hidden again",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Move to canvas first (strip should appear).
      canvas_html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      assert canvas_html =~ ~s(data-pane="bottom-strip")

      # Back to gallery — strip is hidden again.
      gallery_html =
        view
        |> element(~s([data-stage-mode-button="gallery"]))
        |> render_click()

      assert gallery_html =~ ~s(data-stage-mode="gallery")
      refute gallery_html =~ ~s(data-pane="bottom-strip")
    end

    test "with 3 human participants, gallery renders 3 <.video_tile> nodes inside [data-gallery-grid]",
         %{conn: conn, meeting: meeting, space: space} do
      # Three humans + one agent. Only humans tile in gallery mode.
      for name <- ~w(Ada Grace Hedy) do
        seed_meeting_presence(space, "user", name)
      end

      seed_meeting_presence(space, "agent", "Bot")

      # Gallery is the DEFAULT mode now — no click needed.
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-stage-mode="gallery")
      assert html =~ ~s(data-gallery-tile-count="3")
      assert html =~ ~s(data-gallery-grid)
      # Task 01a05b14 stage 3: 3 humans → 2 columns, and the odd cell
      # out is completed by a GHOST cell so the block reads as a 2x2
      # with one free seat.
      assert html =~ ~s(data-gallery-grid-shape="grid-cols-2")
      assert html =~ ~s(data-gallery-ghost-cell)

      # Scope the count to the gallery grid block. There is no bottom
      # strip in gallery mode, so the entire suffix after [data-gallery-grid]
      # is the grid section. Word-boundary split so the new sibling
      # `data-gallery-grid-shape` attr (task 019e412a) doesn't fool the
      # anchor.
      gallery_section =
        case Regex.split(~r/data-gallery-grid(?![-\w])/, html, parts: 2) do
          [_, after_grid] -> after_grid
          _ -> ""
        end

      tile_count =
        Regex.scan(~r/phx-hook="MeetingVideoTile"/, gallery_section)
        |> length()

      assert tile_count == 3
    end

    test "with 1 human participant, gallery uses the 1x1 grid shape",
         %{conn: conn, meeting: meeting, space: space} do
      seed_meeting_presence(space, "user", "Solo")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-gallery-tile-count="1")
      assert html =~ ~s(data-gallery-grid-shape="grid-cols-1")
      refute html =~ ~s(data-gallery-ghost-cell)
    end

    test "with 6 human participants, gallery uses the 3-column grid shape",
         %{conn: conn, meeting: meeting, space: space} do
      for name <- ~w(Ada Grace Hedy Edith Karen Sophie) do
        seed_meeting_presence(space, "user", name)
      end

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-gallery-tile-count="6")

      assert html =~ ~s(data-gallery-grid-shape="grid-cols-3")
      refute html =~ ~s(data-gallery-ghost-cell)
    end

    # ── Task 01a05b14 stage 3: a filling grid, and the ghost cell ───────
    #
    # WHAT THESE TESTS CAN AND CANNOT SEE, stated rather than implied: a
    # LiveViewTest render has no layout engine, so it can pin the column
    # class and the ghost cell's PRESENCE, and it CANNOT pin that the
    # grid actually fills the stage. The 224px -> ~32px deficit closing
    # is measured by DOM probe at capture time and lives in the stage
    # evidence, not here.
    # REGRESSION, found while capturing this stage's evidence (not by any
    # test): commit 6ecb0d5b -- stage 2 of this same task -- committed four
    # lines of erl stderr ("=WARNING REPORT==== ... Multiple -sname given to
    # erl") to the TOP of `meeting_live.html.heex`, where they rendered as
    # visible body text above the meeting shell on every /meetings request.
    #
    # Nothing caught it. Every assertion in this file is `html =~ needle`
    # or a selector count, and stray text at the top of the template
    # changes neither. Only a screenshot showed it. This is the assertion
    # that would have.
    test "the page renders no stray BEAM/erl diagnostic text", %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      body = html |> frag() |> LazyHTML.query("main") |> LazyHTML.text()

      for needle <- ["WARNING REPORT", "=ERROR REPORT", "Multiple -sname given"] do
        refute body =~ needle,
               "BEAM diagnostic output leaked into the rendered page: #{needle}"
      end
    end

    test "the column count tracks the participant count at 1, 2, 4 and 9",
         %{conn: conn, meeting: meeting, space: space} do
      names = ~w(Ada Grace Hedy Edith Karen Sophie Joan Radia Barbara)
      expected = %{1 => "grid-cols-1", 2 => "grid-cols-2", 4 => "grid-cols-2", 9 => "grid-cols-3"}

      for {n, shape} <- Enum.sort(expected) do
        _ = space_with_humans(space, names, n)

        {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

        assert html =~ ~s(data-gallery-tile-count="#{n}"),
               "seeding #{n} humans did not produce #{n} tiles"

        assert html =~ ~s(data-gallery-grid-shape="#{shape}"),
               "#{n} participants should render #{shape}"
      end
    end

    # ONE TEST PER COUNT, ON PURPOSE. A single test looping 1..5 aborts at
    # the first failing count and reports ONE failure for FIVE breakages,
    # which is exactly the arithmetic the mutation-count guard exists to
    # detect. Loosening the `:if` to always-true must go red at 1, 2, 4
    # AND 5 independently -- and stay green at 3.
    for n <- [1, 2, 4, 5] do
      test "no ghost cell at #{n} participants", %{
        conn: conn,
        meeting: meeting,
        space: space
      } do
        n = unquote(n)
        _ = space_with_humans(space, ~w(Ada Grace Hedy Edith Karen), n)

        {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

        assert html =~ ~s(data-gallery-tile-count="#{n}")

        assert count(html, ~s([data-gallery-ghost-cell])) == 0,
               "a ghost cell leaked at #{n} participants"
      end
    end

    test "exactly one ghost cell completes the 2x2 at three participants",
         %{conn: conn, meeting: meeting, space: space} do
      _ = space_with_humans(space, ~w(Ada Grace Hedy), 3)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-gallery-tile-count="3")

      assert count(html, ~s([data-gallery-ghost-cell])) == 1,
             "three participants should be completed to a 2x2 by ONE ghost cell"

      # It is decoration, not a seat: no tile binds against it, so it must
      # not claim to be a gallery cell, and it must not be announced.
      ghost = within(html, ~s([data-gallery-ghost-cell]))
      assert LazyHTML.attribute(ghost, "aria-hidden") == ["true"]
      [class] = LazyHTML.attribute(ghost, "class")
      assert class =~ "opacity-30"
      assert count(html, ~s([data-gallery-ghost-cell][data-gallery-cell])) == 0
    end

    test "identity alignment: gallery and strip use the same `\"user:\" <> pid` format",
         %{conn: conn, meeting: meeting, space: space} do
      # Seed one live human so both renderers have something to emit. The
      # gallery_identity is `"user:" <> user_id` (the LiveKit identity).
      {_participant, pid} = seed_meeting_presence(space, "user", "Ada Lovelace")

      {:ok, view, gallery_html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Default gallery → the identity (emitted as `data-participant` by
      # `<.video_tile>`) for this human in the grid is `"user:" <> pid`.
      assert gallery_html =~ ~s(data-participant="user:#{pid}")
      # And no `strip:user:` prefix anywhere (it was the old strip
      # identity; the alignment in stage 3 drops the prefix).
      refute gallery_html =~ "strip:user:"

      # Flip to canvas mode so the bottom strip renders.
      strip_html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      assert strip_html =~ ~s(data-pane="bottom-strip")
      # The strip's video tile uses the SAME identity as the gallery
      # tile — this is the cross-mode track-attachment continuity hook.
      assert strip_html =~ ~s(data-participant="user:#{pid}")
      refute strip_html =~ "strip:user:"
    end
  end

  describe "gallery_participants/1 + gallery_identity/1" do
    alias PlatformWeb.MeetingLive

    test "gallery_participants/1 keeps users and drops agents" do
      participants = [
        %{participant_type: "user", display_name: "Ada"},
        %{participant_type: "agent", display_name: "Bot"},
        %{participant_type: "user", display_name: "Grace"}
      ]

      assert [%{display_name: "Ada"}, %{display_name: "Grace"}] =
               MeetingLive.gallery_participants(participants)
    end

    test "gallery_participants/1 returns [] for non-list input" do
      assert MeetingLive.gallery_participants(nil) == []
      assert MeetingLive.gallery_participants("not a list") == []
    end

    test "gallery_identity/1 prefixes the participant_id (matches bottom-strip convention)" do
      assert MeetingLive.gallery_identity(%{participant_id: "abc-123"}) == "user:abc-123"
    end

    test "gallery_identity/1 falls back to id and finally to a sentinel" do
      assert MeetingLive.gallery_identity(%{id: "row-7"}) == "user:row-7"
      assert MeetingLive.gallery_identity(%{}) == "user:unknown"
    end
  end

  # ── gallery_grid_class/1 + gallery_ghost_cell?/1 ─────────────────────────
  #
  # Task 01a05b14 stage 3 replaced the 019e412a shape table. The old table
  # emitted `grid-cols-N grid-rows-M` with a mobile/desktop `sm:` split and
  # paired it with a per-TILE 16:9 binding plus `place-items-center`. That
  # combination is what the sponsor rejected: measured on `/meetings` at
  # 1280x800 with two participants, the stage was 744px wide and the grid
  # 520px — a 224px horizontal deficit against a stage padding of only
  # 32px, so the call read as two floating cards.
  #
  # The cells now STRETCH and the tile fills the cell (`object-cover` on the
  # injected <video>), so the shape only has to say how many columns. Rows
  # come from `auto-rows-fr`. Those old row classes and `sm:` prefixes are
  # asserted GONE below, not merely un-asserted, so a revert goes red.
  #
  # Every literal class string MUST stay statically discoverable by Tailwind
  # v4's content scanner — that is why the function body avoids
  # `"grid-cols-\#{n}"` style interpolation.
  describe "gallery_grid_class/1" do
    alias PlatformWeb.MeetingLive

    test "0 or 1 participants get a single column" do
      assert MeetingLive.gallery_grid_class(0) == "grid-cols-1"
      assert MeetingLive.gallery_grid_class(1) == "grid-cols-1"
    end

    test "2..4 participants get two columns (the canvas's 2x2 block)" do
      for n <- 2..4 do
        assert MeetingLive.gallery_grid_class(n) == "grid-cols-2"
      end
    end

    test "5..9 participants get three columns" do
      for n <- 5..9 do
        assert MeetingLive.gallery_grid_class(n) == "grid-cols-3"
      end
    end

    test "10 and beyond get four columns" do
      assert MeetingLive.gallery_grid_class(10) == "grid-cols-4"
      assert MeetingLive.gallery_grid_class(17) == "grid-cols-4"
      assert MeetingLive.gallery_grid_class(100) == "grid-cols-4"
    end

    test "no shape carries a row class or an sm: breakpoint any more" do
      # The reverted-to-019e412a failure mode is a shape string that
      # re-introduces `grid-rows-*` (which fights `auto-rows-fr`) or a
      # `sm:` prefix (which reinstates the mobile vertical stack the
      # canvas does not draw). Pin it across the whole domain rather
      # than at the few counts the render tests happen to exercise.
      for n <- 0..20 do
        shape = MeetingLive.gallery_grid_class(n)
        refute shape =~ "grid-rows-", "count #{n} still emits a row class: #{shape}"
        refute shape =~ "sm:", "count #{n} still emits an sm: breakpoint: #{shape}"
      end
    end

    test "arity-2 delegates to arity-1 for every chrome mode and count" do
      # The guest surface's old side-by-side carve-out for 2 and 3 existed
      # only to reclaim width the stacked shell layout wasted. Stretched
      # cells do that on both surfaces, so the shapes no longer diverge —
      # asserted across the full domain so a re-introduced carve-out for
      # any single count goes red.
      for n <- 0..20, chrome <- [:shell, :none] do
        assert MeetingLive.gallery_grid_class(n, chrome) == MeetingLive.gallery_grid_class(n)
      end
    end
  end

  describe "gallery_ghost_cell?/1" do
    alias PlatformWeb.MeetingLive

    test "true at exactly three cells and false at every other count" do
      # Three cells in a two-column grid leaves one ragged hole, which the
      # canvas fills with a dimmed outline. Every other count is either
      # already rectangular or lives in a wider grid where one ghost per
      # empty slot would paint up to six dead boxes.
      assert MeetingLive.gallery_ghost_cell?(3)

      for n <- Enum.reject(0..20, &(&1 == 3)) do
        refute MeetingLive.gallery_ghost_cell?(n), "ghost cell leaked at count #{n}"
      end
    end
  end

  # ── Meetings index (:index action) ───────────────────────────────────────
  #
  # Task 019fb954-8ead stage 3 REPLACED the pre-calendar index surface. The
  # `data-empty-state="meetings-index"` card and the grouped section/row
  # list were the below-`lg` surface stage 2 kept alive for exactly one
  # stage; the mobile week strip and day view are what they were being kept
  # for, so this stage deletes them rather than drawing the new surface
  # underneath the old one.
  #
  # The assertions that pinned them are re-pointed, not dropped:
  #
  #   * "an empty index shows the empty-state card" is now "an empty index
  #     shows the calendar's own empty answer, and the card is gone" — the
  #     removal is asserted, so a revert goes red.
  #   * "one section per non-empty status bucket, rows linking to
  #     /meetings/<slug>" is now "meetings render as day-view event blocks".
  #     The `<slug>` LINK has no analogue on the calendar and is not faked
  #     here: stage 4 gives a selected meeting a detail surface, and until
  #     it lands there is no path from the index to a meeting page at ANY
  #     width (the desktop half lost the same thing in stage 2).
  #
  # Two stage-1 tests were deleted outright rather than re-pointed, because
  # what they pinned no longer exists in any form: "section ordering is live
  # → upcoming → ended" and "sections with zero rows are omitted". The
  # calendar partitions by DATE, and has no sections to order or omit.
  # `group_meetings_by_status/1` still has its own describe below.

  describe ":index action — the pre-calendar surface is gone" do
    setup %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      Repo.delete_all(Meeting)
      project = create_project()
      {:ok, conn: conn, user: user, project: project}
    end

    test "an empty index still draws the calendar, not a grouped list", %{conn: conn} do
      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      # The deleted surface, named so a revert is loud rather than merely
      # duplicated on screen. NOTE (019f9cb7 stage 5): the two refutes that
      # named `data-empty-state="meetings-index"` and "No meetings yet" were
      # re-pointed, not dropped. What this describe deleted was the grouped
      # LIST and its centred card; scoping the index made zero meetings an
      # ordinary answer for a real viewer rather than a fresh-install one, so
      # a left-aligned empty state came back above the grid. The claim worth
      # pinning is that it did not bring the LIST back with it, and that the
      # calendar still draws — both asserted here and below.
      refute html =~ ~s(data-role="meeting-row")
      refute html =~ ~s(data-section="upcoming")

      # What replaced it: below `lg` the strip and the day view draw their
      # chrome with nothing in them, exactly as the desktop grid does. An
      # empty calendar IS a calendar's answer to "what is on this week?".
      assert length(attrs_of(html, ~s([data-role="calendar-strip-day"]), "data-date")) == 7

      assert attrs_of(html, ~s([data-role="calendar-day-view"]), "data-role") ==
               ["calendar-day-view"]

      assert day_count_text(html) == "No meetings"
    end

    test "meetings render as calendar blocks, not as grouped status sections",
         %{conn: conn, project: project} do
      today = grid_today()

      live_meeting =
        seed_grid_meeting(project,
          slug: "live-now",
          name: "Live Standup",
          status: "live",
          scheduled_start_at: zoned_utc(today, 9, 0),
          scheduled_end_at: zoned_utc(today, 10, 0)
        )

      upcoming =
        seed_grid_meeting(project,
          slug: "next-up",
          name: "Quarterly Review",
          status: "scheduled",
          scheduled_start_at: zoned_utc(today, 11, 0),
          scheduled_end_at: zoned_utc(today, 12, 0)
        )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      # The grouped list's markers are gone in every form it had.
      refute html =~ ~s(data-section="live")
      refute html =~ ~s(data-section="upcoming")
      refute html =~ ~s(data-section="ended")
      refute html =~ ~s(data-role="meeting-status-pill")
      refute html =~ ~s(data-role="meeting-row")

      # The slug link is back — but on FE-17 stage 7's mobile CARD (task
      # 01a07410), never on a grouped row. Pinned by where it lives, not by
      # its absence: `meeting_live_index_mobile_cards_test.exs` owns the
      # card's own contract.
      assert attrs_of(html, ~s([data-role="meeting-card"]), "href") ==
               ["/meetings/#{live_meeting.slug}", "/meetings/#{upcoming.slug}"]

      # And both meetings are on the day view instead, carrying their own
      # statuses rather than a section's.
      assert attrs_of(html, day_view(~s([data-role="calendar-event"])), "data-meeting-id") ==
               [live_meeting.id, upcoming.id]

      assert attrs_of(html, day_view(~s([data-role="calendar-event"])), "data-meeting-status") ==
               ["live", "scheduled"]

      assert html =~ live_meeting.name
      assert html =~ upcoming.name
    end

    # ── Scoped-index states (019f9cb7 stage 5) ────────────────────────────
    #
    # Scoping changed what a CORRECT index holds: zero is ordinary for a new
    # external user, one is ordinary for most people. These pin the states a
    # scoped list actually produces.

    test "an empty index tells an INTERNAL viewer their org's meetings land here",
         %{conn: conn} do
      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      assert html =~ ~s(data-empty-state="meetings-index")
      assert html =~ "No meetings yet."

      # The branch matters more than the string. An internal viewer is scoped
      # by ORG MEMBERSHIP and will routinely open meetings nobody invited
      # them to, so the invite copy would tell them something false about why
      # their list is empty.
      assert attrs_of(html, ~s([data-role="meetings-index-empty-note"]), "data-viewer") ==
               ["internal"]

      assert html =~ "Meetings for your organisation will appear here."
      refute html =~ "once you&#39;ve been invited"
    end

    # The EXTERNAL branch of this same empty state is asserted in
    # `meeting_live_index_external_test.exs` — reaching `/meetings` as an
    # external user needs the configured meet host, which is process-global
    # config and cannot be set from this `async: true` module.

    test "a one-meeting index is a finished page: the row draws and the empty state does not",
         %{conn: conn, project: project} do
      today = grid_today()

      only =
        seed_grid_meeting(project,
          slug: "only-one",
          name: "The Only Meeting",
          status: "scheduled",
          scheduled_start_at: zoned_utc(today, 9, 0),
          scheduled_end_at: zoned_utc(today, 10, 0)
        )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      assert attrs_of(html, day_view(~s([data-role="calendar-event"])), "data-meeting-id") ==
               [only.id]

      refute html =~ ~s(data-empty-state="meetings-index")

      # No skeleton implying more is loading. A single row is the whole
      # answer, not a partially-loaded one.
      refute html =~ "animate-pulse bg-base-300"
      refute html =~ ~s(data-role="meetings-skeleton")
    end

    test "the empty state renders under the not-found flash without a centred hero",
         %{conn: conn} do
      other_org_project = create_project(Platform.TenancyFixtures.tenant_org_id("soylent"))
      {meeting, _space} = create_meeting(%{project: other_org_project, name: "Not Yours"})

      # The real path this state has to survive: a denied detail request
      # redirects HERE carrying "Meeting not found.".
      assert {:error, {:live_redirect, %{to: "/meetings", flash: flash}}} =
               live(grid_conn(conn), ~p"/meetings/#{meeting.slug}")

      assert flash["error"] == "Meeting not found."

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      empty =
        html
        |> doc()
        |> LazyHTML.query(~s([data-empty-state="meetings-index"]))
        |> LazyHTML.attribute("class")
        |> List.first()

      # Two centred messages stacked read as a broken app, so this block is
      # left-aligned body text in the content column. If it ever acquires
      # hero centring, this goes red.
      refute empty =~ "text-center"
      refute empty =~ "items-center"
      refute empty =~ "justify-center"
    end

    test "index renders without forcing a local data-theme override (inherits shell theme)",
         %{conn: conn} do
      # Task 019e40ed: the `:index` placeholder branch had the same
      # hardcoded `data-theme="light"` as the `:show` shell — both must
      # now inherit the shell's `data-theme` from `<html>` in
      # `root.html.heex`.
      {:ok, _view, html} = live(conn, ~p"/meetings")

      refute html =~ ~s(data-theme="light")
      refute html =~ ~s(data-theme="dark")
    end
  end

  describe ":index action — PubSub live updates" do
    setup %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      Repo.delete_all(Meeting)
      project = create_project()
      {:ok, conn: conn, project: project}
    end

    test ":meeting_created PubSub message places the new meeting without a remount",
         %{conn: conn, project: project} do
      today = grid_today()

      {:ok, view, html} = live(grid_conn(conn), ~p"/meetings")

      # Empty to start — asserted on the calendar now that the empty-state
      # card is gone.
      assert attrs_of(html, ~s([data-role="calendar-event"]), "data-meeting-id") == []
      assert day_count_text(html) == "No meetings"

      {:ok, meeting} =
        Platform.Meetings.create_meeting(%{
          project_id: project.id,
          name: "Brand New Meeting",
          scheduled_start_at: zoned_utc(today, 13, 0),
          scheduled_end_at: zoned_utc(today, 14, 0)
        })

      # Force the LV to flush the inbound :meeting_created broadcast.
      html = render(view)

      assert attrs_of(html, day_view(~s([data-role="calendar-event"])), "data-meeting-id") ==
               [meeting.id]

      assert day_count_text(html) == "1 meeting"
      assert html =~ "Brand New Meeting"
    end

    test ":meeting_ended PubSub message flips the block's status in place",
         %{conn: conn, project: project} do
      # The row does not MOVE any more — a meeting occupies the slot it was
      # scheduled for whether it is live or ended — so what the broadcast
      # has to change is the block's own status, and the live tell with it.
      today = grid_today()

      meeting =
        seed_grid_meeting(project,
          slug: "end-me",
          name: "Ending Meeting",
          status: "live",
          scheduled_start_at: zoned_utc(today, 15, 0),
          scheduled_end_at: zoned_utc(today, 16, 0)
        )

      {:ok, view, html} = live(grid_conn(conn), ~p"/meetings")

      block = day_view(~s([data-role="calendar-event"][data-meeting-id="#{meeting.id}"]))

      assert attrs_of(html, block, "data-meeting-status") == ["live"]
      assert attrs_of(html, block, "data-live") == ["true"]

      {:ok, _ended} = Platform.Meetings.end_meeting(meeting)

      html = render(view)

      assert attrs_of(html, block, "data-meeting-status") == ["ended"]
      # Both sides named: `attribute/2` skips nodes that lack the attribute,
      # so "no `true` on the page" and "this block lost its `true`" are
      # different claims and only the second one is about this block.
      assert attrs_of(html, block, "data-live") == []
      assert html =~ "Ending Meeting"
    end
  end

  # ── group_meetings_by_status/1 (pure helper) ─────────────────────────────

  describe "group_meetings_by_status/1" do
    alias PlatformWeb.MeetingLive

    test "buckets by status with `scheduled` → :upcoming" do
      m1 = %Meeting{id: "1", status: "live", name: "L"}
      m2 = %Meeting{id: "2", status: "scheduled", name: "S"}
      m3 = %Meeting{id: "3", status: "ended", name: "E"}

      grouped = MeetingLive.group_meetings_by_status([m1, m2, m3])

      assert [%{id: "1"}] = grouped.live
      assert [%{id: "2"}] = grouped.upcoming
      assert [%{id: "3"}] = grouped.ended
    end

    test "preserves input order within a bucket" do
      m1 = %Meeting{id: "newer", status: "live"}
      m2 = %Meeting{id: "older", status: "live"}

      grouped = MeetingLive.group_meetings_by_status([m1, m2])
      assert [%{id: "newer"}, %{id: "older"}] = grouped.live
    end

    test "returns empty buckets for non-list input" do
      assert %{live: [], upcoming: [], ended: []} =
               MeetingLive.group_meetings_by_status(nil)
    end

    test "unknown status defensively falls into :upcoming" do
      m = %Meeting{id: "x", status: "weird"}
      grouped = MeetingLive.group_meetings_by_status([m])
      assert [%{id: "x"}] = grouped.upcoming
    end
  end

  # ── Desktop week grid (task 019fb954-8ead stage 2) ───────────────────────
  #
  # Parsed with `LazyHTML`, not with `=~` against the raw document. Two
  # reasons, both of which a substring assertion gets wrong:
  #
  #   * "the event is in Wednesday's column" is a CONTAINMENT fact. `html =~
  #     ~s(data-date="2026-08-05")` is satisfied by a grid that renders the
  #     right column and puts every event in Monday's.
  #   * `attribute/2` returns one entry per match in document order and skips
  #     nodes that lack the attribute, which is exactly the shape an ordering
  #     or a one-of-two assertion needs.
  #
  # `Floki` is deliberately not used — it is not a dependency of this
  # umbrella, and a test written against it compiles and then fails at
  # runtime on every assertion at once, which reads like a real regression.
  describe ":index action — desktop week grid" do
    # A real IANA zone with a UTC offset, so a test that confused local and
    # UTC clock readings cannot accidentally pass. Fixed rather than derived
    # from the machine: the grid's whole contract is "the VIEWER's zone", and
    # a fixture that inherits the server's cannot tell the two apart.
    @grid_zone "America/Chicago"

    setup %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      Repo.delete_all(Meeting)
      project = create_project()
      {:ok, conn: conn, user: user, project: project}
    end

    defp grid_conn(conn), do: put_connect_params(conn, %{"timezone" => @grid_zone})

    defp grid_today, do: PlatformWeb.MeetingLive.calendar_today_date(@grid_zone)

    # A UTC instant for a wall-clock time in the viewer's zone. Everything
    # persisted is UTC; everything asserted is local; this is the only place
    # the two meet.
    defp zoned_utc(%Date{} = date, hour, minute) do
      date
      |> DateTime.new!(Time.new!(hour, minute, 0), @grid_zone)
      |> DateTime.shift_zone!("Etc/UTC")
    end

    defp seed_grid_meeting(project, opts) do
      space = create_space()
      meeting_id = Platform.Types.UUIDv7.generate()

      attrs =
        %{
          project_id: project.id,
          chat_space_id: space.id,
          slug: Keyword.fetch!(opts, :slug),
          name: Keyword.get(opts, :name, "Meeting #{Keyword.fetch!(opts, :slug)}"),
          livekit_room_name: "meeting-#{meeting_id}",
          status: Keyword.get(opts, :status, "scheduled"),
          scheduled_start_at: Keyword.get(opts, :scheduled_start_at),
          scheduled_end_at: Keyword.get(opts, :scheduled_end_at)
        }

      {:ok, meeting} =
        %Meeting{id: meeting_id}
        |> Meeting.changeset(attrs)
        |> Repo.insert()

      meeting
    end

    defp doc(html), do: LazyHTML.from_fragment(html)

    defp attrs_of(html, selector, attribute) do
      html |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(attribute)
    end

    defp column_selector(%Date{} = date),
      do: ~s([data-role="calendar-day-column"][data-date="#{Date.to_iso8601(date)}"])

    # Task 019fb954-8ead stage 3 landed the mobile day view, which renders
    # `data-role="calendar-event"` and `data-role="calendar-now-line"` from
    # the SAME contract as the grid — deliberately, so one selector reads
    # both halves. The consequence for these tests is that an unscoped
    # "exactly one event is on the page" is no longer a claim about the
    # desktop grid; it is a claim about both halves at once, and it fails
    # for a reason that has nothing to do with the grid. Every desktop
    # assertion therefore scopes itself inside the week grid.
    defp in_grid(selector), do: ~s([data-role="calendar-week-grid"] #{selector})

    test "the grid renders its chrome with zero meetings", %{conn: conn} do
      # A calendar's empty state is an empty calendar. This is the assertion
      # that used to read `refute html =~ ~s(data-region="meetings-list")` in
      # the empty-state describe above: the region is no longer conditional
      # on there being meetings to put in it.
      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      assert attrs_of(html, ~s([data-role="calendar-week-grid"]), "data-role") ==
               ["calendar-week-grid"]

      assert length(attrs_of(html, ~s([data-role="calendar-week-day-heading"]), "data-date")) == 7
      assert length(attrs_of(html, ~s([data-role="calendar-day-column"]), "data-date")) == 7
      assert attrs_of(html, in_grid(~s([data-role="calendar-event"])), "data-meeting-id") == []
    end

    test "the grid is the `lg` surface and the day view is the surface below it",
         %{conn: conn, project: project} do
      # ONE test, ONE document, BOTH halves — extended by stage 3 rather
      # than joined by a second test. LiveView renders a single document
      # containing every breakpoint's markup and there is no viewport at
      # test time, so each half alone is satisfied by a wrong answer:
      # "the grid carries hidden lg:grid" passes on a build that also
      # draws the day view at every width, and "the day view carries
      # lg:hidden" passes on one that draws neither. Only the pair says
      # the two halves swap at `lg`.
      #
      # Stage 4 extends the SAME test rather than adding a second one, for
      # the same reason: the detail PANEL and the detail SHEET are one more
      # pair that has to swap at exactly this breakpoint, and asserting
      # each alone admits a build that draws both at 375px.
      #
      # Stage 5 adds the third pair: the header's `new-meeting-button` and
      # the corner FAB are two entry points to ONE create flow, and exactly
      # one of them may be drawn at any width. Asserting the button alone
      # passes on a build that shows both at 1440px (a redundant, competing
      # create affordance); asserting the FAB alone passes on a build that
      # shows NEITHER at 1024px — a surface with no way to create a meeting.
      meeting =
        seed_grid_meeting(project,
          slug: "grid-responsive",
          name: "Responsive Meeting",
          scheduled_start_at: zoned_utc(grid_today(), 10, 0),
          scheduled_end_at: zoned_utc(grid_today(), 11, 0)
        )

      {:ok, view, html} = live(grid_conn(conn), ~p"/meetings")

      classes = fn html, selector ->
        html |> attrs_of(selector, "class") |> List.first() |> String.split()
      end

      grid_classes = classes.(html, ~s([data-role="calendar-week-grid"]))
      day_view_classes = classes.(html, ~s([data-role="calendar-day-view"]))

      assert "hidden" in grid_classes
      assert "lg:grid" in grid_classes
      assert "lg:hidden" in day_view_classes
      # …and the day view is not ALSO hidden below `lg`, which is the way
      # `lg:hidden` can be present and still mean "never drawn".
      refute "hidden" in day_view_classes

      # ── The create pair (stage 5) ──────────────────────────────────────
      button_classes = classes.(html, ~s([data-role="new-meeting-button"]))
      fab_classes = classes.(html, ~s([data-role="start-meeting-fab"]))

      assert "hidden" in button_classes
      assert "lg:inline-flex" in button_classes
      assert "lg:hidden" in fab_classes
      # The same trap as the day view: a FAB carrying both `hidden` and
      # `lg:hidden` is never drawn at any width, and the mobile surface
      # loses its only create path while this pin stays green.
      refute "hidden" in fab_classes

      # The FAB is `position: fixed`, so it is out of flow and the in-flow
      # bottom nav does NOT push it up — the offset has to reserve that
      # height itself or the FAB sits behind the nav on a phone. Asserted by
      # EQUALITY on the whole token, not by substring: the token is a literal
      # class string with no clock and no entropy, so it is stable, and a
      # substring assertion cannot see a LONGER token that silently changed
      # the arithmetic. (Equality would be the wrong tool on a generated
      # value; it is the right one here.)
      assert Enum.find(fab_classes, &String.starts_with?(&1, "bottom-[")) ==
               "bottom-[calc(env(safe-area-inset-bottom)+1.5rem+var(--bottom-nav-height,0px))]"

      # The detail pair, in the same document, on the same render.
      html =
        view
        |> element(in_grid(~s([data-role="calendar-event"][data-meeting-id="#{meeting.id}"])))
        |> render_click()

      panel_classes = classes.(html, ~s([data-role="meeting-detail-panel"]))
      sheet_classes = classes.(html, ~s([data-role="meeting-detail-sheet"]))

      assert "hidden" in panel_classes
      assert "lg:flex" in panel_classes
      assert "lg:hidden" in sheet_classes
      refute "hidden" in sheet_classes
    end

    # The task's mobile floor. Named as a number rather than as a class so
    # the assertion below can be wrong about the class and still right about
    # the requirement.
    @touch_target_px 44

    # Tailwind's spacing scale, `--spacing: 0.25rem` in the built stylesheet,
    # so `min-h-11` is 11 × 4px. Resolved arithmetically rather than matched
    # as a literal: a test that greps for the string `min-h-11` is satisfied
    # by `min-h-10` being swapped in for it only if someone remembers to
    # update the grep, and it cannot say WHY 11 is the right number.
    defp tailwind_spacing_px(token, prefix) do
      case Float.parse(String.replace_prefix(token, prefix, "")) do
        {steps, ""} -> steps * 4
        _ -> nil
      end
    end

    test "the header count chip counts the blocks the grid drew, not the rows it loaded",
         %{conn: conn, project: project} do
      # The defect this pins: the chip read `7 total` beside a grid holding
      # 5 blocks. It was `length(@meetings)` — a binding left over from the
      # meetings LIST this surface used to be, where `@meetings` WAS what
      # was on screen. The calendar replaced the list; the chip kept
      # pointing at the old collection.
      #
      # The fixture is sized so that three different wrong answers are three
      # different numbers, because a fixture where the wrong answer happens
      # to equal the right one cannot fail:
      #
      #   5 — every row loaded (the defect)
      #   3 — every PLACEABLE row, ignoring the rendered week
      #   2 — the blocks actually drawn (correct)
      today = grid_today()

      for {slug, hour} <- [{"chip-placed-a", 10}, {"chip-placed-b", 14}] do
        seed_grid_meeting(project,
          slug: slug,
          scheduled_start_at: zoned_utc(today, hour, 0),
          scheduled_end_at: zoned_utc(today, hour + 1, 0)
        )
      end

      # Excluded by the status conjunct of `placeable?/1`…
      seed_grid_meeting(project,
        slug: "chip-cancelled",
        status: "cancelled",
        scheduled_start_at: zoned_utc(today, 11, 0),
        scheduled_end_at: zoned_utc(today, 12, 0)
      )

      # …and by the `scheduled_start_at` conjunct. Both are rows the grid
      # deliberately refuses to place, and both were counted.
      seed_grid_meeting(project, slug: "chip-unscheduled", status: "scheduled")

      # Placeable, but three weeks out — so it is not in the rendered week
      # and must not be in the rendered week's count. This is the half of
      # the defect that a `total` label made invisible: the old source was
      # unscoped in time as well as unfiltered by status.
      far = Date.add(today, 21)

      seed_grid_meeting(project,
        slug: "chip-next-month",
        scheduled_start_at: zoned_utc(far, 10, 0),
        scheduled_end_at: zoned_utc(far, 11, 0)
      )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      chip =
        html |> doc() |> LazyHTML.query(~s([data-role="meetings-count"])) |> LazyHTML.text()

      # Equality on the whole string, not `=~ "2"`. A substring assertion
      # for the digit is satisfied by `2 total` — which is the un-scoped
      # label the fix exists to retire — and by `12 meetings this week`.
      assert String.trim(chip) == "2 meetings this week"

      # And it agrees with the grid it sits beside, counted independently
      # off the rendered document rather than restated from the fixture.
      # This is the claim the chip makes and the one it broke; if a future
      # change makes the two disagree, the number above being right about
      # the fixture would not save it.
      assert length(attrs_of(html, in_grid(~s([data-role="calendar-event"])), "data-meeting-id")) ==
               2
    end

    test "the FAB meets the 44px touch-target floor", %{conn: conn} do
      # The defect this pins: the FAB measured 35.00 × 35.00px, computed
      # `min-height: 0px` / `min-width: 0px`, on the ONLY create path a
      # phone has. `btn-circle` was not broken and nothing was overriding
      # it — read out of the built stylesheet, `.btn-circle` resolves to
      # `width: var(--size); height: var(--size)`, `.btn` sets
      # `--size: calc(var(--size-field, 0.25rem) * 10)`, and this app's
      # theme sets `--size-field: 0.21875rem`. 0.21875 × 10 = 2.1875rem =
      # 35px, exactly the measurement. The class was faithfully rendering a
      # token that is under the floor.
      #
      # So the floor has to be asserted as a floor. What is checked is the
      # NUMBER the rendered constraint resolves to, not that a constraint is
      # present: the element was present at 35px the entire time, and so was
      # `btn-circle`.
      {:ok, _html, html} = live(grid_conn(conn), ~p"/meetings")

      fab_classes =
        html |> attrs_of(~s([data-role="start-meeting-fab"]), "class") |> List.first()

      assert is_binary(fab_classes)
      fab_classes = String.split(fab_classes)

      # Exactly one of each. Two `min-h-*` tokens on one element is a
      # cascade race whose winner depends on the order Tailwind emitted
      # them in, which is not a thing this test — or the reader — can see.
      assert [min_h] = Enum.filter(fab_classes, &String.starts_with?(&1, "min-h-"))
      assert [min_w] = Enum.filter(fab_classes, &String.starts_with?(&1, "min-w-"))

      assert tailwind_spacing_px(min_h, "min-h-") >= @touch_target_px
      assert tailwind_spacing_px(min_w, "min-w-") >= @touch_target_px

      # The floor is stated as `min-*` deliberately. `size-*` sets the same
      # two properties `btn-circle` already sets, so it would win or lose on
      # emission order; `min-width`/`min-height` beat `width`/`height` in the
      # box model whatever that order is. A fix that swapped to `size-11`
      # would measure 44px today and silently stop the day daisyUI's rule
      # moved below it in the bundle.
      refute Enum.any?(fab_classes, &String.starts_with?(&1, "size-"))

      # Growing the button must not eat its clearance over the bottom nav.
      # Re-asserted here, on the same render, because this test is the one
      # that changes the button's size — and because a browser cannot check
      # it: headless Chrome resolves `env(safe-area-inset-*)` to 0, so the
      # inset term contributes nothing to a measured clearance and the
      # result looks fine while the term is missing.
      assert Enum.find(fab_classes, &String.starts_with?(&1, "bottom-[")) ==
               "bottom-[calc(env(safe-area-inset-bottom)+1.5rem+var(--bottom-nav-height,0px))]"
    end

    test "a meeting lands in the column matching its local date, at its computed offset",
         %{conn: conn, project: project} do
      today = grid_today()

      meeting =
        seed_grid_meeting(project,
          slug: "grid-placed",
          name: "Placed Meeting",
          scheduled_start_at: zoned_utc(today, 10, 0),
          scheduled_end_at: zoned_utc(today, 11, 0)
        )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      # It is in TODAY's column, and it is the only event on the grid — so a
      # grid that renders every meeting in every column fails here.
      assert attrs_of(html, in_grid(~s([data-role="calendar-event"])), "data-meeting-id") ==
               [meeting.id]

      assert attrs_of(
               html,
               ~s(#{column_selector(today)} [data-role="calendar-event"]),
               "data-meeting-id"
             ) == [meeting.id]

      # Hand-computed against the default {8, 18} window this single 10:00
      # meeting does not widen: the window is 600 minutes, the meeting starts
      # 120 minutes into it (120/600 = 20%) and runs 60 (60/600 = 10%). With
      # nothing to share the column with it takes the whole width, less the
      # 0.25rem gutter on each side.
      assert attrs_of(html, in_grid(~s([data-role="calendar-event"])), "style") ==
               ["top:20.0%;height:10.0%;left:calc(0.0% + 0.25rem);width:calc(100.0% - 0.5rem)"]

      # And it carries its own status, not a rendered guess at one.
      assert attrs_of(html, in_grid(~s([data-role="calendar-event"])), "data-meeting-status") ==
               ["scheduled"]

      assert attrs_of(html, in_grid(~s([data-role="calendar-event"])), "phx-value-id") ==
               [meeting.id]
    end

    test "a meeting with no scheduled_start_at renders no event block and does not raise",
         %{conn: conn, project: project} do
      seed_grid_meeting(project, slug: "grid-adhoc", name: "Ad-hoc Meeting")

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      # The grid still draws — an unplaceable meeting is not an error state.
      assert attrs_of(html, ~s([data-role="calendar-week-grid"]), "data-role") ==
               ["calendar-week-grid"]

      assert attrs_of(html, in_grid(~s([data-role="calendar-event"])), "data-meeting-id") == []
    end

    test "a cancelled meeting is not placed while a scheduled one at the same instant is",
         %{conn: conn, project: project} do
      # Two rows, ONE variable: same day, same instant, same duration, same
      # project. Status is the only thing that differs, so a failure here can
      # only be about status.
      today = grid_today()
      start_at = zoned_utc(today, 14, 0)
      end_at = zoned_utc(today, 15, 0)

      _cancelled =
        seed_grid_meeting(project,
          slug: "grid-cancelled",
          name: "Cancelled Meeting",
          status: "cancelled",
          scheduled_start_at: start_at,
          scheduled_end_at: end_at
        )

      scheduled =
        seed_grid_meeting(project,
          slug: "grid-scheduled",
          name: "Scheduled Meeting",
          status: "scheduled",
          scheduled_start_at: start_at,
          scheduled_end_at: end_at
        )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      assert attrs_of(html, in_grid(~s([data-role="calendar-event"])), "data-meeting-id") ==
               [scheduled.id]
    end

    test "a live meeting carries data-live while a scheduled one at the same instant does not",
         %{conn: conn, project: project} do
      today = grid_today()
      start_at = zoned_utc(today, 9, 0)
      end_at = zoned_utc(today, 10, 0)

      live_meeting =
        seed_grid_meeting(project,
          slug: "grid-live",
          name: "Live Meeting",
          status: "live",
          scheduled_start_at: start_at,
          scheduled_end_at: end_at
        )

      scheduled =
        seed_grid_meeting(project,
          slug: "grid-not-live",
          name: "Scheduled Meeting",
          status: "scheduled",
          scheduled_start_at: start_at,
          scheduled_end_at: end_at
        )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      live_selector =
        in_grid(~s([data-role="calendar-event"][data-meeting-id="#{live_meeting.id}"]))

      scheduled_selector =
        in_grid(~s([data-role="calendar-event"][data-meeting-id="#{scheduled.id}"]))

      # Both halves named, because `attribute/2` skips nodes without the
      # attribute: asserting only the presence of one `"true"` on the page
      # cannot tell which of the two blocks carries it.
      assert attrs_of(html, live_selector, "data-live") == ["true"]
      assert attrs_of(html, scheduled_selector, "data-live") == []

      # The live variant is a SHAPE, and it is inside the live block only.
      assert attrs_of(
               html,
               ~s(#{live_selector} [data-role="calendar-event-live-dot"]),
               "data-role"
             ) == ["calendar-event-live-dot"]

      assert attrs_of(html, in_grid(~s([data-role="calendar-event-live-dot"])), "data-role") ==
               ["calendar-event-live-dot"]
    end

    test "concurrent meetings take separate lanes in the week grid and sequential ones do not",
         %{conn: conn, project: project} do
      # The sponsor's defect, pinned. Two 30-minute meetings at the same
      # time and two 30-minute meetings back to back, in the same column, on
      # the same day: one variable across two rows. Nothing about "both
      # render" would have failed before the fix.
      today = grid_today()

      concurrent_a =
        seed_grid_meeting(project,
          slug: "grid-lane-same-a",
          name: "Same Time A",
          scheduled_start_at: zoned_utc(today, 10, 0),
          scheduled_end_at: zoned_utc(today, 10, 30)
        )

      concurrent_b =
        seed_grid_meeting(project,
          slug: "grid-lane-same-b",
          name: "Same Time B",
          scheduled_start_at: zoned_utc(today, 10, 0),
          scheduled_end_at: zoned_utc(today, 10, 30)
        )

      sequential_a =
        seed_grid_meeting(project,
          slug: "grid-lane-seq-a",
          name: "Sequential A",
          scheduled_start_at: zoned_utc(today, 14, 0),
          scheduled_end_at: zoned_utc(today, 14, 30)
        )

      sequential_b =
        seed_grid_meeting(project,
          slug: "grid-lane-seq-b",
          name: "Sequential B",
          scheduled_start_at: zoned_utc(today, 14, 30),
          scheduled_end_at: zoned_utc(today, 15, 0)
        )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      assert grid_lane_of(html, concurrent_a) == {"0", "2"}
      assert grid_lane_of(html, concurrent_b) == {"1", "2"}

      assert grid_horizontal_of(html, concurrent_a) ==
               "left:calc(0.0% + 0.25rem);width:calc(50.0% - 0.5rem)"

      assert grid_horizontal_of(html, concurrent_b) ==
               "left:calc(50.0% + 0.25rem);width:calc(50.0% - 0.5rem)"

      # Back to back is not a conflict: both keep the full column, and it is
      # their VERTICAL position that differs.
      assert grid_lane_of(html, sequential_a) == {"0", "1"}
      assert grid_lane_of(html, sequential_b) == {"0", "1"}

      assert grid_horizontal_of(html, sequential_a) ==
               "left:calc(0.0% + 0.25rem);width:calc(100.0% - 0.5rem)"

      assert grid_horizontal_of(html, sequential_a) == grid_horizontal_of(html, sequential_b)

      refute grid_style_of(html, sequential_a) == grid_style_of(html, sequential_b)
    end

    test "a block too short for two lines drops to one, and a taller one does not",
         %{conn: conn, project: project} do
      # The other half of dropping the pixel floor. The floor existed
      # because a half-hour block in a 3.25rem row is 26px and clips its own
      # time line; removing it without answering that would re-open the
      # defect it was added for. The answer is one line, not a taller box —
      # a taller box is what collided with the block below it.
      today = grid_today()

      short =
        seed_grid_meeting(project,
          slug: "grid-compact-short",
          name: "Short Meeting",
          scheduled_start_at: zoned_utc(today, 10, 0),
          scheduled_end_at: zoned_utc(today, 10, 30)
        )

      tall =
        seed_grid_meeting(project,
          slug: "grid-compact-tall",
          name: "Long Meeting",
          scheduled_start_at: zoned_utc(today, 14, 0),
          scheduled_end_at: zoned_utc(today, 16, 0)
        )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      assert attrs_of(html, grid_selector(short), "data-compact") == ["true"]
      assert attrs_of(html, grid_selector(tall), "data-compact") == []

      # And the threshold is a real measurement of the two halves, not a
      # duration guess: 26px of a 35px requirement against 104px of it.
      window = {8, 18}
      assert PlatformWeb.MeetingLive.calendar_compact_block?(%{height: 5.0}, window, :week)
      refute PlatformWeb.MeetingLive.calendar_compact_block?(%{height: 20.0}, window, :week)
    end

    defp grid_selector(meeting),
      do: in_grid(~s([data-role="calendar-event"][data-meeting-id="#{meeting.id}"]))

    defp grid_style_of(html, meeting),
      do: html |> attrs_of(grid_selector(meeting), "style") |> List.first()

    defp grid_horizontal_of(html, meeting),
      do: html |> grid_style_of(meeting) |> String.split(";") |> Enum.drop(2) |> Enum.join(";")

    defp grid_lane_of(html, meeting) do
      {
        html |> attrs_of(grid_selector(meeting), "data-lane") |> List.first(),
        html |> attrs_of(grid_selector(meeting), "data-lanes") |> List.first()
      }
    end

    test "the now-line renders inside today's column only", %{conn: conn, project: project} do
      # Seeded at the CURRENT local hour so `hour_window/2` is guaranteed to
      # contain "now" whatever time this suite runs at. Without it, a 3 AM
      # run would draw no now-line at all and the assertion would be vacuous
      # in a way that looks green.
      today = grid_today()
      now = DateTime.now!(@grid_zone)

      seed_grid_meeting(project,
        slug: "grid-nowline-anchor",
        name: "Now Anchor",
        scheduled_start_at: zoned_utc(today, now.hour, 0),
        scheduled_end_at: zoned_utc(today, now.hour, 30)
      )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      # Exactly one, and it is in today's column. A now-line drawn in every
      # column would satisfy "it is in today's column" and fail the count.
      assert attrs_of(html, in_grid(~s([data-role="calendar-now-line"])), "data-role") ==
               ["calendar-now-line"]

      assert attrs_of(
               html,
               ~s(#{column_selector(today)} [data-role="calendar-now-line"]),
               "data-role"
             ) == ["calendar-now-line"]
    end

    test "the now-line MOVES on the beat", %{conn: conn} do
      # The defect this pins: the line rendered at the right place on the
      # first paint and then never moved again for the life of the session.
      # A now-line frozen at mount is a confidently wrong answer that looks
      # exactly like a right one, and it survived review because the only
      # thing asserted about it was that the ELEMENT existed — which it did,
      # the whole time. So the assertion here is on the rendered `top`, and
      # it is that two beats produce two DIFFERENT values.
      #
      # The instants are injected via the tick's arity-2 message rather than
      # slept for: the offset is minute-granular, so a test driving the bare
      # `:calendar_tick` twice inside one wall-clock minute reads the same
      # percentage both times and cannot tell a working line from a frozen
      # one. No meetings are seeded, so `hour_window/2` stays at its default
      # {8, 18} — 600 minutes — and the arithmetic below is exact.
      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")

      today = grid_today()

      beat = fn hour, minute ->
        send(view.pid, {:calendar_tick, zoned_utc(today, hour, minute)})
        attrs_of(render(view), in_grid(~s([data-role="calendar-now-line"])), "style")
      end

      # 09:00 is 60 minutes into a 600-minute window.
      first = beat.(9, 0)
      # 09:06 is 66. Six minutes on rather than one so the expected values
      # are exact decimals and the assertion pins a number instead of a
      # float repr.
      second = beat.(9, 6)

      assert first == ["top:10.0%"]
      assert second == ["top:11.0%"]

      # Stated separately and on purpose. The two equalities above would
      # both hold against a lucky clock; this is the claim the defect
      # violated, and it cannot hold for a line that is not recomputed.
      assert first != second
    end

    test "today's day heading is the only one marked, and it is the viewer's today",
         %{conn: conn} do
      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      # Exactly one marked day…
      assert attrs_of(
               html,
               ~s([data-role="calendar-week-day-heading"] [data-today]),
               "data-today"
             ) == ["true"]

      # …and it is the day the viewer's zone calls today. Walked per-heading
      # rather than with a `:has()` selector so the association between the
      # heading's `data-date` and the marker inside it is the thing asserted,
      # not the coincidence that both strings appear on the page.
      marked =
        html
        |> doc()
        |> LazyHTML.query(~s([data-role="calendar-week-day-heading"]))
        |> Enum.filter(
          &(LazyHTML.attribute(LazyHTML.query(&1, "[data-today]"), "data-today") != [])
        )
        |> Enum.flat_map(&LazyHTML.attribute(&1, "data-date"))

      assert marked == [Date.to_iso8601(grid_today())]
    end

    test "the zone label renders the resolved zone when connected", %{conn: conn} do
      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      assert html
             |> doc()
             |> LazyHTML.query(~s([data-role="calendar-timezone"]))
             |> LazyHTML.text()
             |> String.trim() == @grid_zone
    end

    test "the dead render names no zone rather than guessing UTC", %{conn: conn} do
      # The static render carries no connect params, so there is no resolved
      # zone. Printing `UTC` there would be a confident wrong answer that
      # nobody notices until they miss a call, so the label is ABSENT.
      html = conn |> get(~p"/meetings") |> html_response(200)

      assert attrs_of(html, ~s([data-role="calendar-week-grid"]), "data-role") ==
               ["calendar-week-grid"]

      assert attrs_of(html, ~s([data-role="calendar-timezone"]), "data-role") == []
      refute html =~ "Etc/UTC"
    end

    test "the week nav pages the label and Today returns to it", %{conn: conn} do
      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")

      this_week = PlatformWeb.MeetingLive.calendar_week_label(grid_today())
      next_week = PlatformWeb.MeetingLive.calendar_week_label(Date.add(grid_today(), 7))
      previous_week = PlatformWeb.MeetingLive.calendar_week_label(Date.add(grid_today(), -7))

      assert week_label(view) == this_week

      view |> element(~s([phx-click="calendar_next_week"])) |> render_click()
      assert week_label(view) == next_week

      view |> element(~s([phx-click="calendar_prev_week"])) |> render_click()
      view |> element(~s([phx-click="calendar_prev_week"])) |> render_click()
      assert week_label(view) == previous_week

      view |> element(~s([phx-click="calendar_today"])) |> render_click()
      assert week_label(view) == this_week
    end

    defp week_label(view) do
      view
      |> element(~s([data-role="calendar-week-label"]))
      |> render()
      |> doc()
      |> LazyHTML.text()
      |> String.trim()
    end

    # ── An unresolvable zone is not an empty week (task 019fd220 stage 1) ──
    #
    # `resolve_time_zone/1` answers nil for BOTH "nothing was sent" and
    # "something was sent and Tzdata does not know it", and the week query
    # is skipped on nil either way. On the connected client the second
    # cause is permanent — connect params are read once, in `mount/3`, and
    # nothing re-attempts — so the viewer sits in front of a calendar that
    # says "No meetings" forever while meetings exist. These tests pin the
    # SERVER state that tells the two causes apart; the markup that says so
    # is stage 2's.
    defp calendar_assigns(view), do: :sys.get_state(view.pid).socket.assigns

    test "a connected mount with no zone param records the nil arm as unresolved",
         %{conn: conn} do
      # ANTI-VACUITY: this is a CONNECTED mount (`live/2`, no
      # `put_connect_params`) whose zone is nil, which is the hazard
      # itself. Asserting the connected-side assigns rather than the empty
      # page is what records that the nil arm was entered — an empty page
      # is what a genuinely empty week looks like too.
      {:ok, view, _html} = live(conn, ~p"/meetings")

      assigns = calendar_assigns(view)

      assert assigns.calendar_time_zone == nil
      assert assigns.calendar_zone_unresolved?
      assert assigns.calendar_zone_assumed? == false
      # No param was sent, so there is no browser string to show back.
      assert assigns.calendar_time_zone_raw == nil
    end

    test "an unknown zone keeps the raw browser string, distinguishing it from no param",
         %{conn: conn} do
      {:ok, view, _html} =
        live(put_connect_params(conn, %{"timezone" => "Mars/Olympus"}), ~p"/meetings")

      assigns = calendar_assigns(view)

      assert assigns.calendar_time_zone == nil
      assert assigns.calendar_zone_unresolved?
      # The whole point of keeping the raw value: the two nil-zone causes
      # are different situations and must not read the same.
      assert assigns.calendar_time_zone_raw == "Mars/Olympus"
    end

    test "a resolvable zone is not unresolved (positive control)", %{conn: conn} do
      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")

      assigns = calendar_assigns(view)

      assert assigns.calendar_time_zone == @grid_zone
      refute assigns.calendar_zone_unresolved?
      assert assigns.calendar_time_zone_raw == nil
    end

    test "the dead render is unchanged — nil there is the intended answer", %{conn: conn} do
      # `connected?/1` is the discriminator precisely so the STATIC render
      # keeps saying nothing. There is no process to read assigns from on a
      # plain GET, so the claim is made where it is observable: the bytes.
      # This must stay true after stage 2 adds the connected-only affordance.
      html = conn |> get(~p"/meetings") |> html_response(200)

      assert attrs_of(html, ~s([data-role="calendar-week-grid"]), "data-role") ==
               ["calendar-week-grid"]

      refute html =~ "calendar_assume_utc"
      refute html =~ "Etc/UTC"
    end

    # ── The markup that tells the two nil-zone causes apart (stage 2) ──────
    #
    # Stage 1 pinned the SERVER state. These pin the RENDER, and they pin it
    # by reading named elements out of the parsed document rather than
    # matching substrings against the whole body: `html =~
    # ~s(data-empty-state="calendar-no-timezone")` is satisfied by the string
    # appearing anywhere, including inside a comment or an unrelated branch.

    test "an unresolved zone and a genuinely empty week render differently", %{conn: conn} do
      # THE distinguishing assertion, both halves in one test — because the
      # claim is a DIFFERENCE, and two tests that each assert one side pass
      # independently even if the two renders are identical.
      {:ok, _resolved, resolved_html} = live(grid_conn(conn), ~p"/meetings")
      {:ok, _unresolved, unresolved_html} = live(conn, ~p"/meetings")

      notice = ~s([data-empty-state="calendar-no-timezone"])
      count = ~s([data-role="calendar-day-count"])
      control = ~s([data-action="calendar-assume-utc"])

      # 1. The notice element exists on exactly one of them. A real empty
      #    week carries no such element at all.
      assert attrs_of(resolved_html, notice, "data-empty-state") == []
      assert attrs_of(unresolved_html, notice, "data-empty-state") == ["calendar-no-timezone"]

      # 2. The day count does not assert "No meetings" when nothing was
      #    counted. Asserted on the specific element, both sides.
      assert attrs_of(resolved_html, count, "data-count-state") == []
      assert attrs_of(unresolved_html, count, "data-count-state") == ["unknown"]

      assert day_count_text(resolved_html) == "No meetings"
      assert day_count_text(unresolved_html) == "—"

      # The header count is the same assertion at week scale and it is the
      # one read first. Found in a measured screenshot, not in the brief.
      week_count = ~s([data-role="meetings-count"])

      assert attrs_of(resolved_html, week_count, "data-count-state") == []
      assert attrs_of(unresolved_html, week_count, "data-count-state") == ["unknown"]

      refute unresolved_html
             |> doc()
             |> LazyHTML.query(week_count)
             |> LazyHTML.text() =~ "No meetings"

      # 3. The control count is the third difference: one offers a next
      #    action, the other has none to offer.
      assert length(attrs_of(unresolved_html, control, "data-action")) == 1
      assert length(attrs_of(resolved_html, control, "data-action")) == 0
    end

    test "the notice is absent from a resolved week that actually has meetings", %{
      conn: conn,
      project: project
    } do
      # ANTI-VACUITY control for the test above: "the notice is absent" must
      # not be satisfiable by a page that failed to render at all. Three
      # meetings drawn in three named columns prove the calendar is alive.
      monday = Date.beginning_of_week(grid_today())

      seeded =
        for {slug, offset, hour} <- [{"tz-mon", 0, 9}, {"tz-wed", 2, 13}, {"tz-fri", 4, 17}] do
          date = Date.add(monday, offset)
          start_at = zoned_utc(date, hour, 0)

          meeting =
            seed_grid_meeting(project,
              slug: slug,
              scheduled_start_at: start_at,
              scheduled_end_at: DateTime.add(start_at, 3600, :second)
            )

          {meeting, date}
        end

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      for {meeting, date} <- seeded do
        assert attrs_of(
                 html,
                 in_grid(~s(#{column_selector(date)} [data-role="calendar-event"])),
                 "data-meeting-id"
               ) == [meeting.id]
      end

      assert attrs_of(html, ~s([data-empty-state="calendar-no-timezone"]), "data-empty-state") ==
               []

      assert attrs_of(html, ~s([data-action="calendar-assume-utc"]), "data-action") == []
    end

    test "the rejected browser string is shown back, escaped, and only when one was sent", %{
      conn: conn
    } do
      {:ok, _view, with_raw} =
        live(put_connect_params(conn, %{"timezone" => "Mars/Olympus"}), ~p"/meetings")

      assert with_raw
             |> doc()
             |> LazyHTML.query(~s([data-role="calendar-no-timezone-raw"]))
             |> LazyHTML.text()
             |> String.trim() == "Mars/Olympus"

      # No param sent — there is no browser string to quote, and inventing
      # one would make the two nil-zone causes read the same again.
      {:ok, _view, no_param} = live(conn, ~p"/meetings")

      assert attrs_of(no_param, ~s([data-role="calendar-no-timezone-raw"]), "data-role") == []

      # The notice itself is present in BOTH — only the quoted string differs.
      assert attrs_of(no_param, ~s([data-empty-state="calendar-no-timezone"]), "data-empty-state") ==
               ["calendar-no-timezone"]
    end

    test "the raw browser string is escaped rather than interpolated as markup", %{conn: conn} do
      # It is client-controlled. `raw/1` here would be stored XSS reachable
      # by anyone who can set a connect param.
      injected = "</p><script>alert(1)</script>"

      {:ok, _view, html} =
        live(put_connect_params(conn, %{"timezone" => injected}), ~p"/meetings")

      refute html =~ "<script>alert(1)</script>"

      assert html
             |> doc()
             |> LazyHTML.query(~s([data-role="calendar-no-timezone-raw"]))
             |> LazyHTML.text()
             |> String.trim() =~ "alert(1)"
    end

    test "clicking the control marks the zone assumed and draws the week", %{
      conn: conn,
      project: project
    } do
      today = Date.utc_today()
      monday = Date.beginning_of_week(today)

      seeded =
        for {slug, offset, hour} <- [{"btn-mon", 0, 9}, {"btn-wed", 2, 13}, {"btn-fri", 4, 17}] do
          date = Date.add(monday, offset)
          start_at = DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")

          meeting =
            seed_grid_meeting(project,
              slug: slug,
              scheduled_start_at: start_at,
              scheduled_end_at: DateTime.add(start_at, 3600, :second)
            )

          {meeting, date}
        end

      {:ok, view, _html} = live(conn, ~p"/meetings")

      # Through the rendered control, not by pushing the event name — the
      # button being wired is part of the claim.
      html = view |> element(~s([data-action="calendar-assume-utc"])) |> render_click()

      # An assumed zone must not present itself as a detected one.
      assert attrs_of(html, ~s([data-role="calendar-timezone"]), "data-zone-assumed") == ["true"]

      assert html
             |> doc()
             |> LazyHTML.query(~s([data-role="calendar-timezone-assumed-note"]))
             |> LazyHTML.text()
             |> String.trim() != ""

      assert attrs_of(html, ~s([data-empty-state="calendar-no-timezone"]), "data-empty-state") ==
               []

      for {meeting, date} <- seeded do
        assert attrs_of(
                 html,
                 in_grid(~s(#{column_selector(date)} [data-role="calendar-event"])),
                 "data-meeting-id"
               ) == [meeting.id]
      end
    end

    test "a zone that resolved normally carries no assumed marker", %{conn: conn} do
      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      assert attrs_of(html, ~s([data-role="calendar-timezone"]), "data-zone-assumed") == []

      assert attrs_of(html, ~s([data-role="calendar-timezone-assumed-note"]), "data-role") == []
    end

    defp day_count_text(html) do
      html
      |> doc()
      |> LazyHTML.query(~s([data-role="calendar-day-count"]))
      |> LazyHTML.text()
      |> String.trim()
    end

    test "assuming UTC queries the week and places every meeting in it", %{
      conn: conn,
      project: project
    } do
      # With no zone the anchor week is the UTC week containing UTC today
      # (`calendar_today_date(nil, now)` is `DateTime.to_date(now)`), so the
      # fixture is built in UTC — the zone the viewer is about to assume.
      today = Date.utc_today()
      monday = Date.beginning_of_week(today)

      # THREE meetings on three different days at three different times.
      # One would let "place any arbitrary row" pass; three in named
      # columns will not.
      placements = [
        {"utc-mon", Date.add(monday, 0), 9},
        {"utc-wed", Date.add(monday, 2), 13},
        {"utc-fri", Date.add(monday, 4), 17}
      ]

      seeded =
        Enum.map(placements, fn {slug, date, hour} ->
          start_at = DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")

          meeting =
            seed_grid_meeting(project,
              slug: slug,
              status: "scheduled",
              scheduled_start_at: start_at,
              scheduled_end_at: DateTime.add(start_at, 3600, :second)
            )

          {meeting, date}
        end)

      {:ok, view, _html} = live(conn, ~p"/meetings")

      # The hazard first: the week is EMPTY while the zone is unresolved,
      # even though all three rows exist.
      assert attrs_of(render(view), in_grid(~s([data-role="calendar-event"])), "data-meeting-id") ==
               []

      html = render_click(view, "calendar_assume_utc", %{})

      assigns = calendar_assigns(view)
      assert assigns.calendar_time_zone == "Etc/UTC"
      assert assigns.calendar_zone_assumed?
      refute assigns.calendar_zone_unresolved?

      # BY ID, per column — not by count and not by non-emptiness.
      for {meeting, date} <- seeded do
        assert attrs_of(
                 html,
                 in_grid(~s(#{column_selector(date)} [data-role="calendar-event"])),
                 "data-meeting-id"
               ) == [meeting.id]
      end

      assert Enum.sort(
               attrs_of(html, in_grid(~s([data-role="calendar-event"])), "data-meeting-id")
             ) == Enum.sort(Enum.map(seeded, fn {meeting, _date} -> meeting.id end))
    end

    test "assuming UTC is a no-op for a viewer whose zone resolved", %{conn: conn} do
      # The event can be pushed from a console. Honouring it for a viewer
      # who already has a zone would silently move every block on their
      # calendar by an unstated offset.
      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")

      render_click(view, "calendar_assume_utc", %{})

      assigns = calendar_assigns(view)
      assert assigns.calendar_time_zone == @grid_zone
      refute assigns.calendar_zone_assumed?
      refute assigns.calendar_zone_unresolved?
    end
  end

  # ── Mobile week strip + day view (task 019fb954-8ead stage 3) ────────────
  #
  # Below `lg` the calendar is a different information architecture, not a
  # narrower grid: a week strip for navigation over a single-column day
  # view for detail. These tests read the same document the desktop ones
  # do — there is no viewport at test time — so each one names the half it
  # is about, either by scoping inside `[data-role="calendar-day-view"]` or
  # by asserting the breakpoint classes directly (see "the grid is the `lg`
  # surface and the day view is the surface below it", which is the one
  # test that pins the swap and deliberately stayed a single test).
  describe ":index action — mobile day view" do
    setup %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      Repo.delete_all(Meeting)
      project = create_project()
      {:ok, conn: conn, user: user, project: project}
    end

    defp day_view(selector), do: ~s([data-role="calendar-day-view"] #{selector})

    defp day_count_text(html) do
      html
      |> doc()
      |> LazyHTML.query(~s([data-role="calendar-day-count"]))
      |> LazyHTML.text()
      |> String.trim()
    end

    defp day_heading_date(html),
      do: html |> attrs_of(~s([data-role="calendar-day-heading"]), "data-date") |> List.first()

    defp strip_letters(html) do
      html
      |> doc()
      |> LazyHTML.query(~s([data-role="calendar-strip-day"]))
      |> Enum.map(fn cell ->
        cell
        |> LazyHTML.query(~s([data-role="calendar-strip-day-number"]))
        |> then(fn number -> String.replace(LazyHTML.text(cell), LazyHTML.text(number), "") end)
        |> String.trim()
      end)
    end

    # The expected week, derived from `Date.beginning_of_week/1`'s stdlib
    # `:monday` default rather than from anything the template calls.
    defp monday_first_week(%Date{} = anchor) do
      monday = Date.beginning_of_week(anchor)
      Enum.map(0..6, &Date.to_iso8601(Date.add(monday, &1)))
    end

    defp click_strip_day(view, %Date{} = date) do
      view
      |> element(~s([data-role="calendar-strip-day"][data-date="#{Date.to_iso8601(date)}"]))
      |> render_click()
    end

    test "the strip is seven cells, Monday first", %{conn: conn} do
      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      assert attrs_of(html, ~s([data-role="calendar-strip-day"]), "data-date") ==
               monday_first_week(grid_today())

      # The letters are the load-bearing half of "Monday first", and they
      # are literal rather than derived: a Sunday-first strip renders the
      # same SEVEN cells over a different span, and the date list alone
      # leaves a reader checking two week-start conventions against each
      # other. `S M T W T F S` and `M T W T F S S` cannot be confused.
      assert strip_letters(html) == ~w(M T W T F S S)

      # Every cell is a 44px touch target — the canvas pins that number
      # explicitly, and a 7-across strip at 375px is exactly where it bites.
      for class <- attrs_of(html, ~s([data-role="calendar-strip-day"]), "class") do
        assert "min-h-11" in String.split(class)
      end
    end

    test "the strip opens on the viewer's today, selected and marked", %{conn: conn} do
      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      today = Date.to_iso8601(grid_today())

      # Exactly one selected cell, and it is today's. Walked per-cell so
      # what is asserted is the ASSOCIATION between the cell's date and its
      # own marker, not that both strings appear somewhere on the page.
      assert marked_strip_dates(html, "data-selected") == [today]
      assert marked_strip_dates(html, "data-today") == [today]
      assert day_heading_date(html) == today
    end

    defp marked_strip_dates(html, attribute) do
      html
      |> doc()
      |> LazyHTML.query(~s([data-role="calendar-strip-day"]))
      |> Enum.filter(&(LazyHTML.attribute(&1, attribute) != []))
      |> Enum.flat_map(&LazyHTML.attribute(&1, "data-date"))
    end

    test "clicking a strip day moves the heading and the selection to that day",
         %{conn: conn} do
      {:ok, view, html} = live(grid_conn(conn), ~p"/meetings")

      today = grid_today()
      target = Enum.find(week_dates(today), &(Date.compare(&1, today) != :eq))

      assert day_heading_date(html) == Date.to_iso8601(today)

      html = click_strip_day(view, target)

      assert day_heading_date(html) == Date.to_iso8601(target)
      assert marked_strip_dates(html, "data-selected") == [Date.to_iso8601(target)]

      # The heading names the day in words, which is the whole reason it
      # exists: the strip prints one letter and a number.
      assert html
             |> doc()
             |> LazyHTML.query(~s([data-role="calendar-day-heading"]))
             |> LazyHTML.text() =~ Calendar.strftime(target, "%A, %b %-d")

      # `data-today` does NOT follow the selection — today is still today.
      assert marked_strip_dates(html, "data-today") == [Date.to_iso8601(today)]
    end

    defp week_dates(%Date{} = anchor) do
      monday = Date.beginning_of_week(anchor)
      Enum.map(0..6, &Date.add(monday, &1))
    end

    test "a Tuesday meeting is absent from the day view while Wednesday is selected, and its Wednesday sibling is present",
         %{conn: conn, project: project} do
      # TWO ROWS, ONE VARIABLE: same status, same wall-clock time, same
      # duration, same project. Only the date differs, so a failure here
      # can only be about which day the column is drawing.
      [_mon, tuesday, wednesday | _] = week_dates(grid_today())

      tue_meeting =
        seed_grid_meeting(project,
          slug: "mob-tuesday",
          name: "Tuesday Meeting",
          scheduled_start_at: zoned_utc(tuesday, 10, 0),
          scheduled_end_at: zoned_utc(tuesday, 11, 0)
        )

      wed_meeting =
        seed_grid_meeting(project,
          slug: "mob-wednesday",
          name: "Wednesday Meeting",
          scheduled_start_at: zoned_utc(wednesday, 10, 0),
          scheduled_end_at: zoned_utc(wednesday, 11, 0)
        )

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")

      html = click_strip_day(view, wednesday)

      assert attrs_of(html, day_view(~s([data-role="calendar-event"])), "data-meeting-id") ==
               [wed_meeting.id]

      # …and the absent one is absent because the DAY VIEW filters it, not
      # because it was never loaded: the desktop grid, reading the same
      # week's meetings, still draws both.
      assert attrs_of(html, in_grid(~s([data-role="calendar-event"])), "data-meeting-id") ==
               [tue_meeting.id, wed_meeting.id]

      html = click_strip_day(view, tuesday)

      assert attrs_of(html, day_view(~s([data-role="calendar-event"])), "data-meeting-id") ==
               [tue_meeting.id]
    end

    test "the day heading counts the meetings the column DRAWS, not the rows on that date",
         %{conn: conn, project: project} do
      [_mon, _tue, wednesday | _] = week_dates(grid_today())

      seed_grid_meeting(project,
        slug: "mob-count-a",
        name: "Counted A",
        scheduled_start_at: zoned_utc(wednesday, 9, 0),
        scheduled_end_at: zoned_utc(wednesday, 10, 0)
      )

      seed_grid_meeting(project,
        slug: "mob-count-b",
        name: "Counted B",
        scheduled_start_at: zoned_utc(wednesday, 11, 0),
        scheduled_end_at: zoned_utc(wednesday, 12, 0)
      )

      # Same day, same instant as B, differing only in status — so the
      # count can only move for a status reason.
      cancelled =
        seed_grid_meeting(project,
          slug: "mob-count-cancelled",
          name: "Cancelled C",
          status: "cancelled",
          scheduled_start_at: zoned_utc(wednesday, 11, 0),
          scheduled_end_at: zoned_utc(wednesday, 12, 0)
        )

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")

      html = click_strip_day(view, wednesday)

      assert day_count_text(html) == "2 meetings"

      refute cancelled.id in attrs_of(
               html,
               day_view(~s([data-role="calendar-event"])),
               "data-meeting-id"
             )
    end

    test "the count is worded, and singular for one meeting", %{conn: conn, project: project} do
      [_mon, _tue, wednesday | _] = week_dates(grid_today())

      seed_grid_meeting(project,
        slug: "mob-singular",
        name: "Only One",
        scheduled_start_at: zoned_utc(wednesday, 9, 0),
        scheduled_end_at: zoned_utc(wednesday, 9, 30)
      )

      {:ok, view, html} = live(grid_conn(conn), ~p"/meetings")

      # A day with nothing on it says so in words. `0 meetings` under an
      # empty column reads like a failed load; this is the only sentence a
      # phone gets about the selected day.
      empty_day = Enum.find(week_dates(grid_today()), &(Date.compare(&1, wednesday) != :eq))

      assert day_count_text(click_strip_day(view, empty_day)) == "No meetings"
      assert day_count_text(click_strip_day(view, wednesday)) == "1 meeting"

      # And the heading is present on the very first render, not only after
      # a click.
      assert day_count_text(html) in ["No meetings", "1 meeting"]
    end

    # The mobile touch-target floor, named once. It is the same 44px the
    # strip cells and every control on this page are asserted against.
    @mobile_touch_target_px 44

    test "the shortest block a phone can draw is a 44px touch target by GEOMETRY, with no CSS floor",
         %{conn: conn, project: project} do
      # The two constraints that were in direct conflict, asserted together
      # so they cannot silently diverge again.
      #
      # A CSS `min-height` of 44px is what the day view used to carry, and
      # it is what the sponsor saw: in a 48px hour row a half-hour block's
      # own slot is 24px, so a 44px floor drew it 20px into the block below
      # and the two labels overprinted. No DOM assertion could see that —
      # both elements are present and individually correct — so it survived
      # every green run until someone looked at a screenshot.
      #
      # The fix is to meet 44px with the ROW HEIGHT instead of overriding
      # the box: at 5.5rem an hour, the half-hour floor in
      # `CalendarWindow.place/4` lands on exactly 44px. Both bounds are
      # asserted because either one alone is satisfiable by the bug — "at
      # least 44px" passes with the CSS floor back, and "no more than its
      # slot" passes with rows too short to touch.
      today = grid_today()

      seed_grid_meeting(project,
        slug: "mob-short",
        name: "Short Meeting",
        scheduled_start_at: zoned_utc(today, 10, 0),
        scheduled_end_at: zoned_utc(today, 10, 30)
      )

      # A five-minute meeting too: the floor that the row height is sized
      # against is the placement's, so the smallest block a phone can draw
      # has to clear the target as well.
      seed_grid_meeting(project,
        slug: "mob-tiny",
        name: "Tiny Meeting",
        scheduled_start_at: zoned_utc(today, 14, 0),
        scheduled_end_at: zoned_utc(today, 14, 5)
      )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      window = {8, 18}

      for {height, minutes} <- [{5.0, 30}, {5.0, 5}] do
        drawn = PlatformWeb.MeetingLive.calendar_block_height_px(%{height: height}, window, :day)

        assert drawn >= @mobile_touch_target_px,
               "a #{minutes}-minute block draws #{drawn}px, under the #{@mobile_touch_target_px}px target"

        # And it is met by the slot, not by spilling out of it: the drawn
        # box is never taller than the share of the hour the placement gave
        # it. `place/4` floors a 5-minute meeting to a half hour, so its
        # share IS half an hour — the floor lives in the geometry, where a
        # lane split can see it, rather than in CSS, where nothing can.
        slot_px =
          max(minutes, 30) / 60 * PlatformWeb.MeetingLive.calendar_hour_row_rem(:day) * 16

        assert drawn <= slot_px,
               "a #{minutes}-minute block draws #{drawn}px into a #{slot_px}px slot"
      end

      # Structural half of the same claim: nothing may put the pixel floor
      # back on the box. The comparison above is arithmetic and cannot see
      # a CSS class.
      for class <- attrs_of(html, day_view(~s([data-role="calendar-event"])), "class") do
        refute Enum.any?(String.split(class), &String.starts_with?(&1, "min-h-")),
               "the day-view block carries a pixel height floor again: #{class}"
      end

      # Two lines fit at this row height, which is why the phone half needs
      # no compact variant where the week grid does.
      refute PlatformWeb.MeetingLive.calendar_compact_block?(%{height: 5.0}, window, :day)

      # The percentage geometry is still the truth about WHEN, and with
      # nothing to share the column with, the block spans it.
      assert "top:20.0%;height:5.0%;left:calc(0.0% + 0.375rem);width:calc(100.0% - 0.75rem)" in attrs_of(
               html,
               day_view(~s([data-role="calendar-event"])),
               "style"
             )
    end

    test "concurrent meetings take separate lanes in the day column and sequential ones do not",
         %{conn: conn, project: project} do
      # Two rows, one variable. Both pairs are two 30-minute meetings in the
      # same column; the only difference is whether their times coincide.
      # A test asserting merely that all four render would have passed
      # before this fix too — that is exactly the shape that let the defect
      # through.
      today = grid_today()

      concurrent_a =
        seed_grid_meeting(project,
          slug: "mob-lane-same-a",
          name: "Same Time A",
          scheduled_start_at: zoned_utc(today, 10, 0),
          scheduled_end_at: zoned_utc(today, 10, 30)
        )

      concurrent_b =
        seed_grid_meeting(project,
          slug: "mob-lane-same-b",
          name: "Same Time B",
          scheduled_start_at: zoned_utc(today, 10, 0),
          scheduled_end_at: zoned_utc(today, 10, 30)
        )

      sequential_a =
        seed_grid_meeting(project,
          slug: "mob-lane-seq-a",
          name: "Sequential A",
          scheduled_start_at: zoned_utc(today, 14, 0),
          scheduled_end_at: zoned_utc(today, 14, 30)
        )

      sequential_b =
        seed_grid_meeting(project,
          slug: "mob-lane-seq-b",
          name: "Sequential B",
          scheduled_start_at: zoned_utc(today, 14, 30),
          scheduled_end_at: zoned_utc(today, 15, 0)
        )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      # The concurrent pair: same vertical box, DIFFERENT horizontal one.
      assert lane_of(html, concurrent_a) == {"0", "2"}
      assert lane_of(html, concurrent_b) == {"1", "2"}
      refute block_style(html, concurrent_a) == block_style(html, concurrent_b)

      # The sequential pair: different vertical box, SAME horizontal one —
      # both full width, because 10:30 following 10:00 is not a conflict.
      assert lane_of(html, sequential_a) == {"0", "1"}
      assert lane_of(html, sequential_b) == {"0", "1"}

      assert horizontal_of(block_style(html, sequential_a)) ==
               horizontal_of(block_style(html, sequential_b))

      refute vertical_of(block_style(html, sequential_a)) ==
               vertical_of(block_style(html, sequential_b))

      # And the split really is a split: the two lanes are half a column
      # each, not two full-width boxes with different `left`s.
      assert horizontal_of(block_style(html, concurrent_a)) ==
               "left:calc(0.0% + 0.375rem);width:calc(50.0% - 0.75rem)"

      assert horizontal_of(block_style(html, concurrent_b)) ==
               "left:calc(50.0% + 0.375rem);width:calc(50.0% - 0.75rem)"
    end

    defp lane_of(html, meeting) do
      selector = day_view(~s([data-role="calendar-event"][data-meeting-id="#{meeting.id}"]))

      {
        html |> attrs_of(selector, "data-lane") |> List.first(),
        html |> attrs_of(selector, "data-lanes") |> List.first()
      }
    end

    defp block_style(html, meeting) do
      html
      |> attrs_of(
        day_view(~s([data-role="calendar-event"][data-meeting-id="#{meeting.id}"])),
        "style"
      )
      |> List.first()
    end

    defp vertical_of(style),
      do: style |> String.split(";") |> Enum.take(2) |> Enum.join(";")

    defp horizontal_of(style),
      do: style |> String.split(";") |> Enum.drop(2) |> Enum.join(";")

    test "the now-line is drawn for today and disappears when another day is selected",
         %{conn: conn, project: project} do
      # Anchored at the CURRENT local hour so the drawn window is
      # guaranteed to contain "now" whatever time this suite runs at.
      # Without it a 3 AM run draws no line at all and the first assertion
      # is vacuous in a way that looks green.
      today = grid_today()
      now = DateTime.now!(@grid_zone)

      seed_grid_meeting(project,
        slug: "mob-nowline-anchor",
        name: "Now Anchor",
        scheduled_start_at: zoned_utc(today, now.hour, 0),
        scheduled_end_at: zoned_utc(today, now.hour, 30)
      )

      {:ok, view, html} = live(grid_conn(conn), ~p"/meetings")

      assert attrs_of(html, day_view(~s([data-role="calendar-now-line"])), "data-role") ==
               ["calendar-now-line"]

      other_day = Enum.find(week_dates(today), &(Date.compare(&1, today) != :eq))
      html = click_strip_day(view, other_day)

      # Absent from the DAY VIEW, and still present on the desktop grid in
      # the same document — the line is a fact about today, and the grid
      # still draws today's column.
      assert attrs_of(html, day_view(~s([data-role="calendar-now-line"])), "data-role") == []

      assert attrs_of(html, in_grid(~s([data-role="calendar-now-line"])), "data-role") ==
               ["calendar-now-line"]
    end

    test "a selection naming a day outside the rendered week is ignored", %{conn: conn} do
      # The seven strip cells are the only thing that sends this event, so
      # an eighth date is not a request the UI can make. Honouring it would
      # select a day whose meetings were never queried — the week is loaded
      # per week — and draw a confidently empty column.
      {:ok, view, html} = live(grid_conn(conn), ~p"/meetings")

      today = Date.to_iso8601(grid_today())
      assert day_heading_date(html) == today

      next_week = Date.to_iso8601(Date.add(grid_today(), 7))
      html = render_click(view, "select_calendar_day", %{"date" => next_week})
      assert day_heading_date(html) == today

      html = render_click(view, "select_calendar_day", %{"date" => "not-a-date"})
      assert day_heading_date(html) == today
    end

    test "paging the week carries the selected day's weekday with it", %{conn: conn} do
      {:ok, view, html} = live(grid_conn(conn), ~p"/meetings")

      today = grid_today()
      target = Enum.find(week_dates(today), &(Date.compare(&1, today) != :eq))

      assert day_heading_date(html) == Date.to_iso8601(today)

      click_strip_day(view, target)
      html = view |> element(~s([phx-click="calendar_next_week"])) |> render_click()

      # A Wednesday stays a Wednesday: the selection keeps its offset in the
      # week rather than snapping back to Monday, and the strip's selected
      # cell agrees with the heading.
      expected = Date.to_iso8601(Date.add(target, 7))
      assert day_heading_date(html) == expected
      assert marked_strip_dates(html, "data-selected") == [expected]

      # Which SEVEN days, not in which order. Sorted deliberately: the
      # strip's ordering is pinned once, in "the strip is seven cells,
      # Monday first", and a second test reading the same ordered list
      # would die for that reason too — at which point neither failure
      # tells you which of the two behaviours broke. Found by detonating
      # the Sunday-first probe, which killed both tests before this line
      # was narrowed.
      assert Enum.sort(attrs_of(html, ~s([data-role="calendar-strip-day"]), "data-date")) ==
               Enum.sort(monday_first_week(Date.add(today, 7)))
    end
  end

  # ── Meeting detail panel + sheet (task 019fb954-8ead stage 4) ────────────
  #
  # The selection made in the grid or the day view has to become something
  # a reader can act on, and until this stage there was NO path from the
  # index to a meeting page at any width: the old grouped rows linked to
  # `/meetings/<slug>` and both calendar halves now select instead.
  # `data-role="meeting-detail-open"` is what restores it, which is why the
  # tests below care so much about whether it can scroll out of view.
  describe ":index action — meeting detail" do
    setup %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      Repo.delete_all(Meeting)
      project = create_project()
      {:ok, conn: conn, user: user, project: project}
    end

    # 2:00–3:00 PM local on the viewer's today, so the meeting is inside the
    # rendered week AND inside the default {8, 18} hour window whatever time
    # the suite runs at.
    defp seed_detail_meeting(project, opts \\ []) do
      today = grid_today()

      seed_grid_meeting(project,
        slug: Keyword.get(opts, :slug, "detail-meeting"),
        name: Keyword.get(opts, :name, "Detail Meeting"),
        status: Keyword.get(opts, :status, "scheduled"),
        scheduled_start_at: zoned_utc(today, Keyword.get(opts, :start_hour, 14), 0),
        scheduled_end_at: zoned_utc(today, Keyword.get(opts, :end_hour, 15), 0)
      )
    end

    # Both calendar halves render `data-role="calendar-event"` for the same
    # meeting — one contract, two surfaces — so an unscoped selector matches
    # two nodes and `element/2` refuses it. The grid's copy is the one
    # clicked here; the day view's carries the identical `phx-click`.
    defp select_meeting(view, meeting) do
      view
      |> element(in_grid(~s([data-role="calendar-event"][data-meeting-id="#{meeting.id}"])))
      |> render_click()
    end

    defp detail_panel(doc), do: LazyHTML.query(doc, ~s([data-role="meeting-detail-panel"]))
    defp detail_sheet(doc), do: LazyHTML.query(doc, ~s([data-role="meeting-detail-sheet"]))

    defp detail_text(node, selector),
      do: node |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

    @guest_window_seconds 24 * 60 * 60

    # A GUEST invite row written directly rather than through
    # `invite_guest/2`: that function also mints a token, creates a guest
    # chat space and runs delivery, and none of that is what these tests
    # are about. `revoked_at` is the one variable they vary.
    #
    # `expires_at` is not decoration. Until stage 5 of task 019fb955-1d7b
    # this fixture wrote `display_name` alone, which is a row shape NO
    # writer in the codebase produces — `invite_guest/2` always stamps an
    # expiry and `invite_external_user/3` always writes an email — and the
    # rendered surface refuses it by raising rather than guessing a tag.
    # The fixture was the thing that was wrong, so the fixture moved.
    defp seed_invite!(meeting, display_name, revoked_at \\ nil) do
      %Invite{}
      |> Invite.changeset(%{
        meeting_id: meeting.id,
        display_name: display_name,
        expires_at: DateTime.add(DateTime.utc_now(), @guest_window_seconds, :second),
        revoked_at: revoked_at
      })
      |> Repo.insert!()
    end

    test "neither the panel nor the sheet renders before a selection", %{
      conn: conn,
      project: project
    } do
      # The meeting EXISTS and is drawn — so this is "nothing is selected",
      # not "there was nothing to select", which would pass on a build that
      # never renders the detail surface at all.
      meeting = seed_detail_meeting(project)

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      assert attrs_of(html, in_grid(~s([data-role="calendar-event"])), "data-meeting-id") ==
               [meeting.id]

      assert attrs_of(html, ~s([data-role="meeting-detail-panel"]), "data-role") == []
      assert attrs_of(html, ~s([data-role="meeting-detail-sheet"]), "data-role") == []
    end

    test "clicking a calendar event opens both surfaces on that meeting", %{
      conn: conn,
      project: project
    } do
      meeting = seed_detail_meeting(project, name: "Quarterly Planning")

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      # Both surfaces, both naming the meeting. Asserted per-surface rather
      # than against the whole document: "Quarterly Planning" is also the
      # text of the grid block that was clicked, so a page-level `=~` is
      # satisfied by a build that renders neither.
      assert detail_text(detail_panel(doc), ~s([data-role="meeting-detail-name"])) ==
               "Quarterly Planning"

      assert detail_text(detail_sheet(doc), ~s([data-role="meeting-detail-name"])) ==
               "Quarterly Planning"

      # The same local time range on both, rendered server-side in the
      # VIEWER's zone — the one property that makes this string agree with
      # the column the block was clicked in.
      expected_when = MeetingDetail.when_label(meeting, @grid_zone)
      assert expected_when == "#{Calendar.strftime(grid_today(), "%a %b %-d")} · 2:00–3:00 PM"

      assert detail_text(detail_panel(doc), ~s([data-role="meeting-detail-when"])) ==
               expected_when

      assert detail_text(detail_sheet(doc), ~s([data-role="meeting-detail-when"])) ==
               expected_when

      # Status is carried, not guessed.
      assert detail_panel(doc)
             |> LazyHTML.query(~s([data-role="meeting-detail-status"]))
             |> LazyHTML.attribute("data-status") == ["scheduled"]

      # And the escape hatch back to the meeting page exists on both.
      assert detail_panel(doc)
             |> LazyHTML.query(~s([data-role="meeting-detail-open"]))
             |> LazyHTML.attribute("href") == ["/meetings/#{meeting.slug}"]

      assert detail_sheet(doc)
             |> LazyHTML.query(~s([data-role="meeting-detail-open"]))
             |> LazyHTML.attribute("href") == ["/meetings/#{meeting.slug}"]
    end

    # The stage text asks for the `.ics` href to be pinned by EQUALITY
    # against a second `CalendarLink.sign/1` call. That premise is false and
    # was checked rather than obeyed: `Plug.Crypto.sign/4` encodes a
    # `signed_at` MILLISECOND stamp into the payload, so two calls a
    # millisecond apart produce different tokens and the equality would be
    # flaky-by-construction.
    #
    # What replaces it is strictly stronger than the substring the stage
    # text was guarding against: the path is pinned by equality, `token` is
    # the ONLY query parameter (so a longer wrong query string fails), and
    # the token is required to VERIFY back to this meeting's id — which a
    # token for a different meeting, or a truncated one, does not.
    test "the calendar link names the meeting id and carries a token that verifies to it", %{
      conn: conn,
      project: project
    } do
      meeting = seed_detail_meeting(project)

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      [href] =
        detail_panel(doc)
        |> LazyHTML.query(~s([data-role="meeting-detail-ics"]))
        |> LazyHTML.attribute("href")

      # The sheet's link is the same link — one component, so it cannot drift.
      assert detail_sheet(doc)
             |> LazyHTML.query(~s([data-role="meeting-detail-ics"]))
             |> LazyHTML.attribute("href")
             |> length() == 1

      %URI{path: path, query: query} = URI.parse(href)
      assert path == "/meetings/#{meeting.id}/invite.ics"

      # Named before it is decoded, so a token-less href fails HERE with a
      # sentence rather than inside `URI.decode_query/1` with a
      # FunctionClauseError on nil — a crash proves nothing about the href.
      assert is_binary(query), "the .ics href carries no query string, so it carries no token"

      params = URI.decode_query(query)
      assert Map.keys(params) == ["token"]
      assert CalendarLink.verify(params["token"]) == {:ok, %{meeting_id: meeting.id}}
    end

    test "the rendered calendar link is fetchable and the same path without the token is not",
         %{conn: conn, project: project} do
      # The end-to-end version of the assertion above, and the one that says
      # the token is load-bearing rather than decorative: `show/2` answers a
      # uniform 404 for an absent token, so dropping `?token=` from the href
      # ships a link that is dead on arrival.
      meeting = seed_detail_meeting(project)

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      [href] =
        detail_panel(doc)
        |> LazyHTML.query(~s([data-role="meeting-detail-ics"]))
        |> LazyHTML.attribute("href")

      assert build_conn() |> get(href) |> response(200) =~ "BEGIN:VCALENDAR"
      assert build_conn() |> get("/meetings/#{meeting.id}/invite.ics") |> response(404)
    end

    # Stage 5 of task 019fb955-1d7b deleted the count CHIP this test used to
    # read. The chip counted `list_invites/2` while the list beneath it drew
    # the rendered rows, and the two legitimately differ — the producer agent
    # is a rendered row and is not a `meeting_invites` row — so one of the
    # two numbers had to go, and the canvas draws one. Re-pointed at the
    # surviving observable rather than deleted: the claim (a revoked invitee
    # is not an invitee) is unchanged and still worth pinning.
    defp invite_rows(surface),
      do: LazyHTML.query(surface, ~s([data-role="meeting-invite-row"]))

    defp list_header(surface) do
      surface
      |> LazyHTML.query(~s([data-role="meeting-invite-list-header"]))
      |> LazyHTML.text()
      |> String.trim()
    end

    test "a revoked invitee is neither counted nor drawn", %{
      conn: conn,
      project: project
    } do
      # Two rows, ONE variable. Both name the same meeting, both carry a
      # display name, and only `revoked_at` differs — so a failure here can
      # only be about whether a revoked invite is counted as invited.
      meeting = seed_detail_meeting(project)
      live_invite = seed_invite!(meeting, "Still Invited")
      revoked = seed_invite!(meeting, "Revoked Invitee", DateTime.utc_now())

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      for surface <- [detail_panel(doc), detail_sheet(doc)] do
        assert list_header(surface) == "Invited · 1"

        # Both sides asserted: the live row is drawn AND the revoked one is
        # not. A bare count of 1 is also satisfied by drawing the wrong row.
        assert surface |> invite_rows() |> LazyHTML.attribute("data-entry-id") ==
                 [live_invite.id]

        refute revoked.id in (surface |> invite_rows() |> LazyHTML.attribute("data-entry-id"))
      end
    end

    test "closing the detail removes both surfaces and leaves the anchor week alone", %{
      conn: conn,
      project: project
    } do
      # Deliberately NOT on the anchor the page opens at. "Leaves the week
      # alone" is unfalsifiable while the week IS this week: a handler that
      # snapped the anchor back to today would be indistinguishable from one
      # that touched nothing. Paging forward first makes the reset visible,
      # and the meeting is seeded a week out so there is something to select
      # once we are there.
      meeting =
        seed_grid_meeting(project,
          slug: "detail-next-week",
          name: "Next Week Meeting",
          scheduled_start_at: zoned_utc(Date.add(grid_today(), 7), 14, 0),
          scheduled_end_at: zoned_utc(Date.add(grid_today(), 7), 15, 0)
        )

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      html = view |> element(~s([phx-click="calendar_next_week"])) |> render_click()

      week_before = week_label(view)
      day_before = day_heading_date(html)
      refute week_before == PlatformWeb.MeetingLive.calendar_week_label(grid_today())

      html = select_meeting(view, meeting)

      assert attrs_of(html, ~s([data-role="meeting-detail-panel"]), "data-role") ==
               ["meeting-detail-panel"]

      # Selecting is not navigation: it must not page the week or move the
      # selected day out from under the reader.
      assert week_label(view) == week_before
      assert day_heading_date(html) == day_before

      html =
        view
        |> element(~s([data-role="meeting-detail-panel-close"]))
        |> render_click()

      assert attrs_of(html, ~s([data-role="meeting-detail-panel"]), "data-role") == []
      assert attrs_of(html, ~s([data-role="meeting-detail-sheet"]), "data-role") == []

      # …and closing is not navigation either.
      assert week_label(view) == week_before
      assert day_heading_date(html) == day_before
    end

    test "the FAB cannot collide with the desktop panel, because it is not drawn there", %{
      conn: conn,
      project: project
    } do
      # HISTORY, because the shape of this test changed with the defect it
      # guards. Stage 4 measured a real collision at 1440x900: the FAB is
      # anchored to the VIEWPORT's bottom-right, the panel is an opaque
      # 322px rail pinned to the same edge with its action row in that
      # corner, so the FAB painted over `meeting-detail-open`. Stage 4 fixed
      # it by sliding the FAB left by the panel's width while the panel was
      # open.
      #
      # Stage 5 makes the FAB `lg:hidden`. The panel is `hidden lg:flex`, so
      # it exists ONLY at `lg` and above — precisely where the FAB now
      # renders nothing. The two can no longer occupy a viewport together at
      # any width, so the offset was deleted rather than left in place: a
      # `lg:right-…` class on a `lg:hidden` element is a rule that can never
      # apply, and asserting its presence would have read as protection
      # while guarding a state that cannot be reached.
      #
      # So what is pinned here is the REPLACEMENT invariant, on the same
      # observable (the FAB's class list with the panel open): the FAB is
      # absent at the panel's breakpoint, and it carries NO horizontal
      # displacement — which is only safe BECAUSE it is absent. Re-adding
      # the offset without re-adding a reason fails here.
      meeting = seed_detail_meeting(project)

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")

      html = select_meeting(view, meeting)

      assert attrs_of(html, ~s([data-role="meeting-detail-panel"]), "data-role") ==
               ["meeting-detail-panel"]

      fab_classes =
        html |> attrs_of(~s([data-role="start-meeting-fab"]), "class") |> List.first()

      assert "lg:hidden" in String.split(fab_classes)
      refute fab_classes =~ ~r/(^| )(lg:)?right-\[calc\(20\.125rem/

      # Its horizontal anchor is the plain edge offset at EVERY width — no
      # panel-conditional variant survives.
      assert Enum.filter(String.split(fab_classes), &(&1 =~ ~r/right-/)) == ["right-6"]
    end

    test "the sheet's backdrop closes it", %{conn: conn, project: project} do
      meeting = seed_detail_meeting(project)

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      _ = select_meeting(view, meeting)

      html =
        view
        |> element(~s([data-role="meeting-detail-sheet-backdrop"]))
        |> render_click()

      assert attrs_of(html, ~s([data-role="meeting-detail-sheet"]), "data-role") == []
    end

    test "the sheet rises from the bottom edge and carries the frames' drag handle", %{
      conn: conn,
      project: project
    } do
      meeting = seed_detail_meeting(project)

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      sheet_classes = doc |> detail_sheet() |> class_of() |> String.split()

      # `items-end` is what makes this a bottom SHEET rather than a centred
      # modal: a thumb starts at the bottom edge of a phone, and the frames
      # draw it there. Both halves named — `items-center` present alongside
      # `items-end` would be the same defect with the pin still green.
      assert "items-end" in sheet_classes
      refute "items-center" in sheet_classes
      assert "fixed" in sheet_classes
      assert "inset-0" in sheet_classes

      assert doc
             |> detail_sheet()
             |> LazyHTML.query(~s([data-role="meeting-detail-sheet-handle"]))
             |> Enum.count() == 1

      # Out of flow, so the safe-area inset is the right clearance and the
      # in-flow bottom-nav reservation is not.
      panel_class =
        doc |> LazyHTML.query(~s([data-role="meeting-detail-sheet"] > div.relative)) |> class_of()

      assert panel_class =~ "pb-[env(safe-area-inset-bottom)]"
      refute panel_class =~ "--bottom-nav-height"
    end

    # ── The rejected geometry, in a second place ──────────────────────────
    #
    # The sponsor rejected the create sheet for exactly this: the panel was
    # one scroll region, so a long staged-invite list carried the primary
    # action off the bottom of the modal. This surface is the SAME shape and
    # the create+invite member's next stage fills its body with per-invitee
    # rows, so the content grows without bound here too.
    #
    # Asserting the action row is PRESENT cannot see the defect — it was
    # present the whole time, just out of view — so what is asserted is the
    # structure that makes it impossible: the surface caps and CLIPS,
    # exactly one descendant scrolls, and the action row is not inside it.
    # That property holds at any content length, which is why it is
    # preferable to any assertion about a particular one.
    defp detail_scrollers(node),
      do: node |> LazyHTML.query("*") |> Enum.filter(&(&1 |> class_of() |> scrolls?()))

    test "each detail surface clips, scrolls in one place, and pins its action row", %{
      conn: conn,
      project: project
    } do
      meeting = seed_detail_meeting(project)

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      # The panel is the element itself; the sheet's cap lives on the panel
      # INSIDE the fixed backdrop wrapper, so each names its own host.
      surfaces = [
        {"panel", detail_panel(doc), "meeting-detail-panel-body"},
        {"sheet", LazyHTML.query(doc, ~s([data-role="meeting-detail-sheet"] > div.relative)),
         "meeting-detail-sheet-body"}
      ]

      for {name, surface, body_role} <- surfaces do
        surface_class = class_of(surface)

        assert surface_class =~ "flex", "the #{name} is not a flex container"
        assert surface_class =~ "flex-col", "the #{name} is not a flex COLUMN"

        refute scrolls?(surface_class),
               "the #{name} itself scrolls (#{surface_class}) — its action row scrolls away " <>
                 "with the body, which is the geometry the sponsor rejected"

        # `LazyHTML.query(node, "*")` INCLUDES the node it is rooted at, so a
        # surface that scrolled would be counted here rather than skipped.
        assert [body] = detail_scrollers(surface),
               "expected exactly one scrolling region in the #{name}, found " <>
                 "#{length(detail_scrollers(surface))}"

        assert LazyHTML.attribute(body, "data-role") == [body_role]

        # `min-h-0` is the load-bearing bit: a flex child defaults to
        # `min-height: auto` and refuses to shrink below its content, so
        # without it the body never scrolls and the action row is pushed out
        # of the surface even though the surface is a flex column.
        body_class = class_of(body)
        assert body_class =~ "min-h-0", "the #{name}'s body can grow past the surface's cap"
        assert body_class =~ "flex-1", "the #{name}'s body does not take the free space"

        # The action row renders exactly once per surface …
        assert surface |> LazyHTML.query(~s([data-role="meeting-detail-open"])) |> Enum.count() ==
                 1

        # … and NOT from inside the region that scrolls away.
        assert body |> LazyHTML.query(~s([data-role="meeting-detail-open"])) |> Enum.count() == 0,
               "meeting-detail-open is inside the #{name}'s scrolling body — enough invitee " <>
                 "rows push it out of view"

        # …while the content that GROWS is inside it, without which the two
        # assertions above hold trivially on a surface whose body is empty.
        assert body
               |> LazyHTML.query(~s([data-role="meeting-detail-body-content"]))
               |> Enum.count() == 1
      end
    end

    test "a long invite list does not move the action row into the scrolling region", %{
      conn: conn,
      project: project
    } do
      # The COUNT is the variable, not the kind — that is the specification
      # error that let the rejected defect through the first time. Twelve
      # live invitees is well past the point where the per-invitee rows the
      # next stage adds would overflow a 75vh sheet.
      meeting = seed_detail_meeting(project)
      for index <- 1..12, do: seed_invite!(meeting, "Invitee #{index}")

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      for surface <- [
            detail_panel(doc),
            LazyHTML.query(doc, ~s([data-role="meeting-detail-sheet"] > div.relative))
          ] do
        assert [body] = detail_scrollers(surface)

        # The twelve rows are the growing content, and they are INSIDE the
        # region that scrolls. Counted on the body rather than the surface:
        # rows rendered between the body and the action row would satisfy a
        # surface-level count while re-creating the exact defect.
        assert body |> invite_rows() |> Enum.count() == 12

        assert surface |> LazyHTML.query(~s([data-role="meeting-detail-open"])) |> Enum.count() ==
                 1

        assert body |> LazyHTML.query(~s([data-role="meeting-detail-open"])) |> Enum.count() == 0
      end
    end

    # ── The invitee list (task 019fb955-1d7b stage 5) ────────────────────
    #
    # Rows are written directly rather than through `invite_guest/2` /
    # `invite_user/3` for the same reason the count fixtures above are:
    # those functions also mint tokens, create guest chat spaces and run
    # delivery, and none of that is what the RENDERING is about. What the
    # panel reads off a row is `user_id`, `email`, `expires_at` and the
    # invitee's org membership, so those are what the fixtures vary — one
    # variable per kind.
    #
    # The guest link is derived from the row rather than stored on it, so
    # seeding the row directly is also the only way to assert the derivation
    # rather than re-reading whatever `invite_guest/2` happened to return.

    defp seed_user_invite!(meeting, user) do
      %Invite{}
      |> Invite.changeset(%{meeting_id: meeting.id, user_id: user.id})
      |> Repo.insert!()
    end

    # `user_id` NULL, an `email`, and NO expiry — the interim row
    # `invite_external_user/3` writes for an address with no account yet.
    # `Invite.kind/1` calls this `:guest`; the panel must not.
    defp seed_external_pending_invite!(meeting, email) do
      %Invite{}
      |> Invite.changeset(%{meeting_id: meeting.id, display_name: email, email: email})
      |> Repo.insert!()
    end

    defp seed_invitee_user!(name, opts \\ []) do
      user =
        Repo.insert!(%User{
          email: "invitee_#{System.unique_integer([:positive])}@example.com",
          name: name,
          oidc_sub: "oidc-invitee-#{System.unique_integer([:positive])}"
        })

      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user.id,
        org_id: Platform.TenancyFixtures.fabrikam_org_id(),
        role: "member",
        external: Keyword.get(opts, :external, false)
      })
      |> Repo.insert!()

      user
    end

    defp copy_controls(surface),
      do: LazyHTML.query(surface, ~s([data-role="meeting-invite-copy"]))

    # The token is the last path segment of the guest URL. Written to
    # survive a URL that is not a guest URL at all — the prescribed mutant
    # emits `meeting.slug` here — so that a mutation fails on the token
    # COMPARISON below rather than crashing in this helper, which would
    # prove nothing about distinctness.
    defp guest_token(url) do
      %URI{path: path} = URI.parse(url)

      path |> to_string() |> String.split("/") |> List.last()
    end

    test "the list draws one row per live invite, in `list_invites/2`'s order", %{
      conn: conn,
      project: project
    } do
      meeting = seed_detail_meeting(project)

      # Seeded in a deliberate order and asserted against the CONTEXT's
      # ordering rather than against the literal insertion sequence: the
      # claim is that the panel does not re-sort, and re-deriving the
      # expectation here would let both drift together.
      seed_invite!(meeting, "Sam Ortiz")
      seed_user_invite!(meeting, seed_invitee_user!("Dalton Reyes"))
      seed_external_pending_invite!(meeting, "jane@doeco.example")
      seed_invite!(meeting, "Jess Tran")

      expected = Enum.map(Meetings.list_invites(meeting.id), & &1.id)
      assert length(expected) == 4

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      for surface <- [detail_panel(doc), detail_sheet(doc)] do
        assert surface |> invite_rows() |> LazyHTML.attribute("data-entry-id") == expected
        assert list_header(surface) == "Invited · 4"
      end
    end

    test "each kind gets the tag the canvas draws, not `Invite.kind/1`'s two", %{
      conn: conn,
      project: project
    } do
      # The one place the stored model and the rendered model disagree.
      # `Invite.kind/1` answers `:guest` for BOTH rows with a NULL
      # `user_id` — the guest and the external-pending — and `:user` for
      # both rows with one, so it cannot tell any of these four apart.
      meeting = seed_detail_meeting(project)

      internal = seed_user_invite!(meeting, seed_invitee_user!("Dalton Reyes"))
      external = seed_user_invite!(meeting, seed_invitee_user!("Jane Doe", external: true))
      guest = seed_invite!(meeting, "Sam Ortiz")
      pending = seed_external_pending_invite!(meeting, "jess@doeco.example")

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      tag = fn surface, invite ->
        surface
        |> LazyHTML.query(~s([data-role="meeting-invite-row"][data-entry-id="#{invite.id}"]))
        |> LazyHTML.query(~s([data-role="meeting-invite-tag"]))
        |> LazyHTML.text()
        |> String.trim()
      end

      subtitle = fn surface, invite ->
        surface
        |> LazyHTML.query(~s([data-role="meeting-invite-row"][data-entry-id="#{invite.id}"]))
        |> LazyHTML.query(~s([data-role="meeting-invite-row-subtitle"]))
        |> LazyHTML.text()
        |> String.trim()
      end

      for surface <- [detail_panel(doc), detail_sheet(doc)] do
        assert tag.(surface, internal) == "internal"
        assert tag.(surface, external) == "external"
        assert tag.(surface, guest) == "guest"

        # The row `kind/1` gets wrong. Pinned by equality, because
        # `=~ "external"` is satisfied by the word appearing anywhere in
        # the row — including in the address the subtitle prints.
        assert tag.(surface, pending) == "external"

        # STATE, one line, never explanation. An internal member's name is
        # the whole fact, so their row carries no sub-line at all —
        # asserted as the empty string rather than skipped, because "no
        # subtitle" is a decision and not an absence of one.
        assert subtitle.(surface, internal) == ""
        assert subtitle.(surface, external) == Repo.get!(User, external.user_id).email
        assert subtitle.(surface, guest) == "expires in 24h"
        assert subtitle.(surface, pending) == "jess@doeco.example"
      end
    end

    test "two guests get two rows carrying two DISTINCT personal links", %{
      conn: conn,
      project: project
    } do
      # The regression this whole task exists for. A meeting-wide link
      # handed out twice renders two copy controls too, so "two controls
      # exist" is not the claim — "the two admit different people" is.
      meeting = seed_detail_meeting(project)
      sam = seed_invite!(meeting, "Sam Ortiz")
      jess = seed_invite!(meeting, "Jess Tran")

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      for surface <- [detail_panel(doc), detail_sheet(doc)] do
        assert [sam_url, jess_url] =
                 surface |> copy_controls() |> LazyHTML.attribute("data-clipboard-text")

        # Which control belongs to whom, before anything is decoded — so a
        # build that rendered both links on one row fails here rather than
        # further down with a confusing message.
        assert surface |> copy_controls() |> LazyHTML.attribute("data-entry-id") ==
                 [sam.id, jess.id]

        sam_token = guest_token(sam_url)
        jess_token = guest_token(jess_url)

        # THE assertion. Not "both are present" — different.
        refute sam_token == jess_token,
               "both guests were handed the same token, which is a meeting-wide link"

        # And each token is not merely different, it is THEIRS.
        # `verify/1` rather than equality against a freshly signed token:
        # `Plug.Crypto.sign/4` stamps a millisecond `signed_at`, so two
        # signatures of the same payload differ and an equality assertion
        # would be flaky by construction. The round trip is deterministic
        # and strictly stronger — it pins what the token MEANS.
        assert {:ok, sam_payload} = GuestInvite.verify(sam_token)
        assert {:ok, jess_payload} = GuestInvite.verify(jess_token)

        assert sam_payload.invite_id == sam.id
        assert jess_payload.invite_id == jess.id
        refute sam_payload.invite_id == jess_payload.invite_id

        # The token names its meeting exactly — a slug alone is unique per
        # project only, which is why `meeting_id` is on the payload.
        assert sam_payload.meeting_id == meeting.id
        assert sam_payload.meeting_slug == meeting.slug
        assert sam_payload.display_name == "Sam Ortiz"

        # Path shape pinned by equality, and the whole path: a link with the
        # right token under the wrong route admits nobody.
        assert %URI{path: path, query: nil} = URI.parse(sam_url)
        assert path == "/#{meeting.slug}/#{sam_token}"
      end
    end

    test "a re-minted link still dies with the row it names", %{conn: conn, project: project} do
      # The panel derives the link from the row rather than reading a stored
      # token, so the string a host copies today is not byte-identical to the
      # one `invite_guest/2` returned. This is what makes that safe: the row
      # is the revocation surface, and revoking it kills the derived link
      # too. Without this, re-minting would be a way to hand out a
      # capability that was deliberately withdrawn.
      meeting = seed_detail_meeting(project)
      sam = seed_invite!(meeting, "Sam Ortiz")

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      [url] =
        doc |> detail_panel() |> copy_controls() |> LazyHTML.attribute("data-clipboard-text")

      token = guest_token(url)

      # Live before, dead after — one variable, and the link is the same
      # string on both sides of it.
      assert {:ok, %{state: :in_meeting, display_name: "Sam Ortiz"}} =
               Meetings.resolve_guest_invite(meeting.slug, token)

      {:ok, _revoked} = Meetings.revoke_invite(sam)

      assert Meetings.resolve_guest_invite(meeting.slug, token) == {:error, :revoked}
    end

    test "only guest rows carry a copy control, and it is a 44px target", %{
      conn: conn,
      project: project
    } do
      # An account-holder signs in as themselves and an external invite
      # awaiting a grant has no token at all, so a copy control on either
      # would copy something that cannot admit anyone.
      meeting = seed_detail_meeting(project)
      seed_user_invite!(meeting, seed_invitee_user!("Dalton Reyes"))
      seed_external_pending_invite!(meeting, "jane@doeco.example")
      guest = seed_invite!(meeting, "Sam Ortiz")

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      for surface <- [detail_panel(doc), detail_sheet(doc)] do
        assert surface |> invite_rows() |> Enum.count() == 3
        assert surface |> copy_controls() |> LazyHTML.attribute("data-entry-id") == [guest.id]

        # A real BUTTON at 375px, not a chip: both axes, because the label
        # makes the horizontal one look satisfied while a shorter label
        # would not be.
        control = copy_controls(surface)
        assert LazyHTML.attribute(control, "type") == ["button"]

        control_class = class_of(control)
        assert control_class =~ "min-h-11"
        assert control_class =~ "min-w-11"

        # Wired to the ONE clipboard hook that already exists, reading the
        # attribute that hook reads.
        assert LazyHTML.attribute(control, "phx-hook") == ["CopyToClipboard"]
      end
    end

    test "the panel and the sheet do not share the copy control's DOM id", %{
      conn: conn,
      project: project
    } do
      # Both surfaces render simultaneously — one is hidden by CSS, not by
      # absence — and LiveView keys `phx-hook` by DOM id. Two elements
      # sharing one id means one hook never mounts, and that button then
      # copies nothing while looking identical to the working one.
      meeting = seed_detail_meeting(project)
      seed_invite!(meeting, "Sam Ortiz")

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      ids = doc |> copy_controls() |> LazyHTML.attribute("id")

      assert length(ids) == 2, "expected one copy control per surface"
      assert ids == Enum.uniq(ids)
    end

    test "the producer agent row renders when the sender agent is seeded", %{
      conn: conn,
      project: project
    } do
      # `config/test.exs` sets `meetings_enabled: false`, so the boot-time
      # seed does not run and `SenderSeed.get/0` is nil for the whole suite
      # unless a test asks for it. That makes the two states genuinely
      # independent rather than a flag flipped in one direction.
      meeting = seed_detail_meeting(project)
      seed_invite!(meeting, "Sam Ortiz")

      {:ok, agent} = SenderSeed.ensure!()

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      for surface <- [detail_panel(doc), detail_sheet(doc)] do
        row =
          LazyHTML.query(
            surface,
            ~s([data-role="meeting-invite-row"][data-entry-id="agent:#{agent.id}"])
          )

        assert LazyHTML.attribute(row, "data-tag") == ["agent"]

        assert row
               |> LazyHTML.query(~s([data-role="meeting-invite-row-subtitle"]))
               |> LazyHTML.text()
               |> String.trim() == "meeting producer"

        # Display-only: no remove control and no copy control, and it is
        # counted in the header alongside the invite it sits under.
        assert row |> LazyHTML.query(~s([data-role="meeting-invite-copy"])) |> Enum.count() == 0

        assert row |> LazyHTML.query(~s([data-role="meeting-invite-unstage"])) |> Enum.count() ==
                 0

        assert list_header(surface) == "Invited · 2"
      end
    end

    test "the producer agent row is OMITTED when the sender agent is not seeded", %{
      conn: conn,
      project: project
    } do
      # The expected state wherever the meetings subsystem was never
      # enabled. No placeholder: a synthesised row would name an agent that
      # does not exist and cannot be messaged.
      meeting = seed_detail_meeting(project)
      seed_invite!(meeting, "Sam Ortiz")

      assert SenderSeed.get() == nil

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      for surface <- [detail_panel(doc), detail_sheet(doc)] do
        assert surface |> invite_rows() |> Enum.count() == 1
        assert surface |> invite_rows() |> LazyHTML.attribute("data-tag") == ["guest"]
        assert list_header(surface) == "Invited · 1"
      end
    end

    test "there is no revoke control on any row, at either width", %{
      conn: conn,
      project: project
    } do
      # Not an omission. `recipients_for_meeting/1` falls back to the chat
      # space's participants when the live invite list is EMPTY, so revoking
      # the last invitee WIDENS the notified audience instead of narrowing
      # it; and guests carry no `user_id`, so a guest-only list silences
      # every human. Both need a sponsor ruling, and shipping the control
      # first ships the widening.
      meeting = seed_detail_meeting(project)
      seed_invite!(meeting, "Sam Ortiz")
      seed_user_invite!(meeting, seed_invitee_user!("Dalton Reyes"))

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      for surface <- [detail_panel(doc), detail_sheet(doc)] do
        assert surface |> invite_rows() |> Enum.count() == 2

        assert surface |> LazyHTML.query(~s([data-role="meeting-invite-unstage"])) |> Enum.count() ==
                 0

        assert surface |> LazyHTML.query("[phx-click='meeting_invite_revoke']") |> Enum.count() ==
                 0
      end
    end

    test "`Add people` is the only invite affordance, and it writes a real row", %{
      conn: conn,
      project: project
    } do
      meeting = seed_detail_meeting(project)

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      doc = view |> select_meeting(meeting) |> LazyHTML.from_fragment()

      # There is deliberately no invite button in any toolbar: the row at
      # the end of the list is the whole affordance.
      assert doc |> LazyHTML.query(~s([data-role="meeting-invite-add-people"])) |> Enum.count() ==
               2

      # Closed until asked for.
      assert doc
             |> LazyHTML.query(~s([data-role="meeting-detail-invite-expansion"]))
             |> Enum.count() == 0

      doc =
        view
        |> element(in_panel(~s([data-role="meeting-invite-add-people"])))
        |> render_click()
        |> LazyHTML.from_fragment()

      assert doc
             |> LazyHTML.query(~s([data-role="meeting-detail-invite-expansion"]))
             |> Enum.count() == 2

      view
      |> element(in_panel(~s([data-role="meeting-invite-search"])))
      |> render_keyup(%{"value" => "newguest@doeco.example"})

      doc =
        view
        |> element(in_panel(~s([data-role="meeting-invite-option"][data-option="guest"])))
        |> render_click()
        |> LazyHTML.from_fragment()

      # `:live` means WRITTEN, not staged — there is no submit to lose it
      # at, so the assertion is against the database as well as the DOM.
      assert [%Invite{} = invite] = Meetings.list_invites(meeting.id)
      assert invite.display_name == "newguest@doeco.example"

      for surface <- [detail_panel(doc), detail_sheet(doc)] do
        assert surface |> invite_rows() |> LazyHTML.attribute("data-entry-id") == [invite.id]
        assert surface |> invite_rows() |> LazyHTML.attribute("data-tag") == ["guest"]

        # …with its own link, minted for the row that was just written.
        assert [url] = surface |> copy_controls() |> LazyHTML.attribute("data-clipboard-text")
        assert {:ok, payload} = GuestInvite.verify(guest_token(url))
        assert payload.invite_id == invite.id
      end
    end

    test "the detail surface's dropdown is IN FLOW, so its second option is reachable", %{
      conn: conn,
      project: project
    } do
      # Measured, not guessed. At 1440x900 with the panel's body scrolled
      # fully down, the create sheet's FLOATING dropdown was clipped by the
      # panel's `overflow-hidden` cap and its second option — `Invite as an
      # external member` — could not be reached at any scroll position:
      # absolute positioning takes it out of the flow the scroll height is
      # computed from. A fork with one reachable prong is not a fork.
      #
      # Pinned on a `data-` attribute rather than on the class list, per
      # this component's DOM contract — a class reshuffle must not be able
      # to break a test, and the attribute is what the position MEANS.
      meeting = seed_detail_meeting(project)

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      _ = select_meeting(view, meeting)

      view |> element(in_panel(~s([data-role="meeting-invite-add-people"]))) |> render_click()

      doc =
        view
        |> element(in_panel(~s([data-role="meeting-invite-search"])))
        |> render_keyup(%{"value" => "stranger@doeco.example"})
        |> LazyHTML.from_fragment()

      dropdowns = LazyHTML.query(doc, ~s([data-role="meeting-invite-dropdown"]))

      # Both options are rendered — the claim is about reaching the second,
      # so a build that never drew it would pass a position assertion alone.
      assert dropdowns |> LazyHTML.query(~s([data-role="meeting-invite-option"])) |> Enum.count() ==
               4

      assert LazyHTML.attribute(dropdowns, "data-dropdown-position") == ["inline", "inline"]

      # …and the create sheet, which has room to float over its own body,
      # still does. Asserted here so "inline everywhere" — which would be
      # the same edit with no measurement behind it — fails.
      {:ok, create_view, _} = live(grid_conn(conn), ~p"/meetings")
      create_view |> element(~s([data-role="start-meeting-fab"])) |> render_click()

      create_doc =
        create_view
        |> element(
          ~s([data-role="meeting-create-invite-section"] [data-role="meeting-invite-search"])
        )
        |> render_keyup(%{"value" => "stranger@doeco.example"})
        |> LazyHTML.from_fragment()

      assert create_doc
             |> LazyHTML.query(~s([data-role="meeting-invite-dropdown"]))
             |> LazyHTML.attribute("data-dropdown-position") == ["floating"]
    end

    test "changing the selection closes the invite control", %{conn: conn, project: project} do
      # It is scoped to ONE meeting. Left open across a change of selection
      # it would be a search box under a different meeting's list, and the
      # next thing chosen in it would be written to that meeting.
      first = seed_detail_meeting(project, slug: "detail-first", name: "First")

      second =
        seed_detail_meeting(project,
          slug: "detail-second",
          name: "Second",
          start_hour: 16,
          end_hour: 17
        )

      {:ok, view, _html} = live(grid_conn(conn), ~p"/meetings")
      _ = select_meeting(view, first)

      html =
        view |> element(in_panel(~s([data-role="meeting-invite-add-people"]))) |> render_click()

      assert attrs_of(html, ~s([data-role="meeting-detail-invite-expansion"]), "data-role") ==
               ["meeting-detail-invite-expansion", "meeting-detail-invite-expansion"]

      html = select_meeting(view, second)

      assert attrs_of(html, ~s([data-role="meeting-detail-invite-expansion"]), "data-role") == []
    end

    defp in_panel(selector), do: ~s([data-role="meeting-detail-panel"] #{selector})
  end

  describe "MeetingLive.guest_expiry_label/1" do
    # Spans chosen OFF the boundaries. `expires_at` is compared against
    # `DateTime.utc_now()` at call time, so a fixture seeded at exactly
    # 3600s reads back as 3599 and lands in the neighbouring branch — an
    # assertion pinned to an edge would be flaky by construction. Each
    # value here is far enough from its edge that elapsed test time cannot
    # move it.
    defp in_seconds(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

    test "a freshly minted 24h link says 24h, not 23h" do
      # The whole reason this rounds rather than truncates. `invite_guest/2`
      # stamps `now + 24h`; by the time it renders the span is 23h59m59s,
      # and truncation would tell the host an hour they still have is gone.
      assert PlatformWeb.MeetingLive.guest_expiry_label(in_seconds(24 * 3600)) ==
               "expires in 24h"
    end

    test "whole hours in between" do
      assert PlatformWeb.MeetingLive.guest_expiry_label(in_seconds(2 * 3600 + 60)) ==
               "expires in 2h"
    end

    test "a sub-hour span never claims an hour" do
      # Rounding UP is the direction that misleads — a link with four
      # minutes left must not read as having an hour — so a sub-hour span
      # does not go through the hours form at all.
      assert PlatformWeb.MeetingLive.guest_expiry_label(in_seconds(1800)) == "expires in <1h"
    end

    test "a past-due link says so rather than rendering as live" do
      # Reachable: `list_invites/2` filters revoked rows and NOT expired
      # ones, so an aged-out guest still draws a row.
      assert PlatformWeb.MeetingLive.guest_expiry_label(in_seconds(-60)) == "expired"
    end
  end

  describe "MeetingDetail.when_label/2" do
    # Pinned with `==` rather than `=~` throughout: `=~ "2:00"` is satisfied
    # by "12:00", by "2:001" and by a string that merely contains it.
    test "a range inside one meridiem prints the meridiem once" do
      meeting = %Meeting{
        scheduled_start_at: ~U[2026-08-05 19:00:00.000000Z],
        scheduled_end_at: ~U[2026-08-05 20:00:00.000000Z]
      }

      assert MeetingDetail.when_label(meeting, "America/Chicago") == "Wed Aug 5 · 2:00–3:00 PM"
    end

    test "a range crossing noon prints both meridiems" do
      meeting = %Meeting{
        scheduled_start_at: ~U[2026-08-05 16:30:00.000000Z],
        scheduled_end_at: ~U[2026-08-05 17:30:00.000000Z]
      }

      assert MeetingDetail.when_label(meeting, "America/Chicago") ==
               "Wed Aug 5 · 11:30 AM–12:30 PM"
    end

    test "the label is the VIEWER's local day, not the stored UTC one" do
      # 01:30 UTC on the 6th is 8:30 PM on the 5th in Chicago. A label built
      # from the stored instant would name Thu Aug 6 while the block sits in
      # Wednesday's column.
      meeting = %Meeting{
        scheduled_start_at: ~U[2026-08-06 01:30:00.000000Z],
        scheduled_end_at: ~U[2026-08-06 02:30:00.000000Z]
      }

      assert MeetingDetail.when_label(meeting, "America/Chicago") == "Wed Aug 5 · 8:30–9:30 PM"
      assert MeetingDetail.when_label(meeting, "Etc/UTC") == "Thu Aug 6 · 1:30–2:30 AM"
    end

    test "an unresolved zone raises rather than rendering server time as the viewer's" do
      meeting = %Meeting{
        scheduled_start_at: ~U[2026-08-05 19:00:00.000000Z],
        scheduled_end_at: ~U[2026-08-05 20:00:00.000000Z]
      }

      assert_raise FunctionClauseError, fn -> MeetingDetail.when_label(meeting, nil) end
    end
  end

  describe "calendar_week_label/1" do
    # An en dash (U+2013), the typographic range mark, and the year printed
    # exactly once for every week that stays inside one. Pinned with `==`
    # rather than `=~`: `=~ "Aug 3"` is satisfied by "Aug 3 - 9, 2026" with a
    # hyphen, by "Aug 3, 2026 - Aug 9, 2026", and by a longer string that
    # merely contains the short one.
    test "a week inside one month names the month and the year once" do
      assert PlatformWeb.MeetingLive.calendar_week_label(~D[2026-08-05]) == "Aug 3 – 9, 2026"
    end

    test "a week straddling two months names both months and the year once" do
      assert PlatformWeb.MeetingLive.calendar_week_label(~D[2026-09-02]) ==
               "Aug 31 – Sep 6, 2026"
    end

    test "a week straddling two years names both years" do
      assert PlatformWeb.MeetingLive.calendar_week_label(~D[2025-12-31]) ==
               "Dec 29, 2025 – Jan 4, 2026"
    end
  end

  describe "calendar_hour_label/1" do
    test "noon and midnight read as 12, not as 0" do
      assert PlatformWeb.MeetingLive.calendar_hour_label(0) == "12 AM"
      assert PlatformWeb.MeetingLive.calendar_hour_label(12) == "12 PM"
    end

    test "morning and afternoon hours carry their meridiem" do
      assert PlatformWeb.MeetingLive.calendar_hour_label(8) == "8 AM"
      assert PlatformWeb.MeetingLive.calendar_hour_label(13) == "1 PM"
      assert PlatformWeb.MeetingLive.calendar_hour_label(23) == "11 PM"
    end
  end

  # ── Start-meeting FAB + bottom-sheet (stage 2 of task 019e2ca8) ──────────

  describe ":index action — Start-meeting FAB" do
    setup %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      Repo.delete_all(Meeting)
      project = create_project()
      {:ok, conn: conn, user: user, project: project}
    end

    test "FAB renders on /meetings (index action) with hero-video-camera icon", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings")

      assert html =~ ~s(data-role="start-meeting-fab")
      assert html =~ ~s(phx-click="open_start_meeting_sheet")
      # Uses the same hero icon as the sidebar nav meeting glyph for
      # visual consistency.
      assert html =~ "hero-video-camera"
      # Mobile reachability: safe-area-inset-bottom offset *and*
      # bottom-nav-height clearance so the FAB never sits behind the
      # mobile bottom nav (mirrors tasks_live FAB pattern).
      assert html =~
               "bottom-[calc(env(safe-area-inset-bottom)+1.5rem+var(--bottom-nav-height,0px))]"

      # Bottom-right placement, primary daisyUI variant, circular.
      assert html =~ "btn-primary"
      assert html =~ "btn-circle"
      assert html =~ "right-6"
    end

    test "FAB does NOT render on /meetings/:slug (show action)", %{
      conn: conn
    } do
      {meeting, _space} =
        create_meeting(%{slug: "no-fab-on-show", name: "No FAB Here"})

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      refute html =~ ~s(data-role="start-meeting-fab")
    end

    test "clicking the FAB opens the start-meeting sheet", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/meetings")

      # Sheet is closed by default.
      refute html =~ ~s(data-role="start-meeting-sheet")

      open_html =
        view
        |> element(~s([data-role="start-meeting-fab"]))
        |> render_click()

      assert open_html =~ ~s(data-role="start-meeting-sheet")

      # The TITLE ELEMENT, not the document. `assert open_html =~ "New
      # meeting"` would also be satisfied by the FAB's own label, which is
      # rendered on the same page and is not what this asserts.
      assert open_html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#start-meeting-sheet-title")
             |> LazyHTML.text()
             |> String.trim() == "New meeting"

      assert open_html =~ ~s(name="start_meeting[name]")
      assert open_html =~ ~s(name="start_meeting[project_id]")
    end

    test "the desktop New meeting button renders and opens the SAME sheet", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/meetings")

      doc = LazyHTML.from_fragment(html)
      button = LazyHTML.query(doc, ~s([data-role="new-meeting-button"]))

      assert Enum.count(button) == 1

      # The glyph the toolbar frame draws — a hero icon, not a typographic
      # `+`, so it inherits the icon sizing the rest of the header uses.
      assert button |> LazyHTML.query("span") |> class_of() =~ "hero-plus"
      assert button |> LazyHTML.text() |> String.trim() == "New meeting"

      refute html =~ ~s(data-role="start-meeting-sheet")

      open_html =
        view
        |> element(~s([data-role="new-meeting-button"]))
        |> render_click()

      # The point of this test: ONE sheet, reached from a second entry
      # point. A button wired to its own handler and its own duplicate sheet
      # would satisfy "a sheet opened" — so this asserts the sheet the FAB
      # opens, by the id the FAB's own test keys on, and asserts there is
      # exactly one of it.
      assert open_html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-role="start-meeting-sheet"]))
             |> Enum.count() == 1

      assert open_html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#start-meeting-sheet-title")
             |> LazyHTML.text()
             |> String.trim() == "New meeting"
    end

    test "close button + backdrop dismiss the sheet", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/meetings")

      # Open via FAB.
      _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()
      assert render(view) =~ ~s(data-role="start-meeting-sheet")

      # Close via close-button.
      closed_html =
        view
        |> element(~s([data-role="start-meeting-sheet-close"]))
        |> render_click()

      refute closed_html =~ ~s(data-role="start-meeting-sheet")

      # Re-open and dismiss via backdrop.
      _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()
      assert render(view) =~ ~s(data-role="start-meeting-sheet")

      backdrop_closed =
        view
        |> element(~s([data-role="start-meeting-sheet-backdrop"]))
        |> render_click()

      refute backdrop_closed =~ ~s(data-role="start-meeting-sheet")
    end

    test "submitting a name and a project creates a meeting", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings")

      _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()

      view
      |> form("#start-meeting-form",
        start_meeting: %{"name" => "Synthesis Sync", "project_id" => project.id}
      )
      |> render_submit()

      # Deliberately does NOT look at what render_submit returned. Whether
      # a success redirects is the next describe's claim, and borrowing its
      # observable here would make this test die for that reason too.
      assert [%Meeting{name: "Synthesis Sync"}] = Repo.all(Meeting)
    end

    test "submitting with a blank name shows an inline error and keeps the sheet open", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings")

      _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()

      html =
        view
        |> form("#start-meeting-form",
          start_meeting: %{"name" => "", "project_id" => project.id}
        )
        |> render_submit()

      # No meeting was created.
      assert Repo.all(Meeting) == []

      # Sheet stays open and the inline error renders.
      assert html =~ ~s(data-role="start-meeting-sheet")
      assert html =~ ~s(data-role="start-meeting-error")
      assert html =~ "Name is required"
    end
  end

  # ── New-meeting create sheet (task 019fb955-1d7b stage 4) ────────────────
  #
  # The sheet the stage-2 FAB opens is now the canvas's CREATE sheet: a
  # schedulable time, a required project, and a list of invites staged
  # client-side and replayed after the meeting commits.
  #
  # ## Every absence assertion here has a positive control
  #
  # `refute Repo.exists?(Meeting)` passes on a fixture that could never
  # have written a row — a broken `create_project/0`, a form that never
  # reached the handler, an authenticated_conn that 302s. So the refusal
  # tests submit AGAIN with the missing field supplied and assert the row
  # appears. The control runs against the same view, the same form and the
  # same session, which is the only way it constrains the same code path.
  #
  # ## And each side of a present/absent pair is its own test
  #
  # ExUnit halts a test at its first failed assertion, so an `assert
  # rendered / refute written` pair can only ever report one of the two.

  describe ":index action — new-meeting create sheet" do
    # A real IANA zone with a non-zero UTC offset. Fixed rather than
    # inherited from the machine: the whole contract is "the wall clock the
    # VIEWER typed", and a fixture running in the server's zone cannot tell
    # a correct conversion from no conversion at all.
    @create_zone "America/Chicago"

    setup %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      Repo.delete_all(Meeting)
      project = create_project()

      {:ok,
       conn: put_connect_params(conn, %{"timezone" => @create_zone}), user: user, project: project}
    end

    defp open_create_sheet(conn) do
      {:ok, view, _html} = live(conn, ~p"/meetings")
      _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()
      view
    end

    defp create_params(overrides) do
      Map.merge(
        %{
          "name" => "Design review",
          "project_id" => "",
          "date" => "",
          "start_time" => "",
          "duration_minutes" => "30"
        },
        overrides
      )
    end

    defp submit_create(view, overrides) do
      view
      |> form("#start-meeting-form", start_meeting: create_params(overrides))
      |> render_submit()
    end

    # A UTC instant for a wall-clock reading in @create_zone. Everything
    # persisted is UTC; everything typed is local; this is where they meet.
    defp create_zone_utc(%Date{} = date, hour, minute) do
      date
      |> DateTime.new!(Time.new!(hour, minute, 0), @create_zone)
      |> DateTime.shift_zone!("Etc/UTC")
    end

    defp seed_invitee(name, email) do
      user =
        Repo.insert!(%User{
          email: email,
          name: name,
          oidc_sub: "oidc-invitee-#{System.unique_integer([:positive])}"
        })

      member!(user, Platform.TenancyFixtures.fabrikam_org_id())
    end

    defp search_invites(view, query) do
      view
      |> element(~s([data-role="meeting-invite-search"]))
      |> render_keyup(%{"value" => query})
    end

    defp staged_ids(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="meeting-invite-row"]))
      |> LazyHTML.attribute("data-entry-id")
    end

    # ── the schedule ───────────────────────────────────────────────────────

    test "a date and a start time persist both endpoints, converted from the viewer's zone",
         %{conn: conn, project: project} do
      view = open_create_sheet(conn)

      submit_create(view, %{
        "name" => "Design review",
        "project_id" => project.id,
        "date" => "2026-09-16",
        "start_time" => "09:30",
        "duration_minutes" => "45"
      })

      assert [%Meeting{} = created] = Repo.all(Meeting)

      # 09:30 CDT is 14:30 UTC. A handler that read the wall clock as UTC
      # would store 09:30Z and this fails by five hours.
      assert DateTime.compare(
               created.scheduled_start_at,
               create_zone_utc(~D[2026-09-16], 9, 30)
             ) == :eq

      assert DateTime.compare(
               created.scheduled_end_at,
               create_zone_utc(~D[2026-09-16], 10, 15)
             ) == :eq
    end

    test "leaving the date and start blank creates an ad-hoc meeting with neither endpoint",
         %{conn: conn, project: project} do
      view = open_create_sheet(conn)

      submit_create(view, %{"project_id" => project.id})

      assert [%Meeting{scheduled_start_at: nil, scheduled_end_at: nil}] = Repo.all(Meeting)
    end

    test "a date without a start time is refused", %{conn: conn, project: project} do
      view = open_create_sheet(conn)

      html = submit_create(view, %{"project_id" => project.id, "date" => "2026-09-16"})

      assert html =~ "Date and start time are required together."
    end

    test "a date without a start time writes no row, and the same form then does", %{
      conn: conn,
      project: project
    } do
      view = open_create_sheet(conn)

      submit_create(view, %{"project_id" => project.id, "date" => "2026-09-16"})
      refute Repo.exists?(Meeting)

      # Positive control on the SAME view and form: supplying the missing
      # field writes a row, so the refute above constrained the guard rather
      # than a fixture that could never have written anything.
      submit_create(view, %{
        "project_id" => project.id,
        "date" => "2026-09-16",
        "start_time" => "09:30"
      })

      assert Repo.exists?(Meeting)
    end

    test "a duration the select never offered is refused", %{conn: conn, project: project} do
      view = open_create_sheet(conn)

      # Sent as a raw event: `form/3` cannot select an option the sheet does
      # not render, and the point is precisely a value that did not come
      # from this form.
      html =
        render_submit(view, "start_meeting", %{
          "start_meeting" =>
            create_params(%{
              "project_id" => project.id,
              "date" => "2026-09-16",
              "start_time" => "09:30",
              "duration_minutes" => "37"
            })
        })

      assert html =~ "Duration is invalid."
    end

    test "a duration the select never offered writes no row, and an offered one does", %{
      conn: conn,
      project: project
    } do
      view = open_create_sheet(conn)

      base = %{"project_id" => project.id, "date" => "2026-09-16", "start_time" => "09:30"}

      render_submit(view, "start_meeting", %{
        "start_meeting" => create_params(Map.put(base, "duration_minutes", "37"))
      })

      refute Repo.exists?(Meeting)

      submit_create(view, Map.put(base, "duration_minutes", "60"))
      assert Repo.exists?(Meeting)
    end

    test "an hour the wall clock reads twice resolves to the earlier instant", %{
      conn: conn,
      project: project
    } do
      view = open_create_sheet(conn)

      # 2026-11-01 01:30 occurs twice in America/Chicago: once on CDT
      # (06:30Z) and again an hour later on CST (07:30Z).
      submit_create(view, %{
        "project_id" => project.id,
        "date" => "2026-11-01",
        "start_time" => "01:30"
      })

      assert [%Meeting{} = created] = Repo.all(Meeting)

      assert DateTime.to_iso8601(DateTime.shift_zone!(created.scheduled_start_at, "Etc/UTC")) =~
               "2026-11-01T06:30:00"
    end

    test "an hour that does not exist is refused rather than nudged", %{
      conn: conn,
      project: project
    } do
      view = open_create_sheet(conn)

      # 2026-03-08 02:30 is skipped by the spring transition in
      # America/Chicago — the clock goes 01:59:59 to 03:00:00.
      html =
        submit_create(view, %{
          "project_id" => project.id,
          "date" => "2026-03-08",
          "start_time" => "02:30"
        })

      assert html =~ "That time does not exist on that date."
    end

    test "an hour that does not exist writes no row, and a real one does", %{
      conn: conn,
      project: project
    } do
      view = open_create_sheet(conn)
      base = %{"project_id" => project.id, "date" => "2026-03-08"}

      submit_create(view, Map.put(base, "start_time", "02:30"))
      refute Repo.exists?(Meeting)

      submit_create(view, Map.put(base, "start_time", "03:30"))
      assert Repo.exists?(Meeting)
    end

    # ── the time zone the calendar member already plumbed ──────────────────

    test "a browser that named no zone cannot schedule a time", %{
      conn: conn,
      project: project
    } do
      # No `put_connect_params`, so `resolve_time_zone/1` answers nil — the
      # same answer the dead render gives. There is no honest conversion of
      # "09:30" without a zone, so it is refused rather than read as UTC.
      {:ok, view, _html} = live(build_conn() |> authenticated_conn() |> elem(0), ~p"/meetings")
      _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()

      html =
        submit_create(view, %{
          "project_id" => project.id,
          "date" => "2026-09-16",
          "start_time" => "09:30"
        })

      assert html =~ "Time zone unavailable"
      refute Repo.exists?(Meeting)
    end

    test "a browser that named no zone can still create an ad-hoc meeting", %{
      conn: conn,
      project: project
    } do
      # The refusal above is scoped to a SCHEDULED create. Without this
      # control it would be indistinguishable from a zone-less mount that
      # cannot create anything at all.
      {:ok, view, _html} = live(build_conn() |> authenticated_conn() |> elem(0), ~p"/meetings")
      _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()

      submit_create(view, %{"project_id" => project.id})

      assert [%Meeting{scheduled_start_at: nil}] = Repo.all(Meeting)
      assert is_map(conn)
    end

    # ── the project gate ───────────────────────────────────────────────────

    test "submitting with no project renders the server-side refusal", %{conn: conn} do
      Repo.delete_all(Project)
      view = open_create_sheet(conn)

      html = submit_create(view, %{"name" => "Project-less meeting", "project_id" => ""})

      assert html =~ ~s(data-role="start-meeting-sheet")
      assert html =~ ~s(data-role="start-meeting-error")
      assert html =~ "Project is required."
    end

    test "submitting with no project writes no row, and supplying one then does", %{
      conn: conn,
      project: project
    } do
      view = open_create_sheet(conn)

      submit_create(view, %{"name" => "Project-less meeting", "project_id" => ""})
      refute Repo.exists?(Meeting)

      # Positive control: same view, same form, project supplied.
      submit_create(view, %{"name" => "Project-less meeting", "project_id" => project.id})
      assert Repo.exists?(Meeting)
    end

    # ── the behaviour change: create does not open the room ────────────────

    test "a successful create keeps the viewer on the index", %{conn: conn, project: project} do
      view = open_create_sheet(conn)

      result = submit_create(view, %{"project_id" => project.id})

      # A `push_navigate` comes back as `{:error, {:live_redirect, …}}`. A
      # meeting scheduled for next week must not open its room now.
      assert is_binary(result)
      refute result =~ ~s(data-role="start-meeting-sheet")
    end

    test "a successful create flashes that the meeting was created", %{
      conn: conn,
      project: project
    } do
      view = open_create_sheet(conn)

      assert submit_create(view, %{"project_id" => project.id}) =~ "Meeting created."
    end

    # ── staged invites ─────────────────────────────────────────────────────

    test "staging a member then submitting writes an invite carrying their user_id", %{
      conn: conn,
      project: project
    } do
      invitee = seed_invitee("Dalton Reeve", "dalton.reeve@example.com")

      view = open_create_sheet(conn)
      search_invites(view, "Dalton Reeve")

      view
      |> element(~s([data-role="meeting-invite-candidate"][data-user-id="#{invitee.id}"]))
      |> render_click()

      assert staged_ids(view) == ["user:#{invitee.id}"]

      submit_create(view, %{"project_id" => project.id})

      assert [%Meeting{} = meeting] = Repo.all(Meeting)
      assert [%Invite{} = invite] = Repo.all(Invite)
      assert invite.meeting_id == meeting.id
      assert invite.user_id == invitee.id
    end

    test "staging then unstaging a member writes no invite", %{conn: conn, project: project} do
      invitee = seed_invitee("Marlowe Sun", "marlowe.sun@example.com")

      view = open_create_sheet(conn)
      search_invites(view, "Marlowe Sun")

      view
      |> element(~s([data-role="meeting-invite-candidate"][data-user-id="#{invitee.id}"]))
      |> render_click()

      view
      |> element(~s([data-role="meeting-invite-unstage"][data-entry-id="user:#{invitee.id}"]))
      |> render_click()

      assert staged_ids(view) == []

      submit_create(view, %{"project_id" => project.id})

      # The meeting IS written — the positive control for the refute below
      # is in the same submit, so a create that silently failed could not
      # masquerade as an unstage that worked.
      assert Repo.exists?(Meeting)
      assert Repo.all(Invite) == []
    end

    test "staging a guest writes a row with an expiry and no user", %{
      conn: conn,
      project: project
    } do
      view = open_create_sheet(conn)
      search_invites(view, "outsider@example.test")

      view
      |> element(~s([data-role="meeting-invite-option"][data-option="guest"]))
      |> render_click()

      assert staged_ids(view) == ["guest:outsider@example.test"]

      submit_create(view, %{"project_id" => project.id})

      assert [%Invite{} = invite] = Repo.all(Invite)
      assert invite.user_id == nil
      assert %DateTime{} = invite.expires_at
    end

    test "staging an external address writes a row with the address and no expiry", %{
      conn: conn,
      project: project
    } do
      view = open_create_sheet(conn)
      search_invites(view, "contractor@example.test")

      view
      |> element(~s([data-role="meeting-invite-option"][data-option="external"]))
      |> render_click()

      assert staged_ids(view) == ["external:contractor@example.test"]

      submit_create(view, %{"project_id" => project.id})

      assert [%Invite{} = invite] = Repo.all(Invite)
      assert invite.user_id == nil
      assert invite.email == "contractor@example.test"
      assert invite.expires_at == nil
    end

    # Named for what it can actually detect. An earlier version of this
    # said "dismissing the sheet drops the staged invites" and could not:
    # the list is only observable through a rendered sheet, rendering one
    # requires an open, and the open resets. A mutant deleting the
    # close-side reset left it green, so the close-side reset went away and
    # this asserts the guarantee that survives — a reopened sheet is clean.
    test "reopening the sheet starts with no staged invites", %{conn: conn} do
      invitee = seed_invitee("Rae Molina", "rae.molina@example.com")

      view = open_create_sheet(conn)
      search_invites(view, "Rae Molina")

      view
      |> element(~s([data-role="meeting-invite-candidate"][data-user-id="#{invitee.id}"]))
      |> render_click()

      assert staged_ids(view) == ["user:#{invitee.id}"]

      _ = view |> element(~s([data-role="start-meeting-sheet-close"])) |> render_click()
      _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()

      assert staged_ids(view) == []
    end

    test "an invite that cannot be written is reported rather than swallowed", %{
      conn: conn,
      project: project
    } do
      invitee = seed_invitee("Vanishing Vic", "vanishing.vic@example.com")

      view = open_create_sheet(conn)
      search_invites(view, "Vanishing Vic")

      view
      |> element(~s([data-role="meeting-invite-candidate"][data-user-id="#{invitee.id}"]))
      |> render_click()

      # The invitee stops existing between staging and submit, so the
      # invite's foreign key fails while the meeting itself is fine.
      Repo.delete!(invitee)

      html = submit_create(view, %{"project_id" => project.id})

      assert html =~ "1 invite could not be sent."
    end

    test "an invite that cannot be written does not roll the meeting back", %{
      conn: conn,
      project: project
    } do
      invitee = seed_invitee("Vanishing Val", "vanishing.val@example.com")

      view = open_create_sheet(conn)
      search_invites(view, "Vanishing Val")

      view
      |> element(~s([data-role="meeting-invite-candidate"][data-user-id="#{invitee.id}"]))
      |> render_click()

      Repo.delete!(invitee)
      submit_create(view, %{"project_id" => project.id})

      assert Repo.exists?(Meeting)
      assert Repo.all(Invite) == []
    end

    test "an id no candidate row offered crashes rather than staging a stranger", %{conn: conn} do
      Process.flag(:trap_exit, true)
      view = open_create_sheet(conn)

      # The only legal source of that id is a candidate row this socket
      # just drew. Anything else is a forged event, and staging it would
      # invite someone the host never saw offered.
      reason =
        catch_exit(
          render_click(view, "meeting_create_invite_stage", %{
            "kind" => "user",
            "id" => Ecto.UUID.generate()
          })
        )

      assert {{%ArgumentError{message: message}, _stacktrace}, _from} = reason
      assert message =~ "no candidate is currently offered"
    end

    # ── the rendered frame ─────────────────────────────────────────────────

    test "the description textarea is gone and the schedule fields took its place", %{
      conn: conn
    } do
      html = conn |> open_create_sheet() |> render()

      # `create_meeting/1` never persisted a description, so the field
      # silently discarded whatever was typed into it.
      refute html =~ ~s(name="start_meeting[description]")

      # The positive side, so the refute above cannot pass off a sheet that
      # failed to render at all.
      assert html =~ ~s(name="start_meeting[date]")
      assert html =~ ~s(name="start_meeting[start_time]")
      assert html =~ ~s(name="start_meeting[duration_minutes]")
    end

    test "the mobile Create button is hidden from sm up and submits the sheet's form", %{
      conn: conn
    } do
      doc = conn |> open_create_sheet() |> render() |> LazyHTML.from_fragment()
      mobile = LazyHTML.query(doc, ~s([data-role="meeting-create-submit-mobile"]))

      # Exactly one, and its `form` attribute is what lets a control OUTSIDE
      # the `<form>` element submit it — the canvas puts it in the header.
      assert LazyHTML.attribute(mobile, "form") == ["start-meeting-form"]
      assert LazyHTML.attribute(mobile, "type") == ["submit"]
      assert [class] = LazyHTML.attribute(mobile, "class")
      assert class =~ "sm:hidden"
    end

    test "the desktop footer bar is hidden below sm and holds Cancel plus the primary", %{
      conn: conn
    } do
      doc = conn |> open_create_sheet() |> render() |> LazyHTML.from_fragment()

      assert [class] =
               doc
               |> LazyHTML.query(~s([data-role="meeting-create-footer"]))
               |> LazyHTML.attribute("class")

      assert class =~ "hidden"
      assert class =~ "sm:flex"

      # Both live INSIDE the footer, so the two breakpoints cannot end up
      # offering the same control twice.
      assert doc
             |> LazyHTML.query(
               ~s([data-role="meeting-create-footer"] [data-role="start-meeting-cancel"])
             )
             |> Enum.count() == 1

      assert doc
             |> LazyHTML.query(
               ~s([data-role="meeting-create-footer"] [data-role="start-meeting-submit"])
             )
             |> Enum.count() == 1
    end

    # The sponsor rejected stage 4 at the UI gate: "having too many meeting
    # invites pushes the button off the modal on desktop". The panel was one
    # scroll region (`max-h-[75vh] overflow-y-auto` on the panel itself), so
    # the footer bar scrolled WITH the staged-invite list instead of staying
    # pinned, and past a few staged rows `start-meeting-submit` sat below the
    # visible edge of the modal.
    #
    # Asserting the button is PRESENT cannot see this — it was present the
    # whole time, just out of view. So assert the structure that makes the
    # defect impossible: the panel caps height but does not scroll, exactly
    # one descendant scrolls, and the primary action is NOT inside it.
    defp create_sheet_panel(doc) do
      LazyHTML.query(doc, ~s([data-role="start-meeting-sheet"] > div.relative))
    end

    defp class_of(lazy), do: lazy |> LazyHTML.attribute("class") |> List.first("")

    # A class list that establishes a scroll container on the block axis.
    # `overflow-hidden` is deliberately NOT one of these — it clips, it does
    # not scroll, and it is what the panel is supposed to carry.
    defp scrolls?(class) do
      Enum.any?(
        ~w(overflow-y-auto overflow-y-scroll overflow-auto overflow-scroll),
        &String.contains?(class, &1)
      )
    end

    test "the panel caps height without scrolling, so the footer cannot be pushed off", %{
      conn: conn
    } do
      doc = conn |> open_create_sheet() |> render() |> LazyHTML.from_fragment()
      panel_class = doc |> create_sheet_panel() |> class_of()

      # Positive side first: the panel rendered at all.
      assert panel_class =~ "max-h-[75vh]", "the panel no longer caps its height"

      # A capped-height flex column. Without `flex-col` the body cannot be
      # the only thing that grows, and the cap goes back to clipping or
      # scrolling the footer along with the list.
      assert panel_class =~ "flex", "the panel is not a flex container"
      assert panel_class =~ "flex-col", "the panel is not a flex COLUMN"

      refute scrolls?(panel_class),
             "the panel itself scrolls (#{panel_class}) — the footer bar scrolls with the " <>
               "staged-invite list and leaves the modal, which is the rejected defect"
    end

    test "the primary action lives outside the sheet's one scrolling region", %{conn: conn} do
      doc = conn |> open_create_sheet() |> render() |> LazyHTML.from_fragment()
      panel = create_sheet_panel(doc)

      # Per-node walk, not a `class*=` selector: read each node's own class
      # list and decide, so a scroll container introduced anywhere in the
      # panel is counted rather than matched by luck of the selector.
      # `LazyHTML.query(node, "*")` includes the node it is rooted at, so
      # the panel is in this walk too — a panel that scrolls shows up here
      # as a region that contains the footer.
      scrollers =
        panel
        |> LazyHTML.query("*")
        |> Enum.filter(&(&1 |> class_of() |> scrolls?()))

      assert [body] = scrollers,
             "expected exactly one scrolling region inside the panel, found #{length(scrollers)}"

      # `min-h-0` is the load-bearing bit: a flex child defaults to
      # `min-height: auto` and refuses to shrink below its content, so
      # without it the body never scrolls and the footer is pushed off
      # again even though the panel is a flex column.
      body_class = class_of(body)
      assert body_class =~ "min-h-0", "the scrolling body can grow past the panel's cap"
      assert body_class =~ "flex-1", "the scrolling body does not take the free space"

      # The submit renders exactly once in the panel …
      assert panel |> LazyHTML.query(~s([data-role="start-meeting-submit"])) |> Enum.count() == 1

      # … and not from inside the region that scrolls away.
      assert body |> LazyHTML.query(~s([data-role="start-meeting-submit"])) |> Enum.count() == 0,
             "start-meeting-submit is inside the scrolling body — enough staged invites push " <>
               "it out of the visible modal"

      assert body |> LazyHTML.query(~s([data-role="start-meeting-cancel"])) |> Enum.count() == 0,
             "start-meeting-cancel is inside the scrolling body"

      # The staged invites are what grows, so they MUST be inside it —
      # otherwise the assertions above hold trivially on a sheet whose body
      # scrolls nothing.
      assert body
             |> LazyHTML.query(~s([data-role="meeting-create-invite-section"]))
             |> Enum.count() == 1
    end

    test "a long staged-invite list does not move the primary action into the scroll region", %{
      conn: conn
    } do
      view = open_create_sheet(conn)

      # Ten staged externals — well past the point where the old markup had
      # already carried the footer below the panel's visible edge.
      for index <- 1..10 do
        _ = search_invites(view, "overflow#{index}@example.com")

        view
        |> element(~s([data-role="meeting-invite-option"][data-option="guest"]))
        |> render_click()
      end

      doc = view |> render() |> LazyHTML.from_fragment()
      assert doc |> LazyHTML.query(~s([data-role="meeting-invite-row"])) |> Enum.count() == 10

      panel = create_sheet_panel(doc)

      assert [body] =
               panel
               |> LazyHTML.query("*")
               |> Enum.filter(&(&1 |> class_of() |> scrolls?()))

      assert body |> LazyHTML.query(~s([data-role="meeting-invite-row"])) |> Enum.count() == 10

      assert body |> LazyHTML.query(~s([data-role="start-meeting-submit"])) |> Enum.count() == 0,
             "with ten invites staged the primary action sits inside the scrolling body"
    end

    test "every control in the sheet clears a 44px tap target", %{conn: conn} do
      doc = conn |> open_create_sheet() |> render() |> LazyHTML.from_fragment()

      roles = [
        "start-meeting-name",
        "start-meeting-project",
        "meeting-create-date",
        "meeting-create-start-time",
        "meeting-create-duration",
        "start-meeting-cancel",
        "start-meeting-submit",
        "meeting-create-submit-mobile"
      ]

      # `Enum.each` with an explicit one-element match, NOT a comprehension:
      # `for {role, [class]} <- …` silently SKIPS a role that rendered zero
      # elements, which is exactly the failure this is looking for.
      Enum.each(roles, fn role ->
        assert [class] =
                 doc
                 |> LazyHTML.query(~s([data-role="#{role}"]))
                 |> LazyHTML.attribute("class"),
               "#{role} did not render exactly once"

        assert class =~ "min-h-11", "#{role} does not clear 44px"
      end)
    end

    test "the sheet stays an overlay with safe-area padding, not a second bottom sheet", %{
      conn: conn
    } do
      doc = conn |> open_create_sheet() |> render() |> LazyHTML.from_fragment()

      assert [wrapper] =
               doc
               |> LazyHTML.query(~s([data-role="start-meeting-sheet"]))
               |> LazyHTML.attribute("class")

      assert wrapper =~ "fixed inset-0"
      assert wrapper =~ "items-end sm:items-center"

      # Out of flow, so the safe-area inset is the whole clearance — the
      # bottom-nav reservation applies to in-flow scroll regions, which
      # already end above a sticky nav.
      assert doc
             |> LazyHTML.query(~s([data-role="start-meeting-sheet"] > div.relative))
             |> LazyHTML.attribute("class")
             |> List.first() =~ "pb-[env(safe-area-inset-bottom)]"
    end
  end

  # ── LiveKit wiring via MeetingHooks (task 019e2d1a stage 2) ──────────────
  #
  # Stage 2 wires the LiveKit lifecycle into MeetingLive by reusing
  # `PlatformWeb.ChatLive.MeetingHooks`. Auto-join on connected mount
  # mints a token and push_events `"join-meeting"` to the MeetingClient
  # JS hook; mic/cam/screen-share buttons in the top bar push the
  # corresponding toggle events; the "Leave" CTA pushes
  # `"leave-meeting"` and flips `@in_meeting` back to false. These tests
  # exercise the server-side surface — the JS hooks themselves are not
  # mounted in LV tests, but the push_events ARE captured.

  describe "LiveKit wiring (stage 2)" do
    setup %{conn: conn} do
      # MeetingHooks.do_join calls `Meetings.generate_token/2` which
      # needs LIVEKIT_API_KEY + LIVEKIT_API_SECRET + LIVEKIT_URL in app
      # env. The test runtime config doesn't set these (meetings are
      # gated behind real LiveKit creds in production); stash a fake
      # triple for the duration of this describe block and restore on
      # exit so the global enabled?/0 gate stays inert elsewhere.
      original = Application.get_env(:platform, :livekit, [])

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: "test-livekit-secret-0123456789abcdef",
        url: "wss://livekit.test"
      )

      on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

      {meeting, space} =
        create_meeting(%{slug: "livekit-wiring", name: "LiveKit Wiring"})

      {conn, user} = authenticated_conn(conn)

      # MeetingHooks.do_join also needs a `:current_participant` in
      # the meeting's chat space — seed one for the viewer so the join
      # path exits via the {:ok, token} branch and the push_event
      # actually fires.
      {:ok, _participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: "LiveKit Viewer",
          joined_at: DateTime.utc_now()
        })

      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "renders the two hidden MeetingClient/MeetingRoom hook nodes", %{
      conn: conn,
      meeting: meeting
    } do
      # The `?no_autojoin=true` escape hatch silences the auto-join so
      # we can assert the static markup without racing the
      # join-meeting push_event.
      {:ok, _view, html} =
        live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert html =~ ~s(id="meeting-client")
      assert html =~ ~s(phx-hook="MeetingClient")
      assert html =~ ~s(id="meeting-room")
      assert html =~ ~s(phx-hook="MeetingRoom")
    end

    test "the Transcript tab's empty state says 'No speech yet' when LiveKit is configured — decided at mount, not at join",
         %{conn: conn, meeting: meeting} do
      # Task 01a0693d. `captions_available` on `/meetings` used to derive
      # from `@livekit_url`, which is assigned ONLY on the guest bundle
      # path (`MeetingHooks.do_join` puts the url in the join push_event
      # payload, never in an assign), so every signed-in viewer read
      # "unavailable" before, during and after a join even with captions
      # flowing. It now reads `@meetings_enabled`, the same mount-time
      # `Platform.Meetings.enabled?/0` the quickmeet passes, which is true
      # under this describe's LiveKit triple. No join round-trip is needed
      # to prove it: the first render is the whole claim.
      #
      # NAMED MUTATION: restore `(assigns[:livekit_url] || "") != ""` in
      # `meeting_live.html.heex` and the positive assertion goes red. The
      # unconfigured-env twin lives under "right rail: the shared
      # CallShell on /meetings" and pins the other branch.
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=transcript")

      assert html =~ "No speech yet. Lines appear here as people talk."
      refute html =~ "Captions are unavailable"

      # And the copy sits where a later patch can still reach it: in the
      # LiveView-owned wrap, NOT inside the `phx-update="ignore"` host.
      assert count(
               html,
               ~s([data-role="meeting-transcript-wrap"] > [data-role="transcript-empty"])
             ) ==
               1

      assert count(html, ~s([data-role="meeting-transcript"] [data-role="transcript-empty"])) == 0
    end

    test "auto-joins on connected mount and push_events join-meeting with token + url + room_name",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # The join lifecycle runs in MeetingHooks.do_join — token mint,
      # MeetingState broadcast, then push_event. Asserting the payload
      # carries token / url / room_name matches the JS hook's contract
      # in meeting_client.js.
      assert_push_event(view, "join-meeting", %{
        token: token,
        url: url,
        room_name: room_name
      })

      assert is_binary(token) and token != ""
      assert url == "wss://livekit.test"
      assert is_binary(room_name) and room_name != ""

      # And the LV reflects the in-meeting state so the top bar flips
      # the CTA from "Join" to "Leave".
      html = render(view)
      assert html =~ ~s(data-role="meeting-leave")
      refute html =~ ~s(data-role="meeting-join")
    end

    test "?no_autojoin=true skips the auto-join and leaves the Join CTA", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, html} =
        live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # No auto-join fired → still showing the Join CTA, not the Leave CTA.
      assert html =~ ~s(data-role="meeting-join")
      refute html =~ ~s(data-role="meeting-leave")

      # The manual click should still push the join-meeting event.
      view
      |> element(~s([data-role="meeting-join"]))
      |> render_click()

      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})
    end

    test "meeting_toggle_mic flips @mic_enabled and pushes toggle-mic", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} =
        live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # Default is mic ON (MeetingHooks.attach initial assigns).
      html_before = render(view)
      assert html_before =~ ~s(data-role="meeting-mic" data-active="true")

      html_after =
        view
        |> element(~s([data-role="meeting-mic"]))
        |> render_click()

      assert html_after =~ ~s(data-role="meeting-mic" data-active="false")
      assert_push_event(view, "toggle-mic", %{})
    end

    test "meeting_toggle_camera flips @camera_enabled and pushes toggle-camera",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} =
        live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # Default is camera ON (bugfix re-pass for task 019e2d1a — the
      # spec expects the gallery entry state to show `hero-video-camera`
      # rather than `hero-video-camera-slash`, which means the
      # `:camera_enabled` assign must start `true`).
      html_before = render(view)
      assert html_before =~ ~s(data-role="meeting-camera" data-active="true")

      html_after =
        view
        |> element(~s([data-role="meeting-camera"]))
        |> render_click()

      assert html_after =~ ~s(data-role="meeting-camera" data-active="false")
      assert_push_event(view, "toggle-camera", %{})
    end

    test "meeting_leave click flips @in_meeting back to false and pushes leave-meeting",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # The auto-join push must clear from the queue before we assert
      # the leave push lands — render once to flush.
      _ = render(view)
      assert render(view) =~ ~s(data-role="meeting-leave")

      html_after =
        view
        |> element(~s([data-role="meeting-leave"]))
        |> render_click()

      # CTA flipped back to Join…
      assert html_after =~ ~s(data-role="meeting-join")
      refute html_after =~ ~s(data-role="meeting-leave")
      # …and the leave-meeting event landed on the JS-hook channel.
      assert_push_event(view, "leave-meeting", %{})
    end
  end

  # ── Screen-share fix (task 019e420f) ──────────────────────────────
  #
  # Stages 1 + 2 + 3 of the screen-share fix:
  #   * Stage 1: MeetingClient + MeetingRoom + meeting-media hooks mount
  #     on the dedicated meeting page so the LiveKit Room survives
  #     navigation.
  #   * Stage 2: the screen-share button is wired via the
  #     `MeetingShareButton` JS hook (client-side gesture preservation),
  #     not via a phx-click that round-trips through the server.
  #   * Stage 3: incoming screen-share tracks route to a dedicated
  #     preview slot in Quick Meet, not into the per-participant tile.
  describe "screen-share fix (task 019e420f)" do
    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{slug: "screen-share-fix", name: "Screen Share Fix"})

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "MeetingClient + MeetingRoom hooks mount on the meeting page (stage 1)",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # Stage 1 contract: the dedicated meeting page mounts MeetingClient
      # so the LiveKit Room survives nav from /chat/<slug> → /meetings/<slug>.
      assert html =~ ~s(id="meeting-client")
      assert html =~ ~s(phx-hook="MeetingClient")
      # MeetingRoom is the parity hook (track-event sink for video tiles).
      assert html =~ ~s(id="meeting-room")
      assert html =~ ~s(phx-hook="MeetingRoom")
      # And a media sink for <audio> elements so they don't pollute body.
      assert html =~ ~s(id="meeting-media")
    end

    test "screen-share button uses the MeetingShareButton hook, not phx-click (stage 2)",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # Stage 2 contract: client-side click handler. The top-bar share
      # button MUST use `phx-hook="MeetingShareButton"` so the gesture
      # reaches `getDisplayMedia()` without yielding to the WebSocket.
      assert html =~ ~s(id="meeting-share-btn-desktop")
      assert html =~ ~s(phx-hook="MeetingShareButton")

      # Belt-and-suspenders: the legacy phx-click that used to be on
      # this button must NOT be present anymore (it would race the hook).
      # `phx-click` IS still on the button, deliberately: the hook calls
      # `preventDefault`/`stopPropagation` and only falls back to the
      # server event when there is no LiveKit room to drive. What must
      # not happen is the hook going missing, which is asserted above and
      # again in the CallShell mount tests.
      assert html =~ ~s(data-role="meeting-screen-share")
    end

    test "screen-mode CTA uses the MeetingShareButton hook (stage 2)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} =
        live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      html =
        view
        |> element(~s([data-stage-mode-button="screen"]))
        |> render_click()

      # The "Start sharing" CTA on the Screen-mode empty state is now
      # owned by the MeetingShareButton hook (stage 2 wiring) instead of
      # the server-roundtripped `meeting_start_screen_share` phx-click.
      assert html =~ ~s(id="meeting-share-btn-screen-cta")
      assert html =~ ~s(data-action="start-screen-share")

      refute html =~
               ~r/id="meeting-share-btn-screen-cta"[^>]*phx-click="meeting_start_screen_share"/
    end

    test "meeting_screen_share_state assigns the boolean and does NOT push toggle-screen-share",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} =
        live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # Default is FALSE (MeetingHooks.attach).
      assert render(view) =~ ~s(data-role="meeting-screen-share" data-active="false")

      # The JS hook (MeetingShareButton) pushes meeting_screen_share_state
      # with the post-toggle boolean. We drive that directly here.
      render_hook(view, "meeting_screen_share_state", %{"enabled" => true})

      assert render(view) =~ ~s(data-role="meeting-screen-share" data-active="true")

      # And: NO `toggle-screen-share` browser event was pushed. The JS
      # hook already did the LiveKit work itself; pushing another event
      # would double-toggle.
      refute_push_event(view, "toggle-screen-share", %{})
    end

    test "meeting_screen_share_state with a non-boolean is ignored cleanly", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} =
        live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # Hand-crafted bad payload — the guard refuses it without crashing
      # the LV. The assign stays at its default.
      render_hook(view, "meeting_screen_share_state", %{"enabled" => "true"})

      assert render(view) =~ ~s(data-role="meeting-screen-share" data-active="false")
    end
  end

  # ── Desktop pane collapse (task 019e40f2) ──────────────────────────────
  #
  # Two new desktop-only collapse affordances: the participant rail (left
  # side) and the chat pane (right side). Both default expanded, flip via
  # `phx-click` to a slim 48px rail, mirror their state into localStorage
  # via the parameterized `SidebarCollapse` JS hook. Mobile is untouched —
  # the existing `:chat_panel_open` drawer path keeps working byte-
  # identically.
  describe "desktop pane collapse (task 019e40f2)" do
    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{slug: "kickoff-collapse", name: "Collapse Meeting"})

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "mounts expanded, with no left rail to collapse", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # The call rail renders wide. Task 01a084bf stage 2: the collapse
      # state is an ATTRIBUTE on the one rail node (`data-collapsed`), so
      # this reads the value rather than the absence of a second node —
      # which is a stronger read, because absence also held when the rail
      # failed to render at all.
      assert html =~ ~s(data-pane="call-rail")
      assert html =~ ~s(data-pane="call-rail" data-collapsed="false")
    end

    # THE GUARD (task 01a05b14 stage 3). The left rail is gone, and so is
    # everything that drove it. This is asserted as ABSENCE because the
    # failure mode it protects against is a partial removal: an assign
    # deleted while its `SidebarCollapse` host survives leaves a live hook
    # pushing `meeting_participant_rail_hydrate` at a handler that no
    # longer exists, which no server-side test can otherwise see.
    test "the left participant rail and its persistence host are gone", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      refute html =~ ~s(data-pane="left-rail")
      refute html =~ ~s(data-role="participant-rail-toggle")
      refute html =~ ~s(id="meeting-participant-rail-collapse-hook")
      refute html =~ ~s(data-storage-key="suite.meeting.participant_rail.collapsed")
      refute html =~ ~s(data-hydrate-event="meeting_participant_rail_hydrate")
      refute html =~ ~s(data-change-event="meeting_participant_rail_collapsed_changed")
    end

    # ── THE GUARD (task 01a084bf stage 2) ────────────────────────────────
    #
    # STRUCTURAL, deliberately. The rail's collapse used to swap between
    # two sibling nodes that BOTH carried `data-pane="call-rail"`: a wide
    # one hidden at `lg`, and a 48px `<aside :if={@chat_panel_collapsed}>`.
    # A per-node CSS transition cannot animate a width that moves between
    # two nodes, so the collapse filmed frame-by-frame as a single-frame
    # 312px → 48px jump (task 01a0740d's V5 case).
    #
    # The check that let that through asserted THAT A TRANSITION CLASS WAS
    # PRESENT. It was present — on the node being replaced. That assertion
    # was vacuous and is not repeated here in any form.
    #
    # What this pins instead is the property the animation actually needs,
    # and nothing about styling: `[data-pane="call-rail"]` matches exactly
    # ONE node in each state, and it is THE SAME node — same stable `id` —
    # in both, with the state carried as an attribute on it. Named mutation
    # `two-node` (re-split the rail into two `:if`-gated
    # `data-pane="call-rail"` siblings) was run against this and turns it
    # red on the collapsed count.
    test "the call rail is ONE node in both states, and the SAME node — collapsed is an attribute, not a sibling swap",
         %{conn: conn, meeting: meeting} do
      {:ok, view, expanded} = live(conn, ~p"/meetings/#{meeting.slug}")

      expanded_rails = call_rail_panes(expanded)

      assert length(expanded_rails) == 1,
             "expected exactly ONE [data-pane=\"call-rail\"] while expanded, got " <>
               "#{length(expanded_rails)}: #{inspect(expanded_rails)}"

      collapsed = render_hook(view, "toggle_meeting_chat_pane", %{})
      collapsed_rails = call_rail_panes(collapsed)

      assert length(collapsed_rails) == 1,
             "expected exactly ONE [data-pane=\"call-rail\"] while collapsed, got " <>
               "#{length(collapsed_rails)}: #{inspect(collapsed_rails)}"

      [expanded_attrs] = expanded_rails
      [collapsed_attrs] = collapsed_rails

      # The state is ON the node, both ways round. Asserting both values
      # (rather than the absence of an attribute) is what makes the count
      # above mean something: a document with no rail at all would satisfy
      # "no collapsed marker" but not this.
      assert expanded_attrs["data-collapsed"] == "false"
      assert collapsed_attrs["data-collapsed"] == "true"

      # …and it is the SAME element. A count of 1 either side would also
      # hold if collapsing swapped one node for a DIFFERENT single node,
      # which is precisely the structure this guard forbids.
      assert collapsed_attrs["id"] == expanded_attrs["id"],
             "the collapsed rail is a DIFFERENT element " <>
               "(#{inspect(collapsed_attrs["id"])}) from the expanded one " <>
               "(#{inspect(expanded_attrs["id"])}); a width transition cannot " <>
               "animate a value that moves between two nodes"

      assert expanded_attrs["id"] == "meeting-call-rail-pane"

      # Both former siblings are now BRANCHES INSIDE that node. Queried as
      # descendants of it, so a branch hoisted back out to sibling
      # position fails here even if it drops `data-pane`. `LazyHTML.query/2`
      # descends the whole tree; `filter/2` would only match the fragment's
      # root nodes and read as "not there".
      collapsed_doc = frag(collapsed)

      assert collapsed_doc
             |> LazyHTML.query(~s([data-pane="call-rail"] [data-role="call-rail-collapsed"]))
             |> Enum.count() == 1

      assert collapsed_doc
             |> LazyHTML.query(~s([data-pane="call-rail"] [data-role="call-rail-expanded"]))
             |> Enum.count() == 1
    end

    # The other half of the restructure. Folding the slim strip INTO the rail
    # node put the desktop collapse and the `<lg` drawer on one element for
    # the first time, which is exactly where "a preference flipped on a
    # laptop silently breaks the rail toggle on a phone" becomes reachable.
    # Nothing covered the rail drawer before this stage.
    test "collapse stays a DESKTOP concern — the `<lg` drawer still opens while collapsed, and the slim strip is `lg:`-only",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      collapsed = render_hook(view, "toggle_meeting_chat_pane", %{})
      assert collapsed =~ ~s(data-pane="call-rail" data-collapsed="true")

      # The branch that IS the drawer is still in the document while
      # collapsed — hidden at `lg` by CSS, never `:if`-removed, so
      # `#meeting-call-rail` and the hooks under it survive.
      assert collapsed
             |> frag()
             |> LazyHTML.query(~s([data-role="call-rail-expanded"] #meeting-call-rail))
             |> Enum.count() == 1

      # Open the `<lg` surface WHILE collapsed.
      opened = view |> element(~s([data-role="call-rail-toggle"])) |> render_click()

      [opened_attrs] = call_rail_panes(opened)
      assert opened_attrs["data-call-rail-open"] == "true"
      assert opened_attrs["data-collapsed"] == "true"

      classes = String.split(opened_attrs["class"])

      # The desktop collapse width is `lg:`-prefixed. (The drawer's
      # base-layer `translate-x-0` went with the drawer in task 01a07410
      # stage 3; the `<lg` open-state is asserted on the sheet below.)

      # 44px, not 48px. Task 01a0740d shipped and MEASURED the collapsed
      # strip at exactly 44.000 and derives the 268px stage delta
      # (312 - 44) from it; this stage's one-node fold was drafted at
      # `w-12` before that landed and adopts the shipped width, because
      # two different collapsed widths in one file is the failure mode.
      # Tokenised: the bare `w-11` refutation is what catches the width
      # leaking out of its `lg:` scope onto the `<lg` drawer.
      assert "lg:w-11" in classes
      refute "w-11" in classes
      refute "lg:w-12" in classes

      # The slim strip is `>=lg` ONLY: `hidden` at the base layer means a
      # phone never sees it, whatever the stored desktop preference says.
      [strip_class] =
        opened
        |> frag()
        |> LazyHTML.query(~s([data-role="call-rail-collapsed"]))
        |> LazyHTML.attribute("class")

      strip_classes = String.split(strip_class)
      assert "hidden" in strip_classes
      assert "lg:flex" in strip_classes

      # …and the expanded branch's hiding is likewise `lg:`-scoped, so the
      # collapse cannot blank the drawer.
      [expanded_class] =
        opened
        |> frag()
        |> LazyHTML.query(~s([data-role="call-rail-expanded"]))
        |> LazyHTML.attribute("class")

      expanded_classes = String.split(expanded_class)
      assert "lg:hidden" in expanded_classes
      refute "hidden" in expanded_classes

      # And on a phone the same collapsed preference does not stop the
      # sheet: the rail renders inside it, open, with the expanded branch
      # still `lg:`-hidden only.
      below = render_hook(view, "meeting_viewport", %{"below" => true})
      assert count(below, ~s(#meeting-rail-sheet[data-open="true"])) == 1

      assert below
             |> frag()
             |> LazyHTML.query(
               ~s(#meeting-rail-sheet [data-role="call-rail-expanded"] #meeting-call-rail)
             )
             |> Enum.count() == 1
    end

    # Attribute maps for every `[data-pane="call-rail"]` in a document, one
    # map per matching node. `LazyHTML.attributes/1` is per-node, unlike
    # `attribute/2`, which flattens and silently drops nodes that lack the
    # attribute — that flattening would make a two-node document
    # indistinguishable from a one-node one here.
    defp call_rail_panes(html) do
      html
      |> frag()
      |> LazyHTML.query(~s([data-pane="call-rail"]))
      |> LazyHTML.attributes()
      |> Enum.map(&Map.new/1)
    end

    test "toggle_meeting_chat_pane flips the chat_panel_collapsed assign", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      after_collapse = render_hook(view, "toggle_meeting_chat_pane", %{})
      # The one rail node reports itself collapsed on `>=lg`.
      assert after_collapse =~ ~s(data-pane="call-rail" data-collapsed="true")
      # CHANGED BY task 01a05b14 stage 6. `@chat_panel_collapsed` used to
      # remove the rail from the document outright; it now hides it at
      # `lg` ONLY, because the rail is also the `<lg` drawer and this
      # collapse is a DESKTOP affordance driven by a `lg:`-only chevron.
      # Letting a preference set on a laptop silently break the rail
      # toggle on a phone was the alternative.
      #
      # RE-ANCHORED by task 01a084bf stage 2. This used to assert the bare
      # string `"lg:!hidden"` against the whole document, which the chat
      # drawer also carries unconditionally — so it would have kept
      # passing with the rail's own hiding removed entirely. The hiding is
      # now read off the expanded branch's own class attribute.
      assert after_collapse =~ ~s(data-component="call-rail")

      [expanded_class] =
        after_collapse
        |> frag()
        |> LazyHTML.query(~s([data-role="call-rail-expanded"]))
        |> LazyHTML.attribute("class")

      assert expanded_class =~ "lg:hidden"
      assert_push_event(view, "meeting_chat_pane_collapsed_changed", %{collapsed: true})

      after_expand = render_hook(view, "toggle_meeting_chat_pane", %{})
      assert after_expand =~ ~s(data-pane="call-rail" data-collapsed="false")
      assert after_expand =~ ~s(data-component="call-rail")
      assert_push_event(view, "meeting_chat_pane_collapsed_changed", %{collapsed: false})
    end

    test "meeting_chat_pane_hydrate adopts a stored value when different", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      after_hydrate =
        render_hook(view, "meeting_chat_pane_hydrate", %{"collapsed" => true})

      assert after_hydrate =~ ~s(data-pane="call-rail" data-collapsed="true")
    end

    test "hydrate is idempotent when the value matches the current assign", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      _ = render_hook(view, "meeting_chat_pane_hydrate", %{"collapsed" => false})

      html = render(view)
      assert html =~ ~s(data-pane="call-rail" data-collapsed="false")
    end

    test "clicking chat-pane-toggle collapses the call rail to the slim strip",
         %{conn: conn, meeting: meeting} do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-role="chat-pane-toggle")
      assert html =~ ~s(data-pane="call-rail" data-collapsed="false")

      after_collapse =
        view
        |> element(~s([data-role="chat-pane-toggle"]))
        |> render_click()

      assert after_collapse =~ ~s(data-pane="call-rail" data-collapsed="true")
      assert after_collapse =~ "hero-chevron-double-left"
    end

    test "the collapse toggle carries `hidden lg:inline-flex` so it's invisible on mobile",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~
               ~r/data-role="chat-pane-toggle"[^>]*hidden lg:inline-flex|hidden lg:inline-flex[^>]*data-role="chat-pane-toggle"/
    end

    test "the surviving SidebarCollapse host is the chat-pane one",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(id="meeting-chat-pane-collapse-hook")
      assert html =~ ~s(data-storage-key="suite.meeting.chat_pane.collapsed")
      assert html =~ ~s(data-hydrate-event="meeting_chat_pane_hydrate")
      assert html =~ ~s(data-change-event="meeting_chat_pane_collapsed_changed")

      # Exactly one meeting-scoped host now that the participant-rail one
      # went with the rail. (The shell's own sidebar host is a different
      # storage key and is counted out by the `suite.meeting.` prefix.)
      assert length(String.split(html, ~s(data-storage-key="suite.meeting.))) - 1 == 1
    end

    test "the `<lg` drawer latch stays orthogonal to the desktop collapse", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # WAS phrased against `:chat_panel_open` and `data-chat-panel-open`,
      # the chat drawer's own latch. Task 01a084bf stage 3 deleted that
      # drawer and that assign; chat rides the RAIL's drawer now, whose
      # latch is `:call_rail_open` / `data-call-rail-open`.
      #
      # The property under test is unchanged and is the one that matters:
      # the `<lg` open-state and the `>=lg` collapse preference are
      # INDEPENDENT, so a laptop collapse cannot silently disable a phone's
      # drawer. It is now strictly more load-bearing than before, because
      # after the fold both live on the same DOM node.
      _ =
        view
        |> element(~s([data-role="chat-panel-toggle"]))
        |> render_click()

      [open_attrs] = call_rail_panes(render(view))
      assert open_attrs["data-call-rail-open"] == "true"
      assert open_attrs["data-collapsed"] == "false"

      # Now collapse the rail (desktop). The `<lg` latch is unchanged.
      _ = render_hook(view, "toggle_meeting_chat_pane", %{})

      [collapsed_attrs] = call_rail_panes(render(view))
      assert collapsed_attrs["data-call-rail-open"] == "true"
      assert collapsed_attrs["data-collapsed"] == "true"

      # Same node throughout — the one-node property this describe pins.
      assert open_attrs["id"] == collapsed_attrs["id"]
      assert collapsed_attrs["id"] == "meeting-call-rail-pane"
    end
  end

  # The shared call shell, mounted (task 01a05b14 stage 3). `call_shell_test.exs`
  # covers the component in isolation; these cover what the component test
  # structurally cannot — that `/meetings` is what mounts it, with real
  # assigns, and that the panes it now owns are rendered in exactly one place.
  describe "right rail: the shared CallShell on /meetings" do
    setup %{conn: conn} do
      # Three tests in this block render the JOINED state through
      # `meeting_join`, which needs LiveKit creds to be present or the
      # join fails with `:livekit_not_configured` and `@in_meeting` stays
      # false. The test runtime config sets none (same reason as the
      # "LiveKit wiring" block above), so stash a fake triple for this
      # block and restore on exit. Without this the block only passed on
      # a host that happened to export LIVEKIT_* (stage 5 finding).
      original = Application.get_env(:platform, :livekit, [])

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: "test-livekit-secret-0123456789abcdef",
        url: "wss://livekit.test"
      )

      on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

      {meeting, space} =
        create_meeting(%{
          slug: "call-shell-#{System.unique_integer([:positive])}",
          name: "Call Shell"
        })

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "renders the three tabs with exactly one active", %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Three, not four, since task 01a0693e: the mislabeled Canvas tab is gone
      # from the desktop right rail (the card board is the first-class LEFT rail).
      assert count(html, ~s([data-role="call-rail-tab"])) == 3
      assert count(html, ~s([data-role="call-rail-tab"][data-tab="canvas"])) == 0

      for tab <- ~w(people chat transcript) do
        assert count(html, ~s([data-role="call-rail-tab"][data-tab="#{tab}"])) == 1
      end

      assert count(html, ~s([data-role="call-rail-tab"][data-active="true"])) == 1

      assert count(html, ~s([data-role="call-rail-tab"][data-tab="people"][data-active="true"])) ==
               1
    end

    # SCOPED DELIBERATELY. `[data-section="agents"]` is NOT unique on this
    # page — `participant_rail.ex` renders one and the bottom strip has its
    # own sections — so an unscoped assertion would pass or fail for the
    # wrong reason. Every selector here is anchored on the rail.
    test "the People pane holds humans AND agents, inside the rail", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      seed_meeting_presence(space, "agent", "Rail Agent")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      rail = ~s([data-component="call-rail"] )

      assert count(html, rail <> ~s([data-role="call-rail-pane"][data-pane-tab="people"])) == 1
      assert count(html, rail <> ~s([data-component="participant-rail"])) == 1
      assert count(html, rail <> ~s([data-section="humans"])) == 1
      assert count(html, rail <> ~s([data-section="agents"])) == 1
      assert html =~ "Rail Agent"
    end

    test "the agent invite picker is rendered at most once, and only in the rail", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert count(html, ~s([data-role="meeting-agent-invite"])) <= 1

      assert count(html, ~s([data-role="meeting-agent-invite"])) ==
               count(
                 html,
                 ~s([data-component="call-rail"] [data-role="meeting-agent-invite"])
               )
    end

    test "meeting_tab_select swaps the pane", %{conn: conn, meeting: meeting} do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert count(html, ~s([data-role="call-rail-pane"][data-pane-tab="people"])) == 1

      # Canvas is no longer a right-rail tab on desktop (task 01a0693e — the card
      # board is the LEFT rail), so the swap is exercised through Transcript.
      transcript =
        view
        |> element(~s([data-role="call-rail-tab"][data-tab="transcript"]))
        |> render_click()

      assert count(transcript, ~s([data-role="call-rail-pane"][data-pane-tab="transcript"])) == 1
      assert count(transcript, ~s([data-role="call-rail-pane"][data-pane-tab="people"])) == 0

      assert count(
               transcript,
               ~s([data-role="call-rail-tab"][data-tab="transcript"][data-active="true"])
             ) == 1

      # There is NO Canvas tab in the right rail to swap to.
      assert count(transcript, ~s([data-role="call-rail-tab"][data-tab="canvas"])) == 0

      people = render_click(view, "meeting_tab_select", %{"tab" => "people"})
      assert count(people, ~s([data-role="call-rail-pane"][data-pane-tab="people"])) == 1

      # An unrecognised tab costs the tab, not the pane.
      fallback = render_click(view, "meeting_tab_select", %{"tab" => "nope"})
      assert count(fallback, ~s([data-role="call-rail-pane"][data-pane-tab="people"])) == 1
    end

    test "the Transcript tab renders the JS-owned log and an honest empty state", %{
      conn: conn,
      meeting: meeting
    } do
      # `?tab=` deep-link (stage 3) names the pane directly rather than
      # clicking through from the default mount.
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=transcript")

      assert count(html, ~s([data-role="meeting-transcript"])) == 1

      # The container is hook-owned and morphdom-exempt: `meeting:caption`
      # is a client-side DOM CustomEvent that never reaches the server, so
      # the lines exist ONLY in the DOM the hook writes. A LiveView patch
      # without `phx-update="ignore"` would erase the transcript mid-call.
      assert count(
               html,
               ~s([data-role="meeting-transcript"][phx-hook="MeetingTranscript"][phx-update="ignore"])
             ) == 1

      # The empty-state WORDING is not asserted here any more. This describe's
      # setup stashes a LiveKit triple, so under the mount-time
      # `@meetings_enabled` (task 01a0693d) the pane reads "No speech yet…"
      # here — the positive case is pinned under "LiveKit wiring (stage 2)"
      # and the unconfigured NEGATIVE CONTROL lives in
      # `meeting_live_captions_unconfigured_test.exs`, an `async: false`
      # module, because REMOVING the triple from this async module would
      # race every concurrent meeting join.
      #
      # HISTORY, so nobody trusts the old comment: this test used to assert
      # "Captions are unavailable" with a comment claiming the env was
      # unconfigured while sitting in a describe that configures it. It was
      # green anyway, because the value came from `@livekit_url`, which the
      # signed-in path never assigns — the very defect 01a0693d fixed.
      assert count(html, ~s([data-role="transcript-empty"])) == 1
      refute html =~ "Listening"
    end

    # Task 01a06524 stage 1. This REPLACES the "toggling adds/removes
    # `[data-role=meeting-transcript]`" contract the ticket first asked
    # for, deliberately: a host that leaves the DOM on People is a hook
    # LiveView destroys, and a destroyed hook is the whole buffer gone
    # because the reader glanced at the roster. So the host is present
    # exactly once in BOTH tab states and what flips is `hidden` on the
    # outer wrap LiveView owns (under `phx-update="ignore"` a flip on the
    # host itself would never reach the DOM). What this cannot prove is
    # that the browser keeps the lines across the flip — that is the
    # e2e's job, in a real DOM under morphdom.
    test "the transcript host persists across meeting_tab_select and only the wrap hides", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      transcript = render_click(view, "meeting_tab_select", %{"tab" => "transcript"})
      assert count(transcript, ~s([data-role="meeting-transcript"])) == 1
      assert count(transcript, ~s([phx-hook="MeetingTranscript"])) == 1
      assert count(transcript, ~s([data-role="meeting-transcript-wrap"][data-active="true"])) == 1
      assert count(transcript, ~s([data-role="meeting-transcript-wrap"][hidden])) == 0

      people = render_click(view, "meeting_tab_select", %{"tab" => "people"})
      assert count(people, ~s([data-role="meeting-transcript"])) == 1
      assert count(people, ~s([phx-hook="MeetingTranscript"])) == 1

      assert count(people, ~s([data-role="meeting-transcript-wrap"][data-active="false"][hidden])) ==
               1

      # And back: still the one host, revealed again.
      again = render_click(view, "meeting_tab_select", %{"tab" => "transcript"})
      assert count(again, ~s([data-role="meeting-transcript"])) == 1
      assert count(again, ~s([data-role="meeting-transcript-wrap"][hidden])) == 0
    end

    test "the candidate rail is the first-class LEFT rail, once, and NOT in the right rail",
         %{
           conn: conn,
           meeting: meeting
         } do
      # A live candidate so the board component actually materialises — the
      # `candidate_rail` renders NOTHING when it has no card, so a value under a
      # known id is what tells "renders the board" from "renders an empty div".
      {:ok, candidate} =
        Platform.Meetings.Candidates.create(%{
          meeting_id: meeting.id,
          transcript_chunk_id: Ecto.UUID.generate(),
          transcript_chunk_ids: [Ecto.UUID.generate()],
          state: :heard,
          acts_at: nil,
          evidence_quote: "we should add a CSV export"
        })

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # RE-POINTED by task 01a0693e. This used to assert the board lived ONLY in
      # the right rail's Canvas pane (count 0 on the default People tab, then
      # revealed by clicking Canvas). The prototype alignment moved the board to
      # a first-class LEFT rail that is ALWAYS visible on desktop — no tab to
      # select — and dropped the Canvas tab from the right rail entirely.

      # The board is present WITHOUT selecting any tab, carrying this
      # candidate's own card (the `candidate_rail` renders nothing when empty,
      # so a card under a KNOWN id is what proves the board rendered).
      assert count(
               html,
               ~s([data-role="meeting-candidate-card"][data-candidate-id="#{candidate.id}"])
             ) ==
               1

      # It lives in the left rail, not the right (call) rail.
      assert count(
               html,
               ~s([data-role="meeting-left-rail"] [data-role="meeting-candidate-card"][data-candidate-id="#{candidate.id}"])
             ) == 1

      assert count(
               html,
               ~s([data-component="call-rail"] [data-role="meeting-candidate-card"])
             ) == 0

      # And the mislabeled Canvas tab is gone from the right rail.
      assert count(html, ~s([data-role="call-rail-tab"][data-tab="canvas"])) == 0
    end

    test "the desktop left rail shows cards AND agents at once, without a tab (task 01a0693e)",
         %{conn: conn, meeting: meeting, space: space} do
      # The sponsor's core complaint: cards and agents could never be seen
      # together. The left rail restores the prototype's layout — the card board
      # on top, the roster below, both present on first paint with no tab to
      # pick.
      seed_meeting_presence(space, "user", "Ada Human")
      seed_meeting_presence(space, "agent", "Left Rail Agent")

      {:ok, candidate} =
        Platform.Meetings.Candidates.create(%{
          meeting_id: meeting.id,
          transcript_chunk_id: Ecto.UUID.generate(),
          transcript_chunk_ids: [Ecto.UUID.generate()],
          state: :heard,
          acts_at: nil,
          evidence_quote: "rotate the staging secrets"
        })

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      left = ~s([data-role="meeting-left-rail"] )

      # The rail exists, and holds both sections simultaneously.
      assert count(html, ~s([data-role="meeting-left-rail"])) == 1
      assert count(html, left <> ~s([data-role="meeting-left-rail-cards"])) == 1
      assert count(html, left <> ~s([data-role="meeting-left-rail-agents"])) == 1

      # Cards: this candidate's card, present without selecting anything.
      assert count(
               html,
               left <>
                 ~s([data-role="meeting-candidate-card"][data-candidate-id="#{candidate.id}"])
             ) == 1

      # Agents: the same roster component, showing the seeded agent, alongside
      # the board in the same rail.
      assert count(html, left <> ~s([data-component="participant-rail"])) == 1
      assert html =~ "Left Rail Agent"

      # It is a desktop affordance: hidden below `lg`.
      [rail_class] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-left-rail"]))
        |> LazyHTML.attribute("class")

      assert rail_class =~ ~r/\bhidden\b/
      assert rail_class =~ ~r/\blg:flex\b/
    end

    test "the controls are CallShell's, and Share keeps its hook", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert count(html, ~s([data-component="call-controls"])) == 1
      assert count(html, ~s([data-role="meeting-mic"])) == 1
      assert count(html, ~s([data-role="meeting-camera"])) == 1

      # THE ONE `mix test` OTHERWISE CANNOT SEE. `meeting_share_button.js`
      # binds the click on its own element and pushes straight at this
      # LiveView; losing `phx-hook` in the move would leave a Share button
      # that silently never reaches `getDisplayMedia()` inside the gesture.
      share = ~s([data-role="meeting-screen-share"])
      assert count(html, share) == 1

      share_el = html |> frag() |> LazyHTML.query(share)
      assert LazyHTML.attribute(share_el, "phx-hook") == ["MeetingShareButton"]
      assert LazyHTML.attribute(share_el, "id") == ["meeting-share-btn-desktop"]
      assert LazyHTML.attribute(share_el, "phx-click") == ["meeting_toggle_screen_share"]
    end

    # ── Task 01a05b14 stage 2: the controls are UNDER the stage ────────
    #
    # These four tests exist because the previous stage's gates all
    # passed on a screen the sponsor rejected: every control was
    # present and every token correct, but they were wired into the
    # wrong parent. "It renders" is therefore not the assertion; WHERE
    # it renders is.
    test "all four controls render inside the stage column, not in the header", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      for role <- ~w(meeting-mic meeting-camera meeting-screen-share) do
        sel = ~s([data-role="#{role}"])

        assert count(html, ~s([data-pane="center-stage"] #{sel})) == 1,
               "#{role} is not inside the stage column"

        assert count(html, ~s(header #{sel})) == 0,
               "#{role} is still in the top bar"
      end

      # The bar itself is the canvas's `.ctrls`: a centred 46px row,
      # a direct child of the stage column and NOT of the tile area.
      bar = ~s([data-role="meeting-stage-controls"])
      assert count(html, ~s([data-pane="center-stage"] #{bar})) == 1
      assert count(html, ~s([data-role="meeting-stage-body"] #{bar})) == 0

      bar_el = html |> frag() |> LazyHTML.query(bar)
      [class] = LazyHTML.attribute(bar_el, "class")
      assert class =~ "h-[46px]"
      assert class =~ "justify-center"
    end

    test "Leave is in the stage bar too, once the viewer has joined", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      joined = render_click(view, "meeting_join", %{})

      assert count(joined, ~s([data-pane="center-stage"] [data-role="meeting-leave"])) == 1
      assert count(joined, ~s(header [data-role="meeting-leave"])) == 0
    end

    # The controls LEFT the header; the header's OTHER controls did
    # not. A static mockup omitting them is not evidence they should
    # be deleted, and each of these has a live handler behind it.
    test "the header keeps the controls the mockup does not depict", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      html = render_click(view, "meeting_join", %{})

      for role <- ~w(chat-panel-toggle call-rail-toggle meeting-captions-toggle) do
        assert count(html, ~s(header [data-role="#{role}"])) == 1,
               "#{role} was collateral damage of the move"
      end

      assert count(html, ~s(header [data-stage-mode-button])) > 0 or
               count(html, ~s(header [phx-click="set_stage_mode"])) > 0,
             "the stage-mode segmented control left the header"
    end

    # MUTATION-COUNT GUARD SUBJECT, part 1 of 7. Seven
    # `phx-update="ignore"` ids carry JS-owned subtrees;
    # `meeting_client.js` reparents the single persistent local <video>
    # between docks chosen by `matchMedia`, so a rename is invisible to
    # every server-side assertion but fatal in a browser.
    #
    # ONE TEST PER ID, ON PURPOSE. A `for` loop over the seven would
    # abort at the first failing id and report ONE failure for SEVEN
    # breakages, which is precisely the arithmetic the mutation-count
    # guard exists to detect. Six of the seven live on the quickmeet
    # and are pinned the same way in
    # `chat/partials_meeting_panel_test.exs`.
    test "phx-update=ignore id meeting-media survives the move", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      html = render_click(view, "meeting_join", %{})

      assert count(html, ~s(#meeting-media)) == 1
    end
  end

  # ── Persistent local self-view anchor (task 019e42f6) ──────────────────
  #
  # The bug: switching @current_stage_mode remounted the local camera tile
  # (gallery cond arm <-> footer strip), and the JS hook's global
  # `track.detach()` then black-screened the freshly-mounted sibling. The
  # defense-in-depth fix is a dedicated self-view tile that lives OUTSIDE
  # both mode-switched subtrees under `phx-update="ignore"`, so LiveView
  # never destroys/recreates it on a `set_stage_mode` patch. These tests
  # pin the SERVER contract — a single, id-stable `data-role="local-self-view"`
  # node that persists across mode switches. The JS attach/detach lifecycle
  # is covered by the vitest suite + the e2e_behavior gate (a LiveViewTest
  # render does NOT exercise the JS hook, per ORG_MEMORY).
  describe "local self-view anchor (task 019e42f6)" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "kickoff-selfview", name: "Self View"})
      {conn, user} = authenticated_conn(conn)

      # Add the viewer as a chat participant keyed by `user.id` so
      # `find_participant/2` resolves `@current_participant` (still the
      # chat-membership row — it drives the LiveKit identity), and as a
      # LIVE meeting presence row so the viewer appears in `@participants`
      # (now sourced from `Meetings.active_participants_for_space/1`). Both
      # carry `user.id`, so `gallery_identity/1` aligns the self-view dock
      # to the viewer's gallery/strip tile.
      {:ok, _participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: "Self View User",
          joined_at: DateTime.utc_now()
        })

      {:ok, room} = Platform.Meetings.ensure_room(space.id)
      {:ok, room} = Platform.Meetings.activate_room(room)

      {:ok, _presence} =
        Platform.Meetings.participant_joined(room, %{
          user_id: user.id,
          display_name: "Self View User"
        })

      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "renders exactly one local-self-view PARKING node, hidden and id-stable", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Exactly one self-view parking slot.
      assert length(String.split(html, ~s(data-role="local-self-view"))) - 1 == 1

      # v2: the parking slot keeps its stable id + phx-update="ignore" so the
      # MeetingClient hook owns a never-unmounted node — but it no longer
      # renders the v1 inner self-view tile, and it is hidden / off-layout
      # (no visible bottom-right PiP positioning classes).
      assert html =~ ~s(id="meeting-local-self-view")
      assert html =~ ~s(phx-update="ignore")

      parking_tag =
        Regex.run(~r/<div[^>]*data-role="local-self-view"[^>]*>/, html) |> List.first()

      assert parking_tag =~ "hidden", "parking slot should be hidden, got: #{parking_tag}"
      # The v1 floating-PiP positioning is gone (no fixed bottom-right anchor).
      refute parking_tag =~ "bottom-["
      refute parking_tag =~ "aspect-video"
      # No inner self-view tile is rendered into the parking slot anymore.
      refute html =~ ~s(id="local-self-view-user:)
    end

    test "the self-view parking node persists with an unchanged id across gallery/screen/canvas switches",
         %{conn: conn, meeting: meeting} do
      {:ok, view, gallery_html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert gallery_html =~ ~s(id="meeting-local-self-view")

      screen_html =
        view |> element(~s([data-stage-mode-button="screen"])) |> render_click()

      assert screen_html =~ ~s(id="meeting-local-self-view")
      assert screen_html =~ ~s(data-role="local-self-view")

      canvas_html =
        view |> element(~s([data-stage-mode-button="canvas"])) |> render_click()

      assert canvas_html =~ ~s(id="meeting-local-self-view")

      back_to_gallery =
        view |> element(~s([data-stage-mode-button="gallery"])) |> render_click()

      assert back_to_gallery =~ ~s(id="meeting-local-self-view")
    end

    test "gallery mode renders exactly one gallery dock for the local participant", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Default mode is gallery → the local cell carries one gallery dock.
      gallery_docks =
        Regex.scan(~r/data-local-video-dock[^>]*data-dock-mode="gallery"/, html) |> length()

      assert gallery_docks == 1, "expected exactly one gallery dock, got #{gallery_docks}"

      # The local tile is flagged so MeetingVideoTile skips its self-attach.
      assert html =~ ~s(data-local-dock="true")
    end

    test "canvas/screen/whiteboard render a strip dock for the local participant", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      for mode <- ~w(canvas screen whiteboard) do
        html =
          view |> element(~s([data-stage-mode-button="#{mode}"])) |> render_click()

        strip_docks =
          Regex.scan(~r/data-local-video-dock[^>]*data-dock-mode="strip"/, html) |> length()

        assert strip_docks == 1,
               "expected exactly one strip dock in #{mode} mode, got #{strip_docks}"
      end
    end

    test "omits the self-view when the viewer has no participant row", %{conn: conn} do
      # Fresh meeting + user with NO participant row → @current_participant
      # is nil → self-view renders nothing.
      {meeting, _space} = create_meeting(%{slug: "kickoff-no-selfview", name: "No Self"})
      {conn, _user} = authenticated_conn(conn)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      refute html =~ ~s(data-role="local-self-view")
    end
  end

  # ── Live presence bridge (task 019e4b3e — "Participant List not reflective") ─
  #
  # The rail/count must source from LIVE meeting presence
  # (Meetings.active_participants_for_space/1) — preloaded :user/:agent,
  # left_at-filtered — NOT from durable Chat membership (whose nil
  # display_names render as the literal "User" and whose count is wrong).
  describe "build_meeting_participants/1 + resolve_identity/1" do
    alias Platform.Meetings.Participant, as: MeetingParticipant
    alias PlatformWeb.MeetingLive

    test "resolve_identity/1 prefers the preloaded user name and avatar" do
      p = %MeetingParticipant{
        user: %User{name: "Ada Lovelace", email: "ada@example.com", avatar_url: "/a.png"},
        display_name: "stale join name"
      }

      assert {"Ada Lovelace", "/a.png"} = MeetingLive.resolve_identity(p)
    end

    test "resolve_identity/1 falls back to join display_name then email" do
      p_email = %MeetingParticipant{
        user: %User{name: nil, email: "grace@example.com", avatar_url: nil},
        display_name: nil
      }

      assert {"grace@example.com", nil} = MeetingLive.resolve_identity(p_email)

      p_join = %MeetingParticipant{
        user: %User{name: nil, email: nil, avatar_url: nil},
        display_name: "Joined As"
      }

      assert {"Joined As", nil} = MeetingLive.resolve_identity(p_join)
    end

    test "resolve_identity/1 uses the agent name for agent rows" do
      p = %MeetingParticipant{
        agent: %Platform.Agents.Agent{name: "Helper Bot"},
        display_name: nil
      }

      assert {"Helper Bot", nil} = MeetingLive.resolve_identity(p)
    end

    # ── Agent avatars (task 01a00122 stage 4) ──────────────────────────────
    #
    # This clause used to return a LITERAL `{name, nil}`: `meetings.participants`
    # has no `avatar_url` column, so the rail's agent section
    # (participant_rail.ex:157) passed a structurally-guaranteed nil and every
    # agent rendered as an initial. The avatar now comes off the preloaded
    # `%Agent{}` — `Meetings.active_participants/1` preloads `[:user, :agent]`
    # — WITHOUT adding a column to the participant row, which would denormalise
    # a mutable field onto every presence row in every meeting.
    test "resolve_identity/1 returns the AGENT'S avatar_url where it once hardcoded nil" do
      p = %MeetingParticipant{
        agent: %Platform.Agents.Agent{
          name: "Helper Bot",
          avatar_url: "/agents/de305d54/avatar?v=GKHEI"
        },
        display_name: nil
      }

      assert {"Helper Bot", avatar_url} = MeetingLive.resolve_identity(p)

      assert avatar_url == "/agents/de305d54/avatar?v=GKHEI",
             "agent avatar must resolve from the preloaded agent row, got: " <>
               inspect(avatar_url)
    end

    test "resolve_identity/1 passes the ?v= cache token through verbatim" do
      # The serving route is stable across re-uploads, so the query string IS
      # the cache-buster. Stripping or re-encoding it pins viewers to a stale
      # image.
      url = "/agents/abc123/avatar?v=aB3-_x9"

      p = %MeetingParticipant{
        agent: %Platform.Agents.Agent{name: "Cache Bot", avatar_url: url},
        display_name: nil
      }

      assert {"Cache Bot", ^url} = MeetingLive.resolve_identity(p)
    end

    test "resolve_identity/1 gives an agent with no avatar nil, not an empty string" do
      p_nil = %MeetingParticipant{
        agent: %Platform.Agents.Agent{name: "Bare Bot", avatar_url: nil},
        display_name: nil
      }

      assert {"Bare Bot", nil} = MeetingLive.resolve_identity(p_nil)

      p_blank = %MeetingParticipant{
        agent: %Platform.Agents.Agent{name: "Blank Bot", avatar_url: "   "},
        display_name: nil
      }

      assert {"Blank Bot", avatar_url} = MeetingLive.resolve_identity(p_blank)

      assert avatar_url == nil,
             "a blank column must normalise to nil rather than reach the render " <>
               "layer as junk, got: " <> inspect(avatar_url)
    end

    test "resolve_identity/1 still prefers the agent name over the stale join name" do
      # The avatar change must not disturb the name-precedence contract.
      p = %MeetingParticipant{
        agent: %Platform.Agents.Agent{name: "Real Name", avatar_url: "/agents/x/avatar?v=1"},
        display_name: "stale join name"
      }

      assert {"Real Name", "/agents/x/avatar?v=1"} = MeetingLive.resolve_identity(p)
    end

    test "meeting_participant_view_model exposes the agent avatar on the rail view-model" do
      # The rail reads `p.avatar_url` off this map (participant_rail.ex:157),
      # so the seam has to survive the wrapping, not just resolve_identity/1.
      agent = %Platform.Agents.Agent{
        id: "11111111-1111-1111-1111-111111111111",
        name: "Rail Bot",
        avatar_url: "/agents/11111111/avatar?v=RAIL"
      }

      p = %MeetingParticipant{
        id: "22222222-2222-2222-2222-222222222222",
        agent_id: agent.id,
        agent: agent,
        user_id: nil,
        user: nil,
        display_name: nil,
        metadata: %{"identity" => "agent:" <> agent.id}
      }

      vm = MeetingLive.meeting_participant_view_model(p)

      assert vm.participant_type == "agent"
      assert vm.participant_id == agent.id
      assert vm.display_name == "Rail Bot"
      assert vm.avatar_url == "/agents/11111111/avatar?v=RAIL"
    end

    test "resolve_identity/1 returns nil display_name for a genuinely-unknown row" do
      # Orphaned presence row: user/agent not loaded, no join name. The
      # render layer (not this fn) supplies the honest "Unknown participant".
      p = %MeetingParticipant{user: nil, agent: nil, display_name: nil}
      assert {nil, nil} = MeetingLive.resolve_identity(p)
    end

    # ── Guest-shape presence rows (task 019f2483 e2e cases 3 + 4) ──────────
    #
    # Guests join via the signed guest-invite URL: the LiveKit webhook upserts
    # a Meetings.Participant with `user_id: nil AND agent_id: nil AND
    # display_name: "<name> (guest)"`. The catch-all previously nilled the
    # name out, which (a) rendered "Unknown participant" on the rail and
    # (b) starved `via_guest_link?/1` of the " (guest)" suffix it needs to
    # emit the "via guest link" sub-line. The guest-shape clause must fire
    # BEFORE the catch-all and preserve the join name.
    test "resolve_identity/1 preserves guest display_name for guest-shape rows" do
      p = %MeetingParticipant{
        user_id: nil,
        agent_id: nil,
        user: nil,
        agent: nil,
        display_name: "Ada (guest)"
      }

      assert {"Ada (guest)", nil} = MeetingLive.resolve_identity(p)
    end

    test "resolve_identity/1 trims whitespace-only guest display_name to nil" do
      p = %MeetingParticipant{
        user_id: nil,
        agent_id: nil,
        user: nil,
        agent: nil,
        display_name: "   "
      }

      assert {nil, nil} = MeetingLive.resolve_identity(p)
    end

    test "resolve_identity/1 returns nil for empty-string guest display_name" do
      p = %MeetingParticipant{
        user_id: nil,
        agent_id: nil,
        user: nil,
        agent: nil,
        display_name: ""
      }

      assert {nil, nil} = MeetingLive.resolve_identity(p)
    end

    test "resolve_identity/1 does not fire guest clause for user rows with nil display_name" do
      # A row that has a real user preload but nil display_name must hit
      # the user clause (which falls back to email), NOT the new guest
      # clause. Regression guard: pattern-match specificity requires
      # `user_id: nil` AND `agent_id: nil` to trigger the guest path.
      p = %MeetingParticipant{
        user_id: "u_1",
        agent_id: nil,
        user: %User{name: nil, email: "grace@example.com", avatar_url: nil},
        display_name: nil
      }

      assert {"grace@example.com", nil} = MeetingLive.resolve_identity(p)
    end

    test "resolve_identity/1 does not fire guest clause for agent rows" do
      # Agent row with a display_name still resolves via the agent-preload
      # clause; the guest clause requires `agent_id: nil`.
      p = %MeetingParticipant{
        user_id: nil,
        agent_id: "a_1",
        user: nil,
        agent: %Platform.Agents.Agent{name: "Helper Bot"},
        display_name: "Some Stale Name"
      }

      assert {"Helper Bot", nil} = MeetingLive.resolve_identity(p)
    end

    test "via_guest_link?/1 fires on the resolved guest display_name" do
      # End-to-end assertion: guest-shape row → resolve_identity keeps the
      # " (guest)" suffix → via_guest_link? returns true → rail sub-line
      # renders. This is the seam that cases 3 + 4 fail on when broken.
      p = %MeetingParticipant{
        user_id: nil,
        agent_id: nil,
        user: nil,
        agent: nil,
        display_name: "Grace (guest)"
      }

      {display_name, _avatar} = MeetingLive.resolve_identity(p)
      assert MeetingLive.via_guest_link?(%{display_name: display_name})
    end

    test "build_meeting_participants/1 returns [] for nil space" do
      assert MeetingLive.build_meeting_participants(nil) == []
    end
  end

  describe "MeetingLive @participants sourced from live presence" do
    alias Platform.Meetings

    # Seed an ACTIVE room for the space and join `users` as live
    # participants. Returns the list of inserted Meetings.Participant rows.
    defp seed_active_participants(space, users) do
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)

      Enum.map(users, fn user ->
        {:ok, p} =
          Meetings.participant_joined(room, %{
            user_id: user.id,
            display_name: user.name
          })

        p
      end)
    end

    defp seed_user(name) do
      Repo.insert!(%User{
        email: "live_#{System.unique_integer([:positive])}@example.com",
        name: name,
        oidc_sub: "oidc-live-#{System.unique_integer([:positive])}"
      })
    end

    test "rail renders real participant names and the live count, not \"User\"",
         %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "kickoff-live", name: "Kickoff Live"})
      ada = seed_user("Ada Lovelace")
      grace = seed_user("Grace Hopper")
      seed_active_participants(space, [ada, grace])

      {conn, _viewer} = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert html =~ "Ada Lovelace"
      assert html =~ "Grace Hopper"

      # Resolved rows must carry real names — the blanket "User" fallback
      # (the bug symptom) must NOT appear in any participant-name span.
      names =
        :sys.get_state(view.pid).socket.assigns.participants
        |> Enum.map(& &1.display_name)

      assert "Ada Lovelace" in names
      assert "Grace Hopper" in names
      refute "User" in names

      # Count assign reflects the live presence set (2), not membership.
      assert length(:sys.get_state(view.pid).socket.assigns.participants) == 2
    end

    test "left_at participants are excluded from the live set", %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "kickoff-left", name: "Kickoff Left"})
      ada = seed_user("Ada Lovelace")
      grace = seed_user("Grace Hopper")
      [_ada_row, grace_row] = seed_active_participants(space, [ada, grace])

      # Grace leaves.
      grace_row
      |> Platform.Meetings.Participant.changeset(%{left_at: DateTime.utc_now()})
      |> Repo.update!()

      {conn, _viewer} = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert html =~ "Ada Lovelace"
      refute html =~ "Grace Hopper"
      assert length(:sys.get_state(view.pid).socket.assigns.participants) == 1
    end

    test "a participant_left broadcast live-decrements the rail without reload",
         %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "kickoff-decr", name: "Kickoff Decr"})
      ada = seed_user("Ada Lovelace")
      grace = seed_user("Grace Hopper")
      seed_active_participants(space, [ada, grace])

      {conn, _viewer} = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert length(:sys.get_state(view.pid).socket.assigns.participants) == 2

      # Grace leaves via the context, which broadcasts {:participant_left, _}
      # on the room topic AND a presence update on the space topic.
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, _} = Meetings.participant_left(room, "Grace Hopper")

      # Let the LV process the broadcast.
      _ = render(view)
      Process.sleep(50)
      html = render(view)

      assert html =~ "Ada Lovelace"
      refute html =~ "Grace Hopper"
      assert length(:sys.get_state(view.pid).socket.assigns.participants) == 1
    end

    test "an orphaned (nil user) presence row renders \"Unknown participant\" without poisoning resolved rows",
         %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "kickoff-orphan", name: "Kickoff Orphan"})
      ada = seed_user("Ada Lovelace")

      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)

      # Ada resolves normally.
      {:ok, _} = Meetings.participant_joined(room, %{user_id: ada.id, display_name: ada.name})

      # Orphaned row: a presence row pointing at a user account that has
      # since been deleted. The preload returns a nil `:user`, so
      # `resolve_identity/1` yields nil and the render labels it honestly
      # as "Unknown participant" rather than trusting the stale join name.
      ghost =
        Repo.insert!(%User{
          email: "ghost_#{System.unique_integer([:positive])}@example.com",
          name: "Stale Ghost Name",
          oidc_sub: "oidc-ghost-#{System.unique_integer([:positive])}"
        })

      {:ok, _} =
        Meetings.participant_joined(room, %{user_id: ghost.id, display_name: "Stale Ghost Name"})

      Repo.delete!(ghost)

      {conn, _viewer} = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert html =~ "Ada Lovelace"
      assert html =~ "Unknown participant"
      # The stale join name of the deleted account is NOT trusted.
      refute html =~ "Stale Ghost Name"
    end
  end

  # ── Closed captions (task 019f3f17 stage 1) ─────────────────────────
  #
  # Gating: the CC toggle button only renders while the viewer is joined
  # (mirrors the Leave-button gate) because captions come from the
  # LiveKit transcription stream, which only flows during an active
  # session. In tests the connected mount auto-joins, so
  # `:in_meeting=true` and the button is present. The overlay
  # (`#meeting-captions` + `MeetingCaptions` hook) is `:if`-gated on
  # `:captions_visible`, which defaults to false — so it's absent at
  # mount and appears only after the toggle.
  # The CC toggle's rendered class tokens. `LazyHTML.query/2` (never
  # `filter/2` — `filter/2` matches only the fragment's ROOT nodes, so
  # this nested button would come back `[]` and read as "not there")
  # then `attribute/2`, so the assertion is made against the extracted
  # string and not against the always-truthy `%LazyHTML{}` struct.
  defp captions_toggle_classes(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="meeting-captions-toggle"]))
    |> LazyHTML.attribute("class")
    |> case do
      [class] -> String.split(class)
      other -> flunk("expected exactly one CC toggle, got: #{inspect(other)}")
    end
  end

  describe "closed captions (stage 1)" do
    setup %{conn: conn} do
      # The CC toggle button is `<%= if @in_meeting do %>` gated
      # (captions come from the LiveKit stream, which only flows during
      # an active session), so the same LiveKit-env stub the
      # "LiveKit wiring" describe uses is needed here — otherwise
      # auto-join hits `:livekit_not_configured` and `:in_meeting`
      # stays false, and the toggle never renders.
      original = Application.get_env(:platform, :livekit, [])

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: "test-livekit-secret-0123456789abcdef",
        url: "wss://livekit.test"
      )

      on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

      {meeting, space} = create_meeting(%{slug: "cc-stage-1", name: "CC Stage 1"})
      {conn, user} = authenticated_conn(conn)

      # Seed the viewer as a chat-space participant so MeetingHooks.do_join
      # can resolve `:current_participant` and reach the successful
      # `{:ok, token}` branch that flips `:in_meeting=true`.
      {:ok, _participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: "CC Viewer",
          joined_at: DateTime.utc_now()
        })

      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "captions overlay is absent at mount (default off)", %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # The `MeetingCaptions` hook is only mounted when the viewer has
      # toggled captions on — at rest it's neither in the DOM nor
      # binding document-level listeners.
      refute html =~ ~s(data-role="meeting-captions")
    end

    test "CC toggle button renders with aria-pressed=false when joined", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Wait for the auto-join push_event to land before asserting the
      # in-meeting UI — `assert_push_event/3` blocks the test process
      # until the LV mailbox drains the join-meeting broadcast, which
      # is what flips `:in_meeting=true`. Same pattern as the
      # LiveKit-wiring "auto-joins on connected mount" test.
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})
      html = render(view)

      # The CC toggle is present with the initial "off" state — attributes
      # rendered separately since Phoenix templates emit them in the order
      # the HEEX declares them (aria-pressed comes BEFORE data-role in the
      # rendered `<button>`), so a single `[^>]*` regex spanning both would
      # need the wildcard to cross the leading edge of the attribute.
      assert html =~ ~s(data-role="meeting-captions-toggle")
      assert html =~ ~s(data-active="false" class=)
      assert html =~ ~s(aria-pressed="false" title="Show captions")
      assert html =~ ~s(aria-label="Show captions")
    end

    test "clicking the CC toggle flips :captions_visible and mounts the overlay",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      html =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()

      # Button flipped to pressed, overlay + hook now in the DOM.
      assert html =~ ~s(data-role="meeting-captions-toggle")
      assert html =~ ~s(data-active="true" class=)
      assert html =~ ~s(aria-pressed="true" title="Hide captions")
      assert html =~ ~s(id="meeting-captions")
      assert html =~ ~s(phx-hook="MeetingCaptions")
      assert html =~ ~s(data-role="meeting-captions")

      # Task 019ff712 stage 2 — MeetingLive still mounts the hook exactly
      # ONCE with captions on. That stage collapsed the quick-meet panel's
      # two hosts into one; /meetings is a genuinely different render
      # path, so its host contract has to be asserted here rather than
      # inferred from the quick-meet test. Counted with LazyHTML because
      # `LazyHTML.query/2` returns a struct and is never falsy.
      hosts =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([phx-hook="MeetingCaptions"]))
        |> Enum.count()

      assert hosts == 1

      # Server-push mirrored to localStorage by the hook: assert the
      # meeting_captions_persist event landed.
      assert_push_event(view, "meeting_captions_persist", %{visible: true})
    end

    # Task 01a0740e stage 1 — the CC toggle's OFF and ON colour states.
    #
    # SURFACE: this mounts `~p"/meetings/#{slug}"` on the DEFAULT host,
    # i.e. `@shell? == true`. The control is NOT `@shell?`-gated (only
    # the breadcrumb and guest-link controls are) so it renders on the
    # `meet.` guest surface too; the default host is chosen so the
    # assertion cannot pass by accident on a surface that would have
    # rendered the button either way.
    #
    # Asserted on the EXTRACTED attribute, never on the query result:
    # `LazyHTML.query/2` returns a truthy `%LazyHTML{}` even with zero
    # matched nodes (and `length/1` raises on it), so a `refute` against
    # the struct would pass on an element that is not there at all.
    test "CC toggle: off is base-content/70, on is a base-300 pressed ground", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      # Split into whole class tokens rather than substring-matching:
      # `"text-base-content" =~` is satisfied by `text-base-content/70`,
      # so a substring assertion on the ON state would pass unchanged if
      # someone reverted the OFF token onto it.
      off = captions_toggle_classes(render(view))

      # Positive: off is /70, the "available and off" treatment.
      assert "text-base-content/70" in off

      # Negative, and the point of the change: `/40` is the treatment a
      # DISABLED control gets. While the off state wore it, "captions
      # work here and are off" and "captions cannot work here" looked
      # identical. `/40` is reclaimed for genuinely-unavailable, and this
      # control has no unavailable state, so it must not reappear here.
      refute "text-base-content/40" in off

      on =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()
        |> captions_toggle_classes()

      # ON is a PRESSED treatment — a filled `base-300` ground with a
      # `base-content` foreground — so the button reads as depressed.
      assert "bg-base-300" in on
      assert "text-base-content" in on

      # Negative: NOT the brand colour. Every other control in this row
      # is already cyan, so `text-primary` read as one more action
      # rather than as state. Semantic slots only, and no raw hex.
      refute "text-primary" in on
      refute Enum.any?(on, &String.contains?(&1, "#"))
    end

    test "clicking the CC toggle twice returns to hidden state", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      view
      |> element(~s([data-role="meeting-captions-toggle"]))
      |> render_click()

      html =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()

      # Overlay withdrawn, button back to unpressed.
      refute html =~ ~s(data-role="meeting-captions")
      assert html =~ ~s(aria-pressed="false" title="Show captions")
      assert_push_event(view, "meeting_captions_persist", %{visible: false})
    end

    test "meeting_captions_hydrate restores state from a bool payload", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      # The JS hook fires this on mount when a stored value differs
      # from the current assign. `true` should flip the assign +
      # render the overlay.
      html = render_hook(view, "meeting_captions_hydrate", %{"visible" => true})

      assert html =~ ~s(id="meeting-captions")
      assert html =~ ~s(aria-pressed="true" title="Hide captions")

      # Idempotent: firing hydrate again with the same value is a no-op.
      html = render_hook(view, "meeting_captions_hydrate", %{"visible" => true})
      assert html =~ ~s(id="meeting-captions")

      # And hydrating to false hides the overlay.
      html = render_hook(view, "meeting_captions_hydrate", %{"visible" => false})
      refute html =~ ~s(data-role="meeting-captions")
    end

    test "CC toggle button is hidden when the viewer isn't joined", %{
      conn: conn,
      meeting: meeting
    } do
      # `?no_autojoin=true` short-circuits the auto-join, so :in_meeting
      # stays false and the CC toggle stays out of the top bar. Captions
      # come from the LiveKit session; there's nothing to render before
      # a join.
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      refute html =~ ~s(data-role="meeting-captions-toggle")
    end

    test "CC glyph mirrors shell.html.heex CC svg (no emoji)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})
      html = render(view)

      # The SVG path from shell.html.heex:253 — mirroring the shell CC
      # button so the visual language stays consistent (Rowan's hero
      # icons-only rule). No emoji anywhere in the caption UI.
      assert html =~ "M2 5a2 2 0 012-2h16a2 2 0 012 2v10a2 2 0 01-2 2H6l-4 4V5z"
    end
  end

  # ── Closed captions (task 019f3f17 stage 2) ─────────────────────────
  #
  # Stage 2's per-speaker overlay slots are GONE (task 019ff712 stage 3) —
  # what remains here are the two fold-in review fixes from stage 1 plus the
  # assertion that gallery has no per-tile slot and DOES have the bar:
  #
  #   1. Persistence host div is mounted OUTSIDE the `:if @captions_visible`
  #      gate so localStorage restore survives a reload with the server
  #      default `false`. Verified by the presence of
  #      `#meeting-captions-persist-host` on mount before any toggle.
  #   2. Caption bar z-index bumped from `z-30` to `z-40` so it paints
  #      above the sticky mobile bottom-nav (which sits at `z-30`).
  #
  describe "closed captions (no per-tile overlays)" do
    setup %{conn: conn} do
      # Reuse the stage-1 LiveKit env stub so `:in_meeting=true` after
      # auto-join and the CC toggle button is reachable.
      original = Application.get_env(:platform, :livekit, [])

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: "test-livekit-secret-0123456789abcdef",
        url: "wss://livekit.test"
      )

      on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

      {meeting, space} = create_meeting(%{slug: "cc-stage-2", name: "CC Stage 2"})
      {conn, user} = authenticated_conn(conn)

      {:ok, _participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: "CC Viewer",
          joined_at: DateTime.utc_now()
        })

      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "persistence host mounts outside the `:if @captions_visible` gate", %{
      conn: conn,
      meeting: meeting
    } do
      # Stage 1 review finding: localStorage restore lived in the
      # MeetingCaptions hook, which mounted on `#meeting-captions` — a
      # div gated on `:if={@captions_visible}`. On reload with the server
      # default `false`, that div wasn't in the DOM, so the restore
      # branch never ran. Stage 2 splits persistence into a separate
      # always-mounted host — assert it's present at rest.
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # Captions off by default, so the overlay itself is absent…
      refute html =~ ~s(data-role="meeting-captions")
      # …but the persistence host div renders regardless of the toggle
      # so localStorage-restore can fire on mount and flip the assign
      # before the toggle button is even reachable.
      assert html =~ ~s(id="meeting-captions-persist-host")
      assert html =~ ~s(phx-hook="MeetingCaptionsPersist")
      assert html =~ ~s(data-persist-key="suite.meeting.captions_visible")
    end

    test "persistence host survives the CC toggle (still present when captions visible)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      # Toggle CC on and re-render.
      html =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()

      # The overlay is now in the DOM AND the persistence host is still
      # there — the two are independent, and morphdom mustn't wipe one
      # when the other's gate flips.
      assert html =~ ~s(id="meeting-captions-persist-host")
      assert html =~ ~s(id="meeting-captions")
    end

    test "caption bar paints at z-40 (above the sticky mobile bottom-nav at z-30)", %{
      conn: conn,
      meeting: meeting
    } do
      # Stage 1 review finding: the 3-line caption bar was at `z-30`,
      # colliding with the mobile bottom-nav rail (also `z-30`) on narrow
      # viewports. Bump to `z-40` guarantees the caption bar wins the
      # z-order.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      html =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()

      # The caption bar's OUTER positioning shell carries `z-40` (was
      # `z-30` in stage 1). Task 019f43e4 stage 1 split the caption bar
      # into an outer positioning shell (`data-role="meeting-captions-shell"`)
      # and an inner stable hook host (`#meeting-captions`) so the outer
      # can carry a dynamic `hidden` class through `phx-update="ignore"`.
      # The z-index has to live on the positioning shell for the CSS to
      # take effect (z-index only applies to positioned elements).
      assert html =~ ~r/data-role="meeting-captions-shell"[^>]*z-40/
      refute html =~ ~r/data-role="meeting-captions-shell"[^>]*\bz-30\b/
    end

    test "gallery with CC on: zero caption slots AND one un-hidden consolidated bar", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      # BOTH halves in one test, deliberately. Task 019ff712 stage 3 deleted
      # the per-tile `[data-caption-slot]` overlay AND removed the
      # `@current_stage_mode == :gallery && "hidden"` class that suppressed
      # the consolidated bar. Half (a) alone is satisfied by simply deleting
      # every caption surface in gallery — half (b) is what makes it an
      # assertion about captions rather than about their absence.
      {_ada, _} = seed_meeting_presence(space, "user", "Ada Lovelace")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      html =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.current_stage_mode == :gallery
      doc = LazyHTML.from_fragment(html)

      # Anti-vacuity: a gallery tile really rendered, so (a) is a statement
      # about the overlay and not about an empty gallery.
      assert doc |> LazyHTML.query(~s([data-participant])) |> Enum.count() > 0

      # (a) zero per-tile caption slots.
      assert doc |> LazyHTML.query(~s([data-caption-slot])) |> Enum.count() == 0

      # (b) exactly one consolidated bar host, and its shell is NOT hidden.
      assert doc |> LazyHTML.query(~s([data-role="meeting-captions"])) |> Enum.count() == 1

      shell_classes =
        doc
        |> LazyHTML.query(~s([data-role="meeting-captions-shell"]))
        |> LazyHTML.attribute("class")

      assert [shell_class] = shell_classes

      refute "hidden" in String.split(shell_class),
             "consolidated caption bar must render in gallery; class list was: #{shell_class}"
    end

    test "the shell's positioning classes are pinned in gallery AND canvas", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      # Task 019ff712 stage 4. Three separate regressions this pins, each of
      # which a later refactor could reintroduce silently:
      #
      #   1. the gallery-specific `hidden` class coming back (refuted on the
      #      GALLERY render specifically — the canvas assert below cannot see
      #      it, which is why there is one assertion per side);
      #   2. either of the two offset terms being dropped —
      #      `env(safe-area-inset-bottom)` (the iOS home indicator) or
      #      `var(--bottom-nav-height,0px)` (the mobile bottom-nav rail).
      #      NEITHER is observable in a headless screenshot: headless Chrome
      #      reports a zero safe-area inset and the nav var is 0 on desktop,
      #      so this render assertion is the only thing that can see them;
      #   3. the offset becoming mode-conditional. The exact same class
      #      string is asserted in gallery and in canvas — one caption
      #      surface means one position, not a per-mode position.
      {_ada, _} = seed_meeting_presence(space, "user", "Ada Lovelace")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      gallery_html =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.current_stage_mode == :gallery

      offset =
        "bottom-[calc(1.75rem+env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))]"

      gallery_class = caption_bar_shell_class(gallery_html)

      assert gallery_class =~ offset,
             "gallery caption shell lost its offset; class list was: #{gallery_class}"

      assert gallery_class =~ "env(safe-area-inset-bottom)"
      assert gallery_class =~ "var(--bottom-nav-height,0px)"
      assert gallery_class =~ "fixed"
      assert gallery_class =~ "left-1/2"
      assert gallery_class =~ "-translate-x-1/2"

      # One assertion per side: the canvas case below cannot observe a
      # `hidden` that only gallery renders.
      refute "hidden" in String.split(gallery_class),
             "caption shell must not be hidden in gallery; class list was: #{gallery_class}"

      canvas_html = render_click(view, "set_stage_mode", %{"mode" => "canvas"})
      canvas_class = caption_bar_shell_class(canvas_html)

      assert canvas_class =~ offset,
             "canvas caption shell lost its offset; class list was: #{canvas_class}"

      refute "hidden" in String.split(canvas_class),
             "caption shell must not be hidden in canvas; class list was: #{canvas_class}"

      # The placement is SHARED, so the two class lists are identical.
      assert gallery_class == canvas_class,
             "caption placement must not branch on stage mode; gallery=#{gallery_class} canvas=#{canvas_class}"
    end

    test "no caption slot renders in the bottom strip either", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {_ada, _} = seed_meeting_presence(space, "user", "Ada Lovelace")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      view
      |> element(~s([data-role="meeting-captions-toggle"]))
      |> render_click()

      html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      assert html =~ ~s(data-pane="bottom-strip")
      refute html =~ ~s(data-caption-slot)
    end

    test "with CC off the consolidated bar is absent from the DOM", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      # The `:if={@captions_visible}` gate is untouched by stage 3 — removing
      # the `hidden` class must not turn the bar into an always-on element.
      {_ada, _} = seed_meeting_presence(space, "user", "Ada Lovelace")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      refute html =~ ~s(data-role="meeting-captions")
      refute html =~ ~s(data-caption-slot)
    end

    test "toggling CC off withdraws the consolidated bar in gallery", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {_ada, _} = seed_meeting_presence(space, "user", "Ada Lovelace")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      html =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()

      assert html =~ ~s(data-role="meeting-captions-shell")

      html =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()

      refute html =~ ~s(data-role="meeting-captions-shell")
    end
  end

  # ── Caption bar / gallery interaction (task 019f43e4 stage 1) ─────────
  #
  # Gallery used to hide the consolidated bar with a `hidden` class because
  # it had per-tile caption overlays instead. Those overlays are gone (task
  # 019ff712 stage 3) and the class went with them: the bar is now the ONE
  # caption surface in EVERY stage mode. These tests pin that the class list
  # carries no `hidden` in any mode, while `data-stage-mode` still mirrors
  # the assign so CDP e2e can query it. The canvas / screen / whiteboard
  # cases are the control — they worked before this change and must be
  # byte-for-byte unaffected by it.
  describe "caption bar / stage mode interaction" do
    setup %{conn: conn} do
      # Same LiveKit env stub the other caption describe blocks use —
      # captions come from the LiveKit stream, so `:in_meeting=true` must
      # be reachable for the CC toggle to render.
      original = Application.get_env(:platform, :livekit, [])

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: "test-livekit-secret-0123456789abcdef",
        url: "wss://livekit.test"
      )

      on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

      {meeting, space} = create_meeting(%{slug: "cc-gallery-dedup", name: "CC Gallery Dedup"})
      {conn, user} = authenticated_conn(conn)

      {:ok, _participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: "CC Viewer",
          joined_at: DateTime.utc_now()
        })

      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "caption bar renders WITHOUT `hidden` class in gallery mode when captions on",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      html =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()

      # Gallery is the default mount mode.
      assert :sys.get_state(view.pid).socket.assigns.current_stage_mode == :gallery

      tag = caption_bar_shell_open_tag(html)

      assert tag,
             ~s(expected `[data-role="meeting-captions-shell"]` element to render when captions are on)

      # Bar carries the mode attribute and NO `hidden` class.
      assert tag =~ ~s(data-stage-mode="gallery")

      refute tag =~ ~r/\bhidden\b/,
             "caption bar must render in gallery mode; got: #{tag}"

      # The host div is in the DOM and the hook is mounted on it.
      assert html =~ ~s(id="meeting-captions")
      assert html =~ ~s(phx-hook="MeetingCaptions")
    end

    test "caption bar renders WITHOUT `hidden` class in canvas mode",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      view
      |> element(~s([data-role="meeting-captions-toggle"]))
      |> render_click()

      html = render_click(view, "set_stage_mode", %{"mode" => "canvas"})

      tag = caption_bar_shell_open_tag(html)
      assert tag, ~s(expected `[data-role="meeting-captions-shell"]` element in canvas mode)
      assert tag =~ ~s(data-stage-mode="canvas")

      refute tag =~ ~r/\bhidden\b/,
             "caption bar must NOT carry `hidden` outside gallery mode; got: #{tag}"
    end

    test "caption bar renders WITHOUT `hidden` class in screen and whiteboard modes",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      view
      |> element(~s([data-role="meeting-captions-toggle"]))
      |> render_click()

      for mode <- ["screen", "whiteboard"] do
        html = render_click(view, "set_stage_mode", %{"mode" => mode})
        tag = caption_bar_shell_open_tag(html)

        assert tag, ~s(expected `[data-role="meeting-captions-shell"]` element in #{mode} mode)
        assert tag =~ ~s(data-stage-mode="#{mode}")

        refute tag =~ ~r/\bhidden\b/,
               "caption bar must NOT carry `hidden` in #{mode} mode; got: #{tag}"
      end
    end

    test "toggling stage mode gallery -> canvas -> gallery never hides the bar",
         %{conn: conn, meeting: meeting} do
      # Regression: with `phx-update=\"ignore\"` on the element, morphdom
      # still has to re-apply attribute changes on stage-mode transitions
      # — `ignore` preserves children, not attributes. `data-stage-mode`
      # is the observable that proves the transition actually happened, so
      # the `hidden` refutes are not passing on a stale render.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      view
      |> element(~s([data-role="meeting-captions-toggle"]))
      |> render_click()

      html_gallery = render(view)
      tag_g1 = caption_bar_shell_open_tag(html_gallery)
      refute tag_g1 =~ ~r/\bhidden\b/
      assert tag_g1 =~ ~s(data-stage-mode="gallery")

      html_canvas = render_click(view, "set_stage_mode", %{"mode" => "canvas"})
      tag_c = caption_bar_shell_open_tag(html_canvas)
      refute tag_c =~ ~r/\bhidden\b/
      assert tag_c =~ ~s(data-stage-mode="canvas")

      html_back = render_click(view, "set_stage_mode", %{"mode" => "gallery"})
      tag_g2 = caption_bar_shell_open_tag(html_back)
      refute tag_g2 =~ ~r/\bhidden\b/
      assert tag_g2 =~ ~s(data-stage-mode="gallery")
    end

    test "caption bar absent from DOM when captions_visible=false regardless of stage mode",
         %{conn: conn, meeting: meeting} do
      # The `:if={@captions_visible}` gate still short-circuits mount, so
      # the class flip only takes effect once captions are actually on.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      for mode <- ["gallery", "canvas", "screen", "whiteboard"] do
        html = render_click(view, "set_stage_mode", %{"mode" => mode})

        refute html =~ ~s(data-role="meeting-captions"),
               "caption bar must be absent when captions_visible=false in #{mode} mode"
      end
    end
  end

  describe "chrome_mode session param (task 019f498d stage 1)" do
    # Stage 1 is passive plumbing: mount reads `session["chrome_mode"]`
    # and assigns `:chrome_mode` / `:shell?`. The default
    # `/meetings/:slug` mount injects no `chrome_mode` session key →
    # falls back to `:shell` / `shell? = true`. The `meet.` host guest
    # route (real chrome_mode :none path) is covered end-to-end in
    # `meeting_live_guest_mount_test.exs` (async: false because it stubs
    # LiveKit env) — stage 6 also lands host-routing regression coverage
    # here in `meeting_live_test.exs`.

    test "authenticated /meetings/:slug mount defaults chrome_mode to :shell + shell? true",
         %{conn: conn} do
      {meeting, _space} = create_meeting(%{slug: "chrome-default", name: "Chrome Default"})
      {conn, _user} = authenticated_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.chrome_mode == :shell
      assert assigns.shell? == true
    end
  end

  # ── task 019f498d stage 6: chrome-escape + host-scope ports ────────────────
  #
  # These describe blocks port the invariant + router coverage that lived in
  # the now-deleted `guest_meeting_live_test.exs`. They pin behaviors that
  # the stage-3 mount + stage-4 heex branch land, but that
  # `meeting_live_guest_mount_test.exs` doesn't cover from the perspective of
  # the ported originals — specifically the `www.example.com` router regression
  # and the shell-side chrome-visible regression check.
  #
  # `Application.put_env(:platform, :livekit, …)` mutates process-global config;
  # the file is `async: true` so this is technically racy, but the existing
  # `describe` blocks earlier in this file use the same pattern with `on_exit`
  # cleanup. Follow suit — refactoring the file to :async false is out of scope.

  defp put_guest_livekit_env do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
    :ok
  end

  # Prefix the conn's host with `meet.` so the router's guest scope matches.
  defp with_meet_host(conn, host \\ "meet.localhost"), do: %{conn | host: host}

  # Decode the JWT payload segment to inspect the `name` + `sub` claims
  # without pulling in JOSE.
  defp decode_jwt_claims(jwt) when is_binary(jwt) do
    with [_h, payload, _sig] <- String.split(jwt, ".", parts: 3),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> :error
    end
  end

  # Meeting + chat_space + minted-token bundle, ready for a guest mount.
  # `create_meeting/1` in this file returns `{meeting, space}` but doesn't
  # preload `:chat_space` — the guest-mount path reads `meeting.chat_space.slug`
  # through `mint_guest_join_bundle/2`, so preload here.
  defp create_guest_meeting(display_name \\ "Jane Doe") do
    {meeting, _space} =
      create_meeting(%{slug: "guest-stage6-#{System.unique_integer([:positive])}"})

    meeting = Repo.preload(meeting, :chat_space)
    expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
    token = GuestInvite.sign(meeting.slug, expires_at, display_name)
    {meeting, token}
  end

  describe "host: routing for guest surface (task 019f498d stage 6)" do
    setup do
      put_guest_livekit_env()
      :ok
    end

    test "requests on host `meet.<any>.<tld>` resolve MeetingLive via the :show action",
         %{conn: conn} do
      {meeting, token} = create_guest_meeting()

      {:ok, view, html} =
        conn
        |> with_meet_host("meet.example.com")
        |> live("/#{meeting.slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns
      # Router injected `chrome_mode: "none"` through the `:guest_meeting`
      # live_session; MeetingLive.mount normalized to `:none`.
      assert assigns.chrome_mode == :none
      assert assigns.shell? == false
      # Guest surface still renders the meeting controls…
      assert html =~ ~s(data-role="meeting-mic")
      # …but not the chat panel (gated on `@shell?`).
      refute html =~ ~s(data-pane="chat-panel")
    end

    test "requests on default `www.example.com` host do NOT resolve /:slug/:token to MeetingLive",
         %{conn: conn} do
      {meeting, token} = create_guest_meeting()

      # ConnTest's default conn carries host `www.example.com`, which does
      # NOT match the `meet.` scope. The route `/:slug/:token` has no
      # sibling under the default scope, so the dispatch bails out 404
      # before any LiveView runs. Use plain `get/2` so the response
      # status is inspectable directly (LiveViewTest.live/2 wraps the
      # miss in a WebSocket-connect FunctionClauseError).
      response_conn = get(conn, "/#{meeting.slug}/#{token}")
      assert response_conn.status == 404
    end
  end

  describe "layout chrome-escape (guest surface) (task 019f498d stage 6)" do
    setup do
      put_guest_livekit_env()
      :ok
    end

    test "rendered document contains no shell chrome markers", %{conn: conn} do
      {meeting, token} = create_guest_meeting()

      # Fetch the static-render body directly so root layout HTML (which
      # would carry shell chrome if the layout were `:app`) is included.
      conn = with_meet_host(conn)
      %{resp_body: body} = get(conn, "/#{meeting.slug}/#{token}")

      refute body =~ "shell-sidebar"
      refute body =~ "icon-rail"
      refute body =~ "bottom-nav"
      refute body =~ "chat-sidebar"
    end

    test "guest surface omits the Copy guest link + chat panel + chat drawer",
         %{conn: conn} do
      {meeting, token} = create_guest_meeting()

      {:ok, _view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      refute html =~ "meeting-copy-guest-link"
      refute html =~ ~s(data-pane="chat-panel")
      refute html =~ "chat-panel-toggle"
      refute html =~ "chat-pane-toggle"
    end

    test "authenticated /meetings/:slug still renders full shell chrome (regression check)",
         %{conn: conn} do
      # Sanity: if a future edit widens a `@shell?` guard from the auth
      # surface, the chat panel / chat-panel toggle should still show.
      {meeting, _space} =
        create_meeting(%{slug: "shell-regression-#{System.unique_integer([:positive])}"})

      {conn, _user} = authenticated_conn(conn)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # The chat DRAWER (`data-pane="chat-panel"`) is gone as of task
      # 01a084bf stage 3, so the shell-only surface to sanity-check is the
      # chat BODY in the rail plus the top-bar control. Both are `@shell?`-
      # gated, which is what this regression check is really about — the
      # guest counterpart above refutes them.
      assert html =~ ~s(data-pane="meeting-chat-panel")
      assert html =~ "chat-panel-toggle"
    end
  end

  describe "guest LiveKit token bundle (task 019f498d stage 6)" do
    setup do
      put_guest_livekit_env()
      :ok
    end

    test "minted JWT `name` claim carries the ` (guest)` suffix", %{conn: conn} do
      {meeting, token} = create_guest_meeting("Jane Doe")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert_push_event(view, "join-meeting", %{token: pushed_token})
      assert {:ok, claims} = decode_jwt_claims(pushed_token)
      assert String.ends_with?(claims["name"], " (guest)")
      assert claims["name"] == "Jane Doe (guest)"
    end

    test "identity carries the `guest:` prefix on the JWT sub claim", %{conn: conn} do
      # The `join-meeting` push_event payload is `%{token, url, room_name,
      # space_slug}` — `identity` isn't in the payload directly, so assert
      # against the decoded JWT's `sub` claim (the LiveKit identity).
      {meeting, token} = create_guest_meeting("Jane Doe")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert_push_event(view, "join-meeting", %{token: pushed_token})
      assert {:ok, claims} = decode_jwt_claims(pushed_token)
      assert String.starts_with?(claims["sub"], "guest:")
    end
  end

  describe "chat_space preload (task 019f498d stage 6)" do
    setup do
      put_guest_livekit_env()
      :ok
    end

    test "chat_space is preloaded on the meeting assign for :in_meeting guests",
         %{conn: conn} do
      # If `resolve_guest_invite/2` failed to preload `:chat_space`, the
      # `push_join_event` code path would crash on
      # `%Ecto.Association.NotLoaded{}` when reading `meeting.chat_space.slug`.
      # This test locks the preload contract.
      {meeting, token} = create_guest_meeting()

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert %Meeting{} = assigns.meeting
      assert %Chat.Space{} = assigns.meeting.chat_space
      assert assigns.meeting.chat_space.id == meeting.chat_space_id
    end
  end

  describe "guest meeting presence subscription (task 019f498d stage 6)" do
    setup do
      put_guest_livekit_env()
      :ok
    end

    test "guest mount subscribes to per-space presence topic; a broadcast on it refreshes :participants",
         %{conn: conn} do
      {meeting, token} = create_guest_meeting()
      space_id = meeting.chat_space_id

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      # Baseline: the guest's OWN mount (task 019f498d re-dispatch) now
      # calls `Meetings.upsert_live_participant/2` so a `.video_tile`
      # renders for the guest on both their own surface AND on any
      # subscribed authenticated MeetingLive. So the initial participant
      # list contains exactly one row — the guest themselves.
      initial = :sys.get_state(view.pid).socket.assigns
      assert initial.state == :in_meeting
      assert length(initial.participants) == 1
      assert Enum.any?(initial.participants, &String.contains?(&1.display_name, "(guest)"))

      # Seed an ADDITIONAL live participant, then broadcast on the space
      # presence topic. The guest mount subscribed to `presence_topic(space_id)`
      # via `MeetingsPubSub.subscribe_presence/1`; the LV's
      # `{:meeting_presence_update, _}` handler calls `refresh_participants`,
      # which re-reads from `active_participants_for_space/1` and now sees
      # both our seeded participant and the guest.
      {:ok, room} = Meetings.ensure_room(space_id)
      {:ok, room} = Meetings.activate_room(room)
      {:ok, _alice} = Meetings.participant_joined(room, %{display_name: "Alice"})

      MeetingsPubSub.broadcast_presence(
        space_id,
        {:meeting_presence_update, %{space_id: space_id, active: true, count: 2}}
      )

      _ = render(view)
      Process.sleep(50)

      after_broadcast = :sys.get_state(view.pid).socket.assigns
      assert length(after_broadcast.participants) == 2
    end
  end

  # ── [data-video-slot] identity stability (task 019f8153 stage 4) ─────────────
  #
  # The StableTileElementInfo JS fix (task 019f8153 stage 1,
  # assets/js/hooks/meeting_video_tile.js) holds a DIRECT reference to the
  # `<video>` the hook injects into `[data-video-slot]`, and that hook is now
  # the SOLE LiveKit visibility oracle — the SDK's default IntersectionObserver
  # watcher is intentionally never installed. The slot's stable
  # `id={"video-slot-#{@id_prefix}-#{@identity}"}` + `phx-update="ignore"`
  # (video_tile.ex) are what keep morphdom from ever replacing that node across
  # LiveView patches. Any future server-side change that moves the slot out of
  # its `ignore` boundary or perturbs the id derivation would resurrect the
  # black-tile class this task eliminated — as a SILENT production regression.
  # This block trips on it at CI time instead. See also the two vitest hook
  # regression tests (meeting_video_tile_adaptive.test.js /
  # meeting_video_tile_contract.test.js).
  #
  # The events are a MODULE-LEVEL {event, params} list so a reviewer appends a
  # new toggle here the moment one lands (acceptance #6): every currently-known
  # state-touching MeetingLive event must leave the gallery slots byte-identical.
  @slot_identity_events [
    {"toggle_captions_meeting", %{}},
    # The mic-toggle event path — handled by the attached MeetingHooks
    # `:meeting_events` handle_event hook (meeting_hooks.ex); under
    # `?no_autojoin=true` the guest variant handles it.
    {"meeting_toggle_mic", %{}},
    # A no-op re-assert of the already-active gallery mode. The gallery↔screen
    # REMOUNT is exercised separately (see the mode-swap test below).
    {"set_stage_mode", %{"mode" => "gallery"}},
    {"toggle_chat_panel", %{}},
    {"meeting_tab_select", %{"tab" => "canvas"}},
    {"toggle_meeting_chat_pane", %{}}
  ]

  # Parse every `[data-video-slot]` opening tag out of a rendered LiveView
  # snapshot into an `id => phx-update` map. Regex (not Floki) mirrors this
  # file's house style — Floki isn't a direct dep here. The slot carries no
  # server-rendered children (the `<video>` is injected client-side), so the
  # opening tag holds the full contract we assert on.
  defp video_slot_map(html) do
    ~r/<div[^>]*\bdata-video-slot\b[^>]*>/
    |> Regex.scan(html)
    |> List.flatten()
    |> Map.new(fn tag ->
      [_, id] = Regex.run(~r/\bid="([^"]*)"/, tag)

      phx_update =
        case Regex.run(~r/\bphx-update="([^"]*)"/, tag) do
          [_, value] -> value
          nil -> nil
        end

      {id, phx_update}
    end)
  end

  describe "[data-video-slot] identity stability across state-touching events" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "slot-identity", name: "Slot Identity"})
      {conn, _user} = authenticated_conn(conn)

      # Two live humans → exactly two gallery tiles. `?no_autojoin=true` keeps
      # the viewer out of the roster so the count is deterministic (mirrors the
      # "renders one VideoTile per human participant" test above).
      {_ada, ada_id} = seed_meeting_presence(space, "user", "Ada Lovelace")
      {_grace, grace_id} = seed_meeting_presence(space, "user", "Grace Hopper")

      {:ok, conn: conn, meeting: meeting, space: space, ada_id: ada_id, grace_id: grace_id}
    end

    test "every currently-known state-touching event leaves the gallery slot ids + phx-update byte-identical",
         %{conn: conn, meeting: meeting} do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # Default mount is gallery mode. Baseline: two gallery-tile slots, each
      # keyed by identity and carrying `phx-update="ignore"`.
      baseline = video_slot_map(html)

      assert map_size(baseline) == 2

      assert Enum.all?(
               Map.keys(baseline),
               &String.starts_with?(&1, "video-slot-gallery-tile-")
             )

      assert Enum.all?(Map.values(baseline), &(&1 == "ignore"))

      for {event, params} <- @slot_identity_events do
        after_map = video_slot_map(render_click(view, event, params))

        assert after_map == baseline,
               "event #{inspect(event)} perturbed a [data-video-slot] id or phx-update " <>
                 "(the injected <video> would go black in production). " <>
                 "before=#{inspect(baseline)} after=#{inspect(after_map)}"
      end

      # Byte-identical again after the full sequence.
      assert video_slot_map(render(view)) == baseline
    end

    test "a {:participant_joined, _} broadcast adds a new slot and leaves the two existing ids unchanged",
         %{conn: conn, meeting: meeting, space: space} do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      baseline = video_slot_map(html)
      assert map_size(baseline) == 2

      # Seed a third live human, then deliver the granular room-topic event the
      # LiveKit webhook fires (meeting_live.ex handle_info/2 →
      # refresh_participants re-reads the roster from the DB, so the row must
      # exist first).
      {new_participant, _new_id} = seed_meeting_presence(space, "user", "Katherine Johnson")
      send(view.pid, {:participant_joined, new_participant})

      after_map = video_slot_map(render(view))

      # The two pre-existing gallery slots are byte-identical…
      for {id, phx_update} <- baseline do
        assert Map.get(after_map, id) == phx_update,
               "existing slot #{id} changed after a participant joined"
      end

      # …and exactly one new slot appeared, also under `phx-update="ignore"`.
      assert map_size(after_map) == 3
      new_ids = Map.keys(after_map) -- Map.keys(baseline)
      assert length(new_ids) == 1
      assert Enum.all?(new_ids, &String.starts_with?(&1, "video-slot-gallery-tile-"))
      assert after_map[hd(new_ids)] == "ignore"
    end

    test "gallery↔screen deliberately remounts tiles, but the gallery slot id is deterministic from identity",
         %{conn: conn, meeting: meeting} do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      baseline = video_slot_map(html)
      assert map_size(baseline) == 2

      # Switch to Screen: the gallery grid unmounts and the bottom strip mounts
      # its tiles under the DISTINCT `strip-tile` id prefix (video_tile.ex
      # id_prefix doc) — so NO `gallery-tile` slot survives the swap. This is
      # the intended remount, not node reuse.
      screen_map = video_slot_map(render_click(view, "set_stage_mode", %{"mode" => "screen"}))

      refute Enum.any?(
               Map.keys(screen_map),
               &String.starts_with?(&1, "video-slot-gallery-tile-")
             ),
             "gallery-tile slots must remount away when leaving gallery mode"

      # Switch back to Gallery: because the id is a pure function of identity,
      # the gallery slot map is byte-identical to the original mount — the fix's
      # stability guarantee is that the id is DETERMINISTIC, not that the node
      # object is reused across the mode swap.
      back_map = video_slot_map(render_click(view, "set_stage_mode", %{"mode" => "gallery"}))

      assert back_map == baseline
    end
  end

  # ── Intents-collapse bar (task 019f70b8 stage 7) ───────────────────────────
  #
  # Every case here mounts the REAL route and seeds the REAL per-meeting
  # queue keyed by the meeting's own id, then asserts on rendered DOM.
  # None of them construct assigns directly: this subsystem has already
  # shipped a green suite over a dead path (`meeting_id: nil`), and a
  # test that hands the LV a list of rows proves the template renders a
  # list — not that the mount ever finds one.
  describe "intents-collapse bar — role gate (AC13)" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "intents-gate", name: "Intent Gate"})
      {conn, user} = authenticated_conn(conn)
      on_exit(fn -> IntentQueue.stop(meeting.id) end)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "unassigned meeting_producer leaves NOTHING in the DOM", %{
      conn: conn,
      meeting: meeting
    } do
      # AC13 is "absent", not "hidden": an unfilled capability is not a
      # denial, and a CSS-hidden panel would still reserve layout space
      # and still ship the queue's contents to a viewer who may not see
      # them. Assert on the data-role hook, which is what the contract
      # names.
      refute Platform.Roles.agent_id_for_role("meeting_producer")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      refute html =~ ~s(data-role="intents-collapse")
      refute html =~ "intents-collapse"
      # ...and no CSS-hidden twin either.
      refute html =~ "Listening for intents"
    end

    test "assigned meeting_producer renders the strip", %{conn: conn, meeting: meeting} do
      assign_producer!()

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      assert html =~ ~s(data-role="intents-collapse")
      assert html =~ "intents-collapse"
    end

    test "the strip is a sibling of the chat body, not a replacement for it", %{
      conn: conn,
      meeting: meeting
    } do
      # The stage brief is explicit: keep hosting the embedded ChatLive.
      # The bar shares the right rail with it; it does not displace it.
      assign_producer!()

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      assert html =~ ~s(data-role="intents-collapse")
      assert html =~ ~s(data-intent-panel-host="true")
      assert html =~ ~s(data-pane="meeting-chat-panel")

      # Ordering: the strip renders above the chat body inside the same aside.
      strip_at = :binary.match(html, ~s(data-role="intents-collapse")) |> elem(0)
      host_at = :binary.match(html, ~s(data-intent-panel-host="true")) |> elem(0)
      assert strip_at < host_at
    end

    test "a role assigned mid-meeting fades the panel in without a reload", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      refute html =~ ~s(data-role="intents-collapse")

      # Seed a row while the panel is invisible — the appointed producer
      # must inherit the meeting's history, not only what happens next.
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "book_followup"})

      assign_producer!()

      html = render(view)
      assert html =~ ~s(data-role="intents-collapse")
      assert html =~ ~s(data-intent-id="#{row.id}")
      assert html =~ "book_followup"
    end

    test "unassigning mid-meeting removes the panel and its contents", %{
      conn: conn,
      meeting: meeting
    } do
      assign_producer!()
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "book_followup"})

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      assert html =~ ~s(data-intent-id="#{row.id}")

      :ok = Platform.Roles.unassign_role("meeting_producer")

      html = render(view)
      refute html =~ ~s(data-role="intents-collapse")
      refute html =~ ~s(data-intent-id="#{row.id}")
    end

    test "a non-producer cannot drive a removal by replaying the event", %{
      conn: conn,
      meeting: meeting
    } do
      # The template gate keeps the bar out of the DOM. This keeps it out
      # of reach: a phx-click is a client-supplied message.
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "book_followup"})

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      render_click(view, "intent_remove", %{
        "intent_id" => row.id,
        "reason" => "wrong_intent"
      })

      assert IntentCorrections.list_for_meeting(meeting.id) == []
      assert [%{status: :queued}] = IntentQueue.list(meeting.id)
    end
  end

  describe "intents-collapse bar — mount seeding + status chips" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "intents-chips", name: "Intent Chips"})
      {conn, user} = authenticated_conn(conn)
      assign_producer!()
      on_exit(fn -> IntentQueue.stop(meeting.id) end)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "an empty queue renders the listening state, not an error", %{
      conn: conn,
      meeting: meeting
    } do
      # `IntentQueue.list/1` returns [] when no owner is running — a
      # meeting that never produced an intent and one whose queue ended
      # are indistinguishable, and both are an empty strip.
      refute IntentQueue.running?(meeting.id)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      assert html =~ ~s(data-role="intents-empty")
      assert html =~ "Listening for intents"
      assert html =~ ~s(data-intent-count="0")
    end

    test "mount seeds from the live queue keyed by THIS meeting's id", %{
      conn: conn,
      meeting: meeting
    } do
      # The derivation under test: the LV must find the queue the
      # classifier enqueues into, keyed by `meeting.id`. A queue seeded
      # under any other id renders nothing.
      {:ok, first} = enqueue_intent(meeting, %{classified_intent: "create_task"})
      {:ok, second} = enqueue_intent(meeting, %{classified_intent: "book_followup"})

      other_meeting_id = Platform.Types.UUIDv7.generate()
      {:ok, _} = IntentQueue.ensure_started(other_meeting_id)
      on_exit(fn -> IntentQueue.stop(other_meeting_id) end)

      {:ok, stranger} =
        IntentQueue.enqueue(other_meeting_id, %{
          classified_intent: "not_this_meeting",
          target_role: "designer",
          dedupe_key: "stranger-#{System.unique_integer([:positive])}"
        })

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      assert html =~ ~s(data-intent-id="#{first.id}")
      assert html =~ ~s(data-intent-id="#{second.id}")
      assert html =~ ~s(data-intent-count="2")
      refute html =~ ~s(data-intent-id="#{stranger.id}")
      refute html =~ "not_this_meeting"
    end

    test "rows render oldest-first on the queue's monotonic seq", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, first} = enqueue_intent(meeting, %{classified_intent: "alpha_intent"})
      {:ok, second} = enqueue_intent(meeting, %{classified_intent: "beta_intent"})

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      assert :binary.match(html, ~s(data-intent-id="#{first.id}")) |> elem(0) <
               :binary.match(html, ~s(data-intent-id="#{second.id}")) |> elem(0)
    end

    test "all nine statuses render a distinct glyph + mono label", %{
      conn: conn,
      meeting: meeting
    } do
      # Colourblind-safety is the point: the glyph and the label carry
      # the meaning, colour only reinforces it. Nine rows, nine glyphs,
      # nine labels, no duplicates.
      rows =
        for status <- IntentQueue.statuses(), into: %{} do
          {:ok, row} = enqueue_intent(meeting, %{classified_intent: "intent_#{status}"})
          {:ok, row} = force_status(meeting, row, status)
          {status, row}
        end

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      for {status, row} <- rows do
        assert html =~ ~s(data-intent-id="#{row.id}")
        assert html =~ ~s(data-intent-status="#{status}")
        assert html =~ IntentsCollapse.status_icon(status)
        assert html =~ IntentsCollapse.status_label(status)
      end

      glyphs = Enum.map(IntentQueue.statuses(), &IntentsCollapse.status_icon/1)
      assert length(Enum.uniq(glyphs)) == length(IntentQueue.statuses())

      labels = Enum.map(IntentQueue.statuses(), &IntentsCollapse.status_label/1)
      assert length(Enum.uniq(labels)) == length(IntentQueue.statuses())
    end

    test "the error split is amber for :timed_out and red for the two hard failures", %{
      conn: conn,
      meeting: meeting
    } do
      # :timed_out means "we waited and got nothing"; the other two mean
      # "something is broken". Three different operator actions, so they
      # must not collapse into one chip. Stage 6 carried the same split
      # into the corrections corpus.
      {:ok, timed_out} = enqueue_intent(meeting, %{classified_intent: "waited_intent"})
      {:ok, timed_out} = force_status(meeting, timed_out, :timed_out)

      {:ok, no_runtime} = enqueue_intent(meeting, %{classified_intent: "no_runtime_intent"})
      {:ok, no_runtime} = force_status(meeting, no_runtime, :dispatch_failed)

      {:ok, spawn_failed} = enqueue_intent(meeting, %{classified_intent: "spawn_failed_intent"})
      {:ok, spawn_failed} = force_status(meeting, spawn_failed, :no_ack_spawn_failed)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      assert IntentsCollapse.status_tone(:timed_out) == "warning"
      assert IntentsCollapse.status_tone(:dispatch_failed) == "error"
      assert IntentsCollapse.status_tone(:no_ack_spawn_failed) == "error"

      assert chip_tone_for(html, timed_out.id) == "chip-warning"
      assert chip_tone_for(html, no_runtime.id) == "chip-error"
      assert chip_tone_for(html, spawn_failed.id) == "chip-error"
    end

    test "rows are grouped for reading: in-flight, success, cancelled, error", %{
      conn: conn,
      meeting: meeting
    } do
      for {status, group} <- [
            {:queued, "in_flight"},
            {:dispatched, "in_flight"},
            {:acked, "in_flight"},
            {:completed, "success"},
            {:cancelled, "cancelled"},
            {:cancelled_late, "cancelled"},
            {:timed_out, "error"},
            {:dispatch_failed, "error"},
            {:no_ack_spawn_failed, "error"}
          ] do
        assert to_string(IntentsCollapse.status_group(status)) == group
      end

      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "grouped_intent"})
      {:ok, row} = force_status(meeting, row, :timed_out)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      assert html =~ ~s(data-intent-group="error")
      assert html =~ ~s(data-intent-id="#{row.id}")
    end
  end

  describe "intents-collapse bar — live updates (all eight events)" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "intents-live", name: "Intent Live"})
      {conn, user} = authenticated_conn(conn)
      assign_producer!()
      on_exit(fn -> IntentQueue.stop(meeting.id) end)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test ":intent_classified inserts a row that wasn't there at mount", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      assert html =~ ~s(data-intent-count="0")

      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "late_arrival"})

      html = render(view)
      assert html =~ ~s(data-intent-id="#{row.id}")
      assert html =~ ~s(data-intent-count="1")
      assert html =~ "late_arrival"
    end

    test "each of the seven transition events mutates the rendered status", %{
      conn: conn,
      meeting: meeting
    } do
      # Driven through the real queue so every assertion exercises the
      # real broadcast, not a hand-rolled `send/2` of a shape the LV
      # happens to match.
      for status <- [
            :dispatched,
            :acked,
            :completed,
            :cancelled,
            :timed_out,
            :dispatch_failed,
            :no_ack_spawn_failed
          ] do
        {:ok, row} = enqueue_intent(meeting, %{classified_intent: "evented_#{status}"})

        {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
        assert html =~ ~s(data-intent-status="queued")

        {:ok, _} = force_status(meeting, row, status)

        html = render(view)

        assert html =~ ~s(data-intent-status="#{status}"),
               "expected the #{status} broadcast to move the rendered row"

        assert html =~ IntentsCollapse.status_label(status)

        IntentQueue.delete(meeting.id, row.id)
      end
    end

    test ":cancelled_late is distinguishable from :cancelled in the DOM", %{
      conn: conn,
      meeting: meeting
    } do
      # Both share the `:intent_cancelled` broadcast — the payload's
      # status is the only thing telling them apart, so the LV must read
      # it rather than assume.
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "raced_intent"})

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      {:ok, _} = force_status(meeting, row, :cancelled_late)

      html = render(view)
      assert html =~ ~s(data-intent-status="cancelled_late")
      assert html =~ "Cancelled late"
    end

    test "an event for a different meeting is ignored", %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      # Same topic shape, different meeting — the LV is only subscribed
      # to its own, but the guard is the thing that makes that safe when
      # a shared topic is ever introduced.
      stranger = %{
        id: Platform.Types.UUIDv7.generate(),
        meeting_id: Platform.Types.UUIDv7.generate(),
        classified_intent: "stranger_intent",
        status: :queued,
        seq: 1
      }

      send(view.pid, {:intent_classified, stranger})

      html = render(view)
      refute html =~ "stranger_intent"
      assert html =~ ~s(data-intent-count="0")
    end

    test "the expanded table exposes subagent_id and dispatch_failure_reason", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "expanded_intent"})

      {:ok, _} =
        IntentQueue.transition(meeting.id, row.id, :dispatch_failed, %{
          dispatch_failure_reason: :no_runtime,
          subagent_id: "higgins.moon"
        })

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      refute html =~ ~s(data-role="intents-expanded")

      html = render_click(view, "toggle_intents_expanded", %{})

      assert html =~ ~s(data-role="intents-expanded")
      assert html =~ "higgins.moon"
      assert html =~ "no_runtime"
    end

    test "both overlays render OUTSIDE the transformed chat rail", %{
      conn: conn,
      meeting: meeting
    } do
      # The chat rail carries `transition-transform` + `translate-x-0` so
      # it can slide in as a mobile drawer, and a transformed ancestor
      # becomes the containing block for `position: fixed`. An overlay
      # rendered inside the strip is therefore centred on a 320px rail
      # instead of on the viewport — a "centered modal" that is nothing
      # of the sort. Assert on document ORDER: both overlays must land
      # after the rail's closing markup, not nested inside it.
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "overlay_intent"})

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      html = render_click(view, "toggle_intents_expanded", %{})
      assert overlay_outside_rail?(html, "intents-expanded")

      render_click(view, "toggle_intents_expanded", %{})
      html = render_click(view, "intent_edit_open", %{"intent_id" => row.id})
      assert overlay_outside_rail?(html, "intent-edit-modal")
    end

    test "the collapse header toggles the body without dropping the rows", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "toggled_intent"})

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      assert html =~ ~s(data-role="intents-collapse-body")

      html = render_click(view, "toggle_intents_collapse", %{})
      refute html =~ ~s(data-role="intents-collapse-body")
      assert html =~ ~s(data-intent-count="1")

      html = render_click(view, "toggle_intents_collapse", %{})
      assert html =~ ~s(data-intent-id="#{row.id}")
    end
  end

  describe "intents-collapse bar — status-aware controls + 44px targets" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "intents-controls", name: "Intent Controls"})
      {conn, user} = authenticated_conn(conn)
      assign_producer!()
      on_exit(fn -> IntentQueue.stop(meeting.id) end)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "controls are drawn per status, not on every row", %{conn: conn, meeting: meeting} do
      expectations = [
        {:queued, true, true},
        {:dispatched, true, true},
        {:acked, true, true},
        {:completed, false, false},
        {:cancelled, false, false},
        {:cancelled_late, false, false},
        {:timed_out, true, false},
        {:dispatch_failed, true, true},
        {:no_ack_spawn_failed, true, true}
      ]

      for {status, removable, correctable} <- expectations do
        assert IntentsCollapse.removable?(status) == removable
        assert IntentsCollapse.correctable?(status) == correctable
      end

      for {status, removable, correctable} <- expectations do
        {:ok, row} = enqueue_intent(meeting, %{classified_intent: "control_#{status}"})
        {:ok, _} = force_status(meeting, row, status)

        {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

        assert html =~ ~s(data-role="intent-remove" data-intent-id="#{row.id}") == removable,
               "#{status}: expected remove control presence #{removable}"

        assert html =~ ~s(data-role="intent-edit" data-intent-id="#{row.id}") == correctable,
               "#{status}: expected edit control presence #{correctable}"

        IntentQueue.delete(meeting.id, row.id)
      end
    end

    test "every control in the strip clears the 44px tap floor", %{
      conn: conn,
      meeting: meeting
    } do
      # The mock's row icons read as btn-xs (~24px), under the floor.
      # Tailwind `11` = 44px.
      {:ok, _row} = enqueue_intent(meeting, %{classified_intent: "tappable_intent"})

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      for role <- ~w(intents-collapse-toggle intents-expand-toggle intent-remove intent-edit) do
        assert html =~ ~s(data-role="#{role}")
      end

      for tag <- strip_button_tags(html) do
        assert tag =~ "min-h-11", "control below the 44px floor: #{tag}"
      end

      # The reason picker's options are touch targets too.
      html = render_click(view, "intent_reason_picker_toggle", %{"intent_id" => first_id(html)})
      assert html =~ ~s(data-role="intent-reason-picker")

      for tag <- strip_button_tags(html) do
        assert tag =~ "min-h-11", "control below the 44px floor: #{tag}"
      end
    end

    test "rows are two-line at EVERY viewport, not only below sm", %{
      conn: conn,
      meeting: meeting
    } do
      # The design direction says "two-line below `sm`". A viewport
      # breakpoint is the wrong instrument: this rail is `lg:w-80` on
      # desktop and `w-80 max-w-[85vw]` as a mobile drawer — ~320px in
      # both cases. An `sm:flex-row` would flip a 320px container to one
      # line on the WIDEST viewport, truncating `visual_adjust` to "v.".
      {:ok, _row} = enqueue_intent(meeting, %{classified_intent: "narrow_intent"})

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      [row_tag] = Regex.run(~r/<li[^>]*data-role="intent-row"[^>]*>/, html)
      assert row_tag =~ "flex-col"
      assert row_tag =~ "min-h-11"

      refute row_tag =~ "sm:flex-row",
             "a viewport breakpoint cannot describe a fixed-width rail"
    end

    test "controls are persistent, never hover-revealed", %{conn: conn, meeting: meeting} do
      # Mobile has no hover. A control that only appears on :hover is a
      # control a phone user does not have.
      {:ok, _row} = enqueue_intent(meeting, %{classified_intent: "persistent_intent"})

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      for tag <- strip_button_tags(html) do
        refute tag =~ "group-hover:", "hover-revealed control: #{tag}"
        refute tag =~ "opacity-0", "hover-revealed control: #{tag}"
      end
    end
  end

  describe "intents-collapse bar — the collapsed summary protects the severity fragment" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "intents-summary", name: "Intent Summary"})
      {conn, user} = authenticated_conn(conn)
      assign_producer!()
      on_exit(fn -> IntentQueue.stop(meeting.id) end)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "severity is rendered first and refuses to shrink; the count yields", %{
      conn: conn,
      meeting: meeting
    } do
      # The resting state exists to answer "is anything wrong?" without
      # expanding. It previously clipped to `3 need…` in the ~320px
      # rail — failing that purpose in exactly the case it singles out.
      for n <- 1..10 do
        {:ok, row} = enqueue_intent(meeting, %{classified_intent: "summary_intent_#{n}"})
        if n <= 3, do: {:ok, _} = force_status(meeting, row, :dispatch_failed)
      end

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      [severity_tag] =
        Regex.run(~r/<span[^>]*data-role="intents-summary-severity"[^>]*>/, html)

      [tail_tag] = Regex.run(~r/<span[^>]*data-role="intents-summary-tail"[^>]*>/, html)

      # Structural: the severity span keeps its width, the tail gives
      # its up. Not a copy convention someone can reword away.
      assert severity_tag =~ "shrink-0"
      assert severity_tag =~ "whitespace-nowrap"
      refute severity_tag =~ "truncate"
      assert tail_tag =~ "truncate"
      assert tail_tag =~ "min-w-0"

      # Ordered: severity first, so a clip eats the benign tail.
      severity_at = :binary.match(html, ~s(data-role="intents-summary-severity")) |> elem(0)
      tail_at = :binary.match(html, ~s(data-role="intents-summary-tail")) |> elem(0)
      assert severity_at < tail_at

      assert html =~ "3 need attention"
      assert html =~ "· 10 intents"
    end

    test "the Producer chip yields its width before the summary does", %{
      conn: conn,
      meeting: meeting
    } do
      # Saru's alternative to compacting the copy: everything else in the
      # header gives up room first. The chip labels a permission that
      # never changes — the cheapest thing on the row to squeeze.
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "chip_yield_intent"})
      {:ok, _} = force_status(meeting, row, :timed_out)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      [chip_tag] = Regex.run(~r/<span[^>]*class="[^"]*chip-primary[^"]*"[^>]*>/, html)

      assert chip_tag =~ "truncate"

      refute chip_tag =~ "flex-shrink-0",
             "the Producer chip must be able to yield so the summary does not have to"
    end

    test "the zero-attention case has no severity span and may truncate freely", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _row} = enqueue_intent(meeting, %{classified_intent: "benign_intent"})

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      refute html =~ ~s(data-role="intents-summary-severity")
      assert html =~ ~s(data-role="intents-summary-tail")
      assert html =~ "1 intent"
      refute html =~ "need attention"
    end
  end

  describe "intents-collapse bar — low confidence is emphasised, never by colour alone" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "intents-conf", name: "Intent Confidence"})
      {conn, user} = authenticated_conn(conn)
      assign_producer!()
      on_exit(fn -> IntentQueue.stop(meeting.id) end)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "a 0.55 row and a 0.96 row do not render identically", %{
      conn: conn,
      meeting: meeting
    } do
      # A producer deciding whether to trust a dispatch is exactly the
      # person who needs those two to look different.
      {:ok, low} = enqueue_intent(meeting, %{classified_intent: "shaky_intent", confidence: 0.55})

      {:ok, high} =
        enqueue_intent(meeting, %{classified_intent: "certain_intent", confidence: 0.96})

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      low_readout = confidence_span(html, low.id)
      high_readout = confidence_span(html, high.id)

      # 1. warning tone
      assert low_readout =~ "text-warning"
      refute high_readout =~ "text-warning"

      # 2. `~` prefix on the mono value — the non-colour half, so the
      #    signal survives a colourblind reader and a greyscale print.
      assert low_readout =~ "~0.55"
      assert high_readout =~ "0.96"
      refute high_readout =~ "~"

      # 3. spoken as words, not just painted
      assert low_readout =~ ~s(aria-label="Confidence 0.55, low confidence")
      assert high_readout =~ ~s(aria-label="Confidence 0.96")
      refute high_readout =~ "low confidence"

      # And a machine-readable hook so the treatment is assertable
      # without parsing Tailwind.
      assert low_readout =~ ~s(data-low-confidence="true")
      assert high_readout =~ ~s(data-low-confidence="false")
    end

    test "the threshold is exclusive — 0.70 is not low", %{conn: conn, meeting: meeting} do
      {:ok, at} = enqueue_intent(meeting, %{classified_intent: "at_threshold", confidence: 0.70})

      {:ok, under} =
        enqueue_intent(meeting, %{classified_intent: "under_threshold", confidence: 0.69})

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      assert confidence_span(html, at.id) =~ ~s(data-low-confidence="false")
      assert confidence_span(html, under.id) =~ ~s(data-low-confidence="true")
    end

    test "a confidence the classifier never reported is not painted as bad", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, none} =
        enqueue_intent(meeting, %{classified_intent: "silent_intent", confidence: nil})

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      readout = confidence_span(html, none.id)

      assert readout =~ ~s(data-low-confidence="false")
      refute readout =~ "text-warning"
      refute readout =~ "low confidence"
    end

    test "the expanded table paints the same number the same way", %{
      conn: conn,
      meeting: meeting
    } do
      # A producer opens the table BECAUSE a row looked wrong. Showing
      # `0.55` plain there, two clicks after `~0.55` in warning tone,
      # would read as two different numbers.
      {:ok, low} = enqueue_intent(meeting, %{classified_intent: "shaky_row", confidence: 0.55})

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      html = render_click(view, "toggle_intents_expanded", %{})

      assert html =~ ~s(data-role="intents-expanded-table")

      [cell] =
        Regex.run(
          ~r/<td[^>]*data-role="intents-expanded-confidence"[^>]*>.*?<\/td>/s,
          html
        )

      assert cell =~ ~s(data-low-confidence="true")
      assert cell =~ "text-warning"
      assert cell =~ "~0.55"
      assert cell =~ "low confidence"

      IntentQueue.delete(meeting.id, low.id)
    end
  end

  describe "intents-collapse bar — X writes a correction (AC11)" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "intents-remove", name: "Intent Remove"})
      {conn, user} = authenticated_conn(conn)
      assign_producer!()
      on_exit(fn -> IntentQueue.stop(meeting.id) end)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "the X opens a reason picker before it removes anything", %{
      conn: conn,
      meeting: meeting
    } do
      # A cancel carries no reason until a human states one, and stage
      # 6's corpus requires a reason on every row — so it is collected
      # BEFORE the mutation, not invented after it.
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "picked_intent"})

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      refute html =~ ~s(data-role="intent-reason-picker")

      html = render_click(view, "intent_reason_picker_toggle", %{"intent_id" => row.id})

      assert html =~ ~s(data-role="intent-reason-picker")

      for reason <- Platform.Meetings.IntentCorrection.reasons() do
        assert html =~ ~s(data-reason="#{reason}")
      end

      # In flow, not absolutely positioned. The strip's body is
      # `overflow-y-auto`, which clips an absolute child — the menu
      # rendered with two of its four options cut off at the scroll edge,
      # which is a picker you cannot pick with.
      [picker_tag] = Regex.run(~r/<ul[^>]*data-role="intent-reason-picker"[^>]*>/, html)
      refute picker_tag =~ "absolute"

      # Still queued — opening the picker mutates nothing.
      assert [%{status: :queued}] = IntentQueue.list(meeting.id)
      assert IntentCorrections.list_for_meeting(meeting.id) == []
    end

    test "removing a :queued row deletes it and writes :removed_no_action with NO outcome", %{
      conn: conn,
      meeting: meeting,
      space: space,
      user: user
    } do
      # A row the producer pulled before it ever left the queue has no
      # dispatch outcome. Inventing one would poison the corpus with a
      # dispatch that never happened.
      participant = join_space!(space, user)
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "pulled_intent"})

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      html =
        render_click(view, "intent_remove", %{
          "intent_id" => row.id,
          "reason" => "not_actionable"
        })

      refute html =~ ~s(data-intent-id="#{row.id}")
      assert IntentQueue.list(meeting.id) == []

      assert [correction] = IntentCorrections.list_for_meeting(meeting.id)
      assert correction.correction == :removed_no_action
      assert correction.reason == :not_actionable
      assert correction.dispatch_outcome == nil
      assert correction.classified_intent == "pulled_intent"
      assert correction.transcript_chunk_excerpt == row.chunk_excerpt
      assert correction.actor_participant_id == participant.id
      assert correction.meeting_id == meeting.id
    end

    test "the dispatch_outcome is captured from the status at CLICK time", %{
      conn: conn,
      meeting: meeting
    } do
      # The cancel below moves the row. A correction stamped with the
      # post-cancel status would record the producer's own action rather
      # than where the intent had got to when they judged it wrong.
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "inflight_intent"})
      {:ok, _} = force_status(meeting, row, :dispatched)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      render_click(view, "intent_remove", %{
        "intent_id" => row.id,
        "reason" => "wrong_target"
      })

      assert [correction] = IntentCorrections.list_for_meeting(meeting.id)
      assert correction.dispatch_outcome == :dispatched
      refute correction.dispatch_outcome == :cancelled
    end

    test "removing an in-flight row with a reachable runtime shows a PENDING cancel", %{
      conn: conn,
      meeting: meeting
    } do
      # `IntentQueue.cancel/3` does NOT flip an in-flight row at signal
      # time — the row moves on `intent_ack(:cancel_honored)`. Showing
      # `:cancelled` while a subagent kept working would be exactly the
      # invisibility this task exists to remove.
      {agent, _runtime} = create_linked_agent!()
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "running_intent"})
      {:ok, _} = force_status(meeting, row, :dispatched, %{target_agent_id: agent.id})
      {:ok, _} = IntentQueue.ack(meeting.id, row.id, "higgins.moon", :working)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      html =
        render_click(view, "intent_remove", %{
          "intent_id" => row.id,
          "reason" => "wrong_intent"
        })

      # Still visible, still `:acked`, plus a pending-cancel affordance.
      assert html =~ ~s(data-intent-id="#{row.id}")
      assert html =~ ~s(data-intent-status="acked")
      assert html =~ ~s(data-pending-cancel="true")
      assert html =~ ~s(data-role="intent-pending-cancel-chip")
      assert html =~ "Cancelling"

      # And the controls are disabled so a double-tap can't double-fire.
      assert html =~ "btn-disabled"

      assert {:ok, %{status: :acked}} = IntentQueue.get(meeting.id, row.id)

      # The ack resolves it.
      {:ok, _} = IntentQueue.ack(meeting.id, row.id, "higgins.moon", :cancel_honored)

      html = render(view)
      assert html =~ ~s(data-intent-status="cancelled")
      assert html =~ ~s(data-pending-cancel="false")
    end

    test "an in-flight row with no reachable runtime lands cancelled locally", %{
      conn: conn,
      meeting: meeting
    } do
      # Nobody to ask. Leaving it in flight until the ack window expired
      # would show `:timed_out` for something that was actually cancelled.
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "orphan_intent"})
      {:ok, _} = force_status(meeting, row, :dispatched)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      html =
        render_click(view, "intent_remove", %{"intent_id" => row.id, "reason" => "other"})

      assert html =~ ~s(data-intent-status="cancelled")
      assert html =~ ~s(data-pending-cancel="false")
      assert [%{dispatch_outcome: :dispatched}] = IntentCorrections.list_for_meeting(meeting.id)
    end

    test "an unrecognised reason writes nothing and says so", %{
      conn: conn,
      meeting: meeting
    } do
      # Parsed against the corpus enum rather than `String.to_atom/1`,
      # which would let a crafted click leak atoms into the VM.
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "safe_intent"})

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      html =
        render_click(view, "intent_remove", %{
          "intent_id" => row.id,
          "reason" => "definitely_not_a_reason"
        })

      assert html =~ ~s(data-role="intents-error")
      assert IntentCorrections.list_for_meeting(meeting.id) == []
      assert [%{status: :queued}] = IntentQueue.list(meeting.id)
    end
  end

  describe "intents-collapse bar — pencil writes a correction (AC12)" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "intents-edit", name: "Intent Edit"})
      {conn, user} = authenticated_conn(conn)
      assign_producer!()
      on_exit(fn -> IntentQueue.stop(meeting.id) end)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "the pencil opens a centered modal seeded from the row", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "mislabelled_intent"})

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      refute html =~ ~s(data-role="intent-edit-modal")

      html = render_click(view, "intent_edit_open", %{"intent_id" => row.id})

      assert html =~ ~s(data-role="intent-edit-modal")
      assert html =~ ~s(data-role="intent-edit-intent")
      assert html =~ ~s(data-role="intent-edit-target")
      assert html =~ ~s(data-role="intent-edit-reason")
      assert html =~ "mislabelled_intent"
      # Nothing mutated by opening it.
      assert IntentCorrections.list_for_meeting(meeting.id) == []
    end

    test "saving writes :corrected with the corrected fields and clears the row", %{
      conn: conn,
      meeting: meeting
    } do
      target = create_agent!()
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "wrong_label"})

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      render_click(view, "intent_edit_open", %{"intent_id" => row.id})

      html =
        render_submit(view, "intent_edit_save", %{
          "intent_edit" => %{
            "intent_id" => row.id,
            "corrected_intent" => "book_followup",
            "corrected_target_agent_id" => target.id,
            "reason" => "wrong_target"
          }
        })

      refute html =~ ~s(data-role="intent-edit-modal")
      refute html =~ ~s(data-intent-id="#{row.id}")

      assert [correction] = IntentCorrections.list_for_meeting(meeting.id)
      assert correction.correction == :corrected
      assert correction.corrected_intent == "book_followup"
      assert correction.corrected_target_agent_id == target.id
      assert correction.reason == :wrong_target
      assert correction.classified_intent == "wrong_label"
      assert correction.dispatch_outcome == nil
    end

    test "correcting a live row fires the cancel AND writes the corrected fields", %{
      conn: conn,
      meeting: meeting
    } do
      {agent, runtime} = create_linked_agent!()
      PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "live_wrong_label"})
      {:ok, _} = force_status(meeting, row, :dispatched, %{target_agent_id: agent.id})
      {:ok, _} = IntentQueue.ack(meeting.id, row.id, "higgins.moon", :working)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      render_click(view, "intent_edit_open", %{"intent_id" => row.id})

      html =
        render_submit(view, "intent_edit_save", %{
          "intent_edit" => %{
            "intent_id" => row.id,
            "corrected_intent" => "schedule_review",
            "corrected_target_agent_id" => "",
            "reason" => "wrong_intent"
          }
        })

      # The cancel reaches the runtime as a MAP payload, not a tuple.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "intent_cancelled",
                       payload: %{
                         intent_id: cancelled_id,
                         subagent_id: "higgins.moon",
                         reason: :wrong_intent,
                         corrected_intent: "schedule_review",
                         corrected_target_agent_id: nil
                       }
                     },
                     1_000

      assert cancelled_id == row.id

      # Still in flight, still pending — the row moves on the ack.
      assert html =~ ~s(data-pending-cancel="true")

      assert [correction] = IntentCorrections.list_for_meeting(meeting.id)
      assert correction.correction == :corrected
      assert correction.corrected_intent == "schedule_review"
      assert correction.dispatch_outcome == :acked
    end

    test "a correction naming neither field is rejected in the modal, not silently", %{
      conn: conn,
      meeting: meeting
    } do
      # Mirrors `IntentCorrection.changeset/2`'s one cross-field rule: a
      # :corrected row that names no target is an exemplar with nothing
      # to learn from.
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "vague_intent"})

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      render_click(view, "intent_edit_open", %{"intent_id" => row.id})

      html =
        render_submit(view, "intent_edit_save", %{
          "intent_edit" => %{
            "intent_id" => row.id,
            "corrected_intent" => "   ",
            "corrected_target_agent_id" => "",
            "reason" => "other"
          }
        })

      assert html =~ ~s(data-role="intent-edit-modal")
      assert html =~ ~s(data-role="intents-error")
      assert IntentCorrections.list_for_meeting(meeting.id) == []
      assert [%{status: :queued}] = IntentQueue.list(meeting.id)
    end

    test "closing the modal mutates nothing", %{conn: conn, meeting: meeting} do
      {:ok, row} = enqueue_intent(meeting, %{classified_intent: "abandoned_intent"})

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      render_click(view, "intent_edit_open", %{"intent_id" => row.id})
      html = render_click(view, "intent_edit_close", %{})

      refute html =~ ~s(data-role="intent-edit-modal")
      assert IntentCorrections.list_for_meeting(meeting.id) == []
      assert [%{status: :queued}] = IntentQueue.list(meeting.id)
    end
  end

  describe "per-meeting intent mute — toggle + badge (task 019fbaac stage 3)" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "intent-mute", name: "Intent Mute"})
      {conn, user} = authenticated_conn(conn)
      assign_producer!()
      on_exit(fn -> IntentQueue.stop(meeting.id) end)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "an unmuted meeting renders the toggle live and NO badge", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      assert html =~ ~s(data-role="meeting-intent-mute-toggle")
      assert html =~ ~s(data-muted="false")
      refute html =~ ~s(data-role="meeting-intent-mute-badge")
    end

    test "clicking the toggle mutes: the toggle flips, the badge appears, the ROW changes",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      view |> element(~s([data-role="meeting-intent-mute-toggle"])) |> render_click()

      # `render/1`, not `render_click/1`'s return value, and that is by
      # design rather than by accident. The handler deliberately does
      # NOT assign `:intent_muted?` — it writes, and the write's
      # broadcast updates the assign. So the diff `render_click/1`
      # returns is the one produced BEFORE the LiveView has processed
      # its own broadcast, and it still reads `data-muted="false"`.
      # The next message settles it. Asserting here is what pins the
      # clicking client onto the same path as every other client: one
      # code path, so a divergence has nowhere to come from.
      html = render(view)

      assert html =~ ~s(data-muted="true")
      assert html =~ ~s(data-role="meeting-intent-mute-badge")
      # The DB assertion is the one that catches a purely-cosmetic
      # toggle — a control that repaints itself and mutes nothing.
      assert Meetings.intent_muted?(meeting.id)
    end

    test "clicking again unmutes: the toggle flips back, the badge goes, the ROW clears",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      # Mute first, and assert it took — otherwise the unmute half below
      # is satisfiable by a toggle that never did anything at all.
      # (`render/1` after the click, not the click's own return: see the
      # note in the mute test above.)
      view |> element(~s([data-role="meeting-intent-mute-toggle"])) |> render_click()
      assert render(view) =~ ~s(data-muted="true")
      assert Meetings.intent_muted?(meeting.id)

      view |> element(~s([data-role="meeting-intent-mute-toggle"])) |> render_click()
      html = render(view)

      assert html =~ ~s(data-muted="false")
      refute html =~ ~s(data-role="meeting-intent-mute-badge")
      refute Meetings.intent_muted?(meeting.id)
    end

    test "a meeting already muted before mount renders muted on first paint", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _} = Meetings.set_intent_muted(meeting.id, true)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      assert html =~ ~s(data-role="meeting-intent-mute-badge")
      assert html =~ ~s(data-muted="true")

      # Colour is not the only signal, at any width. The glyph is always
      # painted; the word is `sr-only sm:not-sr-only`, so it is in the
      # DOM and announced even on the 375px viewport where painting it
      # would push three top-bar controls off screen.
      assert html =~ "Agents muted"
      assert html =~ "hero-eye-slash"
      assert html =~ ~s(class="sr-only sm:not-sr-only")
    end

    test "LIVE, NO REJOIN: a toggle in one view reaches a SECOND already-connected view",
         %{conn: conn, meeting: meeting} do
      # The requirement this task exists for: "we are in a meeting right
      # now and we want it to stop". A control that needs a page reload
      # does not solve it, so this test never reloads or re-mounts the
      # observing view — it only re-renders the one it already has.
      {:ok, view_a, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      {conn_b, _user_b} = authenticated_conn(build_conn())
      {:ok, view_b, html_b} = live(conn_b, ~p"/meetings/#{meeting.slug}?tab=canvas")

      refute html_b =~ ~s(data-role="meeting-intent-mute-badge")
      pid_b = view_b.pid

      view_a |> element(~s([data-role="meeting-intent-mute-toggle"])) |> render_click()

      html_b = render(view_b)
      assert html_b =~ ~s(data-role="meeting-intent-mute-badge")
      assert html_b =~ ~s(data-muted="true")

      # Same process on the other side of the update: a re-mount would
      # have replaced it, and a re-mount is the rejoin the requirement
      # forbids.
      assert view_b.pid == pid_b

      # Both directions. A toggle that only propagates on mute leaves
      # the second viewer permanently believing the agents are held.
      view_a |> element(~s([data-role="meeting-intent-mute-toggle"])) |> render_click()

      html_b = render(view_b)
      refute html_b =~ ~s(data-role="meeting-intent-mute-badge")
      assert html_b =~ ~s(data-muted="false")
      assert view_b.pid == pid_b
    end

    test "another meeting's mute does not mute this view", %{conn: conn, meeting: meeting} do
      {other, _space} = create_meeting(%{slug: "intent-mute-other", name: "Other"})
      on_exit(fn -> IntentQueue.stop(other.id) end)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      # Presence half first: prove the view DOES react to its own
      # meeting, so the absence below is about the id guard and not
      # about a handler that never fires.
      {:ok, _} = Meetings.set_intent_muted(meeting.id, true)
      assert render(view) =~ ~s(data-role="meeting-intent-mute-badge")

      {:ok, _} = Meetings.set_intent_muted(meeting.id, false)
      {:ok, _} = Meetings.set_intent_muted(other.id, true)

      refute render(view) =~ ~s(data-role="meeting-intent-mute-badge")
    end

    test "a viewer without the producer role cannot mute by replaying the event", %{
      conn: conn,
      meeting: meeting
    } do
      :ok = Platform.Roles.unassign_role("meeting_producer")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")
      render_click(view, "toggle_intent_mute", %{})

      refute Meetings.intent_muted?(meeting.id)
    end

    test "the stage-mode control yields its width so the drawer toggle never leaves the viewport",
         %{conn: conn, meeting: meeting} do
      # The badge adds ~40px to a top bar that already overflowed 375px by
      # 16. Every one of those pixels lands on the LAST item in the row,
      # `chat-panel-toggle` — the only affordance that opens the drawer
      # holding the mute toggle. Measured in CDP at 375x812 before this
      # was fixed: the toggle went from 12 of its 28px visible (unmuted)
      # to −28 (muted), and a fresh load of an already-muted meeting had
      # no route back to unmuting.
      #
      # The invariant that keeps that from recurring is structural, not
      # cosmetic: the stage-mode segmented control is the bar's ONE
      # flexible region. `flex-shrink-0` there re-exports the squeeze to
      # its siblings and makes the `overflow-x-auto` beside it inert, so
      # this asserts its absence the same way the Producer-chip test above
      # asserts the chip can yield.
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=canvas")

      [control_tag] = Regex.run(~r/<div[^>]*data-stage-mode-control="active"[^>]*>/, html)

      assert control_tag =~ "overflow-x-auto"

      refute control_tag =~ "flex-shrink-0",
             "the stage-mode control must be able to yield, or the top bar exports its " <>
               "overflow to chat-panel-toggle and muting becomes a one-way door at 375px"

      # And the control it protects is still rendered, so this cannot pass
      # by the toggle having been deleted instead.
      assert html =~ ~s(data-role="chat-panel-toggle")
    end
  end

  # ── Intents-collapse test helpers ──────────────────────────────────────────

  defp assign_producer! do
    agent =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "producer-#{System.unique_integer([:positive])}",
        name: "Meeting Producer",
        status: "active"
      })

    {:ok, _} = Platform.Roles.assign_role("meeting_producer", agent.id)
    agent
  end

  defp create_agent! do
    Repo.insert!(%Platform.Agents.Agent{
      slug: "intent-target-#{System.unique_integer([:positive])}",
      name: "Intent Target",
      status: "active",
      kind: "native"
    })
  end

  defp create_linked_agent! do
    agent = create_agent!()

    user =
      Repo.insert!(%User{
        email: "runtime_#{System.unique_integer([:positive])}@example.com",
        name: "Runtime Owner",
        oidc_sub: "oidc-runtime-#{System.unique_integer([:positive])}"
      })

    {:ok, runtime} =
      Platform.Federation.register_runtime(user.id, %{
        runtime_id: "intent-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, linked} = Platform.Federation.link_agent(runtime, agent)
    {linked, runtime}
  end

  defp join_space!(space, user) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  # Enqueue through the REAL facade, keyed by the meeting's own id. The
  # ack window is pushed out so a slow CI box can't time a row out
  # mid-assertion.
  defp enqueue_intent(meeting, attrs) do
    {:ok, _pid} = IntentQueue.ensure_started(meeting.id, ack_timeout_ms: 600_000)

    IntentQueue.enqueue(
      meeting.id,
      Map.merge(
        %{
          target_role: "designer",
          confidence: 0.87,
          chunk_excerpt: "we should get someone on this",
          model_used: "test-model",
          elapsed_ms: 12,
          dedupe_key: "dk-#{System.unique_integer([:positive])}"
        },
        attrs
      )
    )
  end

  defp force_status(meeting, row, status, attrs \\ %{})
  defp force_status(_meeting, row, :queued, _attrs), do: {:ok, row}

  defp force_status(meeting, row, status, attrs),
    do: IntentQueue.transition(meeting.id, row.id, status, attrs)

  # The `chip-*` tone class on one row's status chip. Keyed off the row's
  # data-intent-id so the amber/red split is asserted per row, not
  # per document.
  defp chip_tone_for(html, intent_id) do
    with [row_html] <-
           Regex.run(
             ~r/<li[^>]*data-intent-id="#{intent_id}"[^>]*>.*?<\/li>/s,
             html
           ),
         [_, tone] <- Regex.run(~r/class="[^"]*chip-soft (chip-\w+)/, row_html) do
      tone
    else
      _ -> nil
    end
  end

  # Every `<button>` tag belonging to the intents strip. Selected by
  # `data-role="intent*"` rather than by slicing the document from the
  # `<section>` onward: the strip's sibling is an embedded ChatLive, and
  # a positional slice happily swallows the chat composer's buttons and
  # then blames THIS component for their tap targets.
  defp strip_button_tags(html) do
    ~r/<button[^>]*data-role="intent[^"]*"[^>]*>/
    |> Regex.scan(html)
    |> Enum.map(&hd/1)
  end

  # True when `role`'s element appears AFTER the intents strip's own
  # `<section>` has closed — i.e. it is not nested inside the rail whose
  # transform would trap a `position: fixed` child.
  defp overlay_outside_rail?(html, role) do
    strip_at = :binary.match(html, ~s(data-role="intents-collapse")) |> elem(0)
    overlay_at = :binary.match(html, ~s(data-role="#{role}")) |> elem(0)

    # The FIRST `</aside>` after the strip — the document also carries the
    # participant rail's aside, which closes earlier and would make any
    # placement look correct.
    {rail_close, _} =
      :binary.match(html, "</aside>", scope: {strip_at, byte_size(html) - strip_at})

    overlay_at > rail_close
  end

  defp first_id(html) do
    [_, id] = Regex.run(~r/data-role="intent-row"[^>]*data-intent-id="([^"]+)"/, html)
    id
  end

  # The confidence readout belonging to ONE row: slice the row's <li>
  # first, then pull the readout out of it. Matching `intent-confidence`
  # against the whole document would happily return a sibling row's.
  defp confidence_span(html, intent_id) do
    [row] =
      Regex.run(
        ~r/<li[^>]*data-intent-id="#{Regex.escape(intent_id)}".*?<\/li>/s,
        html
      )

    [readout] = Regex.run(~r/<span[^>]*data-role="intent-confidence"[^>]*>.*?<\/span>/s, row)
    readout
  end

  # A canvas in `space`, authored by a throwaway chat participant. The
  # participant row is the canvas author, NOT a roster fixture for the
  # tile — the tile never needs one, which is the point of the leak
  # assertions below.
  defp seed_canvas(space, attrs \\ %{}) do
    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Canvas Author",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(
        Map.merge(
          %{
            "space_id" => space.id,
            "created_by" => author.id,
            "title" => "Meeting notes"
          },
          attrs
        )
      )

    canvas
  end

  # A canonical canvas document whose only text is `token`, so an
  # assertion on the token is an assertion that THIS document reached the
  # tile — not that some unrelated markup happens to contain a substring.
  defp canvas_document_with(token, revision) do
    %{
      "version" => 1,
      "revision" => revision,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{},
        "children" => [
          %{
            "id" => "block-1",
            "type" => "markdown",
            "props" => %{"content" => token},
            "children" => []
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  defp frag(html), do: LazyHTML.from_fragment(html)

  defp count(html, selector), do: html |> frag() |> LazyHTML.query(selector) |> Enum.count()

  defp within(html, selector), do: html |> frag() |> LazyHTML.query(selector)

  # Reset `space`'s LIVE meeting presence to EXACTLY `n` humans, drawn in
  # order from `names`. Task 01a05b14 stage 3's grid tests sweep a range of
  # counts, and seeding cumulatively would make count N depend on the
  # iteration order (and quietly test N+M). Deleting first makes each
  # iteration an independent statement about that count.
  defp space_with_humans(space, names, n) do
    {:ok, room} = Meetings.ensure_room(space.id)
    Repo.delete_all(from(p in Meetings.Participant, where: p.room_id == ^room.id))

    names
    |> Enum.take(n)
    |> Enum.each(&seed_meeting_presence(space, "user", &1))

    space
  end

  # ── Canvas tile on the meeting stage (task 019ff704 stage 2) ─────────────
  #
  # The tile is a UI slot sourced from LiveView assigns. Two things have to
  # hold at once and each is asserted separately below: it must SHOW the
  # canvas (and keep showing the current one, live), and it must never be
  # mistaken for a roster entry by anything that counts participants.
  describe "canvas tile in the gallery grid and the bottom strip" do
    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{
          slug: "canvas-tile-#{System.unique_integer([:positive])}",
          name: "Canvas Tile Stage"
        })

      {conn, _user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space}
    end

    test "renders exactly one canvas tile, as the LAST cell of the gallery grid", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      canvas = seed_canvas(space)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # One cell for the human, one for the canvas — same wrapper, so the
      # grid geometry stays uniform.
      assert count(html, ~s([data-gallery-grid] [data-gallery-cell])) == 2
      assert count(html, ~s([data-gallery-grid] [data-role="canvas-tile"])) == 1

      cells = html |> frag() |> LazyHTML.query(~s([data-gallery-grid] [data-gallery-cell]))
      last_cell = cells |> Enum.to_list() |> List.last() |> LazyHTML.to_html()

      # LAST, not merely present: the canvas tile is in the final cell and
      # the face tile is not.
      assert count(last_cell, ~s([data-role="canvas-tile"])) == 1
      assert count(last_cell, ~s(.meeting-video-tile)) == 0

      # Distinct dom id prefix from the strip instance.
      assert html
             |> frag()
             |> LazyHTML.query(~s([data-gallery-grid] [data-role="canvas-tile"]))
             |> LazyHTML.attribute("id") == ["gallery-canvas-tile-#{canvas.id}"]
    end

    test "the canvas tile occupies the same cell geometry as a face tile, whatever it contains",
         %{conn: conn, meeting: meeting, space: space} do
      # Rowan rejected the first build partly because content dictated the
      # tile's size: a tall canvas grew its cell and pushed a neighbouring
      # face tile out of line. Two canvases are rendered here — a one-liner
      # and a 200-block monster — and the assertion is that the tile's
      # geometry-bearing attributes are IDENTICAL between them. The small
      # fixture alone would pass against the rejected build, which is exactly
      # why both are here.
      seed_meeting_presence(space, "user", "Ada Human")

      tile_geometry = fn doc ->
        {m, s} =
          create_meeting(%{
            slug: "canvas-geo-#{System.unique_integer([:positive])}",
            name: "Canvas Geometry"
          })

        seed_meeting_presence(s, "user", "Ada Human")
        seed_canvas(s, %{"document" => doc})

        {:ok, _view, html} = live(conn, ~p"/meetings/#{m.slug}")

        frag = frag(html)

        %{
          # The tile's own classes: what it asks of its parent.
          tile_class:
            frag
            |> LazyHTML.query(~s([data-gallery-grid] [data-role="canvas-tile"]))
            |> LazyHTML.attribute("class"),
          # The cell wrapper: the grid geometry it is placed into.
          cell_class:
            frag
            |> LazyHTML.query(~s([data-gallery-grid] [data-gallery-cell]))
            |> LazyHTML.attribute("class"),
          # The grid shape: how many rows/cols the whole grid resolves to.
          shape:
            frag
            |> LazyHTML.query(~s([data-gallery-grid]))
            |> LazyHTML.attribute("data-gallery-grid-shape"),
          html: html
        }
      end

      small = tile_geometry.(canvas_document_with("one short line", 1))

      big_doc = %{
        "version" => 1,
        "revision" => 2,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "props" => %{},
          "children" =>
            for i <- 1..200 do
              %{
                "id" => "b#{i}",
                "type" => "markdown",
                "props" => %{
                  "content" => "Line #{i} " <> String.duplicate("lorem ipsum dolor sit amet ", 12)
                },
                "children" => []
              }
            end
        },
        "theme" => %{},
        "bindings" => %{},
        "meta" => %{}
      }

      large = tile_geometry.(big_doc)

      # The fixtures really are different documents — without this the
      # equality below could be two renders of the same thing.
      assert large.html =~ "Line 200"
      refute small.html =~ "Line 200"

      assert small.tile_class == large.tile_class
      assert small.cell_class == large.cell_class
      assert small.shape == large.shape

      # And the tile is placed in the SAME wrapper the face tiles use, so its
      # sizing comes from the shared `[data-gallery-cell]` container query
      # rather than from anything canvas-specific.
      assert count(large.html, ~s([data-gallery-cell] > [data-role="canvas-tile"])) == 1
      assert count(large.html, ~s([data-gallery-cell] > .meeting-video-tile)) == 1

      # The document is out of flow inside the tile — the structural reason
      # the equality above holds rather than a coincidence of class strings.
      assert count(
               large.html,
               ~s([data-role="canvas-tile-content"].overflow-hidden [data-role="canvas-tile-preview"].absolute)
             ) == 1
    end

    test "the grid shape accounts for the canvas cell without it becoming a participant", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      seed_canvas(space)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      shape =
        html
        |> frag()
        |> LazyHTML.query(~s([data-gallery-grid]))
        |> LazyHTML.attribute("data-gallery-grid-shape")

      # One human + the canvas cell = a TWO-cell grid, even though the
      # participant count is one. If the tile were laundered through the
      # participant list this would read as the one-cell shape, and
      # `data-gallery-tile-count` would read "2".
      assert shape == [PlatformWeb.MeetingLive.gallery_grid_class(2, :shell)]
      assert shape != [PlatformWeb.MeetingLive.gallery_grid_class(1, :shell)]

      assert html
             |> frag()
             |> LazyHTML.query(~s([data-placeholder="center-stage"][data-gallery-tile-count]))
             |> LazyHTML.attribute("data-gallery-tile-count") == ["1"]
    end

    test "no canvas means no tile in either surface", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert count(html, ~s([data-role="canvas-tile"])) == 0

      canvas_html =
        view |> element(~s([data-stage-mode-button="canvas"])) |> render_click()

      assert count(canvas_html, ~s([data-role="canvas-tile"])) == 0
      # The empty-state CTA stays the only canvas affordance.
      assert count(canvas_html, ~s([data-empty-state="canvas"])) == 1
    end

    test "the bottom strip carries the tile in canvas mode under a distinct dom id", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      canvas = seed_canvas(space)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html = view |> element(~s([data-stage-mode-button="canvas"])) |> render_click()

      assert count(html, ~s([data-pane="bottom-strip"] [data-role="canvas-tile"])) == 1

      assert html
             |> frag()
             |> LazyHTML.query(~s([data-pane="bottom-strip"] [data-role="canvas-tile"]))
             |> LazyHTML.attribute("id") == ["strip-canvas-tile-#{canvas.id}"]

      # The strip is hidden in gallery mode, so exactly one instance is on
      # screen at a time — the ids differ so morphdom mounts/destroys rather
      # than moving the node between surfaces.
      gallery_html = view |> element(~s([data-stage-mode-button="gallery"])) |> render_click()
      assert count(gallery_html, ~s([data-pane="bottom-strip"])) == 0
      assert count(gallery_html, ~s([data-role="canvas-tile"])) == 1
    end

    # ANTI-VACUITY. "A tile element exists" is satisfied by a tile that
    # renders once at mount and never moves again — which is the exact
    # failure this ticket exists to prevent. So: drive a REAL canvas write
    # through `Chat.update_canvas/3` (the path `publish_canvas_updated/1`
    # fires from), with a document whose only text is a freshly generated
    # string, and assert that string reaches the TILE's own HTML on the
    # SAME connected LiveView — having asserted it absent first, so the
    # assertion cannot pass on a document that was always there.
    test "the tile's content live-updates when its source canvas is patched", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      canvas = seed_canvas(space)

      token = "canvas-tile-live-token-#{System.unique_integer([:positive])}"

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Direction control: absent BEFORE the patch, and the tile is on
      # screen already (so a later pass cannot be explained by the tile
      # simply appearing).
      refute html =~ token
      assert count(html, ~s([data-role="canvas-tile"])) == 1

      {:ok, _updated} =
        Chat.update_canvas(:system, canvas, %{
          "document" => canvas_document_with(token, 2)
        })

      updated_html = render(view)

      tile_text =
        updated_html
        |> frag()
        |> LazyHTML.query(~s([data-role="canvas-tile"]))
        |> LazyHTML.text()

      assert tile_text =~ token

      # And the transient just-changed marker is set — once, statically.
      assert updated_html
             |> frag()
             |> LazyHTML.query(~s([data-role="canvas-tile"]))
             |> LazyHTML.attribute("data-changed") == ["true"]
    end

    test "the tile never leaks into the human or agent tile counts, and mints no participant row",
         %{conn: conn, meeting: meeting, space: space} do
      seed_meeting_presence(space, "user", "Ada Human")
      seed_meeting_presence(space, "agent", "Helper Agent")
      canvas = seed_canvas(space)

      rows_before = Repo.aggregate(Platform.Chat.Participant, :count, :id)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      html = view |> element(~s([data-stage-mode-button="canvas"])) |> render_click()

      # The tile lives in neither roster section.
      assert count(html, ~s([data-section="humans"] [data-role="canvas-tile"])) == 0
      # The strip's agents section no longer exists at all (task 01a05b14
      # stage 1) — the surviving `[data-section="agents"]` is the
      # participant RAIL's, a different surface. So the stronger claim is
      # that the canvas is not tiled as an agent anywhere.
      assert count(html, ~s([data-pane="bottom-strip"] [data-section="agents"])) == 0
      assert count(html, ~s([data-pane="bottom-strip"] [data-agent-tile])) == 0

      # The declared counts match the tiles actually rendered in each
      # section. Pinned against the rendered count rather than a literal
      # because the viewer's own presence also lands in the humans section —
      # what matters is that the canvas adds to NEITHER number.
      strip = frag(html) |> LazyHTML.query(~s([data-pane="bottom-strip"]))
      human_tiles = count(html, ~s([data-section="humans"] .meeting-video-tile))
      assert human_tiles >= 1
      assert LazyHTML.attribute(strip, "data-tile-count-humans") == [to_string(human_tiles)]

      # ...and it is genuinely rendered, so the two refutes above are not
      # vacuous.
      assert count(html, ~s([data-section="canvas"] [data-role="canvas-tile"])) == 1

      # Rendering the tile — and live-updating its canvas — inserts no
      # `chat_participants` row.
      #
      # Measured as a DELTA against a control meeting with no canvas at
      # all, not as an absolute count: mounting a meeting legitimately
      # inserts the viewer's own participant row (the embedded chat surface
      # joins), so an absolute count would fail for a reason that has
      # nothing to do with the tile. Equal deltas is the statement that
      # matters: the canvas costs zero rows.
      {:ok, _updated} =
        Chat.update_canvas(:system, canvas, %{
          "document" => canvas_document_with("second-render-token", 3)
        })

      _ = render(view)
      delta_with_canvas = Repo.aggregate(Platform.Chat.Participant, :count, :id) - rows_before

      {control_meeting, control_space} =
        create_meeting(%{
          slug: "canvas-tile-control-#{System.unique_integer([:positive])}",
          name: "No Canvas Stage"
        })

      seed_meeting_presence(control_space, "user", "Bea Human")
      seed_meeting_presence(control_space, "agent", "Second Agent")
      control_before = Repo.aggregate(Platform.Chat.Participant, :count, :id)

      {:ok, control_view, control_html} = live(conn, ~p"/meetings/#{control_meeting.slug}")
      _ = control_view |> element(~s([data-stage-mode-button="canvas"])) |> render_click()

      # Control direction check: the control really has no tile, so the
      # delta comparison is between a canvas surface and a canvas-free one.
      assert count(control_html, ~s([data-role="canvas-tile"])) == 0

      delta_without_canvas =
        Repo.aggregate(Platform.Chat.Participant, :count, :id) - control_before

      assert delta_with_canvas == delta_without_canvas
    end

    test "gallery_cell_count/2 adds the canvas cell without touching the participant count" do
      assert PlatformWeb.MeetingLive.gallery_cell_count(0, false) == 0
      assert PlatformWeb.MeetingLive.gallery_cell_count(0, true) == 1
      assert PlatformWeb.MeetingLive.gallery_cell_count(3, false) == 3
      assert PlatformWeb.MeetingLive.gallery_cell_count(3, true) == 4
    end
  end

  # ── Per-session canvas selection + picker (task 019ff704 stage 3) ────────
  #
  # The picker exists so a participant can choose which canvas they are
  # looking at. The selection is a per-socket assign, so the property that
  # actually matters — one person's choice cannot move another person's
  # view — is structural rather than enforced by a rule somewhere.
  describe "canvas picker" do
    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{
          slug: "canvas-picker-#{System.unique_integer([:positive])}",
          name: "Canvas Picker"
        })

      {conn, _user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space}
    end

    # Two canvases with DISTINCT inserted_at. Same-timestamp fixtures make
    # the "most recently created wins" assertion vacuous: with a tie, the
    # ordering is whatever the query happens to return, so the assertion
    # would pass against an implementation that picked either one.
    defp seed_two_canvases(space) do
      older = seed_canvas(space, %{"title" => "Older canvas"})

      # Push the first canvas a full minute into the past. Two back-to-back
      # inserts can land close enough that the ordering is not observably
      # different, and a tie is exactly what makes the "newest wins"
      # assertion vacuous.
      older =
        older
        |> Ecto.Changeset.change(%{inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)})
        |> Repo.update!()

      newer = seed_canvas(space, %{"title" => "Newer canvas"})

      # Make created-order and updated-order DISAGREE: the older canvas is
      # the most recently TOUCHED. Without this the two orderings pick the
      # same canvas and the "most-recently-created" assertion is vacuous —
      # a mutation switching the default to `updated_at` survives it. That
      # mutation is not hypothetical: it is the change DECISION 2
      # explicitly rejects, so the test has to be able to see it.
      older =
        older
        |> Ecto.Changeset.change(%{updated_at: DateTime.utc_now()})
        |> Repo.update!()

      {older, newer}
    end

    defp open_canvas_mode(conn, meeting) do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      html = view |> element(~s([data-stage-mode-button="canvas"])) |> render_click()
      {view, html}
    end

    defp shown_canvas_id(html) do
      html
      |> frag()
      |> LazyHTML.query(~s([data-placeholder="center-stage"][data-canvas-id]))
      |> LazyHTML.attribute("data-canvas-id")
      |> List.first()
    end

    test "lists every non-deleted canvas in the space", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {older, newer} = seed_two_canvases(space)

      # A soft-deleted canvas is the direction control: without it, a
      # picker that simply listed everything would pass.
      deleted = seed_canvas(space, %{"title" => "Deleted canvas"})
      {:ok, _} = Chat.delete_canvas(deleted)

      {_view, html} = open_canvas_mode(conn, meeting)

      ids =
        html
        |> frag()
        |> LazyHTML.query(~s([data-role="canvas-picker-option"]))
        |> LazyHTML.attribute("data-canvas-id")
        |> Enum.sort()

      assert ids == Enum.sort([older.id, newer.id])
      refute deleted.id in ids

      assert count(html, ~s([data-role="canvas-picker"])) == 1
      assert html =~ "Older canvas"
      assert html =~ "Newer canvas"
      refute html =~ "Deleted canvas"
    end

    test "with no explicit selection the default is the most-recently-CREATED canvas", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {older, newer} = seed_two_canvases(space)

      # The fixture makes the two candidate rules DISAGREE, which is the
      # only condition under which this assertion tests anything:
      #   * most recently CREATED  -> newer  (what we want)
      #   * most recently UPDATED  -> older  (the rejected alternative)
      assert DateTime.compare(older.inserted_at, newer.inserted_at) == :lt
      assert DateTime.compare(older.updated_at, newer.updated_at) == :gt

      {_view, html} = open_canvas_mode(conn, meeting)

      assert shown_canvas_id(html) == newer.id
      refute shown_canvas_id(html) == older.id
    end

    test "clicking an option changes the canvas the stage container shows", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {older, newer} = seed_two_canvases(space)

      {view, html} = open_canvas_mode(conn, meeting)

      # Direction control: the OLDER canvas is not what is shown before
      # the click, so a later pass cannot be the default agreeing with us.
      assert shown_canvas_id(html) == newer.id

      after_click =
        view
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{older.id}"]))
        |> render_click()

      assert shown_canvas_id(after_click) == older.id

      # And the picker's own label follows the selection, so the control
      # never claims to be showing something it is not.
      assert after_click
             |> frag()
             |> LazyHTML.query(~s([data-role="canvas-picker-current"]))
             |> LazyHTML.text() =~ "Older canvas"

      # Choosing again goes back — the selection is not one-way.
      back =
        view
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{newer.id}"]))
        |> render_click()

      assert shown_canvas_id(back) == newer.id
    end

    test "an unknown canvas_id is ignored and the selection is unchanged", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {older, newer} = seed_two_canvases(space)

      {view, _html} = open_canvas_mode(conn, meeting)

      # Establish a selection first, so "unchanged" is a real state and
      # not just "still the default" — an implementation that reset to the
      # default on unknown input would pass without this.
      after_pick =
        view
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{older.id}"]))
        |> render_click()

      assert shown_canvas_id(after_pick) == older.id

      # A canvas that exists but lives in ANOTHER space: the clamp is
      # about membership of THIS meeting's set, not about existence.
      {_other_meeting, other_space} =
        create_meeting(%{slug: "other-#{System.unique_integer([:positive])}", name: "Other"})

      foreign = seed_canvas(other_space, %{"title" => "Foreign canvas"})

      for bogus <- [Ecto.UUID.generate(), foreign.id, "not-a-uuid", ""] do
        after_bogus = render_click(view, "select_meeting_canvas", %{"canvas_id" => bogus})

        assert shown_canvas_id(after_bogus) == older.id,
               "canvas_id #{inspect(bogus)} moved the selection"

        refute after_bogus =~ "Foreign canvas"
      end

      # Sanity: the LV is still alive and still switchable after all that.
      assert view
             |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{newer.id}"]))
             |> render_click()
             |> shown_canvas_id() == newer.id
    end

    test "one viewer's selection does not move another viewer's view", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {older, newer} = seed_two_canvases(space)

      {viewer_a, _} = open_canvas_mode(conn, meeting)
      {viewer_b, html_b} = open_canvas_mode(conn, meeting)

      assert shown_canvas_id(html_b) == newer.id

      _ =
        viewer_a
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{older.id}"]))
        |> render_click()

      # B is a separate LiveView process. If the selection were persisted
      # to a shared row or broadcast, B would have moved.
      assert shown_canvas_id(render(viewer_b)) == newer.id
      assert shown_canvas_id(render(viewer_a)) == older.id
    end

    test "a peer's new canvas joins the picker without yanking a viewer who chose", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {older, _newer} = seed_two_canvases(space)

      {view, _html} = open_canvas_mode(conn, meeting)

      _ =
        view
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{older.id}"]))
        |> render_click()

      # A peer creates a canvas. Driven through the real context so the
      # real broadcast fires.
      third = seed_canvas(space, %{"title" => "Peer canvas"})

      html = render(view)

      # It is reachable...
      assert count(html, ~s([data-role="canvas-picker-option"][data-canvas-id="#{third.id}"])) ==
               1

      assert html =~ "Peer canvas"

      # ...but it did NOT take over the view of someone who had chosen.
      assert shown_canvas_id(html) == older.id
    end

    test "resolve_meeting_canvas/2 falls back when the selection no longer resolves" do
      a = %Platform.Chat.Canvas{id: Ecto.UUID.generate(), title: "A"}
      b = %Platform.Chat.Canvas{id: Ecto.UUID.generate(), title: "B"}

      # No pick -> the default (last, i.e. most recently created).
      assert PlatformWeb.MeetingLive.resolve_meeting_canvas([a, b], nil) == b

      # A live pick wins over the default.
      assert PlatformWeb.MeetingLive.resolve_meeting_canvas([a, b], a.id) == a

      # A pick that no longer names a live canvas falls back rather than
      # blanking the stage at someone whose canvas was deleted.
      assert PlatformWeb.MeetingLive.resolve_meeting_canvas([a, b], Ecto.UUID.generate()) == b

      # Empty space -> nil, which is what drives the empty-state CTA.
      assert PlatformWeb.MeetingLive.resolve_meeting_canvas([], nil) == nil
      assert PlatformWeb.MeetingLive.resolve_meeting_canvas([], a.id) == nil
    end

    test "the picker is persistent, not hover-revealed, and its rows are touch-sized", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_two_canvases(space)

      {_view, html} = open_canvas_mode(conn, meeting)

      picker =
        html
        |> frag()
        |> LazyHTML.query(~s([data-role="canvas-picker"]))
        |> LazyHTML.to_html()

      # `hover:` variants compile inside `@media (hover: hover)` and never
      # match on touch, so a hover-gated control is INVISIBLE on a phone
      # rather than merely quiet. None of the picker's own visibility may
      # depend on one.
      refute picker =~ "hover:opacity"
      refute picker =~ "group-hover:"
      refute picker =~ "hover:visible"

      # Touch targets match the existing meeting buttons.
      options = html |> frag() |> LazyHTML.query(~s([data-role="canvas-picker-option"]))
      assert Enum.count(options) == 2

      for class <- LazyHTML.attribute(options, "class") do
        assert class =~ "min-h-11", "picker option is not a touch-sized target: #{class}"
        # The name yields space, the marker never does.
        assert class =~ "truncate" or picker =~ "truncate"
      end

      # The selected row is marked with --color-primary, and exactly one
      # row is marked.
      assert count(html, ~s([data-role="canvas-picker-option"][data-selected="true"])) == 1
    end

    test "no canvas means no picker — the empty-state CTA stays the only affordance", %{
      conn: conn,
      meeting: meeting
    } do
      {_view, html} = open_canvas_mode(conn, meeting)

      assert count(html, ~s([data-role="canvas-picker"])) == 0
      assert count(html, ~s([data-empty-state="canvas"])) == 1
    end
  end

  # ── Hold the choice, signal the change (task 019ff704 stage 4) ───────────
  #
  # The behaviour under test is a NON-EVENT: the view does not move. That
  # is hard to test honestly, because "the id is still X" passes just as
  # well against a page that never rendered, a LiveView that died, or a
  # fixture where X was the only candidate. Every test below therefore
  # pins the id BEFORE the event as a direction control, and every
  # fixture makes the non-selected canvas the NEWEST — the one the
  # default rule (`List.last/1` over an oldest-first list) would pick.
  # Against a single-canvas fixture, or one where the selection happens
  # to be the newest anyway, "unchanged" is true by construction and the
  # suppression could be deleted entirely without reddening anything.
  describe "canvas changed-signal" do
    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{
          slug: "canvas-signal-#{System.unique_integer([:positive])}",
          name: "Canvas Signal"
        })

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space, user: user}
    end

    # Ids of the canvases currently wearing a changed-dot in the picker.
    defp dotted_canvas_ids(html) do
      html
      |> frag()
      |> LazyHTML.query(~s([data-role="canvas-changed-dot"]))
      |> LazyHTML.attribute("data-canvas-id")
      |> Enum.sort()
    end

    # A real write through the real context, so the real broadcast fires.
    # `revision` lives inside the canonical document, not on the schema.
    defp patch_canvas(canvas, revision) do
      token = "canvas-signal-token-#{System.unique_integer([:positive])}"

      {:ok, updated} =
        Chat.update_canvas(:system, canvas, %{"document" => canvas_document_with(token, revision)})

      updated
    end

    test "a peer's edit to the canvas you did NOT choose leaves your view alone and dots the picker",
         %{conn: conn, meeting: meeting, space: space} do
      {older, newer} = seed_two_canvases(space)

      {view, html} = open_canvas_mode(conn, meeting)

      # Direction control #1: before any pick, the default is the NEWEST.
      # This is what makes the fixture bite — the canvas that is about to
      # change is the one the default rule wants to show.
      assert shown_canvas_id(html) == newer.id

      picked =
        view
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{older.id}"]))
        |> render_click()

      # Direction control #2: the pick actually moved the view, so the
      # "unchanged" assertions below are about suppression rather than
      # about a click that silently did nothing.
      assert shown_canvas_id(picked) == older.id

      # Direction control #3: the list opens clean. A picker that dotted
      # everything at mount would satisfy the dot assertions below
      # without any of the change-tracking existing.
      assert dotted_canvas_ids(picked) == []

      # ── Event 1: the OTHER (newest) canvas is edited. ──
      _ = patch_canvas(newer, 2)
      after_update = render(view)

      assert shown_canvas_id(after_update) == older.id,
             "an edit to a canvas the viewer did not choose moved their view"

      assert dotted_canvas_ids(after_update) == [newer.id]

      # The canvas ON SCREEN is never dotted — the news is elsewhere.
      refute older.id in dotted_canvas_ids(after_update)

      # ── Event 2: a peer CREATES a canvas, which is now the newest. ──
      third = seed_canvas(space, %{"title" => "Peer canvas"})
      after_create = render(view)

      assert shown_canvas_id(after_create) == older.id,
             "a newly created canvas took over the view of someone who had chosen"

      # It is reachable AND announced: both halves matter. Reachable
      # without a signal is a canvas nobody knows to look at.
      assert count(
               after_create,
               ~s([data-role="canvas-picker-option"][data-canvas-id="#{third.id}"])
             ) ==
               1

      assert dotted_canvas_ids(after_create) == Enum.sort([newer.id, third.id])
    end

    test "selecting a dotted canvas clears its dot, and a later edit raises it again", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {older, newer} = seed_two_canvases(space)

      {view, _html} = open_canvas_mode(conn, meeting)

      _ =
        view
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{older.id}"]))
        |> render_click()

      _ = patch_canvas(newer, 2)
      assert dotted_canvas_ids(render(view)) == [newer.id]

      # Going to look at it spends the news.
      switched =
        view
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{newer.id}"]))
        |> render_click()

      assert shown_canvas_id(switched) == newer.id
      assert dotted_canvas_ids(switched) == []

      # ...and the news STAYS spent once you look away again. The
      # assertion directly above cannot see this: the render guard
      # suppresses the dot on whatever is on screen, so it holds even if
      # selecting never recorded a baseline at all. A mutation removing
      # the mark-seen from the select handler survived every other
      # assertion in this describe block and was caught only here —
      # without it, a canvas you had just finished reading would re-dot
      # the instant you moved off it, which is the marker crying wolf
      # about news the viewer has already consumed.
      back =
        view
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{older.id}"]))
        |> render_click()

      assert shown_canvas_id(back) == older.id
      assert dotted_canvas_ids(back) == []

      # Return to `newer` so the re-arm assertion below still describes a
      # viewer sitting on it.
      _ =
        view
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{newer.id}"]))
        |> render_click()

      # ANTI-VACUITY: the marker must be re-armable. A implementation that
      # cleared the entry permanently (rather than re-baselining it at the
      # revision seen) would pass every assertion above and then never
      # signal this canvas again for the rest of the call. Edit the canvas
      # the viewer has now moved OFF of.
      _ = patch_canvas(older, 3)
      after_second = render(view)

      assert shown_canvas_id(after_second) == newer.id
      assert dotted_canvas_ids(after_second) == [older.id]
    end

    test "an edit to the canvas you ARE looking at raises no dot", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {older, newer} = seed_two_canvases(space)

      {view, html} = open_canvas_mode(conn, meeting)
      assert shown_canvas_id(html) == newer.id

      _ = patch_canvas(newer, 2)
      after_update = render(view)

      # The view follows its own canvas's edits (that is the stage-2
      # behaviour, unchanged) and the picker stays quiet: a dot on the
      # thing already on screen is noise, not news.
      assert shown_canvas_id(after_update) == newer.id
      assert dotted_canvas_ids(after_update) == []

      # ANTI-VACUITY, and the assertion that actually has teeth. The
      # check above is satisfied by the render-level "never dot the
      # canvas on screen" guard ALONE, so it cannot see whether the
      # baseline was advanced. Move off the canvas and the difference
      # becomes observable: if `:canvas_updated` failed to re-baseline
      # the canvas the viewer watched change, it would dot the instant
      # they looked away — announcing news they had already read.
      switched =
        view
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{older.id}"]))
        |> render_click()

      assert shown_canvas_id(switched) == older.id
      assert dotted_canvas_ids(switched) == []
    end

    test "the stage-mode Canvas button carries the dot so the signal survives gallery mode", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {older, newer} = seed_two_canvases(space)

      {view, _html} = open_canvas_mode(conn, meeting)

      _ =
        view
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{older.id}"]))
        |> render_click()

      # Direction control: no indicator before anything has changed.
      gallery = view |> element(~s([data-stage-mode-button="gallery"])) |> render_click()
      assert count(gallery, ~s([data-role="canvas-changed-indicator"])) == 0

      # The picker is not even rendered here, which is precisely why the
      # mode control has to carry the signal.
      assert count(gallery, ~s([data-role="canvas-picker"])) == 0

      _ = patch_canvas(newer, 2)
      after_update = render(view)

      assert count(after_update, ~s([data-role="canvas-changed-indicator"])) == 1
      assert count(after_update, ~s([data-role="canvas-picker"])) == 0

      # It hangs off the Canvas button specifically, not just anywhere on
      # the control — the signal has to say WHERE to go.
      assert after_update
             |> frag()
             |> LazyHTML.query(
               ~s([data-stage-mode-button="canvas"] [data-role="canvas-changed-indicator"])
             )
             |> Enum.count() == 1

      # And the accessible name carries it too: `aria-label` on the button
      # suppresses inner text, so the dot alone would be silent.
      assert after_update
             |> frag()
             |> LazyHTML.query(~s([data-stage-mode-button="canvas"]))
             |> LazyHTML.attribute("aria-label")
             |> List.first() =~ "canvas changed"

      # Still no auto-switch: the mode is unchanged and so is the canvas.
      assert after_update
             |> frag()
             |> LazyHTML.query(~s([data-stage-mode-button="gallery"]))
             |> LazyHTML.attribute("data-active") == ["true"]
    end

    test "two users on the same meeting each keep their OWN canvas across an update", %{
      meeting: meeting,
      space: space
    } do
      {older, newer} = seed_two_canvases(space)
      third = seed_canvas(space, %{"title" => "Third canvas"})

      {conn_a, user_a} = authenticated_conn(build_conn())
      {conn_b, user_b} = authenticated_conn(build_conn())

      # Two DIFFERENT users. Same-user sessions would still exercise the
      # per-socket assign, but they could not distinguish it from state
      # keyed on the user — which is a shape that would break exactly
      # here and nowhere else.
      refute user_a.id == user_b.id

      {view_a, _} = open_canvas_mode(conn_a, meeting)
      {view_b, _} = open_canvas_mode(conn_b, meeting)

      a_html =
        view_a
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{older.id}"]))
        |> render_click()

      b_html =
        view_b
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{newer.id}"]))
        |> render_click()

      # Direction control: the two sessions genuinely disagree before the
      # event. Identical selections would make "each kept its own"
      # unfalsifiable.
      assert shown_canvas_id(a_html) == older.id
      assert shown_canvas_id(b_html) == newer.id
      refute shown_canvas_id(a_html) == shown_canvas_id(b_html)

      # Drive an update on the canvas NEITHER of them picked.
      _ = patch_canvas(third, 2)

      assert shown_canvas_id(render(view_a)) == older.id
      assert shown_canvas_id(render(view_b)) == newer.id

      # Both are told about it, independently.
      assert dotted_canvas_ids(render(view_a)) == [third.id]
      assert dotted_canvas_ids(render(view_b)) == [third.id]

      # Now edit B's canvas. A must learn about it; B must not be dotted
      # for the canvas it is watching. One event, two correct-but-
      # different outcomes — which is the whole per-user claim.
      _ = patch_canvas(newer, 3)

      assert shown_canvas_id(render(view_a)) == older.id
      assert shown_canvas_id(render(view_b)) == newer.id

      assert dotted_canvas_ids(render(view_a)) == Enum.sort([newer.id, third.id])
      assert dotted_canvas_ids(render(view_b)) == [third.id]
    end

    test "the whole flow mints no chat_participants row and no synthetic agent participant", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {older, newer} = seed_two_canvases(space)

      {view, _html} = open_canvas_mode(conn, meeting)

      # Measured AFTER mount on purpose. Mounting a meeting legitimately
      # inserts the viewer's own participant row (the embedded chat
      # surface joins), so an absolute count would fail for a reason that
      # has nothing to do with this stage. The window is exactly the
      # select-and-signal flow this stage added.
      rows_before = Repo.aggregate(Platform.Chat.Participant, :count, :id)

      _ =
        view
        |> element(~s([data-role="canvas-picker-option"][data-canvas-id="#{older.id}"]))
        |> render_click()

      # The update path is driven with `:system`, so any participant row
      # appearing here would have been minted by the LiveView reacting to
      # the broadcast — which is the leak this asserts against.
      _ = patch_canvas(newer, 2)
      html = render(view)

      assert Repo.aggregate(Platform.Chat.Participant, :count, :id) == rows_before

      # ANTI-VACUITY: the flow really did run. Without this the row-count
      # assertion is also satisfied by a dead LiveView that rendered
      # nothing at all.
      assert shown_canvas_id(html) == older.id
      assert dotted_canvas_ids(html) == [newer.id]

      # No synthetic agent participant reached the roster either. No agent
      # presence is seeded in this meeting, so any tile here would have
      # been invented by the canvas flow — which is the specific failure
      # stage 1 removed and this stage must not reintroduce.
      assert count(html, ~s([data-agent-tile])) == 0
    end
  end

  # ── Agent tile activity (task 01a04a98) ───────────────────────────────────
  #
  # The defect was NOT a wrong state. `<.agent_tile>`'s only non-test call
  # site passed `activity_state={:idle}` as a LITERAL, so the tile could
  # render exactly one value — and `agent_tile_test.exs`, which passes the
  # attribute in directly, was green throughout. Every assertion below
  # therefore goes through `live(conn, ~p"/meetings/…")` and drives at
  # least TWO states, asserting they DIFFER.

  # The `{:agent_typing, …}` payload carries a `chat_participants` row id,
  # NOT an `agents.id`. `seed_meeting_presence/3` seeds live meeting
  # presence and knows nothing about chat membership, so the bridge's row
  # has to be seeded separately — which is also the point: two different
  # UUIDs, both called a participant id.
  defp seat_agent_in_chat(space, agent_id, display_name) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent_id,
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp agent_typing!(space, chat_participant, typing) do
    :ok =
      ChatPubSub.broadcast(
        space.id,
        {:agent_typing,
         %{space_id: space.id, participant_id: chat_participant.id, typing: typing}}
      )
  end

  # The bottom agent dock was retired in task 01a05b14 stage 1. The agent
  # tile's only remaining non-test call site is the gallery grid, which
  # admits an agent ONLY while it is in `speaking_identities` — so these
  # tests promote the agent first and then assert on the grid instance.
  # `speaking_identities` is an assign, so one promotion holds across every
  # later `render/1`.
  defp promote_agent(view, agent_id) do
    render_hook(view, "active_speakers", %{"identities" => ["agent:" <> agent_id]})
  end

  defp tile_activity(html, agent_id) do
    html
    |> frag()
    |> LazyHTML.query(~s([data-gallery-grid] [data-agent="agent:#{agent_id}"]))
    |> LazyHTML.attribute("data-activity-state")
  end

  # The rail's activity BADGE for one participant row — ring + glyph +
  # word, which replaced the single green dot for every non-idle state.
  # An idle agent has no badge at all and keeps the dot below.
  # SCOPED TO THE LEFT RAIL (task 01a0693e). Since the desktop card board landed
  # as a first-class LEFT rail beside the agents, `participant-rail` renders in
  # TWO places on the People tab — the always-visible left rail and the right
  # rail's People pane — so an unscoped `[data-component="participant-rail"]`
  # would match both and hand these helpers a two-element list. The left rail is
  # present regardless of which right-rail tab is active, so it is the stable
  # place to read one agent's activity badge.
  @left_rail_participant ~s([data-role="meeting-left-rail"] [data-component="participant-rail"] )

  defp rail_activity_state(html, participant_row_id) do
    html
    |> frag()
    |> LazyHTML.query(
      @left_rail_participant <>
        ~s([data-participant-id="#{participant_row_id}"] [data-role="agent-activity-avatar"])
    )
    |> LazyHTML.attribute("data-activity-state")
  end

  defp rail_activity_word(html, participant_row_id) do
    html
    |> frag()
    |> LazyHTML.query(
      @left_rail_participant <>
        ~s([data-participant-id="#{participant_row_id}"] [data-role="agent-activity-word"])
    )
    |> LazyHTML.text()
    |> String.trim()
  end

  # The `:delayed` second line (task 01a07400 stage 3). A separate node
  # from the word, deliberately: the reason is the protected line and it
  # wraps rather than sharing the word's row.
  defp rail_delay_reason(html, participant_row_id) do
    html
    |> frag()
    |> LazyHTML.query(
      @left_rail_participant <>
        ~s([data-participant-id="#{participant_row_id}"] [data-role="agent-activity-delay-reason"])
    )
    |> LazyHTML.text()
    |> String.trim()
  end

  defp rail_dot_class(html, participant_row_id) do
    html
    |> frag()
    |> LazyHTML.query(
      @left_rail_participant <>
        ~s([data-participant-id="#{participant_row_id}"] [data-role="agent-status-dot"])
    )
    |> LazyHTML.attribute("class")
  end

  describe "agent tile activity — the rendered state actually moves" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "tile-activity", name: "Tile Activity"})
      {conn, user} = authenticated_conn(conn)
      on_exit(fn -> IntentQueue.stop(meeting.id) end)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "ONE agent, TWO activities, and the tile renders two DIFFERENT values",
         %{conn: conn, meeting: meeting, space: space} do
      {_presence, agent_id} = seed_meeting_presence(space, "agent", "Solo Agent")
      chat_participant = seat_agent_in_chat(space, agent_id, "Solo Agent")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      html = promote_agent(view, agent_id)

      # Baseline: nothing is happening, and the tile exists to be moved.
      assert count(html, ~s([data-gallery-grid] [data-agent-tile])) == 1
      assert tile_activity(html, agent_id) == ["idle"]

      # Activity 1 — an intent dispatched to this agent. Driven through the
      # REAL queue, so this exercises the real shell-topic mirror.
      {:ok, row} = enqueue_intent(meeting, %{target_agent_id: agent_id})
      {:ok, _} = force_status(meeting, row, :dispatched)
      computing_html = render(view)
      assert tile_activity(computing_html, agent_id) == ["computing"]

      # Activity 2 — the same agent starts typing.
      agent_typing!(space, chat_participant, true)
      typing_html = render(view)
      assert tile_activity(typing_html, agent_id) == ["typing"]

      # THE ASSERTION: three renders of one tile, three different values.
      # A hardcoded literal — the defect — satisfies none of these but the
      # first, and the component test that passes `activity_state` in
      # directly satisfies all of them while the surface is inert.
      assert Enum.uniq([
               tile_activity(html, agent_id),
               tile_activity(computing_html, agent_id),
               tile_activity(typing_html, agent_id)
             ]) == [["idle"], ["computing"], ["typing"]]

      # And it comes back down: typing stops, the intent is still in
      # flight, so the honest answer is `computing` — not `idle`.
      agent_typing!(space, chat_participant, false)
      assert tile_activity(render(view), agent_id) == ["computing"]

      {:ok, _} = force_status(meeting, row, :completed)
      assert tile_activity(render(view), agent_id) == ["idle"]
    end

    test "TWO agents in ONE meeting render DIFFERENT activities at the same time",
         %{conn: conn, meeting: meeting, space: space} do
      {_p1, computing_id} = seed_meeting_presence(space, "agent", "Computer")
      {_p2, typing_id} = seed_meeting_presence(space, "agent", "Typist")
      {_p3, idle_id} = seed_meeting_presence(space, "agent", "Bystander")
      typing_participant = seat_agent_in_chat(space, typing_id, "Typist")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      _ =
        render_hook(view, "active_speakers", %{
          "identities" => Enum.map([computing_id, typing_id, idle_id], &("agent:" <> &1))
        })

      {:ok, row} = enqueue_intent(meeting, %{target_agent_id: computing_id})
      {:ok, _} = force_status(meeting, row, :dispatched)
      agent_typing!(space, typing_participant, true)

      html = render(view)

      # This is what a single shared assign cannot do, and what a
      # one-agent test can never catch: three tiles, three answers.
      assert count(html, ~s([data-gallery-grid] [data-agent-tile])) == 3
      assert tile_activity(html, computing_id) == ["computing"]
      assert tile_activity(html, typing_id) == ["typing"]
      assert tile_activity(html, idle_id) == ["idle"]

      # The dot is per-tile too: exactly two of the three are lit.
      assert count(html, ~s([data-gallery-grid] [data-activity-indicator])) == 2
    end

    test "an agent that is `active` in the GLOBAL agents.status column but idle in THIS meeting renders idle",
         %{conn: conn, meeting: meeting, space: space} do
      {presence, agent_id} = seed_meeting_presence(space, "agent", "Globally Busy")

      # POSITIVE CONTROL. `seed_meeting_presence/3` hardcodes
      # `status: "active"`, so this agent IS globally active — the exact
      # condition under which the old status dot rendered `bg-success` for
      # every seated agent in every meeting at once.
      assert Repo.get(Platform.Agents.Agent, agent_id).status == "active"

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      html = promote_agent(view, agent_id)

      assert tile_activity(html, agent_id) == ["idle"]
      assert count(html, ~s([data-gallery-grid] [data-activity-indicator])) == 0

      [idle_dot] = rail_dot_class(html, presence.id)
      refute idle_dot =~ "bg-success"

      # An idle agent shows the reachability dot AND is drawn as a real
      # state: a muted ring and the word "Idle". `:idle` has a producer
      # — it is what `AgentActivity.for_agent/2` computes here — so
      # drawing it states a fact. It used to be gated out of the rail
      # entirely and replaced by a bare dot, which meant three of the
      # four visual cues were absent exactly on the quiet meeting where
      # a reader most needs to read the row.
      assert rail_activity_state(html, presence.id) == ["idle"]
      assert rail_activity_word(html, presence.id) == "Idle"

      # ANTI-VACUITY. The rail is reachable and this meeting can light it
      # — it just takes activity IN THIS MEETING to do it, which is the
      # whole distinction. Without this the refute above is equally
      # satisfied by a rail that never lights at all.
      {:ok, row} = enqueue_intent(meeting, %{target_agent_id: agent_id})
      {:ok, _} = force_status(meeting, row, :dispatched)
      busy_html = render(view)

      # The badge NAMES the state rather than turning one shared dot
      # green. Before it, `agent_status_dot_class/3` mapped every
      # non-idle state to `bg-success`, so this assertion could not tell
      # `:computing` from `:typing` from `:failed`.
      #
      # `=~`, not `==`: task 01a06e07 stage 3 appends an age counter (and,
      # for this fixture — no linked voice worker — a delay clause) to the
      # SAME word node the bare word used to occupy alone.
      # CHANGED in task 01a07400 stage 3, and CORRECTED later in the same
      # stage. `seed_meeting_presence/3` inserts a bare `%Agent{}` with NO
      # `runtime_id` and no `agent_runtimes` row at all, so this fixture
      # trips TWO specific causes at once and the only question was which
      # one the `cond` reached first.
      #
      # It used to say "no voice worker in this room", because that clause
      # sat above `runtime_offline?`. That clause is no longer promotable —
      # a missing voice worker does not hold up computing, and `:speaking`
      # is not even delayable, so it had no true configuration as a state
      # (see `AgentDelayReason.specific_for_agent/1`). The row is still
      # `:delayed`, now through the cause that IS true of this fixture: the
      # agent has no reachable runtime whatsoever.
      #
      # The point of THIS test is untouched and is what the assertions
      # below still prove: the row is derived from THIS MEETING, not from
      # the global `agents.status` column. `:delayed` is a meeting-scoped
      # reading exactly as `:computing` was — and, critically, it is not
      # `:idle`, which is what the agent would read as if the meeting
      # signal had been missed.
      assert rail_activity_state(busy_html, presence.id) == ["delayed"]
      assert rail_activity_word(busy_html, presence.id) =~ "Delayed"
      refute rail_activity_word(busy_html, presence.id) =~ "Idle"
      assert rail_delay_reason(busy_html, presence.id) =~ "agent went offline"

      # The TILE surface is unchanged by stage 3 and still reads the
      # underlying signal, which is the proof the meeting signal itself is
      # `:computing` underneath the delay qualifying it.
      assert tile_activity(busy_html, agent_id) == ["computing"]
    end

    # Task 01a06e07 stage 3, correction 1 — "drive both surfaces" — and
    # correction 2 — "the ceiling is currently inert on the render path".
    # This is `/meetings`' own half of both: `MeetingHooks.schedule_agent_activity_tick/0`
    # is armed directly from `MeetingLive`'s `:show` join (not through
    # `join_call_shell/2`, which no-ops here), and the SAME
    # `:agent_activity_tick` clause `meeting_hooks_agent_typing_test.exs`
    # proves on the quickmeet handles it here too, since `MeetingHooks.attach/2`
    # installs that hook on this surface as well.
    test "a real :agent_activity_tick message advances the clock, and past the ceiling the row reads Couldn't",
         %{conn: conn, meeting: meeting, space: space} do
      {presence, agent_id} = seed_meeting_presence(space, "agent", "Ticker")

      {:ok, row} = enqueue_intent(meeting, %{target_agent_id: agent_id})
      {:ok, _} = force_status(meeting, row, :dispatched)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      before = :sys.get_state(view.pid).socket.assigns.agent_activity_now
      assert %DateTime{} = before

      html = render(view)
      # "Delayed", not "Thinking": this fixture seeds no voice runtime, so
      # the row carries a specific delay cause, which task 01a07400 stage 2
      # promotes to a state. What this test is about is the CLOCK, and the
      # clock is unaffected — `:delayed` qualifies the working state without
      # restarting its age, so the ceiling below still fires on schedule.
      assert rail_activity_word(html, presence.id) =~ "Delayed"

      send(view.pid, :agent_activity_tick)
      # `render/1` is a synchronous round trip through the SAME mailbox
      # `send/2` just enqueued onto, so by the time it returns the tick's
      # `handle_info/2` clause has already run.
      _ = render(view)

      after_tick = :sys.get_state(view.pid).socket.assigns.agent_activity_now

      assert DateTime.compare(after_tick, before) == :gt,
             "the tick fired but @agent_activity_now did not move — /meetings' rail " <>
               "ages would be as frozen as the quickmeet's were before this stage"

      # Backdate the SAME row's stamp past `AgentActivity.ceiling_seconds/0`
      # (120s), through `Phoenix.Component.assign/3` rather than a bare
      # state mutation — LiveView's diff engine gates a nested component's
      # re-render on `socket.assigns.__changed__`, which only `assign/3`/
      # `update/3` maintain; a raw `put_in` on the process state changes
      # the VALUE but leaves the diff thinking `:agent_activity` never
      # moved, and the next render silently reuses the pre-backdate HTML.
      stale_at =
        DateTime.add(
          DateTime.utc_now(),
          -(Platform.Meetings.AgentActivity.ceiling_seconds() + 1),
          :second
        )

      :sys.replace_state(view.pid, fn state ->
        activity = state.socket.assigns.agent_activity
        backdated = %{activity | computing: Map.put(activity.computing, agent_id, stale_at)}
        %{state | socket: Phoenix.Component.assign(state.socket, :agent_activity, backdated)}
      end)

      send(view.pid, :agent_activity_tick)
      capped_html = render(view)

      # Stage 1 (`61d4e616`) shipped `resolve_at/2`'s 120s ceiling
      # unit-tested but never called from any render path — `for_agent/2`
      # is what `participant_rail.ex` called, and it has no ceiling. This
      # is the render-level proof the ceiling now actually reaches the
      # screen, on the authenticated `/meetings` surface.
      assert rail_activity_word(capped_html, presence.id) =~ "Couldn't"
      assert rail_activity_state(capped_html, presence.id) == ["failed"]
    end

    # The stage spec's own example: "Thinking · 47s · reply budget resets
    # in 13s". `Meetings.say/4`'s own path needs a minted LiveKit token and
    # a resolved voice runtime, neither of which this test wires up — and
    # the budget check happens BEFORE either, so seeding the exact ledger
    # `Meetings.reply_budget_exhausted?/2` reads is the honest way to
    # reach "exhausted" without faking a whole voice call.
    test "a still-computing agent's row carries the SPECIFIC reply-budget clause",
         %{conn: conn, meeting: meeting, space: space} do
      {presence, agent_id} = seed_meeting_presence(space, "agent", "Budgeted")
      room = Platform.Meetings.get_active_room(space.id)
      now_ms = System.monotonic_time(:millisecond)

      for _ <- 1..Platform.Meetings.meeting_say_budget_per_minute() do
        Platform.Meetings.SayRegistry.ledger_put(Platform.Types.UUIDv7.generate(), %{
          room_id: room.id,
          room_name: room.livekit_room_name,
          agent_id: agent_id,
          at_ms: now_ms
        })
      end

      {:ok, row} = enqueue_intent(meeting, %{target_agent_id: agent_id})
      {:ok, _} = force_status(meeting, row, :dispatched)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      html = render(view)

      # CHANGED in task 01a07400 stage 3, and this is the canonical case
      # for the change. An exhausted reply budget is one of the four
      # SPECIFIC causes, and stage 2's `Delayed` promotes those from a
      # trailing note to a state of their own: an agent whose budget has
      # not reset is not merely slow, it is blocked, and the direction
      # (canvas 01a07402-99e3) gives that its own word and its own line.
      #
      # The clause therefore moves OFF the word node and onto the protected
      # second line — the one that "truncates last" — rather than being
      # appended to the counter it used to share a row with.
      assert rail_activity_word(html, presence.id) =~ "Delayed"
      refute rail_activity_word(html, presence.id) =~ "reply budget resets in"
      assert rail_delay_reason(html, presence.id) =~ "reply budget resets in"
      assert rail_activity_state(html, presence.id) == ["delayed"]

      # The delay QUALIFIES the working state rather than replacing what
      # produced it: the socket's own pre-delay struct still reads the
      # in-flight intent row underneath.
      assert Platform.Meetings.AgentActivity.for_agent(
               :sys.get_state(view.pid).socket.assigns.agent_activity,
               agent_id
             ) == :computing
    end

    test "a socket that mounts AFTER the dispatch hydrates the in-flight state",
         %{conn: conn, meeting: meeting, space: space} do
      {_presence, agent_id} = seed_meeting_presence(space, "agent", "Already Working")

      # The signal happens BEFORE anybody is watching. This is the board
      # ticket's "avatar stuck on thinking" in reverse: a mount that does
      # not hydrate shows a working agent as idle forever.
      {:ok, row} = enqueue_intent(meeting, %{target_agent_id: agent_id})
      {:ok, _} = force_status(meeting, row, :dispatched)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      html = promote_agent(view, agent_id)

      assert tile_activity(html, agent_id) == ["computing"]

      # ANTI-VACUITY: hydration read the queue, it did not default to
      # `computing`. A second, later socket over a COMPLETED row mounts idle.
      {:ok, _} = force_status(meeting, row, :completed)
      assert tile_activity(render(view), agent_id) == ["idle"]

      {:ok, view2, _} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert tile_activity(promote_agent(view2, agent_id), agent_id) == ["idle"]
    end

    test "a HUMAN typing in the meeting chat lights no agent tile",
         %{conn: conn, meeting: meeting, space: space} do
      {_presence, agent_id} = seed_meeting_presence(space, "agent", "Innocent Agent")
      {human_participant, _message} = seed_message(space, "A Person", "hello")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      _ = promote_agent(view, agent_id)

      agent_typing!(space, human_participant, true)
      assert tile_activity(render(view), agent_id) == ["idle"]

      # ANTI-VACUITY: the same broadcast shape from the AGENT's chat
      # participant does land, so the refutation is about the bridge and
      # not about a handler that ignores the event entirely.
      agent_participant = seat_agent_in_chat(space, agent_id, "Innocent Agent")
      agent_typing!(space, agent_participant, true)
      assert tile_activity(render(view), agent_id) == ["typing"]
    end

    test "activity from ANOTHER meeting never reaches this one",
         %{conn: conn, meeting: meeting, space: space} do
      {_presence, agent_id} = seed_meeting_presence(space, "agent", "Shared Agent")
      {other_meeting, _other_space} = create_meeting(%{slug: "tile-activity-other"})
      on_exit(fn -> IntentQueue.stop(other_meeting.id) end)

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      _ = promote_agent(view, agent_id)

      {:ok, other_row} = enqueue_intent(other_meeting, %{target_agent_id: agent_id})
      {:ok, _} = force_status(other_meeting, other_row, :dispatched)

      assert tile_activity(render(view), agent_id) == ["idle"]

      # ANTI-VACUITY: the same agent, the same transition, this meeting.
      {:ok, row} = enqueue_intent(meeting, %{target_agent_id: agent_id})
      {:ok, _} = force_status(meeting, row, :dispatched)
      assert tile_activity(render(view), agent_id) == ["computing"]
    end
  end

  # ── The bottom agent dock is retired (task 01a05b14 stage 1) ────────────
  #
  # Task 01a059e4 stage 2 made the bottom strip render in gallery mode
  # carrying ONLY an agents section. This task removes the agent dock
  # outright: agents live in the participant rail, and are tiled only while
  # SPEAKING, in the gallery grid. The strip survives as the humans +
  # canvas footer in canvas / screen / whiteboard modes — deleting it there
  # would kill the `[data-local-video-dock][data-dock-mode="strip"]`
  # reparent target and with it local video in those modes.
  describe "the retired bottom agent dock" do
    setup %{conn: conn} do
      # One test in this block renders the JOINED state through
      # `meeting_join`, which needs LiveKit creds to be present or the
      # join fails with `:livekit_not_configured` and `@in_meeting` stays
      # false. The test runtime config sets none (same reason as the
      # "LiveKit wiring" block above), so stash a fake triple for this
      # block and restore on exit. Without this the block only passed on
      # a host that happened to export LIVEKIT_* (stage 5 finding).
      original = Application.get_env(:platform, :livekit, [])

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: "test-livekit-secret-0123456789abcdef",
        url: "wss://livekit.test"
      )

      on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

      {meeting, space} =
        create_meeting(%{
          slug: "dock-retired-#{System.unique_integer([:positive])}",
          name: "Dock Retired"
        })

      {conn, _user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space}
    end

    # THE REGRESSION. An agent participant is present and the strip is on
    # screen — the exact conditions under which the dock used to render —
    # and there is no agents section in it.
    test "an agent participant is present and the strip is rendered, yet it has no agents section",
         %{conn: conn, meeting: meeting, space: space} do
      seed_meeting_presence(space, "user", "Ada Human")
      {_presence, agent_id} = seed_meeting_presence(space, "agent", "Dockless Agent")

      {:ok, view, gallery_html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Gallery: no strip at all (and no dock hiding in one).
      assert gallery_html =~ ~s(data-stage-mode="gallery")
      assert count(gallery_html, ~s([data-pane="bottom-strip"])) == 0

      html = view |> element(~s([data-stage-mode-button="canvas"])) |> render_click()

      # DIRECTION CONTROL: the strip really is rendered, and the agent
      # really is a participant of this meeting — so the refutations below
      # are not vacuous on a missing footer or a missing agent.
      assert count(html, ~s([data-pane="bottom-strip"])) == 1

      assert Enum.any?(
               :sys.get_state(view.pid).socket.assigns.participants,
               &(&1.participant_type == "agent")
             )

      # THE CLAIM.
      assert count(html, ~s([data-pane="bottom-strip"] [data-section="agents"])) == 0
      assert count(html, ~s([data-pane="bottom-strip"] [data-agent-tile])) == 0
      assert count(html, ~s([data-role="strip-agents-label"])) == 0
      assert count(html, ~s([data-role="strip-divider"])) == 0

      # A silent agent is tiled NOWHERE in the document.
      assert count(html, ~s([data-agent-tile])) == 0

      # ...and it has not simply vanished from the meeting: the rail still
      # carries it.
      rail = ~s([data-component="participant-rail"])

      assert count(html, ~s(#{rail} [data-agent="agent:#{agent_id}"])) +
               count(html, ~s(#{rail} [data-participant-type="agent"])) > 0
    end

    # The other half of the deletion: what must SURVIVE. `meeting_client.js`
    # reparents the single persistent local `<video>` into
    # `[data-local-video-dock][data-dock-mode="strip"]`, so removing the
    # footer wholesale — the tempting simplification — kills local video in
    # canvas / screen / whiteboard.
    test "the humans strip tiles and the local-video dock survive the removal",
         %{conn: conn, meeting: meeting, space: space} do
      seed_meeting_presence(space, "user", "Ada Human")
      seed_meeting_presence(space, "agent", "Dockless Agent")

      {:ok, view, _} = live(conn, ~p"/meetings/#{meeting.slug}")
      html = view |> element(~s([data-stage-mode-button="canvas"])) |> render_click()

      assert count(html, ~s([data-pane="bottom-strip"] [data-section="humans"])) == 1
      assert count(html, ~s([data-pane="bottom-strip"] [data-meeting-video-tile])) >= 1
      assert count(html, ~s([data-local-video-dock][data-dock-mode="strip"])) == 1

      # The declared human counter still matches the tiles rendered, and
      # the retired agent counter is gone rather than lying about zero.
      strip = html |> frag() |> LazyHTML.query(~s([data-pane="bottom-strip"]))
      human_tiles = count(html, ~s([data-section="humans"] [data-meeting-video-tile]))
      assert human_tiles >= 1
      assert LazyHTML.attribute(strip, "data-tile-count-humans") == [to_string(human_tiles)]
      assert LazyHTML.attribute(strip, "data-tile-count-agents") == []
    end

    # `agent_tile.ex` itself is KEPT — it is what renders a SPEAKING agent
    # promoted into the gallery grid. Only its dock call site died.
    test "the agent tile component still has a live call site: the speaking gallery promotion",
         %{conn: conn, meeting: meeting, space: space} do
      seed_meeting_presence(space, "user", "Ada Human")
      {_presence, agent_id} = seed_meeting_presence(space, "agent", "Loud Agent")

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert count(html, ~s([data-agent-tile])) == 0

      promoted = promote_agent(view, agent_id)
      assert count(promoted, ~s([data-gallery-grid] [data-agent-tile])) == 1
      assert count(promoted, ~s([data-pane="bottom-strip"] [data-agent-tile])) == 0
    end
  end

  # The `active_speakers` push comes from the `MeetingRoom` JS hook, which
  # is mounted on `#meeting-room` INSIDE this LiveView. A hook's
  # `pushEvent` ignores `phx-target`, so it lands on the root LV — which is
  # why `render_hook(view, ...)` (root-targeted) is the honest simulation
  # and why the handler must not be moved into a LiveComponent.
  defp speaking_ring?(html, identity) do
    classes =
      html
      |> frag()
      |> LazyHTML.query(~s([data-participant="#{identity}"]))
      |> LazyHTML.attribute("class")

    classes != [] and Enum.any?(classes, &(&1 =~ "ring-primary"))
  end

  defp first_gallery_identity(html) do
    html
    |> frag()
    |> LazyHTML.query(~s([data-gallery-grid] [data-participant]))
    |> LazyHTML.attribute("data-participant")
    |> List.first()
  end

  describe "active speakers → speaking ring + agent promotion (stage 3)" do
    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{
          slug: "active-speakers-#{System.unique_integer([:positive])}",
          name: "Active Speakers"
        })

      {conn, _user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space}
    end

    test "a human identity in the payload gains ring-primary; an empty list clears it",
         %{conn: conn, meeting: meeting, space: space} do
      seed_meeting_presence(space, "user", "Ada Speaker")

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      identity = first_gallery_identity(html)
      assert is_binary(identity), "expected a gallery tile with data-participant"

      # DIRECTION CONTROL: nobody is speaking on mount, so the ring is absent.
      # Without this the assertion below could pass on a tile that always
      # carried the ring.
      refute speaking_ring?(html, identity)

      speaking_html = render_hook(view, "active_speakers", %{"identities" => [identity]})
      assert speaking_ring?(speaking_html, identity)

      cleared_html = render_hook(view, "active_speakers", %{"identities" => []})
      refute speaking_ring?(cleared_html, identity)
    end

    test "a speaking agent is promoted into the gallery grid; a silent one is not",
         %{conn: conn, meeting: meeting, space: space} do
      seed_meeting_presence(space, "user", "Ada Speaker")
      seed_meeting_presence(space, "agent", "Promo Agent")

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-stage-mode="gallery")

      agent_identity =
        :sys.get_state(view.pid).socket.assigns.participants
        |> Enum.find(&(&1.participant_type == "agent"))
        |> PlatformWeb.MeetingLive.agent_gallery_identity()

      assert agent_identity =~ ~r/^agent:.+/

      # DIRECTION CONTROL: a silent agent is tiled NOWHERE — the bottom
      # dock was retired in task 01a05b14 stage 1, so the rail is its only
      # surface until it speaks.
      assert count(html, ~s([data-gallery-grid] [data-agent-tile])) == 0
      assert count(html, ~s([data-agent-tile])) == 0

      # NOTE: `data-gallery-tile-count` is deliberately NOT asserted here.
      # The human roster is presence-driven and the viewer's own auto-join
      # lands asynchronously, so the number drifts (1 on mount, 3 a second
      # later) for reasons that have nothing to do with speaking. The agent
      # tile counts above and below ARE the claim.

      promoted = render_hook(view, "active_speakers", %{"identities" => [agent_identity]})

      # Grown into the grid, with the speaking ring, under a DISTINCT dom id
      # so it does not collide with its dock tile.
      assert count(promoted, ~s([data-gallery-grid] [data-agent-tile])) == 1
      assert promoted =~ ~s(id="gallery-agent-tile-#{agent_identity}")

      grid_agent_classes =
        promoted
        |> frag()
        |> LazyHTML.query(~s([data-gallery-grid] [data-agent-tile]))
        |> LazyHTML.attribute("class")

      assert Enum.any?(grid_agent_classes, &(&1 =~ "ring-primary"))

      # And it drops back out of the grid when it stops speaking.
      silent = render_hook(view, "active_speakers", %{"identities" => []})
      assert count(silent, ~s([data-gallery-grid] [data-agent-tile])) == 0
      assert count(silent, ~s([data-agent-tile])) == 0
    end

    test "a malformed payload is ignored rather than crashing the LV",
         %{conn: conn, meeting: meeting, space: space} do
      seed_meeting_presence(space, "user", "Ada Speaker")
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert render_hook(view, "active_speakers", %{"nonsense" => true})
      assert MapSet.size(:sys.get_state(view.pid).socket.assigns.speaking_identities) == 0
    end
  end

  # ── media_states → the mute overlay (task 01a0740c stage 1) ─────────────
  #
  # `MeetingClient._pushMediaStates` pushes
  # `%{"muted" => [...], "camera_off" => [...]}` on `RoomEvent.TrackMuted`
  # / `TrackUnmuted`. A hook's `pushEvent` ignores `phx-target`, so
  # `render_hook(view, ...)` (root-targeted) is the honest simulation.
  #
  # ANTI-VACUITY. Rendering `<.video_tile audio_muted?={true}>` and
  # asserting the indicator appears proves the COMPONENT, which was never
  # broken, and passes on `origin/main` today. What was broken is the two
  # bindings that fed it, and both answered the same for EVERYBODY: the
  # gallery hardcoded `false` (nobody ever muted) and the strip read
  # `attention_config["mic_on"]`, a key no writer exists for, so every
  # human carried the overlay permanently. So these tests drive the real
  # push and assert PER IDENTITY plus an exact count — a binding that
  # answers uniformly cannot pass either.
  #
  # ── Task 01a0740d stage 1 rewrote what these read ───────────────────────
  #
  # `[data-mute-indicator]` no longer exists. The tile's corner badge and
  # its separate name label became ONE `[data-tile-name-bar]` carrying the
  # name and both state slots, and the mic slot now renders in BOTH states
  # with `data-mic-state="on"|"off"`. So "is this tile muted" stopped being
  # a presence question and became a value question, which is strictly
  # stronger: an element that is always absent and an element that is
  # always present both fail a value assertion, and only the first fails a
  # presence one.
  defp tile_mic_state(html, scope, identity) do
    html
    |> frag()
    |> LazyHTML.query(~s(#{scope} [data-participant="#{identity}"] [data-role="mic-indicator"]))
    |> LazyHTML.attribute("data-mic-state")
    |> List.first()
  end

  defp tile_rendered?(html, scope, identity) do
    count(html, ~s(#{scope} [data-participant="#{identity}"])) > 0
  end

  # The ROSTER row for `identity`, as a `{mic_state, camera_state}` pair.
  # The People pane is `@active_meeting_tab`'s default, so it is in the
  # mount HTML with no tab click needed.
  defp roster_states(html, identity) do
    row =
      case Regex.run(
             ~r/<li[^>]*data-participant-identity="#{Regex.escape(identity)}".*?<\/li>/s,
             html
           ) do
        [r] -> r
        nil -> flunk("no roster row for identity #{identity}")
      end

    parsed = Floki.parse_fragment!(row)

    {
      parsed
      |> Floki.attribute(~s([data-role="mic-indicator"]), "data-mic-state")
      |> List.first(),
      parsed
      |> Floki.attribute(~s([data-role="camera-indicator"]), "data-camera-state")
      |> List.first()
    }
  end

  # The gallery TILE for `identity`, as a `{mic_state, camera_state}` pair,
  # mirroring `roster_states/2` one surface over (task 01a0740d stage 1).
  #
  # The camera slot renders ONLY when the camera is off — a tile with no
  # video already says so, and drawing "camera on" on every face spends
  # attention on the state nobody acts on. So ABSENCE is how the tile says
  # "camera on", and reading absence as a state is exactly the shape that
  # lets an assertion pass on a tile that never rendered at all. The mic
  # slot renders in BOTH states, so its presence is a real liveness check:
  # this helper flunks unless it finds one, and only then is the camera
  # slot's absence allowed to mean anything.
  defp tile_states(html, identity) do
    scope = "[data-gallery-grid]"

    mic = tile_mic_state(html, scope, identity)

    if is_nil(mic) do
      flunk("no gallery tile with a mic slot for identity #{identity}")
    end

    camera =
      html
      |> frag()
      |> LazyHTML.query(
        ~s(#{scope} [data-participant="#{identity}"] [data-role="camera-indicator"])
      )
      |> LazyHTML.attribute("data-camera-state")
      |> List.first()

    {mic, camera || "on"}
  end

  defp identity_for(view, display_name) do
    case Enum.find(
           :sys.get_state(view.pid).socket.assigns.participants,
           &(&1.display_name == display_name)
         ) do
      nil -> flunk("no live participant named #{display_name}")
      p -> PlatformWeb.MeetingLive.gallery_identity(p)
    end
  end

  describe "media_states → per-identity mute overlay (stage 1)" do
    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{
          slug: "media-states-#{System.unique_integer([:positive])}",
          name: "Media States"
        })

      seed_meeting_presence(space, "user", "Ada Muted")
      seed_meeting_presence(space, "user", "Bo Loud")

      {conn, _user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space}
    end

    test "only the identity named in the push wears the overlay in the gallery",
         %{conn: conn, meeting: meeting} do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert html =~ ~s(data-stage-mode="gallery")

      ada = identity_for(view, "Ada Muted")
      bo = identity_for(view, "Bo Loud")

      assert tile_rendered?(html, "[data-gallery-grid]", ada)
      assert tile_rendered?(html, "[data-gallery-grid]", bo)

      # DIRECTION CONTROL: every tile reads "on" at mount, so the assertion
      # below cannot pass on a tile that was already drawn muted.
      assert tile_states(html, ada) == {"on", "on"}
      assert tile_states(html, bo) == {"on", "on"}

      muted = render_hook(view, "media_states", %{"muted" => [ada], "camera_off" => []})

      assert tile_states(muted, ada) == {"off", "on"}
      assert tile_states(muted, bo) == {"on", "on"}

      # EXACTLY one tile reading "off", which is the claim a per-identity
      # read has to make and a uniform one cannot: it covers Bo, the local
      # viewer's own tile, and anyone else presence adds while the test
      # runs. The mic slot is on EVERY tile now, so this counts the ones
      # whose VALUE flipped rather than the ones that exist.
      assert count(muted, ~s([data-gallery-grid] [data-mic-state="off"])) == 1

      cleared = render_hook(view, "media_states", %{"muted" => [], "camera_off" => []})
      assert tile_states(cleared, ada) == {"on", "on"}
      assert count(cleared, ~s([data-gallery-grid] [data-mic-state="off"])) == 0

      # Anti-vacuity for that zero: the slots are all still there, reading
      # "on". A count of zero "off" tiles would also be what a gallery that
      # stopped rendering mic slots entirely produces.
      assert count(cleared, ~s([data-gallery-grid] [data-mic-state="on"])) > 0
    end

    test "the bottom strip answers per identity too, not `true` for everyone",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      ada = identity_for(view, "Ada Muted")
      bo = identity_for(view, "Bo Loud")

      # The strip renders the humans only outside gallery mode.
      strip = render_click(view, "set_stage_mode", %{"mode" => "canvas"})

      assert tile_rendered?(strip, ~s([data-pane="bottom-strip"]), ada)
      assert tile_rendered?(strip, ~s([data-pane="bottom-strip"]), bo)

      # THE DEFECT, stated as a control: on the commit before task 01a0740c
      # this count equalled the number of humans in the strip before any
      # push arrived, because `!Map.get(attention_config, "mic_on", false)`
      # was true for every row `MeetingLive` builds.
      assert count(strip, ~s([data-pane="bottom-strip"] [data-mic-state="off"])) == 0
      assert tile_mic_state(strip, ~s([data-pane="bottom-strip"]), ada) == "on"
      assert tile_mic_state(strip, ~s([data-pane="bottom-strip"]), bo) == "on"

      # No `camera_off` key at all — a partial payload must fold what it has.
      muted = render_hook(view, "media_states", %{"muted" => [ada]})

      assert tile_mic_state(muted, ~s([data-pane="bottom-strip"]), ada) == "off"
      assert tile_mic_state(muted, ~s([data-pane="bottom-strip"]), bo) == "on"
      assert count(muted, ~s([data-pane="bottom-strip"] [data-mic-state="off"])) == 1
    end

    test "camera_off folds into its own assign AND reaches the tile's camera slot",
         %{conn: conn, meeting: meeting} do
      # THE OLD RULE, REWRITTEN. This test used to assert that camera_off
      # folded into its assign and added NO badge to the tile, on the
      # argument that the full-frame avatar already says "camera off" and a
      # corner badge would restate it. Task 01a0740d changed the premise
      # rather than the reasoning: the tile's two competing bottom overlays
      # became ONE name bar, so a camera slot inside it costs no new
      # overlay and no pixels fighting the video — it sits beside the name,
      # which the eye is already reading. The avatar fallback is untouched,
      # so the pair reads as "this person has their camera down" rather
      # than as a failed feed.
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
      ada = identity_for(view, "Ada Muted")
      bo = identity_for(view, "Bo Loud")

      # DIRECTION CONTROL: no camera slot anywhere at mount.
      assert tile_states(html, ada) == {"on", "on"}
      assert count(html, ~s([data-gallery-grid] [data-role="camera-indicator"])) == 0

      dark = render_hook(view, "media_states", %{"muted" => [], "camera_off" => [ada]})

      assert :sys.get_state(view.pid).socket.assigns.camera_off_identities ==
               MapSet.new([ada])

      assert tile_states(dark, ada) == {"on", "off"}
      assert tile_states(dark, bo) == {"on", "on"}

      # EXACTLY one, so a binding that answered uniformly cannot pass.
      assert count(dark, ~s([data-gallery-grid] [data-role="camera-indicator"])) == 1

      # And the avatar fallback is still there — the camera slot ADDS to it.
      assert count(dark, "[data-gallery-grid] [data-avatar-fallback]") > 0
    end

    test "the ROSTER row for the pushed identity flips, and only that row",
         %{conn: conn, meeting: meeting} do
      # THE ANTI-VACUITY CLAIM (stage 3 spec): a component test handed a
      # muted identity by hand proves the rendering, which was never the
      # broken part. This pushes the event the browser pushes and reads
      # the People roster the viewer actually looks at.
      #
      # Fails on `origin/main` twice over: there is no
      # `data-participant-identity` on a roster row to find, and the mic
      # slot there reads `mic_on?/1`, which answers `false` for every row
      # whatever any event carries.
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      ada = identity_for(view, "Ada Muted")
      bo = identity_for(view, "Bo Loud")

      # DIRECTION CONTROL: nobody reads muted at mount, so the assertion
      # below cannot pass on a row that was already drawn that way.
      assert roster_states(html, ada) == {"on", "on"}
      assert roster_states(html, bo) == {"on", "on"}

      muted = render_hook(view, "media_states", %{"muted" => [ada], "camera_off" => []})

      assert roster_states(muted, ada) == {"off", "on"}
      assert roster_states(muted, bo) == {"on", "on"}

      cleared = render_hook(view, "media_states", %{"muted" => [], "camera_off" => []})
      assert roster_states(cleared, ada) == {"on", "on"}
    end

    test "camera_off reaches the roster's camera slot AND the tile's, from one push",
         %{conn: conn, meeting: meeting} do
      # THE OLD RULE, REWRITTEN. The second half of this test's name used
      # to be "which the tile has no badge for", and that clause is now
      # false — see the rewritten test above. What survives is the claim
      # worth making: ONE `media_states` push feeds BOTH surfaces, and the
      # two agree about the same identity. Two readers that disagree about
      # whether Ada's camera is off is the drift this asserts against.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      ada = identity_for(view, "Ada Muted")
      bo = identity_for(view, "Bo Loud")

      html = render_hook(view, "media_states", %{"muted" => [], "camera_off" => [ada]})

      assert roster_states(html, ada) == {"on", "off"}
      assert roster_states(html, bo) == {"on", "on"}

      assert tile_states(html, ada) == roster_states(html, ada)
      assert tile_states(html, bo) == roster_states(html, bo)
    end

    test "the viewer's own roster row follows their own mic and camera buttons",
         %{conn: conn, meeting: meeting, space: space} do
      # LiveKit's `remoteParticipants` EXCLUDES the local participant, so
      # `:muted_identities` can never name the viewer — and the viewer's
      # own row is the one they look at most. Without
      # `MeetingLive.roster_off_set/3` folding `:mic_enabled` /
      # `:camera_enabled` in, the roster would tell everyone else's truth
      # and the viewer's lie.
      # `viewer_gallery_identity/1` resolves off `:current_participant`,
      # which mount only finds for a viewer who is a participant of the
      # meeting's chat space. Seed that, then re-mount: an unjoined viewer
      # publishes nothing and correctly gets no fold, so the fold has to
      # be exercised on the joined path.
      {:ok, probe, _} = live(conn, ~p"/meetings/#{meeting.slug}")
      user_id = :sys.get_state(probe.pid).socket.assigns.user_id

      # Tolerant of the row already existing: the probe mount's auto-join
      # may have inserted it first, and either way the guard below is the
      # one that matters.
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        display_name: "Meeting Test User",
        joined_at: DateTime.utc_now()
      })

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      me =
        PlatformWeb.MeetingLive.viewer_gallery_identity(:sys.get_state(view.pid).socket.assigns)

      refute me == "user:unknown", "the viewer has no resolvable identity in this fixture"

      assert roster_states(html, me) == {"on", "on"}

      muted = render_click(view, "meeting_toggle_mic")
      assert roster_states(muted, me) == {"off", "on"}

      # And nobody else moved: the fold is one identity wide.
      assert roster_states(muted, identity_for(view, "Ada Muted")) == {"on", "on"}

      dark = render_click(view, "meeting_toggle_camera")
      assert roster_states(dark, me) == {"off", "off"}

      back = render_click(view, "meeting_toggle_mic")
      assert roster_states(back, me) == {"on", "off"}
    end

    test "the viewer's own TILE follows their own mic and camera buttons too",
         %{conn: conn, meeting: meeting, space: space} do
      # Task 01a0740d stage 1. The same fold as the roster test above, one
      # surface over, and it became load-bearing at exactly the moment the
      # name bar started showing mic state on EVERY tile. Before that the
      # tile only drew an indicator for muted people, so a viewer whose own
      # mute was missing from `:muted_identities` simply saw nothing. Now
      # the absent fold does not omit a signal — it renders the WRONG one:
      # the viewer's own tile would say "unmuted" in so many words while
      # they are muted, which is worse than saying nothing.
      #
      # `room.remoteParticipants` excludes the local participant by
      # construction, so no `media_states` push can ever carry the viewer.
      # Only `MeetingLive.roster_off_set/3`, folding their own
      # `:mic_enabled` / `:camera_enabled`, can make their tile honest.
      {:ok, probe, _} = live(conn, ~p"/meetings/#{meeting.slug}")
      user_id = :sys.get_state(probe.pid).socket.assigns.user_id

      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        display_name: "Meeting Test User",
        joined_at: DateTime.utc_now()
      })

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      me =
        PlatformWeb.MeetingLive.viewer_gallery_identity(:sys.get_state(view.pid).socket.assigns)

      refute me == "user:unknown", "the viewer has no resolvable identity in this fixture"

      # DIRECTION CONTROL: the viewer's own tile starts unmuted, camera on.
      assert tile_states(html, me) == {"on", "on"}

      muted = render_click(view, "meeting_toggle_mic")
      assert tile_states(muted, me) == {"off", "on"}

      # And nobody else moved: the fold is one identity wide.
      assert tile_states(muted, identity_for(view, "Ada Muted")) == {"on", "on"}

      dark = render_click(view, "meeting_toggle_camera")
      assert tile_states(dark, me) == {"off", "off"}

      back = render_click(view, "meeting_toggle_mic")
      assert tile_states(back, me) == {"on", "off"}

      # The two surfaces stay in step: one fold, read the same way twice.
      assert tile_states(back, me) == roster_states(back, me)

      # THE BOTTOM STRIP TAKES THE SAME FOLD, and nothing above proves it.
      # Measured, not assumed: deleting `roster_off_set/3` from the STRIP
      # call site while leaving the gallery's intact left this entire file
      # green (417 tests, 0 failures). The gallery fold was covered and the
      # strip fold was not, so the strip could have been reverted by a
      # later refactor without a single test noticing. The strip renders
      # humans only outside gallery mode, hence the mode switch.
      strip = render_click(view, "set_stage_mode", %{"mode" => "canvas"})
      scope = ~s([data-pane="bottom-strip"])

      # DIRECTION CONTROL: the last click above turned the mic back ON, so
      # the strip must say "on" BEFORE the flip below. `tile_mic_state/3`
      # returns nil when no tile matches, so this also proves the viewer
      # actually has a tile in the strip rather than silently comparing
      # nothing.
      assert tile_mic_state(strip, scope, me) == "on"

      remuted = render_click(view, "meeting_toggle_mic")
      assert tile_mic_state(remuted, scope, me) == "off"

      # One identity wide here too.
      assert tile_mic_state(remuted, scope, identity_for(view, "Ada Muted")) == "on"
    end

    test "a malformed payload is ignored rather than crashing the LV",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      ada = identity_for(view, "Ada Muted")

      for bad <- [%{"nonsense" => true}, %{"muted" => "user:not-a-list"}, %{}] do
        render_hook(view, "media_states", bad)
        assert Process.alive?(view.pid), "crashed on #{inspect(bad)}"

        assert MapSet.size(:sys.get_state(view.pid).socket.assigns.muted_identities) == 0,
               "assigned from #{inspect(bad)}"
      end

      # Non-binary members are dropped; the binaries survive.
      render_hook(view, "media_states", %{"muted" => [1, nil, ada, %{}]})
      assert :sys.get_state(view.pid).socket.assigns.muted_identities == MapSet.new([ada])
    end
  end

  describe "top bar: live pill + roster count (task 01a05b14 stage 5)" do
    alias Platform.Meetings
    alias PlatformWeb.MeetingLive

    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{
          slug: "top-bar-#{System.unique_integer([:positive])}",
          name: "Top Bar"
        })

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    # THE NEGATIVE. A scheduled meeting whose space has no live room must
    # render NO pill — the approved target's green "meeting live" is
    # earned by an observed room, never inferred from the meeting
    # existing. Shown to detonate: loosening the `:if` to always-true
    # fails this test (stage 5 evidence).
    test "no live room, no pill", %{conn: conn, meeting: meeting, space: space} do
      assert Meetings.get_active_room(space.id) == nil

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert count(html, ~s([data-role="meeting-live-pill"])) == 0
      refute html =~ "meeting live"
    end

    test "a live room renders the pill, on the success slot, with the word as text", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      assert %Meetings.Room{status: "active"} = Meetings.get_active_room(space.id)

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert count(html, ~s(header [data-role="meeting-live-pill"])) == 1

      [pill_class] =
        html
        |> frag()
        |> LazyHTML.query(~s([data-role="meeting-live-pill"]))
        |> LazyHTML.attribute("class")

      assert pill_class =~ "text-success"
      assert pill_class =~ "rounded-full"
      assert pill_class =~ "text-[10px]"

      pill_text =
        html
        |> frag()
        |> LazyHTML.query(~s([data-role="meeting-live-pill"]))
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      assert pill_text == "meeting live"
    end

    # OBSERVED, not inferred, in the other direction too: when the room
    # finishes (the LiveKit `room_finished` webhook path) the pill goes
    # away on the presence broadcast, without a reload.
    test "the pill follows the room: it leaves when the room finishes", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
      assert count(html, ~s([data-role="meeting-live-pill"])) == 1

      room = Meetings.get_active_room(space.id)
      {:ok, _finished} = Meetings.finish_room(room)

      # `finish_room/1` broadcasts `{:meeting_presence_update, _}` on the
      # space topic; wait for the LV to process it.
      assert render(view) =~ ~s(data-role="meeting-roster-count")
      assert count(render(view), ~s([data-role="meeting-live-pill"])) == 0
    end

    test "the roster count is the rail's own partition", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      seed_meeting_presence(space, "user", "Grace Human")
      seed_meeting_presence(space, "user", "Linus Human")
      seed_meeting_presence(space, "agent", "Rail Agent")
      seed_meeting_presence(space, "agent", "Other Agent")

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      readout = html |> frag() |> LazyHTML.query(~s(header [data-role="meeting-roster-count"]))
      assert Enum.count(readout) == 1
      assert LazyHTML.attribute(readout, "data-people") == ["3"]
      assert LazyHTML.attribute(readout, "data-agents") == ["2"]
      assert LazyHTML.attribute(readout, "title") == ["3 people · 2 agents"]

      # The SAME numbers the rail draws: rows under "In this call" and
      # rows under "Agents", from the same `partition_participants/1`.
      rail = ~s([data-component="call-rail"] )

      assert count(html, rail <> ~s([data-section="humans"] li[data-participant-type="user"])) ==
               3

      assert count(html, rail <> ~s([data-section="agents"] li[data-participant-type="agent"])) ==
               2

      participants = :sys.get_state(view.pid).socket.assigns.participants
      assert MeetingLive.roster_count(participants) == {3, 2}
    end

    test "the count pluralises honestly", %{conn: conn, meeting: meeting, space: space} do
      seed_meeting_presence(space, "user", "Ada Human")
      seed_meeting_presence(space, "agent", "Rail Agent")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      readout = html |> frag() |> LazyHTML.query(~s([data-role="meeting-roster-count"]))
      assert LazyHTML.attribute(readout, "title") == ["1 person · 1 agent"]

      assert MeetingLive.roster_label({0, 0}) == "0 people · 0 agents"
      assert MeetingLive.roster_label({3, 4}) == "3 people · 4 agents"
    end

    defp people_count(html) do
      html
      |> frag()
      |> LazyHTML.query(~s([data-role="meeting-roster-count"]))
      |> LazyHTML.attribute("data-people")
    end

    test "the count follows a leave without a reload", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      seed_meeting_presence(space, "user", "Grace Human")

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
      assert people_count(html) == ["2"]

      # Broadcasts `{:meeting_presence_update, _}`; PubSub delivers to the
      # LV mailbox before returning, and `render/1` queues behind it.
      room = Meetings.get_active_room(space.id)
      {:ok, _} = Meetings.participant_left(room, "Grace Human")

      assert people_count(render(view)) == ["1"]
    end
  end

  # ── Recording indicator (task 01a0740d stage 2, FE-7) ────────────────────
  #
  # The rows are seeded by hand with `Repo.insert!`, deliberately NOT through
  # `Meetings.start_recording/2`. That function sets `meeting_rooms.status` to
  # `"recording"`, and `Meetings.get_active_room/1` matches `"active"` only, so
  # calling it would take the room out from under BOTH pills and every
  # assertion below would go green or red for a reason that has nothing to do
  # with the indicator. See `room_recording?/1` in meeting_live.ex.
  describe "top bar: recording pill (task 01a0740d stage 2)" do
    alias Platform.Meetings

    @recording_pill ~s([data-role="meeting-recording-pill"])
    @live_pill ~s([data-role="meeting-live-pill"])

    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{
          slug: "rec-pill-#{System.unique_integer([:positive])}",
          name: "Rec Pill"
        })

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    # THE NEGATIVE. A live room that is NOT being captured renders no
    # indicator at all — not a hidden one, not a grey one. A consent surface
    # that is present while nothing is recording is the failure this `:if`
    # exists to prevent.
    #
    # The word is refuted through the header's TEXT and not through the raw
    # HTML, because the markup splits it (`rec` + a `sr-only` `ording`), so
    # `html =~ "recording"` would be false even with the pill rendered — an
    # assertion that passes without the system doing anything. The aria-label
    # is refuted separately, on the raw HTML, since it is the one place the
    # claim is spelled out contiguously.
    test "a live room with no recording row renders no pill and no word", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert count(html, @live_pill) == 1
      assert count(html, @recording_pill) == 0
      refute header_text(html) =~ "recording"
      refute html =~ "being recorded"
    end

    test "a recording row renders one pill on the error slot, with the word", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      room = Meetings.get_active_room(space.id)
      seed_recording(room, "recording")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert count(html, ~s(header #{@recording_pill})) == 1

      [pill_class] = attrs(html, @recording_pill, "class")

      assert pill_class =~ "bg-error/10"
      assert pill_class =~ "border-error/40"
      assert pill_class =~ "rounded-full"
      assert pill_class =~ "text-[10px]"

      # The word is `text-base-content` and NOT `text-error`, and that is a
      # measured decision, not a preference: `text-error` on this pill's own
      # rendered fill is 2.9702:1 light / 4.4376:1 dark, under the 4.5:1 that
      # 10px text needs. `text-base-content` is 17.1452:1 / 15.7191:1.
      # Re-measure with Platform.Design.WcagContrast before changing this.
      assert pill_class =~ "text-base-content"
      refute pill_class =~ "text-error"

      # STATE does not yield at narrow widths. The roster count next to it is
      # informational and carries `hidden sm:flex`; this must not.
      refute pill_class =~ "hidden"

      # The dot carries the hue, and it is what has to clear the 3:1 non-text
      # floor (3.1799:1 light / 4.6703:1 dark on this fill).
      assert Enum.any?(attrs(html, ~s(#{@recording_pill} span), "class"), &(&1 =~ "bg-error"))

      assert pill_text(html) == "recording"
    end

    # THE ONE THAT SEPARATES A LIVE ROW FROM A STATIC FLAG. One mount, no
    # `live/2` in the middle, no remount: the pill has to appear and then
    # disappear inside the SAME view process, driven only by the row plus the
    # broadcast. An implementation that reads the recording once at mount
    # cannot pass this.
    test "the pill follows the row through a broadcast, in one mounted view", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      room = Meetings.get_active_room(space.id)

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
      assert count(html, @recording_pill) == 0

      recording = seed_recording(room, "recording")
      MeetingsPubSub.broadcast_room(room.id, {:recording_updated, recording})

      assert count(render(view), @recording_pill) == 1

      stopped =
        recording
        |> Ecto.Changeset.change(status: "processing")
        |> Repo.update!()

      MeetingsPubSub.broadcast_room(room.id, {:recording_updated, stopped})

      assert count(render(view), @recording_pill) == 0
    end

    # A failed egress is not a dead meeting. `failed` means capture stopped,
    # so the recording pill goes; the room is still live, so the green one
    # stays. The two pills are independent reads and this is where that shows.
    test "a failed recording renders no pill and leaves the live pill alone", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      room = Meetings.get_active_room(space.id)
      seed_recording(room, "failed")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      assert count(html, @recording_pill) == 0
      assert count(html, @live_pill) == 1
    end

    # THE WIDTH BUDGET. The title box is basis-driven, so it does NOT get wider
    # when a second pill moves in — the pill's 51.7px comes straight out of the
    # only `min-w-0` item in the box, and measured at 390x844 that put the
    # meeting name at 2.14px. The fix is a lighter shrink weight, and it is
    # conditional so a meeting that is NOT being recorded keeps the exact line
    # it shipped with. Both halves are asserted, because only pinning the
    # recording half would let the quiet regression back in.
    test "the title box takes a lighter shrink only while recording", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      room = Meetings.get_active_room(space.id)

      {:ok, view, quiet} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")
      [quiet_class] = attrs(quiet, ~s([data-role="meeting-title"]), "class")

      assert quiet_class =~ "shrink"
      refute quiet_class =~ "shrink-["

      recording = seed_recording(room, "recording")
      MeetingsPubSub.broadcast_room(room.id, {:recording_updated, recording})

      [loud_class] = attrs(render(view), ~s([data-role="meeting-title"]), "class")

      assert loud_class =~ "shrink-[0.2]"
      assert loud_class =~ "sm:shrink"

      # The basis is what keeps a long name truncating instead of overflowing
      # the page. It is deliberately NOT part of the trade.
      assert quiet_class =~ "basis-[60%]"
      assert loud_class =~ "basis-[60%]"
    end

    # THE TOKEN FENCE. On this surface `warning` (amber) means a human is
    # being asked for something: it is the invite honesty banner's slot and
    # the last-five-seconds colour of the FE-9 commit countdown, which renders
    # inches away. An amber recording dot would read as a demand for a
    # response that does not exist. This is the only part of that constraint a
    # machine can catch, so it is asserted rather than only written down.
    test "the pill carries no amber utility and no raw colour literal", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      seed_meeting_presence(space, "user", "Ada Human")
      room = Meetings.get_active_room(space.id)
      seed_recording(room, "recording")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      classes =
        attrs(html, @recording_pill, "class") ++
          attrs(html, ~s(#{@recording_pill} span), "class")

      assert classes != []

      for class <- classes do
        refute class =~ ~r/warning|amber|yellow|orange/i, "amber utility in #{inspect(class)}"
        refute class =~ ~r/#[0-9a-f]{3,8}\b|oklch\(/i, "raw colour literal in #{inspect(class)}"
      end
    end
  end

  # Insert a `meeting_recordings` row directly. NOT `Meetings.start_recording/2`
  # — see the describe-block note above for why that would move the room out
  # from under the test.
  defp seed_recording(room, status) do
    Repo.insert!(%Platform.Meetings.Recording{
      room_id: room.id,
      space_id: room.space_id,
      status: status
    })
  end

  defp header_text(html), do: node_text(html, "header")

  defp pill_text(html), do: node_text(html, ~s([data-role="meeting-recording-pill"]))

  defp node_text(html, selector) do
    html
    |> frag()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp attrs(html, selector, attribute) do
    html |> frag() |> LazyHTML.query(selector) |> LazyHTML.attribute(attribute)
  end
end
