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
end
