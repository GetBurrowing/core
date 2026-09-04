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

  # Task 01a06d01 stage 2. `proven` records what core OBSERVED, so the tests
  # that matter are the ones that pin what it does NOT record: a proof must
  # not survive a new session, and a capability with no inbound frame must
  # stay absent rather than defaulting to anything.
  describe "prove/2" do
    test "stamps the named capability" do
      RuntimePresence.track("rt-prove-1")

      RuntimePresence.prove("rt-prove-1", "chat_reply")

      assert %{proven: %{"chat_reply" => %DateTime{}}} = RuntimePresence.status("rt-prove-1")
    end

    test "PRESERVES connected_at — it is not track/1" do
      RuntimePresence.track("rt-prove-2")
      initial = RuntimePresence.status("rt-prove-2")

      Process.sleep(10)
      RuntimePresence.prove("rt-prove-2", "meeting_voice")
      after_prove = RuntimePresence.status("rt-prove-2")

      # Equality with the pre-call value, not merely "a DateTime is present":
      # a whole-entry overwrite would leave a perfectly well-formed timestamp
      # here while silently converting the session age into a rolling clock.
      # That shipped once already and was fixed in `e752bdce`.
      assert after_prove.connected_at == initial.connected_at
      assert DateTime.compare(after_prove.last_seen_at, initial.last_seen_at) == :gt
    end

    test "upserts rather than raising when the runtime is not tracked" do
      refute RuntimePresence.online?("rt-prove-3")

      RuntimePresence.prove("rt-prove-3", "chat_reply")

      status = RuntimePresence.status("rt-prove-3")
      assert %{connected_at: %DateTime{}, last_seen_at: %DateTime{}} = status
      assert Map.has_key?(status.proven, "chat_reply")
    end

    test "a second proof of the same capability advances it in place" do
      RuntimePresence.prove("rt-prove-4", "chat_reply")
      first = RuntimePresence.status("rt-prove-4").proven["chat_reply"]

      Process.sleep(10)
      RuntimePresence.prove("rt-prove-4", "chat_reply")
      second = RuntimePresence.status("rt-prove-4").proven["chat_reply"]

      assert DateTime.compare(second, first) == :gt
      assert map_size(RuntimePresence.status("rt-prove-4").proven) == 1
    end

    test "the map is bounded, and the cap drops the NEW key rather than an observed one" do
      RuntimePresence.prove("rt-prove-5", "chat_reply")

      for i <- 1..40, do: RuntimePresence.prove("rt-prove-5", "flood_#{i}")

      proven = RuntimePresence.status("rt-prove-5").proven

      assert map_size(proven) <= 16
      # The first thing core actually observed is still on the record.
      assert Map.has_key?(proven, "chat_reply")
    end
  end

  describe "proven across session boundaries" do
    test "track/1 clears proven — a dead process's proof must not survive" do
      RuntimePresence.prove("rt-session-1", "chat_reply")
      assert Map.has_key?(RuntimePresence.status("rt-session-1").proven, "chat_reply")

      # The runtime reconnects. This is a different OS process, possibly on a
      # different build: nothing the previous one demonstrated carries over.
      RuntimePresence.track("rt-session-1")

      assert RuntimePresence.status("rt-session-1").proven == %{}
    end

    test "touch/1 preserves proven — a heartbeat neither adds nor erases evidence" do
      RuntimePresence.prove("rt-session-2", "meeting_voice")
      before = RuntimePresence.status("rt-session-2").proven

      RuntimePresence.touch("rt-session-2")

      assert RuntimePresence.status("rt-session-2").proven == before
    end

    test "track/1 and touch/1 both seed an empty proven map" do
      RuntimePresence.track("rt-session-3")
      assert RuntimePresence.status("rt-session-3").proven == %{}

      RuntimePresence.touch("rt-session-4")
      assert RuntimePresence.status("rt-session-4").proven == %{}
    end
  end
end
