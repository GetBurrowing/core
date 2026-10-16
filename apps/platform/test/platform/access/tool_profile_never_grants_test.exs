defmodule Platform.Access.ToolProfileNeverGrantsTest do
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.{RuntimeProfiles, Tools}
  alias Platform.Agents.AgentRuntime
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
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

  defp runtime_id, do: "profile-never-grants-#{System.unique_integer([:positive])}"
end
