defmodule Platform.Tasks.PlanDeployRepos do
  @moduledoc """
  A plan's deploy repository declaration (task 01a1e4fa stage 1).

  `plan_create` and `plan_update` accept an optional top-level
  `deploy_repos`: a non-empty list of `%{"repo_url" => url, "ci" =>
  "required" | "none" | "unenforced"}` (`ci` optional). Before this, no MCP
  tool exposed `task.deploy_strategy`, so an agent could not say where a
  task's work lands, and every task resolved to the project's default repo.

  ## One source

  The declaration is written onto `task.deploy_strategy` — the effective
  strategy (`Tasks.resolve_deploy_strategy/1`) with `"repos"` replaced and
  `"repos_declared_by" => "plan"` — in the SAME transaction as the plan
  write. `BranchProvisioner.ensure_branches/2`, `DeployStageBuilder` and the
  heartbeat's deploy prompt all already read that field, so they cannot
  disagree. No column is added.

  ## Two phases

  `prepare/3` runs BEFORE the plan transaction and does every refusal, so a
  refused plan writes nothing at all (the same lockout-free position the
  other plan_create guards occupy). `write_in_transaction/2` is called from
  INSIDE the plan transaction and rolls it back on failure, so a plan and its
  declaration commit or fail together.

  ## Refusals (all recoverable, nothing written)

    * `:deploy_repos_on_stack_member` — `task.stack_id` is set. A strategy
      written onto a stack member would win over `no_op_wait_for_rollup` in
      `Tasks.resolve_deploy_strategy/1` and give it a solo deploy.
    * `:deploy_repos_needs_pr_merge` — the effective strategy is not
      `pr_merge`; only `pr_merge` gates per repository.
    * `:invalid_deploy_repos` — `DeployStageBuilder.validate_strategy/1`
      refused the candidate strategy. There is no second validator.
    * `:deploy_repos_conflict` — `task.deploy_strategy` already carries
      `"repos"` NOT declared by a plan, and they differ. A human declaration
      wins; a previous plan's may be replaced.
    * `:undeclared_cross_repo` — no `deploy_repos`, and the stage text names
      another repository (`PlanEngine.detect_undeclared_cross_repo/2`).

  `"repos_declared_by"` is read ONLY by the conflict rule.
  """

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.DeployStageBuilder
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.RepoRef
  alias Platform.Tasks.Task, as: TaskRecord

  @declared_by_key "repos_declared_by"

  @doc """
  Run every pre-transaction check for a plan write on `task_id`.

  Returns `{:ok, nil}` when nothing is to be written (no declaration, or a
  declaration identical to a human one already on the task), `{:ok,
  strategy}` when `strategy` must be written by `write_in_transaction/2`, or
  `{:error, envelope}` with a tool-surface error envelope carrying `code`.

  An unknown task returns `{:ok, nil}` so the caller's own not-found path
  answers, unchanged.
  """
  @spec prepare(term(), map(), list()) :: {:ok, map() | nil} | {:error, map()}
  def prepare(task_id, args, stages_input) when is_map(args) do
    case load_task(task_id) do
      nil ->
        {:ok, nil}

      %TaskRecord{} = task ->
        case Map.get(args, "deploy_repos") do
          nil -> check_cross_repo(task, stages_input)
          repos -> check_declaration(task, repos)
        end
    end
  end

  @doc """
  Write `strategy` onto the task. MUST be called inside the plan's
  `Repo.transaction/1`; a failed write rolls the whole transaction back.
  `nil` is a no-op.
  """
  @spec write_in_transaction(term(), map() | nil) :: :ok
  def write_in_transaction(_task_id, nil), do: :ok

  def write_in_transaction(task_id, strategy) when is_map(strategy) do
    task = Repo.get!(TaskRecord, task_id)

    case task |> TaskRecord.changeset(%{deploy_strategy: strategy}) |> Repo.update() do
      {:ok, _} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # ── Checks ─────────────────────────────────────────────────────────────

  defp load_task(task_id) do
    if Platform.UUID.valid?(task_id) do
      case Repo.get(TaskRecord, task_id) do
        nil -> nil
        task -> Repo.preload(task, [:project, :stack])
      end
    end
  end

  # The scan only applies where a declaration is both POSSIBLE and MISSING.
  # A task that already carries "repos" (a human or an earlier plan declared
  # them) is not undeclared. A stack member or a non-pr_merge strategy could
  # not accept `deploy_repos`, so refusing it with "pass deploy_repos" would
  # name a fix that is itself refused.
  defp check_cross_repo(task, stages_input) do
    cond do
      declared_repos?(task.deploy_strategy) -> {:ok, nil}
      not is_nil(task.stack_id) -> {:ok, nil}
      effective_type(task) != "pr_merge" -> {:ok, nil}
      true -> scan(task, stages_input)
    end
  end

  defp scan(task, stages_input) do
    project_repo_url = task.project && task.project.repo_url

    case PlanEngine.detect_undeclared_cross_repo(stages_input, project_repo_url) do
      :ok -> {:ok, nil}
      {:error, info} -> {:error, undeclared_cross_repo_envelope(info)}
    end
  end

  defp check_declaration(task, repos) do
    if is_nil(task.stack_id) do
      effective = Tasks.resolve_deploy_strategy(task)

      if Map.get(effective, "type") == "pr_merge" do
        candidate =
          effective
          |> Map.put("repos", repos)
          |> Map.put(@declared_by_key, "plan")

        case DeployStageBuilder.validate_strategy(candidate) do
          :ok -> check_conflict(task, repos, candidate)
          {:error, reason} -> {:error, invalid_envelope(reason)}
        end
      else
        {:error, needs_pr_merge_envelope(Map.get(effective, "type"))}
      end
    else
      {:error, stack_member_envelope(task)}
    end
  end

  defp check_conflict(task, repos, candidate) do
    existing = task.deploy_strategy

    cond do
      not declared_repos?(existing) ->
        {:ok, candidate}

      Map.get(existing, @declared_by_key) == "plan" ->
        {:ok, candidate}

      same_repos?(Map.get(existing, "repos"), repos) ->
        # Identical to the human declaration: nothing to write, and the
        # human's mark is kept so a later plan still cannot replace it.
        {:ok, nil}

      true ->
        {:error, conflict_envelope(Map.get(existing, "repos"), repos)}
    end
  end

  defp declared_repos?(%{"repos" => repos}) when not is_nil(repos), do: true
  defp declared_repos?(_), do: false

  defp effective_type(task), do: task |> Tasks.resolve_deploy_strategy() |> Map.get("type")

  defp same_repos?(left, right) when is_list(left) and is_list(right) do
    repo_keys(left) == repo_keys(right)
  end

  defp same_repos?(_, _), do: false

  defp repo_keys(repos) do
    Enum.map(repos, fn
      entry when is_map(entry) ->
        url = Map.get(entry, "repo_url")
        slug = RepoRef.slug(url)
        {if(slug, do: String.downcase(slug), else: url), Map.get(entry, "ci", "required")}

      other ->
        {other, nil}
    end)
  end

  defp repo_names(repos) when is_list(repos) do
    Enum.map_join(repos, ", ", fn
      entry when is_map(entry) ->
        url = Map.get(entry, "repo_url")
        RepoRef.slug(url) || inspect(url)

      other ->
        inspect(other)
    end)
  end

  defp repo_names(other), do: inspect(other)

  # ── Envelopes ──────────────────────────────────────────────────────────

  defp undeclared_cross_repo_envelope(%{slugs: slugs, project_slug: project_slug}) do
    named = Enum.join(slugs, ", ")
    project = project_slug || "the project repository"

    include_project =
      if project_slug do
        ~s(, and include #{project_slug} as well if any of the work also lands there)
      else
        ""
      end

    %{
      code: :undeclared_cross_repo,
      error:
        "The stage text names #{named}, which is not this project's repository (#{project}), " <>
          "but the plan declares no deploy_repos. Without a declaration the task branch is " <>
          "created in, and the deploy gate watches, #{project} only, so work pushed to " <>
          "#{named} would ship through a gate on the wrong repository.",
      recoverable: true,
      suggestion:
        "Retry with a top-level \"deploy_repos\" listing every repository the work lands in, " <>
          ~s(e.g. "deploy_repos": [{"repo_url": "https://github.com/#{hd(slugs)}"}]) <>
          include_project <>
          ". If the stage only MENTIONS #{named} and no work lands there, declare the project " <>
          "repository alone. Nothing was written."
    }
  end

  defp stack_member_envelope(task) do
    %{
      code: :deploy_repos_on_stack_member,
      error:
        "deploy_repos cannot be declared on task #{task.id}: it is a member of stack " <>
          "#{task.stack_id}, which ships as one rollup PR. A task-level deploy strategy would " <>
          "override the rollup and give this member its own deploy.",
      recoverable: true,
      suggestion:
        "Retry without deploy_repos. The stack's rollup decides where the work deploys. " <>
          "Nothing was written."
    }
  end

  defp needs_pr_merge_envelope(type) do
    %{
      code: :deploy_repos_needs_pr_merge,
      error:
        "deploy_repos only applies to a pr_merge deploy strategy; this task's effective " <>
          "strategy is #{inspect(type)}, which does not gate per repository.",
      recoverable: true,
      suggestion:
        "Retry without deploy_repos, or ask a human to set the project or task deploy " <>
          "strategy to pr_merge first. Nothing was written."
    }
  end

  defp invalid_envelope(reason) do
    %{
      code: :invalid_deploy_repos,
      error: "deploy_repos is invalid: #{reason}",
      recoverable: true,
      suggestion:
        "Pass a non-empty list of {\"repo_url\": \"https://github.com/<owner>/<name>\", " <>
          "\"ci\": \"required\" | \"none\" | \"unenforced\"} objects (ci optional, default " <>
          "required). Nothing was written."
    }
  end

  defp conflict_envelope(existing, requested) do
    %{
      code: :deploy_repos_conflict,
      error:
        "This task's deploy repositories were set outside a plan (#{repo_names(existing)}) and " <>
          "differ from the plan's deploy_repos (#{repo_names(requested)}). A human " <>
          "declaration is not overwritten by a plan.",
      recoverable: true,
      suggestion:
        "Retry without deploy_repos to keep the existing set, or with exactly the existing set, " <>
          "or ask a human to change the task's deploy strategy. Nothing was written."
    }
  end
end
