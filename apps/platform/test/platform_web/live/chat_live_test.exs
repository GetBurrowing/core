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
        canvas_type: "custom",
        title: "Out-of-band canvas",
        state: %{}
      })

    updated_state = %{
      "version" => 1,
      "root" => %{
        "type" => "stack",
        "props" => %{"gap" => 8},
        "children" => [
          %{
            "type" => "heading",
            "props" => %{"level" => 3, "value" => "Out-of-band render test"}
          },
          %{
            "type" => "markdown",
            "props" => %{"content" => "Canvas should render the latest stored state."}
          }
        ]
      }
    }

    canvas
    |> Canvas.changeset(%{"state" => updated_state})
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

      render_click(view, "react", %{"message_id" => msg.id, "emoji" => "👍"})

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
      render_click(view, "react", %{"message_id" => msg.id, "emoji" => "👍"})
      assert [_] = Chat.list_reactions(msg.id)

      # React again (same user, same emoji) — reaction is removed
      render_click(view, "react", %{"message_id" => msg.id, "emoji" => "👍"})
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

      html = render_click(view, "open_reaction_picker", %{"message_id" => msg.id})

      # Popover is now in the DOM, anchored to this message via the emoji buttons.
      assert html =~ ~s(id="reaction-picker")
      assert html =~ ~s(aria-label="Add reaction")
      # Every picker emoji button carries the target message_id.
      assert html =~ ~s(phx-value-message_id="#{msg.id}")
    end

    test "closing the reaction picker removes the popover", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "close-picker"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      html = render_click(view, "open_reaction_picker", %{"message_id" => msg.id})
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
      render_click(view, "open_reaction_picker", %{"message_id" => msg.id})

      # Pick an emoji that is NOT in @quick_emojis, to prove the picker is the
      # path under test (not the hover quick-react buttons).
      html = render_click(view, "react", %{"message_id" => msg.id, "emoji" => "🚀"})

      # Reaction is persisted.
      assert [%{emoji: "🚀"}] = Chat.list_reactions(msg.id)

      # Picker is closed after selection — one-click flow.
      refute html =~ ~s(id="reaction-picker")
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
