defmodule Platform.Chat.ThreadTest do
  use Platform.DataCase, async: false

  alias Platform.Chat

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_space!(name \\ "test-space") do
    slug = "#{name}-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, space} = Chat.create_space(%{name: name, slug: slug, kind: "channel"})
    space
  end

  defp create_participant!(space_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp create_message!(space_id, participant_id) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: "hello from test"
      })

    msg
  end

  # ── create_thread/2 ──────────────────────────────────────────────────────────

  describe "create_thread/2" do
    test "creates a thread in a space" do
      space = create_space!()
      {:ok, thread} = Chat.create_thread(space.id, %{title: "Discussion"})

      assert thread.space_id == space.id
      assert thread.title == "Discussion"
    end

    test "creates a thread with a parent_message_id" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      {:ok, thread} = Chat.create_thread(space.id, %{parent_message_id: msg.id})

      assert thread.space_id == space.id
      assert thread.parent_message_id == msg.id
    end

    test "creates a thread with no attrs (minimal)" do
      space = create_space!()
      {:ok, thread} = Chat.create_thread(space.id)

      assert thread.space_id == space.id
      assert is_nil(thread.title)
    end
  end

  # ── create_thread_for_message/3 ───────────────────────────────────────────────

  describe "create_thread_for_message/3" do
    test "creates a new thread when none exists for the message" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      {:ok, thread} = Chat.create_thread_for_message(space.id, msg.id)

      assert thread.space_id == space.id
      assert thread.parent_message_id == msg.id
    end

    test "returns the existing thread when called twice for the same message" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      {:ok, thread1} = Chat.create_thread_for_message(space.id, msg.id)
      {:ok, thread2} = Chat.create_thread_for_message(space.id, msg.id)

      assert thread1.id == thread2.id
    end

    test "creates distinct threads for different parent messages" do
      space = create_space!()
      p = create_participant!(space.id)
      msg1 = create_message!(space.id, p.id)
      msg2 = create_message!(space.id, p.id)

      {:ok, t1} = Chat.create_thread_for_message(space.id, msg1.id)
      {:ok, t2} = Chat.create_thread_for_message(space.id, msg2.id)

      assert t1.id != t2.id
    end
  end

  # ── get_thread/1 ─────────────────────────────────────────────────────────────

  describe "get_thread/1" do
    test "returns the thread by id" do
      space = create_space!()
      {:ok, thread} = Chat.create_thread(space.id, %{title: "Fetched"})

      assert Chat.get_thread(thread.id).id == thread.id
    end

    test "returns nil for unknown id" do
      assert is_nil(Chat.get_thread(Ecto.UUID.generate()))
    end
  end

  # ── list_threads/1 ───────────────────────────────────────────────────────────

  describe "list_threads/1" do
    test "returns threads for a space, oldest first" do
      space = create_space!()
      {:ok, t1} = Chat.create_thread(space.id, %{title: "First"})
      {:ok, t2} = Chat.create_thread(space.id, %{title: "Second"})

      ids = Chat.list_threads(space.id) |> Enum.map(& &1.id)
      assert ids == [t1.id, t2.id]
    end

    test "does not leak threads from another space" do
      space1 = create_space!("space-a")
      space2 = create_space!("space-b")

      {:ok, _} = Chat.create_thread(space1.id)

      assert Chat.list_threads(space2.id) == []
    end
  end

  # ── reply_to_thread/3 ────────────────────────────────────────────────────────

  describe "reply_to_thread/3" do
    test "creates a message with thread_id set" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)
      {:ok, thread} = Chat.create_thread_for_message(space.id, msg.id)

      {:ok, reply} =
        Chat.reply_to_thread(thread.id, p.id, %{
          content: "This is a reply",
          content_type: "text"
        })

      assert reply.thread_id == thread.id
      assert reply.space_id == space.id
      assert reply.content == "This is a reply"
    end

    test "returns :thread_not_found for unknown thread" do
      assert {:error, :thread_not_found} =
               Chat.reply_to_thread(Ecto.UUID.generate(), Ecto.UUID.generate(), %{
                 content: "reply"
               })
    end
  end
end
