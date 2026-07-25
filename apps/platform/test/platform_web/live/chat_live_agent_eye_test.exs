defmodule PlatformWeb.ChatLiveAgentEyeTest do
  @moduledoc """
  Render + event coverage for the single agent-eye header control
  (task 019f9790 stage 4).

  Before this task the chat header carried three controls that could disagree
  with one another — a "Talking to {name}" pill, a dimmed "{primary} listening"
  hint, and a `watch_enabled` eye — and none of them was the thing that
  actually routes messages. There is now exactly one button and its state IS
  the `ActiveAgentStore` mutex.

  These tests assert on `data-eye-state` rather than on Tailwind classes, so a
  restyle does not read as a behaviour regression:

    * `open`   — a mutex is held, the agent's name is shown
    * `closed` — no mutex but `resolve_armable/2` found a target (clickable)
    * `inert`  — no mutex and no defensible target (rendered, `disabled`)

  DM spaces render no control at all: `attention_router.ex` makes DMs
  unconditionally `:directed`, so there is nothing to toggle there.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user = insert_chat_user()
    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp insert_chat_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "agent_eye_#{n}@example.com",
      name: "Agent Eye Test User",
      oidc_sub: "oidc-agent-eye-#{n}"
    })
  end

  defp insert_chat_agent(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "agent-eye-#{n}",
      name: name,
      status: "active",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    })
  end

  defp create_space(kind) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Agent Eye #{n}",
        slug: "agent-eye-#{kind}-#{n}",
        kind: kind
      })

    space
  end

  defp add_user(space, user) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp add_agent(space, name) do
    agent = insert_chat_agent(name)

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  # `/chat` redirects to the first channel as soon as one exists; always land
  # on the space this test actually built.
  defp live_at(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: redirect}}} -> live(conn, redirect)
      ok -> ok
    end
  end

  # The control renders `data-role` before `data-eye-state`; pull the state out
  # of the button rather than matching on classes.
  defp eye_state(html) do
    case Regex.run(~r/data-role="agent-eye"[^>]*data-eye-state="([a-z]+)"/, html) do
      [_full, state] -> state
      nil -> nil
    end
  end

  defp eye_tag(html) do
    case Regex.run(~r/<button[^>]*data-role="agent-eye"[^>]*>/, html) do
      [tag] -> tag
      nil -> nil
    end
  end

  describe "closed (armable) state" do
    test "a channel with one agent participant and no mutex renders `closed`", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      space = create_space("channel")
      add_user(space, user)
      add_agent(space, "Higgins")

      {:ok, _view, html} = live_at(conn, ~p"/chat/#{space.slug}")

      assert eye_state(html) == "closed"
      # Closed shows no agent name and no dimmed listening hint.
      refute html =~ "listening"
      refute html =~ "Talking to"
      refute eye_tag(html) =~ "disabled"
    end

    test "the closed eye is wired to `active_agent_arm`", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      space = create_space("channel")
      add_user(space, user)
      add_agent(space, "Higgins")

      {:ok, _view, html} = live_at(conn, ~p"/chat/#{space.slug}")

      assert eye_tag(html) =~ ~s(phx-click="active_agent_arm")
    end
  end

  describe "open state" do
    test "an ActiveAgentStore broadcast flips the eye to `open` with the agent name", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      space = create_space("channel")
      add_user(space, user)
      agent_participant = add_agent(space, "Higgins")

      {:ok, view, html} = live_at(conn, ~p"/chat/#{space.slug}")
      assert eye_state(html) == "closed"

      ActiveAgentStore.set_active(space.id, agent_participant.id)
      Process.sleep(50)

      html = render(view)

      assert eye_state(html) == "open"
      assert html =~ "Higgins"
      assert eye_tag(html) =~ ~s(phx-click="active_agent_clear")
    end

    test "clicking the open eye clears the mutex and returns to `closed`", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      space = create_space("channel")
      add_user(space, user)
      agent_participant = add_agent(space, "Higgins")

      {:ok, view, _html} = live_at(conn, ~p"/chat/#{space.slug}")

      ActiveAgentStore.set_active(space.id, agent_participant.id)
      Process.sleep(50)
      assert eye_state(render(view)) == "open"

      view |> element(~s([data-role="agent-eye"])) |> render_click()
      Process.sleep(50)

      assert ActiveAgentStore.get_active(space.id) == nil
      # The store retains `last`, so the eye stays clickable rather than inert.
      assert eye_state(render(view)) == "closed"
    end
  end

  describe "inert state" do
    test "two agent participants with no mutex history render `inert` and disabled", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      space = create_space("channel")
      add_user(space, user)
      add_agent(space, "Higgins")
      add_agent(space, "Saru")

      {:ok, _view, html} = live_at(conn, ~p"/chat/#{space.slug}")

      assert eye_state(html) == "inert"
      assert eye_tag(html) =~ "disabled"
      # Inert is rendered, not hidden — the header must not reflow when the
      # roster changes.
      refute eye_tag(html) =~ "phx-click"
    end
  end

  describe "close → re-open round trip" do
    test "re-opening the eye resumes the SAME agent, with no @mention", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      space = create_space("channel")
      add_user(space, user)
      agent_participant = add_agent(space, "Higgins")
      # A second agent so a pass here can only come from `resolve_armable/2`
      # rule 1 (remembered agent), never from rule 2 (sole agent).
      add_agent(space, "Saru")

      {:ok, view, _html} = live_at(conn, ~p"/chat/#{space.slug}")

      ActiveAgentStore.set_active(space.id, agent_participant.id)
      Process.sleep(50)
      assert eye_state(render(view)) == "open"

      view |> element(~s([data-role="agent-eye"])) |> render_click()
      Process.sleep(50)
      assert eye_state(render(view)) == "closed"
      assert ActiveAgentStore.get_active(space.id) == nil

      view |> element(~s([data-role="agent-eye"])) |> render_click()
      Process.sleep(50)

      html = render(view)
      assert eye_state(html) == "open"
      # The open-state title names the armed agent — assert on that rather
      # than on a bare name match, which the roster sidebar would also satisfy.
      assert eye_tag(html) =~ "Your next message goes to Higgins"
      assert ActiveAgentStore.get_active(space.id) == agent_participant.id
    end
  end

  describe "multi-window live refresh" do
    test "closing the eye in one window closes it in the other without a reload", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      space = create_space("channel")
      add_user(space, user)
      agent_participant = add_agent(space, "Higgins")

      {:ok, view_a, _html} = live_at(conn, ~p"/chat/#{space.slug}")
      {:ok, view_b, _html} = live_at(conn, ~p"/chat/#{space.slug}")

      ActiveAgentStore.set_active(space.id, agent_participant.id)
      Process.sleep(50)
      assert eye_state(render(view_a)) == "open"
      assert eye_state(render(view_b)) == "open"

      # Close in window A only; window B must follow off the
      # {:active_agent_changed, ...} broadcast, not off a remount.
      view_a |> element(~s([data-role="agent-eye"])) |> render_click()
      Process.sleep(50)

      assert ActiveAgentStore.get_active(space.id) == nil
      assert eye_state(render(view_b)) == "closed"
      assert eye_state(render(view_a)) == "closed"
    end
  end

  describe "DM spaces" do
    test "an agent DM renders no eye control at all", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      space = create_space("dm")
      add_user(space, user)
      add_agent(space, "Higgins")

      {:ok, _view, html} = live_at(conn, ~p"/chat/#{space.slug}")

      # Guard the refutes below: prove the space header actually rendered, so
      # a routing regression cannot pass this test by rendering nothing.
      assert html =~ ~s(phx-click="settings_open")
      refute html =~ ~s(data-role="agent-eye")
      refute html =~ "Talking to"
      refute html =~ "listening"
    end
  end
end
