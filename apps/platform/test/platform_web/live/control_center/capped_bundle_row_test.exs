defmodule PlatformWeb.ControlCenter.CappedBundleRowTest do
  @moduledoc """
  Task 01a1a2e4-9265 stage 2: the agent page's tool-profile rows show the
  owner cap honestly. A bundle that is on but capped by its owner carries a
  warning line naming the owner and the missing permission; a bundle that is
  on and not capped carries the "Inherited from owner" hint; an off bundle
  carries neither. Asserted by data-role, not by copy alone.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.{Roles, RuntimeProfiles}
  alias Platform.Agents.Agent
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tenancy.Org

  @capped ~s([data-role="bundle-capped-line"][data-bundle="prototype"])
  @hint ~s([data-role="bundle-inherited-hint"][data-bundle="prototype"])
  @ask ~s([data-role="bundle-ask-admin"][data-bundle="prototype"])

  defp user!(role) do
    user = World.create_user!()
    World.plain_member!(user, Repo.get!(Org, acme_org_id()), role)
    Repo.get!(Platform.Accounts.User, user.id)
  end

  defp as_user(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp federated_agent!(owner, modules) do
    n = System.unique_integer([:positive])
    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "capped-row-#{n}"})

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "capped-row-#{n}",
        name: "Capped Row Agent #{n}",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert()

    {:ok, _} = RuntimeProfiles.set_tool_profile(runtime, modules)
    {agent, runtime}
  end

  test "a member owner sees the capped line, the ask-admin note and no Grant button", %{
    conn: conn
  } do
    owner = user!("member")
    {agent, _runtime} = federated_agent!(owner, ["prototype", "task"])

    {:ok, view, _html} = live(as_user(conn, owner), ~p"/control/#{agent.slug}")

    assert has_element?(view, @capped)
    line = view |> element(@capped) |> render()
    assert line =~ owner.name
    assert line =~ "On, but capped:"
    assert line =~ "doesn&#39;t have &quot;Publish prototypes&quot;"
    assert line =~ ~s(data-permission="prototypes.publish")
    assert line =~ "hero-exclamation-triangle"
    assert line =~ "text-warning"

    assert view
           |> element(@capped <> ~s( [data-role="capped-permission-key"]))
           |> render() =~ "prototypes.publish"

    assert has_element?(view, @ask, "Ask an org admin to grant this")
    refute has_element?(view, ~s([data-role="bundle-grant-button"]))
    refute has_element?(view, @hint)

    # tasks.* are member permissions: that bundle is on and not capped.
    assert has_element?(view, ~s([data-role="bundle-inherited-hint"][data-bundle="task"]))
    refute has_element?(view, ~s([data-role="bundle-capped-line"][data-bundle="task"]))
  end

  test "an admin-owned agent shows the inherited hint and no capped line", %{conn: conn} do
    owner = user!("admin")
    {agent, _runtime} = federated_agent!(owner, ["prototype"])

    {:ok, view, _html} = live(as_user(conn, owner), ~p"/control/#{agent.slug}")

    assert has_element?(view, @hint, "Inherited from owner")
    assert view |> element(@hint) |> render() =~ "text-info"
    refute has_element?(view, @capped)
    refute has_element?(view, @ask)
  end

  test "a module that is off shows neither line", %{conn: conn} do
    owner = user!("member")
    {agent, _runtime} = federated_agent!(owner, ["task"])

    {:ok, view, _html} = live(as_user(conn, owner), ~p"/control/#{agent.slug}")

    refute has_element?(view, @capped)
    refute has_element?(view, @hint)
    refute has_element?(view, @ask)
  end

  test "after the owner is assigned a publishing role, the row re-renders as inherited", %{
    conn: conn
  } do
    owner = user!("member")
    {agent, _runtime} = federated_agent!(owner, ["prototype"])

    {:ok, view, _html} = live(as_user(conn, owner), ~p"/control/#{agent.slug}")
    assert has_element?(view, @capped)

    {:ok, role} =
      Roles.create_custom_role(acme_org_id(), %{
        name: "Prototype publisher #{System.unique_integer([:positive])}",
        permissions: %{"prototypes.publish" => "membership_org"}
      })

    {:ok, _} = Roles.assign(%{principal: owner, role: role})

    {:ok, view, _html} = live(as_user(conn, owner), ~p"/control/#{agent.slug}")
    refute has_element?(view, @capped)
    assert has_element?(view, @hint)
  end

  test "a viewer without manage rights sees the cap in the chip view too", %{conn: conn} do
    owner = user!("member")
    other = user!("member")
    {agent, _runtime} = federated_agent!(owner, ["prototype"])

    {:ok, view, _html} = live(as_user(conn, other), ~p"/control/#{agent.slug}")

    refute has_element?(view, "form[phx-submit=save_tool_profile]")
    assert has_element?(view, @capped)
    assert view |> element(@capped) |> render() =~ owner.name
    assert has_element?(view, @ask)
    refute has_element?(view, @hint)
  end
end
