defmodule Platform.Lifecycle.StepTest do
  # `async: false` is LOAD-BEARING, not caution. Every budget test below sets
  # `:lifecycle_step_timeout_ms` / `:lifecycle_edge_budget_ms` with
  # `Application.put_env/3`, which is VM-GLOBAL: a concurrent case reading
  # either knob would observe this file's injected value and fail, or worse,
  # this file would observe a sibling's and pass for the wrong reason. This
  # is the fourth instance of that family found in this repo; it is not
  # theoretical.
  use ExUnit.Case, async: false

  alias Platform.Lifecycle
  alias Platform.Lifecycle.Step
  alias Platform.Lifecycle.TestSteps

  setup do
    # Restore whatever was there — including "not set at all", which is the
    # shipped state and is NOT the same as set-to-the-default.
    step_before = Application.fetch_env(:platform, :lifecycle_step_timeout_ms)
    edge_before = Application.fetch_env(:platform, :lifecycle_edge_budget_ms)

    on_exit(fn ->
      restore(:lifecycle_step_timeout_ms, step_before)
      restore(:lifecycle_edge_budget_ms, edge_before)
    end)

    :ok
  end

  defp restore(key, :error), do: Application.delete_env(:platform, key)
  defp restore(key, {:ok, value}), do: Application.put_env(:platform, key, value)

  describe "step_timeout_ms/0" do
    test "falls back to the compiled default when nothing is injected" do
      Application.delete_env(:platform, :lifecycle_step_timeout_ms)

      assert Lifecycle.step_timeout_ms() == Lifecycle.default_step_timeout_ms()
    end

    test "returns an injected value" do
      Application.put_env(:platform, :lifecycle_step_timeout_ms, 25)

      assert Lifecycle.step_timeout_ms() == 25
    end

    test "the shipped default is 30 minutes and is unmoved by injection" do
      Application.put_env(:platform, :lifecycle_step_timeout_ms, 25)

      # Pinned exactly, not as a floor: this records a CHOICE (the value
      # `TaskRouter` already holds a design step to), and a floor assertion
      # would admit a silent change to it.
      assert Lifecycle.default_step_timeout_ms() == 1_800_000
    end
  end

  describe "edge_budget_ms/0" do
    test "falls back to the compiled default when nothing is injected" do
      Application.delete_env(:platform, :lifecycle_edge_budget_ms)

      assert Lifecycle.edge_budget_ms() == Lifecycle.default_edge_budget_ms()
    end

    test "returns an injected value" do
      Application.put_env(:platform, :lifecycle_edge_budget_ms, 40)

      assert Lifecycle.edge_budget_ms() == 40
    end

    test "the shipped default is 60 minutes and is unmoved by injection" do
      Application.put_env(:platform, :lifecycle_edge_budget_ms, 40)

      assert Lifecycle.default_edge_budget_ms() == 3_600_000
    end
  end

  describe "the two budgets are independent knobs" do
    # This is the assertion that stops a later refactor deriving one budget
    # from the other (`edge = n * step`). Under a derived implementation the
    # runner's two budget behaviours become indistinguishable and both of
    # stage 3's tests would pass on a single-budget executor.
    test "injecting the step timeout leaves the edge budget at its default" do
      Application.delete_env(:platform, :lifecycle_edge_budget_ms)
      Application.put_env(:platform, :lifecycle_step_timeout_ms, 25)

      assert Lifecycle.step_timeout_ms() == 25
      assert Lifecycle.edge_budget_ms() == Lifecycle.default_edge_budget_ms()
      assert Lifecycle.edge_budget_ms() != 25
    end

    test "injecting the edge budget leaves the step timeout at its default" do
      Application.delete_env(:platform, :lifecycle_step_timeout_ms)
      Application.put_env(:platform, :lifecycle_edge_budget_ms, 40)

      assert Lifecycle.edge_budget_ms() == 40
      assert Lifecycle.step_timeout_ms() == Lifecycle.default_step_timeout_ms()
      assert Lifecycle.step_timeout_ms() != 40
    end

    test "the shipped defaults are not equal, so neither can stand in for the other" do
      refute Lifecycle.default_step_timeout_ms() == Lifecycle.default_edge_budget_ms()
    end
  end

  describe "the behaviour's shape" do
    test "declares exactly start/2 and kind/0" do
      assert Enum.sort(Step.behaviour_info(:callbacks)) == [kind: 0, start: 2]
    end

    test "a :sync step settles inside start/2" do
      assert TestSteps.Sync.kind() == :sync
      assert TestSteps.Sync.start(%{}, %{reply_to: self()}) == {:completed, :ok}
    end

    test "a :sync step can report any terminal outcome, including a divert" do
      Process.put({:lifecycle_test_step, :sync_outcome}, {:diverted, :back_to_planning})

      assert TestSteps.Sync.start(%{}, %{reply_to: self()}) == {:diverted, :back_to_planning}
    end

    test "an :async step returns a ref and settles on command" do
      assert TestSteps.Async.kind() == :async
      assert {:running, ref} = TestSteps.Async.start(%{}, %{reply_to: self()})

      assert :ok = TestSteps.Async.settle(ref, {:completed, :done})
      assert_receive {:lifecycle_step_settled, ^ref, {:completed, :done}}
    end

    test "an :async step can NEVER settle — the case the budget exists for" do
      assert {:running, ref} = TestSteps.Async.start(%{}, %{reply_to: self()})

      # Nothing is sent unless a test asks for it. This is the agent-died
      # path, and a support module that always settled could not produce it.
      refute_receive {:lifecycle_step_settled, ^ref, _outcome}, 50
    end

    test "each async start gets its own ref, so concurrent runs are tellable apart" do
      assert {:running, ref_a} = TestSteps.Async.start(%{}, %{reply_to: self()})
      assert {:running, ref_b} = TestSteps.Async.start(%{}, %{reply_to: self()})
      refute ref_a == ref_b

      assert :ok = TestSteps.Async.settle(ref_b, {:failed, :boom})

      assert_receive {:lifecycle_step_settled, ^ref_b, {:failed, :boom}}
      refute_receive {:lifecycle_step_settled, ^ref_a, _outcome}, 20
    end

    test "settling a ref this process never started is an error, not a silent :ok" do
      assert TestSteps.Async.settle(make_ref(), {:completed, :done}) == :error
    end
  end
end
