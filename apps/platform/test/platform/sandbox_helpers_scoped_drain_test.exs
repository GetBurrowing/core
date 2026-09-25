# Pins the OWNERSHIP property of `Platform.SandboxHelpers.await_own_supervised_writes/2`
# — the one thing that makes a drain safe to run from an `async: true` case.
#
# The unconditional drain (`await_supervised_writes/1`) is ruled out for
# `async: true` and stays ruled out: concurrent modules share
# `Platform.TaskSupervisor`, so its child set belongs to other modules as much
# as to this one and waiting on it is waiting on an unrelated test. The scoped
# drain is only admissible if it can actually tell those apart, so that
# discrimination — not a green suite — is what this file measures, in both
# directions:
#
#   * EXCLUDES a foreign child (`test "…foreign…"`). Written first and shown RED
#     against a naive implementation that drains everything: with the foreign
#     child held alive past the deadline, an unfiltered poller returns
#     `{:timeout, _}` where `:ok` is required.
#   * INCLUDES its own child, transitively (the two `own`/`grandchild` tests).
#     Without these, "excludes everything" would pass the first test.
#
# Each test also asserts the MECHANISM it depends on rather than assuming it:
# that `Task.Supervisor.start_child/2` seeds `:"$callers"` in the child, that
# `Process.info(pid, :dictionary)` exposes it, and that the pid it names is the
# starting process. Those are the claims the filter is built on, so a change in
# OTP or Elixir that breaks them must fail here and not silently widen the drain.
#
# Deliberately NOT in scope: bare `spawn/1` children. They carry no `$callers`,
# never resolve a sandbox owner, and this drain cannot see them by construction
# — that is the INVERSE defect (task 01a06638 / PR #965) and conflating the two
# is how a "fix" gets aimed at the wrong layer. `test "a bare-spawn child is
# invisible…"` pins that as a stated limitation rather than leaving it implied.
defmodule Platform.SandboxHelpersScopedDrainTest do
  use ExUnit.Case, async: true

  alias Platform.SandboxHelpers

  @supervisor Platform.TaskSupervisor

  # Long enough that a foreign child is still alive well past the 200 ms
  # deadline below, so "did not wait for it" is unambiguous.
  @hold_ms 10_000

  # Long enough to be far outside poll jitter (`@poll_interval_ms` is 5 ms),
  # short enough that the test is cheap.
  @own_work_ms 300

  describe "await_own_supervised_writes/2 ownership filter" do
    test "EXCLUDES a foreign child: returns :ok promptly and does not wait for it" do
      {foreign_parent, foreign} = start_foreign_child()

      # The foreign child is genuinely under the supervisor being drained — so
      # an unfiltered poller cannot help but see it. Without this the test
      # could pass because there was nothing there at all.
      assert foreign in Task.Supervisor.children(@supervisor),
             "the foreign child is not under #{inspect(@supervisor)}, so this test " <>
               "is not exercising the filter"

      # The mechanism, asserted rather than assumed: the child's `$callers`
      # names the process that STARTED it, and does not name this test.
      callers = callers_of_live(foreign)

      assert foreign_parent in callers,
             "$callers of the foreign child does not name its starter — the filter's " <>
               "premise is wrong: #{inspect(callers)}"

      refute self() in callers,
             "$callers of the foreign child names THIS test (#{inspect(self())}), so " <>
               "the two cannot be distinguished by ownership and the unconditional-drain " <>
               "objection applies to the scoped drain too: #{inspect(callers)}"

      {elapsed, result} =
        timed(fn -> SandboxHelpers.await_own_supervised_writes(self(), timeout: 200) end)

      assert result == :ok,
             """
             The scoped drain waited for a child this test does not own.
             Got: #{inspect(result)} after #{elapsed}ms.

             This is the failure an UNFILTERED drain produces, and it is exactly why
             an unconditional drain is ruled out in `async: true`.
             """

      assert elapsed < 150,
             "returned :ok but took #{elapsed}ms — it was waiting on something; the " <>
               "own-child set was empty, so it should return on the first poll"

      assert Process.alive?(foreign),
             "the foreign child died during the call — the timing above measured nothing"

      stop_foreign_child(foreign_parent, foreign)
    end

    test "INCLUDES its own child: blocks until that child exits" do
      test_pid = self()

      # Held on `receive`, not `Process.sleep/1`: the child must be PROVABLY alive
      # when its dictionary is read, or a slow read sees a dead pid and blames
      # `$callers` seeding for a test-lifetime race. The `:own_started` handshake
      # also proves `Task.Supervised.noreply/4` has already run `put_callers/1` —
      # `start_child/2` returns before the child is scheduled at all.
      {:ok, mine} =
        Task.Supervisor.start_child(@supervisor, fn ->
          send(test_pid, {:own_started, self()})

          receive do
            :release -> :ok
          after
            @hold_ms -> :ok
          end
        end)

      ref = Process.monitor(mine)
      assert_receive {:own_started, ^mine}, 5_000

      assert self() in callers_of_live(mine),
             "$callers of a child started by this test does not name this test — " <>
               "`Task.Supervisor.start_child/2` did not seed the caller chain and the " <>
               "filter cannot work"

      # Released on a timer rather than by sleeping, so the child still runs for
      # `@own_work_ms` from here and the `elapsed` floor below keeps its meaning.
      Process.send_after(mine, :release, @own_work_ms)

      {elapsed, result} =
        timed(fn -> SandboxHelpers.await_own_supervised_writes(self(), timeout: 5_000) end)

      assert result == :ok,
             "the drain timed out on this test's own #{@own_work_ms}ms child: #{inspect(result)}"

      assert elapsed >= @own_work_ms - 50,
             """
             The drain returned after only #{elapsed}ms for a child that runs for
             #{@own_work_ms}ms, so it did not wait for it. A filter that excludes
             everything passes the foreign-child test above; this is what separates
             the two.
             """

      refute Process.alive?(mine),
             "the drain returned :ok while this test's own child was still alive"

      assert_receive {:DOWN, ^ref, :process, ^mine, _}, 5_000
    end

    test "INCLUDES a grandchild: ownership is the whole $callers chain, not its head" do
      test_pid = self()

      {:ok, child} =
        Task.Supervisor.start_child(@supervisor, fn ->
          {:ok, grandchild} =
            Task.Supervisor.start_child(@supervisor, fn ->
              send(test_pid, {:grandchild_started, self()})

              receive do
                :release -> :ok
              after
                @hold_ms -> :ok
              end
            end)

          send(test_pid, {:grandchild, grandchild})
        end)

      assert_receive {:grandchild, grandchild}, 5_000
      ref = Process.monitor(grandchild)
      assert_receive {:grandchild_started, ^grandchild}, 5_000

      chain = callers_of_live(grandchild)

      assert test_pid in chain,
             "a grandchild's $callers does not contain the test pid, so a transitive " <>
               "writer (which is the real audit path: test -> handler -> Repo) cannot " <>
               "be attributed: #{inspect(chain)}"

      refute hd(chain) == test_pid,
             "the grandchild's $callers HEAD is the test pid, so this test does not " <>
               "actually exercise the transitive case: #{inspect(chain)}"

      Process.send_after(grandchild, :release, @own_work_ms)

      {elapsed, result} =
        timed(fn -> SandboxHelpers.await_own_supervised_writes(test_pid, timeout: 5_000) end)

      assert result == :ok, "drain timed out on an owned grandchild: #{inspect(result)}"

      assert elapsed >= @own_work_ms - 50,
             "the drain returned after #{elapsed}ms and did not wait for the grandchild, " <>
               "so it is matching only the head of $callers"

      refute Process.alive?(grandchild)
      refute Process.alive?(child)
      assert_receive {:DOWN, ^ref, :process, ^grandchild, _}, 5_000
    end

    test "a timeout is REPORTED, not swallowed, and names the still-running count" do
      test_pid = self()

      {:ok, mine} =
        Task.Supervisor.start_child(@supervisor, fn ->
          send(test_pid, :started)

          receive do
            :release -> :ok
          after
            @hold_ms -> :ok
          end
        end)

      assert_receive :started, 5_000

      assert {:timeout, active} =
               SandboxHelpers.await_own_supervised_writes(test_pid, timeout: 50)

      assert active >= 1,
             "a timeout reported #{active} running children while one of ours was " <>
               "provably alive — the count is not the filtered set"

      send(mine, :release)
      await_death(mine)
    end

    test "a bare-spawn child is invisible to the scoped drain BY CONSTRUCTION" do
      test_pid = self()

      # Stated as a limitation, not a defect: this is the inverse family
      # (task 01a06638 / PR #965). A bare `spawn` carries no `$callers`, so it
      # never resolves a sandbox owner and no ownership-scoped drain can see it.
      # If this ever starts being visible, the two families have merged and the
      # moduledoc's `by construction` claim must be re-derived.
      bare =
        spawn(fn ->
          send(test_pid, :bare_started)

          receive do
            :release -> :ok
          after
            @hold_ms -> :ok
          end
        end)

      assert_receive :bare_started, 5_000

      refute bare in Task.Supervisor.children(@supervisor),
             "a bare-spawn process is under #{inspect(@supervisor)}, which cannot happen"

      bare_callers = callers_of_live(bare)

      assert bare_callers == [],
             "a bare-spawn process carries $callers: #{inspect(bare_callers)}"

      assert :ok = SandboxHelpers.await_own_supervised_writes(test_pid, timeout: 200)
      assert Process.alive?(bare)

      send(bare, :release)
      await_death(bare)
    end
  end

  # Task 01a0d265 stage 2. The quiesce is `drain_own_or_warn` plus the
  # terminal step that makes a fire-and-forget lifecycle edge quiescable at
  # all: its runner parks in a `receive` on a 30-minute budget, so no
  # wait-shaped drain can ever see it exit, and the owner-exit disconnect
  # happens unless the leftover children are terminated BEFORE the owner
  # stops. These tests pin the three load-bearing properties of that step:
  # it terminates THIS test's leftovers while the owner is alive, it leaves a
  # foreign child alone, and it leaves the children of an ALREADY-DEAD owner
  # untouched — the last one is what
  # `PlatformWeb.ConnCaseSupervisedOrphanBeyondDrainTest`'s construction
  # depends on, where the readings die with the children if the gate is
  # missing. There is no sandbox in this module, so the "owner" here is a
  # stand-in pid: the only thing the gate reads is `Process.alive?/1`.
  describe "quiesce_own_or_warn/3 terminal step" do
    test "terminates this test's leftover child while the owner stand-in is alive" do
      test_pid = self()

      {:ok, mine} =
        Task.Supervisor.start_child(@supervisor, fn ->
          send(test_pid, {:own_started, self()})

          receive do
            :release -> :ok
          after
            @hold_ms -> :ok
          end
        end)

      assert_receive {:own_started, ^mine}, 5_000
      # Monitor BEFORE the quiesce: the DOWN is the proof the child was
      # terminated by the terminal step (an exit signal is immediate, so the
      # message is in the mailbox well before the quiesce returns).
      ref = Process.monitor(mine)

      owner =
        spawn(fn ->
          receive do
            _msg -> :ok
          end
        end)

      {elapsed, :ok} =
        timed(fn -> SandboxHelpers.quiesce_own_or_warn(test_pid, owner, timeout: 200) end)

      assert elapsed < 3_000,
             "the terminal step took #{elapsed}ms — the drain and the terminations " <>
               "should both be sub-second at these deadlines"

      refute Process.alive?(mine),
             "the leftover child survived a quiesce with the owner alive — the edge " <>
               "leak this function exists to close is still open"

      assert_receive {:DOWN, ^ref, :process, ^mine, _}, 5_000
      assert Process.alive?(owner), "the owner stand-in was killed by its own quiesce"
      send(owner, :stop)
    end

    test "does not terminate a foreign child" do
      {foreign_parent, foreign} = start_foreign_child()

      owner =
        spawn(fn ->
          receive do
            _msg -> :ok
          end
        end)

      assert :ok = SandboxHelpers.quiesce_own_or_warn(self(), owner, timeout: 200)

      assert Process.alive?(foreign),
             "the quiesce terminated a child this test does not own — the scoping " <>
               "that makes the drain admissible in async mode does not hold for the " <>
               "terminal step"

      send(owner, :stop)
      stop_foreign_child(foreign_parent, foreign)
    end

    test "leaves the children of an already-dead owner untouched" do
      test_pid = self()

      {:ok, mine} =
        Task.Supervisor.start_child(@supervisor, fn ->
          send(test_pid, {:own_started, self()})

          receive do
            :release -> :ok
          after
            @hold_ms -> :ok
          end
        end)

      assert_receive {:own_started, ^mine}, 5_000

      owner =
        spawn(fn ->
          receive do
            _msg -> :ok
          end
        end)

      send(owner, :stop)
      await_death(owner)

      assert :ok = SandboxHelpers.quiesce_own_or_warn(test_pid, owner, timeout: 200)

      assert Process.alive?(mine),
             "the quiesce terminated children of a DEAD owner — the beyond-drain " <>
               "construction's orphans are parked exactly there, and their readings " <>
               "die with them"

      send(mine, :release)
      await_death(mine)
    end
  end

  describe "own_children/2" do
    test "returns [] when the supervisor is not running" do
      assert SandboxHelpers.own_children(self(), :no_such_supervisor_01a08b49) == []
    end

    test "a dead pid is not ours — Process.info/2 returns nil for it" do
      {:ok, mine} = Task.Supervisor.start_child(@supervisor, fn -> :ok end)
      await_death(mine)

      assert Process.info(mine, :dictionary) == nil,
             "Process.info/2 on a dead pid did not return nil, so the filter's " <>
               "dead-pid branch is guarding the wrong thing"

      refute mine in SandboxHelpers.own_children(self())
    end
  end

  # -- helpers --

  # A bare `spawn` does not inherit the spawner's process dictionary, so the
  # `Task.Supervisor` child it starts gets a `$callers` chain rooted at the
  # bare process — never at this test. That is what makes it foreign.
  defp start_foreign_child do
    test_pid = self()

    parent =
      spawn(fn ->
        {:ok, child} =
          Task.Supervisor.start_child(@supervisor, fn ->
            send(test_pid, {:foreign_started, self()})

            receive do
              :release -> :ok
            after
              @hold_ms -> :ok
            end
          end)

        send(test_pid, {:foreign_child, self(), child})

        receive do
          :stop -> :ok
        after
          @hold_ms -> :ok
        end
      end)

    assert_receive {:foreign_child, ^parent, child}, 5_000
    assert_receive {:foreign_started, ^child}, 5_000
    {parent, child}
  end

  defp stop_foreign_child(parent, child) do
    send(child, :release)
    send(parent, :stop)
    await_death(child)
    await_death(parent)
  end

  # Reads `:"$callers"` from a process that MUST be alive. The two ways of
  # getting nothing back are different facts and must not share a message:
  #
  #   * alive, no `$callers` key -> `[]`, and the caller's assertion reports
  #     that the chain was not seeded (true only because every caller first
  #     handshakes with the child, so its fun — and `put_callers/1` before it —
  #     has provably run);
  #   * dead -> `flunk/1` here. A dead pid's dictionary is unreadable, which
  #     says nothing about seeding; it means the test let its subject exit
  #     before reading it.
  defp callers_of_live(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case List.keyfind(dict, :"$callers", 0) do
          {_, callers} when is_list(callers) -> callers
          _ -> []
        end

      nil ->
        flunk("""
        #{inspect(pid)} is DEAD, so its $callers could not be read.

        This is a test-lifetime race — the process exited before this test read
        its dictionary. It is NOT evidence that `$callers` was unseeded; hold the
        process on `receive` until after the read.
        """)
    end
  end

  defp await_death(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end
end
