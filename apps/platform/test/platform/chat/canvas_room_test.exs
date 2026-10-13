defmodule Platform.Chat.CanvasRoomTest do
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Chat
  alias Platform.Chat.CanvasRoom
  alias Platform.Chat.CanvasRoom.{Event, Record}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo

  @node "proto-1"

  setup do
    {:ok, space} =
      Chat.create_space(%{
        name: "Canvas Room Test",
        slug: "cr-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Author",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Room"
      })

    previous = Application.get_env(:platform, CanvasRoom)

    on_exit(fn ->
      stop_rooms(canvas.id)

      if previous,
        do: Application.put_env(:platform, CanvasRoom, previous),
        else: Application.delete_env(:platform, CanvasRoom)
    end)

    %{canvas: canvas, a: actor("A"), b: actor("B")}
  end

  defp actor(name), do: %{type: "user", id: Ecto.UUID.generate(), display_name: name}

  defp put_config(kv) do
    current = Application.get_env(:platform, CanvasRoom, [])
    Application.put_env(:platform, CanvasRoom, Keyword.merge(current, kv))
  end

  defp stop_rooms(canvas_id) do
    Platform.Chat.Registry
    |> Registry.select([{{{:canvas_room, canvas_id, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> Enum.each(&CanvasRoom.stop(canvas_id, &1))
  end

  defp record(canvas_id, node_id \\ @node) do
    Repo.one(from(r in Record, where: r.canvas_id == ^canvas_id and r.node_id == ^node_id))
  end

  defp events(%Record{id: id}),
    do: Repo.all(from(e in Event, where: e.room_id == ^id, order_by: e.seq))

  defp event_count(canvas_id) do
    case record(canvas_id) do
      nil -> 0
      rec -> length(events(rec))
    end
  end

  defp eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition not met before the deadline")
      else
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end

  defp viewer do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp inc, do: %{"type" => "state.increment", "key" => "n"}

  # MUTATION NOTE (task 01a1316b-84fa stage 1): replacing this body with a
  # read-then-set in the caller —
  #   {:ok, %{state: s}} = CanvasRoom.snapshot(c, n)
  #   CanvasRoom.apply_op(c, n, actor, %{"type" => "state.set", "key" => "n",
  #     "value" => (s["keys"]["n"] || 0) + 1})
  # — must make the concurrency test fail (lost updates: final < 20).
  defp increment(canvas_id, actor),
    do: CanvasRoom.apply_op(canvas_id, @node, actor, inc())

  describe "concurrency" do
    test "20 simultaneous increments from two actors land exactly", %{canvas: c, a: a, b: b} do
      put_config(persist_debounce_ms: 10_000)

      results =
        (List.duplicate(a, 10) ++ List.duplicate(b, 10))
        |> Enum.map(fn actor -> Task.async(fn -> increment(c.id, actor) end) end)
        |> Task.await_many(10_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      assert results |> Enum.map(fn {:ok, %{seq: seq}} -> seq end) |> Enum.sort() ==
               Enum.to_list(1..20)

      assert {:ok, %{seq: 20, state: %{"keys" => %{"n" => 20}}}} =
               CanvasRoom.snapshot(c.id, @node)

      :ok = CanvasRoom.stop(c.id, @node)

      rec = record(c.id)
      assert rec.seq == 20
      assert rec.state["keys"]["n"] == 20
      rows = events(rec)
      assert Enum.map(rows, & &1.seq) == Enum.to_list(1..20)
      assert Enum.count(rows, &(&1.actor_id == a.id)) == 10
      assert Enum.count(rows, &(&1.actor_id == b.id)) == 10
      assert Enum.all?(rows, &(&1.actor_type == "user" and &1.op == inc()))
    end
  end

  describe "persistence" do
    test "ops are flushed in one batch after the debounce", %{canvas: c, a: a} do
      put_config(persist_debounce_ms: 100)

      for _ <- 1..3, do: assert({:ok, _} = increment(c.id, a))
      assert record(c.id) == nil

      eventually(fn -> match?(%Record{seq: 3}, record(c.id)) end)
      assert length(events(record(c.id))) == 3
    end

    test "a graceful stop inside the debounce window still persists, and a restart resumes",
         %{canvas: c, a: a} do
      put_config(persist_debounce_ms: 60_000)

      {:ok, _} = increment(c.id, a)

      {:ok, %{result: id}} =
        CanvasRoom.apply_op(c.id, @node, a, %{
          "type" => "collection.add",
          "name" => "notes",
          "item" => %{"t" => "x"}
        })

      assert record(c.id) == nil
      :ok = CanvasRoom.stop(c.id, @node)
      assert CanvasRoom.whereis(c.id, @node) == nil

      rec = record(c.id)
      assert rec.seq == 2
      assert rec.state == %{"keys" => %{"n" => 1}, "collections" => %{"notes" => [%{"t" => "x", "id" => id}]}}
      # A replay reproduces the add: the logged op carries the assigned id.
      assert [_, %Event{op: %{"type" => "collection.add", "id" => ^id}}] = events(rec)

      assert {:ok, %{seq: 2, state: state}} = CanvasRoom.snapshot(c.id, @node)
      assert state == rec.state
      assert {:ok, %{seq: 3, result: 2}} = increment(c.id, a)
      :ok = CanvasRoom.stop(c.id, @node)
      assert %Record{seq: 3} = record(c.id)
      assert length(events(record(c.id))) == 3
    end

    test "a failed flush is logged and keeps the buffer", %{canvas: c, a: a} do
      put_config(persist_debounce_ms: 50)
      {:ok, _} = increment(c.id, a)
      pid = CanvasRoom.whereis(c.id, @node)

      # Pull the canvas out from under the room: the snapshot's FK now fails.
      Repo.delete_all(from(x in "chat_canvases", where: x.id == type(^c.id, :binary_id)))

      # The debounce fires at 50 ms and is re-armed after each failure.
      log = capture_log(fn -> Process.sleep(300) end)

      assert log =~ "CanvasRoom flush failed"
      assert log =~ "keeping 1 buffered op(s)"
      assert Process.alive?(pid)
      assert [%{seq: 1}] = :sys.get_state(pid).buffer
      assert :sys.get_state(pid).timers |> Map.has_key?(:persist)

      capture_log(fn -> :ok = CanvasRoom.stop(c.id, @node) end)
    end

    test "a missing canvas or a malformed id is refused", %{a: a} do
      assert {:error, :canvas_not_found} = CanvasRoom.apply_op(Ecto.UUID.generate(), @node, a, inc())
      assert {:error, :invalid_canvas_id} = CanvasRoom.apply_op("not-a-uuid", @node, a, inc())
      assert {:error, :invalid_node_id} = CanvasRoom.apply_op(Ecto.UUID.generate(), "", a, inc())
    end

    test "an actor without a type and id is refused", %{canvas: c} do
      assert {:error, :invalid_actor} = CanvasRoom.apply_op(c.id, @node, %{id: "x"}, inc())
      assert {:error, :invalid_actor} = CanvasRoom.join(c.id, @node, self(), %{type: "bot", id: "x"})
    end
  end

  describe "timers" do
    test "a scheduled timer fires (positive control) and broadcasts", %{canvas: c} do
      ChatPubSub.subscribe_canvas_room(c.id, @node)
      {:ok, _ref} = CanvasRoom.schedule_timer(c.id, @node, :t, 20, :ping)
      assert_receive {:canvas_room_timer, cid, @node, :t, :ping}, 1_000
      assert cid == c.id
    end

    test "a cancelled timer does not fire", %{canvas: c} do
      ChatPubSub.subscribe_canvas_room(c.id, @node)
      {:ok, ref} = CanvasRoom.schedule_timer(c.id, @node, :t, 50, :ping)
      :ok = CanvasRoom.cancel_timer(c.id, @node, :t)
      assert Process.read_timer(ref) == false
      refute_receive {:canvas_room_timer, _, _, :t, _}, 200
    end

    test "every timer is cancelled on stop", %{canvas: c, a: a} do
      put_config(persist_debounce_ms: 60_000)
      ChatPubSub.subscribe_canvas_room(c.id, @node)
      {:ok, _} = increment(c.id, a)
      {:ok, ref} = CanvasRoom.schedule_timer(c.id, @node, :t, 150, :ping)
      %{timers: timers} = :sys.get_state(CanvasRoom.whereis(c.id, @node))
      assert Map.keys(timers) |> Enum.sort() == [:idle_stop, :persist, :t]
      refs = for {_name, {r, _token}} <- timers, do: r
      assert ref in refs

      :ok = CanvasRoom.stop(c.id, @node)

      # read_timer is false only for a timer that fired or was cancelled; a
      # live timer to a dead pid would still report its remaining ms.
      assert Enum.all?(refs, &(Process.read_timer(&1) == false))
      refute_receive {:canvas_room_timer, _, _, :t, _}, 300
    end
  end

  describe "idle stop" do
    test "the room flushes and stops idle_stop_ms after its last viewer dies", %{canvas: c, a: a} do
      put_config(idle_stop_ms: 50, persist_debounce_ms: 60_000)
      v = viewer()
      {:ok, %{room_pid: room}} = CanvasRoom.join(c.id, @node, v, a)
      {:ok, _} = increment(c.id, a)
      mon = Process.monitor(room)

      Process.sleep(120)
      assert Process.alive?(room), "a room with a live viewer must not idle-stop"

      send(v, :stop)
      assert_receive {:DOWN, ^mon, :process, ^room, :normal}, 1_000
      assert CanvasRoom.whereis(c.id, @node) == nil
      assert %Record{seq: 1} = record(c.id)
    end

    test "a join cancels a pending idle stop", %{canvas: c, a: a} do
      put_config(idle_stop_ms: 100)
      {:ok, _} = CanvasRoom.snapshot(c.id, @node)
      room = CanvasRoom.whereis(c.id, @node)
      assert Map.has_key?(:sys.get_state(room).timers, :idle_stop)

      {:ok, %{room_pid: ^room}} = CanvasRoom.join(c.id, @node, viewer(), a)
      refute Map.has_key?(:sys.get_state(room).timers, :idle_stop)
      Process.sleep(250)
      assert Process.alive?(room)
    end
  end

  describe "presence" do
    test "diffs on join, leave and DOWN; one pid is one viewer", %{canvas: c, a: a, b: b} do
      ChatPubSub.subscribe_canvas_room(c.id, @node)
      cid = c.id
      v1 = viewer()
      v2 = viewer()
      v3 = viewer()

      {:ok, %{presence: [%{id: aid, viewers: 1}]}} = CanvasRoom.join(c.id, @node, v1, a)
      assert aid == a.id
      assert_receive {:canvas_room_presence, ^cid, @node, [%{viewers: 1}]}

      # Same pid again: still one viewer.
      {:ok, %{presence: [%{viewers: 1}]}} = CanvasRoom.join(c.id, @node, v1, a)
      assert_receive {:canvas_room_presence, ^cid, @node, [%{viewers: 1}]}

      # Same actor, second pid (chat panel + mobile overlay): two viewers.
      {:ok, _} = CanvasRoom.join(c.id, @node, v2, a)
      assert_receive {:canvas_room_presence, ^cid, @node, [%{id: ^aid, viewers: 2}]}

      {:ok, %{presence: list}} = CanvasRoom.join(c.id, @node, v3, b)
      assert_receive {:canvas_room_presence, ^cid, @node, ^list}
      assert Enum.sort(Enum.map(list, &{&1.id, &1.viewers})) == Enum.sort([{a.id, 2}, {b.id, 1}])

      :ok = CanvasRoom.leave(c.id, @node, v2)
      assert_receive {:canvas_room_presence, ^cid, @node, list}
      assert Enum.sort(Enum.map(list, &{&1.id, &1.viewers})) == Enum.sort([{a.id, 1}, {b.id, 1}])

      send(v3, :stop)
      assert_receive {:canvas_room_presence, ^cid, @node, [%{id: ^aid, viewers: 1, display_name: "A"}]}, 1_000
    end
  end

  describe "ephemeral" do
    test "broadcast only: subscribers receive it, the room runs no query, nothing is logged",
         %{canvas: c, a: a} do
      {:ok, _} = CanvasRoom.join(c.id, @node, viewer(), a)
      {:ok, _} = increment(c.id, a)
      :ok = CanvasRoom.stop(c.id, @node)
      {:ok, %{room_pid: room}} = CanvasRoom.join(c.id, @node, viewer(), a)
      rows_before = event_count(c.id)
      assert rows_before == 1

      ChatPubSub.subscribe_canvas_room(c.id, @node)
      test_pid = self()
      handler = "canvas-room-ephemeral-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:platform, :repo, :query],
        fn _event, _measure, meta, _ ->
          if self() in [room, test_pid], do: send(test_pid, {:query, meta[:source]})
        end,
        nil
      )

      try do
        for i <- 1..50 do
          :ok = CanvasRoom.ephemeral(c.id, @node, a, "cursor", %{"x" => i, "y" => i})
        end

        # A call after the casts: every cast is processed when it returns.
        {:ok, _} = CanvasRoom.snapshot(c.id, @node)
      after
        :telemetry.detach(handler)
      end

      refute_received {:query, _}

      received = collect_ephemeral([])
      # 30/s with a burst of 30: the excess of 50 back-to-back casts is dropped.
      assert length(received) in 30..32
      assert hd(received) == {"cursor", %{"x" => 1, "y" => 1}, a.id}

      assert event_count(c.id) == rows_before
      assert {:ok, %{seq: 1}} = CanvasRoom.snapshot(c.id, @node)
      assert Process.alive?(room)
    end

    test "an oversized payload is dropped, and no room is started for it", %{canvas: c, a: a} do
      {:ok, _} = CanvasRoom.join(c.id, @node, viewer(), a)
      ChatPubSub.subscribe_canvas_room(c.id, @node)
      big = String.duplicate("x", CanvasRoom.limits().max_ephemeral_bytes)
      :ok = CanvasRoom.ephemeral(c.id, @node, a, "cursor", %{"b" => big})
      {:ok, _} = CanvasRoom.snapshot(c.id, @node)
      refute_received {:canvas_room_ephemeral, _, _, _, _, _}

      :ok = CanvasRoom.ephemeral(c.id, "never-started", a, "cursor", %{})
      assert CanvasRoom.whereis(c.id, "never-started") == nil
    end
  end

  defp collect_ephemeral(acc) do
    receive do
      {:canvas_room_ephemeral, _cid, @node, channel, payload, actor_id} ->
        collect_ephemeral([{channel, payload, actor_id} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "rate limit" do
    test "the 41st durable op in a burst is :rate_limited; another actor is not", %{
      canvas: c,
      a: a,
      b: b
    } do
      {:ok, _} = CanvasRoom.snapshot(c.id, @node)

      results = for _ <- 1..41, do: increment(c.id, a)
      assert Enum.take(results, 40) |> Enum.all?(&match?({:ok, _}, &1))
      assert List.last(results) == {:error, :rate_limited}

      assert {:ok, %{seq: 41}} = increment(c.id, b)
    end
  end

  describe "diffs" do
    test "each accepted op broadcasts its seq, diff and actor on the room topic only", %{
      canvas: c,
      a: a
    } do
      ChatPubSub.subscribe_canvas_room(c.id, @node)
      ChatPubSub.subscribe_canvas(c.id)
      cid = c.id
      aid = a.id

      {:ok, %{seq: 1, result: 1}} = increment(c.id, a)

      assert_receive {:canvas_room_diff, ^cid, @node, 1,
                      %{"kind" => "key", "key" => "n", "value" => 1} = diff, ^aid}

      refute Map.has_key?(diff, "result")
      refute_received {:canvas_patched, _, _, _}
      refute_received {:canvas_event, _, _}

      assert {:error, :unknown_op} = CanvasRoom.apply_op(c.id, @node, a, %{"type" => "nope"})
      refute_receive {:canvas_room_diff, _, _, _, _, _}, 50
      assert {:ok, %{seq: 1}} = CanvasRoom.snapshot(c.id, @node)
    end
  end
end
