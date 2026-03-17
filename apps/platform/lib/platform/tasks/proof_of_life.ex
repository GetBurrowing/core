defmodule Platform.Tasks.ProofOfLife do
  @moduledoc """
  Smallest end-to-end proof flow for the Tasks + Execution epic.

  This module bootstraps a Suite-native demo task, stores a minimal plan inside
  task-scoped context, launches a local execution run against a durable git
  worktree, and verifies that the orchestration can produce a real repo change
  and push it to GitHub.

  Two execution modes are supported:

    * `:scripted` (default) — a deterministic shell step writes the proof file,
      then the platform commits + pushes after the runner exits. This keeps the
      test path fully hermetic.
    * `:claude_cli` — the runner launches the authenticated Claude CLI inside the
      prepared worktree and the agent itself performs the edit, commit, and push.
      This is the Hive-oriented proof that a real agent subprocess can be
      orchestrated end-to-end.
  """

  alias Platform.{Context, Execution}
  alias Platform.Execution.{CredentialLease, DockerRunner, LocalRunner, LocalWorkspace}

  @default_task_id "suite-proof-of-life"
  @default_project_id "startup-suite"
  @default_epic_id "tasks-execution"
  @default_remote "origin"
  @default_proof_file "docs/proof-of-life.md"

  @type config :: keyword()
  @type execution_mode :: :scripted | :claude_cli | :docker_scripted | :docker_claude_cli

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
    mode = execution_mode(config)
    remote = Keyword.get(config, :remote, @default_remote)

    with :ok <- validate_mode(config, mode),
         :ok <- ensure_plan_approved(task_id),
         {:ok, repo_path} <- fetch_repo_path(config),
         runner_module = runner_module(mode),
         {:ok, run} <-
           Execution.start_run(task_id,
             project_id: Keyword.get(config, :project_id, @default_project_id),
             epic_id: Keyword.get(config, :epic_id, @default_epic_id),
             runner_type: runner_type(mode),
             meta: %{
               "proof_of_life" => true,
               "execution_mode" => Atom.to_string(mode),
               "runner_backend" => Atom.to_string(runner_type(mode)),
               "repo_path" => repo_path,
               "remote" => remote
             }
           ),
         {:ok, workspace} <-
           LocalWorkspace.ensure_workspace(run, run_root: Keyword.get(config, :run_root)),
         branch = proof_branch(run.id),
         {:ok, worktree_path} <-
           LocalWorkspace.setup_git_worktree(workspace, repo_path,
             branch: branch,
             base_ref: Keyword.get(config, :base_ref, "origin/main")
           ),
         lease = github_lease(run.id, config),
         :ok <- maybe_prepare_agent_push_auth(worktree_path, lease, mode),
         {:ok, _version} <-
           put_task_item(
             task_id,
             "proof_of_life:status",
             %{
               "state" => "starting",
               "mode" => Atom.to_string(mode),
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
               "remote" => remote,
               "repo_path" => repo_path,
               "mode" => Atom.to_string(mode)
             },
             kind: :task_metadata
           ),
         {:ok, context_version} <-
           Execution.push_context(
             run.id,
             %{
               "proof_of_life:plan" => proof_plan(:approved),
               "proof_of_life:instruction" => instruction_payload(run, branch, config, mode)
             },
             kind: :task_metadata
           ),
         {:ok, run} <-
           spawn_run_provider(
             run,
             runner_module,
             config,
             mode,
             lease,
             branch,
             context_version
           ),
         {:ok, run} <- Execution.transition(run.id, :running) do
      spawn(fn -> finalize_run(task_id, run, worktree_path, branch, config, mode, lease) end)
      {:ok, run}
    end
  end

  defp finalize_run(task_id, run, worktree_path, branch, config, mode, lease) do
    remote = Keyword.get(config, :remote, @default_remote)

    case wait_for_terminal(run.id, Keyword.get(config, :wait_timeout_ms, 120_000)) do
      {:ok, %{status: :completed} = completed_run} ->
        with {:ok, _push_state} <-
               maybe_push_branch(worktree_path, completed_run, config, mode, lease),
             {:ok, verification} <-
               verify_run(completed_run, worktree_path, branch, remote, mode, lease),
             :ok <- persist_success(task_id, completed_run, branch, verification),
             :ok <-
               register_result_artifacts(
                 completed_run,
                 branch,
                 remote,
                 worktree_path,
                 verification
               ) do
          :ok
        else
          {:error, reason} ->
            put_failure_status(task_id, run.id, branch, :verification_failed, reason)
        end

      {:ok, terminal_run} ->
        put_failure_status(
          task_id,
          terminal_run.id,
          branch,
          terminal_run.status,
          terminal_run.exit_code
        )

      {:error, reason} ->
        put_failure_status(task_id, run.id, branch, :monitor_failed, reason)
    end
  end

  defp maybe_push_branch(worktree_path, run, config, mode, lease)
       when mode in [:scripted, :docker_scripted] do
    case LocalWorkspace.push_branch(worktree_path, run.id,
           message: commit_message(run.id),
           remote: Keyword.get(config, :remote, @default_remote),
           lease: lease
         ) do
      :ok -> {:ok, :platform_pushed}
      {:error, reason} -> {:error, {:git_push_failed, reason}}
    end
  end

  defp maybe_push_branch(_worktree_path, _run, _config, mode, _lease)
       when mode in [:claude_cli, :docker_claude_cli, :codex_exec, :docker_codex_exec],
       do: {:ok, :agent_pushed}

  defp verify_run(run, worktree_path, branch, remote, mode, lease) do
    proof_file = proof_file_path(worktree_path)

    with {:ok, status_output} <- LocalWorkspace.git_status(worktree_path),
         {:ok, head_sha} <- LocalWorkspace.current_head_sha(worktree_path),
         {:ok, remote_sha} <-
           LocalWorkspace.remote_branch_sha(worktree_path, remote, branch, lease),
         {:ok, proof_content} <- File.read(proof_file) do
      clean = String.trim(status_output) == ""

      proof_present =
        String.contains?(proof_content, run.id) and String.contains?(proof_content, run.task_id)

      pushed = is_binary(remote_sha) and remote_sha == head_sha

      output_path = Path.join(Path.dirname(worktree_path), "agent-output.txt")
      prompt_path = Path.join(Path.dirname(worktree_path), "proof-of-life-prompt.txt")

      verification = %{
        "status" => if(clean and proof_present and pushed, do: "passed", else: "failed"),
        "mode" => Atom.to_string(mode),
        "branch" => branch,
        "remote" => remote,
        "head_sha" => head_sha,
        "remote_sha" => remote_sha,
        "clean_worktree" => clean,
        "proof_file" => Path.relative_to(proof_file, worktree_path),
        "proof_entry_present" => proof_present,
        "git_status" => if(clean, do: "(clean)", else: status_output),
        "output_path" => output_path,
        "prompt_path" => prompt_path,
        "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      if verification["status"] == "passed" do
        {:ok, verification}
      else
        {:error, {:verification_failed, verification}}
      end
    else
      {:error, :enoent} -> {:error, {:proof_file_missing, proof_file}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_success(task_id, completed_run, branch, verification) do
    with {:ok, _version} <-
           put_task_item(task_id, "proof_of_life:verification", verification,
             kind: :task_metadata
           ),
         {:ok, _version} <-
           put_task_item(
             task_id,
             "proof_of_life:status",
             %{
               "state" => "pushed",
               "mode" => verification["mode"],
               "run_id" => completed_run.id,
               "branch" => branch,
               "verification" => verification["status"],
               "head_sha" => verification["head_sha"],
               "remote_sha" => verification["remote_sha"]
             },
             kind: :task_metadata
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_result_artifacts(run, branch, remote, worktree_path, verification) do
    proof_file = proof_file_path(worktree_path)

    with {:ok, _artifact} <-
           Execution.register_artifact(run.id, %{
             kind: :code_output,
             name: "proof-of-life verification",
             locator: %{
               type: "inline",
               content: Jason.encode!(verification)
             },
             metadata: verification
           }),
         {:ok, _artifact} <-
           Execution.register_artifact(run.id, %{
             kind: :generic,
             name: "proof-of-life branch #{branch}",
             locator: %{
               branch: branch,
               remote: remote,
               repo_path: Map.get(run.meta, "repo_path")
             },
             metadata: verification
           }) do
      _ = maybe_register_file_artifact(run.id, "proof-of-life file", proof_file, "text/markdown")

      _ =
        maybe_register_file_artifact(
          run.id,
          "proof-of-life runner output",
          verification["output_path"],
          "text/plain"
        )

      _ =
        maybe_register_file_artifact(
          run.id,
          "proof-of-life prompt",
          verification["prompt_path"],
          "text/plain"
        )

      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_register_file_artifact(run_id, name, path, content_type) do
    case File.read(path) do
      {:ok, content} ->
        Execution.register_artifact(run_id, %{
          kind: :code_output,
          name: name,
          content_type: content_type,
          locator: %{
            type: "inline",
            content: content
          },
          metadata: %{
            "path" => path
          }
        })

      {:error, _reason} ->
        :ok
    end
  end

  defp put_failure_status(task_id, run_id, branch, state, reason) do
    _ =
      put_task_item(
        task_id,
        "proof_of_life:status",
        %{
          "state" => to_string(state),
          "run_id" => run_id,
          "branch" => branch,
          "error" => inspect(reason)
        },
        kind: :task_metadata
      )

    :ok
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
        "Suite-native proof run that launches a real execution flow, makes a deterministic repo change, verifies it, and pushes a branch.",
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
        "Launch the selected execution mode inside the worktree",
        "Verify the proof file, local commit, and remote branch state",
        "Record the result back in Tasks and the artifact store"
      ]
    }
  end

  defp config_snapshot(config) do
    mode = execution_mode(config)

    %{
      "repo_path" => Keyword.get(config, :repo_path),
      "remote" => Keyword.get(config, :remote, @default_remote),
      "base_ref" => Keyword.get(config, :base_ref, "origin/main"),
      "run_root" => Keyword.get(config, :run_root),
      "host_run_root" => Keyword.get(config, :host_run_root),
      "host_repo_git_path" => Keyword.get(config, :host_repo_git_path),
      "mode" => Atom.to_string(mode),
      "proof_file" => Keyword.get(config, :proof_file, @default_proof_file),
      "claude_command" => Keyword.get(config, :claude_command, "claude"),
      "codex_command" => Keyword.get(config, :codex_command, "codex"),
      "runner_image" => Keyword.get(config, :runner_image, "suite-runner:dev"),
      "ssh_auth_path" => Keyword.get(config, :ssh_auth_path),
      "push_remote_url" => Keyword.get(config, :push_remote_url)
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

  defp execution_mode(config) do
    case Keyword.get(config, :mode, :scripted) do
      mode
      when mode in [
             :scripted,
             :claude_cli,
             :codex_exec,
             :docker_scripted,
             :docker_claude_cli,
             :docker_codex_exec
           ] ->
        mode

      mode when is_binary(mode) ->
        normalize_mode(mode)

      _ ->
        :scripted
    end
  end

  defp normalize_mode("scripted"), do: :scripted
  defp normalize_mode("claude_cli"), do: :claude_cli
  defp normalize_mode("claude-cli"), do: :claude_cli
  defp normalize_mode("codex_exec"), do: :codex_exec
  defp normalize_mode("codex-exec"), do: :codex_exec
  defp normalize_mode("docker_scripted"), do: :docker_scripted
  defp normalize_mode("docker-scripted"), do: :docker_scripted
  defp normalize_mode("docker_claude_cli"), do: :docker_claude_cli
  defp normalize_mode("docker-claude-cli"), do: :docker_claude_cli
  defp normalize_mode("docker_codex_exec"), do: :docker_codex_exec
  defp normalize_mode("docker-codex-exec"), do: :docker_codex_exec
  defp normalize_mode(_), do: :scripted

  defp validate_mode(config, :claude_cli) do
    executable = Keyword.get(config, :claude_command, "claude")

    if System.find_executable(executable) do
      :ok
    else
      {:error, {:missing_executable, executable}}
    end
  end

  defp validate_mode(config, :codex_exec) do
    executable = Keyword.get(config, :codex_command, "codex")

    if System.find_executable(executable) do
      :ok
    else
      {:error, {:missing_executable, executable}}
    end
  end

  defp validate_mode(_config, :docker_claude_cli), do: :ok
  defp validate_mode(_config, :docker_codex_exec), do: :ok
  defp validate_mode(_config, :docker_scripted), do: :ok
  defp validate_mode(_config, :scripted), do: :ok

  defp runner_module(mode)
       when mode in [:docker_scripted, :docker_claude_cli, :docker_codex_exec], do: DockerRunner

  defp runner_module(_mode), do: LocalRunner

  defp runner_type(mode) when mode in [:docker_scripted, :docker_claude_cli, :docker_codex_exec],
    do: :docker

  defp runner_type(_mode), do: :local

  defp spawn_run_provider(run, LocalRunner, config, mode, lease, branch, context_version) do
    Execution.spawn_provider(run.id, LocalRunner,
      run_root: Keyword.get(config, :run_root),
      credential_lease: lease,
      context_version: context_version,
      command: shell_path(),
      args: ["-lc", proof_command(run, branch, context_version, config, mode)]
    )
  end

  defp spawn_run_provider(run, DockerRunner, config, mode, lease, branch, context_version) do
    container_run_root = Keyword.get(config, :run_root, "/data/platform/execution-runs")

    Execution.spawn_provider(run.id, DockerRunner,
      run_root: Keyword.get(config, :run_root),
      host_workspace_root: Keyword.get(config, :host_run_root),
      container_workspace_path: Path.join(container_run_root, run.id),
      runner_user: Keyword.get(config, :runner_user),
      credential_lease: lease,
      context_version: context_version,
      command: "/bin/sh",
      args: ["-lc", proof_command(run, branch, context_version, config, mode)],
      extra_env: runner_auth_env(config),
      meta_overrides: runner_meta_overrides(config, mode)
    )
  end

  defp proof_branch(run_id), do: "proof/#{run_id}"

  defp proof_command(run, branch, context_version, config, :scripted) do
    output_path = "../agent-output.txt"

    [
      "set -eu",
      ack_context_command(context_version),
      "export GIT_CONFIG_GLOBAL=../.gitconfig",
      "cd git",
      "git config --global --add safe.directory \"$PWD\"",
      heredoc_append(proof_file(config), scripted_proof_entry(run, branch)),
      "printf 'scripted proof run complete\\n' > #{shell_escape(output_path)}",
      "git status --short >> #{shell_escape(output_path)}"
    ]
    |> Enum.join("\n")
  end

  defp proof_command(run, branch, context_version, config, mode)
       when mode in [:claude_cli, :docker_claude_cli] do
    prompt_path = "../proof-of-life-prompt.txt"
    output_path = "../agent-output.txt"
    claude = shell_escape(Keyword.get(config, :claude_command, "claude"))
    push_remote_url = Keyword.get(config, :push_remote_url)

    [
      "set -eu",
      ack_context_command(context_version),
      "export GIT_CONFIG_GLOBAL=../.gitconfig",
      "cd git",
      "git config --global --add safe.directory \"$PWD\"",
      maybe_set_push_remote(push_remote_url),
      heredoc_write(prompt_path, claude_prompt(run, branch, config, mode)),
      "#{claude} --print --permission-mode bypassPermissions \"$(cat #{shell_escape(prompt_path)})\" > #{shell_escape(output_path)} 2>&1"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp proof_command(run, branch, context_version, config, mode)
       when mode in [:codex_exec, :docker_codex_exec] do
    prompt_path = "../proof-of-life-prompt.txt"
    output_path = "../agent-output.txt"
    codex = shell_escape(Keyword.get(config, :codex_command, "codex"))
    push_remote_url = Keyword.get(config, :push_remote_url)

    [
      "set -eu",
      ack_context_command(context_version),
      "export GIT_CONFIG_GLOBAL=../.gitconfig",
      "cd git",
      "git config --global --add safe.directory \"$PWD\"",
      "git config --global user.name #{shell_escape(Keyword.get(config, :author_name, "Suite Runner"))}",
      "git config --global user.email #{shell_escape(Keyword.get(config, :author_email, "runner@suite.local"))}",
      maybe_set_push_remote(push_remote_url),
      heredoc_write(prompt_path, claude_prompt(run, branch, config, mode)),
      "#{codex} exec --dangerously-bypass-approvals-and-sandbox -C . \"$(cat #{shell_escape(prompt_path)})\" > #{shell_escape(output_path)} 2>&1"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp ack_context_command(version) when is_integer(version) and version > 0 do
    "printf '%s\n' #{version} > .context-ack-version"
  end

  defp ack_context_command(_version), do: nil

  defp instruction_payload(run, branch, config, mode) do
    %{
      "goal" =>
        "Make one deterministic proof-of-life repo change, then verify that the branch was committed and pushed.",
      "mode" => Atom.to_string(mode),
      "branch" => branch,
      "remote" => Keyword.get(config, :remote, @default_remote),
      "proof_file" => proof_file(config),
      "run_id" => run.id,
      "task_id" => run.task_id
    }
  end

  defp maybe_prepare_agent_push_auth(worktree_path, lease, mode)
       when mode in [:claude_cli, :docker_claude_cli, :codex_exec, :docker_codex_exec] do
    LocalWorkspace.prepare_git_push_auth(worktree_path, lease)
  end

  defp maybe_prepare_agent_push_auth(_worktree_path, _lease, _mode), do: :ok

  defp proof_file_path(worktree_path) do
    Path.join(worktree_path, @default_proof_file)
  end

  defp proof_file(config) do
    Keyword.get(config, :proof_file, @default_proof_file)
  end

  defp scripted_proof_entry(run, branch) do
    [
      "## Run #{run.id}",
      "",
      "- task_id: #{run.task_id}",
      "- branch: #{branch}",
      "- mode: scripted",
      "- host: suite-proof",
      "- recorded_at: #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}",
      ""
    ]
    |> Enum.join("\n")
  end

  defp claude_prompt(run, branch, config, mode) do
    remote = Keyword.get(config, :remote, @default_remote)
    proof_file = proof_file(config)
    mode_label = Atom.to_string(mode)

    """
    You are running inside a git worktree prepared by Startup Suite on Hive.

    Goal: prove that the platform can orchestrate a real agent subprocess that edits a repository, commits the change, and pushes the branch to GitHub.

    Requirements:
    - Stay inside the current repository.
    - Do not ask questions; just complete the task.
    - Keep the change tiny and deterministic.
    - Stay on the current branch: #{branch}
    - The target file is #{proof_file}

    Do exactly this:
    1. Ensure #{proof_file} exists.
    2. Append a new markdown entry for this run containing:
       - run_id: #{run.id}
       - task_id: #{run.task_id}
       - branch: #{branch}
       - mode: #{mode_label}
       - host: hive
    3. Run git status --short.
    4. Commit the change with this exact message:
       #{commit_message(run.id)}
    5. Push the current HEAD to #{remote} as branch #{branch}.
    6. Print these exact result lines at the end:
       RESULT branch=#{branch}
       RESULT commit=$(git rev-parse HEAD)
       RESULT remote=#{remote}
       RESULT status=done

    If anything fails, stop immediately and print one line beginning with ERROR: followed by the reason.
    """
  end

  defp commit_message(run_id), do: "proof-of-life: run #{run_id}"

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

  defp runner_auth_env(config) do
    config
    |> Keyword.get(:runner_auth_env, [])
    |> Enum.reduce(%{}, fn key, acc ->
      case System.get_env(to_string(key)) do
        nil -> acc
        value -> Map.put(acc, to_string(key), value)
      end
    end)
  end

  defp runner_meta_overrides(config, mode) do
    base = [runner_image: Keyword.get(config, :runner_image, "suite-runner:dev")]

    case runner_extra_mounts(config, mode) do
      [] -> base
      mounts -> Keyword.put(base, :extra_mounts, mounts)
    end
  end

  defp runner_extra_mounts(config, mode) when mode in [:docker_claude_cli, :docker_codex_exec] do
    []
    |> maybe_add_mount(Keyword.get(config, :ssh_auth_path), "/home/node/.ssh", true)
    |> maybe_add_mount(Keyword.get(config, :host_repo_git_path), "/repos/core/.git", false)
    |> maybe_add_mount(Keyword.get(config, :host_codex_auth_path), "/home/node/.codex", false)
  end

  defp runner_extra_mounts(_config, _mode), do: []

  defp maybe_add_mount(mounts, nil, _container_target, _read_only), do: mounts
  defp maybe_add_mount(mounts, "", _container_target, _read_only), do: mounts

  defp maybe_add_mount(mounts, host_source, container_target, read_only) do
    mounts ++ [bind_mount(host_source, container_target, read_only)]
  end

  defp bind_mount(host_source, container_target, read_only) do
    %{
      type: "bind",
      host_source: host_source,
      container_target: container_target,
      read_only: read_only
    }
  end

  defp maybe_set_push_remote(nil), do: nil
  defp maybe_set_push_remote(""), do: nil

  defp maybe_set_push_remote(url) do
    "git remote set-url origin #{shell_escape(url)}"
  end

  defp shell_path, do: System.find_executable("sh") || "/bin/sh"

  defp heredoc_write(path, content) do
    "cat > #{shell_escape(path)} <<'EOF_PROOF'\n#{content}\nEOF_PROOF"
  end

  defp heredoc_append(path, content) do
    [
      "mkdir -p #{shell_escape(Path.dirname(path))}",
      "touch #{shell_escape(path)}",
      "cat >> #{shell_escape(path)} <<'EOF_PROOF'",
      content,
      "EOF_PROOF"
    ]
    |> Enum.join("\n")
  end

  defp shell_escape(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("'", "'\\''")

    "'#{escaped}'"
  end
end
