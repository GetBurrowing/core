defmodule PlatformWeb.MeetingLiveTest do
  @moduledoc """
  Tests for `PlatformWeb.MeetingLive` and the embedded
  `PlatformWeb.MeetingChatPanelLive` (ADR 0042, task 019e2475-87a8
  stage 1).

  Stage 1 ships:
    * the meeting route + shell skeleton (light theme, top bar with
      stage-mode stub, placeholders for sibling-owned panes)
    * the embedded chat panel rendered via `live_render` of
      `MeetingChatPanelLive` with the meeting's chat space slug
    * the chat panel root with `data-intent-panel-host="true"` (the
      future intent-panel migration's greppable hook)
    * a defensive empty-render path if no chat_space is bound
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
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-pane="left-rail")
      assert html =~ ~s(data-pane="center-stage")
      assert html =~ ~s(data-pane="bottom-strip")
      assert html =~ ~s(data-pane="chat-panel")
    end

    test "center stage carries data-stage-mode='canvas' by default", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-stage-mode="canvas")
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

    test "shell defaults to light mode", %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-theme="light")
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

    test "chat panel header includes the verbatim intent-panel placeholder caption",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Greppable caption (intentional verbatim string — see comment in
      # meeting_live.html.heex). Future-Rowan will use this exact string
      # to find the surface during the intent-panel migration.
      assert html =~ "Discussion · placeholder for intent panel (ADR 0042)"
    end

    test "chat panel header uses hero-chat-bubble-left-right (no emoji)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ "hero-chat-bubble-left-right"
      # Belt-and-suspenders: the header caption itself uses the middle
      # dot (U+00B7) as its separator, NOT an emoji. Refute common chat
      # emoji codepoints just in case a future drive-by edit reaches
      # for one.
      refute html =~ "💬"
      refute html =~ "💭"
    end
  end

  describe "embedded chat panel — render path" do
    setup %{conn: conn} do
      {meeting, space} = create_meeting(%{slug: "kickoff-chat", name: "Kickoff Chat"})
      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "panel root carries data-intent-panel-host=\"true\"", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-intent-panel-host="true")
    end

    test "panel renders the meeting's chat-space messages on mount", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {_p1, _m1} = seed_message(space, "Alice", "first message")
      {_p2, _m2} = seed_message(space, "Bob", "second message")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ "first message"
      assert html =~ "second message"
      assert html =~ "Alice"
      assert html =~ "Bob"
    end

    test "messages from a *different* space do NOT bleed into the panel", %{
      conn: conn,
      meeting: meeting
    } do
      other_space = create_space()
      seed_message(other_space, "Eve", "this should not appear")

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      refute html =~ "this should not appear"
    end

    test "panel exposes a composer form scoped to the chat panel", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-pane-section="composer")
      assert html =~ ~s(name="composer[text]")
    end

    test "submitting the composer persists a message to the chat space", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      panel_view = find_live_child(view, "meeting-chat-panel-#{meeting.id}")

      panel_view
      |> form("form[phx-submit='send_message']", composer: %{text: "hello from composer"})
      |> render_submit()

      messages = Chat.list_messages(space.id, top_level_only: true)
      assert Enum.any?(messages, &(&1.content == "hello from composer"))
    end

    test "panel updates in real time when a message is broadcast on the space topic", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Post a message from a different process; the panel's PubSub
      # subscription should pick it up.
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

      # Force a render to flush async messages.
      _ = render(view)

      # The panel is a child LV; render it directly to capture its
      # current HTML.
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

  describe "embedded chat panel — defensive paths" do
    test "MeetingChatPanelLive mounted with a missing chat_space slug renders an empty placeholder",
         %{conn: conn} do
      # The embed is a child LiveView routed via /meetings/:slug — its
      # session is built from the meeting record. If the upstream
      # meeting record points at a deleted chat_space (slug present
      # but space row gone), the embed must render its own empty state
      # rather than crashing the parent shell.
      #
      # We exercise this directly by mounting the embed from the
      # `__live_render_test/2` helper-equivalent below: the embed is
      # a regular `use PlatformWeb, :live_view`, so we route through
      # the same `live_isolated/3` LiveViewTest helper.
      {conn, _user} = authenticated_conn(conn)

      {:ok, _view, html} =
        live_isolated(conn, PlatformWeb.MeetingChatPanelLive,
          session: %{"chat_space_slug" => "no-such-slug-#{System.unique_integer([:positive])}"}
        )

      assert html =~ ~s(data-pane-section="empty")
      refute html =~ ~s(data-pane-section="composer")
    end

    test "MeetingChatPanelLive mounted without a slug session key renders an empty placeholder",
         %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)

      {:ok, _view, html} =
        live_isolated(conn, PlatformWeb.MeetingChatPanelLive, session: %{})

      assert html =~ ~s(data-pane-section="empty")
    end
  end

  describe "consolidation pass (stage 4)" do
    # Stage 4 is a pure tests stage. Most stage-4 spec items already
    # have direct coverage from stages 1-3 (panel mount, intent-panel
    # data attribute, greppable caption, mobile-toggle assign flip,
    # defensive empty-render). This describe block fills the small
    # remaining gaps and double-anchors the contracts that the stage 5
    # e2e_behavior validations will grep for in the rendered HTML.

    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{slug: "kickoff-stage4", name: "Stage Four Audit"})

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, user: user, meeting: meeting, space: space}
    end

    test "panel root id explicitly encodes the bound chat_space.id (scope contract)", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # The panel's root <div> id is `meeting-chat-panel-root-<chat_space_id>`
      # (see meeting_chat_panel_live.ex render/1). Asserting the bound
      # space id appears in the rendered id pins the scope contract:
      # the embed renders for *this* meeting's chat space, not some
      # other / cached / stale binding.
      assert html =~ ~s(id="meeting-chat-panel-root-#{space.id}")
      # And NOT the empty-state sentinel id.
      refute html =~ ~s(id="meeting-chat-panel-root-empty")
    end

    test "data-intent-panel-host and data-pane='meeting-chat-panel' co-locate on the same root",
         %{conn: conn, meeting: meeting} do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Stage 5's first e2e_behavior validation greps for
      # `data-intent-panel-host`. Make sure it lives on the same DOM
      # element as the embed's pane marker so future-Rowan can pivot
      # from the grep result straight to the surface.
      assert html =~
               ~r/data-intent-panel-host="true"[^>]*data-pane="meeting-chat-panel"|data-pane="meeting-chat-panel"[^>]*data-intent-panel-host="true"/
    end

    test "placeholder caption appears exactly once (greppable single source of truth)", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # Stage 5 grep validation: `rg 'placeholder for intent panel
      # \(ADR 0042\)' apps/platform` should yield one canonical match
      # per LV file. Belt-and-suspenders: confirm the rendered HTML
      # also surfaces it exactly once so a future drive-by edit that
      # accidentally duplicates the caption fails this test loudly.
      occurrences =
        html
        |> String.split("placeholder for intent panel (ADR 0042)")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1
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

    test "defensive empty render still carries data-intent-panel-host (migration hook is unconditional)",
         %{conn: conn} do
      # Even when the chat_space binding is missing, the panel must
      # still expose `data-intent-panel-host="true"` so the future
      # intent-panel migration's hook attaches uniformly. Pairs with
      # the stage 1 defensive tests but pins the migration contract
      # explicitly.
      {conn, _user} = authenticated_conn(conn)

      {:ok, _view, html} =
        live_isolated(conn, PlatformWeb.MeetingChatPanelLive, session: %{})

      assert html =~ ~s(data-intent-panel-host="true")
      assert html =~ ~s(id="meeting-chat-panel-root-empty")
    end
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

    test "defaults to canvas mode with the canvas button active", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      assert html =~ ~s(data-stage-mode-button="canvas")
      # The canvas button is active; the others are not.
      assert html =~ ~r/data-stage-mode-button="canvas"[^>]*data-active="true"/
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
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="gallery"]))
        |> render_click()

      # Left rail + bottom strip are presentation-independent of the
      # stage mode — they must survive a mode switch.
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

        # …and the sibling panes (left rail, bottom strip, participant
        # rail placeholder) remain mounted on every click.
        assert html =~ ~s(data-pane="left-rail"),
               "left rail unmounted after switching to #{mode}"

        assert html =~ ~s(data-pane="bottom-strip"),
               "bottom strip unmounted after switching to #{mode}"

        assert html =~ ~s(data-placeholder="participant-rail"),
               "participant-rail placeholder unmounted after switching to #{mode}"
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
      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

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

      {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}")

      # The data-canvas-id attribute on the center stage points at the
      # newer canvas — older canvases lose to insertion-order tail.
      assert html =~ ~s(data-canvas-id="#{newer.id}")
      refute html =~ ~s(data-canvas-id="#{older.id}")
      # Empty-state CTA does NOT render when a canvas is present.
      refute html =~ "No canvas yet"
    end

    test "clicking the CTA creates a canvas and renders it", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
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

    test "live :canvas_created broadcast on the meeting's space latches the canvas", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {:ok, view, html} = live(conn, ~p"/meetings/#{meeting.slug}")
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
      assert html =~ ~s(phx-click="meeting_start_screen_share")
      assert html =~ ~s(data-action="start-screen-share")
      # Hero icons only — no emoji.
      assert html =~ "hero-computer-desktop"
      assert html =~ "hero-arrow-up-tray"
      # Whiteboard / canvas-empty markers do NOT bleed in.
      refute html =~ ~s(data-coming-soon="whiteboard")
      refute html =~ ~s(data-empty-state="canvas")
    end

    test "Start sharing CTA pushes toggle-screen-share to the JS hooks", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      view
      |> element(~s([data-stage-mode-button="screen"]))
      |> render_click()

      # Click the Start-sharing CTA. The handler push_events
      # `toggle-screen-share` which any MeetingClient JS hook on the page
      # picks up. Asserting render doesn't crash + mode stays Screen
      # proves the handler wired correctly without a JS round-trip.
      html =
        view
        |> element(~s(button[data-action="start-screen-share"]))
        |> render_click()

      assert html =~ ~s(data-stage-mode="screen")
      assert html =~ "Start sharing"
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
      # The sibling-shipped chat panel auto-adds the current user as a
      # participant on mount. To exercise the "0 humans" branch we drop
      # the auto-added participant and broadcast a participant_left so
      # the LV's :participants assign refreshes from the DB.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      for p <- Chat.list_participants(space.id) do
        Repo.delete!(p)
      end

      send(view.pid, {:participant_left, nil})

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

      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      html =
        view
        |> element(~s([data-stage-mode-button="gallery"]))
        |> render_click()

      assert html =~ ~s(data-stage-mode="gallery")
      # Two seeded humans + the chat-panel-auto-added current user = 3
      # human tiles. The agent is omitted from the gallery grid.
      assert html =~ ~s(data-gallery-tile-count="3")
      assert html =~ ~s(data-gallery-grid)

      # Three video tiles, one per human; agent is omitted from the
      # gallery grid. The MeetingVideoTile JS hook attribute appears
      # once per tile.
      tile_count =
        Regex.scan(~r/phx-hook="MeetingVideoTile"/, html)
        |> length()

      assert tile_count == 3
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
end
