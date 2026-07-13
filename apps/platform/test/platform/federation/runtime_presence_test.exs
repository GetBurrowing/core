defmodule Platform.Federation.RuntimePresenceTest do
  use ExUnit.Case, async: false

  alias Platform.Federation.RuntimePresence

  setup do
    on_exit(fn ->
      Agent.update(RuntimePresence, fn _ -> %{} end)
    end)

    :ok
  end

  describe "touch/1 self-heals when the entry is missing" do
    test "upserts a fresh entry when the runtime is not tracked" do
      refute RuntimePresence.online?("rt-heal-1")

      RuntimePresence.touch("rt-heal-1")

      assert RuntimePresence.online?("rt-heal-1")

      status = RuntimePresence.status("rt-heal-1")
      assert %{connected_at: %DateTime{}, last_seen_at: %DateTime{}} = status
      assert status.connected_at == status.last_seen_at
    end

    test "updates last_seen_at without resetting connected_at when entry exists" do
      RuntimePresence.track("rt-heal-2")
      initial = RuntimePresence.status("rt-heal-2")

      Process.sleep(10)
      RuntimePresence.touch("rt-heal-2")
      after_touch = RuntimePresence.status("rt-heal-2")

      assert after_touch.connected_at == initial.connected_at
      assert DateTime.compare(after_touch.last_seen_at, initial.last_seen_at) == :gt
    end

    test "recovers presence after the Agent state was cleared out from under it" do
      RuntimePresence.track("rt-heal-3")
      assert RuntimePresence.online?("rt-heal-3")

      Agent.update(RuntimePresence, fn _ -> %{} end)
      refute RuntimePresence.online?("rt-heal-3")

      RuntimePresence.touch("rt-heal-3")
      assert RuntimePresence.online?("rt-heal-3")
    end
  end
end
