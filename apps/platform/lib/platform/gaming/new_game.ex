defmodule Platform.Gaming.NewGame do
  @moduledoc "Creates a real project and team room, then hands the setup brief to an existing agent."
  alias Platform.{Access, Chat, Repo, Tasks, Tenancy}
  alias Platform.Access.Scope

  def templates, do: [{"Godot · physics playground", "godot"}, {"Unity · blank game", "unity"}, {"Unreal · blank game", "unreal"}]

  def organizations(user) do
    scope = Scope.for_user(user)
    Tenancy.list_user_memberships(user)
    |> Enum.reject(& &1.external)
    |> Enum.map(&Tenancy.get_org(&1.org_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn org ->
      Access.check(scope, "tasks.write", {:org, org.id}) == :ok and
        Access.check(scope, "chat.manage", {:org, org.id}) == :ok
    end)
  end

  def create(user, params) do
    org = Enum.find(organizations(user), &(&1.id == params["org_id"]))
    name = String.trim(params["name"] || "") |> String.slice(0, 80)
    engine = params["engine"]

    with true <- not is_nil(org) and name != "" and engine in ~w(godot unity unreal),
         {:ok, agent} <- Platform.Onboarding.FirstRunGoal.burrow(),
         {:ok, %{project: project, space: space}} <- provision(user, org, name, engine, agent) do
      participant = Repo.get_by!(Chat.Participant, space_id: space.id, participant_type: "user", participant_id: user.id)
      brief = "Help us build #{name} with #{engine}. Set up its repository and a minimal playable first build, then run a playtest. Project ID: #{project.id}. Keep this room as our team conversation and update the project repository configuration once it exists. Start by discussing: " <> String.slice(params["idea"] || "", 0, 2000)

      case Chat.post_message(%{space_id: space.id, participant_id: participant.id, content_type: "text", content: brief}) do
        {:ok, _} -> {:ok, project, :requested}
        _ -> {:ok, project, :message_failed}
      end
    else
      _ -> {:error, :setup_unavailable}
    end
  end

  defp provision(user, org, name, engine, agent) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
    Repo.transaction(fn ->
      with {:ok, project} <- Tasks.create_project(%{name: name, slug: "game-" <> suffix, org_id: org.id, tech_stack: %{"engine" => engine}, config: %{"game_studio" => true}}),
           {:ok, space} <- Chat.create_channel(%{name: name <> " dev", slug: "game-" <> suffix <> "-dev", org_id: org.id, created_by: user.id, metadata: %{"goal_project_id" => project.id}}),
           {:ok, _} <- Chat.ensure_space_agent(space.id, agent.id, role: "principal"),
           {:ok, _} <- Chat.set_agent_attention_policy({:user, user.id}, space.id, "directed"),
           {:ok, project} <- Tasks.update_project(project, %{config: Map.put(project.config, "development_space_id", space.id)}) do
        %{project: project, space: space}
      else
        error -> Repo.rollback(error)
      end
    end)
  end
end
