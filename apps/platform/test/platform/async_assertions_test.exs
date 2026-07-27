defmodule Platform.AsyncAssertionsTest do
  @moduledoc """
  Tests for the shared polling assertion in `test/support/async_assertions.ex`.

  A polling helper is exactly the kind of thing that can be silently wrong in a
  direction nobody notices: if `assert_eventually/3` never actually failed,
  every call site converted to it would pass vacuously and the suite would look
  *more* rigorous while proving less. So the failing paths are asserted on
  directly here, not just the passing ones.
  """
  use ExUnit.Case, async: true

  import Platform.AsyncAssertions

  describe "assert_eventually/3" do
    test "returns the truthy value so callers can assert on it further" do
      assert assert_eventually(fn -> %{status: :done} end) == %{status: :done}
    end

    test "evaluates the function immediately when it is already true" do
      started = System.monotonic_time(:millisecond)
      assert assert_eventually(fn -> true end, 5_000, 500)
      assert System.monotonic_time(:millisecond) - started < 400
    end

    test "succeeds once a condition owned by another process becomes true" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      assert assert_eventually(fn ->
               n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
               if n >= 3, do: n
             end) == 3
    end

    test "fails when the condition never becomes true" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_eventually(fn -> false end, 30, 10)
      end
    end

    test "the failure message names the LAST OBSERVED VALUE, not just 'falsy'" do
      # `nil` is falsy, so this is a value the poll genuinely re-observed on
      # every attempt — unlike a truthy term, which would have satisfied it.
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_eventually(fn -> nil end, 30, 10)
        end

      message = ExUnit.AssertionError.message(error)
      assert message =~ "Last observed value: nil"
      assert message =~ "polling every 10ms"
      assert message =~ "attempt(s)"
      assert message =~ "timed out after"
    end

    test "a bare-boolean predicate gets told its timeout carries no diagnosis" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_eventually(fn -> 1 == 2 end, 30, 10)
        end

      message = ExUnit.AssertionError.message(error)
      assert message =~ "Last observed value: false"
      assert message =~ "carries no diagnosis"
      assert message =~ "asserting on its shape separately"
    end

    test "polls more than once before giving up" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      assert_raise ExUnit.AssertionError, fn ->
        assert_eventually(fn -> Agent.update(counter, &(&1 + 1)) && false end, 60, 10)
      end

      assert Agent.get(counter, & &1) > 1
    end

    test "respects the timeout rather than hanging" do
      started = System.monotonic_time(:millisecond)

      assert_raise ExUnit.AssertionError, fn ->
        assert_eventually(fn -> nil end, 50, 10)
      end

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 40
      assert elapsed < 2_000
    end

    test "propagates a raise instead of retrying it until the deadline" do
      assert_raise ArgumentError, "boom", fn ->
        assert_eventually(fn -> raise ArgumentError, "boom" end, 5_000, 10)
      end
    end

    test "treats nil and false as not-yet, any other term as satisfied" do
      assert assert_eventually(fn -> 0 end) == 0
      assert assert_eventually(fn -> "" end) == ""
      assert assert_eventually(fn -> [] end) == []
    end
  end

  describe "eventually/3" do
    test "returns {:ok, value} without touching ExUnit assertions" do
      assert eventually(fn -> :ready end) == {:ok, :ready}
    end

    test "returns {:timeout, last_observed} instead of failing" do
      assert eventually(fn -> :not_yet_but_falsy_enough && false end, 30, 10) ==
               {:timeout, false}

      assert eventually(fn -> nil end, 30, 10) == {:timeout, nil}
    end
  end

  # A stand-in for `Platform.Orchestration.TaskRouter`: registers under the same
  # Registry with the same `:current_status` call, so `sync_router/2` exercises
  # the real lookup and the real call, but the barrier property can be asserted
  # without a database or a dispatch.
  defmodule StubRouter do
    @moduledoc false
    use GenServer

    def start_link(task_id) do
      GenServer.start_link(__MODULE__, :ok,
        name: {:via, Registry, {Platform.Orchestration.Registry, task_id}}
      )
    end

    @impl true
    def init(:ok), do: {:ok, %{}}

    @impl true
    def handle_call(:current_status, _from, state), do: {:reply, %{status: :running}, state}

    def handle_call(:block, _from, state) do
      Process.sleep(500)
      {:reply, :ok, state}
    end

    # Deliberately slow, and it emits its observable effect at the END. A test
    # that reads the effect without a barrier reads it too early.
    @impl true
    def handle_info({:slow_work, reply_to}, state) do
      Process.sleep(40)
      send(reply_to, :work_done)
      {:noreply, state}
    end
  end

  describe "sync_router/2" do
    setup do
      task_id = "stub-router-#{System.unique_integer([:positive])}"
      {:ok, pid} = StubRouter.start_link(task_id)
      {:ok, task_id: task_id, pid: pid}
    end

    test "drains work enqueued before it, so a non-blocking mailbox assertion is sound",
         %{task_id: task_id, pid: pid} do
      send(pid, {:slow_work, self()})

      # This is the whole point. `refute_received` here proves the effect is NOT
      # already visible, so the `assert_received` after the barrier cannot be
      # passing by accident of timing.
      refute_received :work_done

      assert sync_router(task_id) == :ok

      assert_received :work_done
    end

    test "fails with a message naming the task when no router is registered" do
      err =
        assert_raise ExUnit.AssertionError, fn ->
          sync_router("no-such-task-#{System.unique_integer([:positive])}")
        end

      assert err.message =~ "no TaskRouter registered"
      assert err.message =~ "no-such-task-"
    end

    test "fails with the exit reason rather than a bare GenServer.call exit on timeout",
         %{task_id: task_id, pid: pid} do
      # Wedge the router so the barrier cannot be answered inside its budget.
      spawn(fn -> GenServer.call(pid, :block, 5_000) end)
      Process.sleep(20)

      err =
        assert_raise ExUnit.AssertionError, fn -> sync_router(task_id, 50) end

      assert err.message =~ "could not reach the TaskRouter"
      assert err.message =~ "blocked past 50ms"
      assert err.message =~ ":timeout"
    end
  end
end
