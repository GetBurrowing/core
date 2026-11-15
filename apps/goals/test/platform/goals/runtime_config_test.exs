defmodule Platform.Goals.RuntimeConfigTest do
  # apply/1 writes the global `:goals, :enabled` app env, so not async.
  use ExUnit.Case, async: false

  alias Platform.Goals.RuntimeConfig

  describe "read/1" do
    test "enables Goals for exactly \"true\" and \"1\"" do
      for value <- ["true", "1"] do
        assert RuntimeConfig.read(%{"GOALS_ENABLED" => value}) == [enabled: true],
               "GOALS_ENABLED=#{inspect(value)} should enable Goals"
      end
    end

    test "leaves Goals off when GOALS_ENABLED is unset" do
      assert RuntimeConfig.read(%{}) == [enabled: false]
      assert RuntimeConfig.read(%{"GOALS_ENABLEDX" => "true"}) == [enabled: false]
    end

    test "leaves Goals off for every other value" do
      for value <- ["", "0", "false", "TRUE", "yes", " true"] do
        assert RuntimeConfig.read(%{"GOALS_ENABLED" => value}) == [enabled: false],
               "GOALS_ENABLED=#{inspect(value)} should leave Goals off"
      end
    end
  end

  describe "apply/1" do
    setup do
      previous = Application.fetch_env(:goals, :enabled)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:goals, :enabled, value)
          :error -> Application.delete_env(:goals, :enabled)
        end
      end)
    end

    test "puts the boolean in the :goals app env" do
      RuntimeConfig.apply(%{"GOALS_ENABLED" => "1"})
      assert Application.get_env(:goals, :enabled) == true

      RuntimeConfig.apply(%{})
      assert Application.get_env(:goals, :enabled) == false
    end
  end
end
