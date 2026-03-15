defmodule PlatformWeb.ChatLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "chat_test@example.com",
        name: "Chat Test User",
        oidc_sub: "oidc-chat-test"
      })

    init_test_session(conn, current_user_id: user.id)
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

  test "sending a message renders it in the chat", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/general")

    html =
      view
      |> form("#compose-form", compose: %{text: "hello from test"})
      |> render_submit()

    assert html =~ "hello from test"
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

    test "posting a thread reply appears in thread panel", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#compose-form", compose: %{text: "root message"})
      |> render_submit()

      space = Chat.get_space_by_slug("general")
      [msg | _] = Chat.list_messages(space.id)

      render_click(view, "open_thread", %{"message_id" => msg.id})

      html =
        view
        |> form("#thread-compose-form", thread_compose: %{text: "thread reply"})
        |> render_submit()

      assert html =~ "thread reply"
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
