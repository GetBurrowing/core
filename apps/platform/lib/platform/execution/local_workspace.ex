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
      with :ok <- normalize_worktree_git_permissions(worktree_path, branch) do
        {:ok, worktree_path}
      end
    else
      with :ok <- File.mkdir_p(workspace_path) do
        case System.cmd(
               "git",
               ["worktree", "add", worktree_path, "-b", branch, base_ref],
               cd: repo_path,
               stderr_to_stdout: true
             ) do
          {_out, 0} ->
            with :ok <- normalize_worktree_git_permissions(worktree_path, branch) do
              {:ok, worktree_path}
            end

          {output, code} when is_binary(output) ->
            trimmed = String.trim(output)

            if String.contains?(trimmed, "already exists") or
                 String.contains?(trimmed, "already used by worktree") do
              if String.contains?(trimmed, "already used by worktree") do
                _ =
                  System.cmd("git", ["worktree", "prune"], cd: repo_path, stderr_to_stdout: true)
              end

              case System.cmd(
                     "git",
                     ["worktree", "add", worktree_path, branch],
                     cd: repo_path,
                     stderr_to_stdout: true
                   ) do
                {_out2, 0} ->
                  with :ok <- normalize_worktree_git_permissions(worktree_path, branch) do
                    {:ok, worktree_path}
                  end

                {output2, code2} when is_binary(output2) ->
                  trimmed2 = String.trim(output2)

                  if String.contains?(trimmed2, "already used by worktree") do
                    _ =
                      System.cmd("git", ["worktree", "prune"],
                        cd: repo_path,
                        stderr_to_stdout: true
                      )

                    case System.cmd(
                           "git",
                           ["worktree", "add", worktree_path, branch],
                           cd: repo_path,
                           stderr_to_stdout: true
                         ) do
                      {_out3, 0} ->
                        with :ok <- normalize_worktree_git_permissions(worktree_path, branch) do
                          {:ok, worktree_path}
                        end

                      {output3, code3} ->
                        {:error, {:worktree_add_failed, code3, String.trim(output3)}}
                    end
                  else
                    {:error, {:worktree_add_failed, code2, trimmed2}}
                  end
              end
            else
              {:error, {:worktree_add_failed, code, trimmed}}
            end
        end
      end
    end
  end

  @doc """
  Configures local git credential helper state for authenticated HTTPS push.

  The helper reads `GITHUB_TOKEN` from the process environment at push time, so
  the token never needs to be written into the repository config itself. If no
  valid lease is available, this is a no-op.
  """
  @spec prepare_git_push_auth(String.t(), CredentialLease.t() | nil) :: :ok | {:error, term()}
  def prepare_git_push_auth(_worktree_path, nil), do: :ok

  def prepare_git_push_auth(worktree_path, %CredentialLease{} = lease) do
    if CredentialLease.valid?(lease) do
      helper =
        "!f() { test -n \"$GITHUB_TOKEN\" || exit 1; echo username=x-access-token; echo password=$GITHUB_TOKEN; }; f"

      with :ok <- git_config_local(worktree_path, "credential.helper", helper),
           :ok <- git_config_local(worktree_path, "credential.useHttpPath", "true") do
        :ok
      end
    else
      :ok
    end
  end

  @doc """
  Returns `git status --short` output for the worktree.
  """
  @spec git_status(String.t()) :: {:ok, String.t()} | {:error, term()}
  def git_status(worktree_path) do
    case System.cmd("git", ["status", "--short"], cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:git_status_failed, code, String.trim(output)}}
    end
  end

  @doc """
  Returns the current HEAD SHA for the worktree.
  """
  @spec current_head_sha(String.t()) :: {:ok, String.t()} | {:error, term()}
  def current_head_sha(worktree_path) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:git_head_failed, code, String.trim(output)}}
    end
  end

  @doc """
  Returns the remote SHA for `branch`, or `nil` if the ref does not exist.
  """
  @spec remote_branch_sha(String.t(), String.t(), String.t(), CredentialLease.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def remote_branch_sha(worktree_path, remote, branch, lease \\ nil) do
    env = build_git_env(lease)

    case System.cmd(
           "git",
           ["ls-remote", remote, "refs/heads/#{branch}"],
           cd: worktree_path,
           env: env,
           stderr_to_stdout: true
         ) do
      {"", 0} ->
        {:ok, nil}

      {output, 0} ->
        sha =
          output
          |> String.trim()
          |> String.split()
          |> List.first()

        {:ok, sha}

      {output, code} ->
        {:error, {:git_ls_remote_failed, code, String.trim(output)}}
    end
  end

  @doc """
  Stages all changes, commits, and pushes the current branch to `origin`.

  The caller may supply a valid `CredentialLease` so the push can authenticate.
  """
  @spec push_branch(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def push_branch(worktree_path, run_id, opts \\ []) do
    message = Keyword.get(opts, :message, "Run #{run_id} checkpoint")
    remote = Keyword.get(opts, :remote, "origin")
    lease = Keyword.get(opts, :lease)

    env = build_git_env(lease)

    with :ok <- prepare_git_push_auth(worktree_path, lease),
         :ok <- git_add_all(worktree_path, env),
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

  defp normalize_worktree_git_permissions(worktree_path, branch) do
    git_pointer = Path.join(worktree_path, ".git")

    with {:ok, pointer} <- File.read(git_pointer),
         gitdir when is_binary(gitdir) <- parse_gitdir(pointer),
         true <- gitdir != nil do
      common_gitdir = common_gitdir(gitdir)

      paths = [
        gitdir,
        Path.join([common_gitdir, "refs"]),
        Path.dirname(Path.join([common_gitdir, "refs", "heads", branch])),
        Path.join([common_gitdir, "refs", "heads", branch]),
        Path.join([common_gitdir, "logs", "refs"]),
        Path.dirname(Path.join([common_gitdir, "logs", "refs", "heads", branch])),
        Path.join([common_gitdir, "logs", "refs", "heads", branch])
      ]

      Enum.each(paths, &relax_git_path/1)
      :ok
    else
      nil -> :ok
      {:error, :enoent} -> :ok
      _ -> :ok
    end
  end

  defp common_gitdir(gitdir) do
    commondir_file = Path.join(gitdir, "commondir")

    case File.read(commondir_file) do
      {:ok, relative_path} -> Path.expand(String.trim(relative_path), gitdir)
      _ -> Path.expand(Path.join(gitdir, "../.."))
    end
  end

  defp relax_git_path(path) do
    cond do
      File.dir?(path) ->
        _ = System.cmd("chmod", ["g+s", path], stderr_to_stdout: true)
        _ = System.cmd("chmod", ["-R", "ug+rwX", path], stderr_to_stdout: true)
        :ok

      File.exists?(path) ->
        _ = System.cmd("chmod", ["ug+rwX", path], stderr_to_stdout: true)
        :ok

      true ->
        :ok
    end
  end

  defp parse_gitdir(pointer) when is_binary(pointer) do
    pointer
    |> String.trim()
    |> case do
      <<"gitdir: ", path::binary>> -> String.trim(path)
      _ -> nil
    end
  end

  defp git_add_all(worktree_path, env) do
    case System.cmd("git", ["add", "--all"], cd: worktree_path, env: env, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {output, code} -> {:error, {:git_add_failed, code, String.trim(output)}}
    end
  end

  defp git_commit(worktree_path, message, env) do
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

  defp git_config_local(worktree_path, key, value) do
    case System.cmd(
           "git",
           ["config", "--local", key, value],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      {output, code} -> {:error, {:git_config_failed, key, code, String.trim(output)}}
    end
  end

  defp build_git_env(nil), do: []

  defp build_git_env(%CredentialLease{} = lease) do
    lease
    |> CredentialLease.to_env()
    |> Enum.map(fn {k, v} -> {k, v} end)
    |> Kernel.++([{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_ASKPASS", "true"}])
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
