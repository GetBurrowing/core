defmodule Platform.Chat.Policy1EditScopingTest do
  @moduledoc """
  Adversarial integration tests for Policy 1 of the editable-messages
  contract (`docs/contracts/editable-messages-contract.md`, Section f).

  Stage 4 of task `019e1e83-fe24-77c4-8a7b-8f90fb5cfca5`. Pins the
  broadcaster's privacy invariant by subscribing test pids to each
  candidate `chat:participant:<id>` topic and asserting which mailboxes
  do — and don't — receive `{:message_edited, _}` after an edit fires.

  Why a dedicated file rather than extending `edit_test.exs`:

    * `edit_test.exs` covers single-recipient happy-path fan-out shape
      (Stage 2 deliverable).
    * `eligible_edit_recipients_test.exs` covers the recipient-resolution
      helper in isolation (Stage 1 deliverable).
    * **This file** is the *adversarial* layer: multi-agent simultaneous
      fixtures, cross-space scoping negatives, and the explicit
      space-wide-AND-per-participant coexistence assertion that future
      regressions are most likely to break.

  See `audit/2026-05-13-policy-1-broadcaster/03-stage3-deferred.md` for
  why the agent-side consumer wiring is intentionally deferred — these
  tests pin the producer contract so a future consumer can't regress
  Policy 1.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.{MessageVersions, PubSub}
  alias Platform.Chat.Messages.Edit
  alias Platform.Tasks

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp create_space!(opts \\ []) do
    n = System.unique_integer([:positive, :monotonic])
    metadata = Keyword.get(opts, :metadata, %{})

    attrs =
      %{
        name: "Policy1 Scoping #{n}",
        slug: "p1-scoping-#{n}",
        kind: "channel"
      }
      |> Map.merge(if metadata == %{}, do: %{}, else: %{metadata: metadata})

    {:ok, space} = Chat.create_space(attrs)
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

    MessageVersions.record_v1!(msg)
    msg
  end

  defp create_task_for_agent!(agent_id) do
    n = System.unique_integer([:positive, :monotonic])
    {:ok, project} = Tasks.create_project(%{name: "P1 Scoping #{n}", slug: "p1-scope-#{n}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Policy1 scope task",
        status: "planning",
        assignee_type: "agent",
        assignee_id: agent_id
      })

    task
  end

  defp subscribe_participant!(participant_id) do
    :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "chat:participant:" <> participant_id)
  end

  # ── Case A: three-agent fixture ──────────────────────────────────────────

  describe "three-agent fan-out" do
    test "edit reaches @-mentioned A and task-assigned B but NOT channel-only C" do
      # Wire a chat space whose metadata.task_id binds it to a task assigned
      # to agent B. Add three agent participants (A mentioned by name in the
      # forthcoming message body, B as the task assignee, C with no
      # relationship). User U authors and edits the message.
      brian_agent_id = Ecto.UUID.generate()
      task = create_task_for_agent!(brian_agent_id)
      space = create_space!(metadata: %{"task_id" => task.id})

      user_u = add_user!(space.id, "U")
      agent_a = add_agent!(space.id, Ecto.UUID.generate(), "Ada")
      agent_b = add_agent!(space.id, brian_agent_id, "Brian")
      agent_c = add_agent!(space.id, Ecto.UUID.generate(), "Cleo")

      msg = post_message!(space.id, user_u.id, "hey @[Ada] take a look")

      subscribe_participant!(agent_a.id)
      subscribe_participant!(agent_b.id)
      subscribe_participant!(agent_c.id)

      assert {:ok, _updated} =
               Edit.apply_edit(msg, user_u, "hey @[Ada] take a look (revised)")

      # A receives — mentioned by name.
      assert_receive {:message_edited, payload_a}, 500
      assert payload_a.message.id == msg.id

      # B receives — task-assignee binding.
      assert_receive {:message_edited, payload_b}, 500
      assert payload_b.message.id == msg.id

      # C does not receive — merely a channel participant. This is the
      # privacy-critical assertion: an agent subscribed to its own
      # participant topic but with no mention or task linkage MUST NOT see
      # edits to messages that don't concern it.
      refute_receive {:message_edited, _}, 200
    end

    test "an agent who is BOTH mentioned AND task-assigned receives exactly once" do
      # Stage 1 unit-tested the helper's dedup behavior; this is the
      # integration-level assertion that the broadcaster doesn't double-
      # broadcast on its participant topic.
      brian_agent_id = Ecto.UUID.generate()
      task = create_task_for_agent!(brian_agent_id)
      space = create_space!(metadata: %{"task_id" => task.id})

      user_u = add_user!(space.id, "U")
      agent_b = add_agent!(space.id, brian_agent_id, "Brian")

      msg = post_message!(space.id, user_u.id, "@[Brian] please review")

      subscribe_participant!(agent_b.id)

      assert {:ok, _} = Edit.apply_edit(msg, user_u, "@[Brian] please review (v2)")

      # Exactly one message — receive then prove the mailbox is empty.
      assert_receive {:message_edited, _}, 500
      refute_receive {:message_edited, _}, 200
    end

    test "space-wide broadcast still fires alongside per-participant fan-out" do
      # User LiveView clients subscribe to the space topic for the (edited)
      # affordance. The Policy 1 fan-out is *additive* — it must not displace
      # the original space-wide broadcast.
      brian_agent_id = Ecto.UUID.generate()
      task = create_task_for_agent!(brian_agent_id)
      space = create_space!(metadata: %{"task_id" => task.id})

      user_u = add_user!(space.id, "U")
      agent_b = add_agent!(space.id, brian_agent_id, "Brian")

      msg = post_message!(space.id, user_u.id, "@[Brian] heads up")

      :ok = PubSub.subscribe(space.id)
      subscribe_participant!(agent_b.id)

      assert {:ok, _} = Edit.apply_edit(msg, user_u, "@[Brian] heads up (v2)")

      # Both topics fire once each.
      assert_receive {:message_edited, _space_payload}, 500
      assert_receive {:message_edited, _participant_payload}, 500
      refute_receive {:message_edited, _}, 200
    end
  end

  # ── Case B: cross-space task-linkage scoping ─────────────────────────────

  describe "cross-space task linkage" do
    test "agent assigned to T2 (linked to S2) does NOT receive edits in S1" do
      # The eligible_edit_recipients_for_message/1 task-assignee clause must
      # be space-scoped: it joins through the *edited message's space* via
      # chat_spaces.metadata.task_id, NOT through the agent's task
      # assignments globally. This test pins that scoping.
      shared_agent_id = Ecto.UUID.generate()

      # Two tasks, one per space.
      _t1 = create_task_for_agent!(Ecto.UUID.generate())
      t2 = create_task_for_agent!(shared_agent_id)

      # S1 is linked to a *different* task (one the shared agent is not
      # assigned to). S2 is linked to T2 (shared agent IS assigned).
      s1 = create_space!(metadata: %{"task_id" => Ecto.UUID.generate()})
      _s2 = create_space!(metadata: %{"task_id" => t2.id})

      author_s1 = add_user!(s1.id, "Author S1")
      shared_in_s1 = add_agent!(s1.id, shared_agent_id, "Shared")
      _other_s1 = add_agent!(s1.id, Ecto.UUID.generate(), "Other")

      msg = post_message!(s1.id, author_s1.id, "no mentions in S1 thread")

      subscribe_participant!(shared_in_s1.id)

      assert {:ok, _} = Edit.apply_edit(msg, author_s1, "no mentions in S1 thread (v2)")

      # The shared agent has a participant row in S1 but no mention there
      # and no task linkage *for S1*. The cross-space task assignment to T2
      # MUST NOT leak edit visibility into S1.
      refute_receive {:message_edited, _}, 200
    end

    test "agent NOT in the message's space receives nothing even when task-assigned to a different space" do
      # Defensive variant: even if the shared agent is assigned to the task
      # linked to S2, an edit in S1 cannot reach the agent's participant
      # topic for an S2 binding because the broadcast targets participant
      # ids resolved from S1's participant list. Belt-and-braces with the
      # previous test.
      shared_agent_id = Ecto.UUID.generate()
      t2 = create_task_for_agent!(shared_agent_id)

      s1 = create_space!()
      s2 = create_space!(metadata: %{"task_id" => t2.id})

      author_s1 = add_user!(s1.id, "Author S1")
      _other_s1 = add_agent!(s1.id, Ecto.UUID.generate(), "Other")
      shared_in_s2 = add_agent!(s2.id, shared_agent_id, "Shared")

      msg = post_message!(s1.id, author_s1.id, "S1 message body")

      subscribe_participant!(shared_in_s2.id)

      assert {:ok, _} = Edit.apply_edit(msg, author_s1, "S1 message body (v2)")

      refute_receive {:message_edited, _}, 200
    end
  end

  # ── Case C: empty recipient set ──────────────────────────────────────────

  describe "empty recipient set" do
    test "no participant topic fires when message has no mentions and no task linkage" do
      # When the eligible-recipients helper returns [], the per-participant
      # Enum.each short-circuits. The space-wide broadcast still fires (so
      # LiveView users still see the edit), but no agent participant topic
      # receives anything. This is the baseline contract: an agent merely
      # subscribed to a space without mention-or-task linkage MUST NOT see
      # edits.
      space = create_space!()
      author = add_user!(space.id, "Author")
      agent_a = add_agent!(space.id, Ecto.UUID.generate(), "Ada")
      agent_b = add_agent!(space.id, Ecto.UUID.generate(), "Brian")

      msg = post_message!(space.id, author.id, "daily standup notes draft")

      :ok = PubSub.subscribe(space.id)
      subscribe_participant!(agent_a.id)
      subscribe_participant!(agent_b.id)

      assert {:ok, _} = Edit.apply_edit(msg, author, "daily standup notes draft (v2)")

      # Space topic still fires — LiveView user clients keep working.
      assert_receive {:message_edited, _}, 500

      # Neither agent participant topic fires.
      refute_receive {:message_edited, _}, 200
    end
  end
end
