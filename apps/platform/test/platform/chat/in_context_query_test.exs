defmodule Platform.Chat.InContextQueryTest do
  @moduledoc """
  Tests for `Platform.Chat.in_context_message_ids_for_agent/2` — the
  shared query used by Policy 2 task-scoped + ad-hoc freeze triggers
  (task `019e1e80-4230-7a79-ac73-c157975b3999`).

  See `apps/platform/audit/2026-05-13-policy-2-freeze-trigger/design.md`
  for the rationale behind the two-arm union (mention + execution-space-
  task-linked).
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskRecord

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp unique_slug, do: "in-ctx-#{System.unique_integer([:positive, :monotonic])}"

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: unique_slug(), kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp create_execution_space(task_id) do
    {:ok, space} =
      Chat.create_space(%{
        name: "exec-#{task_id}",
        slug: "exec-#{unique_slug()}",
        kind: "execution",
        metadata: %{"task_id" => task_id}
      })

    space
  end

  defp create_agent_participant(space_id, display_name, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, Ecto.UUID.generate())

    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: agent_id,
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
  end

  defp create_user_participant(space_id, display_name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
  end

  defp post_message(space_id, participant_id, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    msg
  end

  defp create_task(attrs) do
    project_id = ensure_test_project()

    default = %{
      title: "T",
      status: "planning",
      assignee_type: "agent",
      project_id: project_id
    }

    %TaskRecord{}
    |> TaskRecord.changeset(Map.merge(default, attrs))
    |> Repo.insert!()
  end

  defp ensure_test_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "InCtxTest #{System.unique_integer([:positive, :monotonic])}",
        slug: "inctx-#{System.unique_integer([:positive, :monotonic])}"
      })

    project.id
  end

  # ── Mention arm ────────────────────────────────────────────────────────────

  describe "in_context_message_ids_for_agent/2 — mention arm" do
    test "agent mentioned via bracketed @[Display] form gets the message" do
      space = create_space()
      author = create_user_participant(space.id, "Author")
      agent = create_agent_participant(space.id, "Saru")

      msg = post_message(space.id, author.id, "Hey @[Saru] please look at this")

      ids = Chat.in_context_message_ids_for_agent(agent.id, space.id)

      assert MapSet.member?(ids, msg.id)
    end

    test "agent mentioned via legacy @name form gets the message" do
      space = create_space()
      author = create_user_participant(space.id, "Author")
      agent = create_agent_participant(space.id, "Saru")

      msg = post_message(space.id, author.id, "ping @saru can you check")

      ids = Chat.in_context_message_ids_for_agent(agent.id, space.id)

      assert MapSet.member?(ids, msg.id)
    end

    test "agent NOT mentioned and not task-assigned gets empty set" do
      space = create_space()
      author = create_user_participant(space.id, "Author")
      agent = create_agent_participant(space.id, "Saru")

      _msg = post_message(space.id, author.id, "general chatter, no mention")

      ids = Chat.in_context_message_ids_for_agent(agent.id, space.id)

      assert MapSet.size(ids) == 0
    end

    test "different agent's name in body does NOT match" do
      space = create_space()
      author = create_user_participant(space.id, "Author")
      saru = create_agent_participant(space.id, "Saru")
      _higgins = create_agent_participant(space.id, "Higgins")

      _msg = post_message(space.id, author.id, "@[Higgins] take a look")

      ids = Chat.in_context_message_ids_for_agent(saru.id, space.id)
      assert MapSet.size(ids) == 0
    end
  end

  # ── Task arm (execution-space-binding) ─────────────────────────────────────

  describe "in_context_message_ids_for_agent/2 — task arm" do
    test "agent assigned to open task linked to execution space sees all messages" do
      agent_id = Ecto.UUID.generate()
      task = create_task(%{status: "planning", assignee_id: agent_id})
      space = create_execution_space(task.id)
      author = create_user_participant(space.id, "Author")
      agent = create_agent_participant(space.id, "Saru", agent_id: agent_id)

      msg1 = post_message(space.id, author.id, "no mention, just chatter A")
      msg2 = post_message(space.id, author.id, "no mention, just chatter B")

      ids = Chat.in_context_message_ids_for_agent(agent.id, space.id)

      assert MapSet.member?(ids, msg1.id)
      assert MapSet.member?(ids, msg2.id)
    end

    test "agent assigned to in_progress task linked to execution space sees messages" do
      agent_id = Ecto.UUID.generate()
      task = create_task(%{status: "in_progress", assignee_id: agent_id})
      space = create_execution_space(task.id)
      author = create_user_participant(space.id, "Author")
      agent = create_agent_participant(space.id, "Saru", agent_id: agent_id)

      msg = post_message(space.id, author.id, "no mention, mid-work chatter")

      ids = Chat.in_context_message_ids_for_agent(agent.id, space.id)
      assert MapSet.member?(ids, msg.id)
    end

    test "closed (done) task is excluded — task arm returns empty" do
      agent_id = Ecto.UUID.generate()
      task = create_task(%{status: "done", assignee_id: agent_id})
      space = create_execution_space(task.id)
      author = create_user_participant(space.id, "Author")
      agent = create_agent_participant(space.id, "Saru", agent_id: agent_id)

      _msg = post_message(space.id, author.id, "no mention")

      ids = Chat.in_context_message_ids_for_agent(agent.id, space.id)
      assert MapSet.size(ids) == 0
    end

    test "agent NOT assigned to the task does not get task-arm messages" do
      assignee_id = Ecto.UUID.generate()
      bystander_id = Ecto.UUID.generate()
      task = create_task(%{status: "in_progress", assignee_id: assignee_id})
      space = create_execution_space(task.id)
      author = create_user_participant(space.id, "Author")
      _assignee = create_agent_participant(space.id, "Assignee", agent_id: assignee_id)
      bystander = create_agent_participant(space.id, "Bystander", agent_id: bystander_id)

      _msg = post_message(space.id, author.id, "no mention, just chatter")

      ids = Chat.in_context_message_ids_for_agent(bystander.id, space.id)
      assert MapSet.size(ids) == 0
    end

    test "non-execution space (channel kind) → task arm returns empty" do
      agent_id = Ecto.UUID.generate()
      task = create_task(%{status: "planning", assignee_id: agent_id})
      # Channel-kind space (not execution) — metadata.task_id is irrelevant for task arm.
      {:ok, space} =
        Chat.create_space(%{
          name: "Chan",
          slug: unique_slug(),
          kind: "channel",
          metadata: %{"task_id" => task.id}
        })

      author = create_user_participant(space.id, "Author")
      agent = create_agent_participant(space.id, "Saru", agent_id: agent_id)

      _msg = post_message(space.id, author.id, "no mention")

      ids = Chat.in_context_message_ids_for_agent(agent.id, space.id)
      assert MapSet.size(ids) == 0
    end
  end

  # ── Union semantics + cross-space isolation ────────────────────────────────

  describe "in_context_message_ids_for_agent/2 — union + cross-space" do
    test "mention AND task-linked → single message in set (deduped, not duplicate)" do
      agent_id = Ecto.UUID.generate()
      task = create_task(%{status: "in_progress", assignee_id: agent_id})
      space = create_execution_space(task.id)
      author = create_user_participant(space.id, "Author")
      agent = create_agent_participant(space.id, "Saru", agent_id: agent_id)

      msg = post_message(space.id, author.id, "Hey @[Saru] thoughts?")

      ids = Chat.in_context_message_ids_for_agent(agent.id, space.id)

      # Even though both arms match, the message id appears once (MapSet semantics).
      assert MapSet.member?(ids, msg.id)
      assert MapSet.size(ids) == 1
    end

    test "cross-space leakage prevented — querying space B returns empty when participant lives in space A" do
      space_a = create_space()
      space_b = create_space()
      author_b = create_user_participant(space_b.id, "AuthorB")
      agent_in_a = create_agent_participant(space_a.id, "Saru")

      # Message in space B that mentions Saru by name.
      _msg = post_message(space_b.id, author_b.id, "Hey @[Saru]")

      # Agent participant `agent_in_a` lives in space A. Asking about space B
      # using that participant id returns empty (no cross-space leakage).
      ids = Chat.in_context_message_ids_for_agent(agent_in_a.id, space_b.id)
      assert MapSet.size(ids) == 0
    end

    test "non-existent participant id → empty set" do
      space = create_space()
      ids = Chat.in_context_message_ids_for_agent(Ecto.UUID.generate(), space.id)
      assert MapSet.size(ids) == 0
    end
  end
end
