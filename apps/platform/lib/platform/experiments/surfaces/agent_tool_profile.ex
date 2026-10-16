defmodule Platform.Experiments.Surfaces.AgentToolProfile do
  @moduledoc """
  The `agents.tool_profile` experiment can remove modules from a runtime's
  stored profile. Resolution keeps stored order and cannot grant a module.
  """

  @behaviour Platform.Experiments.Surface

  alias Platform.Federation.ToolSurface

  @target "agents.tool_profile"

  @impl true
  def key, do: @target

  @impl true
  def subject_type, do: "agent"

  @impl true
  def path, do: :draft

  @impl true
  def targets, do: [@target]

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["modules"],
      "properties" => %{
        "modules" => %{
          "type" => "array",
          "items" => %{"type" => "string", "enum" => ToolSurface.all_bundles()}
        }
      }
    }
  end

  @impl true
  def validate_payload(%{"modules" => modules} = payload) when is_list(modules) do
    if map_size(payload) == 1 and Enum.all?(modules, &(&1 in ToolSurface.all_bundles())) do
      {:ok, %{"modules" => modules}}
    else
      {:error, ["modules must contain only declared tool modules"]}
    end
  end

  def validate_payload(_), do: {:error, ["modules must be a list"]}

  @impl true
  def control_payload(_target, _opts \\ []), do: {:ok, %{"modules" => ToolSurface.all_bundles()}}
end
