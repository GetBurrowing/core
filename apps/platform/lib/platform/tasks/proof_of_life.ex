defmodule Platform.Tasks.ProofOfLife do
  @moduledoc """
  Smallest end-to-end proof flow for the Tasks + Execution epic.

  This module bootstraps a Suite-native demo task, stores a minimal plan inside
  task-scoped context, launches a local execution run against a durable git
  worktree, performs one deterministic file change + verification step, pushes a
  branch, and records the result back into task context and the artifact store.
  """

  alias Platform.{Context, Execution}
  alias Platform.Execution.{CredentialLease, LocalRunner, LocalWorkspace}

  @default_task_id "suite-proof-of-life"
  @default_project_id "startup-suite"
  @default_epic_id "tasks-execution"

  @type config :: keyword()

  @spec default_task_id() :: String.t()
  def default_task_id, do: @default_task_id

  @spec bootstrap_task(keyword()) :: {:ok, String.t()} | {:error, term()}
  def bootstrap_task(opts \\ []) do
    task_id = Keyword.get(opts, :task_id, @default_task_id)
    config = config(opts)

    with {:ok, _session} <- Context.ensure_session(%{task_id: task_id}),
         {:ok, _version} <-
           put_task_item(task_id, "task:meta", task_meta(task_id), kind: :task_metadata),
         {:ok, _version} <-
           put_task_item(task_id, "task:plan", proof_plan(:draft), kind: :task_metadata),
         {:ok, _version} <-
           put_task_item(task_id, "proof_of_life:config", config_snapshot(config),
             kind: :task_metadata
           ),
         {:ok, _version} <-
           put_task_item(task_id, "proof_of_life:status", %{"state" => "ready"},
             kind: :task_metadata
           ) do
      {:ok, task_id}
    end
  end

  @spec approve_plan(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def approve_plan(task_id) do
    put_task_item(task_id, "task:plan", proof_plan(:approved), kind: :task_metadata)
  end

  @spec launch(String.t(), keyword()) :: {:ok, Execution.Run.t()} | {:error, term()}
  def launch(task_id, opts \\ []) do
    config = config(opts)

    with :ok <- ensure_plan_approved(task_id),
         {:ok, repo_path} <- fetch_repo_path(config),
         {:ok, run} <-
           Execution.start_run(task_id,
             project_id: Keyword.get(config, :project_id, @default_project_id),
             epic_id: Keyword.get(config, :epic_id, @default_epic_id),
             runner_type: :local,
             meta: %{"proof_of_life" => true}
           ),
         {:ok, workspace} <-
           LocalWorkspace.ensure_workspace(run, run_root: Keyword.get(config, :run_root)),
         branch = proof_branch(run.id),
         {:ok, worktree_path} <-
           LocalWorkspace.setup_git_worktree(workspace, repo_path,
             branch: branch,
             base_ref: Keyword.get(config, :base_ref, "origin/main")
           ),
         {:ok, _version} <-
           put_task_item(
             task_id,
             "proof_of_life:status",
             %{
               "state" => "starting",
               "run_id" => run.id,
               "branch" => branch,
               "repo_path" => repo_path
             },
             kind: :task_metadata
           ),
         {:ok, _version} <-
           put_task_item(
             task_id,
             "proof_of_life:branch",
             %{
               "branch" => branch,
               "remote" => Keyword.get(config, :remote, "origin"),
               "repo_path" => repo_path
             },
             kind: :task_metadata
           ),
         {:ok, _version} <-
           Execution.push_context(
             run.id,
             %{
               "proof_of_life:plan" => proof_plan(:approved),
               "proof_of_life:instruction" => %{
                 "goal" =>
                   "Make one deterministic repo change, verify it, and prepare it for push.",
                 "branch" => branch
               }
             },
             kind: :task_metadata
           ),
         {:ok, run} <-
           Execution.spawn_provider(run.id, LocalRunner,
             run_root: Keyword.get(config, :run_root),
             credential_lease: github_lease(run.id, config),
             command: shell_path(),
             args: ["-lc", proof_command(run.id)]
           ),
         {:ok, run} <- Execution.transition(run.id, :running) do
      spawn(fn -> finalize_run(task_id, run, worktree_path, branch, config) end)
      {:ok, run}
    end
  end

  defp finalize_run(task_id, run, worktree_path, branch, config) do
    case wait_for_terminal(run.id, Keyword.get(config, :wait_timeout_ms, 30_000)) do
      {:ok, %{status: :completed} = completed_run} ->
        verification = verification_payload(branch)

        _ =
          put_task_item(task_id, "proof_of_life:verification", verification, kind: :task_metadata)

        push_result =
          LocalWorkspace.push_branch(worktree_path, run.id,
            message: "proof-of-life: run #{run.id}",
            remote: Keyword.get(config, :remote, "origin"),
            lease: github_lease(run.id, config)
          )

        case push_result do
          :ok ->
            _ =
              put_task_item(
                task_id,
                "proof_of_life:status",
                %{
                  "state" => "pushed",
                  "run_id" => completed_run.id,
                  "branch" => branch,
                  "verification" => "passed"
                },
                kind: :task_metadata
              )

            _ =
              Execution.register_artifact(completed_run.id, %{
                kind: :code_output,
                name: "proof-of-life branch #{branch}",
                locator: %{
                  branch: branch,
                  remote: Keyword.get(config, :remote, "origin"),
                  repo_path: Keyword.get(config, :repo_path)
                },
                metadata: verification
              })

          {:error, reason} ->
            _ =
              put_task_item(
                task_id,
                "proof_of_life:status",
                %{
                  "state" => "push_failed",
                  "run_id" => completed_run.id,
                  "branch" => branch,
                  "error" => inspect(reason)
                },
                kind: :task_metadata
              )
        end

      {:ok, terminal_run} ->
        _ =
          put_task_item(
            task_id,
            "proof_of_life:status",
            %{
              "state" => Atom.to_string(terminal_run.status),
              "run_id" => terminal_run.id,
              "error" => terminal_run.exit_code
            },
            kind: :task_metadata
          )

      {:error, reason} ->
        _ =
          put_task_item(
            task_id,
            "proof_of_life:status",
            %{
              "state" => "monitor_failed",
              "run_id" => run.id,
              "error" => inspect(reason)
            },
            kind: :task_metadata
          )
    end
  end

  defp wait_for_terminal(run_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_terminal(run_id, deadline)
  end

  defp do_wait_for_terminal(run_id, deadline) do
    case Execution.get_run(run_id) do
      {:ok, run} when run.status in [:completed, :failed, :cancelled] ->
        {:ok, run}

      {:ok, _run} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          do_wait_for_terminal(run_id, deadline)
        else
          {:error, :timeout}
        end

      error ->
        error
    end
  end

  defp ensure_plan_approved(task_id) do
    case current_task_item(task_id, "task:plan") do
      %{"approval_status" => "approved"} -> :ok
      %{approval_status: "approved"} -> :ok
      _ -> {:error, :plan_not_approved}
    end
  end

  defp current_task_item(task_id, key) do
    with {:ok, snapshot} <- Context.snapshot(%{task_id: task_id}) do
      snapshot.items
      |> Enum.find(&(&1.key == key))
      |> case do
        nil -> nil
        item -> item.value
      end
    else
      _ -> nil
    end
  end

  defp put_task_item(task_id, key, value, opts) do
    Context.put_item(%{task_id: task_id}, key, value, opts)
  end

  defp task_meta(task_id) do
    %{
      "title" => "Proof-of-life task",
      "description" =>
        "Suite-native proof run that creates a deterministic repo change, verifies it, and pushes a branch.",
      "source" => "proof_of_life",
      "task_id" => task_id
    }
  end

  defp proof_plan(status) do
    %{
      "title" => "Proof of life plan",
      "approval_status" => Atom.to_string(status),
      "steps" => [
        "Create a durable run workspace and git worktree",
        "Make one deterministic file change",
        "Run a verification command",
        "Push the branch and record the result back in Tasks"
      ]
    }
  end

  defp config_snapshot(config) do
    %{
      "repo_path" => Keyword.get(config, :repo_path),
      "remote" => Keyword.get(config, :remote, "origin"),
      "base_ref" => Keyword.get(config, :base_ref, "origin/main"),
      "run_root" => Keyword.get(config, :run_root)
    }
  end

  defp config(opts) do
    Application.get_env(:platform, :proof_of_life, [])
    |> Keyword.merge(opts)
  end

  defp fetch_repo_path(config) do
    case Keyword.get(config, :repo_path) || System.get_env("PROOF_OF_LIFE_REPO_PATH") do
      nil -> {:error, :missing_repo_path}
      value -> {:ok, Path.expand(value)}
    end
  end

  defp proof_branch(run_id), do: "proof/#{run_id}"

  defp proof_command(run_id) do
    "cd git && printf 'proof-of-life run=#{run_id}\\n' > suite-proof-of-life.txt && test -f suite-proof-of-life.txt"
  end

  defp verification_payload(branch) do
    %{
      "command" => "test -f suite-proof-of-life.txt",
      "status" => "passed",
      "branch" => branch,
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp github_lease(run_id, config) do
    opts = [
      run_id: run_id,
      repo: Keyword.get(config, :repo_slug),
      github_token: Keyword.get(config, :github_token),
      author_name: Keyword.get(config, :author_name, "Suite Runner"),
      author_email: Keyword.get(config, :author_email, "runner@suite.local")
    ]

    case CredentialLease.lease(:github, opts) do
      {:ok, lease} -> lease
      {:error, :missing_github_token} -> nil
      {:error, _reason} -> nil
    end
  end

  defp shell_path, do: System.find_executable("sh") || "/bin/sh"
end
