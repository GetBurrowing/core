defmodule Platform.Social.ClipRevisionAccess do
  @moduledoc false
  alias Platform.{Access, Accounts, Federation, Repo, Social}
  alias Platform.Access.{RuntimeProfiles, Scope}
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Social.Studio

  def human(nil, _), do: {:error, :not_found}

  def human(profile, id) do
    with :ok <- Social.preparer_check(profile.org_id, profile, id),
         {:ok, %{archived_at: nil}} <- Social.render_project(profile),
         :ok <- Studio.require_social_use(id, profile),
         %{} = user <- Accounts.get_user(id),
         :ok <- Access.check(Scope.for_user(user), "files.read", {:project, profile.project_id}) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unauthorized}
    end
  end

  def session({:agent, id, runtime_id}) do
    with true <- Platform.UUID.valid?(id) and is_binary(runtime_id),
         %Agent{status: "active"} = agent <- Repo.get(Agent, id),
         :ok <- org_resolves(agent),
         %AgentRuntime{agent_id: ^id, status: "active"} <-
           Federation.get_runtime_by_runtime_id(runtime_id) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  def session({:user, id}) do
    if Platform.UUID.valid?(id) and match?(%{archived_at: nil}, Accounts.get_user(id)),
      do: :ok,
      else: {:error, :unauthorized}
  end

  def session(_), do: {:error, :unauthorized}

  def actor(profile, {:user, id}), do: human(profile, id)

  def actor(profile, {:agent, id, runtime_id}) do
    with :ok <- session({:agent, id, runtime_id}),
         {:ok, agent} <- agent(profile, id),
         %AgentRuntime{agent_id: ^id} = runtime <-
           Federation.get_runtime_by_runtime_id(runtime_id),
         :ok <- runtime_access(profile, runtime),
         true <- agent.id == id do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  def actor(_, _), do: {:error, :unauthorized}

  def agent(profile, id) do
    with true <- Platform.UUID.valid?(id),
         %Agent{status: "active"} = agent <- Repo.get(Agent, id),
         :ok <- org_resolves(agent),
         true <- Social.org_visible?(Platform.Experiments.Tools.home_org(agent), profile.org_id),
         {:ok, %{archived_at: nil}} <- Social.render_project(profile),
         true <-
           Enum.any?(Federation.runtimes_for_agent(agent), &(runtime_access(profile, &1) == :ok)) do
      {:ok, agent}
    else
      _ -> {:error, :maker_unavailable}
    end
  end

  def recipient(profile, id) do
    with {:ok, agent} <- agent(profile, id),
         true <- is_binary(profile.space_id),
         true <-
           Enum.any?(
             Platform.Chat.list_participants(profile.space_id, participant_type: "agent"),
             &(&1.participant_id == id and not &1.silenced)
           ) do
      {:ok, agent}
    else
      _ -> {:error, :maker_unavailable}
    end
  end

  defp runtime_access(profile, %AgentRuntime{status: "active"} = runtime) do
    scope = Scope.for_runtime(runtime)
    modules = RuntimeProfiles.tool_profile(runtime)

    if "social" in modules and "files" in modules and
         Access.module_access?(scope, :social, "social.use") and
         Access.can?(scope, "social.use", {:project, profile.project_id}) and
         Access.can?(scope, "files.read", {:project, profile.project_id}),
       do: :ok,
       else: {:error, :unauthorized}
  end

  defp runtime_access(_, _), do: {:error, :unauthorized}

  defp org_resolves(agent) do
    case (agent.metadata || %{})["org_id"] do
      nil ->
        :ok

      "" ->
        :ok

      id ->
        if Platform.UUID.valid?(id) and Platform.Tenancy.get_org(id),
          do: :ok,
          else: {:error, :unauthorized}
    end
  end
end
