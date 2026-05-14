defmodule Platform.Chat.AdHocFreezeListenerTest do
  @moduledoc """
  Tests the consumer side of Decision D-6 — `AdHocFreezeListener` reacts
  to `{:agent_first_state_op, agent_participant_id, space_id}` signals on
  the `chat:agent_runtime` topic by atomically freezing every in-context
  message for the agent.

  See `apps/platform/audit/2026-05-13-policy-2-freeze-trigger/design.md`
  for the architecture rationale (Stage 4 of task
  `019e1e80-4230-7a79-ac73-c157975b3999`).

  Test strategy: rather than starting the real GenServer (which is in the
  Application supervision tree and would race with sandbox checkout), we
  drive `handle_info/2` directly. This isolates the consumer contract
  cleanly and avoids `:meck` / global supervision-tree mutation.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.AdHocFreezeListener
  alias Platform.Chat.Message
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp unique_int, do: System.unique_integer([:positive, :monotonic])

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "AdHoc Test #{unique_int()}",
        slug: "adhoc-#{unique_int()}"
      })

    project
  end

  defp open_task_for_agent(project, agent_id) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Open task",
        status: "planning",
        assignee_type: "agent",
        assignee_id: agent_id
      })

    task
  end

  defp seed_exec_space_with_agent(task, agent_id, display_name \\ "Saru") do
    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    {:ok, agent_p} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent_id,
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: "Author"
      })

    {space, agent_p, author}
  end

  defp post_message!(space_id, participant_id, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    msg
  end

  # ── Happy path — freeze fires on :agent_first_state_op ────────────────────

  describe "handle_info({:agent_first_state_op, …}) — freeze fires" do
    test "freezes in-context messages for the agent and broadcasts post-commit" do
      project = create_project()
      agent_id = Ecto.UUID.generate()
      task = open_task_for_agent(project, agent_id)
      {space, agent_p, author} = seed_exec_space_with_agent(task, agent_id, "Saru")

      # Two unfrozen messages in the agent's task-linked exec space →
      # both are in-context per the Stage 2 predicate's task arm.
      msg1 = post_message!(space.id, author.id, "first chatter")
      msg2 = post_message!(space.id, author.id, "second chatter, no mention")

      ChatPubSub.subscribe(space.id)

      # Drive the consumer contract directly.
      {:noreply, _state} =
        AdHocFreezeListener.handle_info(
          {:agent_first_state_op, agent_p.id, space.id},
          %{}
        )

      # Both messages are now frozen, with the agent's participant as the actor.
      r1 = Repo.get!(Message, msg1.id)
      r2 = Repo.get!(Message, msg2.id)
      assert %DateTime{} = r1.frozen_at
      assert %DateTime{} = r2.frozen_at
      assert r1.frozen_by_participant_id == agent_p.id
      assert r2.frozen_by_participant_id == agent_p.id

      # Broadcast arrived on the space topic with the expected shape +
      # reason. Order of ids in the list is not guaranteed (depends on the
      # Repo query order), so assert as a set.
      assert_receive {:messages_frozen, ids, meta}, 1_000
      assert meta.reason == :agent_first_state_op
      assert meta.agent_participant_id == agent_p.id
      assert meta.space_id == space.id
      assert MapSet.new(ids) == MapSet.new([msg1.id, msg2.id])
    end

    test "already-frozen messages are not re-frozen (idempotent)" do
      project = create_project()
      agent_id = Ecto.UUID.generate()
      task = open_task_for_agent(project, agent_id)
      {space, agent_p, author} = seed_exec_space_with_agent(task, agent_id)

      msg = post_message!(space.id, author.id, "already-frozen target")

      # Pre-freeze with a different real participant so we can detect
      # whether the audit got overwritten.
      {:ok, other} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          joined_at: DateTime.utc_now(),
          display_name: "PriorFreezer"
        })

      original_frozen_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      msg
      |> Message.changeset(%{
        frozen_at: original_frozen_at,
        frozen_by_participant_id: other.id
      })
      |> Repo.update!()

      {:noreply, _} =
        AdHocFreezeListener.handle_info(
          {:agent_first_state_op, agent_p.id, space.id},
          %{}
        )

      refreshed = Repo.get!(Message, msg.id)
      # First-freezer audit preserved; ad-hoc trigger did NOT overwrite.
      assert refreshed.frozen_by_participant_id == other.id
      assert DateTime.compare(refreshed.frozen_at, original_frozen_at) == :eq
    end
  end

  # ── Negative case — non-state-changing signals do NOT freeze ──────────────

  describe "handle_info(non-state-op tuple) — ignored, no freeze" do
    test ":agent_read_op signal does not freeze any messages" do
      project = create_project()
      agent_id = Ecto.UUID.generate()
      task = open_task_for_agent(project, agent_id)
      {space, _agent_p, author} = seed_exec_space_with_agent(task, agent_id)

      msg = post_message!(space.id, author.id, "in-scope but agent only read")

      # Fire a non-:agent_first_state_op tuple — same topic, different tag.
      {:noreply, _} =
        AdHocFreezeListener.handle_info(
          {:agent_read_op, agent_id, space.id},
          %{}
        )

      assert is_nil(Repo.get!(Message, msg.id).frozen_at)
    end

    test "arbitrary non-matching message is silently ignored" do
      project = create_project()
      agent_id = Ecto.UUID.generate()
      task = open_task_for_agent(project, agent_id)
      {space, _agent_p, author} = seed_exec_space_with_agent(task, agent_id)

      msg = post_message!(space.id, author.id, "should stay unfrozen")

      {:noreply, _} = AdHocFreezeListener.handle_info(:some_unrelated_atom, %{})
      {:noreply, _} = AdHocFreezeListener.handle_info({:other, "tuple", :foo}, %{})

      assert is_nil(Repo.get!(Message, msg.id).frozen_at)
    end
  end

  # ── Out-of-scope agent — no in-context messages → no-op broadcast ─────────

  describe "handle_info(:agent_first_state_op) — agent has no in-context messages" do
    test "no messages frozen and no broadcast when in-context set is empty" do
      # Bystander agent: NOT mentioned in any message, NOT assigned to any
      # task linked to the queried space.
      project = create_project()
      bystander_agent_id = Ecto.UUID.generate()
      assignee_agent_id = Ecto.UUID.generate()
      task = open_task_for_agent(project, assignee_agent_id)
      {space, _assignee_p, author} = seed_exec_space_with_agent(task, assignee_agent_id)

      {:ok, bystander_p} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: bystander_agent_id,
          joined_at: DateTime.utc_now(),
          display_name: "Bystander"
        })

      msg = post_message!(space.id, author.id, "no bystander mention here")

      ChatPubSub.subscribe(space.id)

      {:noreply, _} =
        AdHocFreezeListener.handle_info(
          {:agent_first_state_op, bystander_p.id, space.id},
          %{}
        )

      # Bystander's first-state-op produces empty in-context set, so the
      # message stays unfrozen and no broadcast fires.
      assert is_nil(Repo.get!(Message, msg.id).frozen_at)
      refute_received {:messages_frozen, _, _}
    end
  end
end
