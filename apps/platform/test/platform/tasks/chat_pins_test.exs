defmodule Platform.Tasks.ChatPinsTest do
  @moduledoc """
  Tests for `Platform.Tasks.ChatPins` — Pin-to-Chat stage 2 (task 019f62a1).

  The load-bearing contract this suite protects:

    * `pin/3` materialises the execution `chat_spaces` row LAZILY (first
      pin wins) via `ExecutionSpace.find_or_create/1`. Repeat pins reuse
      the existing space, keeping the count at exactly one.

    * `Tasks.create_task/1` alone does NOT touch `chat_spaces` — this is
      the regression fence for the "hundreds of orphan backlog spaces"
      concern captured in the plan's v1/v2 feedback.

    * `pin/3` is idempotent on `(task, participant)` at the DB layer
      (unique index) AND at the broadcast layer (context short-circuits
      on repeat).

    * `unpin_all_for_task/1` deletes every pin for a task and broadcasts
      the union set — the task-done cascade endpoint used by stage 3.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.Space
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{ChatPin, ChatPins}

  setup do
    {:ok, project} = Tasks.create_project(%{name: "ChatPins Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Pin regression"})

    # Subscribe to the global space-lifecycle topic so we can assert on
    # `:task_pin_added` / `:task_pin_removed` broadcasts. `pin/3` uses
    # `ChatPubSub.broadcast_space_event/1` which routes here.
    :ok = ChatPubSub.subscribe_spaces()

    on_exit(fn -> ChatPubSub.unsubscribe_spaces() end)

    %{project: project, task: task}
  end

  defp count_chat_spaces_for(task_id) do
    Repo.aggregate(
      from(s in Space,
        where:
          s.kind == "execution" and
            fragment("?->>'task_id' = ?", s.metadata, ^task_id)
      ),
      :count
    )
  end

  defp count_pins_for(task_id) do
    Repo.aggregate(from(p in ChatPin, where: p.task_id == ^task_id), :count)
  end

  defp sponsor, do: %{kind: "user", id: "sponsor@example.com"}

  describe "lazy execution-space materialisation" do
    test "Tasks.create_task/1 alone does NOT create a chat_spaces row (regression fence)",
         %{task: task} do
      # This is the "hundreds of orphan backlog spaces" fence. The
      # plan's v1/v2 feedback explicitly rejects eager creation — every
      # backlog task that's never picked up must stay off the chat rail
      # and out of `chat_spaces`.
      assert count_chat_spaces_for(task.id) == 0

      # Sanity: neither the pin nor the space exists before anyone acts.
      assert count_pins_for(task.id) == 0
      assert ExecutionSpace.find_by_task_id(task.id) == nil
    end

    test "pin/3 creates the execution space when none exists", %{task: task} do
      assert count_chat_spaces_for(task.id) == 0

      assert {:ok, %{space: %Space{} = space, pin: %ChatPin{} = pin}} =
               ChatPins.pin(task.id, sponsor(), "sponsor@example.com")

      assert space.kind == "execution"
      assert space.metadata["task_id"] == task.id

      # 0 → 1 transition: the pin caused the materialisation.
      assert count_chat_spaces_for(task.id) == 1
      assert count_pins_for(task.id) == 1

      # Broadcast fired with the four-field payload.
      assert_receive {:task_pin_added,
                      %{
                        task_id: broadcast_task_id,
                        space_id: broadcast_space_id,
                        participant_kind: "user",
                        participant_id: "sponsor@example.com"
                      }}

      assert broadcast_task_id == task.id
      assert broadcast_space_id == space.id
      assert pin.task_id == task.id
      assert pin.participant_kind == "user"
      assert pin.participant_id == "sponsor@example.com"
      assert pin.pinned_by == "sponsor@example.com"
    end

    test "pin/3 REUSES an existing execution space instead of creating a duplicate",
         %{task: task} do
      # Pre-materialise the space via the same chokepoint the plan
      # engine uses — proves the two writers converge on one row.
      {:ok, %Space{id: pre_existing_id} = _pre} = ExecutionSpace.find_or_create(task.id)
      assert count_chat_spaces_for(task.id) == 1

      assert {:ok, %{space: %Space{id: returned_id}}} =
               ChatPins.pin(task.id, sponsor(), "sponsor@example.com")

      assert returned_id == pre_existing_id
      # Still exactly one — no duplicate exec space.
      assert count_chat_spaces_for(task.id) == 1
      assert count_pins_for(task.id) == 1
    end
  end

  describe "idempotency" do
    test "pin/3 called twice for the same (task, participant) inserts exactly one row",
         %{task: task} do
      assert {:ok, %{pin: %ChatPin{id: first_id}}} =
               ChatPins.pin(task.id, sponsor(), "sponsor@example.com")

      assert_receive {:task_pin_added, %{}}

      # Second call — same participant. Must be a no-op at the DB layer
      # AND at the broadcast layer.
      assert {:ok, %{pin: %ChatPin{id: second_id}}} =
               ChatPins.pin(task.id, sponsor(), "sponsor@example.com")

      # Same row returned — the get_by short-circuit picked up the
      # existing pin.
      assert second_id == first_id
      assert count_pins_for(task.id) == 1
      assert count_chat_spaces_for(task.id) == 1

      # Explicit no-broadcast fence — the caller
      # (reinvite_and_pin_mentioned in stage 3) relies on this.
      refute_receive {:task_pin_added, _}, 100
    end

    test "pin/3 for a different participant on the same task creates a second row",
         %{task: task} do
      assert {:ok, _} = ChatPins.pin(task.id, sponsor(), "sponsor@example.com")
      assert_receive {:task_pin_added, _}

      other = %{kind: "user", id: "alice@example.com"}

      assert {:ok, %{pin: %ChatPin{}}} =
               ChatPins.pin(task.id, other, "sponsor@example.com")

      assert count_pins_for(task.id) == 2
      # Still one exec space — participants share the same space.
      assert count_chat_spaces_for(task.id) == 1
      assert_receive {:task_pin_added, %{participant_id: "alice@example.com"}}
    end

    test "pinned?/2 reflects the pin lifecycle", %{task: task} do
      refute ChatPins.pinned?(task.id, sponsor())
      assert {:ok, _} = ChatPins.pin(task.id, sponsor(), "sponsor@example.com")
      assert ChatPins.pinned?(task.id, sponsor())
      assert {:ok, :removed} = ChatPins.unpin(task.id, sponsor())
      refute ChatPins.pinned?(task.id, sponsor())
    end
  end

  describe "unpin/3" do
    test "removes the row and broadcasts :task_pin_removed", %{task: task} do
      assert {:ok, _} = ChatPins.pin(task.id, sponsor(), "sponsor@example.com")
      assert_receive {:task_pin_added, _}

      assert {:ok, :removed} = ChatPins.unpin(task.id, sponsor())
      assert count_pins_for(task.id) == 0

      # Space is intentionally NOT archived — plan engine may still own
      # it, and post-mortem access is preserved by design.
      assert count_chat_spaces_for(task.id) == 1

      assert_receive {:task_pin_removed,
                      %{
                        task_id: broadcast_task_id,
                        participant_kind: "user",
                        participant_id: "sponsor@example.com"
                      }}

      assert broadcast_task_id == task.id
    end

    test "is a no-op when no pin exists", %{task: task} do
      assert {:ok, :noop} = ChatPins.unpin(task.id, sponsor())
      refute_receive {:task_pin_removed, _}, 100
    end

    # Stage 4 fixup #2 (task 019f62a1): the rail's inline unpin icon lets
    # any participant self-unpin. The context contract for that surface
    # is participant-scoped delete — an unpin for participant A must
    # NOT collateral-damage participant B's row on the same task.
    test "removes only the matching participant's row; other pins survive",
         %{task: task} do
      alice = %{kind: "user", id: "alice@example.com"}
      bob = %{kind: "user", id: "bob@example.com"}
      agent = %{kind: "agent", id: "historian"}

      for p <- [alice, bob, agent] do
        assert {:ok, _} = ChatPins.pin(task.id, p, "sponsor@example.com")
        assert_receive {:task_pin_added, _}
      end

      assert count_pins_for(task.id) == 3

      # Alice self-unpins — only her row goes.
      assert {:ok, :removed} = ChatPins.unpin(task.id, alice, "alice@example.com")

      assert count_pins_for(task.id) == 2
      refute ChatPins.pinned?(task.id, alice)
      assert ChatPins.pinned?(task.id, bob)
      assert ChatPins.pinned?(task.id, agent)

      # Exactly one broadcast fired, keyed to alice.
      assert_receive {:task_pin_removed,
                      %{participant_kind: "user", participant_id: "alice@example.com"}}

      refute_receive {:task_pin_removed, _}, 100
    end
  end

  describe "unpin_all_for_task/1" do
    test "deletes every row for a task and broadcasts each removal", %{task: task} do
      participants = [
        %{kind: "user", id: "sponsor@example.com"},
        %{kind: "user", id: "alice@example.com"},
        %{kind: "agent", id: "historian"}
      ]

      for p <- participants do
        assert {:ok, _} = ChatPins.pin(task.id, p, "sponsor@example.com")
        assert_receive {:task_pin_added, _}
      end

      assert count_pins_for(task.id) == 3

      assert {:ok, 3} = ChatPins.unpin_all_for_task(task.id)
      assert count_pins_for(task.id) == 0
      # Space persists — cascade is pin-only.
      assert count_chat_spaces_for(task.id) == 1

      # Three broadcasts — one per removed participant. Assert we can
      # collect all three regardless of order (broadcast order is
      # implementation-defined; consumers must not rely on it).
      broadcasts =
        for _ <- 1..3 do
          assert_receive {:task_pin_removed, payload}
          {payload.participant_kind, payload.participant_id}
        end

      assert Enum.sort(broadcasts) ==
               Enum.sort(Enum.map(participants, fn %{kind: k, id: i} -> {k, i} end))
    end

    test "is a no-op with an empty pin set", %{task: task} do
      assert {:ok, 0} = ChatPins.unpin_all_for_task(task.id)
      refute_receive {:task_pin_removed, _}, 100
    end
  end

  describe "list_pinned_task_spaces_for/1" do
    test "returns every non-archived space the participant has pinned, newest first",
         %{project: project, task: task} do
      # Second task so we have two rows to order.
      {:ok, task2} =
        Tasks.create_task(%{project_id: project.id, title: "Second pin"})

      viewer = %{kind: "user", id: "viewer@example.com"}

      assert {:ok, _} = ChatPins.pin(task.id, viewer, "sponsor@example.com")
      # Small nudge so `inserted_at` ordering is deterministic across
      # timestamp resolution.
      Process.sleep(5)
      assert {:ok, _} = ChatPins.pin(task2.id, viewer, "sponsor@example.com")

      [first, second] = ChatPins.list_pinned_task_spaces_for(viewer)
      # Newest pin (task2) comes first per `order_by: [desc: pin.inserted_at]`.
      assert first.metadata["task_id"] == task2.id
      assert second.metadata["task_id"] == task.id
    end

    test "filters archived execution spaces out", %{task: task} do
      viewer = %{kind: "user", id: "viewer@example.com"}
      assert {:ok, %{space: space}} = ChatPins.pin(task.id, viewer, "viewer@example.com")

      assert ChatPins.list_pinned_task_spaces_for(viewer) |> length() == 1

      # Archive the space directly — the pin row stays, but the query
      # must drop the archived row.
      space
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
      |> Repo.update!()

      assert ChatPins.list_pinned_task_spaces_for(viewer) == []
    end

    # COMPOSED CASE. The user-visible symptom: a router shutdown archived the
    # execution space of a task that was still running, and the later pin then
    # succeeded silently against that tombstone — the pin row persisted and the
    # space could never render, because the read path filters archived rows.
    #
    # Pinning to an ACTIVE space is the only path that works today, so a test
    # that does that passes against unpatched code and proves nothing. This one
    # starts from the archived state deliberately.
    test "a pin created after the space was archived still renders (revive on write)",
         %{task: task} do
      viewer = %{kind: "user", id: "viewer@example.com"}

      # Materialise the space, then archive it as a premature router shutdown
      # would have done.
      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      {:ok, _archived} = Platform.Chat.archive_space(space)
      assert Repo.get!(Space, space.id).archived_at != nil

      assert {:ok, %{space: pinned}} = ChatPins.pin(task.id, viewer, viewer.id)

      # The write path revived the row rather than handing back a tombstone —
      # same id, no duplicate.
      assert pinned.id == space.id
      assert pinned.archived_at == nil
      assert count_chat_spaces_for(task.id) == 1

      assert [listed] = ChatPins.list_pinned_task_spaces_for(viewer)
      assert listed.id == space.id
    end

    # HAPPY-PATH GUARD, paired with the case above: pinning to a space that was
    # never archived must keep working. Expected to pass both before and after.
    test "a pin created against an active space still renders", %{task: task} do
      viewer = %{kind: "user", id: "viewer@example.com"}

      assert {:ok, %{space: space}} = ChatPins.pin(task.id, viewer, viewer.id)
      assert space.archived_at == nil
      assert [listed] = ChatPins.list_pinned_task_spaces_for(viewer)
      assert listed.id == space.id
    end

    test "returns [] for a participant with no pins" do
      assert ChatPins.list_pinned_task_spaces_for(%{kind: "user", id: "nobody@example.com"}) ==
               []
    end
  end

  describe "display_name_for_space/1" do
    test "returns the underlying task title when metadata.task_id resolves",
         %{task: task} do
      viewer = %{kind: "user", id: "viewer@example.com"}
      {:ok, %{space: space}} = ChatPins.pin(task.id, viewer, viewer.id)

      # Confirm the default synthesised space.name is the cryptic slug the
      # sponsor complained about — the change under test replaces THIS
      # with the task's real title in the rail.
      assert String.starts_with?(space.name, "task-exec-")
      assert ChatPins.display_name_for_space(space) == task.title
    end

    test "falls back to space.name when metadata has no task_id" do
      # A space struct with metadata missing the task_id key should not
      # crash the rail render — the fallback preserves the raw name.
      space = %Space{id: Ecto.UUID.generate(), name: "task-exec-abcdef01", metadata: %{}}
      assert ChatPins.display_name_for_space(space) == "task-exec-abcdef01"
    end

    test "falls back to space.name when the task has been deleted" do
      # Stale pin/space pointing at a task_id that no longer resolves —
      # rail must render the slug rather than blowing up.
      space = %Space{
        id: Ecto.UUID.generate(),
        name: "task-exec-deadbeef",
        metadata: %{"task_id" => Ecto.UUID.generate()}
      }

      assert ChatPins.display_name_for_space(space) == "task-exec-deadbeef"
    end
  end
end
