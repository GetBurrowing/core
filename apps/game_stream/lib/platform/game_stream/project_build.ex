defmodule Platform.GameStream.ProjectBuild do
  @moduledoc "An explicit project/default-branch build. Never changes a task's review state."
  alias Platform.{Access, Tasks}
  alias Platform.Access.Scope
  alias Platform.Tasks.{BranchProvisioner, RepoRef}

  def resolve(id, user, opts \\ []) do
    scope = Scope.for_user(user)
    project = Enum.find(Tasks.list_projects_for_user(user, access_scope: scope), &(&1.id == id and is_nil(&1.archived_at)))

    with %{repo_url: url, default_branch: branch} <- project,
         :ok <- Access.authorize(scope, "play.use", project),
         {:ok, repo} <- RepoRef.normalize(url || ""),
         true <- is_binary(branch) and branch != "",
         runner = Keyword.get(opts, :runner, BranchProvisioner.runner()),
         {:ok, sha} <- runner.branch_head_sha(%{repo: repo, branch: branch}),
         true <- is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) do
      {:ok, %{task: nil, project_id: project.id, repo_url: url, repo: repo, branch: branch, sha: sha}}
    else
      _ -> {:error, :project_build_unavailable}
    end
  end
end
