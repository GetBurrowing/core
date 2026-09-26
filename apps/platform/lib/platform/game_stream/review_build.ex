defmodule Platform.GameStream.ReviewBuild do
  @moduledoc """
  Which commit a play session builds (task 01a0db5f stage 2).

  A playable review build is the tip of the task's OWN branch, read at the
  moment the session starts:

    * the task must be `in_review` — otherwise `{:error, :not_in_review}`;
    * the repository is the task's project `repo_url`;
    * the branch is `Platform.Tasks.StackDeployer.member_branch_for/1`, never
      hand-built, because a stacked member's slug differs from a lone task's;
    * the sha is that branch's head, asked through the same runner seam
      `Platform.Tasks.BranchProvisioner` uses
      (`BranchProvisioner.runner().branch_head_sha/1`).

  ## It never falls back to main

  A missing branch is `{:error, :no_review_branch}`. Any other failure to
  read the tip is `{:error, {:review_branch_unresolved, reason}}`. Neither
  path ever substitutes the default branch, the project's `default_branch`,
  or any other ref: a reviewer who is shown main while believing they are
  playing the review build has been told something false, which is worse
  than being told nothing. That is the stage's acceptance criterion, and
  `test/platform/game_stream_test.exs` pins it by asserting the runner is
  never asked about any other branch.
  """

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.BranchProvisioner
  alias Platform.Tasks.RepoRef
  alias Platform.Tasks.StackDeployer
  alias Platform.Tasks.Task, as: TaskRecord

  @sha_regex ~r/\A[0-9a-f]{40}\z/

  @type t :: %{
          task: TaskRecord.t(),
          repo_url: String.t(),
          repo: String.t(),
          branch: String.t(),
          sha: String.t()
        }

  @doc """
  Resolves the review build for `task_id`.

  Options: `:runner` overrides `BranchProvisioner.runner/0` (tests).
  """
  @spec resolve(String.t(), keyword()) ::
          {:ok, t()}
          | {:error,
             :task_not_found
             | :not_in_review
             | :no_repo
             | :no_review_branch
             | {:review_branch_unresolved, term()}}
  def resolve(task_id, opts \\ [])

  def resolve(task_id, opts) when is_binary(task_id) do
    runner = Keyword.get(opts, :runner, BranchProvisioner.runner())

    with {:ok, task} <- fetch_task(task_id),
         :ok <- ensure_in_review(task),
         {:ok, repo_url, repo} <- project_repo(task) do
      branch = StackDeployer.member_branch_for(task)

      case runner.branch_head_sha(%{repo: repo, branch: branch}) do
        {:ok, sha} when is_binary(sha) ->
          if Regex.match?(@sha_regex, sha) do
            {:ok, %{task: task, repo_url: repo_url, repo: repo, branch: branch, sha: sha}}
          else
            {:error, {:review_branch_unresolved, {:bad_sha, sha}}}
          end

        {:error, :ref_not_found} ->
          {:error, :no_review_branch}

        {:error, reason, message} ->
          {:error, {:review_branch_unresolved, {reason, message}}}

        {:error, reason} ->
          {:error, {:review_branch_unresolved, reason}}

        other ->
          {:error, {:review_branch_unresolved, {:unexpected, other}}}
      end
    end
  end

  def resolve(_task_id, _opts), do: {:error, :task_not_found}

  # `task_id` is an MCP argument; a malformed one is not-found, never a
  # CastError out of the lookup.
  defp fetch_task(task_id) do
    with true <- Platform.UUID.valid?(task_id),
         %TaskRecord{} = task <- Tasks.get_task_record(task_id) do
      {:ok, task}
    else
      _ -> {:error, :task_not_found}
    end
  end

  defp ensure_in_review(%TaskRecord{status: "in_review"}), do: :ok
  defp ensure_in_review(_task), do: {:error, :not_in_review}

  defp project_repo(%TaskRecord{project_id: nil}), do: {:error, :no_repo}

  defp project_repo(%TaskRecord{project_id: project_id}) do
    case Repo.get(Platform.Tasks.Project, project_id) do
      %{repo_url: url} when is_binary(url) and url != "" ->
        case RepoRef.normalize(url) do
          {:ok, repo} -> {:ok, url, repo}
          :error -> {:error, :no_repo}
        end

      _ ->
        {:error, :no_repo}
    end
  end
end
