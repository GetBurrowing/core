defmodule Platform.Access.RuntimeProfileRequiredTest do
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.{RuntimeProfiles, Tools}
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo

  test "a runtime without its Access profile cannot list or call tools" do
    owner = root_admin!()

    runtime =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "profile-required-#{System.unique_integer([:positive])}",
        owner_user_id: owner.id,
        status: "active"
      })
      |> Repo.insert!()

    assert RuntimeProfiles.get(runtime) == nil
    assert RuntimeProfiles.tool_profile(runtime) == []
    assert RuntimeProfiles.restrictions(runtime) == %{}
    assert Tools.tool_names(runtime) == []
    assert Tools.authorize("federation_status", runtime) == {:error, :forbidden}

    {:ok, _profile} =
      RuntimeProfiles.create_for_runtime(runtime, ["federation"], nil)

    assert "federation_status" in Tools.tool_names(runtime)
    assert Tools.authorize("federation_status", runtime) == :ok
  end
end
