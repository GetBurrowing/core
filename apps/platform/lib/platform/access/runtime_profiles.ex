defmodule Platform.Access.RuntimeProfiles do
  @moduledoc """
  Access-owned runtime profile writes. A profile orders and limits the modules
  loaded for a runtime; it never grants a permission absent from its owner.
  """

  alias Platform.Access.{Agents, Registry, RuntimeProfile, Scope, ToolPermissions}
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  @core_valid_modules ~w(federation space context_read messaging review canvas task plan memory skill attachment files meetings mail experiments code_mode prototype)

  @spec get(AgentRuntime.t()) :: RuntimeProfile.t() | nil
  def get(%AgentRuntime{id: id}) when is_binary(id), do: Repo.get(RuntimeProfile, id)
  def get(_), do: nil

  @spec tool_profile(AgentRuntime.t()) :: [String.t()]
  def tool_profile(%AgentRuntime{} = runtime), do: tool_profile(runtime, get(runtime))

  def tool_profile(%AgentRuntime{} = _runtime, profile) do
    case profile do
      %RuntimeProfile{tool_profile: modules} when is_list(modules) -> modules
      %RuntimeProfile{tool_profile: nil} -> ToolSurface.all_bundles()
      nil -> []
    end
  end

  @spec restrictions(AgentRuntime.t()) :: %{String.t() => String.t()} | nil
  def restrictions(%AgentRuntime{} = runtime), do: restrictions(runtime, get(runtime))

  def restrictions(%AgentRuntime{} = _runtime, profile) do
    case profile do
      %RuntimeProfile{restricted_permissions: permissions} -> permissions
      nil -> %{}
    end
  end

  @doc "Every currently loaded module name: core modules plus installed extensions."
  def valid_modules, do: @core_valid_modules ++ Platform.Extensions.tool_bundle_names()

  @spec translated_permissions([String.t()]) :: %{String.t() => String.t()}
  def translated_permissions(modules) do
    modules
    |> Enum.flat_map(&ToolPermissions.bundle_permissions/1)
    |> Map.new(&{&1, "all"})
  end

  @spec create_for_runtime(AgentRuntime.t(), [String.t()], map() | nil) ::
          {:ok, RuntimeProfile.t()} | {:error, Ecto.Changeset.t() | :invalid_module}
  def create_for_runtime(%AgentRuntime{} = runtime, modules, restrictions) do
    if is_list(modules) and Enum.all?(modules, &(&1 in valid_modules())) do
      %RuntimeProfile{}
      |> RuntimeProfile.changeset(%{
        runtime_id: runtime.id,
        tool_profile: modules,
        restricted_permissions: restrictions
      })
      |> Repo.insert()
    else
      {:error, :invalid_module}
    end
  end

  @spec set_tool_profile(AgentRuntime.t(), [String.t()]) ::
          {:ok, RuntimeProfile.t()} | {:error, term()}
  def set_tool_profile(%AgentRuntime{} = runtime, modules) when is_list(modules) do
    persisted = tool_profile(runtime)
    added = Enum.reject(modules, &(&1 in persisted))

    if Enum.all?(added, &(&1 in valid_modules())) do
      upsert(runtime, %{tool_profile: modules})
    else
      {:error, :invalid_module}
    end
  end

  def set_tool_profile(_, _), do: {:error, :invalid_module}

  def set_tool_profile(%Scope{} = scope, %AgentRuntime{} = runtime, modules),
    do: if(Agents.manage?(scope, runtime), do: set_tool_profile(runtime, modules), else: {:error, :unauthorized})

  @spec restrict(AgentRuntime.t(), map() | nil) :: {:ok, RuntimeProfile.t()} | {:error, term()}
  def restrict(%AgentRuntime{} = runtime, nil),
    do: upsert(runtime, %{restricted_permissions: nil})

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

  def restrict(%Scope{} = scope, %AgentRuntime{} = runtime, permissions),
    do: if(Agents.manage?(scope, runtime), do: restrict(runtime, permissions), else: {:error, :unauthorized})

  defp upsert(%AgentRuntime{} = runtime, attrs) do
    profile = get(runtime) || %RuntimeProfile{runtime_id: runtime.id}

    profile
    |> RuntimeProfile.changeset(attrs)
    |> Repo.insert_or_update()
  end
end
