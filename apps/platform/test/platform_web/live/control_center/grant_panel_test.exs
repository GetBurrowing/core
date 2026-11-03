defmodule PlatformWeb.ControlCenter.GrantPanelTest do
  @moduledoc """
  Task 01a1a2e4-9265 stage 3: an org admin lifts an owner cap from the capped
  row through the Grant panel, and a member owner cannot, even by pushing the
  event directly. The server-side proof is that a pushed
  `grant_capped_permission` from a member writes no `access_role_assignments`
  row; hiding the button alone would not pass.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.{Role, RoleAssignment, Roles, RuntimeProfiles}
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
  alias Platform.Federation.ToolAuthorization
  alias Platform.Repo
  alias Platform.Tenancy.Org

  @capped ~s([data-role="bundle-capped-line"][data-bundle="prototype"])
  @hint ~s([data-role="bundle-inherited-hint"][data-bundle="prototype"])
  @grant_button ~s([data-role="bundle-grant-button"][data-bundle="prototype"])
  @owner_required "The owner must get the role: an agent&#39;s own roles never lift its owner&#39;s cap."

  setup %{conn: conn} do
    owner = user!("member")
    admin = user!("admin")
    {agent, runtime} = federated_agent!(owner, ["prototype", "task"])
    %{conn: conn, owner: owner, admin: admin, agent: agent, runtime: runtime}
  end

  defp user!(role) do
    user = World.create_user!()
    World.plain_member!(user, Repo.get!(Org, acme_org_id()), role)
    Repo.get!(Platform.Accounts.User, user.id)
  end

  defp as_user(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp federated_agent!(owner, modules) do
    n = System.unique_integer([:positive])
    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "grant-panel-#{n}"})

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "grant-panel-#{n}",
        name: "Grant Agent #{n}",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert()

    runtime = runtime |> AgentRuntime.changeset(%{agent_id: agent.id}) |> Repo.update!()
    {:ok, _} = RuntimeProfiles.set_tool_profile(runtime, modules)
    {agent, runtime}
  end

  defp publisher!(name \\ nil) do
    {:ok, role} =
      Roles.create_custom_role(acme_org_id(), %{
        name: name || "Prototype publisher #{System.unique_integer([:positive])}",
        permissions: %{
          "prototypes.read" => "membership_org",
          "prototypes.publish" => "membership_org"
        }
      })

    role
  end

  defp assignments_count, do: Repo.aggregate(RoleAssignment, :count)

  defp open_panel(view) do
    view |> element(@grant_button) |> render_click()
    assert has_element?(view, ~s([data-role="grant-panel"]))
  end

  test "existing role: assigns owner and agent, re-renders the row granted, flashes Granted.",
       ctx do
    role = publisher!()
    {:ok, view, _} = live(as_user(ctx.conn, ctx.admin), ~p"/control/#{ctx.agent.slug}")

    assert has_element?(view, @capped)
    refute has_element?(view, ~s([data-role="bundle-ask-admin"][data-bundle="prototype"]))
    open_panel(view)

    assert has_element?(
             view,
             ~s([data-role="grant-panel"]),
             "Give #{ctx.owner.name} and this agent:"
           )

    refute has_element?(view, ~s([data-role="grant-path-existing"][disabled]))
    assert has_element?(view, ~s([data-role="grant-applies-owner"][checked]))
    assert has_element?(view, ~s([data-role="grant-applies-agent"][checked]))

    html =
      view
      |> form("#grant-form", %{
        "path" => "existing",
        "role_key" => role.key,
        "owner" => "true",
        "agent" => "true"
      })
      |> render_submit()

    assert html =~ "Granted."
    refute has_element?(view, ~s([data-role="grant-panel"]))
    refute has_element?(view, @capped)
    assert has_element?(view, @hint)

    rows =
      Repo.all(from(a in RoleAssignment, where: a.role_key == ^role.key))
      |> Enum.map(&{&1.principal_type, &1.principal_id})
      |> MapSet.new()

    assert rows == MapSet.new([{"user", ctx.owner.id}, {"agent", ctx.agent.id}])
    assert :ok = ToolAuthorization.authorize("prototype_publish", Repo.reload!(ctx.runtime))
  end

  test "new role: created in the owner's org with membership_org rules", ctx do
    {:ok, view, _} = live(as_user(ctx.conn, ctx.admin), ~p"/control/#{ctx.agent.slug}")
    open_panel(view)

    assert has_element?(view, ~s([data-role="grant-path-existing"][disabled]))
    assert render(view) =~ "No existing role has this permission"
    assert has_element?(view, ~s([data-role="grant-path-new"][checked]))
    # The missing permission is pre-checked; its sibling is offered.
    assert has_element?(
             view,
             ~s([data-role="grant-new-permission"] input[value="prototypes.publish"][checked])
           )

    assert has_element?(
             view,
             ~s([data-role="grant-new-permission"] input[value="prototypes.read"])
           )

    name = "Publishers #{System.unique_integer([:positive])}"

    html =
      view
      |> form("#grant-form", %{
        "path" => "new",
        "name" => name,
        "permissions" => ["prototypes.publish", "prototypes.read"],
        "owner" => "true",
        "agent" => "true"
      })
      |> render_submit()

    assert html =~ "Granted."
    role = Repo.one!(from(r in Role, where: r.name == ^name))
    assert role.org_id == acme_org_id()

    assert role.permissions == %{
             "prototypes.publish" => "membership_org",
             "prototypes.read" => "membership_org"
           }

    assert :ok = ToolAuthorization.authorize("prototype_publish", Repo.reload!(ctx.runtime))
    assert has_element?(view, @hint)
  end

  test "owner unchecked: grant-error with the owner_required copy and nothing written", ctx do
    role = publisher!()
    {:ok, view, _} = live(as_user(ctx.conn, ctx.admin), ~p"/control/#{ctx.agent.slug}")
    open_panel(view)
    roles_before = Repo.aggregate(Role, :count)
    before = assignments_count()

    html =
      view
      |> form("#grant-form", %{
        "path" => "existing",
        "role_key" => role.key,
        "owner" => "false",
        "agent" => "true"
      })
      |> render_submit()

    assert has_element?(view, ~s([data-role="grant-error"].text-error))
    assert html =~ @owner_required
    assert has_element?(view, ~s([data-role="grant-panel"]))
    assert assignments_count() == before
    assert Repo.aggregate(Role, :count) == roles_before
    assert {:error, :forbidden} = ToolAuthorization.authorize("prototype_publish", ctx.runtime)
  end

  test "a member owner pushing grant_capped_permission directly is refused and writes nothing",
       ctx do
    role = publisher!()
    {:ok, view, _} = live(as_user(ctx.conn, ctx.owner), ~p"/control/#{ctx.agent.slug}")
    refute has_element?(view, @grant_button)
    before = assignments_count()

    html =
      render_hook(view, "grant_capped_permission", %{
        "bundle" => "prototype",
        "permission" => "prototypes.publish",
        "path" => "existing",
        "role_key" => role.key,
        "owner" => "true",
        "agent" => "true"
      })

    assert html =~ "Only an org admin can grant this."
    assert assignments_count() == before

    html =
      render_hook(view, "open_grant_panel", %{
        "bundle" => "prototype",
        "permission" => "prototypes.publish"
      })

    assert html =~ "Only an org admin can grant this."
    refute has_element?(view, ~s([data-role="grant-panel"]))
    assert assignments_count() == before
    assert {:error, :forbidden} = ToolAuthorization.authorize("prototype_publish", ctx.runtime)
  end
end
