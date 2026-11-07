defmodule Platform.GameStream.GameChannels do
  @moduledoc "Game repository bindings. Linking never grants repository access."
  use Ecto.Schema
  import Ecto.Query
  alias Platform.{Access, Repo}
  alias Platform.Accounts.User
  alias Platform.Chat.Space
  alias Platform.Tasks.Project
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "game_channel_bindings" do
    field :project_id, :binary_id
    field :repo_url, :string
    timestamps(type: :utc_datetime_usec)
  end

  def configure(%User{} = user, channel_id, project_id) do
    with true <- Platform.UUID.valid?(channel_id) and Platform.UUID.valid?(project_id),
         %Space{kind: "channel", archived_at: nil} = space <- Repo.get(Space, channel_id),
         %Project{archived_at: nil, repo_url: repo} = project <- Repo.get(Project, project_id),
         true <- is_binary(repo) and String.starts_with?(repo, "https://github.com/"),
         :ok <- Access.authorize(user, "chat.write", space),
         :ok <- repository_access(user, project) do
      Repo.transaction(fn ->
        Repo.one!(from s in Space, where: s.id == ^channel_id, lock: "FOR UPDATE")
        active? = Repo.exists?(from s in Platform.GameStream.NativeSessionRecord,
          where: s.channel_id == ^channel_id and s.state in ["starting", "running", "stopping"])
        if active?, do: Repo.rollback(:active_session)
        case Repo.insert(%__MODULE__{id: channel_id, project_id: project_id, repo_url: repo},
          on_conflict: {:replace, [:project_id, :repo_url, :updated_at]}, conflict_target: [:id]) do
          {:ok, binding} -> binding
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize(%User{} = user, channel_id) do
    with true <- Platform.UUID.valid?(channel_id), %Space{kind: "channel", archived_at: nil} = space <- Repo.get(Space, channel_id),
         :ok <- Access.authorize(user, "chat.read", space),
         %__MODULE__{} = binding <- Repo.get(__MODULE__, channel_id),
         %Project{archived_at: nil, repo_url: repo} = project <- Repo.get(Project, binding.project_id),
         true <- binding.repo_url == repo,
         :ok <- repository_access(user, project) do
      {:ok, binding}
    else
      _ -> {:error, :unauthorized}
    end
  end
  def authorize(_, _), do: {:error, :unauthorized}

  # Require a real repository-org membership as well as project permission.
  # Root-org visibility and an identically shaped UUID are not repo grants.
  defp repository_access(user, project) do
    member? = Repo.exists?(from m in Platform.Tenancy.OrgMembership,
      where: m.user_id == ^user.id and m.org_id == ^project.org_id)
    if member?, do: Access.authorize(user, "tasks.read", project), else: {:error, :unauthorized}
  end
end
