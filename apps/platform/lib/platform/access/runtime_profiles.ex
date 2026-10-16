defmodule Platform.Access.RuntimeProfiles do
  @moduledoc """
  Access-owned runtime profile writes. A profile orders and limits the modules
  loaded for a runtime; it never grants a permission absent from its owner.
  """

  alias Platform.Access.{Registry, RuntimeProfile, ToolPermissions}
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  @spec get(AgentRuntime.t()) :: RuntimeProfile.t() | nil
  def get(%AgentRuntime{id: id}) when is_binary(id), do: Repo.get(RuntimeProfile, id)
  def get(_), do: nil

  @spec tool_profile(AgentRuntime.t()) :: [String.t()]
  def tool_profile(%AgentRuntime{} = runtime), do: tool_profile(runtime, get(runtime))

  def tool_profile(%AgentRuntime{} = runtime, profile) do
    case profile do
      %RuntimeProfile{tool_profile: modules} when is_list(modules) -> modules
      %RuntimeProfile{tool_profile: nil} -> ToolSurface.all_bundles()
      nil -> runtime.allowed_bundles || []
    end
  end

  @spec restrictions(AgentRuntime.t()) :: %{String.t() => String.t()} | nil
  def restrictions(%AgentRuntime{} = runtime), do: restrictions(runtime, get(runtime))

  def restrictions(%AgentRuntime{} = runtime, profile) do
    case profile do
      %RuntimeProfile{restricted_permissions: permissions} -> permissions
      nil -> translated_permissions(runtime.allowed_bundles || [])
    end
  end

  @spec translated_permissions([String.t()]) :: %{String.t() => String.t()}
  def translated_permissions(modules) do
    modules
    |> Enum.flat_map(&ToolPermissions.bundle_permissions/1)
    |> Map.new(&{&1, "all"})
  end

  @spec create_for_runtime(AgentRuntime.t(), [String.t()], map() | nil) ::
          {:ok, RuntimeProfile.t()} | {:error, Ecto.Changeset.t()}
  def create_for_runtime(%AgentRuntime{} = runtime, modules, restrictions) do
    %RuntimeProfile{}
    |> RuntimeProfile.changeset(%{
      runtime_id: runtime.id,
      tool_profile: modules,
      restricted_permissions: restrictions
    })
    |> Repo.insert()
  end

  @spec set_tool_profile(AgentRuntime.t(), [String.t()]) ::
          {:ok, RuntimeProfile.t()} | {:error, term()}
  def set_tool_profile(%AgentRuntime{} = runtime, modules) when is_list(modules) do
    persisted = tool_profile(runtime)
    added = Enum.reject(modules, &(&1 in persisted))

    if Enum.all?(added, &(&1 in ToolSurface.all_bundles())) do
      upsert(runtime, %{tool_profile: modules})
    else
      {:error, :invalid_module}
    end
  end

  def set_tool_profile(_, _), do: {:error, :invalid_module}

  @spec restrict(AgentRuntime.t(), map() | nil) :: {:ok, RuntimeProfile.t()} | {:error, term()}
  def restrict(%AgentRuntime{} = runtime, nil), do: upsert(runtime, %{restricted_permissions: nil})

  def restrict(%AgentRuntime{} = runtime, permissions) when is_map(permissions) do
    if Enum.all?(permissions, fn {key, value} ->
         is_binary(key) and Registry.permission?(key) and value == "all"
       end) do
      upsert(runtime, %{restricted_permissions: permissions})
    else
      {:error, :invalid_permission}
    end
  end

  def restrict(_, _), do: {:error, :invalid_permission}

  defp upsert(%AgentRuntime{} = runtime, attrs) do
    profile = get(runtime) || %RuntimeProfile{runtime_id: runtime.id}

    profile
    |> RuntimeProfile.changeset(attrs)
    |> Repo.insert_or_update()
  end
end
