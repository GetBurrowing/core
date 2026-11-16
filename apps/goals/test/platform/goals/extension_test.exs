defmodule Platform.Goals.ExtensionTest do
  # Flips the global `:goals, :enabled` app env, so not async.
  use ExUnit.Case, async: false

  alias Platform.Goals.Extension
  alias PlatformWeb.Components.IconRail

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

    test "core serves no Goals page and lists no Goals destination" do
      assert Platform.Extensions.live_page_for("goals") == nil
      refute Enum.any?(IconRail.destinations(root_user: true), &(&1.key == :goals))
      refute Enum.any?(IconRail.destinations(), &(&1.key == :goals))
    end

    test "validates" do
      assert Platform.Extensions.validate() == :ok
    end
  end

  describe "with GOALS_ENABLED on" do
    setup do
      set_enabled(true)
    end

    test "registers goals.use with its rail entry, and no bundle" do
      assert Platform.Goals.enabled?()

      assert Extension.permissions() == [
               %{
                 module: "goals",
                 permissions: ["goals.use"],
                 rail: [%{key: :goals, permission: "goals.use"}],
                 bundles: %{"goals" => "goals.use"}
               }
             ]

      assert Platform.Access.Registry.permission?("goals.use")
    end

    test "registers the Goals rail item and the /m/goals page" do
      assert Extension.rail_items() == [
               %{
                 key: :goals,
                 label: "Goals",
                 path: "/m/goals",
                 hero_icon: "hero-flag",
                 cluster: :working,
                 root_only?: false
               }
             ]

      assert Extension.live_pages() == [
               %{
                 prefix: "goals",
                 live_view: PlatformWeb.GoalsLive,
                 title: "Goals",
                 module: :goals,
                 permission: "goals.use"
               }
             ]

      assert %{live_view: PlatformWeb.GoalsLive} = Platform.Extensions.live_page_for("goals")
      assert %{path: "/m/goals"} = Enum.find(IconRail.destinations(), &(&1.key == :goals))
    end

    test "registers the goals bundle and practice canvas kind" do
      assert [%{name: "goals"}] = Extension.mcp_tool_bundles()
      assert Extension.canvas_kinds() == [Platform.Goals.CanvasKinds.FlashCards, Platform.Goals.CanvasKinds.GoalSpaceCard]
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

  test "assets/0 is Tailwind sources only, the lib directory, whatever the flag" do
    set_enabled(false)
    off = Extension.assets()
    set_enabled(true)

    assert off == Extension.assets()
    assert %{tailwind_sources: [lib]} = off
    assert map_size(off) == 1
    assert File.dir?(lib)
    assert File.exists?(Path.join(lib, "platform_web/live/goals_live.ex"))
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
