defmodule Platform.ExternalAgents.EphemeralCredentialsTest do
  @moduledoc """
  Tests for `Platform.ExternalAgents.EphemeralCredentials` — the
  GenServer-owned ETS store for ephemeral external-agent secrets.

  The store is started under the application supervisor (see
  `Platform.Application`), so these tests exercise the already-running
  singleton. To avoid cross-test bleed we key every fixture on a unique
  agent_id derived from the test name.
  """

  # async: false — we kill the singleton GenServer in one test and need
  # supervisor restart to be deterministic without interference.
  use ExUnit.Case, async: false

  alias Platform.ExternalAgents.EphemeralCredentials

  defp unique_agent_id(label) do
    "agent-#{label}-#{System.unique_integer([:positive])}"
  end

  describe "put/2 + get/1" do
    test "round-trips a secret" do
      agent_id = unique_agent_id("roundtrip")
      assert :ok = EphemeralCredentials.put(agent_id, "shh-bearer-token")
      assert {:ok, "shh-bearer-token"} = EphemeralCredentials.get(agent_id)
    end

    test "put overwrites a previous value" do
      agent_id = unique_agent_id("overwrite")
      :ok = EphemeralCredentials.put(agent_id, "v1")
      :ok = EphemeralCredentials.put(agent_id, "v2")
      assert {:ok, "v2"} = EphemeralCredentials.get(agent_id)
    end
  end

  describe "get/1 on a missing key" do
    test "returns {:error, :not_found}" do
      assert {:error, :not_found} =
               EphemeralCredentials.get("definitely-not-stored-#{System.unique_integer()}")
    end
  end

  describe "delete/1" do
    test "clears the row; subsequent get returns :not_found" do
      agent_id = unique_agent_id("delete")
      :ok = EphemeralCredentials.put(agent_id, "ephemeral")
      assert {:ok, "ephemeral"} = EphemeralCredentials.get(agent_id)

      assert :ok = EphemeralCredentials.delete(agent_id)
      assert {:error, :not_found} = EphemeralCredentials.get(agent_id)
    end

    test "is idempotent on an absent key" do
      assert :ok = EphemeralCredentials.delete("never-existed-#{System.unique_integer()}")
    end
  end

  describe "GenServer restart" do
    test "kills the table; previously-put keys are gone after supervisor restart" do
      agent_id = unique_agent_id("restart")
      :ok = EphemeralCredentials.put(agent_id, "will-vanish")
      assert {:ok, "will-vanish"} = EphemeralCredentials.get(agent_id)

      # Capture the owner pid, kill it, wait for the supervisor to
      # restart the singleton, then assert the row is gone — the table
      # dies with its owner (decision 6: no orphaned secrets across
      # app restart).
      pid = Process.whereis(EphemeralCredentials)
      assert is_pid(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      new_pid = wait_for_restart(pid)
      assert is_pid(new_pid) and new_pid != pid

      assert {:error, :not_found} = EphemeralCredentials.get(agent_id)
    end
  end

  defp wait_for_restart(old_pid, attempts \\ 50)
  defp wait_for_restart(_old_pid, 0), do: flunk("EphemeralCredentials did not restart")

  defp wait_for_restart(old_pid, attempts) do
    case Process.whereis(EphemeralCredentials) do
      nil ->
        Process.sleep(20)
        wait_for_restart(old_pid, attempts - 1)

      ^old_pid ->
        Process.sleep(20)
        wait_for_restart(old_pid, attempts - 1)

      pid when is_pid(pid) ->
        pid
    end
  end
end
