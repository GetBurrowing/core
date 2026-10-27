defmodule Platform.Scripts.SeedTabSwitchFixtureGuardTest do
  @moduledoc """
  Task 01a17b00 stage 1: the tab-switch fixture seed writes thousands of rows,
  so it must refuse anything but a per-task dev database. The guard is pure;
  these cases pin every refusal and the one accepted shape.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../priv/scripts/seed_tab_switch_fixture.exs", __DIR__)

  setup_all do
    unless Code.ensure_loaded?(guard()) do
      # Load the modules without running the seed.
      Process.put(:tab_switch_fixture_load_only, true)
      Code.compile_file(@script)
      Process.delete(:tab_switch_fixture_load_only)
    end

    :ok
  end

  # Loaded from the script at runtime: called through a runtime module name.
  defp guard, do: Module.concat(["TabSwitchFixture", "Guard"])
  defp check(env, db, suffix \\ "01a17b00"), do: apply(guard(), :check, [env, db, suffix])

  test "accepts a dev database carrying the task suffix" do
    assert check(:dev, "platform_dev_01a17b00") == :ok
  end

  test "refuses any MIX_ENV but dev, whatever the database" do
    for env <- [:test, :prod, nil] do
      assert {:error, msg} = check(env, "platform_dev_01a17b00")
      assert msg =~ "MIX_ENV must be dev"
    end
  end

  test "refuses the shared databases by name" do
    for db <- ~w(platform_dev platform_test platform_prod platform) do
      assert {:error, msg} = check(:dev, db, "platform")
      assert msg =~ "shared database"
    end
  end

  test "refuses names that look like a shared host or prod, even with the suffix" do
    for db <- ~w(platform_prod_01a17b00 hive_01a17b00 moon_platform_01a17b00) do
      assert {:error, msg} = check(:dev, db)
      assert msg =~ "shared or production"
    end
  end

  test "refuses a per-task database of a different task" do
    assert {:error, msg} = check(:dev, "platform_dev_01a174f5")
    assert msg =~ "lacks the task suffix 01a17b00"
  end

  test "refuses a missing database and a suffix too short to fence anything" do
    assert {:error, "no database configured"} = check(:dev, nil)
    assert {:error, "no database configured"} = check(:dev, "")
    assert {:error, msg} = check(:dev, "platform_dev_01a17b00", "dev")
    assert msg =~ "too short"
  end

  test "loading the script for its modules did not run the seed" do
    # main/1 would have halted or written; the module is only defined.
    assert function_exported?(Module.concat(["TabSwitchFixture"]), :main, 1)
  end
end
