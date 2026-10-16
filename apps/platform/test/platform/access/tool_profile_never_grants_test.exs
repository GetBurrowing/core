defmodule Platform.Access.ToolProfileNeverGrantsTest do
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.CodeModeFixtures, only: [insert_agent!: 0]
  import Platform.TenancyFixtures

  alias Platform.Access.{RuntimeProfiles, Tools}
  alias Platform.Agents.AgentRuntime
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Experiments
  alias Platform.Experiments.Variant
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tenancy

  test "new runtime inherits its owner but its default profile keeps catalogue size bounded" do
    owner = root_admin!()
    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: runtime_id()})
    profile = RuntimeProfiles.get(runtime)

    assert profile.tool_profile == AgentRuntime.default_allowed_bundles()
    assert profile.restricted_permissions == nil
    assert "federation_status" in Tools.tool_names(runtime)
    refute "task_update" in Tools.tool_names(runtime)
  end

  test "a guest profile listing task does not grant task tools" do
    guest = World.create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: acme_org_id()})

    {:ok, runtime} =
      Federation.register_runtime(guest.id, %{
        runtime_id: runtime_id(),
        allowed_bundles: ["task"]
      })

    assert RuntimeProfiles.get(runtime).tool_profile == ["task"]
    refute "task_update" in Tools.tool_names(runtime)
    assert Tools.authorize("task_update", runtime) == {:error, :forbidden}
  end

  test "adding memory to a profile does not grant it when the restriction omits memory" do
    owner = root_admin!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: runtime_id(),
        allowed_bundles: ["task"]
      })

    {:ok, profile} = RuntimeProfiles.set_tool_profile(runtime, ["memory", "task"])
    assert profile.tool_profile == ["memory", "task"]
    assert {:ok, _} = RuntimeProfiles.restrict(runtime, %{"tasks.read" => "all"})
    refute "memory_view" in Tools.tool_names(runtime)
    assert "task_list" in Tools.tool_names(runtime)
    refute "task_update" in Tools.tool_names(runtime)
    assert {:error, :invalid_module} = RuntimeProfiles.set_tool_profile(runtime, ["not_installed"])
  end

  test "an experiment arm naming a module outside the stored profile adds nothing" do
    owner = root_admin!()
    agent = insert_agent!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: runtime_id(),
        agent_id: agent.id,
        allowed_bundles: ["task"]
      })

    assert "task_list" in Tools.tool_names(runtime)

    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "profile-#{System.unique_integer([:positive])}",
        name: "Tool profile",
        surface_key: "agents.tool_profile",
        surface_target: "agents.tool_profile"
      })

    {:ok, _} =
      Experiments.add_variant(experiment, %{
        slug: "treatment",
        payload: %{"modules" => ["memory"]},
        weight: 1
      })

    assert {:ok, _} = Experiments.start(experiment, root_admin!())

    Repo.update_all(
      from(v in Variant, where: v.experiment_id == ^experiment.id and v.slug == "control"),
      set: [weight: 0]
    )

    assert Tools.tool_names(runtime) == []
  end

  test "one profile decision reports its no-experiment query cost" do
    owner = root_admin!()
    agent = insert_agent!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: runtime_id(),
        agent_id: agent.id,
        allowed_bundles: ["task"]
      })

    caller = self()
    ref = make_ref()

    :ok =
      :telemetry.attach(
        ref,
        [:platform, :repo, :query],
        fn _, _, _, _ ->
          if self() == caller, do: send(caller, {ref, :query})
        end,
        nil
      )

    names =
      try do
        Tools.tool_names(runtime)
      after
        :telemetry.detach(ref)
      end

    count = drain_queries(ref, 0)
    IO.puts("profile tool-list queries with no experiment: #{count}")
    assert "task_list" in names
    assert count > 0
  end

  defp drain_queries(ref, count) do
    receive do
      {^ref, :query} -> drain_queries(ref, count + 1)
    after
      0 -> count
    end
  end

  defp runtime_id, do: "profile-never-grants-#{System.unique_integer([:positive])}"
end
