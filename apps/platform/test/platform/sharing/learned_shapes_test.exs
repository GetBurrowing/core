defmodule Platform.Sharing.LearnedShapesTest do
  use Platform.DataCase, async: false
  alias Platform.{Accounts.User, Chat, Habits, Repo, Sharing}
  alias Platform.Sharing.{LearnedShapes, UsageBatcher, UsageReceiver}
  alias Platform.Feedback.GithubPublisher.Broker

  setup do
    parent = self()

    Req.Test.stub(Broker, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:wire, raw})
      Req.Test.json(conn, %{})
    end)

    {:ok, _} = Sharing.set(:usage_counts, true, :system)
    {:ok, _} = Sharing.set(:learned_default_shapes, true, :system)
    {:ok, _} = Sharing.set(:instruction_updates_stopped, false, :system)
    n = System.unique_integer([:positive])

    {:ok, room} =
      Chat.create_space(%{
        name: "SENTINEL_PRIVATE_BODY #{n}",
        slug: "shape-wire-#{n}",
        kind: "channel"
      })

    users =
      for i <- 1..5 do
        Repo.insert!(%User{
          name: "SENTINEL_PERSON #{i}",
          email: "sentinel-#{n}-#{i}@example.test",
          oidc_sub: "wire-#{n}-#{i}"
        })
      end

    %{users: users, room: room}
  end

  defp observe(user, room, target) do
    {:ok, _} =
      Habits.record(%{
        actor_user_id: user.id,
        space_id: room.id,
        action: "chat.message_attention",
        target_type: "user",
        target_id: target.id,
        outcome: "accepted",
        rung: "rank",
        source_message_id: Ecto.UUID.generate()
      })
  end

  test "four-user buckets never reach the wire; five-user shapes share the actual common batch",
       %{users: users, room: room} do
    pid = start_supervised!({UsageBatcher, interval_ms: :manual})
    Req.Test.allow(Broker, self(), pid)
    :sys.get_state(pid)
    for user <- Enum.take(users, 4), do: observe(user, room, List.last(users))
    assert LearnedShapes.snapshot() == []
    assert {:sent, _} = UsageBatcher.flush(pid)
    assert_receive {:wire, first}
    assert Jason.decode!(first)["learned_default_shapes"] == []
    observe(List.last(users), room, List.last(users))
    assert {:sent, _} = UsageBatcher.flush(pid)
    assert_receive {:wire, second}
    body = Jason.decode!(second)
    assert [shape] = body["learned_default_shapes"]

    assert Enum.sort(Map.keys(shape)) ==
             ~w(accept_rate_bucket action pack_provenance rung signal_count_bucket user_count variant)

    assert shape["user_count"] == 5
    assert shape["accept_rate_bucket"] == 1.0
    assert shape["pack_provenance"] == "unavailable"

    for sentinel <-
          ["SENTINEL_PRIVATE_BODY", "SENTINEL_PERSON", "example.test", room.id] ++
            Enum.map(users, & &1.id),
        do: refute(second =~ sentinel)

    assert {:ok, 0} = UsageReceiver.record(body)
    assert {:ok, 0} = UsageReceiver.record(body)
    assert Repo.aggregate("sharing_instruction_outcomes", :count) == 1
    {:ok, _} = Sharing.set(:learned_default_shapes, false, :system)
    assert {:error, :sharing_disabled} = Broker.post_usage(body)
    refute_receive {:wire, _}
    {:ok, _} = Sharing.set(:learned_default_shapes, true, :system)
    {:ok, _} = Sharing.set(:usage_counts, false, :system)
    assert {:error, :sharing_disabled} = Broker.post_usage(body)
    refute_receive {:wire, _}
    {:ok, _} = Sharing.set(:usage_counts, true, :system)
    {:ok, _} = Sharing.set(:instruction_updates_stopped, true, :system)
    assert {:error, :sharing_disabled} = Broker.post_usage(body)
    refute_receive {:wire, _}
  end

  test "receiver repeats exact shape fields, bounds and suppression even for a forged client", %{
    users: users,
    room: room
  } do
    for user <- users, do: observe(user, room, List.last(users))
    assert [shape] = LearnedShapes.snapshot()
    assert LearnedShapes.valid?([shape])
    refute LearnedShapes.valid?([Map.put(shape, "content", "SENTINEL_PRIVATE_BODY")])
    refute LearnedShapes.valid?([%{shape | "user_count" => 4}])
    refute LearnedShapes.valid?([%{shape | "pack_provenance" => "new-current-version"}])

    refute LearnedShapes.valid?([
             %{shape | "variant" => Map.put(shape["variant"], "actor_id", hd(users).id)}
           ])

    refute LearnedShapes.valid?(List.duplicate(shape, 1001))
  end
end
