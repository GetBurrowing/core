defmodule Platform.Execution.LocalWorkspace do
  @moduledoc """
  Deterministic per-run workspace allocation for the local execution provider.

  ## Workspace modes

  The initial MVP allocates a plain durable directory per run under a
  configurable root. No git state is assumed or required.

  The `setup_git_worktree/3` function layers optional git worktree management
  on top of that same seam: given a source repo and branch name it creates a
  worktree under the run directory. This path supports the GitHub proof-of-life
  flow where the local provider must push a branch deterministically.

  ## Push path

  `push_branch/3` runs a minimal git command sequence inside a workspace that
  has been set up with `setup_git_worktree/3`. It:

    1. Creates a commit with any staged or unstaged changes
    2. Pushes the run branch to the remote origin

  Callers are responsible for staging the intended changes before calling
  `push_branch/3`.
  """

  alias Platform.Execution.{CredentialLease, Run}

  @default_root "tmp/execution/runs"

  @type workspace :: %{
          root: String.t(),
          path: String.t()
        }

  @doc """
  Ensures the per-run workspace directory exists and returns its paths.

  The workspace path is deterministic: `<run_root>/<safe_run_id>`. Calling
  this function a second time for the same run is a no-op; it returns the
  same paths.
  """
  @spec ensure_workspace(Run.t(), keyword()) :: {:ok, workspace()} | {:error, term()}
  def ensure_workspace(%Run{id: run_id}, opts \\ []) when is_binary(run_id) do
    root = run_root(opts)
    path = Path.join(root, safe_run_segment(run_id))

    with :ok <- File.mkdir_p(path) do
      {:ok, %{root: root, path: path}}
    end
  end

  @doc """
  Sets up a git worktree for the run inside an already-allocated workspace.

  Given a `repo_path` (path to an existing git repo) and `branch` name, this
  function creates a new git worktree at `<workspace.path>/git` tracking a new
  (or existing) branch named `branch`.

  If the worktree already exists this is a no-op.

  Options:
    - `:base_ref` — the ref to branch from (default: `"HEAD"`)

  Returns `{:ok, worktree_path}` or `{:error, reason}`.
  """
  @spec setup_git_worktree(workspace(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def setup_git_worktree(%{path: workspace_path} = _workspace, repo_path, opts \\ []) do
    worktree_path = Path.join(workspace_path, "git")
    base_ref = Keyword.get(opts, :base_ref, "HEAD")
    branch = Keyword.fetch!(opts, :branch)

    git_file = Path.join(worktree_path, ".git")

    if File.exists?(git_file) do
      # Worktree already set up — idempotent return
      {:ok, worktree_path}
    else
      with :ok <- File.mkdir_p(workspace_path) do
        case System.cmd(
               "git",
               ["worktree", "add", worktree_path, "-b", branch, base_ref],
               cd: repo_path,
               stderr_to_stdout: true
             ) do
          {_out, 0} ->
            {:ok, worktree_path}

          {output, _code} when is_binary(output) ->
            trimmed = String.trim(output)

            # If the branch already exists in the repo, try without -b to attach
            # to the existing branch. This handles repeated calls where the
            # worktree dir was removed but the branch persists.
            if String.contains?(trimmed, "already exists") do
              case System.cmd(
                     "git",
                     ["worktree", "add", worktree_path, branch],
                     cd: repo_path,
                     stderr_to_stdout: true
                   ) do
                {_out2, 0} -> {:ok, worktree_path}
                {output2, code2} -> {:error, {:worktree_add_failed, code2, String.trim(output2)}}
              end
            else
              {:error, {:worktree_add_failed, trimmed}}
            end
        end
      end
    end
  end

  @doc """
  Stages all changes, commits, and pushes the current branch to `origin`.

  The caller must supply a valid `CredentialLease` so the push can
  authenticate. The lease's `GITHUB_TOKEN` is injected into the git credential
  helper for the duration of the push.

  Options:
    - `:message`  — commit message (default: `"Run <run_id> checkpoint"`)
    - `:remote`   — remote name (default: `"origin"`)
    - `:lease`    — a `CredentialLease.t()` (required for authenticated push)

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec push_branch(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def push_branch(worktree_path, run_id, opts \\ []) do
    message = Keyword.get(opts, :message, "Run #{run_id} checkpoint")
    remote = Keyword.get(opts, :remote, "origin")
    lease = Keyword.get(opts, :lease)

    env = build_git_env(lease)

    with :ok <- git_add_all(worktree_path, env),
         :ok <- git_commit(worktree_path, message, env),
         {:ok, branch} <- git_current_branch(worktree_path, env),
         :ok <- git_push(worktree_path, remote, branch, env) do
      :ok
    end
  end

  @doc """
  Returns the configured run root directory (expanded to an absolute path).
  """
  @spec run_root(keyword()) :: String.t()
  def run_root(opts \\ []) do
    opts
    |> Keyword.get(:run_root, configured_run_root())
    |> Path.expand()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp git_add_all(worktree_path, env) do
    case System.cmd("git", ["add", "--all"], cd: worktree_path, env: env, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {output, code} -> {:error, {:git_add_failed, code, String.trim(output)}}
    end
  end

  defp git_commit(worktree_path, message, env) do
    # --allow-empty lets us commit even if nothing was staged; useful for
    # proof-of-life runs that only verify the push path, not code changes.
    case System.cmd(
           "git",
           ["commit", "--allow-empty", "-m", message],
           cd: worktree_path,
           env: env,
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      {output, code} -> {:error, {:git_commit_failed, code, String.trim(output)}}
    end
  end

  defp git_current_branch(worktree_path, env) do
    case System.cmd(
           "git",
           ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: worktree_path,
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:git_branch_failed, code, String.trim(output)}}
    end
  end

  defp git_push(worktree_path, remote, branch, env) do
    case System.cmd(
           "git",
           ["push", remote, "#{branch}:#{branch}"],
           cd: worktree_path,
           env: env,
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      {output, code} -> {:error, {:git_push_failed, code, String.trim(output)}}
    end
  end

  defp build_git_env(nil), do: []

  defp build_git_env(%CredentialLease{} = lease) do
    lease_env = CredentialLease.to_env(lease)

    # Inject a git credential helper that uses GITHUB_TOKEN when present,
    # so `git push` authenticates without interactive prompts.
    helper_env =
      if token = Map.get(lease_env, "GITHUB_TOKEN") do
        helper_script = "!f() { echo \"password=#{token}\"; }; f"
        [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_ASKPASS", "true"}, {"GIT_CREDENTIAL_HELPER", helper_script}]
      else
        []
      end

    lease_env
    |> Enum.map(fn {k, v} -> {k, v} end)
    |> Kernel.++(helper_env)
  end

  defp configured_run_root do
    :platform
    |> Application.get_env(:execution, [])
    |> Keyword.get(:local_run_root, @default_root)
  end

  defp safe_run_segment(run_id) do
    run_id
    |> String.replace(~r/[^A-Za-z0-9._-]/u, "_")
    |> case do
      "" -> "run"
      value -> value
    end
  end
end
