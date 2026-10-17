defmodule Platform.RuntimeProfileFixtures do
  @moduledoc "Helpers for runtime rows and their Access-owned ordered tool profiles."

  alias Platform.Access.RuntimeProfiles
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo

  def runtime!(owner_user_id, modules, attrs \\ %{}, restriction \\ :translated) do
    runtime =
      %AgentRuntime{}
      |> AgentRuntime.changeset(
        Map.merge(
          %{
            runtime_id: "profile-fixture-#{System.unique_integer([:positive])}",
            owner_user_id: owner_user_id
          },
          attrs
        )
      )
      |> Repo.insert!()

    restriction =
      if restriction == :translated,
        do: RuntimeProfiles.translated_permissions(modules),
        else: restriction

    {:ok, _profile} =
      RuntimeProfiles.create_for_runtime(
        runtime,
        modules,
        restriction
      )

    runtime
  end

  @doc """
  Make `runtime_id` name a runtime that may call the Tasks write tools, and
  return it.

  Every `:runtime_id` an MCP context carries names a real runtime row whose
  owner is an org member and whose Scope holds `tasks.write`: the transports'
  tool gate refuses anything else, and since task 01a1472d stage 2 so does
  the Tasks write re-check inside `ToolSurface.execute/3`, which refuses a
  `:runtime_id` that resolves to no runtime. A test that calls a write tool
  directly with a bare string (an agent id standing in for a runtime id, say)
  builds a context production cannot, so this fills in what is missing and
  leaves what is there:

    * no row: one owned by a fresh root admin;
    * no profile: the `task` bundle;
    * an owner with no org membership: a root-org member membership.
  """
  def ensure_task_runtime!(runtime_id) when is_binary(runtime_id) do
    runtime =
      case Platform.Federation.get_runtime_by_runtime_id(runtime_id) do
        %AgentRuntime{} = runtime ->
          runtime

        nil ->
          %AgentRuntime{}
          |> AgentRuntime.changeset(%{
            runtime_id: runtime_id,
            owner_user_id: Platform.TenancyFixtures.root_admin!().id
          })
          |> Repo.insert!()
      end

    if is_nil(RuntimeProfiles.get(runtime)) do
      {:ok, _profile} =
        RuntimeProfiles.create_for_runtime(
          runtime,
          ["task"],
          RuntimeProfiles.translated_permissions(["task"])
        )
    end

    ensure_membership!(runtime.owner_user_id)
    runtime_id
  end

  defp ensure_membership!(user_id) do
    import Ecto.Query, only: [from: 2]

    alias Platform.Tenancy.OrgMembership

    unless Repo.exists?(from(m in OrgMembership, where: m.user_id == ^user_id)) do
      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user_id,
        org_id: Platform.TenancyFixtures.acme_org_id(),
        role: "member"
      })
      |> Repo.insert!()
    end

    :ok
  end
end
