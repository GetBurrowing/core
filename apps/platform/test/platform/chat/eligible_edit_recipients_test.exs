defmodule Platform.Chat.EligibleEditRecipientsTest do
  @moduledoc """
  Tests the Policy 1 recipient-resolution helper
  `Platform.Chat.eligible_edit_recipients_for_message/1`.

  This is the Stage 1 deliverable for task `019e1e83-fe24-77c4-8a7b-8f90fb5cfca5`.
  Stage 4's `policy_1_edit_scoping_test.exs` will extend these with the full
  3-agent adversarial fixture (A mentioned, B task-assigned, C channel-only)
  plus the per-participant fan-out integration test. Here we lock in the
  helper's contract surface in isolation: shape, deduplication, and the
  graceful-skip paths.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tasks

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp create_space! do
    slug = "p1-space-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, space} = Chat.create_space(%{name: "Policy1 Test", slug: slug, kind: "channel"})
    space
  end

  defp create_space_linked_to_task!(task_id) do
    slug = "p1-task-space-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, space} =
      Chat.create_space(%{
        name: "Policy1 Task Space",
        slug: slug,
        kind: "channel",
        metadata: %{"task_id" => task_id}
      })

    space
  end

  defp add_user!(space_id, display_name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
  end

  defp add_agent!(space_id, agent_id, display_name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: agent_id,
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
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

  defp create_project_and_task!(agent_id) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, project} =
      Tasks.create_project(%{name: "Policy1 Project #{n}", slug: "policy1-proj-#{n}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Policy1 task",
        status: "planning",
        assignee_type: "agent",
        assignee_id: agent_id
      })

    task
  end

  # ── Mention clause ───────────────────────────────────────────────────────

  describe "eligible_edit_recipients_for_message/1 — mention clause" do
    test "returns participants @-mentioned by bracketed form" do
      space = create_space!()
      alice = add_user!(space.id, "Alice")
      _bob = add_user!(space.id, "Bob")

      msg = post_message!(space.id, alice.id, "hey @[Alice] take a look")

      assert Chat.eligible_edit_recipients_for_message(msg) == [alice.id]
    end

    test "returns participants @-mentioned by legacy substring form" do
      space = create_space!()
      alice = add_user!(space.id, "alice")
      _bob = add_user!(space.id, "Bob")

      msg = post_message!(space.id, alice.id, "ping @alice")

      assert Chat.eligible_edit_recipients_for_message(msg) == [alice.id]
    end

    test "returns [] when no participant matches the body" do
      space = create_space!()
      alice = add_user!(space.id, "Alice")
      _bob = add_user!(space.id, "Bob")

      msg = post_message!(space.id, alice.id, "daily standup notes draft")

      assert Chat.eligible_edit_recipients_for_message(msg) == []
    end
  end

  # ── Task-assignee clause ─────────────────────────────────────────────────

  describe "eligible_edit_recipients_for_message/1 — task assignee clause" do
    test "returns the agent participant whose participant_id matches the linked task's assignee_id" do
      agent_id = Ecto.UUID.generate()
      task = create_project_and_task!(agent_id)
      space = create_space_linked_to_task!(task.id)

      author = add_user!(space.id, "Author")
      agent_p = add_agent!(space.id, agent_id, "Saru")
      _other_agent = add_agent!(space.id, Ecto.UUID.generate(), "Bystander")

      msg = post_message!(space.id, author.id, "no mentions here")

      assert Chat.eligible_edit_recipients_for_message(msg) == [agent_p.id]
    end

    test "returns [] when the space has no metadata.task_id" do
      space = create_space!()
      author = add_user!(space.id, "Author")
      _agent_p = add_agent!(space.id, Ecto.UUID.generate(), "Saru")

      msg = post_message!(space.id, author.id, "no mentions here")

      assert Chat.eligible_edit_recipients_for_message(msg) == []
    end

    test "returns [] when the linked task is assigned to a user, not an agent" do
      n = System.unique_integer([:positive, :monotonic])
      {:ok, project} = Tasks.create_project(%{name: "Proj #{n}", slug: "proj-#{n}"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "User task",
          status: "planning",
          assignee_type: "user",
          assignee_id: Ecto.UUID.generate()
        })

      space = create_space_linked_to_task!(task.id)
      author = add_user!(space.id, "Author")
      _agent_p = add_agent!(space.id, Ecto.UUID.generate(), "Saru")

      msg = post_message!(space.id, author.id, "no mentions here")

      assert Chat.eligible_edit_recipients_for_message(msg) == []
    end
  end

  # ── Union + dedup ────────────────────────────────────────────────────────

  describe "eligible_edit_recipients_for_message/1 — union and deduplication" do
    test "returns the agent exactly once when they are BOTH mentioned and task-assigned" do
      agent_id = Ecto.UUID.generate()
      task = create_project_and_task!(agent_id)
      space = create_space_linked_to_task!(task.id)

      author = add_user!(space.id, "Author")
      agent_p = add_agent!(space.id, agent_id, "Saru")

      msg = post_message!(space.id, author.id, "@[Saru] please review")

      result = Chat.eligible_edit_recipients_for_message(msg)
      assert result == [agent_p.id]
      assert length(result) == 1
    end

    test "returns BOTH the mentioned user AND the task-assigned agent (set union)" do
      agent_id = Ecto.UUID.generate()
      task = create_project_and_task!(agent_id)
      space = create_space_linked_to_task!(task.id)

      author = add_user!(space.id, "Author")
      alice = add_user!(space.id, "Alice")
      agent_p = add_agent!(space.id, agent_id, "Saru")

      msg = post_message!(space.id, author.id, "@[Alice] heads up — task is yours @Saru")

      result = Chat.eligible_edit_recipients_for_message(msg)
      assert Enum.sort(result) == Enum.sort([alice.id, agent_p.id])
    end
  end

  # ── Schema guards ────────────────────────────────────────────────────────

  describe "eligible_edit_recipients_for_message/1 — input guards" do
    test "returns [] for non-Message input" do
      assert Chat.eligible_edit_recipients_for_message(nil) == []
      assert Chat.eligible_edit_recipients_for_message(%{}) == []
    end

    test "returns [] when the space has been deleted out from under the message" do
      space = create_space!()
      alice = add_user!(space.id, "Alice")
      msg = post_message!(space.id, alice.id, "@[Alice] message")

      # Hard-delete the space row; the message struct in memory still has its id.
      Repo.delete!(Repo.get!(Platform.Chat.Space, space.id))

      # Mention clause needs participants → list_participants returns [] for a
      # deleted space → mentioned filter has nothing to filter; task-assignee
      # clause is also empty because Repo.get(Space, …) returns nil. Net: [].
      assert Chat.eligible_edit_recipients_for_message(msg) == []
    end
  end
end
