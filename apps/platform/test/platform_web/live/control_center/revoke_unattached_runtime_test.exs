defmodule PlatformWeb.ControlCenter.RevokeUnattachedRuntimeTest do
  @moduledoc """
  Task 01a1b84c stage 1: the "revoke_unattached_runtime" Control Center
  event. Gated by admin (`Access.Agents.may_create_ownerless?/1`), it revokes
  only a row `Federation.unattached_runtime?/1` accepts, frees the runtime_id
  for reuse, and never touches an attached runtime whatever id is sent.

  Orphans are built with `Repo.delete!/1` on the agent row (FK
  `on_delete: :nilify_all`), never through `AgentData.delete_agent/1`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Agents.AgentRuntime
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tenancy.Org

  defp member! do
    user = World.create_user!()
    World.plain_member!(user, Repo.get!(Org, acme_org_id()))
    user
  end

  defp as_user(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp rid, do: "gateway-example-#{System.unique_integer([:positive])}"

  defp attached!(owner, runtime_id) do
    n = System.unique_integer([:positive])

    {:ok, agent, runtime, _token} =
      Federation.provision_agent_runtime(
        owner.id,
        %{slug: "revoke-unatt-#{n}", name: "Revoke Unattached #{n}", status: "active"},
        %{runtime_id: runtime_id, tool_profile: AgentRuntime.default_tool_profile()}
      )

    {agent, runtime}
  end

  defp orphan!(owner, runtime_id) do
    {agent, runtime} = attached!(owner, runtime_id)
    Repo.delete!(agent)
    Federation.get_runtime(runtime.id)
  end

  test "an admin revokes an orphan, its token hash is cleared and the runtime_id can be registered again",
       %{conn: conn} do
    owner = member!()
    runtime_id = rid()
    orphan = orphan!(owner, runtime_id)
    assert orphan.auth_token_hash

    admin = root_admin!()
    {:ok, view, _} = live(as_user(conn, admin), ~p"/control")

    assert render_click(view, "revoke_unattached_runtime", %{"id" => orphan.id}) =~
             "Runtime revoked."

    revoked = Federation.get_runtime(orphan.id)
    assert revoked.status == "revoked"
    assert revoked.auth_token_hash == nil
    refute Federation.unattached_runtime?(revoked)

    assert {:ok, reused} = Federation.register_runtime(member!().id, %{runtime_id: runtime_id})
    assert reused.id == orphan.id
    assert reused.status == "pending"
  end

  test "an org member without agents.manage_all is refused by policy and the orphan stays active",
       %{conn: conn} do
    orphan = orphan!(member!(), rid())

    {:ok, view, _} = live(as_user(conn, member!()), ~p"/control")

    assert render_click(view, "revoke_unattached_runtime", %{"id" => orphan.id}) =~
             "Only admins can revoke unattached runtimes."

    row = Federation.get_runtime(orphan.id)
    assert row.status == "active"
    assert row.auth_token_hash == orphan.auth_token_hash
  end

  test "the event with an attached runtime's id leaves it active", %{conn: conn} do
    {_agent, runtime} = attached!(member!(), rid())

    {:ok, view, _} = live(as_user(conn, root_admin!()), ~p"/control")

    assert render_click(view, "revoke_unattached_runtime", %{"id" => runtime.id}) =~
             "That runtime is attached to an agent."

    row = Federation.get_runtime(runtime.id)
    assert row.status == "active"
    assert row.auth_token_hash == runtime.auth_token_hash
  end

  test "an unknown or malformed id is refused without a crash", %{conn: conn} do
    {:ok, view, _} = live(as_user(conn, root_admin!()), ~p"/control")

    assert render_click(view, "revoke_unattached_runtime", %{"id" => Ecto.UUID.generate()}) =~
             "Runtime not found."

    assert render_click(view, "revoke_unattached_runtime", %{"id" => "not-a-uuid"}) =~
             "Runtime not found."
  end
end
