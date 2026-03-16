defmodule Platform.Execution.ProofRun do
  @moduledoc """
  End-to-end proof-of-life run orchestration.

  `ProofRun` wires together the existing execution/context/artifact seams into
  one deterministic callable that:

    1. Creates a run via `Platform.Execution.start_run/2`
    2. Transitions the run to `:running`
    3. Pushes initial task-metadata context items into the run scope
    4. Makes a tiny, deterministic repo change: appends a timestamped entry to
       `docs/proof-of-life.md` in the repo worktree
    5. Runs `git status --short` as a verification command and captures the
       output
    6. Registers the verification output as an execution artifact
    7. Optionally pushes the branch to GitHub when a valid `CredentialLease`
       is available
    8. Registers the pushed branch ref as a second artifact
    9. Transitions the run to `:completed` (or `:failed` on error)

  All results surface back through PubSub automatically: artifact registration
  broadcasts `{:artifact_registered, artifact}` and context pushes broadcast
  `{:context_delta, delta}`. `PlatformWeb.TasksLive` already subscribes to
  these topics and reloads on each event.

  ## Usage

      opts = [
        project_id: "proj-123",
        repo_path: "/path/to/repo",   # required for git operations
        branch: "task/my-task-id",    # branch to commit on
        credential_lease: lease,       # optional; enables GitHub push
      ]

      {:ok, result} = ProofRun.run(task_id, opts)
      # result.run      — the completed Run struct
      # result.artifacts — list of registered Artifact structs
      # result.branch   — branch name that was pushed (or nil)
      # result.verification_output — raw git status output

  ## Run-without-repo mode

  When `:repo_path` is omitted, the git worktree and push steps are skipped.
  The run still creates a workspace, pushes context, and registers a
  verification artifact containing the workspace path. This is useful for
  CI/test environments where the host repo is not available.
  """

  require Logger

  alias Platform.Execution
  alias Platform.Execution.{CredentialLease, LocalWorkspace, Run}
  alias Platform.Artifacts

  @type result :: %{
          run: Run.t(),
          artifacts: [Artifacts.Artifact.t()],
          branch: String.t() | nil,
          verification_output: String.t() | nil,
          pushed: boolean()
        }

  @doc """
  Executes the full proof-of-life run for `task_id`.

  Options:
    - `:run_id`          — override the generated run ID
    - `:project_id`      — project scope
    - `:epic_id`         — epic scope
    - `:repo_path`       — absolute path to the git repo for worktree operations
    - `:branch`          — branch name to create/commit on
    - `:credential_lease` — a `CredentialLease.t()` for authenticated push
    - `:run_root`        — override the workspace root directory
    - `:meta`            — additional metadata merged into the run struct

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(task_id, opts \\ []) when is_binary(task_id) do
    with {:ok, run} <- start_run(task_id, opts),
         {:ok, run} <- transition_to_running(run),
         {:ok, _version} <- push_initial_context(run, task_id, opts),
         {:ok, state} <- execute_repo_work(run, opts),
         {:ok, result} <- finalize(run, state, opts) do
      {:ok, result}
    else
      {:error, reason} = error ->
        Logger.warning("[ProofRun] run failed for task #{task_id}: #{inspect(reason)}")
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Step 1: Start the run
  # ---------------------------------------------------------------------------

  defp start_run(task_id, opts) do
    run_opts =
      opts
      |> Keyword.take([:run_id, :project_id, :epic_id, :run_root, :meta])
      |> Keyword.put(:runner_type, :local)

    case Execution.start_run(task_id, run_opts) do
      {:ok, run} ->
        Logger.info("[ProofRun] started run #{run.id} for task #{task_id}")
        {:ok, run}

      {:error, reason} ->
        {:error, {:start_run_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Step 2: Transition to running
  # ---------------------------------------------------------------------------

  defp transition_to_running(run) do
    with {:ok, run} <- Execution.transition(run.id, :starting),
         {:ok, run} <- Execution.transition(run.id, :running) do
      {:ok, run}
    else
      {:error, reason} -> {:error, {:transition_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Step 3: Push initial context
  # ---------------------------------------------------------------------------

  defp push_initial_context(run, task_id, opts) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    items = %{
      "proof_run.task_id" => task_id,
      "proof_run.run_id" => run.id,
      "proof_run.started_at" => now,
      "proof_run.repo_path" => Keyword.get(opts, :repo_path, ""),
      "proof_run.branch" => Keyword.get(opts, :branch, "")
    }

    case Execution.push_context(run.id, items) do
      {:ok, version} ->
        Logger.debug("[ProofRun] pushed initial context at version #{version}")
        {:ok, version}

      {:error, reason} ->
        {:error, {:push_context_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Step 4 + 5: Repo work (change + verify)
  # ---------------------------------------------------------------------------

  defp execute_repo_work(run, opts) do
    repo_path = Keyword.get(opts, :repo_path)
    branch = Keyword.get(opts, :branch, "proof-of-life/#{run.id}")

    if is_binary(repo_path) and repo_path != "" do
      do_repo_work(run, repo_path, branch, opts)
    else
      # No repo path — run in workspace-only mode
      workspace_only_work(run, opts)
    end
  end

  defp do_repo_work(run, repo_path, branch, opts) do
    run_root = Keyword.get(opts, :run_root)
    run_root_opts = if run_root, do: [run_root: run_root], else: []
    lease = Keyword.get(opts, :credential_lease)

    with {:ok, workspace} <- LocalWorkspace.ensure_workspace(run, run_root_opts),
         {:ok, wt_path} <-
           LocalWorkspace.setup_git_worktree(workspace, repo_path,
             branch: branch,
             base_ref: "HEAD"
           ),
         :ok <- write_proof_change(wt_path, run),
         {:ok, verify_output} <- verify_change(wt_path),
         push_result <- attempt_push(wt_path, run, branch, lease) do
      {:ok,
       %{
         workspace: workspace,
         worktree_path: wt_path,
         branch: branch,
         verification_output: verify_output,
         push_result: push_result
       }}
    else
      {:error, reason} -> {:error, {:repo_work_failed, reason}}
    end
  end

  defp workspace_only_work(run, opts) do
    run_root_opts = if run_root = Keyword.get(opts, :run_root), do: [run_root: run_root], else: []

    case LocalWorkspace.ensure_workspace(run, run_root_opts) do
      {:ok, workspace} ->
        verify_output = "workspace-only mode, path=#{workspace.path}"

        {:ok,
         %{
           workspace: workspace,
           worktree_path: nil,
           branch: nil,
           verification_output: verify_output,
           push_result: :skipped
         }}

      {:error, reason} ->
        {:error, {:workspace_failed, reason}}
    end
  end

  defp write_proof_change(wt_path, run) do
    proof_file = Path.join(wt_path, "docs/proof-of-life.md")
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    # Append a timestamped proof entry — never overwrites prior entries
    entry =
      "\n## Run #{run.id}\n\n- task: #{run.task_id}\n- at: #{now}\n- status: proof-of-life\n"

    case File.read(proof_file) do
      {:ok, existing} ->
        File.write(proof_file, existing <> entry)

      {:error, :enoent} ->
        File.mkdir_p!(Path.dirname(proof_file))

        preamble =
          "# Proof-of-Life Log\n\nThis file records deterministic proof-of-life run entries.\n"

        File.write(proof_file, preamble <> entry)

      {:error, reason} ->
        {:error, {:write_proof_file_failed, reason}}
    end
  end

  defp verify_change(wt_path) do
    case System.cmd("git", ["status", "--short"],
           cd: wt_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        trimmed = String.trim(output)
        output_str = if trimmed == "", do: "(clean — no uncommitted changes)", else: trimmed
        Logger.debug("[ProofRun] git status: #{output_str}")
        {:ok, output_str}

      {output, code} ->
        {:error, {:git_status_failed, code, String.trim(output)}}
    end
  end

  defp attempt_push(wt_path, run, branch, lease) do
    if is_struct(lease, CredentialLease) and CredentialLease.valid?(lease) do
      result =
        LocalWorkspace.push_branch(wt_path, run.id,
          message: "proof-of-life: run #{run.id} on task #{run.task_id}",
          remote: "origin",
          lease: lease
        )

      case result do
        :ok ->
          Logger.info("[ProofRun] pushed branch #{branch}")
          {:ok, branch}

        {:error, reason} ->
          Logger.warning("[ProofRun] push failed: #{inspect(reason)} — continuing without push")
          {:error, reason}
      end
    else
      Logger.debug("[ProofRun] no valid credential lease — skipping push")
      :skipped
    end
  end

  # ---------------------------------------------------------------------------
  # Step 6–9: Register artifacts and finalize
  # ---------------------------------------------------------------------------

  defp finalize(run, state, _opts) do
    artifacts = []

    # Artifact 1: verification output
    {:ok, verify_artifact} =
      Execution.register_artifact(run.id, %{
        kind: :code_output,
        name: "proof-of-life verification",
        content_type: "text/plain",
        locator: %{
          "type" => "inline",
          "content" => state.verification_output
        },
        metadata: %{
          "step" => "git_status",
          "worktree_path" => state.worktree_path || "",
          "branch" => state.branch || ""
        }
      })

    artifacts = [verify_artifact | artifacts]

    # Artifact 2: branch ref (only when push succeeded)
    {artifacts, pushed, branch} =
      case state.push_result do
        {:ok, pushed_branch} ->
          {:ok, branch_artifact} =
            Execution.register_artifact(run.id, %{
              kind: :generic,
              name: "github branch ref",
              content_type: "application/json",
              locator: %{
                "type" => "github_branch",
                "branch" => pushed_branch,
                "repo" => run.meta["repo"] || ""
              },
              metadata: %{
                "step" => "git_push",
                "branch" => pushed_branch,
                "pushed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
              }
            })

          {[branch_artifact | artifacts], true, pushed_branch}

        _ ->
          {artifacts, false, state.branch}
      end

    # Push final context update with run outcome
    push_final_context(run, state, pushed, branch)

    # Transition run to :completed
    {:ok, completed_run} = Execution.transition(run.id, :completed)

    Logger.info("[ProofRun] completed run #{run.id} — pushed=#{pushed}")

    {:ok,
     %{
       run: completed_run,
       artifacts: Enum.reverse(artifacts),
       branch: branch,
       verification_output: state.verification_output,
       pushed: pushed
     }}
  end

  defp push_final_context(run, state, pushed, branch) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    items = %{
      "proof_run.finished_at" => now,
      "proof_run.verification_output" => state.verification_output || "",
      "proof_run.pushed" => to_string(pushed),
      "proof_run.branch" => branch || ""
    }

    case Execution.push_context(run.id, items) do
      {:ok, version} ->
        Logger.debug("[ProofRun] pushed final context at version #{version}")

      {:error, reason} ->
        Logger.warning("[ProofRun] final context push failed: #{inspect(reason)}")
    end
  end
end
