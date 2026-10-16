defmodule PlatformWeb.ControlCenterOwnershipTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.RuntimeProfiles
  alias Platform.Agents.Agent
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Roles.RoleAssignment
  alias Platform.Tenancy.Org

  test "a plain member federates an agent they own and sees its token once", %{conn: conn} do
    user = member!()
    runtime_id = "member-fed-#{System.unique_integer([:positive])}"
    {:ok, view, _} = live(as_user(conn, user), ~p"/control")
    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "federate"})

    html =
      view
      |> form("#federate-form",
        federate: %{runtime_id: runtime_id, display_name: "Member Runtime", agent_name: "Member Agent"}
      )
      |> render_submit()

    assert html =~ "Save this token now"
    runtime = Federation.get_runtime_by_runtime_id(runtime_id)
    assert runtime.owner_user_id == user.id

    html = render_click(view, "federate_done", %{})
    refute html =~ "Save this token now"
  end

  test "plain member edits an owned agent's profile and releases its responsibility", %{
    conn: conn
  } do
    user = member!()
    {agent, runtime} = federated_agent!(user)
    :ok = Roles.unassign_role("designer")
    {:ok, _} = Roles.assign_role("designer", agent.id)

    {:ok, view, html} = live(as_user(conn, user), ~p"/control/#{agent.slug}")
    assert html =~ "Save tool profile"
    assert has_element?(view, ~s([data-role="agent-restrict-toggle"]))

    html =
      view
      |> element("form[phx-submit=save_tool_profile]")
      |> render_submit(%{"modules" => ["task"]})

    assert html =~ "Tool profile updated."
    assert RuntimeProfiles.tool_profile(runtime) == ["task"]

    html =
      view
      |> element("form[phx-submit=save_agent_restrictions]")
      |> render_submit(%{"inherit" => "false", "permissions" => ["tasks.read"]})

    assert html =~ "Agent access updated."
    assert RuntimeProfiles.restrictions(runtime) == %{"tasks.read" => "all"}

    html = render_click(view, "clear_role_assignment", %{"role_key" => "designer"})
    assert html =~ "Cleared assignment for designer."
    assert Repo.get_by(RoleAssignment, role_key: "designer") == nil
  end

  test "member sees another agent but cannot mutate token, profile, or responsibility", %{
    conn: conn
  } do
    owner = member!()
    other = member!()
    {agent, runtime} = federated_agent!(owner)
    :ok = Roles.unassign_role("designer")
    {:ok, _} = Roles.assign_role("designer", agent.id)

    {:ok, view, html} = live(as_user(conn, other), ~p"/control/#{agent.slug}")
    assert html =~ agent.name
    refute html =~ "Save tool profile"
    refute has_element?(view, ~s(button[phx-click="regenerate_federated_token"]))

    original = Repo.get!(Platform.Agents.AgentRuntime, runtime.id)
    profile = RuntimeProfiles.get(runtime)
    assignment = Repo.get_by(RoleAssignment, role_key: "designer")

    for {event, params} <- [
          {"regenerate_federated_token", %{}},
          {"save_tool_profile", %{"modules" => ["task"]}},
          {"clear_role_assignment", %{"role_key" => "designer"}}
        ] do
      assert render_click(view, event, params) =~ "You can only manage your own agents."
    end

    assert Repo.get!(Platform.Agents.AgentRuntime, runtime.id) == original
    assert RuntimeProfiles.get(runtime) == profile
    assert Repo.get_by(RoleAssignment, role_key: "designer") == assignment
  end

  test "unknown event is refused", %{conn: conn} do
    user = member!()
    {:ok, view, _} = live(as_user(conn, user), ~p"/control")
    assert render_click(view, "unclassified_write", %{}) =~ "You can only manage your own agents."
  end

  test "root admin manages another user's agent", %{conn: conn} do
    owner = member!()
    admin = root_admin!()
    {agent, runtime} = federated_agent!(owner)

    {:ok, view, html} = live(as_user(conn, admin), ~p"/control/#{agent.slug}")
    assert html =~ "Save tool profile"
    assert has_element?(view, ~s(button[phx-click="regenerate_federated_token"]))

    assert render_click(view, "save_tool_profile", %{"modules" => ["task"]}) =~
             "Tool profile updated."

    assert RuntimeProfiles.tool_profile(runtime) == ["task"]
  end

  test "event policy classifies every source handler" do
    source = File.read!("lib/platform_web/live/control_center_live.ex")

    handlers =
      Regex.scan(~r/defp handle_control_event\(\s*"([^"]+)"/, source)
      |> Enum.map(&Enum.at(&1, 1))
      |> MapSet.new()

    policy =
      source
      |> String.split("@event_policy %{")
      |> Enum.at(1)
      |> String.split("\n  }", parts: 2)
      |> hd()
      |> then(&Regex.scan(~r/"([^"]+)" =>/, &1))
      |> Enum.map(&Enum.at(&1, 1))
      |> MapSet.new()

    assert handlers == policy
  end

  defp member! do
    user = World.create_user!()
    World.plain_member!(user, Repo.get!(Org, acme_org_id()))
    user
  end

  defp as_user(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp federated_agent!(user) do
    n = System.unique_integer([:positive])
    {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: "owner-test-#{n}"})

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "owner-test-#{n}",
        name: "Owner Agent #{n}",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert()

    {agent, runtime}
  end
end
