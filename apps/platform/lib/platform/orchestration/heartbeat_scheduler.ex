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
    "deploying" => {5 * 60_000, 15 * 60_000, 3},
    "deploy_failure" => {5 * 60_000, 10 * 60_000, 3},
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

  @evidence_workflow_reference """
  ## Submitting evidence for a `manual_approval` validation

  Visual evidence (screenshots, rendered UI, diagrams) is the bottleneck where most agents stall. The path that actually works is a four-tool chain. Use it; don't improvise.

  1. **Capture** — drive the `rock-node-screenshot` skill from hive (`openclaw nodes canvas navigate --node Rock <url>` then `openclaw nodes canvas snapshot --node Rock`). The snapshot is written as `MEDIA:/tmp/openclaw/openclaw-canvas-snapshot-<uuid>.jpg` on hive. Hive itself is headless — do NOT try to launch Chrome locally for browser screenshots. For non-browser visuals, fall back to `screen.snapshot`.

  2. **Upload** — call `attachment.upload_start` (reserve a presigned URL), then `curl -X POST --data-binary '@<file>' <upload_url>` with the matching `Content-Type` and your CF-Access headers. The response gives `{id, url}` where `url` is `/chat/attachments/<uuid>` — that's what canvas image nodes accept. Do NOT use `attachment.upload_inline` for anything bigger than ~2 KB; long base64 strings round-trip-corrupt through tool-call envelopes and fail with `data_base64 is not valid base64` (a payload error, not a permissions error — easy to misdiagnose).

  3. **Embed** — call `canvas.create` (or `canvas.patch ["append_child", ...]` on an existing canvas in the execution space) with an `image` node whose `src` is the `/chat/attachments/<uuid>` URL from step 2. Canvas image `src` MUST match `^/chat/attachments/<uuid>$` — external URLs and data URIs are rejected. Group multiple shots in a `stack` of `card`s with markdown captions explaining what's being shown.

  4. **Submit** — call `review_request_create` with `validation_id` set to the `manual_approval` validation (NOT a `validation_evaluate` call — that's only for `test_pass` / `lint_pass`) and `items: [{label, canvas_id}]` pointing at the canvas from step 3. The review items appear inline on the task detail panel with approve/reject buttons. Items can mix `canvas_id` (visual) and `content` (text) — use `content` for tabular evidence, links, test summaries.

  **Tool-name gotcha**: the Suite MCP HTTP endpoint registers tools with dots (`attachment.upload_start`); the Claude Code MCP wrapper exposes them with underscores. If you fall back to raw curl against `/mcp`, use the dot form or you'll get `not in allowed bundles` (which looks like a permissions denial but is actually a name-lookup miss).

  **Do not** post screenshots via `suite_reply_with_media` and call them evidence — those messages don't reliably render in the reviewer's UI and the `manual_approval` gate doesn't watch the chat thread anyway. Evidence flows through `review_request_create`.\
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
    default_branch = resolve_branch(task)
    task_slug = short_task_id(task)

    assigns = %{
      task_title: task.title,
      stage_info: stage_info,
      repo_url: repo_url,
      default_branch: default_branch,
      task_slug: task_slug,
      skills_reference: @skills_reference,
      evidence_workflow_reference: @evidence_workflow_reference
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

    assigns = %{
      task_title: task.title,
      stage_info: stage_info,
      skills_reference: @skills_reference,
      evidence_workflow_reference: @evidence_workflow_reference
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

  def dispatch_prompt(%{status: "deploying"} = task, plan, stage) do
    stage_info = format_stage_info(plan, stage)
    repo_url = project_attr(task, :repo_url, "")
    default_branch = resolve_branch(task)
    task_slug = short_task_id(task)

    # Extract strategy from the task context (preloaded by TaskRouter)
    resolved_strategy = resolve_task_deploy_strategy(task)
    strategy_type = Map.get(resolved_strategy, "type", "manual")
    strategy_config = Map.get(resolved_strategy, "config", %{}) |> inspect()

    assigns = %{
      task_title: task.title,
      stage_info: stage_info,
      repo_url: repo_url,
      default_branch: default_branch,
      task_slug: task_slug,
      deploy_strategy_type: strategy_type,
      deploy_strategy_config: strategy_config,
      skills_reference: @skills_reference
    }

    prompt =
      case PromptTemplates.render_template("dispatch.deploying", assigns) do
        {:ok, rendered} ->
          rendered

        {:error, :not_found} ->
          hardcoded_dispatch_deploying(task, plan, stage, resolved_strategy)
      end

    enrich_deploying_prompt(prompt, task, stage)
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
  @spec heartbeat_prompt(map(), map() | nil, non_neg_integer(), list(), map() | nil) :: String.t()
  def heartbeat_prompt(task, stage, elapsed_seconds, pending_validations, plan \\ nil) do
    # Plan-aware prompt override for planning phase
    task_status = Map.get(task, :status) || Map.get(task, "status")

    if task_status == "planning" && plan do
      planning_heartbeat_prompt(task, plan)
    else
      # When stage is nil, emit an actionable prompt rather than "unknown — unknown".
      # This happens when current_stage_id is stale/nil and no running stage was found.
      if is_nil(stage) do
        nil_stage_heartbeat_prompt(task, plan)
      else
        elapsed_str = format_elapsed(elapsed_seconds)
        stage_name = stage.name
        stage_status = stage.status

        pending_str =
          case pending_validations do
            [] -> "none"
            validations -> Enum.map_join(validations, ", ", & &1.kind)
          end

        plan_status = if plan, do: plan.status, else: "none"
        plan_exists = if plan, do: "true", else: "false"

        assigns = %{
          task_title: task.title,
          stage_name: stage_name,
          stage_status: stage_status,
          elapsed: elapsed_str,
          pending_validations: pending_str,
          plan_status: plan_status,
          plan_exists: plan_exists
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
    end
  end

  # ── Plan-aware heartbeat prompts ─────────────────────────────────────────

  defp planning_heartbeat_prompt(task, plan) do
    case plan.status do
      "pending_review" ->
        """
        Your plan for "#{task.title}" has been submitted and is awaiting human review.

        No action needed — do not create another plan. The current plan (v#{plan.version}) is in pending_review status. Wait for the human reviewer to approve or reject it.

        If you have other context to share about the plan, post it to the execution space as commentary.
        """

      "draft" ->
        """
        A plan draft for "#{task.title}" is in progress (v#{plan.version}, status: draft).

        Continue working on the plan or submit it when ready using plan_submit. Do not create a new plan — finish and submit the existing draft.
        """

      "rejected" ->
        """
        Your plan for "#{task.title}" was rejected (v#{plan.version}).

        Review any feedback in the execution space, then create a revised plan using plan_create. Address the reviewer's concerns in the new version.
        """

      _other ->
        """
        Task: #{task.title} [planning phase]
        Plan status: #{plan.status} (v#{plan.version})

        Review the plan status and take appropriate action. If the plan needs work, continue with it. If it's ready, submit it for review.
        """
    end
  end

  # ── Nil-stage heartbeat prompt (no running stage found) ──────────────

  # Emits an actionable prompt when stage is nil — either because all stages
  # are complete, or because the plan has pending stages that haven't started yet.
  # This replaces the confusing "stage: unknown — unknown" fallback.
  defp nil_stage_heartbeat_prompt(task, plan) do
    stages = if plan, do: plan.stages || [], else: []
    pending_stages = Enum.filter(stages, &(&1.status == "pending"))

    all_complete? =
      stages != [] && Enum.all?(stages, &(&1.status in ["passed", "failed", "skipped"]))

    cond do
      all_complete? ->
        """
        Task "#{task.title}" — all plan stages are complete.

        If the task is not yet marked done, review the completed stages and confirm the work is finished. Use suite_task_complete if everything is in order, or post a summary to the execution space.
        """

      pending_stages != [] ->
        first = hd(pending_stages)

        stage_list =
          pending_stages
          |> Enum.map_join("\n", fn s -> "  - #{s.name} (#{s.id})" end)

        """
        Task "#{task.title}" — no stage is currently running.

        The next pending stage is: #{first.name} (#{first.id})

        Start this stage now using suite_stage_start with stage_id=#{first.id}, then proceed with the implementation described in the stage.

        All pending stages:
        #{stage_list}
        """

      plan == nil ->
        """
        Task "#{task.title}" — no approved plan found.

        Create a plan using plan_create before beginning work.
        """

      true ->
        """
        Task "#{task.title}" — no active stage found.

        Review the plan stages and resume work. If a stage is stuck, use suite_stage_start on the appropriate stage.
        """
    end
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

    #{@evidence_workflow_reference}

    #{@skills_reference}
    """
    |> enrich_in_progress_prompt(task, stage)
  end

  defp hardcoded_dispatch_in_review(task, plan, stage) do
    stage_info = format_stage_info(plan, stage)

    """
    Task is in review — exercise and validate the implementation.

    Task: #{task.title}
    #{stage_info}\
    Your job is experiential review: exercise the feature in a running environment and produce \
    evidence that it works as intended. Tests and lint were already validated during execution — \
    do not re-check them here.

    ## How to review
    - Start a local dev server for the worktree (reference the dev server skill via attached skills if available)
    - For UI changes: navigate to the relevant pages, take screenshots, verify visual correctness and interaction behavior
    - For non-UI changes: exercise the feature via API calls, CLI, or functional tests that demonstrate the behavior
    - Post screenshots, canvas snapshots, or other concrete evidence into the execution space

    ## First-turn rule (CRITICAL)
    - Do NOT spend your first substantive turn re-discovering broad task/plan state if the dispatch already provides \
    `Current task_id`, `Current stage_id`, `validation_id`, and `execution_space_id`.
    - For a `manual_approval` review stage, your first substantive turn should do the real review work and then create \
    the human gate:
      1. exercise the implementation in a running environment,
      2. publish concrete evidence into the execution space,
      3. call `suite_review_request_create` for the provided `validation_id` with labelled checklist items and links to that evidence.
    - Only call `suite_task_get`, `suite_plan_get`, or `suite_validation_list` if an identifier is actually missing or \
    the dispatch context is contradicted by direct evidence.
    - Reach the evidence + review-request step in the same attempt unless a real blocker prevents it.

    ## Review rules
    - Use `suite_validation_evaluate` for deterministic review validations (`passed` / `failed`).
    - Use `suite_review_request_create` for `manual_approval` validations — include labelled checklist items plus \
    screenshots/canvas/evidence links.
    - Do NOT call `stage_complete` before the required review request and evidence have been created.
    - Do NOT self-approve `manual_approval` validations.
    - Do NOT call `task_update` for lifecycle status changes — review outcomes flow through validations and review requests.
    - If the feature does not work as intended, fail the relevant validation with concrete reproduction details so \
    the task can return to `in_progress`.
    - If review passes, let the plan engine advance the task; do not force status changes manually.

    The attention signal that delivered this message includes a `context` field with the full task hierarchy:
    project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.

    #{@evidence_workflow_reference}

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

  defp hardcoded_dispatch_deploying(task, plan, stage, resolved_strategy) do
    stage_info = format_stage_info(plan, stage)
    strategy_type = Map.get(resolved_strategy, "type", "manual")
    strategy_config = Map.get(resolved_strategy, "config", %{})
    repo_url = project_attr(task, :repo_url, "")
    default_branch = resolve_branch(task)
    task_slug = short_task_id(task)

    strategy_instructions =
      deploy_strategy_instructions(
        strategy_type,
        strategy_config,
        repo_url,
        default_branch,
        task_slug
      )

    """
    Task is deploying — execute the deploy stage based on the resolved strategy.

    Task: #{task.title}
    #{stage_info}\
    Deploy strategy: **#{strategy_type}**
    Strategy config: #{inspect(strategy_config)}

    #{strategy_instructions}

    ### Deploy boundaries
    - Do NOT modify code — if CI fails, report a blocker so the task returns to in_progress
    - Do NOT re-run tests or lint locally — CI handles that
    - The branch is already pushed from execution; your job is to get it merged and deployed

    Push evidence using validation_pass as you complete each deploy step.
    Use report_blocker if you are stuck or the deploy fails.

    The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.

    #{@skills_reference}
    """
  end

  defp deploy_strategy_instructions("pr_merge", config, repo_url, default_branch, task_slug) do
    require_ci = Map.get(config, "require_ci_pass", true)
    auto_merge = Map.get(config, "auto_merge", false)

    ci_instruction =
      if require_ci,
        do:
          "3. Wait for CI to pass. Check with `gh run list --branch task/#{task_slug}` and push `test_pass` evidence when green.",
        else: ""

    merge_instruction =
      if auto_merge,
        do: "4. PR will auto-merge when checks pass.",
        else:
          "4. A human must merge the PR. Create a review request via `suite_review_request_create` for the `manual_approval` validation."

    """
    ## PR Merge Deploy Flow
    1. Ensure all changes are committed and pushed to `task/#{task_slug}`.
    2. Open a PR against `#{default_branch}` on #{repo_url} if not already open.
    #{ci_instruction}
    #{merge_instruction}
    """
  end

  defp deploy_strategy_instructions(
         "docker_deploy",
         config,
         _repo_url,
         _default_branch,
         _task_slug
       ) do
    host = Map.get(config, "host", "the target host")
    image = Map.get(config, "image", "the configured image")

    """
    ## Docker Deploy Flow
    1. SSH to #{host} and pull the latest image (#{image}).
    2. Run `docker compose up -d` (or equivalent) to deploy.
    3. Run health checks to verify the service is up and healthy.
    4. Push `test_pass` evidence with deploy output and health check results.
    5. Create a review request via `suite_review_request_create` for the `manual_approval` validation confirming the deploy is healthy.
    """
  end

  defp deploy_strategy_instructions(
         "skill_driven",
         _config,
         _repo_url,
         _default_branch,
         _task_slug
       ) do
    """
    ## Skill-Driven Deploy
    1. Execute the attached skill's deploy procedure.
    2. Follow the skill's instructions for deployment steps and verification.
    3. Create a review request via `suite_review_request_create` for the `manual_approval` validation with evidence of successful execution.
    """
  end

  defp deploy_strategy_instructions("manual", _config, _repo_url, _default_branch, _task_slug) do
    """
    ## Manual Deploy
    1. The deploy must be performed manually (by a human or following manual steps).
    2. Create a review request via `suite_review_request_create` for the `manual_approval` validation describing what needs to be deployed and how.
    3. Wait for human confirmation.
    """
  end

  defp deploy_strategy_instructions(_type, _config, _repo_url, _default_branch, _task_slug) do
    """
    ## Deploy
    Execute the deployment according to the project's deploy configuration.
    Push validation evidence as you complete each step.
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

  # ── Enrichment pipeline ─────────────────────────────────────────────────
  #
  # Each phase has an enrichment function that injects a phase-specific
  # contract block (with validation IDs, tool instructions, and blocker info)
  # into the rendered prompt — whether it came from DB or hardcoded fallback.
  #
  # Phase → Contract → Concern
  # in_progress → execution_contract → code, tests, commit, push (no PR)
  # in_review   → review_contract   → exercise feature, screenshots, evidence
  # deploying   → deploy_contract   → PR, CI, merge (no code changes)
  # heartbeat   → heartbeat_contract → pending validations reminder

  defp enrich_in_progress_prompt(prompt, task, stage) do
    prompt
    |> maybe_strip_git_workflow(task)
    |> insert_before_context(execution_contract(task, stage))
    |> maybe_insert_git_workflow(task)
  end

  defp enrich_in_review_prompt(prompt, task, stage) do
    prompt
    |> insert_before_context(review_contract(task, stage))
  end

  defp enrich_deploying_prompt(prompt, task, stage) do
    prompt
    |> insert_before_context(deploy_contract(task, stage))
  end

  defp resolve_task_deploy_strategy(task) do
    # The task should be preloaded with project by TaskRouter/ContextAssembler.
    # If it has the deploy_strategy field, use it; otherwise fall back through
    # the Tasks module which handles preloading (for real %Task{} structs).
    strategy = Map.get(task, :deploy_strategy) || Map.get(task, "deploy_strategy")

    cond do
      is_map(strategy) and map_size(strategy) > 0 ->
        strategy

      match?(%Platform.Tasks.Task{}, task) ->
        Platform.Tasks.resolve_deploy_strategy(task)

      true ->
        # Plain map (e.g. in tests) — check project default or fall back to manual
        project = Map.get(task, :project) || Map.get(task, "project") || %{}

        deploy_config =
          Map.get(project, :deploy_config) || Map.get(project, "deploy_config") || %{}

        case Map.get(deploy_config, "default_strategy") do
          %{} = s when map_size(s) > 0 -> s
          _ -> %{"type" => "manual"}
        end
    end
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

  defp execution_contract(_task, nil), do: ""

  defp execution_contract(task, stage) do
    stage_id = contract_id(stage, :id)
    task_id = contract_id(task, :id)
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
    #{contract_target_lines(task_id, stage_id)}
    #{validation_lines}
    #{report_blocker_instruction(task_id, stage_id)}
    """
  end

  defp review_contract(_task, nil), do: ""

  defp review_contract(task, stage) do
    stage_id = contract_id(stage, :id)
    task_id = contract_id(task, :id)
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
    #{contract_target_lines(task_id, stage_id)}
    #{validation_lines}
    - Do NOT call `task_update` for lifecycle status changes. Review outcomes flow through validations and review requests.
    - If review evidence shows the feature is not good enough, fail the relevant validation so the task can return to `in_progress`.
    """
  end

  defp deploy_contract(_task, nil), do: ""

  defp deploy_contract(task, stage) do
    stage_id = contract_id(stage, :id)
    task_id = contract_id(task, :id)
    validations = Map.get(stage, :validations) || Map.get(stage, "validations") || []

    validation_lines =
      case validations do
        [] ->
          "- This deploy stage has no validations. Once the deploy is complete, call `stage_complete` with `stage_id=#{stage_id}`."

        items ->
          Enum.map_join(items, "\n", fn validation ->
            kind = Map.get(validation, :kind) || Map.get(validation, "kind") || "validation"
            id = Map.get(validation, :id) || Map.get(validation, "id") || "<missing-id>"

            case kind do
              "manual_approval" ->
                "- `manual_approval` → validation_id=`#{id}` (create a `suite_review_request_create` with the PR URL and CI status as evidence; do NOT self-approve — a human must merge)"

              _ ->
                "- `#{kind}` → validation_id=`#{id}` (use `validation_pass` when the check passes, then call `stage_complete` with `stage_id=#{stage_id}` once all required validations are passed)"
            end
          end)
      end

    """

    ## Deploy Stage Contract
    #{contract_target_lines(task_id, stage_id)}
    #{validation_lines}
    #{report_blocker_instruction(task_id, stage_id, "If CI fails or the deploy breaks")}
    - do NOT attempt code fixes during deploy.
    """
  end

  defp heartbeat_contract(_task, nil, _pending_validations), do: ""

  defp heartbeat_contract(task, stage, pending_validations) do
    stage_id = contract_id(stage, :id)
    task_id = contract_id(task, :id)

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
    #{contract_target_lines(task_id, stage_id)}
    #{pending_lines}
    #{report_blocker_instruction(task_id, stage_id, "Use `report_blocker`")}
    """
  end

  defp contract_id(entity, key) when is_map(entity) do
    entity
    |> Map.get(key)
    |> Kernel.||(Map.get(entity, to_string(key)))
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp contract_id(_entity, _key), do: nil

  defp contract_target_lines(task_id, stage_id) do
    [
      contract_target_line("task_id", task_id),
      contract_target_line("stage_id", stage_id)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp contract_target_line(_label, nil), do: nil
  defp contract_target_line(label, value), do: "Current #{label}: `#{value}`"

  defp report_blocker_instruction(task_id, stage_id, prefix \\ "Use `report_blocker`") do
    case {task_id, stage_id} do
      {task_id, stage_id} when is_binary(task_id) and is_binary(stage_id) ->
        "- #{prefix} with `task_id=#{task_id}` and `stage_id=#{stage_id}` if you cannot make forward progress."

      {nil, stage_id} when is_binary(stage_id) ->
        "- #{prefix} with the task_id from the attention context and `stage_id=#{stage_id}` if you cannot make forward progress."

      _ ->
        "- #{prefix} with the current task and stage IDs from the attention context if you cannot make forward progress."
    end
  end

  defp git_workflow_section(task) do
    repo_url = project_attr(task, :repo_url, "")
    default_branch = resolve_branch(task)
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
       - Do NOT open a PR yet — PR opening happens in the deploy phase
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

  @doc """
  Resolve the effective branch for a task by walking epic → project.

  Returns `epic.target_branch || project.default_branch || "main"`.
  """
  def resolve_branch(task) do
    epic = Map.get(task, :epic) || Map.get(task, "epic")
    epic_branch = epic && (Map.get(epic, :target_branch) || Map.get(epic, "target_branch"))

    if epic_branch && epic_branch != "" do
      epic_branch
    else
      project_attr(task, :default_branch, "main")
    end
  end

  defp short_task_id(task) do
    task
    |> Map.get(:id, Map.get(task, "id", "task"))
    |> to_string()
    |> String.split("-")
    |> List.first()
  end

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
