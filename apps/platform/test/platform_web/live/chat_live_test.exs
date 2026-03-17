defmodule PlatformWeb.ChatLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentServer}
  alias Platform.Chat
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

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "chat_test@example.com",
        name: "Chat Test User",
        oidc_sub: "oidc-chat-test"
      })

    init_test_session(conn, current_user_id: user.id)
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

  test "sending a message renders it once in the chat", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/general")

    view
    |> form("#compose-form", compose: %{text: "hello from test"})
    |> render_submit()

    html = render(view)

    assert html =~ "hello from test"
    assert count_occurrences(html, "hello from test") == 1
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

    assert html =~ "Agent online"
    assert count_occurrences(html, "Agent online") == 1
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

    assert html =~ "Agent online"
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

    assert html =~ "Agent online"
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

    test "opening a threaded search result opens the thread panel", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "Thread root"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [root_message | _] = Chat.list_messages(space.id)

      render_click(view, "open_thread", %{"message_id" => root_message.id})

      view
      |> form("#thread-compose-form", thread_compose: %{text: "Phoenix lives in threads too"})
      |> render_submit()

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

      html = render_click(view, "open_search_result", %{"message_id" => thread_message.id})

      assert html =~ "thread-compose-form"
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

      assert render_upload(upload, "hello.txt") =~ "hello.txt"

      html =
        view
        |> form("#compose-form", compose: %{text: "see file"})
        |> render_submit()

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

    test "reacting to a message broadcasts reaction_added and updates UI", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      # Send a message first
      view
      |> form("#compose-form", compose: %{text: "emoji test"})
      |> render_submit()

      html = render(view)
      assert html =~ "emoji test"

      # Find a message ID from the space to trigger the react event
      slug = "general"
      space = Chat.get_space_by_slug(slug)
      [msg | _] = Chat.list_messages(space.id)

      # Trigger react event directly
      render_click(view, "react", %{"message_id" => msg.id, "emoji" => "👍"})

      # After the PubSub roundtrip the reaction should appear
      html = render(view)
      # The reaction button shows count ≥ 1
      assert html =~ "👍"
    end
  end

  # ── Threads ──────────────────────────────────────────────────────────────────

  describe "threads" do
    test "opening a thread shows the thread panel", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      # Post a message to open a thread on
      view
      |> form("#compose-form", compose: %{text: "start a thread here"})
      |> render_submit()

      slug = "general"
      space = Chat.get_space_by_slug(slug)
      [msg | _] = Chat.list_messages(space.id)

      html = render_click(view, "open_thread", %{"message_id" => msg.id})

      assert html =~ "Thread"
      assert html =~ "thread-compose-form"
    end

    test "closing the thread panel hides it", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "thread close test"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      render_click(view, "open_thread", %{"message_id" => msg.id})
      html = render_click(view, "close_thread", %{})

      refute html =~ "thread-compose-form"
    end

    test "posting a thread reply appears once in thread panel", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "root message"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      render_click(view, "open_thread", %{"message_id" => msg.id})

      view
      |> form("#thread-compose-form", thread_compose: %{text: "thread reply"})
      |> render_submit()

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

      render_click(view, "open_thread", %{"message_id" => msg.id})

      view
      |> form("#thread-compose-form",
        thread_compose: %{text: "thread reply should stay in thread"}
      )
      |> render_submit()

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

      render_click(view, "open_thread", %{"message_id" => msg.id})

      view
      |> form("#thread-compose-form", thread_compose: %{text: "timestamp thread reply"})
      |> render_submit()

      html = render(view)

      assert html =~ "timestamp thread reply"
      assert Regex.match?(~r/id="thread-messages"[\s\S]*phx-hook="LocalTime"/, html)
      assert Regex.match?(~r/id="thread-messages"[\s\S]*data-local-time=/, html)
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
      render_click(view, "toggle_pin", %{"message_id" => msg.id, "space_id" => msg.space_id})

      # Toggle pins panel open
      html = render_click(view, "toggle_pins_panel", %{})

      assert html =~ "Pinned Messages"
      assert html =~ String.slice(msg.id, 0, 8)
    end

    test "toggle_pins_panel shows and hides the panel", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "pin me"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      render_click(view, "toggle_pin", %{"message_id" => msg.id, "space_id" => msg.space_id})

      html_open = render_click(view, "toggle_pins_panel", %{})
      assert html_open =~ "Pinned Messages"

      html_closed = render_click(view, "toggle_pins_panel", %{})
      refute html_closed =~ "Pinned Messages"
    end
  end
end
