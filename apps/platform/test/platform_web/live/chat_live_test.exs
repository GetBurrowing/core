defmodule PlatformWeb.ChatLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentServer}
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Repo

  setup do
    previous_root = Application.get_env(:platform, :chat_attachments_root)

    upload_root =
      Path.join(
        System.tmp_dir!(),
        "platform_live_test_chat_uploads_#{System.unique_integer([:positive])}"
      )

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

  defp insert_chat_agent(attrs \\ %{}) do
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

    # Shell layout and channel sidebar should be present
    assert html =~ "Channels"
    assert html =~ "Startup Suite"
  end

  test "shell sidebar is rendered on /chat", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/chat")

    # Shell nav and top bar present
    assert html =~ "Startup Suite"
    assert html =~ "/chat"
    assert html =~ "/control"
  end

  test "chat page renders client hooks for last-space and per-space draft persistence", %{
    conn: conn
  } do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/chat/general")

    assert html =~ "phx-hook=\"ChatState\""
    assert html =~ "data-draft-key=\"chat-draft:"
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

    # Server-side, the form's `[:text].value` is also cleared — the textarea
    # body in the next render should not contain the sentinel. (The message
    # itself appears in the message stream; we check the form region.)
    html = render(view)
    # The message body is in the stream and is allowed to contain the sentinel
    # there; we want the textarea body specifically to not contain it.
    # Phoenix.HTML.Form.normalize_value("text", "") renders "" inside the textarea.
    refute html =~ ~s(<textarea\n              name="compose[text]"\n) <> ".*" <> sentinel
    # Tighter: form must serialize text="" — easier check: no <textarea ...>SENTINEL</textarea>
    refute Regex.match?(
             ~r/<textarea[^>]*name="compose\[text\]"[^>]*>[^<]*#{Regex.escape(sentinel)}[^<]*<\/textarea>/s,
             html
           )
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

    {:ok, _updated} = Chat.update_canvas(canvas, %{"document" => patched_document})

    assert render(view) =~ "INLINE_REFRESH_TOKEN"
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
      "value" => "approve"
    })

    assert render(view) =~ "Canvas action: ar-demo"
    assert render(view) =~ "approve"
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

  test "shows the shell agent indicator without a duplicate chat header presence badge", %{
    conn: conn
  } do
    conn = authenticated_conn(conn)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "platform-chat-live-agent-#{System.unique_integer([:positive, :monotonic])}"
      )

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

    assert html =~ "Agent"
    assert count_occurrences(html, "Agent") >= 1
    refute html =~ "Zip online"
  end

  test "chat boots the first configured workspace agent when no main agent exists", %{conn: conn} do
    conn = authenticated_conn(conn)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "platform-chat-live-default-agent-#{System.unique_integer([:positive, :monotonic])}"
      )

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

    assert html =~ "Agent"
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

    assert html =~ "Agent"
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
  end

  describe "attachments" do
    test "uploading a file shows it on the message after send", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      upload =
        file_input(view, "#compose-form", :attachments, [
          %{
            name: "hello.txt",
            content: "hello attachment",
            type: "text/plain"
          }
        ])

      # Open the upload staging dialog so file previews are visible
      view |> element("button[phx-click=upload_dialog_open]") |> render_click()

      assert render_upload(upload, "hello.txt") =~ "hello.txt"

      # Set the caption via the change event, then send via the dialog button
      render_change(view, "upload_caption_change", %{"caption" => "see file"})
      render_click(view, "upload_send")

      html = render(view)

      assert html =~ "see file"
      assert html =~ "hello.txt"

      space = Chat.get_space_by_slug("general")
      [message | _] = Chat.list_messages(space.id)
      [attachment] = Chat.list_attachments(message.id)

      assert attachment.filename == "hello.txt"
      assert html =~ "/chat/attachments/#{attachment.id}"
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

      # Open the staging dialog and progress the upload so the entry
      # is both staged server-side AND visible in the DOM. The
      # dialog-close path has its own cancel, so we keep the dialog
      # open to exercise the space-transition cancel path.
      view |> element("button[phx-click=upload_dialog_open]") |> render_click()
      assert render_upload(upload, "leak.txt") =~ "leak.txt"

      # Navigate to another space without closing the dialog or
      # sending. Both /chat/:space_slug routes map to the same
      # LiveView so handle_params fires in-process, which is the seam
      # where we cancel. Use render_patch (same-LV patch) rather than
      # live_redirect (which may remount).
      html = render_patch(view, ~p"/chat/other")

      # Flash surfaces on the destination render so the user knows
      # their staged file was dropped (and can re-select if intended).
      assert html =~ "Canceled 1 pending upload from the previous space"

      # Re-open the staging dialog in the new space: no leaked entry.
      view |> element("button[phx-click=upload_dialog_open]") |> render_click()
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
      # broadcast originated in, so Marlowe-in-a-DM saw Higgins-typing-in-
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

      # Quick emoji buttons should be present (in the action bar)
      assert html =~ "👍"
      assert html =~ "❤️"
      assert html =~ "😂"
      assert html =~ "🎉"
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

      user = insert_chat_user(%{name: "Marlowe", email: "marlowe@example.com", oidc_sub: "marlowe"})
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

      # Picker is not rendered before anyone opens it.
      refute html =~ ~s(id="reaction-picker")

      view
      |> form("#compose-form", compose: %{text: "picker target"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      html = render_click(view, "open_reaction_picker", %{"message-id" => msg.id})

      # Popover is now in the DOM, anchored to this message via the emoji buttons.
      assert html =~ ~s(id="reaction-picker")
      assert html =~ ~s(aria-label="Add reaction")
      # Every picker emoji button carries the target message-id.
      assert html =~ ~s(phx-value-message-id="#{msg.id}")
    end

    test "closing the reaction picker removes the popover", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "close-picker"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      html = render_click(view, "open_reaction_picker", %{"message-id" => msg.id})
      assert html =~ ~s(id="reaction-picker")

      html = render_click(view, "close_reaction_picker", %{})
      refute html =~ ~s(id="reaction-picker")
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

      # Picker is closed after selection — one-click flow.
      refute html =~ ~s(id="reaction-picker")
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

  # ── Mobile drawer ────────────────────────────────────────────────────────────

  describe "mobile drawer (new-conversation / new-channel)" do
    test "toggling the mobile drawer exposes both 'new conversation' and 'new channel' buttons",
         %{conn: conn} do
      # Before PR 1 the desktop sidebar had the only "+"/new-conversation and
      # "+"/new-channel affordances, wrapped in `<aside class="hidden lg:flex">`.
      # On mobile that rendered as nothing — users could see existing
      # conversations but had no way to start one. This test pins the mobile
      # drawer's entry points.
      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/chat/general")

      # Drawer is closed on initial load → the drawer's new-conversation
      # affordance isn't rendered yet. (Desktop sidebar has its own
      # `aria-label="New channel"` button — always in the DOM but hidden
      # via `hidden lg:flex` on mobile — so we only refute the
      # new-conversation affordance, which is drawer-only.)
      refute html =~ ~s(aria-label="New conversation")

      # Open the drawer.
      html = render_click(view, "toggle_mobile_browser", %{})

      # Both drawer affordances now render. They dispatch the same LV
      # events the desktop sidebar uses — modal wiring is shared; only
      # the trigger surfaces were missing on mobile.
      assert html =~ ~s(aria-label="New conversation")
      assert html =~ ~s(aria-label="New channel")
      assert html =~ "new_conversation_open"
      assert html =~ "new_channel_open"

      # Precision: both "+ " buttons must chain `close_mobile_browser`
      # after opening the modal, otherwise the modal renders behind the
      # drawer. Bounded by 100 chars to ensure the two pushes are part
      # of the same `phx-click` attribute, not just co-present elsewhere
      # (the drawer header close button and sidebar links also fire
      # `close_mobile_browser` on their own).
      assert Regex.match?(
               ~r/new_channel_open.{0,100}close_mobile_browser|close_mobile_browser.{0,100}new_channel_open/s,
               html
             )

      assert Regex.match?(
               ~r/new_conversation_open.{0,100}close_mobile_browser|close_mobile_browser.{0,100}new_conversation_open/s,
               html
             )
    end
  end

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
  end

  # ── Settings modal ──────────────────────────────────────────────────────────

  describe "settings modal" do
    test "opens settings modal for a channel with name/description/topic fields", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      html = render_click(view, "settings_open", %{})

      assert html =~ "Channel Settings"
      assert html =~ ~s(name="name")
      assert html =~ ~s(name="description")
      assert html =~ ~s(name="topic")
      # ADR 0027: Agent Attention Mode removed
      refute html =~ "Agent Attention Mode"
      assert html =~ "Archive Channel"
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

    test "archiving a channel redirects to /chat", %{conn: conn} do
      conn = authenticated_conn(conn)

      {:ok, _space} =
        Chat.create_channel(%{name: "to-archive", slug: "to-archive", description: ""})

      {:ok, view, _html} = live(conn, ~p"/chat/to-archive")

      render_click(view, "settings_open", %{})

      view
      |> element("button[phx-click=settings_archive]")
      |> render_click()

      assert_redirect(view, "/chat")

      archived = Chat.get_space_by_slug("to-archive")
      assert archived.archived_at != nil
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
end
