defmodule Platform.Access.Tools do
  @moduledoc """
  One permission decision for the MCP catalogue and direct tool calls.

  The runtime's ordered bundle list is still the stage-one profile. Later
  migration copies that order to `access_runtime_profiles.tool_profile`.
  """

  alias Platform.Access
  alias Platform.Access.{RuntimeProfiles, Scope, ToolPermissions}
  alias Platform.Agents.AgentRuntime
  alias Platform.Experiments.{Subject, Surfaces}
  alias Platform.Federation.ToolSurface

  @profile_surface "agents.tool_profile"

  @spec effective_tools(AgentRuntime.t()) :: [map()]
  def effective_tools(%AgentRuntime{} = runtime) do
    profile = RuntimeProfiles.get(runtime)
    scope = Scope.for_runtime(runtime, profile)

    runtime
    |> RuntimeProfiles.tool_profile(profile)
    |> profile_arm(runtime)
    |> ToolSurface.list_tools()
    |> Enum.filter(fn tool ->
      Access.holds_anywhere?(scope, ToolPermissions.for_tool(tool.name))
    end)
  end

  @spec tool_names(AgentRuntime.t()) :: [String.t()]
  def tool_names(runtime), do: runtime |> effective_tools() |> Enum.map(& &1.name)

  @spec authorize(String.t(), AgentRuntime.t()) :: :ok | {:error, :forbidden}
  def authorize(name, %AgentRuntime{} = runtime) when is_binary(name) do
    if name in tool_names(runtime), do: :ok, else: {:error, :forbidden}
  end

  def authorize(_name, _runtime), do: {:error, :forbidden}

  defp profile_arm(stored, %AgentRuntime{agent_id: agent_id}) when is_binary(agent_id) do
    case Surfaces.resolve(@profile_surface, @profile_surface, Subject.new("agent", agent_id)) do
      {:variant, _, _, %{"modules" => modules}} ->
        Enum.filter(stored, &(&1 in modules))

      {:default, %{"modules" => modules}} ->
        Enum.filter(stored, &(&1 in modules))

      _ ->
        stored
    end
  end

  defp profile_arm(stored, _runtime), do: stored
end
