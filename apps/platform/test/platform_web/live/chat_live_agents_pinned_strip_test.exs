defmodule PlatformWeb.ChatLiveAgentsPinnedStripTest do
  @moduledoc """
  Render coverage for the Agents chip in the MOBILE pinned strip
  (task `01a0b491-0718-7001-8bba-bf50f119bb13`, v2 stage 2).

  The strip (`Conversation.mobile_pinned_strip/1`, `lg:hidden`) is the
  always-visible mobile nav surface; the drawer from stage 1 costs a tap. Its
  render guard previously fired only when the user had pins, so the widened
  guard — non-nil `@agents_block` — is the substance of this stage and the
  no-pins case below FAILS on the pre-change tree.

  The flag-off-with-pins case is its regression control: without it, a guard
  that accidentally always fires looks correct.

  Assertions are sliced to the strip's own `<nav>`, because the desktop rail
  and the mobile drawer both carry an Agents row in the same HTML and would
  satisfy a document-wide assertion while the strip stayed empty.

  `async: false` — the feature flag is application env, global to the node.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tasks

  @flag_key :agents_goal_surface

  setup do
    previous = Application.get_env(:platform, @flag_key)
    on_exit(fn -> Application.put_env(:platform, @flag_key, previous) end)
    :ok
  end

  defp enable_flag, do: Application.put_env(:platform, @flag_key, true)
  defp disable_flag, do: Application.put_env(:platform, @flag_key, false)

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "agents_strip_#{n}@example.com",
        name: "Agents Strip Test User",
        oidc_sub: "oidc-agents-strip-#{n}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp insert_agent(name) do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "agents-strip-#{n}", name: name, status: "active"})
  end

  defp create_space(attrs) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(
        Map.merge(
          %{name: "Agents #{n}", slug: "agents-strip-space-#{n}", kind: "channel"},
          Map.new(attrs)
        )
      )

    space
  end

  defp add_user(space, user) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    :ok
  end

  defp live_at(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: redirect}}} -> live(conn, redirect)
      ok -> ok
    end
  end

  # Slice to the strip's own <nav>. The rail's `agents-rail-block` and the
  # drawer's `agents-drawer-block` are in the same document.
  defp strip_html(html) do
    case String.split(html, ~s(data-role="mobile-pinned-strip"), parts: 2) do
      [_, rest] ->
        case String.split(rest, "</nav>", parts: 2) do
          [strip | _] -> strip
          [] -> ""
        end

      [_only] ->
        nil
    end
  end

  describe "the widened render guard" do
    test "the strip renders an Agents chip when BOTH pin lists are empty", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      enable_flag()

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")

      strip = strip_html(html)

      refute is_nil(strip),
             "the strip must render for a user with no pins once an Agents block exists"

      assert strip =~ ~s(data-role="agents-pinned-strip-chip")

      chips = length(String.split(strip, ~s(data-role="agents-pinned-strip-chip"))) - 1
      task_chips = length(String.split(strip, ~s(data-role="mobile-pinned-task-chip"))) - 1
      channel_chips = length(String.split(strip, ~s(data-role="mobile-pinned-channel-chip"))) - 1

      assert {chips, task_chips, channel_chips} == {1, 0, 0},
             "expected exactly one chip (the Agents chip), got " <>
               "agents=#{chips} task=#{task_chips} channel=#{channel_chips}"
    end

    test "the Agents chip precedes the task-pin chips by byte position", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      enable_flag()

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      pin_task_space(user)

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")
      strip = strip_html(html)

      refute is_nil(strip)
      assert strip =~ ~s(data-role="mobile-pinned-task-chip")

      agents_at = :binary.match(strip, ~s(data-role="agents-pinned-strip-chip")) |> elem(0)
      task_at = :binary.match(strip, ~s(data-role="mobile-pinned-task-chip")) |> elem(0)

      assert agents_at < task_at,
             "Agents chip must be the first chip in the strip " <>
               "(agents at #{agents_at}, task pin at #{task_at})"
    end

    test "with the flag off and no pins the strip does not render at all", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      disable_flag()

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")

      assert is_nil(strip_html(html)),
             "pre-existing behaviour: no pins and no Agents block means no strip"

      refute html =~ ~s(data-role="agents-pinned-strip-chip")
    end

    test "REGRESSION CONTROL: flag off with pins renders the pins and no Agents chip", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      disable_flag()

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      pin_task_space(user)

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")
      strip = strip_html(html)

      refute is_nil(strip), "the pre-existing pins path must still render the strip"
      assert strip =~ ~s(data-role="mobile-pinned-task-chip")
      refute strip =~ ~s(data-role="agents-pinned-strip-chip")
    end
  end

  describe "the chip's glyph slot" do
    test "a resolved leader renders a ringed avatar", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      enable_flag()

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")
      strip = strip_html(html)

      assert strip =~ "Dalton leads"
      assert strip =~ "ring-2 ring-primary"
    end

    test "no leader renders NO glyph element at all — not an empty span", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      space = create_space(goal: "Close backlog items in Suite")
      add_user(space, user)

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")
      strip = strip_html(html)

      assert strip =~ ~s(data-role="agents-pinned-strip-chip")
      refute strip =~ "ring-2 ring-primary"
      refute strip =~ "leads"

      # This strip's recorded rule, and the OPPOSITE of the rail/drawer rows:
      # no empty indent slot inside a pill.
      refute strip =~ ~s(class="w-5 shrink-0)
    end
  end

  # A task-exec space pinned into @pinned_task_spaces, so "both lists empty"
  # has a non-vacuous counterpart to be ordered against. Seeded through the
  # production pin path (`ChatPins.pin/3`), which is what creates the space.
  defp pin_task_space(user) do
    {:ok, project} =
      Tasks.create_project(%{name: "Agents Strip Project #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Agents Strip Pin Control",
        status: "backlog",
        sponsor_user_id: user.id
      })

    {:ok, %{space: space}} =
      Tasks.ChatPins.pin(task.id, %{kind: "user", id: user.email}, user.email)

    space
  end
end
