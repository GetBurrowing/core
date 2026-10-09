defmodule Platform.Orchestration.ExecutionSpaceTest do
  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  @task_id "01234567-89ab-cdef-0123-456789abcdef"

  defp count_exec_spaces_for(task_id) do
    Repo.aggregate(
      from(s in Platform.Chat.Space,
        where:
          s.kind == "execution" and
            fragment("?->>'task_id' = ?", s.metadata, ^task_id)
      ),
      :count
    )
  end

  describe "find_or_create/1" do
    test "creates an execution space for a task" do
      assert {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert space.kind == "execution"
      # The WHOLE UUID, dashes stripped: all 32 hex characters, so the
      # slug is a bijection of the task id. See `execution_space.ex` for
      # why no front slice can be (task 01a07783 stage 1): the leading
      # 12 hex of a UUIDv7 are the creation millisecond, so a prefix
      # carries none of the random half. `@task_id` here is
      # "01234567-89ab-cdef-0123-456789abcdef".
      assert space.name == "task-exec-0123456789abcdef0123456789abcdef"
      assert space.slug == space.name
      assert space.metadata["task_id"] == @task_id
    end

    # The defect the whole-UUID derivation exists to prevent.
    #
    # Task ids are UUIDv7 and their leading 48 bits (exactly 12 hex
    # characters) are the creation millisecond. The old derivation sliced
    # precisely those 12, so two tasks created in ONE org in the same
    # millisecond produced the SAME slug and the second was rejected by
    # `chat_spaces_unique_org_slug`.
    #
    # The two ids below are CONSTRUCTED to share that 12-hex prefix. Creating
    # two tasks back to back would not test this: on the broken build that
    # passes whenever the scheduler puts a millisecond between the inserts,
    # which is exactly the flake being fixed.
    #
    # A collision comes back as `{:error, %Ecto.Changeset{}}`:
    # `Chat.Space.changeset/2` declares
    # `unique_constraint(:slug, name: :chat_spaces_unique_org_slug)`, so the
    # insert never raises.
    test "two tasks sharing the UUIDv7 millisecond get distinct slugs in one org" do
      org_id = acme_org_id()

      {:ok, project} =
        Tasks.create_project(%{name: "Exec Slug Collision Project", org_id: org_id})

      # Identical leading 12 hex ("0a0a0a0a1b1b"), different remaining 20.
      id_a = "0a0a0a0a-1b1b-7000-8000-00000000000a"
      id_b = "0a0a0a0a-1b1b-7000-8000-00000000000b"
      hex_a = String.replace(id_a, "-", "")
      hex_b = String.replace(id_b, "-", "")

      # Guard the fixture itself: if these ever stop sharing the millisecond
      # prefix, the test below stops discriminating and would go green on the
      # broken derivation.
      assert String.slice(hex_a, 0, 12) == String.slice(hex_b, 0, 12)
      refute hex_a == hex_b

      task_a = Repo.insert!(%Task{id: id_a, project_id: project.id, title: "Same ms A"})
      task_b = Repo.insert!(%Task{id: id_b, project_id: project.id, title: "Same ms B"})

      assert {:ok, space_a} = ExecutionSpace.find_or_create(task_a.id)
      assert {:ok, space_b} = ExecutionSpace.find_or_create(task_b.id)

      assert space_a.slug == "task-exec-" <> hex_a
      assert space_b.slug == "task-exec-" <> hex_b
      assert space_a.slug != space_b.slug
      assert space_a.id != space_b.id

      # `org_id` is what brings `chat_spaces_unique_org_slug` into play at
      # all. With `nil` on both rows the index cannot fire and the pair
      # would prove nothing.
      assert space_a.org_id == org_id
      assert space_b.org_id == org_id
    end

    test "is idempotent — returns existing space" do
      {:ok, space1} = ExecutionSpace.find_or_create(@task_id)
      {:ok, space2} = ExecutionSpace.find_or_create(@task_id)
      assert space1.id == space2.id
    end

    test "execution spaces are excluded from list_spaces by default" do
      {:ok, _space} = ExecutionSpace.find_or_create(@task_id)
      spaces = Chat.list_spaces()
      refute Enum.any?(spaces, &(&1.kind == "execution"))
    end

    test "execution spaces are included with include_execution: true" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      spaces = Chat.list_spaces(include_execution: true)
      assert Enum.any?(spaces, &(&1.id == space.id))
    end

    # Pin-to-Chat v4 stage 2 regression fence — see
    # `apps/platform/priv/repo/migrations/20260715165309_backfill_exec_space_org_id.exs`
    # for the companion backfill. Without an `org_id` on new exec-space
    # rows, `Chat.get_space_by_slug/2` filters them out for viewers
    # inside an org and clicking a pinned rail row bounces the user
    # back to `/chat`.
    test "stamps org_id on new exec space from task → project.org_id" do
      acme_id = acme_org_id()

      {:ok, project} =
        Tasks.create_project(%{name: "Exec Org Stamp Project", org_id: acme_id})

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Exec org stamp"})

      assert {:ok, space} = ExecutionSpace.find_or_create(task.id)
      assert space.org_id == acme_id
      assert space.metadata["task_id"] == task.id
    end

    test "leaves org_id nil + logs warn when task has no resolvable org" do
      # Random UUID that does NOT correspond to any real task row.
      orphan_task_id = Ecto.UUID.generate()

      {result, log} =
        with_log(fn ->
          ExecutionSpace.find_or_create(orphan_task_id)
        end)

      assert {:ok, space} = result
      assert space.org_id == nil
      assert space.metadata["task_id"] == orphan_task_id
      assert log =~ "no org_id resolvable"
      assert log =~ orphan_task_id
    end

    # The write-path revive. `find_or_create/1` is only ever called by paths
    # about to attach LIVE state (pinning, dispatch); handing one an archived
    # row means the write persists against a tombstone the read side filters
    # out, and the user is told it worked.
    test "revives an archived execution space rather than returning the tombstone" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      {:ok, archived} = Chat.archive_space(space)
      refute is_nil(archived.archived_at)

      {result, log} = with_log(fn -> ExecutionSpace.find_or_create(@task_id) end)

      assert {:ok, revived} = result
      # The behaviour under test: the caller gets a USABLE space.
      assert revived.archived_at == nil
      assert revived.deletion_scheduled_at == nil
      assert revived.archived_cascade_org_id == nil

      # Same row, not a fresh one — a newly created space would also satisfy
      # `archived_at == nil` while orphaning the original's message history.
      assert revived.id == space.id
      assert count_exec_spaces_for(@task_id) == 1

      # The condition must be observable the next time it happens.
      assert log =~ "reviving archived execution space"
      assert log =~ @task_id
      assert log =~ space.id
    end

    test "idempotency preserved — second call returns same row without touching org_id" do
      acme_id = acme_org_id()

      {:ok, project} =
        Tasks.create_project(%{name: "Exec Idempotency Project", org_id: acme_id})

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Idempotency"})

      assert {:ok, space1} = ExecutionSpace.find_or_create(task.id)
      assert space1.org_id == acme_id

      # Force the row to a different org_id to prove the second call
      # short-circuits on `find_by_task_id` and does NOT rewrite it.
      other_id = tenant_org_id("sxi")

      {1, _} =
        Repo.update_all(
          from(s in Platform.Chat.Space, where: s.id == ^space1.id),
          set: [org_id: other_id]
        )

      assert {:ok, space2} = ExecutionSpace.find_or_create(task.id)
      assert space2.id == space1.id
      # Untouched by the second call — the find branch fired, not the
      # create branch.
      assert space2.org_id == other_id
    end
  end

  describe "archive/1" do
    test "archives the execution space" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert {:ok, archived} = ExecutionSpace.archive(@task_id)
      assert archived.id == space.id
      assert archived.archived_at != nil
    end

    test "returns error when no space exists" do
      assert {:error, :not_found} = ExecutionSpace.archive("nonexistent-task-id")
    end
  end

  describe "post_log/2" do
    test "posts a log-only message to the execution space" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert {:ok, message} = ExecutionSpace.post_log(space.id, "Task started")
      assert message.content == "Task started"
      assert message.log_only == true
      assert message.content_type == "system"
      assert message.space_id == space.id
      assert message.metadata["source"] == "task_router"
      assert message.metadata["kind"] == "log"
      assert message.metadata["log_only"] == true
    end

    test "metadata is exactly the fixed map (task 01a0e266 stage 2: /3 changed nothing for /2)" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert {:ok, message} = ExecutionSpace.post_log(space.id, "Task started")

      assert message.metadata == %{
               "source" => "task_router",
               "kind" => "log",
               "log_only" => true
             }
    end
  end

  describe "post_log/3" do
    test "merges :metadata over the fixed map and stays log-only" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)

      assert {:ok, message} =
               ExecutionSpace.post_log(space.id, "Case amended",
                 metadata: %{"reason" => "validation_payload_amended", "kind" => "override"}
               )

      assert message.log_only == true
      assert message.content_type == "system"

      assert message.metadata == %{
               "source" => "task_router",
               "kind" => "override",
               "log_only" => true,
               "reason" => "validation_payload_amended"
             }
    end
  end

  describe "post_engagement/2" do
    test "posts an engagement message to the execution space" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert {:ok, message} = ExecutionSpace.post_engagement(space.id, "Heartbeat prompt")
      assert message.content == "Heartbeat prompt"
      assert message.log_only == false
      assert message.content_type == "text"
      assert message.space_id == space.id
      assert message.metadata["source"] == "task_router"
      assert message.metadata["kind"] == "engagement"
      assert message.metadata["log_only"] == false
    end

    test "accepts metadata option" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)

      assert {:ok, message} =
               ExecutionSpace.post_engagement(space.id, "Prompt",
                 metadata: %{"reason" => "task_heartbeat"}
               )

      assert message.metadata["reason"] == "task_heartbeat"
      assert message.metadata["source"] == "task_router"
      assert message.metadata["kind"] == "engagement"
      assert message.metadata["log_only"] == false
    end
  end

  describe "ensure_system_participant/1" do
    test "creates a system participant" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert {:ok, participant} = ExecutionSpace.ensure_system_participant(space.id)
      assert participant.display_name == "TaskRouter"
      # The router is its own kind: no `agents` row resolves it, so counting it
      # in an agent roster inflated every space-health denominator (019ff1af).
      assert participant.participant_type == "system"
    end

    test "is idempotent" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      {:ok, p1} = ExecutionSpace.ensure_system_participant(space.id)
      {:ok, p2} = ExecutionSpace.ensure_system_participant(space.id)
      assert p1.id == p2.id
    end
  end

  describe "find_by_task_id/1" do
    test "returns nil when no execution space exists" do
      assert ExecutionSpace.find_by_task_id("nonexistent-id") == nil
    end

    test "returns the active execution space for a task" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert found = ExecutionSpace.find_by_task_id(@task_id)
      assert found.id == space.id
    end

    # Load-bearing, and NOT collateral damage of the `find_or_create/1`
    # revive: a completed task must still render its execution log, so the
    # READ path keeps falling back to the archived row WITH `archived_at`
    # intact. Only the write path revives.
    test "returns archived space when no active space exists" do
      {:ok, _space} = ExecutionSpace.find_or_create(@task_id)
      {:ok, archived} = ExecutionSpace.archive(@task_id)
      assert found = ExecutionSpace.find_by_task_id(@task_id)
      assert found.id == archived.id
      assert found.archived_at != nil
    end
  end

  describe "list_messages_with_participants/2" do
    test "returns messages with participant info in chronological order" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      {:ok, _log} = ExecutionSpace.post_log(space.id, "First log message")
      {:ok, _eng} = ExecutionSpace.post_engagement(space.id, "Heartbeat prompt")
      {:ok, _log2} = ExecutionSpace.post_log(space.id, "Second log message")

      messages = ExecutionSpace.list_messages_with_participants(space.id)

      assert length(messages) == 3

      [first, second, third] = messages
      assert first.content == "First log message"
      assert first.log_only == true
      assert first.sender_name == "TaskRouter"
      assert first.sender_type == "system"

      assert second.content == "Heartbeat prompt"
      assert second.log_only == false

      assert third.content == "Second log message"

      # Verify chronological order
      assert DateTime.compare(first.inserted_at, second.inserted_at) in [:lt, :eq]
      assert DateTime.compare(second.inserted_at, third.inserted_at) in [:lt, :eq]
    end

    test "returns empty list when no messages exist" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      assert ExecutionSpace.list_messages_with_participants(space.id) == []
    end

    test "includes attachments field for messages" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      {:ok, _msg} = ExecutionSpace.post_log(space.id, "Message with attachments field")

      messages = ExecutionSpace.list_messages_with_participants(space.id)
      assert length(messages) == 1
      [msg] = messages
      assert Map.has_key?(msg, :attachments)
      assert msg.attachments == []
    end

    test "returns engagement-class steering messages with metadata and attachments" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)

      {:ok, user} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Rowan",
          joined_at: DateTime.utc_now()
        })

      {:ok, message, [_attachment]} =
        Chat.post_message_with_attachments(
          %{
            space_id: space.id,
            participant_id: user.id,
            content_type: "text",
            content: "Please focus on the failing execution route",
            log_only: false,
            metadata: %{
              "kind" => "steering",
              "source" => "tasks_live",
              "delivery" => "engagement"
            }
          },
          [
            %{
              filename: "steering.txt",
              content_type: "text/plain",
              byte_size: 24,
              storage_key: "tests/execution-space/steering.txt"
            }
          ]
        )

      [msg] = ExecutionSpace.list_messages_with_participants(space.id)

      assert msg.id == message.id
      assert msg.sender_name == "Rowan"
      assert msg.sender_type == "user"
      assert msg.content_type == "text"
      assert msg.log_only == false
      assert msg.metadata["kind"] == "steering"
      assert msg.metadata["source"] == "tasks_live"
      assert msg.metadata["delivery"] == "engagement"
      assert length(msg.attachments) == 1
      assert hd(msg.attachments).filename == "steering.txt"
      assert hd(msg.attachments).content_type == "text/plain"
    end

    test "respects limit option" do
      {:ok, space} = ExecutionSpace.find_or_create(@task_id)
      {:ok, _} = ExecutionSpace.post_log(space.id, "msg 1")
      {:ok, _} = ExecutionSpace.post_log(space.id, "msg 2")
      {:ok, _} = ExecutionSpace.post_log(space.id, "msg 3")

      messages = ExecutionSpace.list_messages_with_participants(space.id, limit: 2)
      assert length(messages) == 2
      # Should get the oldest 2 (ORDER BY ASC + LIMIT)
      assert hd(messages).content == "msg 1"
    end
  end

  describe "add_participant is deleted (task 019fb90f stage 3)" do
    # The deleted function had zero production call sites; the test that used
    # to live here was the only caller in the repo, which is precisely why its
    # `attention_mode: "all"` could drift from the real dispatch path forever
    # without anything going red. That policy now lives once, in
    # `Platform.Chat.DispatchMembership`.
    #
    # This asserts on the RESIDUE, not on a remembered arity: it filters the
    # export list by NAME and reports whatever it finds. Pinning
    # `refute function_exported?(ExecutionSpace, :add_participant, 2)` would go
    # green the moment someone reintroduced the function at arity 3.
    test "ExecutionSpace exports no add_participant at any arity" do
      Code.ensure_loaded!(ExecutionSpace)

      residue =
        ExecutionSpace.module_info(:exports)
        |> Enum.filter(fn {name, _arity} -> name == :add_participant end)

      assert residue == [], """
      Platform.Orchestration.ExecutionSpace has re-grown an add_participant
      function at arity #{Enum.map_join(residue, ", ", fn {_n, a} -> a end)}.

      Membership in an execution space is owned by
      Platform.Chat.DispatchMembership, which is reached from the dispatch
      path via Platform.Federation.AttentionDispatch. A second entry point
      here is a second copy of the attention_mode policy, and the two will
      drift — that is the exact defect deleting the original closed.

      Call DispatchMembership.ensure_writable(space_id, agent_id,
      source: :task_router) instead.
      """
    end
  end
end
