defmodule Platform.Orchestration.HeartbeatScheduler do
  @moduledoc """
  Stage-aware heartbeat cadence configuration and prompt generation.

  Provides pure functions for determining heartbeat intervals, stall thresholds,
  and generating dispatch/heartbeat prompt messages. No GenServer — this module
  is called by `TaskRouter` to decide timing and message content.

  Cadence table (from ADR 0025):

  | Stage type        | Heartbeat interval | Stall threshold | Escalation after    |
  |-------------------|--------------------|-----------------|---------------------|
  | planning          | 15 min             | 30 min          | 2 missed heartbeats |
  | coding            | 10 min             | 25 min          | 2 missed heartbeats |
  | ci_check          | 5 min              | 15 min          | 3 missed heartbeats |
  | review            | 20 min             | 60 min          | 1 missed heartbeat  |
  | manual_approval   | n/a                | n/a             | n/a (human gate)    |
  """

  alias Platform.Orchestration.PromptTemplates

  @type stage_type :: String.t()

  # Cadence config: {interval_ms, stall_threshold_ms, max_escalations}
  @cadence %{
    "planning" => {15 * 60_000, 30 * 60_000, 2},
    "coding" => {10 * 60_000, 25 * 60_000, 2},
    "ci_check" => {5 * 60_000, 15 * 60_000, 3},
    "review" => {20 * 60_000, 60 * 60_000, 1},
    "manual_approval" => {nil, nil, nil}
  }

  # Default for unknown stage types — treat like coding
  @default_cadence {10 * 60_000, 25 * 60_000, 2}

  @skills_reference """
  The dispatch context includes attached skills under the `skills` key. \
  Treat bundled skill content in that payload as authoritative for this task before trying to rediscover skills from disk. \
  Read and follow any relevant bundled skills — they describe conventions, repo layout, deploy targets, and how to delegate work. \
  Only fall back to filesystem skill lookup if the payload clearly references a path without including the needed content.\
  """

  @doc "Heartbeat interval in milliseconds for the given stage type."
  @spec interval_ms(stage_type()) :: non_neg_integer() | nil
  def interval_ms(stage_type) do
    {interval, _stall, _esc} = Map.get(@cadence, stage_type, @default_cadence)
    interval
  end

  @doc "Stall threshold in milliseconds for the given stage type."
  @spec stall_threshold_ms(stage_type()) :: non_neg_integer() | nil
  def stall_threshold_ms(stage_type) do
    {_interval, stall, _esc} = Map.get(@cadence, stage_type, @default_cadence)
    stall
  end

  @doc "Maximum missed heartbeats before escalation."
  @spec max_escalations(stage_type()) :: non_neg_integer() | nil
  def max_escalations(stage_type) do
    {_interval, _stall, esc} = Map.get(@cadence, stage_type, @default_cadence)
    esc
  end

  @doc "Returns true if the stage type is a human gate that should skip heartbeats."
  @spec manual_approval?(stage_type()) :: boolean()
  def manual_approval?(stage_type), do: stage_type == "manual_approval"

  @doc """
  Generate the initial dispatch prompt sent when a task is first assigned.

  Tries to load the prompt from the DB (via PromptTemplates), falls back to the
  hardcoded prompt if the template is not found.

  Pattern-matched on task status and plan/stage presence:
  - planning (no plan) — instruct agent to create and submit a plan
  - in_progress — execute current stage with evidence
  - in_review — run validations, do not self-approve gates
  - fallback — generic assignment prompt
  """
  @spec dispatch_prompt(map(), map() | nil, map() | nil) :: String.t()
  def dispatch_prompt(%{status: "planning"} = task, nil, nil) do
    assigns = %{
      task_title: task.title,
      task_description: task.description || "No description provided.",
      task_priority: task.priority,
      skills_reference: @skills_reference
    }

    case PromptTemplates.render_template("dispatch.planning", assigns) do
      {:ok, rendered} ->
        rendered

      {:error, :not_found} ->
        hardcoded_dispatch_planning(task)
    end
  end

  def dispatch_prompt(%{status: "in_progress"} = task, plan, stage) do
    stage_info = format_stage_info(plan, stage)
    repo_url = project_attr(task, :repo_url, "")
    default_branch = project_attr(task, :default_branch, "main")
    task_slug = short_task_id(task)

    assigns = %{
      task_title: task.title,
      stage_info: stage_info,
      repo_url: repo_url,
      default_branch: default_branch,
      task_slug: task_slug,
      skills_reference: @skills_reference
    }

    prompt =
      case PromptTemplates.render_template("dispatch.in_progress", assigns) do
        {:ok, rendered} ->
          rendered

        {:error, :not_found} ->
          hardcoded_dispatch_in_progress(task, plan, stage)
      end

    enrich_in_progress_prompt(prompt, task, stage)
  end

  def dispatch_prompt(%{status: "in_review"} = task, plan, stage) do
    stage_info = format_stage_info(plan, stage)
    repo_url = project_attr(task, :repo_url, "")
    default_branch = project_attr(task, :default_branch, "main")
    task_slug = short_task_id(task)

    assigns = %{
      task_title: task.title,
      stage_info: stage_info,
      repo_url: repo_url,
      default_branch: default_branch,
      task_slug: task_slug,
      skills_reference: @skills_reference
    }

    prompt =
      case PromptTemplates.render_template("dispatch.in_review", assigns) do
        {:ok, rendered} ->
          rendered

        {:error, :not_found} ->
          hardcoded_dispatch_in_review(task, plan, stage)
      end

    enrich_in_review_prompt(prompt, task, stage)
  end

  def dispatch_prompt(task, plan, stage) do
    stage_info = format_stage_info(plan, stage)

    assigns = %{
      task_title: task.title,
      task_description: task.description || "No description provided.",
      task_status: task.status,
      task_priority: task.priority,
      stage_info: stage_info,
      skills_reference: @skills_reference
    }

    case PromptTemplates.render_template("dispatch.fallback", assigns) do
      {:ok, rendered} ->
        rendered

      {:error, :not_found} ->
        hardcoded_dispatch_fallback(task, plan, stage)
    end
  end

  @doc """
  Generate a stateful heartbeat interrogation prompt.

  Tries to load the prompt from the DB (via PromptTemplates), falls back to the
  hardcoded prompt if the template is not found.

  This is not a keepalive — it carries elapsed time, stage position, and
  pending validations to force the agent to account for itself.
  """
  @spec heartbeat_prompt(map(), map() | nil, non_neg_integer(), list()) :: String.t()
  def heartbeat_prompt(task, stage, elapsed_seconds, pending_validations) do
    elapsed_str = format_elapsed(elapsed_seconds)
    stage_name = if stage, do: stage.name, else: "unknown"
    stage_status = if stage, do: stage.status, else: "unknown"

    pending_str =
      case pending_validations do
        [] -> "none"
        validations -> Enum.map_join(validations, ", ", & &1.kind)
      end

    assigns = %{
      task_title: task.title,
      stage_name: stage_name,
      stage_status: stage_status,
      elapsed: elapsed_str,
      pending_validations: pending_str
    }

    prompt =
      case PromptTemplates.render_template("heartbeat", assigns) do
        {:ok, rendered} ->
          rendered

        {:error, :not_found} ->
          hardcoded_heartbeat(task, stage_name, stage_status, elapsed_str, pending_str)
      end

    enrich_heartbeat_prompt(prompt, task, stage, pending_validations)
  end

  # ── Hardcoded fallback prompts ─────────────────────────────────────────

  defp hardcoded_dispatch_planning(task) do
    """
    You have been assigned a task that requires a plan before any implementation begins.

    Task: #{task.title}
    Description: #{task.description || "No description provided."}
    Priority: #{task.priority}

    Create a plan using the plan_create tool. The plan will be reviewed by a human before work starts — make it specific enough that they can meaningfully approve or reject it.

    ## Plan structure

    The plan covers the full task lifecycle: implementation AND review. Structure it in two sections:

    **Implementation stages** (run in `in_progress`):
    - Each stage represents a discrete, reviewable unit of work
    - Validations: use `test_pass` and `lint_pass` for code changes
    - Push branch when implementation stages are complete — do NOT open a PR yet

    **Final review stage** (runs when task moves to `in_review`):
    - Name it "Review" or "Validation"
    - Describe: exercise the feature in the local/dev environment, confirm it matches the task goal
    - If the feature has a visible UI: take a screenshot or canvas snapshot as evidence
    - Validations:
      - Use `test_pass` / `lint_pass` for deterministic checks
      - Use `manual_approval` if a human needs to sign off on UI or behavior
      - When you reach a `manual_approval` validation: call `suite_review_request_create` and post a
        screenshot into the execution space so the human can review before approving
    - On success: open the PR and include the PR link as evidence on the final validation

    Do NOT include `code_review` as a validation kind — it is not supported.

    ## Stage quality bar

    A good stage description explains: what specifically will be changed, which files will be modified
    or created, what the implementation approach is, and why. Generic labels like "Client-side changes"
    are not acceptable.

    Example:
    "Add a module-level drafts Map to ComposeInput JS hook (assets/js/hooks/compose_input.js). On every
    input event, store the current textarea value keyed by space_id. On mounted(), restore any saved
    draft and push it to the server via compose_changed event. On compose_reset, delete the draft."

    Aim for 3–7 total stages. Submit with plan_submit. Do not begin implementation until approved.

    The attention signal includes a `context` field with the full task hierarchy: project (name,
    repo_url, tech_stack), epic (name, description, acceptance_criteria), task metadata, current plan
    with stages, and execution_space_id. Use it for full context when writing your plan.

    #{@skills_reference}
    """
  end

  defp hardcoded_dispatch_in_progress(task, plan, stage) do
    stage_info = format_stage_info(plan, stage)

    """
    Plan approved — execute the current stage.

    Task: #{task.title}
    #{stage_info}\
    Push evidence using validation_pass or stage_complete as you finish each step. \
    Post commentary to the execution space so reviewers can follow along. \
    Use report_blocker if you are stuck.

    The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.
    Start from the concrete stage contract and any attached/bundled skill content in that payload before re-fetching broad task/project context.
    Avoid redundant task/plan lookup churn on the first turn unless an identifier is genuinely missing or the stage contract is ambiguous.

    #{@skills_reference}
    """
    |> enrich_in_progress_prompt(task, stage)
  end

  defp hardcoded_dispatch_in_review(task, plan, stage) do
    stage_info = format_stage_info(plan, stage)
    repo_url = project_attr(task, :repo_url, "")
    default_branch = project_attr(task, :default_branch, "main")

    """
    Task is in review — validate the implementation by exercising it in the local/dev environment.

    Task: #{task.title}
    #{stage_info}\
    Your job is to exercise and validate the feature, not just check static artifacts.
    Work through the current review stage's validations and push evidence for each.

    First-turn rule (CRITICAL):
    - If the dispatch already includes `Current task_id`, `Current stage_id`, `validation_id`, and execution-space context, do NOT spend your first substantive turn on broad task/plan rediscovery.
    - For a `manual_approval` review stage, your first substantive turn should normally do the review work and then create the human gate in the same attempt:
      1. exercise the implementation,
      2. publish evidence into the execution space,
      3. call `suite_review_request_create` for the provided validation with labelled checklist items and links to that evidence.
    - Only call `suite_task_get`, `suite_plan_get`, or `suite_validation_list` if an identifier is missing, the dispatch context is contradicted by direct evidence, or you need a specific field that is not already present.
    - Do not stop after status-check churn — reach the evidence + review-request step unless a real blocker prevents it.
    - Do NOT spend this review attempt inspecting unrelated repository history or workspace state first (for example `git status`, `git log`, broad `git diff`, or listing the whole workspace) unless a specific blocker explicitly requires it.
    - Prefer direct review actions over repo archaeology: use the local app, execution-space artifacts, screenshots, and Suite review tools before exploring source diffs.

    Review rules:
    - Use `suite_validation_evaluate` for deterministic review validations (`passed` / `failed`).
    - Use `suite_review_request_create` for `manual_approval` validations and include labelled checklist items plus screenshots/canvas/evidence links.
    - Do NOT self-approve `manual_approval` validations.
    - Do NOT call `stage_complete` before the required manual-review request and evidence have been created.
    - Do NOT manually call `task_update` to move statuses — the plan engine drives transitions.
    - If review fails, record a `failed` result on the relevant validation with specific failure details so the task can return to `in_progress`.
    - If review passes, let the plan engine advance the task; do not force status changes manually.

    The attention signal that delivered this message includes a `context` field with the full task hierarchy:
    project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.

    #{@skills_reference}
    """
  end

  defp hardcoded_dispatch_fallback(task, plan, stage) do
    stage_info = format_stage_info(plan, stage)

    """
    You have been assigned a task.

    Task: #{task.title}
    Description: #{task.description || "No description provided."}
    Status: #{task.status}
    Priority: #{task.priority}
    #{stage_info}\
    Review the task context and begin working. Report progress by pushing validation evidence as you complete each stage.

    The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, current plan with stages, and execution_space_id. Use it for full context.

    #{@skills_reference}
    """
  end

  defp hardcoded_heartbeat(task, stage_name, stage_status, elapsed_str, pending_str) do
    """
    Task: #{task.title} [stage: #{stage_name} — #{stage_status}]
    Stage running for: #{elapsed_str}
    Pending validations: #{pending_str}

    Either push validation evidence or report a blocker.

    The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id.\
    """
  end

  # ── Private helpers ────────────────────────────────────────────────────

  defp enrich_in_progress_prompt(prompt, task, stage) do
    prompt
    |> maybe_strip_git_workflow(task)
    |> insert_before_context(execution_contract(task, stage))
    |> maybe_insert_git_workflow(task)
  end

  defp enrich_in_review_prompt(prompt, task, stage) do
    prompt
    |> maybe_strip_review_git_checks(task)
    |> maybe_strip_task_update_status_instructions()
    |> insert_before_context(review_contract(task, stage))
  end

  defp enrich_heartbeat_prompt(prompt, task, stage, pending_validations) do
    prompt
    |> append_unless_present(heartbeat_contract(task, stage, pending_validations))
  end

  defp maybe_strip_git_workflow(prompt, task) do
    if real_repo_url?(project_attr(task, :repo_url, "")) do
      prompt
    else
      Regex.replace(
        ~r/\n## Git Workflow \(CRITICAL\).*?(?=\nThe attention signal|\z)/s,
        prompt,
        "\n"
      )
    end
  end

  defp maybe_insert_git_workflow(prompt, task) do
    repo_url = project_attr(task, :repo_url, "")

    if real_repo_url?(repo_url) and not String.contains?(prompt, "## Git Workflow (CRITICAL)") do
      insert_before_context(prompt, git_workflow_section(task))
    else
      prompt
    end
  end

  defp maybe_strip_review_git_checks(prompt, task) do
    if real_repo_url?(project_attr(task, :repo_url, "")) do
      prompt
    else
      Regex.replace(
        ~r/\nRun these checks exactly and push evidence for each result:.*?(?=\nIf ALL checks pass:|\n## Review Validation Contract|\nThe attention signal|\z)/s,
        prompt,
        "\n"
      )
      |> String.replace(
        "Check CI / GitHub Actions status with `gh` CLI for #{project_attr(task, :repo_url, "")}",
        ""
      )
      |> String.replace(
        "Check CI / GitHub Actions status#{gh_repo_suffix(project_attr(task, :repo_url, ""))}",
        ""
      )
      |> String.replace(
        "   - Confirm the task branch exists and is pushed: `git fetch origin && git branch -r | grep task/`\n",
        ""
      )
      |> String.replace(
        "   - At that point, open a PR against #{project_attr(task, :default_branch, "main")}#{pr_repo_suffix(project_attr(task, :repo_url, ""))} if not already open\n",
        ""
      )
      |> String.replace(project_attr(task, :repo_url, ""), "")
    end
  end

  defp maybe_strip_task_update_status_instructions(prompt) do
    prompt
    |> then(fn text ->
      Regex.replace(
        ~r/\nIf ALL checks pass:.*?(?=\nIf ANY check fails:|\n## Review Validation Contract|\nThe attention signal|\z)/s,
        text,
        "\n"
      )
    end)
    |> then(fn text ->
      Regex.replace(
        ~r/\nIf ANY check fails:.*?(?=\nDo not self-approve|\n## Review Validation Contract|\nThe attention signal|\z)/s,
        text,
        "\n"
      )
    end)
  end

  defp execution_contract(_task, nil), do: ""

  defp execution_contract(task, stage) do
    stage_id = Map.get(stage, :id) || Map.get(stage, "id") || "<unknown-stage>"
    task_id = Map.get(task, :id) || Map.get(task, "id") || "<unknown-task>"
    validations = Map.get(stage, :validations) || Map.get(stage, "validations") || []

    validation_lines =
      case validations do
        [] ->
          "- This stage has no validations. Once the stage work is genuinely complete, call `stage_complete` with `stage_id=#{stage_id}`."

        items ->
          Enum.map_join(items, "\n", fn validation ->
            kind = Map.get(validation, :kind) || Map.get(validation, "kind") || "validation"
            id = Map.get(validation, :id) || Map.get(validation, "id") || "<missing-id>"

            "- `#{kind}` → validation_id=`#{id}` (use `validation_pass`, then call `stage_complete` with `stage_id=#{stage_id}` once all required validations are passed)"
          end)
      end

    """

    ## Stage Execution Contract
    Current task_id: `#{task_id}`
    Current stage_id: `#{stage_id}`
    #{validation_lines}
    - If you get blocked, call `report_blocker` with `task_id=#{task_id}` and `stage_id=#{stage_id}`.
    """
  end

  defp review_contract(_task, nil), do: ""

  defp review_contract(task, stage) do
    stage_id = Map.get(stage, :id) || Map.get(stage, "id") || "<unknown-stage>"
    task_id = Map.get(task, :id) || Map.get(task, "id") || "<unknown-task>"
    validations = Map.get(stage, :validations) || Map.get(stage, "validations") || []

    validation_lines =
      case validations do
        [] ->
          "- This review stage has no explicit validations. Gather evidence in the execution space and only move forward when the human review is genuinely complete."

        items ->
          Enum.map_join(items, "\n", fn validation ->
            kind = Map.get(validation, :kind) || Map.get(validation, "kind") || "validation"
            id = Map.get(validation, :id) || Map.get(validation, "id") || "<missing-id>"

            case kind do
              "manual_approval" ->
                "- `manual_approval` → validation_id=`#{id}` (create a `suite_review_request_create` for this validation with labelled checklist items and evidence links/screenshots; do NOT self-approve it)"

              _ ->
                "- `#{kind}` → validation_id=`#{id}` (record results with `suite_validation_evaluate`; use status `passed` or `failed` and include concrete evidence)"
            end
          end)
      end

    """

    ## Review Validation Contract
    Current task_id: `#{task_id}`
    Current stage_id: `#{stage_id}`
    #{validation_lines}
    - Do NOT call `task_update` for lifecycle status changes. Review outcomes flow through validations and review requests.
    - If review evidence shows the feature is not good enough, fail the relevant validation so the task can return to `in_progress`.
    """
  end

  defp heartbeat_contract(_task, nil, _pending_validations), do: ""

  defp heartbeat_contract(task, stage, pending_validations) do
    stage_id = Map.get(stage, :id) || Map.get(stage, "id") || "<unknown-stage>"
    task_id = Map.get(task, :id) || Map.get(task, "id") || "<unknown-task>"

    pending_lines =
      case pending_validations do
        [] ->
          "- No validations are pending. If the work is complete, call `stage_complete` with `stage_id=#{stage_id}`."

        items ->
          Enum.map_join(items, "\n", fn validation ->
            kind = Map.get(validation, :kind) || Map.get(validation, "kind") || "validation"
            id = Map.get(validation, :id) || Map.get(validation, "id") || "<missing-id>"
            "- Pending `#{kind}` → validation_id=`#{id}`"
          end)
      end

    """

    ## Completion Reminder
    Current task_id: `#{task_id}`
    Current stage_id: `#{stage_id}`
    #{pending_lines}
    - Use `report_blocker` with `task_id=#{task_id}` and `stage_id=#{stage_id}` if you cannot make forward progress.
    """
  end

  defp git_workflow_section(task) do
    repo_url = project_attr(task, :repo_url, "")
    default_branch = project_attr(task, :default_branch, "main")
    task_slug = short_task_id(task)

    """

    ## Git Workflow (CRITICAL)
    Repository: #{repo_url}
    Base branch: #{default_branch}

    1. Create a worktree from the latest #{default_branch} branch:
       ```
       git fetch origin
       git worktree add ../worktrees/#{task_slug} -b task/#{task_slug} origin/#{default_branch}
       cd ../worktrees/#{task_slug}
       ```
    2. Do ALL work in the worktree directory.
    3. When implementation is complete:
       - Run the full test suite and lint checks
       - Commit all changes with a descriptive message referencing task #{short_task_id(task)}
       - Push the branch: `git push -u origin task/#{task_slug}`
       - Do NOT open a PR yet — PR opening happens after successful review in `in_review`
    4. NEVER work on an existing branch. ALWAYS branch from latest origin/#{default_branch}.
    """
  end

  defp insert_before_context(prompt, ""), do: prompt

  defp insert_before_context(prompt, addition) do
    context_anchor = "\nThe attention signal"

    if String.contains?(prompt, context_anchor) do
      String.replace(prompt, context_anchor, addition <> context_anchor, global: false)
    else
      prompt <> addition
    end
  end

  defp append_unless_present(prompt, ""), do: prompt

  defp append_unless_present(prompt, addition) do
    if String.contains?(prompt, String.trim(addition)) do
      prompt
    else
      prompt <> addition
    end
  end

  defp real_repo_url?(repo_url) when is_binary(repo_url) do
    repo_url != "" and not String.contains?(repo_url, "example.invalid")
  end

  defp real_repo_url?(_repo_url), do: false

  defp format_stage_info(nil, _stage), do: ""

  defp format_stage_info(plan, nil) do
    stage_count = length(plan.stages || [])
    "Plan: v#{plan.version} (#{stage_count} stages)\n"
  end

  defp format_stage_info(plan, stage) do
    stages = plan.stages || []
    stage_count = length(stages)
    position = stage.position || 0
    "Plan: v#{plan.version} (stage #{position}/#{stage_count} — #{stage.name})\n"
  end

  defp project_attr(task, key, default) do
    project = Map.get(task, :project) || Map.get(task, "project") || %{}
    Map.get(project, key) || Map.get(project, Atom.to_string(key)) || default
  end

  defp short_task_id(task) do
    task
    |> Map.get(:id, Map.get(task, "id", "task"))
    |> to_string()
    |> String.split("-")
    |> List.first()
  end

  defp pr_repo_suffix(""), do: ""
  defp pr_repo_suffix(repo_url), do: " on #{repo_url}"

  defp gh_repo_suffix(""), do: ""
  defp gh_repo_suffix(repo_url), do: " for #{repo_url}"

  defp format_elapsed(seconds) when seconds < 60, do: "#{seconds} seconds"

  defp format_elapsed(seconds) do
    minutes = div(seconds, 60)

    if minutes < 60 do
      "#{minutes} minutes"
    else
      hours = div(minutes, 60)
      remaining_minutes = rem(minutes, 60)
      "#{hours}h #{remaining_minutes}m"
    end
  end
end
