defmodule Platform.Responsibilities.StallRegistryTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.StallRegistry` (task 019f2566
  stage 6).

  Each test spins up its own per-case registry with a unique
  `:name` so the default singleton (disabled in `config/test.exs` via
  `:start_stall_registry false`) isn't touched and cases don't cross-
  contaminate each other's registered callbacks.
  """
  use ExUnit.Case, async: true

  alias Platform.Responsibilities.StallRegistry

  defp unique_name do
    Module.concat([StallRegistry, "Inst#{System.unique_integer([:positive])}"])
  end

  defp start_registry! do
    name = unique_name()
    _pid = start_supervised!({StallRegistry, name: name})
    name
  end

  describe "register/2 + all/1 roundtrip" do
    test "a freshly-started registry has no callbacks" do
      name = start_registry!()
      assert StallRegistry.all(name) == []
    end

    test "registering a callback makes it visible in all/1" do
      name = start_registry!()

      assert :ok = StallRegistry.register({MyRuntime, :sweep_foo}, name)
      assert StallRegistry.all(name) == [{MyRuntime, :sweep_foo}]
    end

    test "registering multiple callbacks preserves both" do
      name = start_registry!()

      :ok = StallRegistry.register({RuntimeA, :sweep_a}, name)
      :ok = StallRegistry.register({RuntimeB, :sweep_b}, name)

      # Order is a MapSet iteration detail; assert set-equality instead.
      callbacks = StallRegistry.all(name)
      assert length(callbacks) == 2
      assert {RuntimeA, :sweep_a} in callbacks
      assert {RuntimeB, :sweep_b} in callbacks
    end
  end

  describe "deduplication" do
    test "registering the same {mod, fun} twice appears once in all/1" do
      name = start_registry!()

      :ok = StallRegistry.register({RuntimeA, :sweep}, name)
      :ok = StallRegistry.register({RuntimeA, :sweep}, name)

      assert StallRegistry.all(name) == [{RuntimeA, :sweep}]
    end

    test "same module + different function is NOT deduped" do
      name = start_registry!()

      :ok = StallRegistry.register({RuntimeA, :sweep_one}, name)
      :ok = StallRegistry.register({RuntimeA, :sweep_two}, name)

      callbacks = StallRegistry.all(name)
      assert length(callbacks) == 2
      assert {RuntimeA, :sweep_one} in callbacks
      assert {RuntimeA, :sweep_two} in callbacks
    end
  end

  describe "concurrent registration" do
    test "many processes registering distinct callbacks doesn't lose entries" do
      name = start_registry!()

      # 20 concurrent registrations of distinct callbacks. If the
      # GenServer serialization is honest, all 20 land.
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            StallRegistry.register({Module.concat([Rt, "Inst#{i}"]), :sweep}, name)
          end)
        end

      Enum.each(tasks, &Task.await/1)

      assert length(StallRegistry.all(name)) == 20
    end

    test "many processes registering the SAME callback dedupe correctly" do
      name = start_registry!()

      tasks =
        for _ <- 1..25 do
          Task.async(fn -> StallRegistry.register({SharedRt, :sweep}, name) end)
        end

      Enum.each(tasks, &Task.await/1)

      assert StallRegistry.all(name) == [{SharedRt, :sweep}]
    end
  end

  describe "input validation" do
    test "register/2 rejects non-atom module or function" do
      name = start_registry!()

      assert_raise FunctionClauseError, fn ->
        StallRegistry.register({"not_an_atom", :sweep}, name)
      end

      assert_raise FunctionClauseError, fn ->
        StallRegistry.register({MyRt, "not_an_atom"}, name)
      end
    end
  end
end
