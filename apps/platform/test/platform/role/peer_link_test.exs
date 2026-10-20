defmodule Platform.Role.PeerLinkTest do
  @moduledoc """
  The web node's link to its full peer (task 01a155a6 stage 3). The connect
  and monitor functions are injected, so the reconnect loop runs on a node
  that is not distributed.
  """

  use ExUnit.Case, async: true

  alias Platform.Role.PeerLink

  @peer :"platform@core-platform"

  # A connect fun that reports each attempt to the test and answers from a
  # script: the head of the list, then the last answer forever.
  defp scripted_connect(answers) do
    test_pid = self()
    {:ok, script} = Agent.start_link(fn -> answers end)

    fn peer ->
      answer =
        Agent.get_and_update(script, fn
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end)

      send(test_pid, {:connect_attempt, peer, answer})
      answer
    end
  end

  defp start_link!(answers, opts \\ []) do
    name = Module.concat(PeerLink, "Test#{System.unique_integer([:positive])}")

    pid =
      start_supervised!(
        {PeerLink,
         Keyword.merge(
           [
             name: name,
             peer: @peer,
             connect: scripted_connect(answers),
             monitor: fn true -> :ok end,
             interval_ms: 20
           ],
           opts
         )}
      )

    {pid, name}
  end

  test "no peer configured: the link does not start" do
    assert PeerLink.init(peer: nil) == :ignore
  end

  test "retries every interval until the connect succeeds, then stops dialling" do
    {_pid, name} = start_link!([false, false, true])

    assert_receive {:connect_attempt, @peer, false}, 500
    assert_receive {:connect_attempt, @peer, false}, 500
    assert_receive {:connect_attempt, @peer, true}, 500
    assert PeerLink.connected?(name)
    refute_receive {:connect_attempt, _, _}, 100
  end

  test "reconnects after nodedown" do
    # A slow retry, so `connected?` is read inside the disconnected window.
    {pid, name} = start_link!([true, false, true], interval_ms: 300)

    assert_receive {:connect_attempt, @peer, true}, 500
    assert PeerLink.connected?(name)

    send(pid, {:nodedown, @peer})

    assert_receive {:connect_attempt, @peer, false}, 500
    refute PeerLink.connected?(name)
    assert_receive {:connect_attempt, @peer, true}, 500
    assert PeerLink.connected?(name)
  end

  test "a nodedown for another node is ignored" do
    {pid, name} = start_link!([true])
    assert_receive {:connect_attempt, @peer, true}, 500

    send(pid, {:nodedown, :other@host})

    refute_receive {:connect_attempt, _, _}, 100
    assert PeerLink.connected?(name)
  end

  test "connected?/1 is false when no link is running" do
    refute PeerLink.connected?(Module.concat(PeerLink, "NotStarted"))
  end
end
