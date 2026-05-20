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

  alias Platform.{Chat, Repo}
  alias Platform.Accounts.User
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings.Meeting
  alias Platform.Tasks.Project

  defp authenticated_conn(conn, user \\ nil) do
    user =
      user ||
        Repo.insert!(%User{
          email: "meeting_test_#{System.unique_integer([:positive])}@example.com",
          name: "Meeting Test User",
          oidc_sub: "oidc-meeting-test-#{System.unique_integer([:positive])}"
        })

    {init_test_session(conn, current_user_id: user.id), user}
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
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Meeting Project #{System.unique_integer([:positive])}",
        slug: "meeting-project-#{System.unique_integer([:positive])}"
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
      {:ok, _ada} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Ada Lovelace",
          joined_at: DateTime.utc_now()
        })

      {:ok, _grace} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Grace Hopper",
          joined_at: DateTime.utc_now()
        })

      {:ok, _bot} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Bot McBotface",
          joined_at: DateTime.utc_now()
        })

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
        {:ok, _} =
          Chat.add_participant(space.id, %{
            participant_type: "user",
            participant_id: Ecto.UUID.generate(),
            display_name: name,
            joined_at: DateTime.utc_now()
          })
      end

      {:ok, _bot} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Bot",
          joined_at: DateTime.utc_now()
        })

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
      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Solo",
          joined_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-gallery-tile-count="1")
      assert html =~ ~s(data-gallery-grid-shape="grid-cols-1 grid-rows-1")
    end

    test "with 6 human participants, gallery uses the responsive 1x6 / sm:3x2 grid shape",
         %{conn: conn, meeting: meeting, space: space} do
      for name <- ~w(Ada Grace Hedy Edith Karen Sophie) do
        {:ok, _} =
          Chat.add_participant(space.id, %{
            participant_type: "user",
            participant_id: Ecto.UUID.generate(),
            display_name: name,
            joined_at: DateTime.utc_now()
          })
      end

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-gallery-tile-count="6")

      assert html =~
               ~s(data-gallery-grid-shape="grid-cols-1 grid-rows-6 sm:grid-cols-3 sm:grid-rows-2")
    end

    test "identity alignment: gallery and strip use the same `\"user:\" <> pid` format",
         %{conn: conn, meeting: meeting, space: space} do
      # Seed one human so both renderers have something to emit.
      pid = Ecto.UUID.generate()

      {:ok, _participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: pid,
          display_name: "Ada Lovelace",
          joined_at: DateTime.utc_now()
        })

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

  # ── Meetings index (:index action, stage 1 of task 019e2ca8) ─────────────

  describe ":index action — empty state" do
    test "renders the no-meetings empty state when zero meetings exist", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)

      # Defensive: drop any meetings other tests in this run might have
      # seeded, so the empty branch is exercised in isolation.
      Repo.delete_all(Meeting)

      {:ok, _view, html} = live(conn, ~p"/meetings")

      assert html =~ ~s(data-empty-state="meetings-index")
      assert html =~ "No meetings yet"
      # FAB-pair vocabulary (stage 2 will mount the real button — the
      # empty-state copy + icon must already match).
      assert html =~ "Start a meeting"
      assert html =~ "hero-video-camera"
      # And no rows section at all.
      refute html =~ ~s(data-region="meetings-list")
      refute html =~ ~s(data-role="meeting-row")
    end

    test "index renders without forcing a local data-theme override (inherits shell theme)",
         %{conn: conn} do
      # Task 019e40ed: the `:index` placeholder branch had the same
      # hardcoded `data-theme="light"` as the `:show` shell — both must
      # now inherit the shell's `data-theme` from `<html>` in
      # `root.html.heex`.
      {conn, _user} = authenticated_conn(conn)
      Repo.delete_all(Meeting)

      {:ok, _view, html} = live(conn, ~p"/meetings")

      refute html =~ ~s(data-theme="light")
      refute html =~ ~s(data-theme="dark")
    end
  end

  describe ":index action — grouped sections" do
    setup %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      Repo.delete_all(Meeting)
      project = create_project()
      {:ok, conn: conn, user: user, project: project}
    end

    defp seed_meeting_with_status(project, opts) do
      slug = Keyword.fetch!(opts, :slug)
      name = Keyword.get(opts, :name, "Meeting #{slug}")
      status = Keyword.get(opts, :status, "scheduled")

      space = create_space()
      meeting_id = Platform.Types.UUIDv7.generate()

      attrs = %{
        project_id: project.id,
        chat_space_id: space.id,
        slug: slug,
        name: name,
        livekit_room_name: "meeting-#{meeting_id}",
        status: status
      }

      {:ok, meeting} =
        %Meeting{id: meeting_id}
        |> Meeting.changeset(attrs)
        |> Repo.insert()

      meeting
    end

    test "renders one section per non-empty status bucket with rows linking to /meetings/<slug>",
         %{conn: conn, project: project} do
      live_meeting =
        seed_meeting_with_status(project,
          slug: "live-now",
          name: "Live Standup",
          status: "live"
        )

      upcoming =
        seed_meeting_with_status(project,
          slug: "next-week",
          name: "Quarterly Review",
          status: "scheduled"
        )

      ended =
        seed_meeting_with_status(project,
          slug: "yesterday",
          name: "Closed Postmortem",
          status: "ended"
        )

      {:ok, _view, html} = live(conn, ~p"/meetings")

      # Empty state is GONE.
      refute html =~ ~s(data-empty-state="meetings-index")

      # Three sections render with their data-section markers.
      assert html =~ ~s(data-section="live")
      assert html =~ ~s(data-section="upcoming")
      assert html =~ ~s(data-section="ended")

      # Each meeting's name + slug shows up.
      assert html =~ live_meeting.name
      assert html =~ upcoming.name
      assert html =~ ended.name

      # Each row links to /meetings/<slug>.
      assert html =~ ~s(href="/meetings/#{live_meeting.slug}")
      assert html =~ ~s(href="/meetings/#{upcoming.slug}")
      assert html =~ ~s(href="/meetings/#{ended.slug}")

      # Status pill labels — one per section.
      assert html =~ "Live now"
      assert html =~ "Upcoming"
      assert html =~ "Ended"
    end

    test "section ordering is live → upcoming → ended", %{conn: conn, project: project} do
      seed_meeting_with_status(project, slug: "ord-live", status: "live")
      seed_meeting_with_status(project, slug: "ord-upcoming", status: "scheduled")
      seed_meeting_with_status(project, slug: "ord-ended", status: "ended")

      {:ok, _view, html} = live(conn, ~p"/meetings")

      live_pos = :binary.match(html, ~s(data-section="live")) |> elem(0)
      upcoming_pos = :binary.match(html, ~s(data-section="upcoming")) |> elem(0)
      ended_pos = :binary.match(html, ~s(data-section="ended")) |> elem(0)

      assert live_pos < upcoming_pos
      assert upcoming_pos < ended_pos
    end

    test "sections with zero rows are omitted (not rendered as empty headers)",
         %{conn: conn, project: project} do
      # Only an upcoming meeting — live and ended sections must NOT render.
      seed_meeting_with_status(project, slug: "only-upcoming", status: "scheduled")

      {:ok, _view, html} = live(conn, ~p"/meetings")

      assert html =~ ~s(data-section="upcoming")
      refute html =~ ~s(data-section="live")
      refute html =~ ~s(data-section="ended")
    end
  end

  describe ":index action — PubSub live updates" do
    setup %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      Repo.delete_all(Meeting)
      project = create_project()
      {:ok, conn: conn, project: project}
    end

    test ":meeting_created PubSub message updates the rendered list without remount",
         %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, ~p"/meetings")

      # Empty to start.
      assert html =~ ~s(data-empty-state="meetings-index")

      # Create a meeting via the context — broadcasts on the project topic.
      {:ok, _space} =
        Chat.create_space(%{
          name: "Pub Pre-existing",
          slug: "pub-pre-existing-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, meeting} =
        Platform.Meetings.create_meeting(%{
          project_id: project.id,
          name: "Brand New Meeting"
        })

      # Force the LV to flush the inbound :meeting_created broadcast.
      html = render(view)

      refute html =~ ~s(data-empty-state="meetings-index")
      assert html =~ "Brand New Meeting"
      assert html =~ ~s(data-meeting-id="#{meeting.id}")
      assert html =~ ~s(href="/meetings/#{meeting.slug}")
    end

    test ":meeting_ended PubSub message re-groups the row into the ended section",
         %{conn: conn, project: project} do
      # Seed a live meeting first.
      {:ok, space} =
        Chat.create_space(%{
          name: "End me",
          slug: "end-me-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      meeting_id = Platform.Types.UUIDv7.generate()

      {:ok, meeting} =
        %Meeting{id: meeting_id}
        |> Meeting.changeset(%{
          project_id: project.id,
          chat_space_id: space.id,
          slug: "end-me",
          name: "Ending Meeting",
          livekit_room_name: "meeting-#{meeting_id}",
          status: "live"
        })
        |> Repo.insert()

      {:ok, view, html} = live(conn, ~p"/meetings")

      assert html =~ ~s(data-section="live")
      refute html =~ ~s(data-section="ended")

      # End it; broadcast should land on the LV's project subscription.
      {:ok, _ended} = Platform.Meetings.end_meeting(meeting)

      html = render(view)

      refute html =~ ~s(data-section="live")
      assert html =~ ~s(data-section="ended")
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
end
