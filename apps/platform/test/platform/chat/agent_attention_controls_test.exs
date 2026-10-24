defmodule Platform.Chat.AgentAttentionControlsTest do
  @moduledoc """
  Task 01a1557a-8f80 stage 1: the three writers a space member uses to
  control its agents (`Chat.set_agent_silenced/4`, `Chat.set_agents_awake/3`,
  `Chat.set_agent_attention_policy/3`), the read `Chat.agent_attention_state/1`,
  and the migration backfill that keeps every existing space on today's
  routing.

  Every refusal test has a positive control on the SAME space and target,
  varying only the actor or the id, so a writer that refused everything
  could not pass.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, Participant, Space}
  alias Platform.Repo

  setup do
    store =
      Process.whereis(ActiveAgentStore) ||
        start_supervised!({ActiveAgentStore, []})

    Sandbox.allow(Repo, self(), store)
    :ok
  end

  defp space!(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(Map.merge(%{name: "S#{n}", slug: "s-#{n}"}, attrs))
    space
  end

  defp member!(space) do
    user_id = Ecto.UUID.generate()

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        display_name: "Member",
        joined_at: DateTime.utc_now()
      })

    {:user, user_id}
  end

  defp agent!(space, name) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "agent-#{System.unique_integer([:positive])}",
        name: name,
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert()

    {:ok, participant} = Chat.add_agent_participant(space.id, agent, display_name: name)
    {agent, participant}
  end

  defp silenced?(%Participant{id: id}), do: Repo.get!(Participant, id).silenced

  describe "set_agent_silenced/4" do
    test "persists both ways and broadcasts on the space topic" do
      space = space!()
      actor = member!(space)
      {_agent, p} = agent!(space, "Zip")
      :ok = Chat.PubSub.subscribe(space.id)

      assert {:ok, %Participant{silenced: true}} =
               Chat.set_agent_silenced(actor, space.id, p.id, true)

      assert silenced?(p)
      space_id = space.id
      assert_receive {:agent_attention_changed, ^space_id}

      assert {:ok, %Participant{silenced: false}} =
               Chat.set_agent_silenced(actor, space.id, p.id, false)

      refute silenced?(p)
      assert_receive {:agent_attention_changed, ^space_id}
    end

    test "silencing the mutex holder clears the mutex; silencing another agent does not" do
      space = space!()
      actor = member!(space)
      {_a, holder} = agent!(space, "Zip")
      {_b, other} = agent!(space, "Nova")

      ActiveAgentStore.set_active(space.id, holder.id)
      {:ok, _} = Chat.set_agent_silenced(actor, space.id, other.id, true)
      assert ActiveAgentStore.get_active(space.id) == holder.id

      {:ok, _} = Chat.set_agent_silenced(actor, space.id, holder.id, true)
      assert ActiveAgentStore.get_active(space.id) == nil
    end

    test "a non-participant user is refused; a participant on the same agent is not" do
      space = space!()
      member = member!(space)
      {_agent, p} = agent!(space, "Zip")

      assert {:error, :forbidden} =
               Chat.set_agent_silenced({:user, Ecto.UUID.generate()}, space.id, p.id, true)

      refute silenced?(p)

      # POSITIVE CONTROL: same space, same agent, a member.
      assert {:ok, _} = Chat.set_agent_silenced(member, space.id, p.id, true)
      assert silenced?(p)
    end

    test "an agent actor is refused, even the agent itself" do
      space = space!()
      member = member!(space)
      {agent, p} = agent!(space, "Zip")
      {:ok, _} = Chat.set_agent_silenced(member, space.id, p.id, true)

      assert {:error, :forbidden} =
               Chat.set_agent_silenced({:agent, agent.id}, space.id, p.id, false)

      assert silenced?(p)
    end

    test "a participant id from ANOTHER space is not_found and changes nothing" do
      space = space!()
      other_space = space!()
      actor = member!(space)
      _other_member = member!(other_space)
      {_agent, foreign} = agent!(other_space, "Zip")
      {_agent2, own} = agent!(space, "Nova")

      assert {:error, :not_found} = Chat.set_agent_silenced(actor, space.id, foreign.id, true)
      refute silenced?(foreign)

      # A user participant row of this space is not an agent either.
      user_row = Repo.get_by!(Participant, space_id: space.id, participant_type: "user")
      assert {:error, :not_found} = Chat.set_agent_silenced(actor, space.id, user_row.id, true)
      assert {:error, :not_found} = Chat.set_agent_silenced(actor, space.id, "not-a-uuid", true)

      # POSITIVE CONTROL: this space's own agent.
      assert {:ok, _} = Chat.set_agent_silenced(actor, space.id, own.id, true)
    end
  end

  describe "set_agents_awake/3" do
    test "persists, broadcasts, and off clears the mutex without touching per-agent values" do
      space = space!()
      actor = member!(space)
      {_a, zip} = agent!(space, "Zip")
      {_b, nova} = agent!(space, "Nova")
      {:ok, _} = Chat.set_agent_silenced(actor, space.id, nova.id, true)
      ActiveAgentStore.set_active(space.id, zip.id)
      :ok = Chat.PubSub.subscribe(space.id)
      space_id = space.id

      assert Repo.get!(Space, space.id).agents_awake == true

      assert {:ok, %Space{agents_awake: false}} = Chat.set_agents_awake(actor, space.id, false)
      assert Repo.get!(Space, space.id).agents_awake == false
      assert_receive {:agent_attention_changed, ^space_id}
      assert ActiveAgentStore.get_active(space.id) == nil
      refute silenced?(zip)
      assert silenced?(nova)

      assert {:ok, %Space{agents_awake: true}} = Chat.set_agents_awake(actor, space.id, true)
      assert Repo.get!(Space, space.id).agents_awake == true
      assert_receive {:agent_attention_changed, ^space_id}
      refute silenced?(zip)
      assert silenced?(nova)
    end

    test "a non-participant and an agent actor are refused; a member is not" do
      space = space!()
      member = member!(space)
      {agent, _p} = agent!(space, "Zip")

      assert {:error, :forbidden} =
               Chat.set_agents_awake({:user, Ecto.UUID.generate()}, space.id, false)

      assert {:error, :forbidden} = Chat.set_agents_awake({:agent, agent.id}, space.id, false)
      assert Repo.get!(Space, space.id).agents_awake == true

      assert {:ok, _} = Chat.set_agents_awake(member, space.id, false)
      assert Repo.get!(Space, space.id).agents_awake == false
    end
  end

  describe "set_agent_attention_policy/3" do
    test "persists each policy on a channel and a group, and broadcasts" do
      for kind <- ~w(channel group) do
        space = space!(%{kind: kind})
        actor = member!(space)
        :ok = Chat.PubSub.subscribe(space.id)
        space_id = space.id

        for policy <- ~w(directed collaborative on_mention) do
          assert {:ok, %Space{agent_attention_policy: ^policy}} =
                   Chat.set_agent_attention_policy(actor, space.id, policy)

          assert Repo.get!(Space, space.id).agent_attention_policy == policy
          assert_receive {:agent_attention_changed, ^space_id}
        end
      end
    end

    test "dm and execution spaces are not_applicable" do
      for kind <- ~w(dm execution) do
        space = space!(%{kind: kind})
        actor = member!(space)

        assert {:error, :not_applicable} =
                 Chat.set_agent_attention_policy(actor, space.id, "collaborative")

        assert Repo.get!(Space, space.id).agent_attention_policy == nil
      end
    end

    test "an unknown value is a changeset error and the stored value stays" do
      space = space!()
      actor = member!(space)
      {:ok, _} = Chat.set_agent_attention_policy(actor, space.id, "directed")

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Chat.set_agent_attention_policy(actor, space.id, "everyone")

      assert Keyword.has_key?(errors, :agent_attention_policy)
      assert Repo.get!(Space, space.id).agent_attention_policy == "directed"
    end

    test "a non-participant and an agent actor are refused; a member is not" do
      space = space!()
      member = member!(space)
      {agent, _p} = agent!(space, "Zip")

      assert {:error, :forbidden} =
               Chat.set_agent_attention_policy(
                 {:user, Ecto.UUID.generate()},
                 space.id,
                 "directed"
               )

      assert {:error, :forbidden} =
               Chat.set_agent_attention_policy({:agent, agent.id}, space.id, "directed")

      assert Repo.get!(Space, space.id).agent_attention_policy == nil

      assert {:ok, _} = Chat.set_agent_attention_policy(member, space.id, "directed")
    end

    test "Space.changeset/2 does not cast the two attention columns" do
      changeset =
        Space.changeset(%Space{}, %{
          kind: "channel",
          name: "x",
          slug: "x",
          agents_awake: false,
          agent_attention_policy: "collaborative"
        })

      refute Map.has_key?(changeset.changes, :agents_awake)
      refute Map.has_key?(changeset.changes, :agent_attention_policy)
    end
  end

  describe "agent_attention_state/1" do
    test "reports the switch, the stored and effective policy, and every agent by name" do
      space = space!(%{kind: "group"})
      actor = member!(space)
      {zip_agent, zip} = agent!(space, "Zip")
      {nova_agent, nova} = agent!(space, "Nova")
      {:ok, _} = Chat.set_agent_silenced(actor, space.id, zip.id, true)

      state = Chat.agent_attention_state(space.id)
      slots = Chat.agent_slot_map_for_participants([zip, nova])

      assert %{agents_awake: true, policy: nil, effective_policy: "collaborative"} = state

      assert state.agents == [
               %{
                 participant_id: nova.id,
                 agent_id: nova_agent.id,
                 name: "Nova",
                 slot: Map.fetch!(slots, nova.id),
                 silenced: false
               },
               %{
                 participant_id: zip.id,
                 agent_id: zip_agent.id,
                 name: "Zip",
                 slot: Map.fetch!(slots, zip.id),
                 silenced: true
               }
             ]

      {:ok, _} = Chat.set_agent_attention_policy(actor, space.id, "directed")
      {:ok, _} = Chat.set_agents_awake(actor, space.id, false)

      assert %{agents_awake: false, policy: "directed", effective_policy: "directed"} =
               Chat.agent_attention_state(space.id)
    end

    test "a channel with no stored policy is on_mention; an unknown space is nil" do
      space = space!()

      assert %{policy: nil, effective_policy: "on_mention", agents: []} =
               Chat.agent_attention_state(space.id)

      assert Chat.agent_attention_state(Ecto.UUID.generate()) == nil
    end
  end

  # The suite migrates an EMPTY database, so the backfill UPDATE matches zero
  # rows there and a deleted clause would look identical to a correct one.
  # This runs the shipped migration's `down/0` then `up/0` inside the test's
  # sandbox transaction (Postgres DDL is transactional, so the rollback at the
  # end of the test restores the schema), with rows seeded in between in the
  # pre-migration shape. Same technique as
  # `test/platform/repo/migrations/backfill_channel_creator_admin_test.exs`.
  describe "migration backfill" do
    @migration Platform.Repo.Migrations.AgentAttentionControls
    @migration_path Path.expand(
                      "../../../priv/repo/migrations/20261024170000_agent_attention_controls.exs",
                      __DIR__
                    )

    defp run_migration!(operation) do
      unless Code.ensure_loaded?(@migration), do: Code.require_file(@migration_path)

      {:ok, runner} =
        Ecto.Migration.Runner.start_link(
          {self(), Repo, Repo.config(), @migration, :forward, operation,
           %{level: false, sql: false}}
        )

      Ecto.Migration.Runner.metadata(runner, [])
      apply(@migration, operation, [])
      Ecto.Migration.Runner.flush()
      Ecto.Migration.Runner.stop()
      :ok
    end

    defp insert_legacy_space!(kind, watch_enabled) do
      id = Ecto.UUID.generate()
      n = System.unique_integer([:positive])

      Repo.query!(
        """
        INSERT INTO chat_spaces (id, name, slug, kind, watch_enabled, is_direct, metadata,
                                 inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, '{}'::jsonb, now(), now())
        """,
        [Ecto.UUID.dump!(id), "Legacy #{n}", "legacy-#{n}", kind, watch_enabled, kind == "dm"]
      )

      id
    end

    defp read_back(id) do
      %{rows: [[policy, awake]]} =
        Repo.query!(
          "SELECT agent_attention_policy, agents_awake FROM chat_spaces WHERE id = $1",
          [Ecto.UUID.dump!(id)]
        )

      {policy, awake}
    end

    test "pre-existing channel and group rows read on_mention; dm and execution stay NULL; every row is awake" do
      :ok = run_migration!(:down)

      group = insert_legacy_space!("group", false)
      channel = insert_legacy_space!("channel", false)
      dm = insert_legacy_space!("dm", true)
      execution = insert_legacy_space!("execution", false)

      :ok = run_migration!(:up)

      assert read_back(group) == {"on_mention", true}
      assert read_back(channel) == {"on_mention", true}
      assert read_back(dm) == {nil, true}
      assert read_back(execution) == {nil, true}

      # The CHECK constraint is live after `up/0`.
      assert_raise Postgrex.Error, ~r/chat_spaces_agent_attention_policy_check/, fn ->
        Repo.query!(
          "UPDATE chat_spaces SET agent_attention_policy = 'everyone' WHERE id = $1",
          [Ecto.UUID.dump!(group)]
        )
      end
    end
  end
end
