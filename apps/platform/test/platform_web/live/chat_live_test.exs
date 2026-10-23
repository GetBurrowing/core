defmodule PlatformWeb.ChatLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentServer}
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # The row this product offers, pinned as a LITERAL (task 019e0814 stage 2).
  #
  # Deliberately NOT `Platform.Chat.Emoji.quick_defaults()`. A test that reads
  # back the same function the template reads passes for EVERY possible return
  # value of that function: it proves the wiring and asserts nothing about the
  # set, so mutating `quick_defaults/0` would leave all three surfaces below
  # green. Pinned here, that mutation turns all three red — which was the point
  # of collapsing them onto one source, and was verified by doing it.
  #
  # Written as escapes, not glyphs: `\u{2764}\u{FE0F}` and a bare `\u{2764}` are
  # the same picture in an editor and different strings to
  # `Chat.list_reactions_grouped/1`, which groups by exact match. A row that
  # dropped the variation selector would detach every heart reaction already in
  # the database into a second pill, and no migration repairs that.
  @quick_react_row [
    "\u{1F44D}",
    "\u{1F389}",
    "\u{2705}",
    "\u{2764}\u{FE0F}",
    "\u{1F602}",
    "\u{1F64F}"
  ]

  setup do
    previous_root = Application.get_env(:platform, :chat_attachments_root)

    upload_root =
      Platform.TestTemp.path("platform_live_test_chat_uploads")

    Application.put_env(:platform, :chat_attachments_root, upload_root)

    on_exit(fn ->
      File.rm_rf(upload_root)
      Application.put_env(:platform, :chat_attachments_root, previous_root)
    end)

    :ok
  end

  defp authenticated_conn(conn, attrs \\ %{}) do
    user = insert_chat_user(attrs)
    init_test_session(conn, current_user_id: user.id)
  end

  defp insert_chat_user(attrs \\ %{}) do
    Repo.insert!(%User{
      email: Map.get(attrs, :email, "chat_test@example.com"),
      name: Map.get(attrs, :name, "Chat Test User"),
      oidc_sub: Map.get(attrs, :oidc_sub, "oidc-chat-test"),
      avatar_url: Map.get(attrs, :avatar_url)
    })
  end

  defp insert_chat_agent(attrs) do
    Repo.insert!(%Agent{
      slug: Map.get(attrs, :slug, "agent-#{System.unique_integer([:positive, :monotonic])}"),
      name: Map.get(attrs, :name, "Agent #{System.unique_integer([:positive, :monotonic])}"),
      status: Map.get(attrs, :status, "active"),
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    })
  end

  defp add_user_message(space, user, content) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name || user.email,
        joined_at: DateTime.utc_now()
      })

    {:ok, _message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    participant
  end

  defp add_agent_message(space, agent, content) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, _message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    participant
  end

  # ── Reaction-picker state assertions (task 019e0814 stage 3) ────────────────
  #
  # `#reaction-picker` is ALWAYS mounted now. The JS hook builds its ~1,850-tile
  # grid once and that grid has to survive a close, so the container cannot be
  # gated by `:if` on the server any more and open/closed became STATE on it.
  #
  # Four assertions in this file used to read `refute html =~
  # ~s(id="reaction-picker")`. They were the guards that the picker does not
  # appear unbidden, and that property still needs guarding — it is just
  # expressed differently now. They were CONVERTED, not deleted, because the
  # obvious replacement (`assert` the container exists) passes just as happily
  # against a picker stuck permanently open.
  #
  # THAT FAILURE IS THE ONE THAT MATTERS. An always-open picker means a
  # full-viewport `inset-0` scrim carrying `phx-click="close_reaction_picker"`
  # sitting over the whole chat surface: every message silently stops responding
  # to clicks and nothing looks wrong. Both halves below are therefore
  # load-bearing — the positive on `data-open="false"` AND the refutation of
  # `data-open="true"` — and `inert` is asserted alongside them because it is
  # the layer that still holds if a CSS change breaks the display gate.
  #
  # Verified by mutation: forcing `data-open` to a constant `"true"` in
  # `overlays.ex` turns every call to `assert_picker_closed/1` red.
  defp assert_picker_closed(view) do
    assert has_element?(view, ~s(#reaction-picker[data-open="false"]))
    refute has_element?(view, ~s(#reaction-picker[data-open="true"]))
    assert has_element?(view, "#reaction-picker[inert]")
  end

  defp assert_picker_open(view, msg_id) do
    assert has_element?(view, ~s(#reaction-picker[data-open="true"]))
    refute has_element?(view, ~s(#reaction-picker[data-open="false"]))
    refute has_element?(view, "#reaction-picker[inert]")
    assert has_element?(view, ~s(#reaction-picker[data-message-id="#{msg_id}"]))
  end

  defp count_occurrences(haystack, needle) do
    haystack
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end

  test "GET /chat redirects unauthenticated users to login", %{conn: conn} do
    conn = get(conn, ~p"/chat")
    assert redirected_to(conn) == "/auth/login"
  end

  test "navigating to a garbage slug does not create an accidental channel", %{conn: conn} do
    conn = authenticated_conn(conn)
    # Tool-artifact strings like __from_file__ should never bootstrap real spaces.
    # The route should redirect back to /chat instead of creating a new space.
    space_count_before = Platform.Repo.aggregate(Platform.Chat.Space, :count)

    {:error, {:live_redirect, %{to: "/chat"}}} = live(conn, "/chat/__from_file__")

    space_count_after = Platform.Repo.aggregate(Platform.Chat.Space, :count)

    assert space_count_after == space_count_before,
           "bootstrap_space should not create a space for invalid slugs"
  end

  test "navigating to a valid unknown slug creates a channel via bootstrap", %{conn: conn} do
    conn = authenticated_conn(conn)
    slug = "test-bootstrap-channel-#{System.unique_integer([:positive])}"
    space_count_before = Platform.Repo.aggregate(Platform.Chat.Space, :count)
    {:ok, _view, _html} = live(conn, "/chat/#{slug}")
    space_count_after = Platform.Repo.aggregate(Platform.Chat.Space, :count)

    assert space_count_after == space_count_before + 1,
           "valid slug should bootstrap a new channel"
  end

  test "GET /chat renders chat surface for authenticated users", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/chat")

    # Shell layout + sectioned channel sidebar should be present.
    # The flat "Channels" header was replaced by per-section labels in
    # chat plan v2 Stage 2 (Pinned / Direct Messages / sub-org sections);
    # the DMs label is the cheapest stable hook on the desktop sidebar.
    assert html =~ "Direct Messages"
    # The rail label is the install's app name, "Burrow" on a migrated DB
    # (task 01a120c5 stage 3).
    assert html =~ "Burrow"
  end

  test "shell sidebar is rendered on /chat", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/chat")

    # Shell nav and top bar present
    # The rail label is the install's app name, "Burrow" on a migrated DB
    # (task 01a120c5 stage 3).
    assert html =~ "Burrow"
    assert html =~ "/chat"
    assert html =~ "/control"
  end

  test "chat page renders per-space draft persistence + no bespoke last-space hook", %{
    conn: conn
  } do
    # Task 019f3e9a stage 3: ChatState hook was retired (subsumed by
    # RouteResume, which writes the last-visited chat path under
    # `route_resume:chat` via ClientState on every phx:page-loading-stop).
    # The per-space compose-draft `data-draft-key` remains; it powers
    # ComposeInput's ClientState-backed draft persistence.
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/chat/general")

    refute html =~ "phx-hook=\"ChatState\""
    assert html =~ "data-draft-key=\"chat-draft:"
  end

  # PWA scroll-lock take 2 (Alex's mobile follow-up after #333). Even
  # with the shell chrome correctly rooted at h-[100dvh], the chat
  # surface itself was blowing the layout from the inside: long message
  # threads pushed past the viewport and dragged the bottom-tab nav with
  # them on iOS Safari / PWA standalone. Root cause: the chat root
  # container, the inner flex row, the chat-drop-zone flex column, and
  # the #message-list scroller all relied on the default `min-height:
  # auto` for flex items, which on WebKit refuses to shrink below
  # intrinsic content height. Adding min-h-0 lets the flex children
  # actually receive their bounded `flex-1` height — which is what
  # forces #message-list to scroll on its own instead of letting the
  # surface push the bottom-tab nav out of the viewport.
  #
  # Asserting the literal class strings here keeps the fix from being
  # quietly removed during refactors (mocked render tests cannot
  # exercise iOS WebKit layout, so the visual verification lives in CDP
  # screenshots on the PR; this guards the wiring).
  test "chat surface flex containers set min-h-0 (PWA scroll lock take 2)", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/chat/general")

    # Chat root: flex h-full overflow-hidden + min-h-0
    assert html =~ ~r/<div[^>]*class="flex h-full min-h-0 overflow-hidden"/
    # Inner flex row: must also set min-h-0 so the chat-drop-zone column
    # below it actually receives a bounded height.
    assert html =~ ~r/<div[^>]*class="flex flex-1 overflow-hidden min-w-0 min-h-0"/
    # chat-drop-zone (the flex-col that owns #message-list + composer):
    # min-h-0 lets the message-list flex-1 actually shrink and scroll.
    assert html =~
             ~r/id="chat-drop-zone"[^>]*class="flex flex-1 flex-col overflow-hidden min-w-0 min-h-0"/

    # Scroll container (task 019e18fc Stage 3): infinite-scroll's
    # IntersectionObserver needs the load-more sentinels INSIDE the
    # scroll viewport, so the overflow + overscroll classes moved off
    # #message-list onto a new `#chat-message-scroller` wrapper.
    # #message-list itself is now a non-scrolling flex column inside
    # that wrapper. The intent of this test (iOS rubber-band bounded
    # via min-h-0 + overscroll-contain on the actual scroller) is
    # preserved — the assertion target just moved up one level.
    assert html =~
             ~r/id="chat-message-scroller"[^>]*class="flex-1 min-h-0 overflow-y-auto overflow-x-hidden overscroll-contain/
  end

  test "data-draft-key on the main composer is scoped to the active space's id and updates on channel switch",
       %{conn: conn} do
    conn = authenticated_conn(conn)

    general =
      Chat.get_space_by_slug("general") ||
        elem(Chat.create_space(%{name: "General", slug: "general", kind: "channel"}), 1)

    {:ok, other} = Chat.create_space(%{name: "Other", slug: "other", kind: "channel"})

    {:ok, view, html_a} = live(conn, ~p"/chat/general")

    # On /chat/general the key must be space-scoped to general's id —
    # if it were a constant, drafts would leak across channels.
    assert html_a =~ "data-draft-key=\"chat-draft:#{general.id}\""
    refute html_a =~ "data-draft-key=\"chat-draft:#{other.id}\""

    # Patch (same-LV handle_params) to /chat/other — the key must
    # change. Morphdom uses this attribute change to trigger the JS
    # hook's `_syncDraftState` and re-sync el.value to defaultValue.
    html_b = render_patch(view, ~p"/chat/other")
    assert html_b =~ "data-draft-key=\"chat-draft:#{other.id}\""
    refute html_b =~ "data-draft-key=\"chat-draft:#{general.id}\""
  end

  test "compose drafts are saved per-space and restored on channel switch", %{conn: conn} do
    conn = authenticated_conn(conn)

    _general =
      Chat.get_space_by_slug("general") ||
        elem(Chat.create_space(%{name: "General", slug: "general", kind: "channel"}), 1)

    {:ok, _other} = Chat.create_space(%{name: "Other", slug: "other", kind: "channel"})

    {:ok, view, _html} = live(conn, ~p"/chat/general")

    # Use a unique sentinel so a stray match elsewhere in the page
    # (channel name, message body, etc.) won't false-positive the assertions.
    sentinel_a = "ZZZ-draft-for-general-#{System.unique_integer([:positive])}"

    view
    |> form("#compose-form", compose: %{text: sentinel_a})
    |> render_change()

    # Patching to /chat/other triggers save_draft(prev.id) + restore_draft(other.id).
    # Other has no saved draft, so its textarea body must NOT contain general's text.
    html_other = render_patch(view, ~p"/chat/other")
    refute html_other =~ sentinel_a

    # Patching back to /chat/general restores the previously-saved draft from
    # the server-side :drafts map. The textarea body re-renders with the text.
    html_general_again = render_patch(view, ~p"/chat/general")
    assert html_general_again =~ sentinel_a
  end

  test "sending a message clears the composer (server-side textarea body + push compose_reset event)",
       %{conn: conn} do
    conn = authenticated_conn(conn)

    _general =
      Chat.get_space_by_slug("general") ||
        elem(Chat.create_space(%{name: "General", slug: "general", kind: "channel"}), 1)

    {:ok, view, _html} = live(conn, ~p"/chat/general")

    sentinel = "ZZZ-just-sent-#{System.unique_integer([:positive])}"

    # Submit the form (phx-submit="send_message")
    view
    |> form("#compose-form", compose: %{text: sentinel})
    |> render_submit()

    # The server MUST push a `compose_reset` event so the JS hook clears
    # `el.value` and the localStorage draft. Without this push, the textarea
    # keeps showing the just-sent text (browser quirk: textarea defaultValue
    # changes don't auto-sync to .value after user input).
    assert_push_event(view, "compose_reset", %{})

    # Server-side, the form's `[:text].value` is also cleared. Since redesign
    # rung 10 the form value is the hidden `compose[text]` input behind the
    # chip field (the field itself is `phx-update="ignore"` and JS-owned), so
    # the next render's hidden input must be empty. (The message itself
    # appears in the message stream, which may contain the sentinel.)
    html = render(view)
    assert has_element?(view, ~s(input#compose_text_value[hidden][name="compose[text]"]))
    refute has_element?(view, ~s(input#compose_text_value[value*="#{sentinel}"]))
    refute html =~ ~s(value="#{sentinel}")
  end

  test "sending a message renders it once in the chat", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/general")

    view
    |> form("#compose-form", compose: %{text: "hello from test"})
    |> render_submit()

    html = render(view)

    # Message should appear in the rendered chat
    assert html =~ "hello from test"
    # Text may appear once in the message stream and once in the textarea
    # (LiveView textarea content patching quirk). At most 2 occurrences.
    assert count_occurrences(html, "hello from test") in [1, 2]
  end

  test "chat renders stored human avatars for users with avatar_url", %{conn: conn} do
    avatar_url = "https://issuer.example.com/chat-avatar-user.png"
    conn = authenticated_conn(conn, %{name: "Avatar User", avatar_url: avatar_url})

    {:ok, view, _html} = live(conn, ~p"/chat/general")

    view
    |> form("#compose-form", compose: %{text: "avatar message"})
    |> render_submit()

    html = render(view)

    assert html =~ avatar_url
    assert html =~ "data-avatar-kind=\"human\""
    assert html =~ "data-avatar-mode=\"image\""
  end

  test "chat fallback avatars use varied human palettes while agent visuals stay distinct", %{
    conn: conn
  } do
    conn = authenticated_conn(conn)

    space =
      Chat.get_space_by_slug("general") ||
        elem(Chat.create_space(%{name: "General", slug: "general", kind: "channel"}), 1)

    user_one =
      insert_chat_user(%{
        name: "Alicia Amber",
        email: "alicia@example.com",
        oidc_sub: "seed-a"
      })

    user_two =
      insert_chat_user(%{
        name: "Bianca Blue",
        email: "bianca@example.com",
        oidc_sub: "seed-b"
      })

    agent = insert_chat_agent(%{name: "Zip Agent"})

    add_user_message(space, user_one, "first fallback avatar")
    add_user_message(space, user_two, "second fallback avatar")
    add_agent_message(space, agent, "agent avatar stays separate")

    {:ok, _view, html} = live(conn, ~p"/chat/general")

    palette_classes =
      Regex.scan(~r/avatar-fallback-\d+/, html)
      |> List.flatten()
      |> Enum.uniq()

    assert "avatar-fallback-5" in palette_classes
    assert "avatar-fallback-4" in palette_classes
    assert html =~ "data-avatar-kind=\"human\""
    assert html =~ "msg-agent-avatar"
    assert html =~ "agent avatar stays separate"
  end

  test "inline canvas in the message stream refreshes on :canvas_updated", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    user = Repo.get_by!(User, email: "chat_test@example.com")
    space = Repo.get_by!(Chat.Space, slug: "general")

    participant =
      Repo.get_by(Chat.Participant,
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id
      ) ||
        elem(
          Chat.add_participant(space.id, %{participant_type: "user", participant_id: user.id}),
          1
        )

    {:ok, canvas, _message} =
      Chat.create_canvas_with_message(space.id, participant.id, %{
        title: "Inline refresh test"
      })

    refute render(view) =~ "INLINE_REFRESH_TOKEN"

    patched_document = %{
      "version" => 1,
      "revision" => 2,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{},
        "children" => [
          %{
            "id" => "m1",
            "type" => "markdown",
            "props" => %{"content" => "INLINE_REFRESH_TOKEN body"},
            "children" => []
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }

    {:ok, _updated} = Chat.update_canvas(:system, canvas, %{"document" => patched_document})

    assert render(view) =~ "INLINE_REFRESH_TOKEN"
  end

  # An internal user is subscribed to every channel in the workspace at mount
  # (and to each new one via `{:space_created, ...}`), which is intended:
  # internal staff can see channels across client orgs. Subscription is not
  # permission to RENDER. A `:canvas_updated` broadcast from a channel the
  # viewer is not looking at must not reinsert that channel's messages into
  # the open pane, and must not merge its canvas into `@canvases_by_id`.
  #
  # Both directions live in one test on purpose: a guard that also suppresses
  # same-space refresh would ship green if the positive case sat in a separate
  # test. The same-space half runs FIRST as a positive control, so a failure on
  # the foreign half cannot be blamed on broken plumbing.
  test "a :canvas_updated from a space the viewer is not in never renders in the open pane", %{
    conn: conn
  } do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    user = Repo.get_by!(User, email: "chat_test@example.com")
    space = Repo.get_by!(Chat.Space, slug: "general")

    participant =
      Repo.get_by(Chat.Participant,
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id
      ) ||
        elem(
          Chat.add_participant(space.id, %{participant_type: "user", participant_id: user.id}),
          1
        )

    # ── Positive control: the space the user IS viewing still live-refreshes ──
    {:ok, own_canvas, _own_message} =
      Chat.create_canvas_with_message(space.id, participant.id, %{
        title: "Own space canvas"
      })

    {:ok, _} =
      Chat.update_canvas(:system, own_canvas, %{
        "document" => canvas_document_with_token("OWN_SPACE_REFRESH_TOKEN")
      })

    assert render(view) =~ "OWN_SPACE_REFRESH_TOKEN",
           "same-space :canvas_updated must still refresh the inline canvas card"

    # ── Foreign space: mounted user is deliberately NOT a participant ──
    {:ok, space_b} =
      Chat.create_space(%{name: "Client Channel B", slug: "client-channel-b", kind: "channel"})

    other_user =
      insert_chat_user(%{
        email: "other_org_user@example.com",
        name: "Other Org User",
        oidc_sub: "oidc-other-org-user"
      })

    {:ok, participant_b} =
      Chat.add_participant(space_b.id, %{
        participant_type: "user",
        participant_id: other_user.id,
        display_name: other_user.name,
        joined_at: DateTime.utc_now()
      })

    # Flush the mailbox so the LiveView has handled `{:space_created, space_b}`
    # and subscribed to space B's topic before the canvas broadcast fires.
    # Without this the test could pass because the event never arrived.
    _ = :sys.get_state(view.pid)

    {:ok, canvas_b, message_b} =
      Chat.create_canvas_with_message(space_b.id, participant_b.id, %{
        title: "Foreign space canvas"
      })

    # A real write, not a hand-sent message: only `update_canvas/3` runs
    # `publish_canvas_updated/1`, and only a write inserts through the same
    # path production uses.
    {:ok, _} =
      Chat.update_canvas(:system, canvas_b, %{
        "document" => canvas_document_with_token("FOREIGN_SPACE_BLEED_TOKEN")
      })

    refute render(view) =~ "FOREIGN_SPACE_BLEED_TOKEN",
           "a canvas edit in a space the viewer is not in must not render in the open pane"

    # The bled insert also mutates `:last_msg_day` inside
    # `stream_insert_with_day_label/2`, so it can shift day separators for the
    # space the user IS viewing. The damage is not limited to one extra row.
    assigns = :sys.get_state(view.pid).socket.assigns

    refute Map.has_key?(assigns.msg_day_labels, message_b.id),
           "a foreign space's message must never enter :msg_day_labels"

    # CanvasHooks state, asserted separately from the render. The two guards
    # fail independently and the render assertion above only covers one of them:
    # with MessagesHooks guarded and CanvasHooks not, no foreign message row
    # reaches the stream, so the token cannot render and the refute passes while
    # the foreign canvas still sits in `@canvases_by_id`. Verified by
    # neutralising each guard in turn. Without this assertion the CanvasHooks
    # half of the fix has no coverage at all.
    refute Map.has_key?(assigns.canvases_by_id, canvas_b.id),
           "a foreign space's canvas must never enter @canvases_by_id"
  end

  defp canvas_document_with_token(token) do
    %{
      "version" => 1,
      "revision" => 2,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{},
        "children" => [
          %{
            "id" => "m1",
            "type" => "markdown",
            "props" => %{"content" => "#{token} body"},
            "children" => []
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  test "clicking an action_row button surfaces a flash via :canvas_event broadcast", %{
    conn: conn
  } do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    user = Repo.get_by!(User, email: "chat_test@example.com")
    space = Repo.get_by!(Chat.Space, slug: "general")

    participant =
      Repo.get_by(Chat.Participant,
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id
      ) ||
        elem(
          Chat.add_participant(space.id, %{participant_type: "user", participant_id: user.id}),
          1
        )

    action_doc = %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{},
        "children" => [
          %{
            "id" => "ar-demo",
            "type" => "action_row",
            "props" => %{
              "actions" => [
                %{"label" => "Approve", "value" => "approve", "variant" => "primary"},
                %{"label" => "Reject", "value" => "reject", "variant" => "danger"}
              ]
            },
            "children" => []
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }

    {:ok, canvas, _message} =
      Chat.create_canvas_with_message(space.id, participant.id, %{
        "title" => "Action row test",
        "document" => action_doc
      })

    # Open the canvas so canvas_action_click can resolve the target via active_canvas.
    render_click(view, "canvas_open", %{"canvas-id" => canvas.id})

    # Simulate a click on the "Approve" button. Emits {:canvas_event, canvas_id, %{...}}
    # which the handler consumes (pattern-matched as 3-tuple; the prior 4-tuple mismatch
    # silently dropped every click).
    render_click(view, "canvas_action_click", %{
      "node-id" => "ar-demo",
      "action" => "approve"
    })

    assert render(view) =~ "Canvas action: ar-demo"
    assert render(view) =~ "approve"
  end

  test "action_row click without an active_canvas still resolves via phx-value-canvas-id (task 019f70ff)",
       %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    user = Repo.get_by!(User, email: "chat_test@example.com")
    space = Repo.get_by!(Chat.Space, slug: "general")

    participant =
      Repo.get_by(Chat.Participant,
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id
      ) ||
        elem(
          Chat.add_participant(space.id, %{participant_type: "user", participant_id: user.id}),
          1
        )

    action_doc = %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{},
        "children" => [
          %{
            "id" => "ar-demo",
            "type" => "action_row",
            "props" => %{
              "actions" => [
                %{"label" => "Approve", "value" => "approve", "variant" => "primary"}
              ]
            },
            "children" => []
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }

    {:ok, canvas, _message} =
      Chat.create_canvas_with_message(space.id, participant.id, %{
        "title" => "Action row test — no active",
        "document" => action_doc
      })

    # NB: do NOT open the canvas first. Bug A + B pre-fix meant the click
    # either fired canvas_open (main view) or arrived with an empty value
    # (pinned view without active_canvas). The fix threads canvas_id into
    # phx-value-canvas-id on every button, so this event resolves without
    # any active_canvas set.
    render_click(view, "canvas_action_click", %{
      "canvas-id" => canvas.id,
      "node-id" => "ar-demo",
      "action" => "approve"
    })

    assert render(view) =~ "Canvas action: ar-demo"
    assert render(view) =~ "approve"
  end

  test "rendered inline action_row markup carries phx-value-canvas-id + data-role (task 019f70ff)",
       %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    user = Repo.get_by!(User, email: "chat_test@example.com")
    space = Repo.get_by!(Chat.Space, slug: "general")

    participant =
      Repo.get_by(Chat.Participant,
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id
      ) ||
        elem(
          Chat.add_participant(space.id, %{participant_type: "user", participant_id: user.id}),
          1
        )

    action_doc = %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{},
        "children" => [
          %{
            "id" => "ar-demo",
            "type" => "action_row",
            "props" => %{
              "actions" => [
                %{"label" => "Approve", "value" => "approve", "variant" => "primary"}
              ]
            },
            "children" => []
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }

    {:ok, canvas, _message} =
      Chat.create_canvas_with_message(space.id, participant.id, %{
        "title" => "Action row markup test",
        "document" => action_doc
      })

    html = render(view)

    # The inline chat-message copy of the canvas MUST include the canvas.id on
    # the button (so clicks resolve without active_canvas) AND the data-role
    # marker so the wrapper's onclick stopPropagation guard fires.
    assert html =~ ~s|phx-value-canvas-id="#{canvas.id}"|
    assert html =~ ~s|data-role="canvas-action-button"|
    assert html =~ ~s|phx-value-node-id="ar-demo"|
    assert html =~ ~s|phx-value-action="approve"|
  end

  # Task 019f70ff stage 2 — regression coverage for sibling interactive kinds.
  #
  # Stage 1 fixed action_row clicks in the inline canvas surface (canvas_id
  # threaded through Renderer.render_node into every container kind so buttons
  # carry phx-value-canvas-id; LV's closestPhxBinding then resolves the button
  # over the wrapper's phx-click="canvas_open"). Stage 2 locks in that the
  # OTHER interactive kind rendered by the same pipeline — `form` — still
  # fires its own phx-submit handler and its inline markup exposes the
  # interaction anchors (phx-submit + phx-value-node-id).
  #
  # A checklist_item toggle would parallel this, but checklist_item currently
  # renders a passive row (no phx-click) — the plan's checklist_item toggle
  # spec anticipates a future interaction that doesn't yet exist. `form` is
  # the concrete sibling interactive kind whose end-to-end wiring is
  # exercisable today.
  test "form inside an inline canvas dispatches canvas_form_submit end-to-end (task 019f70ff stage 2)",
       %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    user = Repo.get_by!(User, email: "chat_test@example.com")
    space = Repo.get_by!(Chat.Space, slug: "general")

    participant =
      Repo.get_by(Chat.Participant,
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id
      ) ||
        elem(
          Chat.add_participant(space.id, %{participant_type: "user", participant_id: user.id}),
          1
        )

    form_doc = %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{},
        "children" => [
          %{
            "id" => "f-demo",
            "type" => "form",
            "props" => %{
              "title" => "Stage 2 form regression",
              "fields" => [
                %{"name" => "notes", "label" => "Notes", "type" => "textarea"}
              ]
            },
            "children" => []
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }

    {:ok, canvas, _message} =
      Chat.create_canvas_with_message(space.id, participant.id, %{
        "title" => "Form submit regression",
        "document" => form_doc
      })

    # Assert the inline chat-message copy of the canvas exposes the form's
    # interaction anchors: phx-submit handler + node-id. If Stage 1's
    # canvas_id threading through Renderer.render_node ever regressed such
    # that a container kind swallowed its children's attrs, these assertions
    # would fail.
    html_before = render(view)
    assert html_before =~ ~s|phx-submit="canvas_form_submit"|
    assert html_before =~ ~s|phx-value-node-id="f-demo"|

    # Open the canvas so canvas_form_submit can resolve the target via
    # active_canvas fallback (form kind does NOT emit phx-value-canvas-id
    # today — form_submit relies on active_canvas). Post-open the sidebar
    # is mounted.
    render_click(view, "canvas_open", %{"canvas-id" => canvas.id})
    assert has_element?(view, "#canvas-sidebar")

    # Submit the form — this is what the form kind's phx-submit binding
    # resolves to on the wire. The handler emits {:canvas_event, canvas_id,
    # %{"name" => "submitted", ...}}, which CanvasHooks flashes as
    # "Canvas form submitted: <node-id>".
    render_submit(view, "canvas_form_submit", %{
      "node-id" => "f-demo",
      "form" => %{"notes" => "hello from stage 2"}
    })

    html_after = render(view)
    assert html_after =~ "Canvas form submitted: f-demo"

    # Regression guard: submitting the form did not close the canvas as a
    # side-effect. If a future refactor accidentally routed canvas_form_submit
    # through canvas_close (or set :active_canvas to nil), this would catch it.
    assert has_element?(view, "#canvas-sidebar")
  end

  test "opening a canvas refetches latest state from the database", %{conn: conn} do
    conn = authenticated_conn(conn)

    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    user = Repo.get_by!(User, email: "chat_test@example.com")
    space = Repo.get_by!(Chat.Space, slug: "general")

    participant =
      Repo.get_by(Chat.Participant,
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id
      ) ||
        elem(
          Chat.add_participant(space.id, %{participant_type: "user", participant_id: user.id}),
          1
        )

    {:ok, canvas, _message} =
      Chat.create_canvas_with_message(space.id, participant.id, %{
        title: "Out-of-band canvas"
      })

    updated_document = %{
      "version" => 1,
      "revision" => 2,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 8},
        "children" => [
          %{
            "id" => "h1",
            "type" => "heading",
            "props" => %{"level" => 3, "value" => "Out-of-band render test"},
            "children" => []
          },
          %{
            "id" => "m1",
            "type" => "markdown",
            "props" => %{"content" => "Canvas should render the latest stored state."},
            "children" => []
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }

    canvas
    |> Canvas.changeset(%{"document" => updated_document})
    |> Repo.update!()

    render_click(view, "canvas_open", %{"canvas-id" => canvas.id})

    html = render(view)

    assert html =~ "Out-of-band render test"
    assert html =~ "Canvas should render the latest stored state."
  end

  # Task 019e2c4b stage 2. `canvas-id` is an event param, so a client can push
  # any UUID regardless of what was rendered, and `CanvasHooks.find/2` resolves
  # it through the UNAUTHORIZED `Chat.get_canvas/1` — pinning a stranger's
  # canvas as `active_canvas`. That read gap is a KNOWN, documented gap left to
  # stage 3/4 (see `CanvasHooks.find/2`'s moduledoc).
  #
  # What stage 2 closes is the WRITE it used to enable: restore-confirm
  # overwrote the whole document of whatever was pinned, with no membership
  # check at all. This asserts the forged canvas survives untouched.
  test "a forged canvas-id from another space cannot be overwritten by restore", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    {:ok, other_space} =
      Chat.create_space(%{
        name: "Someone else's space",
        slug: "foreign-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, stranger} =
      Chat.add_participant(other_space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Stranger",
        joined_at: DateTime.utc_now()
      })

    {:ok, foreign_canvas, _msg} =
      Chat.create_canvas_with_message(other_space.id, stranger.id, %{
        "title" => "Confidential elsewhere",
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "props" => %{},
            "children" => [
              %{
                "id" => "secret",
                "type" => "heading",
                "props" => %{"level" => 3, "value" => "FOREIGN_CANVAS_SECRET"},
                "children" => []
              }
            ]
          },
          "theme" => %{},
          "bindings" => %{},
          "meta" => %{}
        }
      })

    # Revision 1 always exists — it is written at canvas creation — so a
    # restore to it is always available to an attacker.
    render_click(view, "canvas_open", %{"canvas-id" => foreign_canvas.id})
    html = render_click(view, "canvas_versions_restore_confirm", %{"revision" => "1"})

    assert html =~ "not edit it"

    reloaded = Chat.get_canvas(foreign_canvas.id)
    assert reloaded.document == foreign_canvas.document
  end

  # Regression: the canvas pane subscribes to per-canvas PubSub but had no
  # `handle_info` clause for `{:canvas_patched, ...}`, so checklist toggles /
  # form saves / etc. silently went to the catch-all and `@active_canvas`
  # stayed on the loaded revision until manual reload.
  test "active canvas pane live-updates on :canvas_patched broadcast", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    user = Repo.get_by!(User, email: "chat_test@example.com")
    space = Repo.get_by!(Chat.Space, slug: "general")

    participant =
      Repo.get_by(Chat.Participant,
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id
      ) ||
        elem(
          Chat.add_participant(space.id, %{participant_type: "user", participant_id: user.id}),
          1
        )

    {:ok, canvas, _message} =
      Chat.create_canvas_with_message(space.id, participant.id, %{title: "Patched canvas"})

    # Open the canvas pane.
    render_click(view, "canvas_open", %{"canvas-id" => canvas.id})

    refute render(view) =~ "PATCHED_LIVE_TOKEN"

    # Out-of-band patch via the server (this is what MCP / agent / other
    # LiveView writers go through). The server broadcasts `:canvas_patched`
    # synchronously before persistence; our hook clause re-syncs the pane from
    # the in-memory server state.
    {:ok, %{revision: rev}} = Platform.Chat.Canvas.Server.describe(canvas.id)

    patch_ops = [
      {:append_child, "root",
       %{
         "id" => "patched-node",
         "type" => "markdown",
         "props" => %{"content" => "PATCHED_LIVE_TOKEN body"},
         "children" => []
       }}
    ]

    {:ok, _new_rev} = Platform.Chat.Canvas.Server.apply_patches(canvas.id, patch_ops, rev)

    assert render(view) =~ "PATCHED_LIVE_TOKEN",
           "canvas pane should refresh on :canvas_patched without a manual reload"
  end

  test "canvas pane ignores :canvas_patched broadcasts for non-active canvases", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    user = Repo.get_by!(User, email: "chat_test@example.com")
    space = Repo.get_by!(Chat.Space, slug: "general")

    participant =
      Repo.get_by(Chat.Participant,
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id
      ) ||
        elem(
          Chat.add_participant(space.id, %{participant_type: "user", participant_id: user.id}),
          1
        )

    {:ok, active_canvas, _} =
      Chat.create_canvas_with_message(space.id, participant.id, %{title: "Active canvas"})

    {:ok, other_canvas, _} =
      Chat.create_canvas_with_message(space.id, participant.id, %{title: "Other canvas"})

    render_click(view, "canvas_open", %{"canvas-id" => active_canvas.id})

    refute render(view) =~ "OTHER_PATCHED_TOKEN"

    {:ok, %{revision: rev}} = Platform.Chat.Canvas.Server.describe(other_canvas.id)

    patch_ops = [
      {:append_child, "root",
       %{
         "id" => "n",
         "type" => "markdown",
         "props" => %{"content" => "OTHER_PATCHED_TOKEN body"},
         "children" => []
       }}
    ]

    {:ok, _} = Platform.Chat.Canvas.Server.apply_patches(other_canvas.id, patch_ops, rev)

    # Allow the PubSub send + handle_info to drain on the LiveView pid.
    _ = :sys.get_state(view.pid)

    assigns = :sys.get_state(view.pid).socket.assigns

    # @active_canvas must remain the original active canvas — the patched one
    # should refresh its in-list entry but never steal pane focus.
    assert assigns.active_canvas.id == active_canvas.id
  end

  test "shows the shell agent indicator without a duplicate chat header presence badge", %{
    conn: conn
  } do
    conn = authenticated_conn(conn)

    workspace =
      Platform.TestTemp.path("platform-chat-live-agent")

    File.mkdir_p!(workspace)

    slug = "zip-#{System.unique_integer([:positive, :monotonic])}"
    previous_workspace = Application.get_env(:platform, :agent_workspace_path)

    on_exit(fn ->
      AgentServer.stop_agent(slug)
      File.rm_rf(workspace)
      Application.put_env(:platform, :agent_workspace_path, previous_workspace)
    end)

    File.write!(
      Path.join(workspace, "openclaw.json"),
      Jason.encode!(%{
        "agents" => %{
          "list" => [
            %{
              "id" => slug,
              "name" => "Zip",
              "model" => %{"primary" => "anthropic/claude-sonnet-4-6"}
            }
          ]
        }
      })
    )

    File.write!(Path.join(workspace, "SOUL.md"), "steady")

    Application.put_env(:platform, :agent_workspace_path, workspace)

    {:ok, _view, html} = live(conn, ~p"/chat/general")

    # The chat surface mounts the shell layout (icon-rail present); the
    # roster button "Agents" text is async-resolved, so we assert on the
    # rail's stable marker rather than the old sidebar's "Agent Resources"
    # link text (removed in task 019e389b Stage 3 — icon-rail rev).
    assert html =~ ~s(data-icon-rail)
    refute html =~ "Zip online"
  end

  test "chat boots the first configured workspace agent when no main agent exists", %{conn: conn} do
    conn = authenticated_conn(conn)

    workspace =
      Platform.TestTemp.path("platform-chat-live-default-agent")

    File.mkdir_p!(workspace)

    previous_workspace = Application.get_env(:platform, :agent_workspace_path)

    on_exit(fn ->
      AgentServer.stop_agent("zip")
      AgentServer.stop_agent("sidecar")
      File.rm_rf(workspace)
      Application.put_env(:platform, :agent_workspace_path, previous_workspace)
    end)

    File.write!(
      Path.join(workspace, "openclaw.json"),
      Jason.encode!(%{
        "agents" => %{
          "list" => [
            %{
              "id" => "zip",
              "name" => "Zip",
              "model" => %{"primary" => "anthropic/claude-sonnet-4-6"}
            },
            %{
              "id" => "sidecar",
              "name" => "Sidecar",
              "model" => %{"primary" => "openai/gpt-4.1"}
            }
          ]
        }
      })
    )

    File.write!(Path.join(workspace, "SOUL.md"), "steady")
    Application.put_env(:platform, :agent_workspace_path, workspace)

    {:ok, _view, html} = live(conn, ~p"/chat/general")

    # Smoke-check: shell layout mounted (icon-rail present). Old sidebar
    # text-match on "Agent Resources" was dropped in task 019e389b Stage 3.
    assert html =~ ~s(data-icon-rail)
    assert is_pid(AgentServer.whereis("zip"))
    assert AgentServer.whereis("sidecar") == nil
  end

  test "chat falls back to persisted main agent when workspace bootstrap is unavailable", %{
    conn: conn
  } do
    conn = authenticated_conn(conn)

    previous_workspace = Application.get_env(:platform, :agent_workspace_path)
    Application.put_env(:platform, :agent_workspace_path, "/tmp/does-not-exist/platform-agent")

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "main",
        name: "Zip",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert()

    on_exit(fn ->
      AgentServer.stop_agent(agent)
      Application.put_env(:platform, :agent_workspace_path, previous_workspace)
    end)

    {:ok, _view, html} = live(conn, ~p"/chat/general")

    # Smoke-check: shell layout mounted (icon-rail present). Old sidebar
    # text-match on "Agent Resources" was dropped in task 019e389b Stage 3.
    assert html =~ ~s(data-icon-rail)
    assert is_pid(AgentServer.whereis(agent.id))
  end

  describe "search" do
    test "searching messages shows ranked results with highlighted matches", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "Phoenix search is live"})
      |> render_submit()

      view
      |> form("#compose-form", compose: %{text: "Other chat note"})
      |> render_submit()

      html =
        view
        |> form("#chat-search-form", search: %{query: "phoenix"})
        |> render_change()

      assert html =~ "Search Results"
      assert html =~ "<mark>Phoenix</mark>"
      assert html =~ "match"
    end

    test "opening a threaded search result expands the inline thread", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "Thread root"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [root_message | _] = Chat.list_messages(space.id)

      render_click(view, "open_thread", %{"message-id" => root_message.id})

      render_submit(view, "send_inline_thread_message", %{
        "inline_thread_compose" => %{
          "text" => "Phoenix lives in threads too",
          "message_id" => root_message.id
        }
      })

      thread_message =
        space.id
        |> Chat.list_messages(
          thread_id: Chat.get_thread_for_message(root_message.id).id,
          limit: 10
        )
        |> List.first()

      html =
        view
        |> form("#chat-search-form", search: %{query: "phoenix"})
        |> render_change()

      assert html =~ "Thread"

      html = render_click(view, "search_open_result", %{"message-id" => thread_message.id})

      assert html =~ "inline-thread-compose-form-#{root_message.id}"
      assert html =~ "Phoenix lives in threads too"
    end

    test "search_open_result sets :highlighted_message_id and does not grow :rendered_message_ids",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "highlight target message"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [target | _] = Chat.list_messages(space.id)

      assigns_before = :sys.get_state(view.pid).socket.assigns
      rendered_before = Map.get(assigns_before, :rendered_message_ids, MapSet.new())
      assert MapSet.member?(rendered_before, target.id)
      size_before = MapSet.size(rendered_before)

      render_click(view, "search_open_result", %{"message-id" => target.id})

      assigns_after = :sys.get_state(view.pid).socket.assigns
      assert assigns_after.highlighted_message_id == target.id

      rendered_after = Map.get(assigns_after, :rendered_message_ids, MapSet.new())

      assert MapSet.size(rendered_after) == size_before,
             "reinsert of an in-DOM target must not change :rendered_message_ids count"
    end

    test "search_clear clears :highlighted_message_id and does not grow :rendered_message_ids",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "clear-me target"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [target | _] = Chat.list_messages(space.id)

      render_click(view, "search_open_result", %{"message-id" => target.id})
      assigns_set = :sys.get_state(view.pid).socket.assigns
      assert assigns_set.highlighted_message_id == target.id
      size_set = MapSet.size(Map.get(assigns_set, :rendered_message_ids, MapSet.new()))

      render_click(view, "search_clear", %{})

      assigns_cleared = :sys.get_state(view.pid).socket.assigns
      assert is_nil(assigns_cleared.highlighted_message_id)

      size_cleared = MapSet.size(Map.get(assigns_cleared, :rendered_message_ids, MapSet.new()))

      assert size_cleared == size_set,
             "clearing the highlight must not change :rendered_message_ids count (reinsert of prior id only refreshes the row)"
    end

    # NOTE: a dedicated test for the non-DOM-target filter (architect's #4)
    # was descoped from the original plan. Reaching `SearchHooks.set_highlights`
    # with a non-DOM uuid via Phoenix.LiveViewTest requires either bypassing
    # the `chat_live.ex:search_open_result` handler (which early-returns on
    # missing messages) or fabricating Chat messages on different spaces, both
    # of which couple the test to internals. The filter is a one-line
    # `Enum.filter(&MapSet.member?(...))` in `reinsert_for_highlight_change/3`
    # — its correctness is structurally guaranteed by the wider chat_live test
    # suite (any out-of-order insert would change rendered_message_ids count
    # AND break the day-label bookkeeping, both of which the existing 70 tests
    # would catch).
  end

  describe "attachments (the composer's staged tray, rung 11)" do
    # Pasted, picked and dropped files stage as thumbnails INSIDE the composer
    # and post with the typed caption as ONE message through `send_message`
    # (task 01a1557a-9de3). There is no upload dialog any more.

    defp png(name \\ "shot.png", bytes \\ 1000) do
      %{name: name, content: String.duplicate("p", bytes), type: "image/png"}
    end

    defp space_rows(space_id) do
      import Ecto.Query

      messages =
        Repo.all(from(m in Platform.Chat.Message, where: m.space_id == ^space_id))

      attachments =
        Repo.all(
          from(a in Platform.Chat.Attachment,
            where: a.space_id == ^space_id and not is_nil(a.message_id)
          )
        )

      {messages, attachments}
    end

    test "the file input lives inside #compose-form and auto-uploads", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      assert has_element?(view, ~s(#compose-form input[type="file"][name="attachments"]))
      assert has_element?(view, ~s(#compose-form input[name="attachments"][data-phx-auto-upload]))
      # ＋ opens the attach menu (stage 2); the menu's pickers stage into
      # this input's upload.
      assert has_element?(view, ~s(button#compose-attach-button[phx-click="attach_menu_open"]))
    end

    test "a staged image shows as a thumbnail in the tray inside the composer", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      refute has_element?(view, "[data-role=staged-tray]")

      upload = file_input(view, "#compose-form", :attachments, [png()])
      render_upload(upload, "shot.png")

      assert has_element?(
               view,
               ~s(#compose-form .compose-pill-bar [data-role=staged-tray] li img[data-phx-hook="Phoenix.LiveImgPreview"][alt="shot.png"])
             )

      assert has_element?(view, ~s([data-role=staged-tray] button[aria-label="Remove shot.png"]))

      assert has_element?(
               view,
               ~s{#compose_text[data-placeholder="Add a message (optional) — Enter to send"]}
             )
    end

    test "Send posts the caption and the staged file as EXACTLY ONE message", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")
      space = Chat.get_space_by_slug("general")

      upload = file_input(view, "#compose-form", :attachments, [png()])
      render_upload(upload, "shot.png")

      view |> form("#compose-form", compose: %{text: "caption here"}) |> render_submit()

      {messages, attachments} = space_rows(space.id)
      assert [message] = messages
      assert message.content == "caption here"
      assert [attachment] = attachments
      assert attachment.message_id == message.id
      assert attachment.filename == "shot.png"

      # The tray collapses with no empty band.
      refute has_element?(view, "[data-role=staged-tray]")
      assert render(view) =~ "/chat/attachments/#{attachment.id}"
    end

    test "a file with an empty caption sends as one message", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")
      space = Chat.get_space_by_slug("general")

      upload = file_input(view, "#compose-form", :attachments, [png()])
      render_upload(upload, "shot.png")

      refute has_element?(view, "button.compose-pill-send[disabled]")
      view |> form("#compose-form", compose: %{text: ""}) |> render_submit()

      assert {[message], [attachment]} = space_rows(space.id)
      assert message.content in [nil, ""]
      assert attachment.message_id == message.id
    end

    test "Send is disabled and named 'Uploading' mid-transfer, enabled at 100%", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      upload = file_input(view, "#compose-form", :attachments, [png("slow.png", 1000)])

      render_upload(upload, "slow.png", 50)
      assert has_element?(view, ~s(button.compose-pill-send[disabled][aria-label="Uploading"]))
      assert has_element?(view, "[data-role=staged-tray] [data-role=upload-ring]")

      render_upload(upload, "slow.png", 50)
      refute has_element?(view, "button.compose-pill-send[disabled]")
      refute has_element?(view, ~s(button.compose-pill-send[aria-label="Uploading"]))
      refute has_element?(view, "[data-role=staged-tray] [data-role=upload-ring]")
    end

    test "Enter mid-transfer posts nothing (the server guard behind the disabled button)",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")
      space = Chat.get_space_by_slug("general")

      upload = file_input(view, "#compose-form", :attachments, [png("slow.png", 1000)])
      render_upload(upload, "slow.png", 50)

      render_submit(view, "send_message", %{"compose" => %{"text" => "too soon"}})
      assert {[], []} = space_rows(space.id)
    end

    test "attach_remove drops the entry and the tray disappears with the last one",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      # One file_input per file: LiveViewTest serves every entry of one
      # file_input from a single upload client, so cancelling one entry there
      # takes its siblings with it (a browser runs one channel per entry).
      view |> file_input("#compose-form", :attachments, [png("a.png")]) |> render_upload("a.png")
      view |> file_input("#compose-form", :attachments, [png("b.png")]) |> render_upload("b.png")

      [a, b] =
        view.pid |> :sys.get_state() |> then(& &1.socket.assigns.uploads.attachments.entries)

      render_click(view, "attach_remove", %{"ref" => a.ref})

      assert has_element?(view, ~s([data-role=staged-tray] img[alt="b.png"]))

      refute has_element?(view, ~s([data-role=staged-tray] img[alt="a.png"]))

      render_click(view, "attach_remove", %{"ref" => b.ref})
      refute has_element?(view, "[data-role=staged-tray]")
      refute has_element?(view, "[data-role=staged-area]")
    end

    test "a non-image file shows as a chip with its size and type", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      upload =
        file_input(view, "#compose-form", :attachments, [
          %{name: "spec.pdf", content: String.duplicate("d", 2048), type: "application/pdf"}
        ])

      render_upload(upload, "spec.pdf")
      assert has_element?(view, "[data-role=staged-tray] [data-role=file-chip]", "spec")
      assert has_element?(view, "[data-role=staged-tray] [data-role=file-chip]", ".pdf")
      assert has_element?(view, "[data-role=staged-tray] [data-role=file-chip]", "· PDF")
    end

    test "a staged file over the install's limit reads TOO LARGE and disables Send",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")
      max = Platform.Chat.UploadLimits.max_bytes()

      render_hook(view, "large_upload_stage", %{
        "ref" => "big-1",
        "name" => "big.bin",
        "size" => max + 1,
        "type" => "application/octet-stream"
      })

      # A caption is typed, so only the too-large file can be what disables Send.
      render_change(view, "compose_changed", %{"compose" => %{"text" => "the big one"}})

      assert has_element?(view, ~s([data-role=staged-tray] li[data-too-large="true"]))

      assert has_element?(
               view,
               "[data-role=staged-too-large]",
               "This Burrow install accepts files up to #{Platform.Chat.UploadLimits.label()}."
             )

      assert has_element?(view, "button.compose-pill-send[disabled]")

      render_click(view, "large_upload_unstage", %{"ref" => "big-1"})
      refute has_element?(view, "[data-role=staged-tray]")
      refute has_element?(view, "button.compose-pill-send[disabled]")
    end

    test "a sixth file past max_entries renders FAILED (outline, no ring, no retry), not uploading",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      files = for i <- 1..6, do: png("p#{i}.png")
      upload = file_input(view, "#compose-form", :attachments, files)
      render_upload(upload, "p1.png")

      assert has_element?(view, "[data-role=staged-error]", "Too many files")

      [_ | _] =
        entries =
        view.pid |> :sys.get_state() |> then(& &1.socket.assigns.uploads.attachments.entries)

      assert length(entries) == 6
      excess = List.last(entries)
      assert excess.client_name == "p6.png"

      assert has_element?(view, ~s(li#staged-#{excess.ref}[data-state="failed"]))
      assert has_element?(view, ~s(li#staged-#{excess.ref} .outline-error))
      refute has_element?(view, ~s(li#staged-#{excess.ref} [data-role=upload-ring]))
      # Too many is a refusal, not a transport failure: removing it is the fix.
      refute has_element?(view, ~s(li#staged-#{excess.ref} [data-attach-retry]))
      assert has_element?(view, ~s(li#staged-#{excess.ref} button[aria-label="Remove p6.png"]))

      # Positive control: the first entry, within the limit, is not failed.
      first = hd(entries)
      refute has_element?(view, ~s(li#staged-#{first.ref}[data-state="failed"]))

      # Removing the excess entry clears the refusal.
      render_click(view, "attach_remove", %{"ref" => excess.ref})
      refute has_element?(view, "[data-role=staged-error]", "Too many files")
      refute has_element?(view, ~s(li[data-state="failed"]))
    end

    test "a file a socket drop interrupted comes back FAILED with 'Retry <name>', and retry posts it",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")
      space = Chat.get_space_by_slug("general")

      # What ComposeInput reports on reconnect for an entry that was mid-upload
      # when the socket dropped (assets/js/attach_stage.js `restage/2`).
      render_hook(view, "attach_transport_failed", %{
        "files" => [
          %{
            "id" => "phx-old-1",
            "name" => "big.png",
            "size" => 14_000_000,
            "type" => "image/png"
          },
          %{"bogus" => true},
          %{"id" => "", "name" => "empty-id.png"}
        ]
      })

      assert has_element?(view, ~s(li#staged-failed-phx-old-1[data-state="failed"]))
      assert has_element?(view, ~s(li#staged-failed-phx-old-1 .outline-error))

      assert has_element?(
               view,
               ~s(li#staged-failed-phx-old-1 button[data-attach-retry="phx-old-1"][aria-label="Retry big.png"])
             )

      assert has_element?(
               view,
               ~s(li#staged-failed-phx-old-1 img[phx-hook="AttachFailedPreview"][alt="big.png"])
             )

      assert has_element?(
               view,
               ~s(li#staged-failed-phx-old-1 button[aria-label="Remove big.png"])
             )

      # Only that thumbnail: the malformed reports render nothing.
      assert [_] =
               view
               |> render()
               |> LazyHTML.from_document()
               |> LazyHTML.query("li[data-failed-id]")
               |> Enum.to_list()

      # A failed file blocks Send, as a failed entry does.
      assert has_element?(view, "button.compose-pill-send[disabled]")

      # Retry: the client drops the failed item and stages the same File again.
      render_click(view, "attach_failed_remove", %{"id" => "phx-old-1"})
      refute has_element?(view, "li[data-failed-id]")

      view
      |> file_input("#compose-form", :attachments, [png("big.png")])
      |> render_upload("big.png")

      refute has_element?(view, "button.compose-pill-send[disabled]")

      view |> form("#compose-form", compose: %{text: "after the drop"}) |> render_submit()
      assert {[message], [attachment]} = space_rows(space.id)
      assert message.content == "after the drop"
      assert attachment.filename == "big.png"
    end

    test "staged uploads are cancelled when navigating to another space (BACKLOG #10)",
         %{conn: conn} do
      conn = authenticated_conn(conn)

      {:ok, _} = Chat.create_space(%{name: "Other", slug: "other", kind: "channel"})

      {:ok, view, _html} = live(conn, ~p"/chat/general")

      upload =
        file_input(view, "#compose-form", :attachments, [
          %{name: "leak.txt", content: "would-leak", type: "text/plain"}
        ])

      assert render_upload(upload, "leak.txt") =~ "leak.txt"

      # Both /chat/:space_slug routes map to the same LiveView, so
      # handle_params fires in-process, which is the seam where we cancel.
      html = render_patch(view, ~p"/chat/other")

      assert html =~ "Canceled 1 pending upload from the previous space"
      refute has_element?(view, "[data-role=staged-tray]")
      refute render(view) =~ "leak.txt"
    end
  end

  # ── Agent typing (BACKLOG #9) ──────────────────────────────────────────

  describe "agent typing — space scoping" do
    test "a typing broadcast from a non-active space does not flip the active LV's thinking label",
         %{conn: conn} do
      conn = authenticated_conn(conn)

      {:ok, other_space} =
        Chat.create_space(%{name: "Other", slug: "other", kind: "channel"})

      {:ok, view, _html} = live(conn, ~p"/chat/general")

      # ChatLive.mount subscribes to every space in the user's sidebar
      # for unread-count updates — so the LV IS listening on `other_space`'s
      # topic. Before this fix, the receiver used the participant_id only
      # and would flip `:agent_typing_pids` regardless of which space the
      # broadcast originated in, so Robin-in-a-DM saw Higgins-typing-in-
      # #general. After the fix, the broadcast's :space_id must match
      # `active_space.id` or the LV drops the event.
      Platform.Chat.PubSub.broadcast(
        other_space.id,
        {:agent_typing,
         %{
           space_id: other_space.id,
           participant_id: Ecto.UUID.generate(),
           typing: true
         }}
      )

      # Give the LV a tick to process the info message.
      :ok = Process.sleep(50)

      html = render(view)
      refute html =~ "is thinking"
    end

    test "a typing broadcast whose space_id matches the active space still flips the label",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      general = Chat.get_space_by_slug("general")
      agent = insert_chat_agent(%{slug: "higgins-test", name: "Higgins"})

      {:ok, agent_participant} =
        Chat.add_participant(general.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: agent.name,
          joined_at: DateTime.utc_now()
        })

      Platform.Chat.PubSub.broadcast(
        general.id,
        {:agent_typing,
         %{
           space_id: general.id,
           participant_id: agent_participant.id,
           typing: true
         }}
      )

      :ok = Process.sleep(50)

      assert render(view) =~ "is thinking"
    end

    test "a typing broadcast with no :space_id key at all is dropped, even on the active space",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      general = Chat.get_space_by_slug("general")
      agent = insert_chat_agent(%{slug: "quillon-test", name: "Quillon"})

      {:ok, agent_participant} =
        Chat.add_participant(general.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: agent.name,
          joined_at: DateTime.utc_now()
        })

      # The payload carries NO :space_id key. It is delivered on the ACTIVE
      # space's topic and names a participant of that space, so everything
      # except the scope key lines up — the only reason to drop it is that
      # the scope predicate must fail closed on a payload it cannot scope.
      # Until this stage a catch-all clause returned `true` here, which
      # accepted such a payload from ANY subscribed topic.
      Platform.Chat.PubSub.broadcast(
        general.id,
        {:agent_typing, %{participant_id: agent_participant.id, typing: true}}
      )

      :ok = Process.sleep(50)

      refute render(view) =~ "is thinking"
    end
  end

  # ── Reactions ────────────────────────────────────────────────────────────────

  describe "reactions" do
    test "renders quick emoji buttons on each message", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      # Post a message so there's something to react to
      view
      |> form("#compose-form", compose: %{text: "react to me"})
      |> render_submit()

      html = render(view)
      assert html =~ "react to me"

      # Quick emoji buttons should be present (in the action bar). Asserted
      # against the pinned row rather than a hand-listed subset: this test
      # listed four of the six and so stayed green through the entire period
      # the hover row and the double-tap pill disagreed (task 019e0814
      # stage 2). A subset check cannot see a missing emoji.
      for emoji <- @quick_react_row do
        assert html =~ emoji
      end
    end

    test "renders the (+) add-reaction button on a message with zero reactions",
         %{conn: conn} do
      # Locks in the always-render behavior (task 019e3402 Stage 1): the
      # reaction-row wrapper used to be gated by `:if={@msg.reactions != []}`
      # so the (+) only appeared once a message had a reaction. We removed
      # that gate; this assertion guards against re-introducing it.
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "no reactions yet"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      # Sanity-check: the message exists with zero reactions in the DB.
      assert Chat.list_reactions(msg.id) == []

      html = render(view)

      # The add-reaction control MUST render even though the message has no
      # reactions. That is what task 019e3402 stage 1 was protecting, and it
      # still holds.
      assert html =~ ~s(aria-label="Add reaction")

      # THE GUARD MOVED, IT DID NOT VANISH (task 01a000c0 stage 3). This used
      # to also assert `reaction-add-btn`, the dashed pill that sat in the
      # reaction row below the message body. That control now lives in the
      # upper-right action row, so the class is gone by design — asserting it
      # would pin the OLD location rather than the behaviour.
      #
      # What the original guard was actually protecting is unchanged: you can
      # add a reaction to a message that has none. So assert that, at its new
      # home, rather than deleting the case.
      refute html =~ "reaction-add-btn"

      assert html =~ ~s(phx-click="open_reaction_picker")

      # And it is inside the action row, not orphaned somewhere else in the
      # markup — the row is revealed by opacity so it stays tab-reachable
      # (see the comment on that div in chat_message.ex).
      assert html =~ "group-focus-within:opacity-100"
    end

    test "reacting to a message persists the reaction and updates the reaction count in the UI",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "emoji test"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      # Before reacting — no reaction row for this message in the DB
      assert Chat.list_reactions(msg.id) == []

      render_click(view, "react", %{"message-id" => msg.id, "emoji" => "👍"})

      # The reaction is persisted in the DB
      assert [%{emoji: "👍"}] = Chat.list_reactions(msg.id)

      # The rendered HTML shows the count badge "1" next to the emoji (reaction-row markup)
      html = render(view)
      assert html =~ "👍"
      # The reaction count span should contain "1" adjacent to the emoji
      assert Regex.match?(~r/👍[\s\S]*?<span>1<\/span>|<span>1<\/span>[\s\S]*?👍/, html)
    end

    test "reacting twice to the same message removes the reaction (toggle)", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "toggle reaction"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      # React once — reaction is added
      render_click(view, "react", %{"message-id" => msg.id, "emoji" => "👍"})
      assert [_] = Chat.list_reactions(msg.id)

      # React again (same user, same emoji) — reaction is removed
      render_click(view, "react", %{"message-id" => msg.id, "emoji" => "👍"})
      assert Chat.list_reactions(msg.id) == []
    end

    test "a reaction from another participant updates the DOM without remount",
         %{conn: conn} do
      # Reactions arriving via PubSub must update the rendered pill/count for
      # already-visible messages. Pills render inside the :messages stream
      # iteration and ride on the stream item itself (Message.reactions virtual
      # field) — every stream_insert re-renders the item with fresh groups.
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "remote-reaction target"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      other_user = insert_chat_user(%{email: "other@example.com", oidc_sub: "other-sub"})

      {:ok, other_participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: other_user.id,
          display_name: other_user.name,
          joined_at: DateTime.utc_now()
        })

      {:ok, _reaction} =
        Chat.add_reaction(%{
          message_id: msg.id,
          participant_id: other_participant.id,
          emoji: "🎉"
        })

      # Assert exactly one pill with count=1 — the exact pill markup, not a
      # loose regex that would false-positive on other <span>1</span> on the
      # page (reply counts, unread badges).
      html = render(view)
      assert count_occurrences(html, "<span>🎉</span><span>1</span>") == 1

      # Removal live-updates the DOM: pill disappears, groups are pruned.
      {:ok, _} = Chat.remove_reaction(msg.id, other_participant.id, "🎉")
      html = render(view)
      assert count_occurrences(html, "<span>🎉</span>") == 0
    end

    test "react event in one LV broadcasts the new pill to a peer LV in the same space",
         %{conn: _conn} do
      # The existing "a reaction from another participant" test bypasses the
      # `react` event handler — it calls Chat.add_reaction/1 directly to fire
      # the broadcast. That covers handle_info, but does NOT lock in the
      # contract that clicking the action-bar button on one user's LV causes
      # a peer user's LV to re-render with the new pill.
      #
      # This test mounts two LVs as different users, has user A click `react`
      # on their own message, and asserts user B's rendered HTML grows the
      # pill — verifying the full path:
      #   LV-A:react event → Chat.toggle_reaction/3 → ChatPubSub.broadcast →
      #   LV-B:handle_info({:reaction_added, _}) → reinsert_stream_message.
      alice =
        insert_chat_user(%{email: "alice@example.com", oidc_sub: "alice-sub", name: "Alice"})

      bob = insert_chat_user(%{email: "bob@example.com", oidc_sub: "bob-sub", name: "Bob"})

      conn_a = init_test_session(Phoenix.ConnTest.build_conn(), current_user_id: alice.id)
      conn_b = init_test_session(Phoenix.ConnTest.build_conn(), current_user_id: bob.id)

      {:ok, view_a, _} = live(conn_a, ~p"/chat/general")
      {:ok, view_b, _} = live(conn_b, ~p"/chat/general")

      view_a
      |> form("#compose-form", compose: %{text: "two-LV PubSub target"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      # Sanity: B sees the message (confirms B's subscription is live).
      assert render(view_b) =~ "two-LV PubSub target"

      # Alice clicks 👍 via the `react` event on her own message.
      render_click(view_a, "react", %{"message-id" => msg.id, "emoji" => "👍"})

      # Bob's LV — without any client-side interaction — must show the pill.
      html_b = render(view_b)
      assert count_occurrences(html_b, "<span>👍</span><span>1</span>") == 1

      # Inverse: Alice toggles off via a second `react` click → Bob's pill
      # disappears. Locks in the remove-broadcast path of the same contract.
      render_click(view_a, "react", %{"message-id" => msg.id, "emoji" => "👍"})

      html_b_after_remove = render(view_b)
      assert count_occurrences(html_b_after_remove, "<span>👍</span>") == 0
    end

    test "duplicate reaction_added delivery does not double-count",
         %{conn: conn} do
      # Stream-shape refactor guarantee: reactions ride on the stream item,
      # rebuilt from DB truth on every stream_insert. Duplicate delivery of
      # the same {:reaction_added, _} message (possible if the LV accidentally
      # subscribes twice, which is exactly what used to happen — see the
      # hotfix PR #199) must NOT double-count. Before the refactor, the
      # incremental `add_reaction_to_map` would have produced count=3 here.
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "idempotency target"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      other_user =
        insert_chat_user(%{email: "dup@example.com", oidc_sub: "dup-sub"})

      {:ok, other_participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: other_user.id,
          display_name: other_user.name,
          joined_at: DateTime.utc_now()
        })

      {:ok, reaction} =
        Chat.add_reaction(%{
          message_id: msg.id,
          participant_id: other_participant.id,
          emoji: "🎉"
        })

      # Simulate duplicate delivery by hand — send the same broadcast payload
      # to the LV pid twice after the real one.
      send(view.pid, {:reaction_added, reaction})
      send(view.pid, {:reaction_added, reaction})

      html = render(view)
      assert count_occurrences(html, "<span>🎉</span><span>1</span>") == 1
      refute html =~ "<span>🎉</span><span>2</span>"
      refute html =~ "<span>🎉</span><span>3</span>"
    end

    test "entering a space pre-populates reactions on stream items",
         %{conn: conn} do
      # Bulk path: enter_space calls enrich_messages_with_reactions which
      # batch-loads all reactions in one query, then attaches to each message
      # as the `:reactions` virtual field. The rendered page on first mount
      # must show pre-existing reactions without any post-mount broadcast.
      conn = authenticated_conn(conn)

      # Seed: create a message and a reaction on it BEFORE anyone mounts the
      # LV, so it only appears via the bulk enrichment path.
      space =
        Chat.get_space_by_slug("general") ||
          elem(Chat.create_space(%{name: "General", slug: "general", kind: "channel"}), 1)

      user = insert_chat_user(%{email: "pre@example.com", oidc_sub: "pre-sub"})
      # add_user_message both adds the participant and posts the message —
      # capture the participant so we don't double-add (unique constraint).
      participant = add_user_message(space, user, "pre-reacted message")
      [msg | _] = Chat.list_messages(space.id)

      {:ok, _} =
        Chat.add_reaction(%{
          message_id: msg.id,
          participant_id: participant.id,
          emoji: "👍"
        })

      # Now mount the LV — the initial render must include the 👍 pill with
      # count=1, populated by the bulk enrichment in enter_space.
      {:ok, _view, html} = live(conn, ~p"/chat/general")
      assert count_occurrences(html, "<span>👍</span><span>1</span>") == 1
    end

    test "reacting with a nil/missing participant does not crash the LiveView", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "safety message"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [_msg | _] = Chat.list_messages(space.id)

      # Deliberately send a bad/unknown message-id — handler should not crash
      html =
        render_click(view, "react", %{
          "message-id" => "00000000-0000-0000-0000-000000000000",
          "emoji" => "👍"
        })

      assert is_binary(html)
      assert html =~ "safety message"
    end

    test "reaction pill carries data-reactors JSON and aria-label with reactor names",
         %{conn: conn} do
      # Desktop reactor-popover feature: the server embeds the reactor list
      # in data-reactors on each pill (read lazily on hover by the JS hook)
      # and emits an aria-label on the pill itself so screen readers get
      # the full list without needing to open the popover. Mobile is
      # intentionally no-op on the hook side, but the aria-label is
      # rendered on every platform.
      conn = authenticated_conn(conn)

      space =
        Chat.get_space_by_slug("general") ||
          elem(Chat.create_space(%{name: "General", slug: "general", kind: "channel"}), 1)

      alice = insert_chat_user(%{name: "Alice", email: "alice@example.com", oidc_sub: "alice"})
      bob = insert_chat_user(%{name: "Bob", email: "bob@example.com", oidc_sub: "bob"})

      alice_participant = add_user_message(space, alice, "pizza or thai?")
      [msg | _] = Chat.list_messages(space.id)

      {:ok, bob_participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: bob.id,
          display_name: bob.name,
          joined_at: DateTime.utc_now()
        })

      {:ok, _} =
        Chat.add_reaction(%{
          message_id: msg.id,
          participant_id: alice_participant.id,
          emoji: "🍕"
        })

      {:ok, _} =
        Chat.add_reaction(%{
          message_id: msg.id,
          participant_id: bob_participant.id,
          emoji: "🍕"
        })

      {:ok, _view, html} = live(conn, ~p"/chat/general")

      # Pill carries the data attributes the hook reads.
      assert html =~ ~s(phx-hook="ReactorPopover")
      assert html =~ ~s(data-emoji="🍕")

      # Both reactor names are embedded in the JSON payload (order
      # follows insertion; the test doesn't pin order).
      assert html =~ "Alice"
      assert html =~ "Bob"
      assert html =~ ~s(data-reactors=)

      # aria-label on the pill itself renders the human-readable list
      # regardless of hook activation.
      assert html =~ "Alice and Bob reacted with 🍕" ||
               html =~ "Bob and Alice reacted with 🍕"
    end

    test "reactor name survives hard-delete of the participant",
         %{conn: conn} do
      # Snapshot parity with ADR 0038: when a participant is hard-deleted
      # from a space, the reactions they made keep the display name they
      # had at reaction-time. The ON DELETE SET NULL FK nulls the
      # reaction's participant_id but leaves the snapshot columns, and
      # the read-path falls back to them.
      conn = authenticated_conn(conn)

      space =
        Chat.get_space_by_slug("general") ||
          elem(Chat.create_space(%{name: "General", slug: "general", kind: "channel"}), 1)

      author =
        insert_chat_user(%{name: "Author", email: "author@example.com", oidc_sub: "author"})

      reactor = insert_chat_user(%{name: "Zoe", email: "zoe@example.com", oidc_sub: "zoe"})

      _author_participant = add_user_message(space, author, "vote on this")
      [msg | _] = Chat.list_messages(space.id)

      {:ok, reactor_participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: reactor.id,
          display_name: reactor.name,
          joined_at: DateTime.utc_now()
        })

      {:ok, _} =
        Chat.add_reaction(%{
          message_id: msg.id,
          participant_id: reactor_participant.id,
          emoji: "👍"
        })

      # Sanity: snapshot was captured at write time.
      [reaction] = Chat.list_reactions(msg.id)
      assert reaction.reactor_display_name == "Zoe"
      assert reaction.reactor_participant_type == "user"

      # Hard-delete the reactor's participant row (simulating dismissal).
      # The FK is ON DELETE SET NULL, so the reaction row survives with
      # participant_id: nil and the snapshot intact.
      Repo.delete!(reactor_participant)

      [reaction_after] = Chat.list_reactions(msg.id)
      assert reaction_after.participant_id == nil
      assert reaction_after.reactor_display_name == "Zoe"

      # LV load still renders Zoe's name via the snapshot fallback —
      # aria-label gets the right reactor even though the live
      # participants_map no longer contains them.
      {:ok, _view, html} = live(conn, ~p"/chat/general")

      assert html =~ "Zoe"
      assert html =~ "Zoe reacted with 👍"
    end

    test "reactor popover marks agent reactors with is_agent=true",
         %{conn: conn} do
      # Agents react via the same Participant/Reaction path humans do.
      # The reactor list must flag them so the UI can render the AI badge.
      conn = authenticated_conn(conn)

      space =
        Chat.get_space_by_slug("general") ||
          elem(Chat.create_space(%{name: "General", slug: "general", kind: "channel"}), 1)

      user = insert_chat_user(%{name: "Robin", email: "robin@example.com", oidc_sub: "robin"})
      agent = insert_chat_agent(%{name: "Higgins", slug: "higgins"})

      _user_participant = add_user_message(space, user, "anyone around?")
      [msg | _] = Chat.list_messages(space.id)

      {:ok, agent_participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: agent.name,
          joined_at: DateTime.utc_now()
        })

      {:ok, _} =
        Chat.add_reaction(%{
          message_id: msg.id,
          participant_id: agent_participant.id,
          emoji: "✅"
        })

      {:ok, _view, html} = live(conn, ~p"/chat/general")

      # JSON attribute must carry is_agent:true for the agent reactor.
      # The Jason encoder escapes quotes in HTML attributes, so match
      # permissively across the encoding.
      assert html =~ ~s(data-emoji="✅")
      assert html =~ "Higgins"
      assert html =~ ~s("is_agent":true) || html =~ ~s(&quot;is_agent&quot;:true)
    end

    test "opening the reaction picker renders the popover for the target message",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/chat/general")

      # The picker is MOUNTED before anyone opens it — the JS hook builds its
      # ~1,850-tile grid once and it has to survive a close — so "not open" is
      # state, not absence. See assert_picker_closed/1.
      assert html =~ ~s(id="reaction-picker")
      assert_picker_closed(view)

      view
      |> form("#compose-form", compose: %{text: "picker target"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      html = render_click(view, "open_reaction_picker", %{"message-id" => msg.id})

      # The picker is now OPEN, and carries the target message id on the
      # container. The tiles no longer carry `phx-value-message-id`: they are
      # built by the hook, which reads `data-message-id` off this element at
      # click time and pushes the hyphenated `"message-id"` key the server
      # matches on.
      assert html =~ ~s(id="reaction-picker")
      assert html =~ ~s(aria-label="Add reaction")
      assert_picker_open(view, msg.id)

      # The grid is CLIENT-BUILT. A server-rendered tile here would mean the
      # ~180-210KB-per-open regression this stage exists to remove has crept
      # back in, and the hook's host would be fighting morphdom for the same
      # children.
      refute has_element?(view, ".reaction-picker-tile")

      assert has_element?(
               view,
               ~s(#reaction-picker-body[phx-hook="ReactionPicker"][phx-update="ignore"])
             )
    end

    test "the picker container is mounted, closed and inert before it is opened",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      assert_picker_closed(view)

      # THE HAZARD, stated as an assertion. A permanently-mounted picker puts a
      # full-viewport inset-0 scrim carrying phx-click="close_reaction_picker"
      # in the DOM for the life of the page. If the closed gate is wrong, that
      # scrim eats every click on the chat surface and nothing looks broken.
      # `inert` is the layer that survives a CSS mistake.
      assert has_element?(view, "#reaction-picker[inert] .reaction-picker-scrim")

      # The window Escape binding must NOT be live while closed, or every
      # Escape anywhere in chat costs a round trip pushing a no-op close.
      refute has_element?(view, ~s(#reaction-picker[phx-window-keydown]))

      # The hook host ships EMPTY. Anything server-rendered inside a
      # phx-update="ignore" host is frozen at first render and can never be
      # updated again (task 01a0693d, the transcript pane's empty state).
      assert [""] =
               view
               |> render()
               |> Floki.parse_document!()
               |> Floki.find("#reaction-picker-body")
               |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
    end

    test "the search field is client-built and costs no round trip per keystroke",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "search field"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      html = render_click(view, "open_reaction_picker", %{"message-id" => msg.id})

      picker =
        html
        |> Floki.parse_document!()
        |> Floki.find("#reaction-picker")

      # NO SERVER-RENDERED INPUT. The field lives inside the
      # `phx-update="ignore"` host and is built by the hook, because a
      # LiveView-owned input would have its `value` re-synced by morphdom on
      # every patch — so anyone posting a message in the space would wipe what
      # the user had typed mid-search.
      assert [] = Floki.find(picker, "input")

      # AND NO `phx-change` ANYWHERE IN THE PICKER. The superseded ticket
      # 019e0814-dba5-7e74-84cd-e48e6689f44d proposed exactly that, which puts
      # a round trip on every keystroke over an inventory the client already
      # holds. Matching is client-side in assets/js/lib/emoji_search.js.
      assert [] = Floki.find(picker, "[phx-change]")

      # The host is still empty, so the four assertions above cannot be
      # satisfied by a field the server rendered somewhere else inside it.
      assert [""] =
               html
               |> Floki.parse_document!()
               |> Floki.find("#reaction-picker-body")
               |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
    end

    test "the Escape window binding exists only while the picker is open",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "escape binding"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      render_click(view, "open_reaction_picker", %{"message-id" => msg.id})

      assert has_element?(
               view,
               ~s(#reaction-picker[phx-window-keydown="close_reaction_picker"][phx-key="Escape"])
             )

      render_click(view, "close_reaction_picker", %{})
      refute has_element?(view, ~s(#reaction-picker[phx-window-keydown]))
    end

    test "closing the reaction picker returns it to the closed state", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "close-picker"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      html = render_click(view, "open_reaction_picker", %{"message-id" => msg.id})
      assert html =~ ~s(id="reaction-picker")
      assert_picker_open(view, msg.id)

      render_click(view, "close_reaction_picker", %{})

      # The container STAYS — closing is a state change, not an unmount, and
      # that is exactly why the closed state has to be asserted rather than the
      # container's absence.
      assert_picker_closed(view)
    end

    test "selecting an emoji from the picker reacts and closes the picker",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "picker react"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      # Open the picker.
      render_click(view, "open_reaction_picker", %{"message-id" => msg.id})

      # Pick an emoji that is NOT in @quick_emojis, to prove the picker is the
      # path under test (not the hover quick-react buttons).
      html = render_click(view, "react", %{"message-id" => msg.id, "emoji" => "🚀"})

      # Reaction is persisted.
      assert [%{emoji: "🚀"}] = Chat.list_reactions(msg.id)

      # Picker is closed after selection — one-click flow. Still mounted.
      assert html =~ ~s(id="reaction-picker")
      assert_picker_closed(view)
    end
  end

  # ── Quick-react popover (mobile double-tap) ─────────────────────────────────

  describe "quick-react popover" do
    test "opening the popover renders the dialog with the target message id",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/chat/general")

      refute html =~ ~s(id="longpress-menu")

      view
      |> form("#compose-form", compose: %{text: "double-tap target"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      html = render_hook(view, "open_longpress_menu", %{"message_id" => msg.id})

      assert html =~ ~s(id="longpress-menu")
      assert html =~ ~s(aria-label="Message actions")
      # The MessageLift hook reads the target via this attribute and clones
      # the corresponding DOM element on mount.
      assert html =~ ~s(data-target-message-id="#{msg.id}")
      assert html =~ ~s(phx-hook="MessageLift")
      # Scrim + pill render together; the Copy / Open-in-thread / Pin action
      # card was removed when long-press was replaced with double-tap, since
      # the card surfaced actions that either duplicated the browser's
      # native selection menu (Copy) or were frequently triggered by
      # accident (Pin).
      assert html =~ "longpress-scrim"
      assert html =~ "longpress-pill"
      # Action card container and its rows are gone — verified via the
      # container class (checking the row labels would false-positive on
      # the desktop hover-bar, which reuses strings like "Copy message"
      # as button titles).
      refute html =~ "longpress-card"
      refute html =~ "longpress-card-label"
      assert html =~ ~s(aria-label="Quick reactions")
      # Emojis should all be present in the pill.
      for emoji <- ~w(👍 🎉 ✅ ❤️ 😂 🙏) do
        assert html =~ emoji
      end
    end

    test "closing the popover removes it from the DOM", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "double-tap close"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      html = render_hook(view, "open_longpress_menu", %{"message_id" => msg.id})
      assert html =~ ~s(id="longpress-menu")

      html = render_click(view, "close_longpress_menu", %{})
      refute html =~ ~s(id="longpress-menu")
    end

    test "message bubbles carry the LongpressMenu hook, data-message-id, and data-is-own-message",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "double-tap attach"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      html = render(view)
      # Hook name retained for minimal churn; the JS now listens for
      # double-tap rather than a 450ms hold.
      assert html =~ ~s(phx-hook="LongpressMenu")
      assert html =~ ~s(data-message-id="#{msg.id}")
      # Authorship flag is what the JS reads to skip firing on the
      # current user's own bubbles (reserved for edit gesture, PR2).
      assert html =~ ~s(data-is-own-message="true")
    end

    test "tapping an emoji in the pill persists a reaction and closes the popover",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "pill react target"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      render_hook(view, "open_longpress_menu", %{"message_id" => msg.id})

      # Fire the same event the pill emits (phx-click="react" with
      # message-id + emoji as phx-value-* attributes).
      html = render_click(view, "react", %{"message-id" => msg.id, "emoji" => "🎉"})

      # Reaction persisted.
      assert [%{emoji: "🎉"}] = Chat.list_reactions(msg.id)

      # Popover closed — close_picker/1 also resets :longpress_menu_for.
      refute html =~ ~s(id="longpress-menu")
    end
  end

  # ── Quick-reaction strip in the touch actions sheet ─────────────────────────
  #
  # Task 01a000c0 stage 1. On touch there is no hover, so the always-visible
  # dashed "+" is currently the only add-reaction path on a phone. Later
  # stages of this task move that "+" into the desktop hover row, which a
  # touch device never reveals — these guards pin the replacement path so
  # that move cannot strand phone users.
  #
  # The contract under test is ONE TAP: tapping a strip emoji must persist
  # the reaction and close the sheet, with no picker in between. A test that
  # has to open the picker to succeed is testing the wrong thing.
  #
  # The strip is 👍 ❤️ 😂 🎉 + — five targets in ONE row, the last of them a
  # "+" that opens the picker. Sam ruled out the separate "More
  # reactions…" row these tests originally pinned: stage 3 puts a "+" beside
  # the same four emoji in the desktop hover row, and a labelled menu row on
  # touch against a glyph on pointer would be two ways to do one thing.

  describe "message actions sheet — quick-reaction strip" do
    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "sheet strip target"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      %{view: view, msg: msg}
    end

    test "the sheet renders a one-tap strip for every quick emoji, above the action rows",
         %{view: view, msg: msg} do
      html = render_click(view, "open_message_actions", %{"id" => msg.id})

      assert html =~ ~s(id="message-actions-quick-reactions")
      assert html =~ ~s(aria-label="Quick reactions")

      # The strip is driven by @quick_emojis — the SAME assign the desktop
      # hover action row and the double-tap pill render — so the surfaces
      # cannot drift. That was aspirational until task 019e0814 stage 2: this
      # loop asserted four emoji while the pill rendered six. If the set
      # changes, change `Platform.Chat.Emoji.quick_defaults/0`, never a
      # template and never this literal alone.
      for emoji <- @quick_react_row do
        assert html =~ ~s(phx-value-emoji="#{emoji}")
        assert html =~ ~s(aria-label="React with #{emoji}")
      end

      # Every strip button carries the sheet's target message id, so a tap
      # reacts to the message the sheet was opened for.
      assert html =~ ~s(phx-value-message-id="#{msg.id}")

      # The strip sits ABOVE "Reply in thread" — ordering is the design, not
      # an accident: the one-tap path is first, the menu rows follow.
      strip_at = :binary.match(html, "message-actions-quick-reactions") |> elem(0)
      reply_at = :binary.match(html, "Reply in thread") |> elem(0)
      assert strip_at < reply_at

      # The escape hatch is the "+" INSIDE the strip, not a labelled row of
      # its own — Sam's ruling, and the shape stage 3 gives the desktop
      # hover row. So it must fall between the strip and "Reply in thread",
      # and the old bottom row must be gone entirely.
      more_at = :binary.match(html, ~s(id="message-actions-more-reactions")) |> elem(0)
      assert strip_at < more_at
      assert more_at < reply_at
      refute html =~ "More reactions…"
    end

    test "every strip button is at least a 44x44 CSS px touch target",
         %{view: view, msg: msg} do
      html = render_click(view, "open_message_actions", %{"id" => msg.id})

      buttons =
        html
        |> Floki.parse_document!()
        |> Floki.find("#message-actions-quick-reactions button")

      # Counted in two parts on purpose, rather than asserting one total.
      # The strip holds two DIFFERENT kinds of target: the emoji that come
      # from @quick_emojis, and one "+" that opens the picker. A flat total
      # would still pass if somebody added the "+" as an extra emoji in the
      # assign and deleted the real control — exactly the mistake the
      # ruling's wording ("the + is a control, not an emoji") invites. So
      # pin the two facts separately.
      emoji_buttons = Floki.filter_out(buttons, "#message-actions-more-reactions")
      assert length(emoji_buttons) == length(@quick_react_row)

      assert [_] = Floki.find(buttons, "#message-actions-more-reactions")
      refute html =~ ~s(phx-value-emoji="+")

      # ALL of them, "+" included, are 44x44. size-11 is Tailwind's 2.75rem on
      # both axes, matching the .longpress-pill-btn hit target this strip
      # borrows from. shrink-0 stops flex from squeezing one below 44px on a
      # narrow phone — the "+" is last in the row and would be squeezed first,
      # and the row got longer when the set went from four to six.
      assert length(buttons) == length(@quick_react_row) + 1

      for button <- buttons do
        classes = button |> Floki.attribute("class") |> List.first() |> String.split()
        assert "size-11" in classes
        assert "shrink-0" in classes
      end
    end

    test "one tap on a strip emoji persists the reaction and closes the sheet",
         %{view: view, msg: msg} do
      render_click(view, "open_message_actions", %{"id" => msg.id})

      # Click the real element so the chained JS command runs exactly as it
      # will in the browser: push("react") with the phx-value-* attributes,
      # then push("close_message_actions"). Firing the bare event by name
      # would skip the wiring this stage is adding.
      view
      |> element("#message-actions-quick-reactions button", "🎉")
      |> render_click()

      assert [%{emoji: "🎉"}] = Chat.list_reactions(msg.id)

      html = render(view)

      # ONE TAP: the sheet is gone and the picker never OPENED. The picker
      # container is always mounted now, so its absence is not the thing to
      # check — its closed state is.
      refute html =~ ~s(id="message-actions-sheet")
      assert_picker_closed(view)
    end

    test "the '+' at the end of the strip opens the picker and closes the sheet",
         %{view: view, msg: msg} do
      render_click(view, "open_message_actions", %{"id" => msg.id})

      # Scoped THROUGH the strip container: the control has to be reachable
      # as the last target in the emoji row, not as a row somewhere else in
      # the sheet. If it is ever lifted back out into its own labelled row,
      # this selector stops matching and the test fails.
      view
      |> element("#message-actions-quick-reactions #message-actions-more-reactions")
      |> render_click()

      html = render(view)

      assert html =~ ~s(id="reaction-picker")
      refute html =~ ~s(id="message-actions-sheet")

      # The "+" opens the picker; it does not itself react.
      assert [] = Chat.list_reactions(msg.id)
    end

    test "the sheet's Pin / Unpin row pins and unpins the message and closes the sheet",
         %{view: view, msg: msg} do
      # Phones have no hover pin button, so this sheet row is their only way
      # to pin. Click the real element so the chained JS command runs as it
      # does in the browser: push("pin_toggle") with the value map built in
      # the template, then push("close_message_actions"). Firing pin_toggle
      # by name would supply params the template never sends — the bug this
      # guards is a value map with no "space-id", which no PinHooks clause
      # matches, so the event fell through to a ChatLive with no catch-all
      # handle_event and crashed the LiveView.
      render_click(view, "open_message_actions", %{"id" => msg.id})

      view
      |> element("#message-actions-pin")
      |> render_click()

      assert msg.id in Enum.map(Chat.list_pins(msg.space_id), & &1.message_id)

      html = render(view)
      refute html =~ ~s(id="message-actions-sheet")

      # Second tap through the sheet takes the unpin path.
      render_click(view, "open_message_actions", %{"id" => msg.id})

      view
      |> element("#message-actions-pin")
      |> render_click()

      refute msg.id in Enum.map(Chat.list_pins(msg.space_id), & &1.message_id)
      refute render(view) =~ ~s(id="message-actions-sheet")
    end
  end

  # ── Mobile drawer ────────────────────────────────────────────────────────────

  # ── Threads ──────────────────────────────────────────────────────────────────

  describe "threads" do
    test "opening a thread expands the inline thread composer", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "start a thread here"})
      |> render_submit()

      slug = "general"
      space = Chat.get_space_by_slug(slug)
      [msg | _] = Chat.list_messages(space.id)

      html = render_click(view, "open_thread", %{"message-id" => msg.id})

      assert html =~ "inline-thread-compose-form-#{msg.id}"
      assert html =~ "Reply in thread..."
    end

    test "toggling the inline thread closed hides its composer", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "thread close test"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      render_click(view, "open_thread", %{"message-id" => msg.id})
      html = render_click(view, "toggle_inline_thread", %{"message-id" => msg.id})

      refute html =~ "inline-thread-compose-form-#{msg.id}"
    end

    test "posting a thread reply appears once inline", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "root message"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      render_click(view, "open_thread", %{"message-id" => msg.id})

      render_submit(view, "send_inline_thread_message", %{
        "inline_thread_compose" => %{"text" => "thread reply", "message_id" => msg.id}
      })

      html = render(view)

      assert html =~ "thread reply"
      assert count_occurrences(html, "thread reply") == 1
    end

    test "channel feed excludes thread replies on reload", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "root for top-level feed"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      render_click(view, "open_thread", %{"message-id" => msg.id})

      render_submit(view, "send_inline_thread_message", %{
        "inline_thread_compose" => %{
          "text" => "thread reply should stay in thread",
          "message_id" => msg.id
        }
      })

      {:ok, _reloaded, html} = live(conn, ~p"/chat/general")

      assert html =~ "root for top-level feed"
      refute html =~ "thread reply should stay in thread"
    end
  end

  describe "timestamps" do
    test "channel messages render LocalTime hook metadata", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "timestamp channel message"})
      |> render_submit()

      html = render(view)

      assert html =~ "timestamp channel message"
      assert html =~ "phx-hook=\"LocalTime\""
      assert html =~ "data-local-time="
      assert html =~ "datetime="
    end

    test "thread replies render LocalTime hook metadata", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "timestamp root"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      render_click(view, "open_thread", %{"message-id" => msg.id})

      render_submit(view, "send_inline_thread_message", %{
        "inline_thread_compose" => %{"text" => "timestamp thread reply", "message_id" => msg.id}
      })

      html = render(view)

      assert html =~ "timestamp thread reply"
      assert Regex.match?(~r/id="inline-thread-ts-[^"]+"[\s\S]*phx-hook="LocalTime"/, html)
      assert Regex.match?(~r/id="inline-thread-ts-[^"]+"[\s\S]*data-local-time=/, html)
    end
  end

  # ── Pins ─────────────────────────────────────────────────────────────────────

  describe "pins" do
    test "pinning a message shows it in the pins panel", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "pin me please"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      # Toggle pin
      render_click(view, "pin_toggle", %{"message-id" => msg.id, "space-id" => msg.space_id})

      # Toggle pins panel open
      html = render_click(view, "pin_panel_toggle", %{})

      assert html =~ "Pinned Messages"
      assert html =~ String.slice(msg.id, 0, 8)
    end

    test "pin_panel_toggle shows and hides the panel", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "pin me"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      render_click(view, "pin_toggle", %{"message-id" => msg.id, "space-id" => msg.space_id})

      html_open = render_click(view, "pin_panel_toggle", %{})
      assert html_open =~ "Pinned Messages"

      html_closed = render_click(view, "pin_panel_toggle", %{})
      refute html_closed =~ "Pinned Messages"
    end

    # NOTE: Same LiveViewTest limitation as the edit-message describe block —
    # `render(view)` re-renders the full component tree from current assigns,
    # so it bypasses the morphdom stream-row race where the actual bug
    # manifests in real browsers. These tests verify the *wiring*: that
    # :pinned_message_ids updates and that the reinsert doesn't grow
    # :rendered_message_ids. Manual browser verification at PR time is the
    # actual bug-resistance proof.
    test "pin_toggle reinserts the row without growing :rendered_message_ids",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "pin propagation target"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      # Capture baseline: the message must be in :rendered_message_ids
      assigns_before = :sys.get_state(view.pid).socket.assigns
      rendered_before = Map.get(assigns_before, :rendered_message_ids, MapSet.new())
      assert MapSet.member?(rendered_before, msg.id)
      size_before = MapSet.size(rendered_before)

      # Trigger pin: Chat.pin_message broadcasts {:pin_added, pin} via PubSub.
      # render_click returns BEFORE the handle_info fires; the follow-up
      # render(view) call below flushes the LV's mailbox so the broadcast
      # is processed. Don't delete the render(view) "redundant" call.
      render_click(view, "pin_toggle", %{"message-id" => msg.id, "space-id" => msg.space_id})
      _ = render(view)

      assigns_after = :sys.get_state(view.pid).socket.assigns

      assert MapSet.member?(assigns_after.pinned_message_ids, msg.id),
             ":pinned_message_ids should contain the toggled message after the PubSub roundtrip"

      rendered_after = Map.get(assigns_after, :rendered_message_ids, MapSet.new())

      assert MapSet.size(rendered_after) == size_before,
             "reinsert of an in-DOM row must not grow :rendered_message_ids"
    end

    test "second pin_toggle (unpin) clears the message id from :pinned_message_ids",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "unpin me target"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      # First pin
      render_click(view, "pin_toggle", %{"message-id" => msg.id, "space-id" => msg.space_id})
      _ = render(view)

      pinned_after_first = :sys.get_state(view.pid).socket.assigns.pinned_message_ids
      assert MapSet.member?(pinned_after_first, msg.id)

      size_after_first =
        :sys.get_state(view.pid).socket.assigns
        |> Map.get(:rendered_message_ids, MapSet.new())
        |> MapSet.size()

      # Second toggle = unpin (pin_hooks.ex:70 checks MapSet.member? to decide)
      render_click(view, "pin_toggle", %{"message-id" => msg.id, "space-id" => msg.space_id})
      _ = render(view)

      assigns_after_unpin = :sys.get_state(view.pid).socket.assigns

      refute MapSet.member?(assigns_after_unpin.pinned_message_ids, msg.id),
             ":pinned_message_ids should no longer contain the message after the unpin roundtrip"

      rendered_after_unpin = Map.get(assigns_after_unpin, :rendered_message_ids, MapSet.new())

      assert MapSet.size(rendered_after_unpin) == size_after_first,
             "reinsert of an in-DOM row on unpin must not grow :rendered_message_ids"
    end
  end

  # ── Settings modal ──────────────────────────────────────────────────────────

  describe "settings modal" do
    test "opens settings modal for a channel with name/description/topic fields", %{conn: conn} do
      # The channel must exist BEFORE this user navigates to it. Navigating to
      # an unknown slug bootstraps the channel with the navigator as
      # `created_by` (task 01a0fd62), which would make this user its creator
      # and so allowed to archive it, defeating the premise below.
      {:ok, _} = Chat.create_channel(%{name: "General", slug: "general"})

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      html = render_click(view, "settings_open", %{})

      assert html =~ "Channel Settings"
      assert html =~ ~s(name="name")
      assert html =~ ~s(name="description")
      assert html =~ ~s(name="topic")
      # ADR 0027: Agent Attention Mode removed
      refute html =~ "Agent Attention Mode"
      # Task 019e95ea stage 4: the Danger Zone is permission-gated — this
      # user is neither an Acme admin nor the channel's creator, so no
      # Archive button renders. Visibility cases live in the "channel
      # deletion" describe block below.
      refute html =~ "Archive Channel"
      refute html =~ "Danger Zone"
    end

    test "settings modal for DMs shows minimal fields", %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = get_session(conn, :current_user_id)

      # Create a DM with another user
      other =
        Repo.insert!(%User{
          email: "dm_settings_target@example.com",
          name: "DM Target",
          oidc_sub: "oidc-dm-settings-target"
        })

      {:ok, dm_space} = Chat.find_or_create_dm(user_id, "user", other.id)
      nav_path = "/chat/#{dm_space.id}"

      {:ok, view, _html} = live(conn, nav_path)

      html = render_click(view, "settings_open", %{})

      assert html =~ "Conversation Settings"
      # ADR 0027: Agent Attention Mode removed
      refute html =~ "Agent Attention Mode"
      # DMs should NOT have name/description/topic fields
      refute html =~ ~s(name="name")
      refute html =~ ~s(name="description")
      refute html =~ ~s(name="topic")
    end

    # ADR 0027: "changing attention mode updates the space" test removed.
    # agent_attention field no longer exists on Space.

    test "archiving a channel redirects to /chat when the actor is the creator", %{conn: conn} do
      user = insert_chat_user()
      conn = init_test_session(conn, current_user_id: user.id)

      # Task 019e95ea: archive is authorized in the context layer for Acme
      # admins and the channel creator — make the mounted user the creator.
      {:ok, _space} =
        Chat.create_channel(%{
          name: "to-archive",
          slug: "to-archive",
          description: "",
          created_by: user.id
        })

      {:ok, view, _html} = live(conn, ~p"/chat/to-archive")

      render_click(view, "settings_open", %{})

      view
      |> element("button[phx-click=settings_archive]")
      |> render_click()

      assert_redirect(view, "/chat")

      archived = Chat.get_space_by_slug("to-archive")
      assert archived.archived_at != nil
    end

    test "archiving is refused for a non-creator without admin rights", %{conn: conn} do
      conn = authenticated_conn(conn)

      creator = insert_chat_user(%{email: "creator@example.com", oidc_sub: "oidc-creator"})

      {:ok, _space} =
        Chat.create_channel(%{
          name: "not-yours",
          slug: "not-yours",
          description: "",
          created_by: creator.id
        })

      {:ok, view, _html} = live(conn, ~p"/chat/not-yours")

      render_click(view, "settings_open", %{})

      # Task 019e95ea stage 4: the Archive button no longer renders for a
      # non-creator/non-admin, so push the event straight at the component
      # (simulating a forged client) — the context layer must still refuse.
      refute has_element?(view, "button[phx-click=settings_archive]")

      view
      |> with_target("#chat-settings")
      |> render_click("settings_archive", %{})

      space = Chat.get_space_by_slug("not-yours")
      assert space.archived_at == nil
    end
  end

  describe "inline thread" do
    test "reply button opens inline thread section", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      # Post a message
      view
      |> form("#compose-form", compose: %{text: "Parent message for inline thread"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      # Pre-create a thread so the handler finds it on toggle
      {:ok, _thread} = Chat.create_thread(space.id, %{parent_message_id: msg.id})

      # Click the Reply button (now toggle_inline_thread)
      render_click(view, "toggle_inline_thread", %{"message-id" => msg.id})

      # Assert the inline thread section appears using element checks
      # (more reliable with LiveView streams than full HTML matching)
      assert has_element?(view, "#inline-thread-#{msg.id}")
      assert has_element?(view, "#inline-thread-compose-#{msg.id}")
    end
  end

  describe "edit message handlers (streams attr-propagation contract)" do
    # NOTE: These tests verify handler logic and the authorization gate.
    # They do NOT reproduce the streams-attr-propagation bug that
    # motivated task 019e1e78 — LiveView's render_click + render(view)
    # re-renders the full component tree from current assigns on every
    # call, bypassing the client-side DOM-patch race where that bug
    # actually manifests. The four e2e_behavior cases attached to the
    # task plan are the real regression coverage; these tests cover
    # handler logic and the auth check.

    test "edit_message_clicked on own message renders the inline editor", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "own message ready to edit"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      # Pre-condition: editor is not rendered yet (editing_message_id is nil)
      refute has_element?(view, "#msg-editor-#{msg.id}")

      render_click(view, "edit_message_clicked", %{"message-id" => msg.id})

      assert has_element?(view, "#msg-editor-#{msg.id}")
      assert render(view) =~ "own message ready to edit"
    end

    test "edit_message_clicked on another participant's message is silently denied",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      # Seed a message authored by a DIFFERENT user — the authenticated
      # session is not the author, so authorize_edit must refuse and the
      # editor must NOT render.
      space = Chat.get_space_by_slug("general")

      other_user =
        insert_chat_user(%{email: "other-author@example.com", oidc_sub: "other-sub-edit"})

      add_user_message(space, other_user, "not yours to edit")

      [other_msg | _] = Chat.list_messages(space.id)
      refute has_element?(view, "#msg-editor-#{other_msg.id}")

      render_click(view, "edit_message_clicked", %{"message-id" => other_msg.id})

      refute has_element?(view, "#msg-editor-#{other_msg.id}")
    end

    test "cancel_edit clears editing state and re-renders the bubble", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "cancel-me message"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      # Open the editor first
      render_click(view, "edit_message_clicked", %{"message-id" => msg.id})
      assert has_element?(view, "#msg-editor-#{msg.id}")

      # Cancel — editor disappears, bubble content remains visible
      render_click(view, "cancel_edit", %{})
      refute has_element?(view, "#msg-editor-#{msg.id}")
      assert render(view) =~ "cancel-me message"
    end
  end

  describe "participants_map stream attr-propagation (task 019e273f)" do
    # NOTE: Same LiveViewTest limitation as the edit-message describe block
    # above — `render(view)` always re-renders the full component tree
    # from current assigns, so it bypasses the morphdom stream-row race
    # where the actual bug manifests in real browsers. These tests
    # verify the *wiring*: that :rendered_message_ids is maintained and
    # that participants_map mutations trigger the batched reinsert path.
    # The actual bug-resistance proof is a manual browser verification
    # Robin does at PR time.

    test "mount populates :rendered_message_ids matching the loaded message list",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "seed message one"})
      |> render_submit()

      view
      |> form("#compose-form", compose: %{text: "seed message two"})
      |> render_submit()

      # Re-enter the space (simulates a fresh load) so enter_space hydrates
      # :rendered_message_ids from the loaded message list.
      render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      rendered = Map.get(assigns, :rendered_message_ids, MapSet.new())

      space = Chat.get_space_by_slug("general")
      stream_ids = MapSet.new(Chat.list_messages(space.id), & &1.id)

      assert MapSet.equal?(rendered, stream_ids),
             "rendered_message_ids should mirror the DB messages on mount"
    end

    test "posting a message adds its id to :rendered_message_ids", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      initial_size =
        :sys.get_state(view.pid).socket.assigns
        |> Map.get(:rendered_message_ids, MapSet.new())
        |> MapSet.size()

      view
      |> form("#compose-form", compose: %{text: "new message that should be tracked"})
      |> render_submit()

      after_size =
        :sys.get_state(view.pid).socket.assigns
        |> Map.get(:rendered_message_ids, MapSet.new())
        |> MapSet.size()

      assert after_size == initial_size + 1,
             "stream_insert_with_day_label should add new message id to the MapSet"
    end
  end

  # ── Archived channels (task 019e95ea stage 2) ─────────────────────────────

  defp insert_channel(attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])

    default = %{
      name: Map.get(attrs, :name, "Lifecycle #{n}"),
      slug: "lifecycle-#{n}",
      kind: "channel"
    }

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp insert_archived_channel(attrs \\ %{}) do
    space = insert_channel(attrs)
    {:ok, archived} = Chat.archive_space(space)
    archived
  end

  # Acme-admin fixture (task 019e95ea stage 4) — same OrgMembership-on-the-
  # acme-org pattern as test/platform/chat/space_deletion_test.exs.
  defp insert_acme_admin! do
    n = System.unique_integer([:positive])

    user =
      insert_chat_user(%{
        email: "acme-admin-#{n}@example.com",
        oidc_sub: "oidc-acme-admin-#{n}",
        name: "Acme Admin #{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  # Flash lives in the LiveView's assigns — asserting there sidesteps
  # HTML-entity escaping (e.g. the apostrophe in "doesn't match").
  defp flash(view), do: :sys.get_state(view.pid).socket.assigns.flash

  describe "archived channels" do
    test "archived channel renders the read-only banner and no composer", %{conn: conn} do
      space = insert_archived_channel()
      conn = authenticated_conn(conn)

      {:ok, view, html} = live(conn, ~p"/chat/#{space.slug}")

      assert html =~ "read-only snapshot"
      assert has_element?(view, "#archived-banner")
      refute has_element?(view, "#compose-form")
      refute has_element?(view, ~s(input[name="attachments"]))
    end

    test "active channel still renders the composer (regression)", %{conn: conn} do
      space = insert_channel()
      conn = authenticated_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      refute has_element?(view, "#archived-banner")
      assert has_element?(view, "#compose-form")
    end

    test "creator sees Unarchive; clicking it unarchives and restores the composer", %{
      conn: conn
    } do
      creator =
        insert_chat_user(%{
          email: "archive-creator@example.com",
          oidc_sub: "oidc-archive-creator"
        })

      space = insert_archived_channel(%{created_by: creator.id})
      conn = init_test_session(conn, current_user_id: creator.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      assert has_element?(view, "#archived-banner button", "Unarchive")

      view
      |> element("#archived-banner button", "Unarchive")
      |> render_click()

      refute has_element?(view, "#archived-banner")
      assert has_element?(view, "#compose-form")
      assert is_nil(Chat.get_space(space.id).archived_at)
    end

    test "non-creator/non-admin does not see the Unarchive button", %{conn: conn} do
      creator =
        insert_chat_user(%{
          email: "archive-owner@example.com",
          oidc_sub: "oidc-archive-owner"
        })

      space = insert_archived_channel(%{created_by: creator.id})
      # authenticated_conn inserts a DIFFERENT user with no org membership.
      conn = authenticated_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      assert has_element?(view, "#archived-banner")
      refute has_element?(view, "#archived-banner button", "Unarchive")
    end

    test "sidebar shows the Archived section when an archived channel exists", %{conn: conn} do
      active = insert_channel()
      _archived = insert_archived_channel(%{name: "Old Reports"})
      conn = authenticated_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/chat/#{active.slug}")

      assert has_element?(view, "[data-section-key='archived']")
      # Collapsed by default — the rows only render after the toggle.
      refute render(view) =~ "Old Reports"

      view
      |> element("button[phx-click='toggle_archived_section']")
      |> render_click()

      assert render(view) =~ "Old Reports"
    end

    test "sidebar hides the Archived section when no archived channels exist", %{conn: conn} do
      active = insert_channel()
      conn = authenticated_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/chat/#{active.slug}")

      refute has_element?(view, "[data-section-key='archived']")
    end

    # Receive-side coverage for the cross-session freshness the Recovery hub
    # relies on (task 019f7600, V4). A restore in ANOTHER session broadcasts
    # :sidebar_changed on this user's topic; without a manual reload the sidebar
    # must drop the no-longer-archived row. Pre-019f7600 the handler recomputed
    # only @sidebar_sections off the stale @channels and never re-read
    # @archived_channels, so the Archived group lingered until reload.
    test "sidebar drops the Archived section live on a :sidebar_changed broadcast", %{conn: conn} do
      active = insert_channel()
      archived = insert_archived_channel(%{name: "Old Reports"})
      conn = authenticated_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/chat/#{active.slug}")

      assert has_element?(view, "[data-section-key='archived']")

      # Another session reactivates the channel and broadcasts the invalidation.
      archived
      |> Ecto.Changeset.change(archived_at: nil)
      |> Repo.update!()

      user_id = :sys.get_state(view.pid).socket.assigns.user_id
      Platform.Chat.PubSub.broadcast_sidebar_changed(user_id)

      # No manual reload — the handler re-reads @archived_channels, so the now
      # empty Archived group disappears.
      refute has_element?(view, "[data-section-key='archived']")
    end
  end

  # ── Channel deletion (task 019e95ea stage 4) ───────────────────────────────
  #
  # NOTE on navigation: these tests mount via `/chat/#{space.id}` (UUID),
  # not the slug. Acme-admin fixtures carry an org membership, so LiveAuth
  # resolves an active org and `get_space_by_slug/2` becomes org-scoped —
  # the org-less fixture channels would miss and `bootstrap_space/2` would
  # silently create a fresh duplicate. The UUID path (`Chat.get_space/1`)
  # is org-agnostic.

  describe "channel deletion (task 019e95ea stage 4)" do
    test "admin sees both Archive and Delete sections in settings", %{conn: conn} do
      admin = insert_acme_admin!()
      space = insert_channel()
      conn = init_test_session(conn, current_user_id: admin.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.id}")
      html = render_click(view, "settings_open", %{})

      assert html =~ "Danger Zone"
      assert html =~ "Archive Channel"
      assert html =~ "Delete Channel"
      assert has_element?(view, "#delete-channel-form")
    end

    test "creator without admin rights sees Archive but not Delete", %{conn: conn} do
      creator =
        insert_chat_user(%{
          email: "delete-creator@example.com",
          oidc_sub: "oidc-delete-creator"
        })

      space = insert_channel(%{created_by: creator.id})
      conn = init_test_session(conn, current_user_id: creator.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.id}")
      html = render_click(view, "settings_open", %{})

      assert html =~ "Danger Zone"
      assert html =~ "Archive Channel"
      refute html =~ "Delete Channel"
      refute has_element?(view, "#delete-channel-form")
    end

    test "plain member sees no Danger Zone at all", %{conn: conn} do
      space = insert_channel()
      conn = authenticated_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.id}")
      html = render_click(view, "settings_open", %{})

      refute html =~ "Danger Zone"
      refute html =~ "Archive Channel"
      refute html =~ "Delete Channel"
    end

    test "delete with a mismatched name flashes an error and does not flag the space",
         %{conn: conn} do
      admin = insert_acme_admin!()
      space = insert_channel()
      conn = init_test_session(conn, current_user_id: admin.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.id}")
      render_click(view, "settings_open", %{})

      view
      |> form("#delete-channel-form", %{"delete_confirm_name" => "totally-wrong"})
      |> render_submit()

      assert flash(view)["error"] =~ "Channel name doesn't match."

      reloaded = Chat.get_space(space.id)
      assert reloaded.deletion_scheduled_at == nil
      assert reloaded.archived_at == nil
    end

    test "delete with the exact name as admin flags the space and navigates to /chat",
         %{conn: conn} do
      admin = insert_acme_admin!()
      space = insert_channel()
      conn = init_test_session(conn, current_user_id: admin.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.id}")
      render_click(view, "settings_open", %{})

      view
      |> form("#delete-channel-form", %{"delete_confirm_name" => space.name})
      |> render_submit()

      assert_redirect(view, "/chat")

      reloaded = Chat.get_space(space.id)
      assert %DateTime{} = reloaded.deletion_scheduled_at
      assert %DateTime{} = reloaded.archived_at
    end

    test "delete injected by a non-admin is refused server-side", %{conn: conn} do
      creator =
        insert_chat_user(%{
          email: "delete-forger@example.com",
          oidc_sub: "oidc-delete-forger"
        })

      space = insert_channel(%{created_by: creator.id})
      conn = init_test_session(conn, current_user_id: creator.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.id}")
      render_click(view, "settings_open", %{})

      # The Delete form is not rendered for non-admins — push the event
      # straight at the component, simulating a forged client. The context
      # layer (Chat.schedule_space_deletion/2) must refuse regardless.
      view
      |> with_target("#chat-settings")
      |> render_click("settings_delete", %{"delete_confirm_name" => space.name})

      assert flash(view)["error"] =~ "permission"

      reloaded = Chat.get_space(space.id)
      assert reloaded.deletion_scheduled_at == nil
      assert reloaded.archived_at == nil
    end

    test "deletion-scheduled channel shows the deletion banner with purge date; admin sees Cancel",
         %{conn: conn} do
      admin = insert_acme_admin!()
      space = insert_channel()
      {:ok, scheduled} = Chat.schedule_space_deletion(admin, space)
      conn = init_test_session(conn, current_user_id: admin.id)

      {:ok, view, html} = live(conn, ~p"/chat/#{space.id}")

      expected_date =
        scheduled.deletion_scheduled_at
        |> DateTime.add(Chat.space_retention_days(), :day)
        |> Calendar.strftime("%B %-d, %Y")

      assert has_element?(view, "#archived-banner")
      assert html =~ "scheduled for permanent deletion on #{expected_date}"
      assert has_element?(view, "#archived-banner button", "Cancel deletion")
      # Unarchive is hidden while a deletion is pending — cancel first.
      refute has_element?(view, "#archived-banner button", "Unarchive")
    end

    test "non-admin sees the deletion banner without the Cancel button", %{conn: conn} do
      admin = insert_acme_admin!()
      space = insert_channel()
      {:ok, _scheduled} = Chat.schedule_space_deletion(admin, space)
      conn = authenticated_conn(conn)

      {:ok, view, html} = live(conn, ~p"/chat/#{space.id}")

      assert has_element?(view, "#archived-banner")
      assert html =~ "scheduled for permanent deletion"
      refute has_element?(view, "#archived-banner button", "Cancel deletion")
      refute has_element?(view, "#archived-banner button", "Unarchive")
    end

    test "cancelling the deletion clears the flag and the archive banner returns",
         %{conn: conn} do
      admin = insert_acme_admin!()
      space = insert_channel()
      {:ok, _scheduled} = Chat.schedule_space_deletion(admin, space)
      conn = init_test_session(conn, current_user_id: admin.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.id}")

      view
      |> element("#archived-banner button", "Cancel deletion")
      |> render_click()

      reloaded = Chat.get_space(space.id)
      assert reloaded.deletion_scheduled_at == nil
      assert %DateTime{} = reloaded.archived_at

      assert flash(view)["info"] =~ "Deletion cancelled"

      # Banner reverts to the archive copy — deletion text gone, Unarchive
      # back (the admin qualifies for unarchive too).
      html = render(view)
      refute html =~ "scheduled for permanent deletion"
      assert html =~ "read-only snapshot"
      assert has_element?(view, "#archived-banner button", "Unarchive")
    end
  end

  # ── Pin-to-Chat stage 4 (task 019f62a1): Pinned rail section ───────────
  #
  # Rail section only surfaces when the current user has pinned at least
  # one task's execution space. `list_pinned_task_spaces_for/1` joins
  # `task_chat_pins → chat_spaces` on `metadata->>'task_id'`, so both
  # writes have to land before the section renders. Load-bearing:
  # participant_id is EMAIL for user pins, not user UUID.
  describe "Pinned task-exec rail section" do
    alias Platform.Chat.PubSub, as: ChatPubSub
    alias Platform.Tasks
    alias Platform.Tasks.ChatPins

    defp seed_pin_for(user, opts) do
      title = Keyword.get(opts, :title, "Pinned Task")

      {:ok, project} =
        Tasks.create_project(%{name: "Pin Project #{System.unique_integer([:positive])}"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: title,
          status: "backlog",
          sponsor_user_id: user.id
        })

      {:ok, %{space: space}} =
        ChatPins.pin(task.id, %{kind: "user", id: user.email}, user.email)

      %{task: task, space: space}
    end

    test "section absent when user has no pins", %{conn: conn} do
      conn =
        authenticated_conn(conn, %{
          email: "no-pins-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-no-pins-#{System.unique_integer([:positive])}"
        })

      {:ok, view, _html} = live(conn, ~p"/chat")

      refute has_element?(view, "[aria-label='Pinned']")
    end

    test "section renders one row per pinned task-exec space", %{conn: conn} do
      user =
        insert_chat_user(%{
          email: "rail-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-rail-#{System.unique_integer([:positive])}"
        })

      %{space: space1} = seed_pin_for(user, title: "Alpha Pinned")
      %{space: space2} = seed_pin_for(user, title: "Beta Pinned")

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, html} = live(conn, ~p"/chat")

      assert has_element?(view, "[aria-label='Pinned']")

      assert has_element?(
               view,
               "[data-role='pinned-task-rail-row'][data-space-id='#{space1.id}']"
             )

      assert has_element?(
               view,
               "[data-role='pinned-task-rail-row'][data-space-id='#{space2.id}']"
             )

      # Per-row task glyph rendered (Saru:
      # hero-clipboard-document-list-mini marks a task-scoped conversation).
      #
      # The `hero-map-pin-mini` header icon this used to assert went with the
      # separate "Pinned Tasks" section (task 019feec6-73d9). One block holds
      # pinned channels, DMs and task conversations now, and it carries no
      # header icon at all — see "the PINNED label carries no icon, no fill
      # and no collapse control" in chat_live_pinned_block_test.exs.
      assert html =~ "hero-clipboard-document-list-mini"
    end

    # Stage-4 review feedback (Alex): the rail row label was the cryptic
    # synthesised `task-exec-<8-char-id>` space slug, so two pinned tasks
    # were indistinguishable. Row must render the real task title now.
    test "rail row renders the task title, not the cryptic exec-space slug",
         %{conn: conn} do
      user =
        insert_chat_user(%{
          email: "title-rail-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-title-rail-#{System.unique_integer([:positive])}"
        })

      %{space: space} = seed_pin_for(user, title: "My cool task")

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, _html} = live(conn, ~p"/chat")

      row_html =
        view
        |> element("[data-role='pinned-task-rail-row'][data-space-id='#{space.id}']")
        |> render()

      assert row_html =~ "My cool task"

      # The `href` on the row still points at `/chat/task-exec-<id>` (URL
      # slugs are unchanged), so scope the refute to the visible label
      # span — that MUST NOT read as the cryptic exec-space slug anymore.
      label_html =
        view
        |> element(
          "[data-role='pinned-task-rail-row'][data-space-id='#{space.id}'] span.truncate"
        )
        |> render()

      refute label_html =~ "task-exec-"
    end

    test "task_pin_added broadcast for THIS user surfaces a fresh row", %{conn: conn} do
      user =
        insert_chat_user(%{
          email: "live-pin-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-live-pin-#{System.unique_integer([:positive])}"
        })

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, _html} = live(conn, ~p"/chat")
      refute has_element?(view, "[aria-label='Pinned']")

      # Pin AFTER mount → the handle_info clause + refresh should fold
      # the new row in without a page refresh.
      %{space: space} = seed_pin_for(user, title: "Live Add")

      # The pin/3 call already broadcasts on the space-lifecycle topic
      # ChatLive subscribes to. Wait for the assign refresh to propagate.
      Process.sleep(50)

      assert has_element?(
               view,
               "[data-role='pinned-task-rail-row'][data-space-id='#{space.id}']"
             )
    end

    test "task_pin_removed broadcast drops the row live", %{conn: conn} do
      user =
        insert_chat_user(%{
          email: "live-unpin-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-live-unpin-#{System.unique_integer([:positive])}"
        })

      %{task: task, space: space} = seed_pin_for(user, title: "Will Unpin")

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(
               view,
               "[data-role='pinned-task-rail-row'][data-space-id='#{space.id}']"
             )

      {:ok, :removed} = ChatPins.unpin(task.id, %{kind: "user", id: user.email}, user.email)

      Process.sleep(50)

      refute has_element?(
               view,
               "[data-role='pinned-task-rail-row'][data-space-id='#{space.id}']"
             )
    end

    test "other users' pin broadcasts do NOT surface in this session", %{conn: conn} do
      user_a =
        insert_chat_user(%{
          email: "user-a-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-user-a-#{System.unique_integer([:positive])}"
        })

      user_b =
        insert_chat_user(%{
          email: "user-b-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-user-b-#{System.unique_integer([:positive])}"
        })

      conn = init_test_session(conn, current_user_id: user_a.id)

      {:ok, view, _html} = live(conn, ~p"/chat")

      # user_b pins a task — the broadcast fans out to every subscriber
      # of the spaces topic (including user_a's session) but the handler
      # filter must drop it: participant_id != user_a.email.
      %{space: b_space} = seed_pin_for(user_b, title: "Not Mine")

      Process.sleep(50)

      refute has_element?(
               view,
               "[data-role='pinned-task-rail-row'][data-space-id='#{b_space.id}']"
             )

      # Sanity: no Pinned tasks section for user_a either (they still
      # have zero pins of their own).
      refute has_element?(view, "[aria-label='Pinned']")

      # Sanity: a stray broadcast that isn't wearing the "user" kind at
      # all (e.g. an agent pin) also doesn't crash the handler or
      # surface a row for user_a.
      _ = ChatPubSub.broadcast_space_event({:task_pin_added, %{participant_kind: "agent"}})
      Process.sleep(50)
      refute has_element?(view, "[aria-label='Pinned']")
    end

    # ── Stage 4 fixup #2 (Alex review): every viewer that sees a row can
    # unpin themselves without navigating to the task detail panel. Unpin is
    # participant-scoped (self only), so a sponsor's unpin does NOT drop other
    # participants' rows.
    #
    # The control moved on 2026-08-13 (task 019ff8ba). It was a `hero-x-mark`
    # at the row's tail; it is now the single item in the menu the row's
    # three-dot trigger opens, so every rail row offers one interaction and
    # not two. Same event, same `task-id` payload, same `data-role` — only the
    # place changed, and these tests open the menu to reach it.
    test "a rail row's menu carries an unpin item that removes the pin", %{conn: conn} do
      user =
        insert_chat_user(%{
          email: "unpin-btn-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-unpin-btn-#{System.unique_integer([:positive])}"
        })

      %{task: task, space: space} = seed_pin_for(user, title: "Will Self-Unpin")

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, _html} = live(conn, ~p"/chat")

      # The row and its trigger are both present at initial render; the unpin
      # itself is one menu-open away.
      assert has_element?(
               view,
               "[data-role='pinned-task-rail-row'][data-space-id='#{space.id}']"
             )

      assert has_element?(
               view,
               "button[data-role='row-actions-trigger'][data-space-id='#{space.id}']"
             )

      view
      |> element("button[data-role='row-actions-trigger'][data-space-id='#{space.id}']")
      |> render_click()

      assert has_element?(
               view,
               "button[data-role='pinned-task-rail-unpin'][data-space-id='#{space.id}']"
             )

      # Click the unpin item — the phx-click event fires with the task
      # id as `task-id`, the handler calls `ChatPins.unpin/3`, and the
      # `:task_pin_removed` broadcast folds the row out of the rail
      # without a navigation.
      view
      |> element("button[data-role='pinned-task-rail-unpin'][data-space-id='#{space.id}']")
      |> render_click()

      # DB is authoritative: no pin row remains for this user + task.
      refute Platform.Tasks.ChatPins.pinned?(task.id, %{kind: "user", id: user.email})

      Process.sleep(50)

      refute has_element?(
               view,
               "[data-role='pinned-task-rail-row'][data-space-id='#{space.id}']"
             )
    end

    # Participant-scope guarantee — the mention-propagation path in
    # stage 3 seeds a pin row for every @-mentioned participant, and
    # each of them sees the same task-exec space in their own rail.
    # When ONE participant clicks unpin, only THEIR row goes; the
    # other participants (including the sponsor) still see the row.
    test "unpin from one participant does NOT drop other participants' rows",
         %{conn: conn} do
      sponsor =
        insert_chat_user(%{
          email: "sponsor-unpin-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-sponsor-unpin-#{System.unique_integer([:positive])}"
        })

      participant =
        insert_chat_user(%{
          email: "participant-unpin-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-participant-unpin-#{System.unique_integer([:positive])}"
        })

      # Sponsor pins the task (materialises the exec space + sponsor's
      # own pin row); mentioned participant's pin is seeded via a direct
      # `ChatPins.pin/3` (stage 3's mention-propagation collapses to the
      # same call site).
      %{task: task, space: space} = seed_pin_for(sponsor, title: "Shared Pin")

      {:ok, _} =
        ChatPins.pin(task.id, %{kind: "user", id: participant.email}, sponsor.email)

      # The participant's session sees the row and clicks unpin.
      conn = init_test_session(conn, current_user_id: participant.id)
      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(
               view,
               "[data-role='pinned-task-rail-row'][data-space-id='#{space.id}']"
             )

      view
      |> element("button[data-role='row-actions-trigger'][data-space-id='#{space.id}']")
      |> render_click()

      view
      |> element("button[data-role='pinned-task-rail-unpin'][data-space-id='#{space.id}']")
      |> render_click()

      Process.sleep(50)

      refute has_element?(
               view,
               "[data-role='pinned-task-rail-row'][data-space-id='#{space.id}']"
             )

      # Sponsor's pin row survives — participant-scoped unpin is the whole
      # point. The sponsor still sees the space in their own rail.
      assert Platform.Tasks.ChatPins.pinned?(task.id, %{kind: "user", id: sponsor.email})

      refute Platform.Tasks.ChatPins.pinned?(task.id, %{
               kind: "user",
               id: participant.email
             })
    end
  end

  # ── Stage 3 (task 019f62a1 v4): safety-net slug resolution for
  # system-managed prefixes. `handle_params/3` now falls through the
  # org-scoped lookup + UUID branch + `system_prefix_fallback/1` before
  # bootstrap. The fallback rescues exec/meeting/dm/group slug rows that
  # sit outside the viewer's org (pre-backfill `org_id = NULL`, or an
  # intentional cross-org access like an @-mentioned bystander opening
  # the sponsor's exec space). Non-reserved slugs are UNTOUCHED — the
  # ADR-0042 per-org channel-slug scoping (`#general` in Acme vs Globex)
  # must not be weakened.
  describe "system_prefix_fallback slug resolution" do
    defp insert_org!(slug \\ nil) do
      n = System.unique_integer([:positive])
      acme = Tenancy.get_org_by_slug!("acme")

      Repo.insert!(%Platform.Tenancy.Org{
        name: "Fallback Org #{n}",
        slug: slug || "fallback-org-#{n}",
        parent_org_id: acme.id
      })
    end

    defp put_membership!(user, org) do
      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
      |> Repo.insert!()

      user
    end

    test "resolves exec-space slug when org_id NULL and viewer has org membership",
         %{conn: conn} do
      # Legacy exec-space row: `find_or_create/1` created it before the
      # stage-2 org_id stamp shipped, so `org_id = NULL`. The viewer sits
      # inside an org (e.g. Acme), so the org-scoped `get_space_by_slug/2`
      # branch filters this row out. Without the safety net, handle_params
      # push_navigates back to `/chat`.
      #
      # A ROOT-org viewer: a sub-org-only member is fenced to their orgs
      # (ticket 01a14721), and a NULL-org execution space with no participant
      # row is outside that fence, so the safety net under test is only
      # reachable for an unfenced viewer.
      org = Tenancy.get_org_by_slug!("acme")

      user =
        insert_chat_user(%{
          email: "null-org-exec-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-null-org-exec-#{System.unique_integer([:positive])}"
        })
        |> put_membership!(org)

      short_id =
        Ecto.UUID.generate() |> String.replace("-", "") |> String.slice(0, 12)

      slug = "task-exec-#{short_id}"

      {:ok, exec} =
        Chat.create_space(%{
          name: slug,
          slug: slug,
          kind: "execution",
          org_id: nil,
          metadata: %{"task_id" => Ecto.UUID.generate()}
        })

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/chat/#{slug}")

      active_space = :sys.get_state(view.pid).socket.assigns.active_space
      assert active_space.id == exec.id
    end

    test "does NOT resolve non-reserved channel slug across orgs (ADR-0042 regression fence)",
         %{conn: conn} do
      # Two orgs, each with its own `#general` channel. Viewer in org-A
      # navigates to `/chat/general` — must land on org-A's row, NEVER
      # org-B's. `general` is not a reserved prefix, so the safety net
      # MUST NOT fire; the org-scoped lookup wins.
      org_a = insert_org!()
      org_b = insert_org!()

      {:ok, general_a} =
        Chat.create_space(%{
          name: "General",
          slug: "general",
          kind: "channel",
          org_id: org_a.id
        })

      {:ok, _general_b} =
        Chat.create_space(%{
          name: "General",
          slug: "general",
          kind: "channel",
          org_id: org_b.id
        })

      user =
        insert_chat_user(%{
          email: "cross-org-chan-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-cross-org-chan-#{System.unique_integer([:positive])}"
        })
        |> put_membership!(org_a)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      active_space = :sys.get_state(view.pid).socket.assigns.active_space
      assert active_space.id == general_a.id
    end

    test "resolves cross-org exec-space slug for @-mentioned bystander",
         %{conn: conn} do
      # Sponsor in org-A pins a task — the exec space carries org_id: A.
      # Bystander sits in org-B (different tenant, but got @-mentioned).
      # Bystander's org-scoped lookup misses (org_id: B vs exec.org_id: A);
      # the safety net kicks in because the slug starts with `task-exec-`.
      #
      # The bystander is a ROOT-org member: since ticket 01a14721 a
      # sub-org-only bystander is fenced to their orgs and refused a foreign
      # org's execution space they hold no participant row in (pinned or
      # not; `Platform.Access.OrgFenceTest`). A root bystander's org-scoped
      # lookup still misses, so the safety net is what resolves it.
      sponsor_org = insert_org!()
      bystander_org = Tenancy.get_org_by_slug!("acme")

      short_id =
        Ecto.UUID.generate() |> String.replace("-", "") |> String.slice(0, 12)

      slug = "task-exec-#{short_id}"

      {:ok, exec} =
        Chat.create_space(%{
          name: slug,
          slug: slug,
          kind: "execution",
          org_id: sponsor_org.id,
          metadata: %{"task_id" => Ecto.UUID.generate()}
        })

      bystander =
        insert_chat_user(%{
          email: "bystander-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-bystander-#{System.unique_integer([:positive])}"
        })
        |> put_membership!(bystander_org)

      conn = init_test_session(conn, current_user_id: bystander.id)
      {:ok, view, _html} = live(conn, ~p"/chat/#{slug}")

      active_space = :sys.get_state(view.pid).socket.assigns.active_space
      assert active_space.id == exec.id
    end
  end

  # ── Stage 4 (task 019f62a1 v4): full sponsor-and-bystander OPEN path.
  # The v4 stages 2+3 fix — org_id stamp on `find_or_create/1` plus the
  # `system_prefix_fallback/1` safety net — should let every user with a
  # pin arrive at the exec space by clicking the rail row (or navigating
  # to the slug directly). Before the fix, the exec-space slug resolved
  # to nil for org-membered viewers, `handle_params/3` push_navigated to
  # `/chat`, and the chat index rebounded to the first channel — the
  # "loading bar but doesn't take me to the space" symptom Alex filed.
  #
  # These tests are disjoint from the pin-write coverage in PR #548's
  # "Pinned task-exec rail section" describe: they lock the OPEN flow
  # end-to-end for sponsor + mention-propagated bystander, plus two
  # regression fences that keep the safety-net narrow (reserved prefixes
  # only, per-org channel scoping preserved).
  describe "pinned task exec space navigation" do
    alias Platform.Tasks
    alias Platform.Tasks.ChatPins

    test "sponsor opens pinned backlog exec space via rail row navigation",
         %{conn: conn} do
      # Sponsor is an Acme member. `Tasks.create_project` defaults project
      # org_id to Acme (see default_org_id/1), and stage 2's `find_or_create`
      # now stamps the exec space with `task → project.org_id`. So the
      # org-scoped `get_space_by_slug/2` branch resolves directly — no
      # safety-net fallback needed for the happy path.
      acme = Tenancy.get_org_by_slug!("acme")

      sponsor =
        insert_chat_user(%{
          email: "pin-open-sponsor-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-pin-open-sponsor-#{System.unique_integer([:positive])}"
        })
        |> put_membership!(acme)

      %{task: task, space: exec} = seed_pin_for(sponsor, title: "Opens via rail row")

      # Stage-2 postcondition: the exec space carries an org_id (Acme).
      # If this assertion regresses, the whole open path collapses back
      # to the bug this task fixes.
      assert exec.org_id == acme.id

      conn = init_test_session(conn, current_user_id: sponsor.id)

      # Direct navigation to the rail-row destination — same URL shape the
      # `.link navigate={~p"/chat/#{space_nav_target(space)}"}` in the rail
      # emits. If handle_params bounced us back to `/chat`, `live/2` would
      # return `{:error, {:live_redirect, %{to: "/chat"}}}` and the OK match
      # below would fail loudly.
      {:ok, view, html} = live(conn, ~p"/chat/#{exec.slug}")

      active_space = :sys.get_state(view.pid).socket.assigns.active_space
      assert active_space.id == exec.id
      # display_name_for_space renders the task title in the header, so a
      # sponsor viewer sees the human-readable task name (Alex's stage-4
      # fixup on the pinned-rail label).
      assert html =~ task.title
    end

    test "mentioned bystander opens pinned exec space via rail row",
         %{conn: conn} do
      # Sponsor pins a task (stage 2 materialises the exec space with
      # sponsor's Acme org_id + a pin row for the sponsor). Stage 3 of
      # PR #548 propagates a pin to every @-mentioned participant via
      # `Platform.Chat.reinvite_and_pin_mentioned/1` — that's a private
      # helper triggered from `post_message`, but both code paths write
      # via `ChatPins.pin/3`, so we call it directly to seed the bystander
      # pin without touching the message pipeline.
      acme = Tenancy.get_org_by_slug!("acme")

      sponsor =
        insert_chat_user(%{
          email: "mention-sponsor-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-mention-sponsor-#{System.unique_integer([:positive])}"
        })
        |> put_membership!(acme)

      bystander =
        insert_chat_user(%{
          email: "mention-bystander-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-mention-bystander-#{System.unique_integer([:positive])}"
        })
        |> put_membership!(acme)

      %{task: task, space: exec} = seed_pin_for(sponsor, title: "Bystander opens too")

      {:ok, _} =
        ChatPins.pin(task.id, %{kind: "user", id: bystander.email}, sponsor.email)

      conn = init_test_session(conn, current_user_id: bystander.id)
      {:ok, view, _html} = live(conn, ~p"/chat/#{exec.slug}")

      active_space = :sys.get_state(view.pid).socket.assigns.active_space
      assert active_space.id == exec.id

      # The bystander's own rail carries the pinned row — mention
      # propagation seeded their pin, and stage 3's safety net (belt for
      # the fallback case) plus stage 2's org_id stamp (suspenders for
      # the primary case) together mean the row's navigate target
      # resolves cleanly for them.
      assert has_element?(
               view,
               "[data-role='pinned-task-rail-row'][data-space-id='#{exec.id}']"
             )
    end

    test "cross-org channel slug scoping preserved (ADR-0042 regression fence)",
         %{conn: conn} do
      # Two orgs (acme-flavoured + globex-flavoured sub-orgs), each with its
      # own `#general` channel. Viewer in the acme-flavoured org must
      # land on THEIR `#general`, not the globex-flavoured one. `general`
      # is not a reserved system-managed prefix (`task-exec-`, `meeting-`,
      # `dm-`, `group-`), so the stage-3 safety-net MUST NOT fire — the
      # org-scoped lookup wins, and ADR-0042 per-org channel-slug scoping
      # stays intact.
      acme_side = insert_org!("acme-nav-#{System.unique_integer([:positive])}")
      globex_side = insert_org!("globex-nav-#{System.unique_integer([:positive])}")

      {:ok, acme_general} =
        Chat.create_space(%{
          name: "General",
          slug: "general",
          kind: "channel",
          org_id: acme_side.id
        })

      {:ok, globex_general} =
        Chat.create_space(%{
          name: "General",
          slug: "general",
          kind: "channel",
          org_id: globex_side.id
        })

      user =
        insert_chat_user(%{
          email: "cross-org-nav-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-cross-org-nav-#{System.unique_integer([:positive])}"
        })
        |> put_membership!(acme_side)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      active_space = :sys.get_state(view.pid).socket.assigns.active_space
      assert active_space.id == acme_general.id
      refute active_space.id == globex_general.id
      assert active_space.org_id == acme_side.id
    end

    test "exec space with NULL org_id still resolvable via safety-net fallback",
         %{conn: conn} do
      # Simulates a legacy/pre-backfill exec-space row (or a race-created
      # duplicate where the backfill couldn't derive an org_id because the
      # task or project was also orphaned). Viewer sits inside Acme, so
      # `active_org_id = acme.id`; the org-scoped `get_space_by_slug/2`
      # misses (exec.org_id IS NULL). The `system_prefix_fallback/1`
      # clause catches it because the slug starts with `task-exec-`.
      acme = Tenancy.get_org_by_slug!("acme")

      user =
        insert_chat_user(%{
          email: "null-org-nav-#{System.unique_integer([:positive])}@example.com",
          oidc_sub: "oidc-null-org-nav-#{System.unique_integer([:positive])}"
        })
        |> put_membership!(acme)

      short_id =
        Ecto.UUID.generate() |> String.replace("-", "") |> String.slice(0, 12)

      slug = "task-exec-#{short_id}"

      {:ok, exec} =
        Chat.create_space(%{
          name: slug,
          slug: slug,
          kind: "execution",
          org_id: nil,
          metadata: %{"task_id" => Ecto.UUID.generate()}
        })

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/chat/#{slug}")

      active_space = :sys.get_state(view.pid).socket.assigns.active_space
      assert active_space.id == exec.id
      assert is_nil(active_space.org_id)
    end
  end

  # ── Quick-react row: one set, three surfaces ─────────────────────────────────

  # The emoji of one quick-react row, in DOM order, read off `phx-value-emoji`.
  #
  # The ATTRIBUTE and not the button's text, because the attribute is what a
  # click actually posts to the `react` event: a row that displayed the right
  # glyph and sent a different string would fail here and pass a text check.
  # It also drops the picker "+" for free — that control carries no
  # `phx-value-emoji`, which is the distinction Sam's ruling turns on.
  defp quick_row_emoji(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> Enum.map(&(&1 |> Floki.attribute("phx-value-emoji") |> List.first()))
  end

  defp hover_row_selector(msg_id) do
    ~s(.message-action-row button[phx-value-message-id="#{msg_id}"][phx-value-emoji])
  end

  @longpress_pill_selector ".longpress-pill button[phx-value-emoji]"
  @actions_sheet_selector "#message-actions-quick-reactions button[phx-value-emoji]"

  describe "quick-react row is one set across every surface" do
    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "one row, three surfaces"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      %{view: view, msg: msg}
    end

    test "the desktop hover row renders the pinned set, in order", %{view: view, msg: msg} do
      html = render(view)

      assert quick_row_emoji(html, hover_row_selector(msg.id)) == @quick_react_row
    end

    test "the mobile double-tap pill renders the pinned set, in order",
         %{view: view, msg: msg} do
      html = render_hook(view, "open_longpress_menu", %{"message_id" => msg.id})

      assert quick_row_emoji(html, @longpress_pill_selector) == @quick_react_row
    end

    test "the mobile message-actions sheet renders the pinned set, in order",
         %{view: view, msg: msg} do
      html = render_click(view, "open_message_actions", %{"id" => msg.id})

      assert quick_row_emoji(html, @actions_sheet_selector) == @quick_react_row
    end

    test "all three surfaces agree with each other on one render pass",
         %{view: view, msg: msg} do
      # The three assertions above each compare a surface to the pin. This
      # compares the surfaces to EACH OTHER, which is the defect being closed:
      # every one of them looked right in isolation while the pointer row
      # offered four emoji and the touch pill offered six, on the same message,
      # in the same account, differing only by the device it was opened on.
      hover = quick_row_emoji(render(view), hover_row_selector(msg.id))

      pill =
        quick_row_emoji(
          render_hook(view, "open_longpress_menu", %{"message_id" => msg.id}),
          @longpress_pill_selector
        )

      sheet =
        quick_row_emoji(
          render_click(view, "open_message_actions", %{"id" => msg.id}),
          @actions_sheet_selector
        )

      assert hover == pill
      assert pill == sheet
      assert length(hover) == 6
    end

    test "the picker control is still a control, not a seventh emoji",
         %{view: view, msg: msg} do
      # The counterpart to the equality assertions: they would all still pass
      # if somebody added the "+" to the set and deleted the real control.
      # Counted separately on each surface, the way the sheet's own strip test
      # counts them, because "the + is a control, not an emoji" is a rule about
      # kinds and not about a total.
      pill_html = render_hook(view, "open_longpress_menu", %{"message_id" => msg.id})
      pill_buttons = pill_html |> Floki.parse_document!() |> Floki.find(".longpress-pill button")

      assert length(pill_buttons) == 7
      assert [_] = Floki.find(pill_buttons, ".longpress-pill-more")

      sheet_html = render_click(view, "open_message_actions", %{"id" => msg.id})

      sheet_buttons =
        sheet_html
        |> Floki.parse_document!()
        |> Floki.find("#message-actions-quick-reactions button")

      assert length(sheet_buttons) == 7
      assert [_] = Floki.find(sheet_buttons, "#message-actions-more-reactions")

      refute pill_html =~ ~s(phx-value-emoji="+")
      refute sheet_html =~ ~s(phx-value-emoji="+")
    end
  end

  describe "quick-react row does not vary by who is looking" do
    test "the row is byte-identical for the participant who reacted and for a peer" do
      # THE REGRESSION THIS STAGE PROTECTS AGAINST. The static system-wide set
      # was chosen over the personalisation options precisely so that two people
      # looking at one message see the same emoji in the same order. A "recents"
      # or "most used" implementation would pass a test that merely asserted the
      # row is non-empty, and would fail this one the moment Alice reacted:
      # her row would reorder and Bob's would not.
      #
      # Two REAL LiveViews under two different sessions, not one view re-rendered
      # — a per-user set would be read from the session, and re-rendering one
      # session cannot observe that.
      alice =
        insert_chat_user(%{email: "row-alice@example.com", oidc_sub: "row-alice", name: "Alice"})

      bob = insert_chat_user(%{email: "row-bob@example.com", oidc_sub: "row-bob", name: "Bob"})

      conn_a = init_test_session(Phoenix.ConnTest.build_conn(), current_user_id: alice.id)
      conn_b = init_test_session(Phoenix.ConnTest.build_conn(), current_user_id: bob.id)

      {:ok, view_a, _} = live(conn_a, ~p"/chat/general")
      {:ok, view_b, _} = live(conn_b, ~p"/chat/general")

      view_a
      |> form("#compose-form", compose: %{text: "same row for everyone"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      # Alice reacts. On a personalised row this is the event that would move
      # her set — a "recents" list puts the emoji she just used at the front.
      render_click(view_a, "react", %{"message-id" => msg.id, "emoji" => "\u{1F64F}"})

      # Sanity: the reaction really landed, so the render below is the
      # after-state and not an unchanged page. Without this the equality
      # assertions could pass because nothing happened at all.
      assert [%{emoji: "\u{1F64F}"}] = Chat.list_reactions(msg.id)
      assert render(view_b) =~ "same row for everyone"

      selector = hover_row_selector(msg.id)
      alice_row = quick_row_emoji(render(view_a), selector)
      bob_row = quick_row_emoji(render(view_b), selector)

      assert alice_row == bob_row
      assert alice_row == @quick_react_row

      # And on touch, where the reacting gesture and the row both live in the
      # same overlay.
      alice_pill =
        quick_row_emoji(
          render_hook(view_a, "open_longpress_menu", %{"message_id" => msg.id}),
          @longpress_pill_selector
        )

      bob_pill =
        quick_row_emoji(
          render_hook(view_b, "open_longpress_menu", %{"message_id" => msg.id}),
          @longpress_pill_selector
        )

      assert alice_pill == bob_pill
      assert alice_pill == @quick_react_row

      alice_sheet =
        quick_row_emoji(
          render_click(view_a, "open_message_actions", %{"id" => msg.id}),
          @actions_sheet_selector
        )

      bob_sheet =
        quick_row_emoji(
          render_click(view_b, "open_message_actions", %{"id" => msg.id}),
          @actions_sheet_selector
        )

      assert alice_sheet == bob_sheet
      assert alice_sheet == @quick_react_row
    end
  end
end
