defmodule Platform.Goals.ExtensionTest do
  # Flips the global `:goals, :enabled` app env, so not async.
  use ExUnit.Case, async: false

  alias Platform.Goals.Extension

  setup do
    previous = Application.fetch_env(:goals, :enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:goals, :enabled, value)
        :error -> Application.delete_env(:goals, :enabled)
      end
    end)
  end

  defp set_enabled(value), do: Application.put_env(:goals, :enabled, value)

  test "is the configured extension" do
    assert Extension in Platform.Extensions.list()
  end

  describe "with GOALS_ENABLED off" do
    setup do
      set_enabled(false)
    end

    test "registers nothing a person or runtime can reach" do
      refute Platform.Goals.enabled?()
      assert Extension.permissions() == []
      assert Extension.rail_items() == []
      assert Extension.live_pages() == []
      assert Extension.mcp_tool_bundles() == []
      assert Extension.canvas_kinds() == []
      refute Platform.Access.Registry.permission?("goals.use")
    end

    test "validates" do
      assert Platform.Extensions.validate() == :ok
    end
  end

  describe "with GOALS_ENABLED on" do
    setup do
      set_enabled(true)
    end

    test "registers goals.use" do
      assert Platform.Goals.enabled?()
      assert Extension.permissions() == [%{module: "goals", permissions: ["goals.use"]}]
      assert Platform.Access.Registry.permission?("goals.use")
    end

    test "still registers no rail item, page, bundle or canvas kind" do
      assert Extension.rail_items() == []
      assert Extension.live_pages() == []
      assert Extension.mcp_tool_bundles() == []
      assert Extension.canvas_kinds() == []
    end

    test "validates" do
      assert Platform.Extensions.validate() == :ok
    end
  end

  test "migrations_path/0 is the same existing directory whatever the flag" do
    set_enabled(false)
    off = Extension.migrations_path()
    set_enabled(true)
    on = Extension.migrations_path()

    assert off == on
    assert File.dir?(off), "#{off} does not exist"
    assert String.ends_with?(off, "priv/repo/migrations")
  end

  test "enabled?/0 is false when the app env is unset or not exactly true" do
    Application.delete_env(:goals, :enabled)
    refute Platform.Goals.enabled?()

    set_enabled("true")
    refute Platform.Goals.enabled?()
  end

  test "the runtime callbacks answer without raising" do
    assert Extension.runtime_channel_events() == []
    assert Extension.handle_runtime_event("anything", "runtime", %{}) == {:error, :unknown_event}
    assert Extension.runtime_disconnected("runtime") == :ok
    assert Extension.live_hooks() == []
    assert Extension.experiment_surfaces() == []
    assert Extension.experiment_metrics() == %{}
  end
end
