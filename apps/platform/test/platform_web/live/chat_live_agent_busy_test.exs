defmodule PlatformWeb.ChatLiveAgentBusyTest do
  @moduledoc """
  The busy and waiting states in the chat dock.

  The reported bug: a mention to an agent that was busy with a long job read
  "<Agent> couldn't reply to this message. Something went wrong…" with a
  Restart button. Now, while a message waits on an agent, the typing
  indicator's slot says which of two things is true:

    * "<Agent> is busy · <activity> · since <time>": its runtime is
      connected and it is working on something else;
    * "Waiting for <Agent> · your message will be delivered when it
      reconnects": its runtime is offline and the message is held.

  Pinned: both lines render from the `{:agent_busy, ...}` broadcast; the
  line goes when the agent posts, when it starts typing (it has turned to
  this space), and on a `busy: nil` clear; a broadcast for another space
  does nothing (anti-vacuity: the same payload with this space's id does).
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.AsyncAssertions

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "busy-#{n}@example.com",
        name: "Busy Viewer",
        oidc_sub: "oidc-busy-#{n}"
      })

    {:ok, space} =
      Chat.create_space(%{name: "Busy #{n}", slug: "busy-#{n}", kind: "channel"})

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    agent =
      Repo.insert!(%Agent{
        slug: "busy-agent-#{n}",
        name: "Ada",
        status: "active",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })

    {:ok, agent_p} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: "Ada",
        joined_at: DateTime.utc_now()
      })

    conn = init_test_session(conn, current_user_id: user.id)
    %{conn: conn, space: space, agent_p: agent_p}
  end

  defp busy_lines(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(#chat-typing-indicator [data-role="agent-busy"]))
    |> Enum.map(&{LazyHTML.attribute(&1, "data-state"), LazyHTML.text(&1)})
  end

  defp busy!(view, space, pid, busy) do
    send(view.pid, {:agent_busy, %{space_id: space.id, participant_id: pid, busy: busy}})
    render(view)
  end

  test "busy: name, activity and since, in the indicator's slot; no Restart anywhere", ctx do
    %{conn: conn, space: space, agent_p: agent_p} = ctx
    {:ok, view, html} = live(conn, ~p"/chat/#{space.slug}")
    assert busy_lines(html) == []

    since = ~U[2026-11-18 20:51:57Z]

    html =
      busy!(view, space, agent_p.id, %{
        state: "busy",
        activity: "working on “Ship it”",
        since: since,
        agent_name: "Ada"
      })

    assert [{["busy"], text}] = busy_lines(html)
    assert text =~ "Ada is busy · working on “Ship it”"
    assert text =~ "since"

    doc = LazyHTML.from_document(html)

    assert [_] =
             doc
             |> LazyHTML.query(
               ~s|#chat-typing-indicator:not([hidden]) time[datetime="#{DateTime.to_iso8601(since)}"]|
             )
             |> Enum.to_list()

    refute html =~ "Restart"
    refute html =~ "couldn't reply"

    # The agent turns to this space: busy gives way to thinking.
    send(
      view.pid,
      {:agent_typing, %{space_id: space.id, participant_id: agent_p.id, typing: true}}
    )

    html = render(view)
    assert busy_lines(html) == []
    assert html =~ "is thinking"
  end

  test "queued: Waiting for <Agent>, cleared when the agent posts", ctx do
    %{conn: conn, space: space, agent_p: agent_p} = ctx
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

    html =
      busy!(view, space, agent_p.id, %{
        state: "queued",
        activity: nil,
        since: DateTime.utc_now(),
        agent_name: "Ada"
      })

    assert [{["queued"], text}] = busy_lines(html)
    assert text =~ "Waiting for Ada · your message will be delivered when it reconnects"

    {:ok, _} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: agent_p.id,
        content_type: "text",
        content: "back now"
      })

    assert_eventually(fn -> busy_lines(render(view)) == [] end)
  end

  test "a clear removes it; another space's broadcast never shows", ctx do
    %{conn: conn, space: space, agent_p: agent_p} = ctx
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
    busy = %{state: "busy", activity: nil, since: DateTime.utc_now(), agent_name: "Ada"}

    send(
      view.pid,
      {:agent_busy, %{space_id: Ecto.UUID.generate(), participant_id: agent_p.id, busy: busy}}
    )

    assert busy_lines(render(view)) == []

    assert [{["busy"], text}] = busy!(view, space, agent_p.id, busy) |> busy_lines()
    # No activity known: the bare line, still with since.
    assert text =~ "Ada is busy"
    refute text =~ "Ada is busy ·"

    assert busy!(view, space, agent_p.id, nil) |> busy_lines() == []
  end
end
