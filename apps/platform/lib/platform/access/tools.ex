defmodule Platform.Access.Tools do
  @moduledoc """
  One permission decision for the MCP catalogue and direct tool calls.

  The runtime's ordered bundle list is still the stage-one profile. Later
  migration copies that order to `access_runtime_profiles.tool_profile`.
  """

  alias Platform.Access
  alias Platform.Access.{Scope, ToolPermissions}
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.ToolSurface

  @spec effective_tools(AgentRuntime.t()) :: [map()]
  def effective_tools(%AgentRuntime{} = runtime) do
    scope = Scope.for_runtime(runtime)

    runtime
    |> bundles()
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

  defp bundles(%AgentRuntime{allowed_bundles: bundles}) when is_list(bundles), do: bundles
  defp bundles(_), do: []
end
