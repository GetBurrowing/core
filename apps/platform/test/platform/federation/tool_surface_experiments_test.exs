defmodule Platform.Federation.ToolSurfaceExperimentsTest do
  @moduledoc """
  The `experiments` bundle on the federation surface (task 01a0d415
  stage 2). Holding the bundle is the first guardrail, so it must be absent
  from a default runtime and present only when granted; and the bundle must
  expose no way to send anything.
  """

  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.ExperimentTools
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolSurface

  @names ~w(experiment_surface_list experiment_list experiment_get experiment_create
            experiment_variant_add experiment_start experiment_stop experiment_conclude
            experiment_results experiment_signals_list experiment_exclude
            experiment_goal_set experiment_goal_list experiment_promote
            dispatch_metrics_list code_mode_report)

  defp runtime(bundles), do: %AgentRuntime{owner_user_id: root_admin!().id, allowed_bundles: bundles}

  test "the bundle is registered, grantable, and lists exactly the experiment tools" do
    assert "experiments" in ToolSurface.all_bundles()
    assert "experiments" in AgentRuntime.valid_bundles()

    names = ToolSurface.list_tools(["experiments"]) |> Enum.map(& &1.name)
    assert Enum.sort(names) == Enum.sort(@names)
    assert Enum.all?(ToolSurface.list_tools(["experiments"]), &(&1.bundle == "experiments"))
  end

  test "absent from a default runtime: every experiment tool is refused" do
    refute "experiments" in AgentRuntime.default_allowed_bundles()
    default = runtime(AgentRuntime.default_allowed_bundles())

    refute Enum.any?(ToolAuthorization.tool_names(default), &(&1 in @names))

    for name <- @names do
      assert ToolAuthorization.authorize(name, default) == {:error, :forbidden}
    end
  end

  test "a fresh AgentRuntime row does not carry the bundle" do
    refute "experiments" in %AgentRuntime{}.allowed_bundles
  end

  test "present when granted" do
    granted = runtime(AgentRuntime.default_allowed_bundles() ++ ["experiments"])

    for name <- @names do
      assert ToolAuthorization.authorize(name, granted) == :ok
    end
  end

  test "no tool in the bundle sends, deletes, un-excludes or approves" do
    for %{name: name} <- ToolSurface.list_tools(["experiments"]) do
      refute name =~ "send"
      refute name =~ "delete"
      refute name =~ "unexclude"
      refute name =~ "approve"
    end
  end

  test "no experiment tool is listed outside the experiments bundle" do
    others = ToolSurface.list_tools(ToolSurface.all_bundles() -- ["experiments"])
    refute Enum.any?(others, &String.starts_with?(&1.name, "experiment_"))
  end

  test "every definition carries the six-component rubric" do
    for tool <- ExperimentTools.definitions() do
      for key <- [:name, :description, :parameters, :returns, :limitations, :when_to_use] do
        assert Map.has_key?(tool, key), "#{tool.name} is missing #{key}"
      end

      for field <- [:description, :returns, :limitations, :when_to_use] do
        assert is_binary(Map.fetch!(tool, field)) and Map.fetch!(tool, field) != ""
      end
    end
  end

  test "the execute prefix routes to Platform.Experiments.Tools" do
    assert {:error, %{code: :unknown_tool}} =
             ToolSurface.execute("experiment_nonexistent", %{}, %{})

    assert {:ok, %{surfaces: [_ | _]}} = ToolSurface.execute("experiment_surface_list", %{}, %{})
  end
end
