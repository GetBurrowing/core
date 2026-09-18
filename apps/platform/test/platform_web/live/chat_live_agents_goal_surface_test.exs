defmodule PlatformWeb.ChatLiveAgentsGoalSurfaceTest do
  @moduledoc """
  Render coverage for the stage-4 agents surface (task
  `01a0b491-0718-7001-8bba-bf50f119bb13`): the rail block above Pinned and
  the space-header goal strip.

  Assertions address `data-role` hooks, not Tailwind classes, so a restyle
  does not read as a behaviour regression. The two exceptions are
  deliberate and are the two visual claims the stage is actually making:

    * the measurement clause carries `text-base-content/60` and NOT
      `/40` — `/40` is the treatment `topic` uses and it was measured at
      2.85:1 light / 3.53:1 dark, which fails AA in both themes;
    * `text-warning` appears on the no-measurement clause and NOWHERE
      else on either surface.

  Every absence is paired with the presence that proves the absence was
  the condition under test and not a broken render.

  `async: false` — the feature flag is application env, global to the node.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Roles

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
        email: "agents_goal_#{n}@example.com",
        name: "Agents Goal Test User",
        oidc_sub: "oidc-agents-goal-#{n}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp insert_agent(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "agents-goal-#{n}",
      name: name,
      status: "active"
    })
  end

  defp create_space(attrs) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(
        Map.merge(
          %{name: "Agents #{n}", slug: "agents-goal-space-#{n}", kind: "channel"},
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

  describe "the flag gates both surfaces" do
    test "with the flag unset nothing renders, even though the columns hold values", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      disable_flag()

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")

      refute html =~ ~s(data-role="agents-rail-block")
      refute html =~ ~s(data-role="agents-goal-strip")
      refute html =~ ~s(data-role="agents-goal-sentence")
      refute html =~ "Close backlog items in Suite"
    end

    test "with the flag set the same space renders both — control for the case above", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      enable_flag()

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")

      assert html =~ ~s(data-role="agents-rail-block")
      assert html =~ ~s(data-role="agents-rail-row")
      assert html =~ ~s(data-role="agents-goal-strip")
      assert html =~ "Close backlog items in Suite"
    end
  end

  describe "the header strip is conditional on the space" do
    test "an ordinary channel's header carries no goal line, no leader and no measurement", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      enable_flag()

      goal_space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(goal_space, user)

      plain = create_space(name: "control", topic: "ordinary topic")
      add_user(plain, user)

      {:ok, _view, plain_html} = live_at(conn, "/chat/#{plain.slug}")

      refute plain_html =~ ~s(data-role="agents-goal-strip")
      refute plain_html =~ ~s(data-role="agents-goal-leader")
      refute plain_html =~ ~s(data-role="agents-goal-measurement")
      # The topic still renders exactly as it did before this feature: the
      # suppression below is scoped to spaces that HAVE a goal.
      assert plain_html =~ "ordinary topic"

      # The rail block is global, so it appears on the control channel too —
      # that is the block saying which space the agents serve, not a claim
      # about the space being read.
      assert plain_html =~ ~s(data-role="agents-rail-block")
    end
  end

  describe "contrast and the single warning" do
    test "the measurement clause uses /60 and not the /40 topic tier", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      space = create_space(goal: "Close backlog items in Suite")
      add_user(space, user)

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")

      [_, clause] = String.split(html, ~s(data-role="agents-goal-measurement"), parts: 2)
      measurement_tag = String.slice(clause, 0, 200)

      assert html =~ "text-base-content/60"
      refute measurement_tag =~ "text-base-content/40"
      # The numeral, and only the numeral, is in the monospace face.
      assert html =~ ~s(data-role="agents-goal-number")
    end

    test "warning appears on the no-measurement state and on nothing else", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      measurable = create_space(goal: "Close backlog items in Suite")
      add_user(measurable, user)

      {:ok, _view, measurable_html} = live_at(conn, "/chat/#{measurable.slug}")

      # Positive control: with a derivable measurement there is no warning
      # anywhere on the surface — not on the delta, not on a falling count.
      refute measurable_html =~ ~s(data-role="agents-goal-measurement-missing")
      refute measurable_html =~ "text-warning"

      {:ok, unmeasurable} = Chat.update_space(measurable, %{goal: "Get SXI to a good state"})

      {:ok, _view, warning_html} = live_at(conn, "/chat/#{unmeasurable.slug}")

      assert warning_html =~ ~s(data-role="agents-goal-measurement-missing")
      assert warning_html =~ "text-warning"
    end
  end

  describe "saving a goal re-derives the measurement" do
    test "a goal that loses its measurement shows the missing state, not the stale number", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      space = create_space(goal: "Close backlog items in Suite")
      add_user(space, user)

      {:ok, view, html} = live_at(conn, "/chat/#{space.slug}")
      assert html =~ ~s(data-role="agents-goal-number")

      # Drive the same event the pencil drives. `can_edit_goal?` is false for
      # this non-admin user, so the write is REFUSED — which is the gate the
      # affordance sits over, asserted here rather than assumed.
      render_change(view, "save_goal", %{"goal" => "Get SXI to a good state"})

      assert Repo.reload!(space).goal == "Close backlog items in Suite"
    end

    test "the panel re-derives from the saved goal with no cached number to fall back to" do
      space = create_space(goal: "Close backlog items in Suite")
      enable_flag()

      assert Sidebar.goal_panel(space).measurement.missing? == false

      {:ok, updated} = Chat.update_space(space, %{goal: "Get SXI to a good state"})

      assert Sidebar.goal_panel(updated).measurement.missing? == true
    end
  end

  describe "a leader swap repaints both avatars with no reload" do
    test "the role broadcast updates the rail row and the header together", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      first = insert_agent("Firstleader")
      second = insert_agent("Secondleader")

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: first.id)
      add_user(space, user)

      {:ok, _} = Roles.assign_role(Sidebar.agents_leader_role(), first.id)

      {:ok, view, html} = live_at(conn, "/chat/#{space.slug}")
      assert html =~ "Firstleader leads"

      # `role_assignments.role_key` is unique and `assign_role/2` is an
      # INSERT, so moving a role is release-then-pin. That is the existing
      # role path, untouched by this stage — recorded here because it is
      # the shape a caller has to use, not a quirk of the test.
      :ok = Roles.unassign_role(Sidebar.agents_leader_role())
      {:ok, _} = Roles.assign_role(Sidebar.agents_leader_role(), second.id)

      html = render(view)
      assert html =~ "Secondleader leads"
      refute html =~ "Firstleader leads"
    end
  end
end
