defmodule Platform.Agents.NativeAgentsTransferOwnerTest do
  @moduledoc """
  `NativeAgents.transfer_owner/4` (task 01a1f42d stage 2): who may transfer,
  what is refused, the audit row, the previous owner's notification, and that
  management follows the new owner.

  Notifications are observed through the `:notify` option: in the test env
  `Platform.Notifications.fan_out_to_user/2` sends nothing and stores nothing,
  so the injected function messages the test process instead.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Agents.{AgentRuntime, NativeAgents}
  alias Platform.Audit.Event
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @event "platform.federation.runtime_owner_changed"

  defp create_user(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "transfer-#{label}-#{n}@example.com",
      name: "Transfer #{label} #{n}",
      oidc_sub: "oidc-transfer-#{label}-#{n}"
    })
  end

  defp with_role(label, role) do
    user = create_user(label)

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: role
    })
    |> Repo.insert!()

    user
  end

  defp admin!, do: with_role("admin", "admin")
  defp member!, do: with_role("member", "member")

  defp native!(owner) do
    {:ok, agent, runtime} =
      NativeAgents.create(owner.id, %{name: "Probe Agent", harness: "claude_code"})

    {agent, runtime}
  end

  defp notify_self do
    test = self()

    fn user_id, payload ->
      send(test, {:notified, user_id, payload})
      :ok
    end
  end

  defp owner_of(runtime), do: Repo.get!(AgentRuntime, runtime.id).owner_user_id

  defp owner_events(runtime) do
    Repo.all(
      from(e in Event,
        where: e.event_type == @event and e.resource_id == ^runtime.id,
        order_by: e.id
      )
    )
  end

  defp event_count, do: Repo.aggregate(Event, :count)

  describe "who may transfer" do
    test "the owner transfers, the row and audit event record it, the owner is not notified" do
      owner = member!()
      new_owner = member!()
      {agent, runtime} = native!(owner)

      assert {:ok, %AgentRuntime{owner_user_id: new_id}} =
               NativeAgents.transfer_owner(owner, agent, new_owner.id, notify: notify_self())

      assert new_id == new_owner.id
      assert owner_of(runtime) == new_owner.id

      assert [event] = owner_events(runtime)
      assert event.actor_type == "user"
      assert event.actor_id == owner.id
      assert event.resource_type == "agent_runtime"
      assert event.metadata["previous_owner_user_id"] == owner.id
      assert event.metadata["new_owner_user_id"] == new_owner.id
      assert event.metadata["runtime_id"] == runtime.id
      assert event.metadata["agent_id"] == agent.id

      # The actor is the previous owner: nobody to tell.
      refute_received {:notified, _, _}
    end

    test "an admin who is not the owner transfers and the previous owner is notified" do
      owner = member!()
      admin = admin!()
      new_owner = member!()
      {agent, runtime} = native!(owner)

      assert {:ok, _} =
               NativeAgents.transfer_owner(admin.id, agent, new_owner.id, notify: notify_self())

      assert owner_of(runtime) == new_owner.id
      assert [%{actor_id: actor_id}] = owner_events(runtime)
      assert actor_id == admin.id

      assert_received {:notified, notified_id, payload}
      assert notified_id == owner.id
      assert payload.url == "/control/#{agent.slug}"
      assert payload.body =~ agent.name
      assert payload.body =~ new_owner.name
      assert payload.body =~ admin.name
      refute_received {:notified, _, _}
    end

    # MUTATION PROBE (stage 2): replace the authorization check in
    # `authorize_transfer/2` with `true` (:ok) -> this test goes red on its
    # `{:error, :forbidden}` match.
    test "a plain member who is not the owner is forbidden and nothing changes" do
      owner = member!()
      member = member!()
      {agent, runtime} = native!(owner)
      events = event_count()

      assert {:error, :forbidden} =
               NativeAgents.transfer_owner(member, agent, member.id, notify: notify_self())

      assert owner_of(runtime) == owner.id
      assert event_count() == events
      assert owner_events(runtime) == []
      refute_received {:notified, _, _}
    end

    test "authorization comes first: a non-owner learns nothing from the other refusals" do
      owner = member!()
      member = member!()
      {agent, _runtime} = native!(owner)
      {fed_agent, _} = federated!(owner)

      assert {:error, :forbidden} = NativeAgents.transfer_owner(member, agent, owner.id)
      assert {:error, :forbidden} = NativeAgents.transfer_owner(member, agent, "not-a-uuid")
      assert {:error, :forbidden} = NativeAgents.transfer_owner(member, fed_agent, member.id)
    end

    test "a nil actor, or an actor id that is not a UUID, is forbidden" do
      owner = member!()
      new_owner = member!()
      {agent, runtime} = native!(owner)

      assert {:error, :forbidden} = NativeAgents.transfer_owner(nil, agent, new_owner.id)
      assert {:error, :forbidden} = NativeAgents.transfer_owner("system", agent, new_owner.id)
      assert {:error, :forbidden} = NativeAgents.transfer_owner(%{id: nil}, agent, new_owner.id)
      assert owner_of(runtime) == owner.id
      assert owner_events(runtime) == []
    end
  end

  describe "refusals that write nothing" do
    test ":not_managed for a federated agent, even for an admin" do
      owner = member!()
      admin = admin!()
      {agent, runtime} = federated!(owner)
      events = event_count()

      assert {:error, :not_managed} = NativeAgents.transfer_owner(admin, agent, admin.id)
      assert owner_of(runtime) == owner.id
      assert event_count() == events
    end

    test ":invalid_owner for a user outside the root org, an archived member, an unknown id" do
      owner = member!()
      outsider = create_user("outsider")
      archived = member!()

      {:ok, _} =
        archived
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
        |> Repo.update()

      {agent, runtime} = native!(owner)
      events = event_count()

      for target <- [outsider.id, archived.id, Ecto.UUID.generate(), "not-a-uuid", nil] do
        assert {:error, :invalid_owner} =
                 NativeAgents.transfer_owner(owner, agent, target, notify: notify_self()),
               "expected :invalid_owner for #{inspect(target)}"
      end

      assert owner_of(runtime) == owner.id
      assert event_count() == events
      refute_received {:notified, _, _}
    end

    test ":same_owner when the new owner already owns it" do
      owner = member!()
      {agent, runtime} = native!(owner)
      events = event_count()

      assert {:error, :same_owner} = NativeAgents.transfer_owner(owner, agent, owner.id)
      assert event_count() == events
      assert owner_of(runtime) == owner.id
    end
  end

  describe "after the transfer" do
    test "management follows the new owner: the old one fails can_manage?, the new one passes" do
      owner = member!()
      new_owner = member!()
      {agent, _runtime} = native!(owner)

      assert NativeAgents.can_manage?(owner, agent)
      refute NativeAgents.can_manage?(new_owner, agent)

      assert {:ok, _} = NativeAgents.transfer_owner(owner, agent, new_owner.id)

      refute NativeAgents.can_manage?(owner, agent)
      refute NativeAgents.can_manage?(owner.id, agent)
      assert NativeAgents.can_manage?(new_owner, agent)
      assert NativeAgents.can_manage?(new_owner.id, agent)

      # The previous owner can no longer transfer it back.
      assert {:error, :forbidden} = NativeAgents.transfer_owner(owner, agent, owner.id)
    end

    test "the owner cap follows the new owner" do
      owner = member!()
      new_owner = member!()
      {agent, runtime} = native!(owner)

      assert {:ok, _} = NativeAgents.transfer_owner(owner, agent, new_owner.id)

      scope = Platform.Access.Scope.for_runtime(Repo.get!(AgentRuntime, runtime.id))
      assert %{actor: %{id: id}} = scope.owner_cap
      assert id == new_owner.id
    end

    test "broadcasts the change on owner_topic/1 for live processes to re-read" do
      owner = member!()
      new_owner = member!()
      {agent, runtime} = native!(owner)
      Phoenix.PubSub.subscribe(Platform.PubSub, NativeAgents.owner_topic(runtime.runtime_id))

      assert {:ok, _} = NativeAgents.transfer_owner(owner, agent, new_owner.id)

      assert_received {:runtime_owner_changed, change}
      assert change.previous_owner_user_id == owner.id
      assert change.new_owner_user_id == new_owner.id
      assert change.runtime_id == runtime.runtime_id
    end

    test "a refused transfer broadcasts nothing" do
      owner = member!()
      member = member!()
      {agent, runtime} = native!(owner)
      Phoenix.PubSub.subscribe(Platform.PubSub, NativeAgents.owner_topic(runtime.runtime_id))

      assert {:error, :forbidden} = NativeAgents.transfer_owner(member, agent, member.id)
      refute_received {:runtime_owner_changed, _}
    end

    test "a failing notification is logged and the transfer stands" do
      owner = member!()
      admin = admin!()
      new_owner = member!()
      {agent, runtime} = native!(owner)

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   NativeAgents.transfer_owner(admin, agent, new_owner.id,
                     notify: fn _user_id, _payload -> raise "push down" end
                   )
        end)

      assert log =~ "push down"
      assert log =~ "the transfer stands"
      assert owner_of(runtime) == new_owner.id
      assert [_] = owner_events(runtime)
    end
  end

  describe "eligible_owners/0" do
    test "lists non-archived root-org members and nobody else" do
      member = member!()
      admin = admin!()
      outsider = create_user("outsider")
      archived = member!()

      {:ok, _} =
        archived
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
        |> Repo.update()

      ids = Enum.map(NativeAgents.eligible_owners(), & &1.id)
      assert member.id in ids
      assert admin.id in ids
      refute outsider.id in ids
      refute archived.id in ids
    end
  end

  defp federated!(owner) do
    n = System.unique_integer([:positive])

    {:ok, agent, runtime, _token} =
      Federation.provision_agent_runtime(
        owner.id,
        %{slug: "fed-transfer-#{n}", name: "Fed #{n}", status: "active"},
        %{runtime_id: "fed-transfer-rt-#{n}"}
      )

    {agent, runtime}
  end
end
