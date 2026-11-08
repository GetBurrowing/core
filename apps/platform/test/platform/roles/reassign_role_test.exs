defmodule Platform.Roles.ReassignRoleTest do
  @moduledoc """
  Task 01a1b741 stage 2: `Roles.reassign_role/2,3` moves a held role to
  another agent in one transaction, with one post-state broadcast.

  `async: false` because `roles:assignments` is a process-group
  broadcast that does not respect the Ecto sandbox: an async sibling
  assigning the same role would land in this mailbox and make the
  "exactly one frame" refutes a function of suite scheduling. Sync
  modules run after every async module has finished.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.Scope
  alias Platform.Agents.{Agent, Burrow}
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Roles.{Role, RoleAssignment}
  alias Platform.Tenancy.Org

  setup do
    previous_token = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "test-host-token")

    on_exit(fn ->
      if previous_token,
        do: Application.put_env(:platform, :agent_host_token, previous_token),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    for key <- Role.valid_keys(), do: :ok = Roles.unassign_role(key)

    {:ok, burrow} = Burrow.ensure(root_admin!().id, "claude_code")
    assert Roles.agent_id_for_role("designer") == burrow.id

    Roles.subscribe_assignments()
    on_exit(&Roles.unsubscribe_assignments/0)

    %{burrow: burrow, specialist: agent!("Sam-agent")}
  end

  defp agent!(name) do
    Repo.insert!(%Agent{
      slug: "reassign-#{System.unique_integer([:positive])}",
      name: name,
      status: "active"
    })
  end

  defp designer_rows do
    Repo.all(from(ra in RoleAssignment, where: ra.role_key == "designer"))
  end

  defp flush_assignment_frames do
    receive do
      {:role_assignment_changed, _} -> flush_assignment_frames()
    after
      0 -> :ok
    end
  end

  test "hands a role Burrow holds to a specialist in one step", %{
    burrow: burrow,
    specialist: specialist
  } do
    assert {:ok, %RoleAssignment{agent_id: sid}} =
             Roles.reassign_role("designer", specialist.id)

    assert sid == specialist.id
    assert Roles.agent_id_for_role("designer") == specialist.id
    refute "designer" in Enum.map(Roles.roles_for(burrow.id), & &1.key)
    assert "designer" in Enum.map(Roles.roles_for(specialist.id), & &1.key)
    assert [%RoleAssignment{agent_id: ^sid}] = designer_rows()

    # Burrow keeps the other nine.
    assert length(Roles.roles_for(burrow.id)) == length(Role.valid_keys()) - 1
  end

  test "sends exactly one post-state broadcast and never a nil frame", %{
    specialist: specialist
  } do
    flush_assignment_frames()
    sid = specialist.id

    assert {:ok, _} = Roles.reassign_role("designer", specialist.id)

    assert_receive {:role_assignment_changed, %{role_key: "designer", agent_id: ^sid}}
    refute_receive {:role_assignment_changed, %{role_key: "designer"}}, 100
  end

  test "a failing insert keeps the old holder and broadcasts nothing", %{burrow: burrow} do
    flush_assignment_frames()
    [before] = designer_rows()

    assert {:error, %Ecto.Changeset{} = changeset} =
             Roles.reassign_role("designer", Ecto.UUID.generate())

    assert {_, [constraint: :foreign, constraint_name: _]} = changeset.errors[:agent_id]

    assert Roles.agent_id_for_role("designer") == burrow.id
    assert [after_row] = designer_rows()
    assert after_row.id == before.id
    refute_receive {:role_assignment_changed, %{role_key: "designer"}}, 100
  end

  test "a same-agent reassign writes nothing and broadcasts nothing", %{burrow: burrow} do
    flush_assignment_frames()
    [before] = designer_rows()

    assert {:ok, %RoleAssignment{id: id}} = Roles.reassign_role("designer", burrow.id)
    assert id == before.id
    assert designer_rows() == [before]
    refute_receive {:role_assignment_changed, %{role_key: "designer"}}, 100
  end

  test "an unheld role behaves like assign: one row, one broadcast", %{specialist: specialist} do
    :ok = Roles.unassign_role("designer")
    flush_assignment_frames()
    sid = specialist.id

    assert {:ok, %RoleAssignment{agent_id: ^sid}} =
             Roles.reassign_role("designer", specialist.id)

    assert [%RoleAssignment{agent_id: ^sid}] = designer_rows()
    assert_receive {:role_assignment_changed, %{role_key: "designer", agent_id: ^sid}}
    refute_receive {:role_assignment_changed, %{role_key: "designer"}}, 100
  end

  test "assign_role/2 still refuses a held role", %{burrow: burrow, specialist: specialist} do
    assert {:error, %Ecto.Changeset{}} = Roles.assign_role("designer", specialist.id)
    assert Roles.agent_id_for_role("designer") == burrow.id
  end

  describe "actor clause" do
    setup do
      root = Repo.get!(Org, acme_org_id())
      owner = World.create_user!()
      World.plain_member!(owner, root)
      owner_scope = Scope.for_user(owner)

      # Ownerless (no runtime): only `agents.manage_all` may release it.
      ownerless_holder = agent!("Alex-agent")

      # Owned by `owner` through a federated runtime, so `owner` may assign it.
      owned = agent!("Owned-agent")

      {:ok, _runtime} =
        Federation.register_runtime(owner_scope, %{
          runtime_id: "reassign-rt-#{System.unique_integer([:positive])}",
          agent_id: owned.id
        })

      :ok = Roles.unassign_role("designer")
      {:ok, _} = Roles.assign_role("designer", ownerless_holder.id)
      flush_assignment_frames()

      %{
        owner_scope: owner_scope,
        root_scope: Scope.for_user(root_admin!()),
        holder: ownerless_holder,
        owned: owned
      }
    end

    test "a scope that may not release the current holder is refused and nothing changes", %{
      owner_scope: owner_scope,
      holder: holder,
      owned: owned
    } do
      [before] = designer_rows()

      assert {:error, :unauthorized} =
               Roles.reassign_role("designer", owned.id, actor: owner_scope)

      assert Roles.agent_id_for_role("designer") == holder.id
      assert designer_rows() == [before]
      refute_receive {:role_assignment_changed, %{role_key: "designer"}}, 100
    end

    test "a scope that may not assign the new agent is refused", %{
      owner_scope: owner_scope,
      root_scope: root_scope,
      holder: holder,
      owned: owned
    } do
      {:ok, _} = Roles.reassign_role("designer", owned.id, actor: root_scope)
      flush_assignment_frames()

      # owner may release `owned` but may not assign the ownerless holder.
      assert {:error, :unauthorized} =
               Roles.reassign_role("designer", holder.id, actor: owner_scope)

      assert Roles.agent_id_for_role("designer") == owned.id
      refute_receive {:role_assignment_changed, %{role_key: "designer"}}, 100
    end

    test "a scope that may do both hands the role over", %{
      root_scope: root_scope,
      owned: owned
    } do
      oid = owned.id

      assert {:ok, %RoleAssignment{agent_id: ^oid}} =
               Roles.reassign_role("designer", owned.id, actor: root_scope)

      assert Roles.agent_id_for_role("designer") == oid
      assert_receive {:role_assignment_changed, %{role_key: "designer", agent_id: ^oid}}
      refute_receive {:role_assignment_changed, %{role_key: "designer"}}, 100
    end
  end
end
