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

  alias Platform.{Chat, Meetings, Repo}
  alias Platform.Accounts.User
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.IntentCorrections
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.Meetings.IntentsCollapse

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

      assert html =~ ~s(data-pane="left-rail")
      assert html =~ ~s(data-pane="center-stage")
      assert html =~ ~s(data-pane="chat-panel")
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

  describe "chat-panel header (stage 2)" do
    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{slug: "kickoff-header", name: "Stage Two Header"})

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "chat panel pane is ~320px wide on desktop (w-80)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Match the chat panel aside element + its width class. We assert
      # the order data-pane="chat-panel" + w-80 to guard the desktop
      # framing the stage 2 contract pins (~320px).
      assert html =~ ~r/data-pane="chat-panel"[^>]*w-80|w-80[^>]*data-pane="chat-panel"/
    end

    test "chat panel renders a header section with the meeting name", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-pane-section="header")
      # Meeting name appears at least twice on the page now: once in the
      # top bar and once in the chat panel header. Sanity-check it is
      # present at all and the header section exists.
      assert html =~ "Stage Two Header"
    end

    test "chat panel header drops the 'placeholder for intent panel' caption (stage 5 swap)",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Stage 5 (019e2d1a) replaced the stub MeetingChatPanelLive with
      # the real ChatLive embed. The placeholder caption that named the
      # stub as a surface-marker for the eventual intent panel is gone
      # — the pane header now carries the meeting name + chat icon
      # only. The greppable migration hook moved to the
      # `data-intent-panel-host` data-attribute on the embed wrapper.
      refute html =~ "placeholder for intent panel"
    end

    test "chat panel header uses hero-chat-bubble-left-right (no emoji)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ "hero-chat-bubble-left-right"
      # Belt-and-suspenders: no emoji codepoints in the chrome.
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

  describe "mobile drawer + toggle (stage 3)" do
    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{slug: "kickoff-drawer", name: "Drawer Meeting"})

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "mounts with :chat_panel_open false (mobile drawer default closed)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Source-of-truth: assign on the parent LV. We can't pull the
      # raw assign from the test client, so assert via the rendered
      # `data-chat-panel-open` attribute on the aside.
      html = render(view)
      assert html =~ ~s(data-chat-panel-open="false")
    end

    test "top bar renders the chat-panel toggle button (mobile-only, hero icon)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-role="chat-panel-toggle")
      # Mobile-only — the button itself carries `lg:hidden` so it
      # disappears at desktop breakpoint.
      assert html =~
               ~r/data-role="chat-panel-toggle"[^>]*lg:hidden|lg:hidden[^>]*data-role="chat-panel-toggle"/

      # phx-click event hook (the only event the parent LV handles).
      assert html =~ ~s(phx-click="toggle_chat_panel")
      # Hero-icon (no emoji codepoint).
      assert html =~ "hero-chat-bubble-left-right"
      refute html =~ "💬"
    end

    test "clicking the toggle flips :chat_panel_open and renders the backdrop", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Closed by default — no backdrop, drawer attribute reads "false".
      refute html =~ ~s(data-role="chat-panel-backdrop")
      assert html =~ ~s(data-chat-panel-open="false")

      # Open: click the top-bar toggle.
      html_after_open =
        view
        |> element(~s([data-role="chat-panel-toggle"]))
        |> render_click()

      assert html_after_open =~ ~s(data-chat-panel-open="true")
      assert html_after_open =~ ~s(data-role="chat-panel-backdrop")

      # Close: click again on the toggle.
      html_after_close =
        view
        |> element(~s([data-role="chat-panel-toggle"]))
        |> render_click()

      assert html_after_close =~ ~s(data-chat-panel-open="false")
      refute html_after_close =~ ~s(data-role="chat-panel-backdrop")
    end

    test "backdrop click also toggles the drawer closed", %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Open the drawer first via the top-bar toggle.
      _ = view |> element(~s([data-role="chat-panel-toggle"])) |> render_click()
      open_html = render(view)
      assert open_html =~ ~s(data-chat-panel-open="true")
      assert open_html =~ ~s(data-role="chat-panel-backdrop")

      # Now click the backdrop — should close.
      closed_html =
        view
        |> element(~s([data-role="chat-panel-backdrop"]))
        |> render_click()

      assert closed_html =~ ~s(data-chat-panel-open="false")
      refute closed_html =~ ~s(data-role="chat-panel-backdrop")
    end

    test "in-drawer close button (mobile-only) also toggles closed", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      _ = view |> element(~s([data-role="chat-panel-toggle"])) |> render_click()
      assert render(view) =~ ~s(data-chat-panel-open="true")

      closed_html =
        view
        |> element(~s([data-role="chat-panel-close"]))
        |> render_click()

      assert closed_html =~ ~s(data-chat-panel-open="false")
    end

    test "drawer aside is the *single* DOM host for the embedded LV (no double-mount)",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Exactly one aside with data-pane="chat-panel" — desktop column
      # and mobile drawer share one DOM node, repositioned via
      # responsive classes. Two would mean two `live_render`s with the
      # same id which would collide.
      occurrences =
        html |> String.split(~s(data-pane="chat-panel")) |> length() |> Kernel.-(1)

      assert occurrences == 1
    end

    test "drawer carries safe-area-inset-bottom + bottom-nav-height bottom offset", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Mirrors the tasks_live.html.heex:1881 pattern — drawer's bottom
      # edge sits above the iOS home indicator + bottom-nav.
      assert html =~ "bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))]"
    end

    test "drawer aside has lg:static and translate-x classes (responsive shape)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # On `<lg`: fixed slide-in (translate-x-full closed).
      # On `>=lg`: static, in-flow column, ignores assign (lg:translate-x-0).
      assert html =~ "lg:static"
      assert html =~ "translate-x-full"
      assert html =~ "lg:translate-x-0"
    end

    test "toggle button has aria-expanded reflecting :chat_panel_open", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(aria-expanded="false")

      open_html =
        view |> element(~s([data-role="chat-panel-toggle"])) |> render_click()

      assert open_html =~ ~s(aria-expanded="true")
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

    test "toggle assign flip is *idempotent* (no drift across multiple cycles)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Three open/close cycles — guards against any latent state-drift
      # bug in toggle_chat_panel that would gradually desync the
      # rendered attribute from the assign.
      for _ <- 1..3 do
        opened =
          view |> element(~s([data-role="chat-panel-toggle"])) |> render_click()

        assert opened =~ ~s(data-chat-panel-open="true")
        assert opened =~ ~s(aria-expanded="true")

        closed =
          view |> element(~s([data-role="chat-panel-toggle"])) |> render_click()

        assert closed =~ ~s(data-chat-panel-open="false")
        assert closed =~ ~s(aria-expanded="false")
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

      # Left rail + bottom strip are presentation-independent of the
      # non-gallery stage modes — they must survive a mode switch.
      assert html =~ ~s(data-pane="left-rail")
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
        assert html =~ ~s(data-pane="left-rail"),
               "left rail unmounted after switching to #{mode}"

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

      # The data-canvas-id attribute on the center stage points at the
      # newer canvas — older canvases lose to insertion-order tail.
      assert html =~ ~s(data-canvas-id="#{newer.id}")
      refute html =~ ~s(data-canvas-id="#{older.id}")
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

    test "renders the 'coming soon' placeholder card with hero-pencil-square", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="whiteboard"]))
        |> render_click()

      # The center stage swapped to the whiteboard placeholder.
      assert html =~ ~s(data-stage-mode="whiteboard")
      assert html =~ ~s(data-coming-soon="whiteboard")
      assert html =~ "hero-pencil-square"
      assert html =~ "Coming soon"
      # And the empty-state canvas CTA is NOT visible in whiteboard mode.
      refute html =~ ~s(data-empty-state="canvas")
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
      # Task 019e412a: the grid shape is participant-count-driven, and
      # 2 humans yields a vertical stack (1 col × 2 rows) so each tile
      # gets a wide-short cell where a 16:9 tile fits at near-full
      # width — much bigger than what a 2x1 horizontal split would
      # produce in a portrait gallery interior.
      assert html =~ ~s(data-gallery-grid-shape="grid-cols-1 grid-rows-2")

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
      # unique element keyed by data-gallery-grid). The grid is
      # `grid h-full w-full auto-rows-fr ... place-items-center` so
      # cells partition the visible interior with no left-over space
      # AND wrappers center in their cells (the wrapper itself fills
      # the cell as a size container for the inner tile's container
      # query).
      [_, grid_class] =
        Regex.run(~r/class="([^"]*)"\s+data-gallery-grid(?![-\w])/, html)

      grid_tokens = String.split(grid_class)

      assert "h-full" in grid_tokens
      assert "w-full" in grid_tokens
      assert "auto-rows-fr" in grid_tokens
      assert "place-items-center" in grid_tokens
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
      # Task 019e412a (v3): 3 humans → 1x3 vertical stack, so the
      # tall portrait gallery interior yields wide-short cells where
      # 16:9 tiles fit at ~462×260 instead of ~200×113.
      assert html =~ ~s(data-gallery-grid-shape="grid-cols-1 grid-rows-3")

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
      assert html =~ ~s(data-gallery-grid-shape="grid-cols-1 grid-rows-1")
    end

    test "with 6 human participants, gallery uses the responsive 1x6 / sm:3x2 grid shape",
         %{conn: conn, meeting: meeting, space: space} do
      for name <- ~w(Ada Grace Hedy Edith Karen Sophie) do
        seed_meeting_presence(space, "user", name)
      end

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-gallery-tile-count="6")

      assert html =~
               ~s(data-gallery-grid-shape="grid-cols-1 grid-rows-6 sm:grid-cols-3 sm:grid-rows-2")
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

  # ── gallery_grid_class/1 (task 019e412a) ────────────────────────────────
  #
  # Drives the responsive grid shape of the gallery wrapper based on the
  # participant count. The function returns a Tailwind class STRING (not
  # a list) so the .heex caller can splice it into a class= list literal
  # without `Enum.join`. Every literal class string MUST be statically
  # discoverable by Tailwind v4's content scanner — that's why the
  # function body avoids `"grid-cols-#{n}"` style interpolation.
  #
  # Mobile/desktop split: at <sm (<640px viewport) the layout collapses
  # to a vertical stack (or 2 cols for very high counts) so each tile
  # keeps a legible width. At sm+ the prior desktop-optimized shape is
  # restored via the `sm:` prefix. The 80px legibility floor was the
  # specific failure on the case-3 (6 participants × 390px) e2e review.
  describe "gallery_grid_class/1" do
    alias PlatformWeb.MeetingLive

    test "returns 1x1 for 0 or 1 participants (the gallery container is single-tile)" do
      assert MeetingLive.gallery_grid_class(0) == "grid-cols-1 grid-rows-1"
      assert MeetingLive.gallery_grid_class(1) == "grid-cols-1 grid-rows-1"
    end

    test "2 participants stack vertically (1x2) so each tile is wide, not narrow" do
      # The desktop gallery interior is roughly portrait (~624×780). A
      # 2-cols-1-row split yields 312×780 cells where a 16:9 tile is
      # width-bounded at 312×175 — tiny and surrounded by vertical
      # letterbox. Stacking 1x2 yields 624×390 cells where the tile
      # fits at 624×351 — ~4× the per-tile area. This was Rowan's
      # explicit feedback after the f1e16f1 fix. Already vertical on
      # mobile too, so no sm: override needed.
      assert MeetingLive.gallery_grid_class(2) == "grid-cols-1 grid-rows-2"
    end

    test "3 participants stack vertically (1x3) for the same reason as 2" do
      # 1x3 in a 624×780 container gives 624×260 cells where the 16:9
      # tile fits at 462×260 — much bigger than the 200×113 a 3x1
      # split would have produced. Already vertical on mobile too.
      assert MeetingLive.gallery_grid_class(3) == "grid-cols-1 grid-rows-3"
    end

    test "arity-2 :shell mode preserves the vertical-stack layout at count 2 and 3" do
      # The default guest-carve-out only kicks in for chrome_mode == :none.
      # Shell (the auth surface) keeps the layout Rowan validated after
      # f1e16f1: 1x2 / 1x3 for 2 or 3 participants respectively.
      assert MeetingLive.gallery_grid_class(2, :shell) == "grid-cols-1 grid-rows-2"
      assert MeetingLive.gallery_grid_class(3, :shell) == "grid-cols-1 grid-rows-3"
    end

    test "arity-2 :none mode goes side-by-side on sm+ for count 2 and 3" do
      # Guest surface has no chat panel — the stage owns the full
      # viewport. Stacking 2/3 tiles vertically there wastes horizontal
      # width; each tile becomes a narrow letterbox. On sm+ we switch
      # to side-by-side (2x1 for 2 participants, 3x1 for 3) so each
      # tile fills ~½ or ⅓ of the wide guest viewport instead. Mobile
      # (< sm) keeps the readable vertical stack.
      assert MeetingLive.gallery_grid_class(2, :none) ==
               "grid-cols-1 grid-rows-2 sm:grid-cols-2 sm:grid-rows-1"

      assert MeetingLive.gallery_grid_class(3, :none) ==
               "grid-cols-1 grid-rows-3 sm:grid-cols-3 sm:grid-rows-1"
    end

    test "arity-2 delegates to arity-1 for every other count regardless of chrome" do
      # Only 2 and 3 differ across surfaces; 0, 1, and >=4 already have
      # sensible layouts that work in both. Sanity-check a couple.
      assert MeetingLive.gallery_grid_class(1, :none) == MeetingLive.gallery_grid_class(1)
      assert MeetingLive.gallery_grid_class(4, :none) == MeetingLive.gallery_grid_class(4)
      assert MeetingLive.gallery_grid_class(9, :shell) == MeetingLive.gallery_grid_class(9)
    end

    test "4 participants stack on mobile (1x4) and form a 2x2 square at sm+" do
      assert MeetingLive.gallery_grid_class(4) ==
               "grid-cols-1 grid-rows-4 sm:grid-cols-2 sm:grid-rows-2"
    end

    test "5..6 stack on mobile (1xN) and fit a 3x2 rectangle at sm+" do
      # Case-3 of the original e2e (6 participants × 390px viewport)
      # failed when the desktop 3x2 shape was applied on mobile —
      # tiles came out 111×63, below the 80px legibility floor. The
      # mobile 1x6 layout gives 6 × ~210px tall tiles in a scrollable
      # container.
      assert MeetingLive.gallery_grid_class(5) ==
               "grid-cols-1 grid-rows-5 sm:grid-cols-3 sm:grid-rows-2"

      assert MeetingLive.gallery_grid_class(6) ==
               "grid-cols-1 grid-rows-6 sm:grid-cols-3 sm:grid-rows-2"
    end

    test "7..9 stack on mobile (1xN) and fit a 3x3 square at sm+" do
      assert MeetingLive.gallery_grid_class(7) ==
               "grid-cols-1 grid-rows-7 sm:grid-cols-3 sm:grid-rows-3"

      assert MeetingLive.gallery_grid_class(8) ==
               "grid-cols-1 grid-rows-8 sm:grid-cols-3 sm:grid-rows-3"

      assert MeetingLive.gallery_grid_class(9) ==
               "grid-cols-1 grid-rows-9 sm:grid-cols-3 sm:grid-rows-3"
    end

    test "10..12 use 2 cols on mobile and fit a 4x3 rectangle at sm+" do
      # At 10+ participants, single-column stacking gets unwieldy on
      # mobile (10+ tiles × ~210px = 2100+ px of scroll). Switching to
      # 2 cols keeps tile width ~180px (above the 80px floor) and
      # halves the scroll distance.
      assert MeetingLive.gallery_grid_class(10) ==
               "grid-cols-2 grid-rows-5 sm:grid-cols-4 sm:grid-rows-3"

      assert MeetingLive.gallery_grid_class(11) ==
               "grid-cols-2 grid-rows-6 sm:grid-cols-4 sm:grid-rows-3"

      assert MeetingLive.gallery_grid_class(12) ==
               "grid-cols-2 grid-rows-6 sm:grid-cols-4 sm:grid-rows-3"
    end

    test "13..16 use 2 cols on mobile and fit a 4x4 square at sm+" do
      assert MeetingLive.gallery_grid_class(13) ==
               "grid-cols-2 grid-rows-7 sm:grid-cols-4 sm:grid-rows-4"

      assert MeetingLive.gallery_grid_class(16) ==
               "grid-cols-2 grid-rows-8 sm:grid-cols-4 sm:grid-rows-4"
    end

    test "17+ use 2 cols on mobile (bounded scroll) and 5x4 at sm+ with overflow" do
      assert MeetingLive.gallery_grid_class(17) ==
               "grid-cols-2 grid-rows-8 sm:grid-cols-5 sm:grid-rows-4"

      assert MeetingLive.gallery_grid_class(100) ==
               "grid-cols-2 grid-rows-8 sm:grid-cols-5 sm:grid-rows-4"
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

    test "an empty index draws the calendar, not a 'No meetings yet' card", %{conn: conn} do
      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      # The deleted surface, named so a revert is loud rather than merely
      # duplicated on screen.
      refute html =~ ~s(data-empty-state="meetings-index")
      refute html =~ "No meetings yet"
      refute html =~ ~s(data-role="meeting-row")

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
      refute html =~ ~s(href="/meetings/#{live_meeting.slug}")

      # And both meetings are on the day view instead, carrying their own
      # statuses rather than a section's.
      assert attrs_of(html, day_view(~s([data-role="calendar-event"])), "data-meeting-id") ==
               [live_meeting.id, upcoming.id]

      assert attrs_of(html, day_view(~s([data-role="calendar-event"])), "data-meeting-status") ==
               ["live", "scheduled"]

      assert html =~ live_meeting.name
      assert html =~ upcoming.name
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
         %{conn: conn} do
      # ONE test, ONE document, BOTH halves — extended by stage 3 rather
      # than joined by a second test. LiveView renders a single document
      # containing every breakpoint's markup and there is no viewport at
      # test time, so each half alone is satisfied by a wrong answer:
      # "the grid carries hidden lg:grid" passes on a build that also
      # draws the day view at every width, and "the day view carries
      # lg:hidden" passes on one that draws neither. Only the pair says
      # the two halves swap at `lg`.
      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      grid_classes =
        html
        |> attrs_of(~s([data-role="calendar-week-grid"]), "class")
        |> List.first()
        |> String.split()

      day_view_classes =
        html
        |> attrs_of(~s([data-role="calendar-day-view"]), "class")
        |> List.first()
        |> String.split()

      assert "hidden" in grid_classes
      assert "lg:grid" in grid_classes
      assert "lg:hidden" in day_view_classes
      # …and the day view is not ALSO hidden below `lg`, which is the way
      # `lg:hidden` can be present and still mean "never drawn".
      refute "hidden" in day_view_classes
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
      # 120 minutes into it (120/600 = 20%) and runs 60 (60/600 = 10%).
      assert attrs_of(html, in_grid(~s([data-role="calendar-event"])), "style") ==
               ["top:20.0%;height:10.0%"]

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

    test "a short meeting still clears the 44px floor in the day column",
         %{conn: conn, project: project} do
      # 30 minutes is 24px in a 48px hour row, which clips the second line
      # off entirely — invisible to every DOM assertion, because the text
      # is in the document either way. The floor is what keeps it readable
      # AND what keeps it tappable; both are the same 44px.
      today = grid_today()

      seed_grid_meeting(project,
        slug: "mob-short",
        name: "Short Meeting",
        scheduled_start_at: zoned_utc(today, 10, 0),
        scheduled_end_at: zoned_utc(today, 10, 30)
      )

      {:ok, _view, html} = live(grid_conn(conn), ~p"/meetings")

      [class] = attrs_of(html, day_view(~s([data-role="calendar-event"])), "class")
      assert "min-h-11" in String.split(class)

      # The percentage geometry is still the truth about WHEN — the floor
      # is a floor on the drawn box, not a rewrite of the placement.
      assert attrs_of(html, day_view(~s([data-role="calendar-event"])), "style") ==
               ["top:20.0%;height:5.0%"]
    end

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

      assert attrs_of(html, ~s([data-role="calendar-strip-day"]), "data-date") ==
               monday_first_week(Date.add(today, 7))
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
      # Sheet header + form fields are rendered.
      assert open_html =~ "Start a meeting"
      assert open_html =~ ~s(name="start_meeting[name]")
      assert open_html =~ ~s(name="start_meeting[project_id]")
      assert open_html =~ ~s(name="start_meeting[description]")
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

    test "submitting valid params creates a meeting and navigates to its slug", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings")

      # Open the sheet first.
      _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()

      # Submit the form. push_navigate should redirect us to the new
      # meeting's /meetings/<slug>.
      result =
        view
        |> form("#start-meeting-form",
          start_meeting: %{
            "name" => "Synthesis Sync",
            "project_id" => project.id,
            "description" => "Quick check-in"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to =~ ~r{^/meetings/}

      # The meeting now exists in the DB with the submitted name.
      assert [%Meeting{name: "Synthesis Sync"} = created] = Repo.all(Meeting)
      assert to == "/meetings/#{created.slug}"
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
          start_meeting: %{
            "name" => "",
            "project_id" => project.id,
            "description" => ""
          }
        )
        |> render_submit()

      # No meeting was created.
      assert Repo.all(Meeting) == []

      # Sheet stays open and the inline error renders.
      assert html =~ ~s(data-role="start-meeting-sheet")
      assert html =~ ~s(data-role="start-meeting-error")
      assert html =~ "Name is required"
    end

    test "submitting with no project_id shows an inline error and keeps the sheet open", %{
      conn: conn
    } do
      # Drop all projects so the form has nothing to pre-fill with.
      Repo.delete_all(Platform.Tasks.Project)

      {:ok, view, _html} = live(conn, ~p"/meetings")

      _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()

      html =
        view
        |> form("#start-meeting-form",
          start_meeting: %{
            "name" => "Project-less Meeting",
            "project_id" => "",
            "description" => ""
          }
        )
        |> render_submit()

      assert Repo.all(Meeting) == []
      assert html =~ ~s(data-role="start-meeting-sheet")
      assert html =~ "Project is required"
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
      assert html =~ ~s(id="meeting-share-btn-topbar")
      assert html =~ ~s(phx-hook="MeetingShareButton")

      # Belt-and-suspenders: the legacy phx-click that used to be on
      # this button must NOT be present anymore (it would race the hook).
      refute html =~
               ~r/id="meeting-share-btn-topbar"[^>]*phx-click="meeting_toggle_screen_share"/
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

    test "mounts with both collapse assigns false (expanded by default)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # The wide left rail renders (no `data-pane-collapsed` attr).
      assert html =~ ~s(data-pane="left-rail")
      refute html =~ ~s(data-pane="left-rail" data-pane-collapsed)
      # The wide chat aside renders, no slim chat rail in DOM.
      assert html =~ ~s(data-pane="chat-panel")
      refute html =~ ~s(data-pane-collapsed="true")
    end

    test "toggle_participant_rail flips the participant_rail_collapsed assign", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Drive the event directly to decouple from heex selector specifics
      # — the click-through path is covered by the next test.
      after_collapse = render_hook(view, "toggle_participant_rail", %{})
      assert after_collapse =~ ~s(data-pane="left-rail" data-pane-collapsed="true")
      assert_push_event(view, "meeting_participant_rail_collapsed_changed", %{collapsed: true})

      after_expand = render_hook(view, "toggle_participant_rail", %{})
      refute after_expand =~ ~s(data-pane="left-rail" data-pane-collapsed="true")
      assert_push_event(view, "meeting_participant_rail_collapsed_changed", %{collapsed: false})
    end

    test "toggle_meeting_chat_pane flips the chat_panel_collapsed assign", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      after_collapse = render_hook(view, "toggle_meeting_chat_pane", %{})
      # Slim chat rail now present with `data-pane="chat-panel"
      # data-pane-collapsed="true"`.
      assert after_collapse =~ ~s(data-pane="chat-panel" data-pane-collapsed="true")
      # The wide aside hides on `>=lg` via the lg:!hidden class.
      assert after_collapse =~ "lg:!hidden"
      assert_push_event(view, "meeting_chat_pane_collapsed_changed", %{collapsed: true})

      after_expand = render_hook(view, "toggle_meeting_chat_pane", %{})
      refute after_expand =~ ~s(data-pane="chat-panel" data-pane-collapsed="true")
      refute after_expand =~ "lg:!hidden"
      assert_push_event(view, "meeting_chat_pane_collapsed_changed", %{collapsed: false})
    end

    test "meeting_participant_rail_hydrate adopts a stored value when different", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      after_hydrate =
        render_hook(view, "meeting_participant_rail_hydrate", %{"collapsed" => true})

      assert after_hydrate =~ ~s(data-pane="left-rail" data-pane-collapsed="true")
    end

    test "meeting_chat_pane_hydrate adopts a stored value when different", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      after_hydrate =
        render_hook(view, "meeting_chat_pane_hydrate", %{"collapsed" => true})

      assert after_hydrate =~ ~s(data-pane="chat-panel" data-pane-collapsed="true")
    end

    test "hydrate is idempotent when the value matches the current assign", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Both default to false; a hydrate with false should be a no-op
      # but must NOT crash.
      _ = render_hook(view, "meeting_participant_rail_hydrate", %{"collapsed" => false})
      _ = render_hook(view, "meeting_chat_pane_hydrate", %{"collapsed" => false})

      html = render(view)
      refute html =~ ~s(data-pane-collapsed="true")
    end

    test "clicking participant-rail-toggle in the expanded rail header collapses to slim rail",
         %{conn: conn, meeting: meeting} do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Starts expanded — the chevron-double-left header button is
      # present, the slim rail is absent.
      assert html =~ ~s(data-role="participant-rail-toggle")
      assert html =~ "hero-chevron-double-left"
      refute html =~ ~s(data-pane="left-rail" data-pane-collapsed="true")

      # There's exactly one rendered participant-rail-toggle on the
      # expanded view (the slim collapsed rail isn't in the DOM until
      # after the toggle). Click it directly.
      after_collapse =
        view
        |> element(~s([data-role="participant-rail-toggle"]))
        |> render_click()

      assert after_collapse =~ ~s(data-pane="left-rail" data-pane-collapsed="true")
      # Slim rail header carries the mirrored chevron-double-right + a
      # second user-group icon for the icon-only state.
      assert after_collapse =~ "hero-chevron-double-right"
    end

    test "clicking chat-pane-toggle in the expanded chat pane header collapses to slim rail",
         %{conn: conn, meeting: meeting} do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-role="chat-pane-toggle")
      refute html =~ ~s(data-pane="chat-panel" data-pane-collapsed="true")

      # Exactly one chat-pane-toggle on the expanded view (in the chat
      # pane header). The slim chat rail's toggle only appears after.
      after_collapse =
        view
        |> element(~s([data-role="chat-pane-toggle"]))
        |> render_click()

      assert after_collapse =~ ~s(data-pane="chat-panel" data-pane-collapsed="true")
      assert after_collapse =~ "lg:!hidden"
    end

    test "collapse toggle buttons carry `hidden lg:inline-flex` so they're invisible on mobile",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Both toggle buttons must hide on `<lg` and render on `>=lg`.
      # The participant-rail-toggle in the expanded header AND the
      # chat-pane-toggle in the expanded chat header both carry
      # `hidden lg:inline-flex`.
      assert html =~
               ~r/data-role="participant-rail-toggle"[^>]*hidden lg:inline-flex|hidden lg:inline-flex[^>]*data-role="participant-rail-toggle"/

      assert html =~
               ~r/data-role="chat-pane-toggle"[^>]*hidden lg:inline-flex|hidden lg:inline-flex[^>]*data-role="chat-pane-toggle"/
    end

    test "SidebarCollapse hook hosts are mounted with namespaced storage keys + event names",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Two hidden hook hosts (one per pane), parameterized via
      # `data-storage-key`, `data-hydrate-event`, `data-change-event`.
      # Storage keys are namespaced under `suite.meeting.*` so they
      # never collide with the shell sidebar key.
      assert html =~ ~s(id="meeting-participant-rail-collapse-hook")
      assert html =~ ~s(data-storage-key="suite.meeting.participant_rail.collapsed")
      assert html =~ ~s(data-hydrate-event="meeting_participant_rail_hydrate")
      assert html =~ ~s(data-change-event="meeting_participant_rail_collapsed_changed")

      assert html =~ ~s(id="meeting-chat-pane-collapse-hook")
      assert html =~ ~s(data-storage-key="suite.meeting.chat_pane.collapsed")
      assert html =~ ~s(data-hydrate-event="meeting_chat_pane_hydrate")
      assert html =~ ~s(data-change-event="meeting_chat_pane_collapsed_changed")

      # Both hook hosts attach the SAME hook module (parameterized via
      # the data-attrs above).
      assert length(String.split(html, ~s(phx-hook="SidebarCollapse"))) - 1 >= 2
    end

    test "mobile drawer path is byte-identical — `:chat_panel_open` is orthogonal", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Open the mobile drawer (the existing pre-task-019e40f2 path).
      _ =
        view
        |> element(~s([data-role="chat-panel-toggle"]))
        |> render_click()

      html_open = render(view)
      # Drawer attribute reflects the mobile state, NOT the collapse state.
      assert html_open =~ ~s(data-chat-panel-open="true")
      # Desktop collapse remains false — the two assigns are independent.
      refute html_open =~ ~s(data-pane-collapsed="true")

      # Now collapse the chat pane (desktop). The mobile drawer assign
      # is unchanged.
      _ = render_hook(view, "toggle_meeting_chat_pane", %{})
      html_collapsed = render(view)
      assert html_collapsed =~ ~s(data-chat-panel-open="true")
      assert html_collapsed =~ ~s(data-pane="chat-panel" data-pane-collapsed="true")
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

      # Server-push mirrored to localStorage by the hook: assert the
      # meeting_captions_persist event landed.
      assert_push_event(view, "meeting_captions_persist", %{visible: true})
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
  # Stage 2 extends the caption feed with per-speaker overlay slots on
  # gallery tiles PLUS two fold-in review fixes from stage 1:
  #
  #   1. Persistence host div is mounted OUTSIDE the `:if @captions_visible`
  #      gate so localStorage restore survives a reload with the server
  #      default `false`. Verified by the presence of
  #      `#meeting-captions-persist-host` on mount before any toggle.
  #   2. Caption bar z-index bumped from `z-30` to `z-40` so it paints
  #      above the sticky mobile bottom-nav (which sits at `z-30`).
  #
  # The per-tile overlay itself is server-rendered as an empty
  # `[data-caption-slot]` div on each gallery `<.video_tile>` when the
  # viewer has captions on. The JS hook populates content at runtime;
  # these tests only pin the SERVER contract: the slot renders in
  # gallery mode when CC is on, and NOT in the strip / non-gallery
  # layouts / with CC off.
  describe "closed captions (stage 2 — per-tile overlays)" do
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

    test "gallery tiles carry a `[data-caption-slot]` overlay when CC is on", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      # Seed one visible human participant so the gallery tile exists.
      {_ada, _} = seed_meeting_presence(space, "user", "Ada Lovelace")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      # Sanity: gallery is the default layout.
      html = render(view)
      assert html =~ ~s(data-stage-mode="gallery")

      # CC off: no per-tile overlay slot on the gallery tiles.
      refute html =~ ~s(data-caption-slot)

      # Toggle CC on and re-render.
      html =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()

      # Now the gallery `<.video_tile>` renders a `[data-caption-slot]`
      # child on the tile. The JS hook uses
      # `[data-participant='<identity>'] [data-caption-slot]` to write
      # per-speaker captions — the empty div is the anchor.
      assert html =~ ~s(data-caption-slot)
      # The overlay is `phx-update="ignore"` so morphdom leaves the
      # JS-populated content alone on unrelated re-renders.
      assert html =~ ~r/data-caption-slot[^>]*|phx-update="ignore"[^>]*data-caption-slot/
    end

    test "the bottom strip's video_tile does NOT carry a caption slot even with CC on", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      # Strip tiles are 96/120px tall — too short for a legible caption
      # line, and the central bar already carries the transcript in
      # non-gallery modes. The stage-2 opt-in (`caption_slot?={true}`)
      # is thread through from the gallery layout only.
      {_ada, _} = seed_meeting_presence(space, "user", "Ada Lovelace")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      # Enable captions first so the central overlay is up.
      view
      |> element(~s([data-role="meeting-captions-toggle"]))
      |> render_click()

      # Then flip to a non-gallery mode so the bottom strip renders.
      html =
        view
        |> element(~s([data-stage-mode-button="canvas"]))
        |> render_click()

      assert html =~ ~s(data-pane="bottom-strip")

      # Isolate the strip section and confirm no caption slot bleeds in
      # from the strip tiles. The strip renders `id_prefix="strip-tile"`
      # — a scoped scan is enough.
      [_, strip_section] = String.split(html, ~s(data-pane="bottom-strip"), parts: 2)

      refute strip_section =~ ~s(data-caption-slot),
             "bottom strip tiles must NOT carry `[data-caption-slot]` (strip is too short for captions)"
    end

    test "no per-tile caption slot renders in gallery when CC is off", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      # The gallery `<.video_tile>` opt-in is `caption_slot?={@captions_visible}`,
      # so the slot must be absent by default (server assign starts false).
      {_ada, _} = seed_meeting_presence(space, "user", "Ada Lovelace")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      # No overlay and no per-tile slot when CC is off.
      refute html =~ ~s(data-role="meeting-captions")
      refute html =~ ~s(data-caption-slot)
    end

    test "toggling CC off removes the per-tile caption slots from gallery tiles", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {_ada, _} = seed_meeting_presence(space, "user", "Ada Lovelace")

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      # Toggle CC on → slot present.
      html =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()

      assert html =~ ~s(data-caption-slot)

      # Toggle CC off → slot withdrawn.
      html =
        view
        |> element(~s([data-role="meeting-captions-toggle"]))
        |> render_click()

      refute html =~ ~s(data-caption-slot)
    end
  end

  # ── Caption bar / gallery interaction (task 019f43e4 stage 1) ─────────
  #
  # In gallery mode, the per-tile `[data-caption-slot]` overlays are the
  # primary surface for spoken captions — the combined lower bar becomes
  # visually redundant (and, on mobile, competes with the sticky nav for
  # safe-area space). We hide the bar via a `hidden` class rather than
  # unmounting it with `:if`, because the `MeetingCaptions` JS hook
  # mounts on `#meeting-captions` and fans caption segments out to BOTH
  # the bar AND every per-tile `[data-caption-slot]`. Dropping the host
  # element from the DOM would silence the per-tile fan-out too.
  #
  # These tests pin the server contract: the bar's class list flips
  # `hidden` on/off in lock-step with `:current_stage_mode`, and the
  # `data-stage-mode` attribute mirrors the assign so CDP e2e can query
  # it. Morphdom must re-apply the class change even though
  # `phx-update="ignore"` is on the element (ignore preserves CHILDREN,
  # not attributes).
  describe "caption bar / gallery interaction (stage 1 — gallery dedup)" do
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

    test "caption bar renders with `hidden` class in gallery mode when captions on",
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

      # Bar carries the mode attribute AND the `hidden` class.
      assert tag =~ ~s(data-stage-mode="gallery")
      assert tag =~ ~r/\bhidden\b/

      # The host div is still in the DOM — hook stays mounted so per-tile
      # fan-out keeps working.
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

    test "toggling stage mode gallery -> canvas -> gallery flips the hidden class in-place",
         %{conn: conn, meeting: meeting} do
      # Regression: with `phx-update=\"ignore\"` on the element, we need
      # morphdom to re-apply attribute + class changes on stage-mode
      # transitions — `ignore` preserves children, not attributes. If the
      # class doesn't flip we've regressed the whole reason for using
      # `hidden` over `:if` (per-tile fan-out preservation).
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})

      view
      |> element(~s([data-role="meeting-captions-toggle"]))
      |> render_click()

      html_gallery = render(view)
      tag_g1 = caption_bar_shell_open_tag(html_gallery)
      assert tag_g1 =~ ~r/\bhidden\b/
      assert tag_g1 =~ ~s(data-stage-mode="gallery")

      html_canvas = render_click(view, "set_stage_mode", %{"mode" => "canvas"})
      tag_c = caption_bar_shell_open_tag(html_canvas)
      refute tag_c =~ ~r/\bhidden\b/
      assert tag_c =~ ~s(data-stage-mode="canvas")

      html_back = render_click(view, "set_stage_mode", %{"mode" => "gallery"})
      tag_g2 = caption_bar_shell_open_tag(html_back)
      assert tag_g2 =~ ~r/\bhidden\b/
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
  defp create_guest_meeting(display_name \\ "Juno Fairbanks") do
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

      assert html =~ ~s(data-pane="chat-panel")
      assert html =~ "chat-panel-toggle"
    end
  end

  describe "guest LiveKit token bundle (task 019f498d stage 6)" do
    setup do
      put_guest_livekit_env()
      :ok
    end

    test "minted JWT `name` claim carries the ` (guest)` suffix", %{conn: conn} do
      {meeting, token} = create_guest_meeting("Juno Fairbanks")

      {:ok, view, _html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assert_push_event(view, "join-meeting", %{token: pushed_token})
      assert {:ok, claims} = decode_jwt_claims(pushed_token)
      assert String.ends_with?(claims["name"], " (guest)")
      assert claims["name"] == "Juno Fairbanks (guest)"
    end

    test "identity carries the `guest:` prefix on the JWT sub claim", %{conn: conn} do
      # The `join-meeting` push_event payload is `%{token, url, room_name,
      # space_slug}` — `identity` isn't in the payload directly, so assert
      # against the decoded JWT's `sub` claim (the LiveKit identity).
      {meeting, token} = create_guest_meeting("Juno Fairbanks")

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
    {"toggle_participant_rail", %{}},
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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      refute html =~ ~s(data-role="intents-collapse")
      refute html =~ "intents-collapse"
      # ...and no CSS-hidden twin either.
      refute html =~ "Listening for intents"
    end

    test "assigned meeting_producer renders the strip", %{conn: conn, meeting: meeting} do
      assign_producer!()

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

        {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      {:ok, _} = force_status(meeting, row, :cancelled_late)

      html = render(view)
      assert html =~ ~s(data-intent-status="cancelled_late")
      assert html =~ "Cancelled late"
    end

    test "an event for a different meeting is ignored", %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

        {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert confidence_span(html, at.id) =~ ~s(data-low-confidence="false")
      assert confidence_span(html, under.id) =~ ~s(data-low-confidence="true")
    end

    test "a confidence the classifier never reported is not painted as bad", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, none} =
        enqueue_intent(meeting, %{classified_intent: "silent_intent", confidence: nil})

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      render_click(view, "intent_edit_open", %{"intent_id" => row.id})
      html = render_click(view, "intent_edit_close", %{})

      refute html =~ ~s(data-role="intent-edit-modal")
      assert IntentCorrections.list_for_meeting(meeting.id) == []
      assert [%{status: :queued}] = IntentQueue.list(meeting.id)
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
end
