defmodule Platform.Chat.FreezeNilParticipantTest do
  @moduledoc """
  Regression cover for the plan-approval outage caused by messages whose
  `participant_id` was nulled out.

  `chat_messages.participant_id` carries an `ON DELETE SET NULL` FK to
  `chat_participants(id)`, so removing a participant from a roster nulls
  the column on every message they authored. Freezing such a message used
  to run the full `Message.changeset/2`, whose
  `validate_required([:space_id, :participant_id, :content_type])` then
  failed with `participant_id: "can't be blank"`. That error propagated
  out of `FreezePolicy.freeze_unfrozen_in_space/2`, rolled back the
  dispatch gate, and made `Tasks.approve_plan/3` fail for every task
  whose execution space contained one of those messages.

  The authorship-destroying FK itself is tracked separately as `019ff1c1`;
  this file only guards the freeze path.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.MessageVersions
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp unique_int, do: System.unique_integer([:positive, :monotonic])

  defp create_space! do
    {:ok, space} =
      Chat.create_space(%{
        name: "Freeze Nil Participant",
        slug: "freeze-nil-#{unique_int()}",
        kind: "channel"
      })

    space
  end

  defp create_participant!(space_id, display_name \\ "Freezer") do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
  end

  # Insert a message with `participant_id: nil` directly. `Message.changeset/2`
  # refuses to build one — which is precisely why the freeze path could not
  # stamp the rows the FK had already nulled.
  defp insert_orphaned_message!(space_id, content \\ "authored by a removed participant") do
    %Message{}
    |> Ecto.Changeset.change(%{
      space_id: space_id,
      participant_id: nil,
      content_type: "text",
      content: content,
      author_display_name: "Removed Participant"
    })
    |> Repo.insert!()
  end

  # ── freeze/2 on a nulled-out author ────────────────────────────────────────

  describe "MessageVersions.freeze/2 with participant_id: nil" do
    test "freezes a message whose author participant row was deleted" do
      space = create_space!()
      freezer = create_participant!(space.id)
      msg = insert_orphaned_message!(space.id)

      assert {:ok, frozen} = MessageVersions.freeze(msg, freezer.id)
      assert %DateTime{} = frozen.frozen_at
      assert frozen.frozen_by_participant_id == freezer.id
    end

    test "leaves participant_id nil rather than backfilling it to pass a validator" do
      space = create_space!()
      freezer = create_participant!(space.id)
      msg = insert_orphaned_message!(space.id)

      assert {:ok, _frozen} = MessageVersions.freeze(msg, freezer.id)

      reloaded = Repo.get!(Message, msg.id)
      assert is_nil(reloaded.participant_id)
      assert %DateTime{} = reloaded.frozen_at
      assert reloaded.frozen_by_participant_id == freezer.id
    end

    test "still no-ops on an already-frozen message" do
      space = create_space!()
      freezer = create_participant!(space.id)
      other = create_participant!(space.id, "Second Freezer")
      msg = insert_orphaned_message!(space.id)

      assert {:ok, frozen} = MessageVersions.freeze(msg, freezer.id)
      assert {:ok, again} = MessageVersions.freeze(frozen, other.id)

      assert again.frozen_at == frozen.frozen_at
      assert again.frozen_by_participant_id == freezer.id
    end
  end

  # ── frozen_both_or_neither invariant survives the narrow changeset ─────────

  describe "frozen_both_or_neither invariant" do
    test "freeze/2 sets both frozen fields together" do
      space = create_space!()
      freezer = create_participant!(space.id)
      msg = insert_orphaned_message!(space.id)

      assert {:ok, frozen} = MessageVersions.freeze(msg, freezer.id)
      refute is_nil(frozen.frozen_at)
      refute is_nil(frozen.frozen_by_participant_id)
    end

    test "setting only frozen_at is invalid" do
      space = create_space!()
      msg = insert_orphaned_message!(space.id)

      changeset = Message.freeze_changeset(msg, %{frozen_at: DateTime.utc_now()})

      refute changeset.valid?

      assert {"is required when frozen_at is set", _} =
               changeset.errors[:frozen_by_participant_id]
    end

    test "setting only frozen_by_participant_id is invalid" do
      space = create_space!()
      freezer = create_participant!(space.id)
      msg = insert_orphaned_message!(space.id)

      changeset =
        Message.freeze_changeset(msg, %{frozen_by_participant_id: freezer.id})

      refute changeset.valid?

      assert {"is required when frozen_by_participant_id is set", _} =
               changeset.errors[:frozen_at]
    end
  end

  # ── End-to-end: plan approval over an execution space with an orphan ───────

  describe "Tasks.approve_plan/3 over an execution space containing an orphaned message" do
    test "approves rather than failing the dispatch gate" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Freeze Nil Participant #{unique_int()}",
          slug: "freeze-nil-proj-#{unique_int()}"
        })

      agent_id = Ecto.UUID.generate()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Plan approval over orphaned messages",
          status: "planning",
          assignee_type: "agent",
          assignee_id: agent_id
        })

      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      {:ok, _agent_participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent_id,
          joined_at: DateTime.utc_now(),
          display_name: "Executor"
        })

      orphan = insert_orphaned_message!(space.id, "posted before the roster change")

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      plan
      |> Ecto.Changeset.change(%{status: "pending_review"})
      |> Repo.update!()

      assert {:ok, _approved} =
               Tasks.approve_plan(
                 Repo.get!(Platform.Tasks.Plan, plan.id),
                 Ecto.UUID.generate()
               )

      reloaded = Repo.get!(Message, orphan.id)
      assert %DateTime{} = reloaded.frozen_at
      assert is_nil(reloaded.participant_id)
    end
  end
end
