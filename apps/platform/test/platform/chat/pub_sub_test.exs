defmodule Platform.Chat.PubSubTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.PubSub, as: ChatPubSub

  describe "space_topic/1" do
    test "returns expected topic string" do
      assert ChatPubSub.space_topic("abc-123") == "chat:space:abc-123"
    end
  end

  describe "subscribe/1 and broadcast/2" do
    test "subscribed process receives broadcast" do
      space_id = Ecto.UUID.generate()
      ChatPubSub.subscribe(space_id)
      ChatPubSub.broadcast(space_id, {:test_event, "hello"})
      assert_receive {:test_event, "hello"}, 500
    end

    test "non-subscribed process does not receive broadcast" do
      space_id = Ecto.UUID.generate()
      # intentionally not subscribing
      ChatPubSub.broadcast(space_id, {:test_event, "ignored"})
      refute_receive {:test_event, "ignored"}, 200
    end

    test "unsubscribed process no longer receives events" do
      space_id = Ecto.UUID.generate()
      ChatPubSub.subscribe(space_id)
      ChatPubSub.unsubscribe(space_id)
      ChatPubSub.broadcast(space_id, {:test_event, "after_unsub"})
      refute_receive {:test_event, "after_unsub"}, 200
    end
  end

  describe "broadcast_from/3" do
    test "sender does not receive its own broadcast" do
      space_id = Ecto.UUID.generate()
      ChatPubSub.subscribe(space_id)
      ChatPubSub.broadcast_from(space_id, self(), {:test_event, "self"})
      refute_receive {:test_event, "self"}, 200
    end

    test "other subscribers receive broadcast_from" do
      space_id = Ecto.UUID.generate()
      parent = self()

      # spawn a subscriber process
      subscriber =
        spawn(fn ->
          ChatPubSub.subscribe(space_id)
          send(parent, :subscribed)

          receive do
            msg -> send(parent, {:got, msg})
          after
            1000 -> send(parent, :timeout)
          end
        end)

      assert_receive :subscribed, 500
      ChatPubSub.broadcast_from(space_id, self(), {:test_event, "others"})
      assert_receive {:got, {:test_event, "others"}}, 500
      Process.exit(subscriber, :kill)
    end
  end
end
