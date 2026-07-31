defmodule Platform.Orchestration.HeartbeatScheduler do
  @moduledoc """
  Stage-aware prompt generation for `TaskRouter`.

  Provides pure functions for composing the two dispatch payload shapes the
  router sends into a runtime, plus legacy cadence/threshold config the
  polling scheduler used to consume (retained for the deploy_failure
  regression tests; slated for removal in the stage 6 ADR cleanup pass).

  ## Two payload shapes (task 019f640d stage 4)

  * `dispatch_prompt/4` — **FULL context** on state transitions. Emitted when
    the task moves to `in_progress`, `in_review`, or `deploying`, when a new
    stage transitions to `running`, or when a failed branch bounces back.
    Composes the task-status-specific dispatch body plus skills_reference,
    evidence_workflow_reference, git workflow, and a per-stage execution /
    review / deploy contract. This stays fat by design — the initial dispatch
    is the runtime's one shot to load org conventions, evidence workflow, and
    the exact validation ids to push.

  * `nudge_prompt/2` — **SHORT form** on safety-net / no-ack events only.
    Emitted by the router's `fire_no_ack_alert/2` and `fire_safety_net_alert/2`
    paths (stage 3 wiring in `arm_liveness_timers/3` — see `task_router.ex`).
    Target output <500 tokens (~<2000 chars): a two-line preamble plus the
    "## Completion Reminder" contract listing pending validation IDs and the
    action fork (ack / validation_pass / report_blocker). No skills_reference,
    no evidence_workflow_reference, no task description, no org preamble.

  The old `heartbeat_prompt/5` composed the fat payload on every tick of the
  polling scheduler; that scheduler is gone (stage 3), and so is the function.
  The `"heartbeat"` DB template slug is retained as DEPRECATED for one more
  release so any migration reader isn't surprised — stage 6's ADR cleanup
  pass removes it.

  ## Legacy cadence table (ADR 0025 — retired)

  Retained only so `deploy_failure` cadence-config tests keep passing until
  the stage 6 sweep drops the accessors entirely. No production caller reads
  these values — the event-driven `LeaseManager` timeouts govern liveness.

  | Stage type        | Heartbeat interval | Stall threshold | Escalation after    |
  |-------------------|--------------------|-----------------|---------------------|
  | planning          | 15 min             | 30 min          | 2 missed heartbeats |
  | coding            | 10 min             | 25 min          | 2 missed heartbeats |
  | ci_check          | 5 min              | 15 min          | 3 missed heartbeats |
  | review            | 20 min             | 60 min          | 1 missed heartbeat  |
  | manual_approval   | n/a                | n/a             | n/a (human gate)    |
  """

  alias Platform.Orchestration.DispatchPhase
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Orchestration.ProviderGuidance
  alias Platform.Tasks.ReviewRequest
  alias Platform.Tasks.Stage

  require Logger

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
  ## Skill discovery — do this BEFORE you start executing

  Skills encode org conventions you may not have; load the right one before improvising. \
  Discovery is an active step, not a passive read — the payload bundler does NOT always pre-attach the skill you need:

  1. Derive this task's domain from its title and description (e.g. "task stack", "canvas", "migration", "LiveView").
  2. Call the `skill_list` MCP tool yourself and scan the returned skills for one plausibly matching that domain \
  (a task mentioning "task stack" -> the `task-stack-creation` skill; "canvas" -> a `canvas-*` skill). \
  Do NOT assume the right skill was pre-attached to the payload.
  3. If a skill matches, call the `skill_get` MCP tool to fetch its full content and follow it as authoritative.

  Discovery happens by calling `skill_list` / `skill_get` yourself — do NOT treat "the `skills` key" or an attached \
  skills object as your discovery mechanism, because you receive rendered text, not an introspectable object.

  If the dispatch context did attach skill content inline, still treat that bundled content as authoritative for this task \
  before trying to rediscover skills from disk. \
  Read and follow any relevant bundled skills — they describe conventions, repo layout, deploy targets, and how to delegate work. \
  Only fall back to filesystem skill lookup if the payload clearly references a path without including the needed content.\
  """

  # Ack-first preamble prepended to every hardcoded dispatch fallback
  # (task 019f640d stage 5). Mirrors `PromptTemplates.task_ack_preamble/0`
  # in shape — the DB template does the mustache substitution; the
  # hardcoded fallback interpolates via Elixir `#{...}` so both routes
  # ship the same guidance regardless of whether the DB template row
  # exists yet.
  @task_ack_preamble_template """
  **Your first tool call must be `task_ack(task_id="__TASK_ID__", stage_id="__STAGE_ID__", subagent_id="__SUBAGENT_ID__")`.**

  Spawn the subagent FIRST, then include its returned agent id in the ack. Empty or missing subagent_id will fail validation — this ordering makes it structurally impossible to ack a dispatch you never spawned a subagent for. Without a successful ack the router will fire a no-ack alert in 5 minutes.
  """

  @evidence_workflow_reference """
  ## Submitting evidence for a `manual_approval` validation

  Visual evidence (screenshots, rendered UI, diagrams) is the bottleneck where most agents stall. The path that actually works is a four-tool chain. Use it; don't improvise.

  1. **Capture** — drive the local headless Chrome via CDP at `127.0.0.1:9222`. Use the `cdp_capture.sh` helper bundled with the dispatch (or invoke directly): `~/sources/core/apps/platform/priv/scripts/cdp_capture.sh <url> <output.jpg> [--width 375 --height 812]`. The script connects to Chrome's CDP, navigates, waits for network idle, optionally applies an `Emulation.setDeviceMetricsOverride` for mobile viewports, and writes a JPG via `Page.captureScreenshot`. The connectivity check is `curl -s http://127.0.0.1:9222/json/version` returning JSON. For non-browser visuals, fall back to `screen.snapshot`.

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
  Decide whether heartbeats should be suppressed for `stage` because every
  pending validation on it is a `manual_approval` already linked to an open
  review request awaiting a human.

  Pure 2-arity predicate — takes already-loaded data and performs no DB calls,
  so it can be unit-tested cheaply and called from the periodic loop without
  per-tick query overhead. Stage 2 of task 019e00cb wires this into the
  `TaskRouter` heartbeat path; this stage adds the predicate only.

  Returns `true` iff ALL of the following hold:
    * `stage` has at least one pending validation,
    * every pending validation has `kind: "manual_approval"`,
    * every such manual_approval validation has at least one matching open
      `review_request` in `pending_review_requests` whose `validation_id`
      points back at it.

  Returns `false` when any of the following holds (the regular advance /
  heartbeat path keeps emitting for visibility):
    * the stage has no pending validations (the regular advance path handles
      empty-pending — this predicate explicitly opts out so that callers do
      not accidentally suppress on completed stages),
    * any pending validation is non-`manual_approval` (mixed kinds mean the
      agent still has work to do — keep nudging it),
    * any manual_approval validation lacks a linked open review request in
      the supplied list (broken or missing linkage — guardrail: keep
      heartbeats alive for visibility rather than silently stalling).

  ## Inputs

    * `stage` — a `Stage.t()` (or compatible map) whose `:validations`
      association is already loaded. Both atom-keyed structs and string-keyed
      maps are accepted, mirroring the rest of this module's helpers.
    * `pending_review_requests` — a list of `ReviewRequest.t()` (or
      compatible maps) representing the OPEN review requests for the task.
      Callers are responsible for filtering by `status == "pending"` before
      calling — this predicate trusts the supplied list.
  """
  @spec heartbeat_suppressible?(Stage.t() | map(), [ReviewRequest.t() | map()]) :: boolean()
  def heartbeat_suppressible?(stage, pending_review_requests)
      when is_list(pending_review_requests) do
    pending = pending_validations_for_stage(stage)

    cond do
      pending == [] ->
        false

      not Enum.all?(pending, &manual_approval_validation?/1) ->
        false

      true ->
        Enum.all?(pending, &has_matching_open_review_request?(&1, pending_review_requests))
    end
  end

  def heartbeat_suppressible?(_stage, _pending_review_requests), do: false

  defp manual_approval_validation?(validation) do
    kind = Map.get(validation, :kind) || Map.get(validation, "kind")
    kind == "manual_approval"
  end

  defp has_matching_open_review_request?(validation, review_requests) do
    validation_id = Map.get(validation, :id) || Map.get(validation, "id")

    validation_id != nil and
      Enum.any?(review_requests, fn rr ->
        (Map.get(rr, :validation_id) || Map.get(rr, "validation_id")) == validation_id
      end)
  end

  @doc """
  Generate the **full-context** initial dispatch prompt for a state transition.

  This is the FAT payload — it carries skills_reference, evidence_workflow_reference,
  git workflow instructions, and a per-stage execution / review / deploy contract
  so the runtime's fresh subagent lands with everything it needs on turn one.
  Emitted on:

  * approved plan → `in_progress` transition (first dispatch after plan approval)
  * `stage_transitioned running → passed` (next-stage dispatch)
  * failure-branch bounce (`stage.status == "failed"` re-dispatch — deploy fail
    or review fail routing the task back to `in_progress`)

  For the SHORT payload emitted on safety-net / no-ack events, see
  `nudge_prompt/2`. The router routes accordingly (task 019f640d stage 3
  wiring in `arm_liveness_timers/3`).

  Tries the DB prompt template first via `PromptTemplates.render_template/2`
  and falls back to the hardcoded module-local prompt if the template isn't
  seeded. The slug is chosen by `Platform.Orchestration.DispatchPhase`:

  * planning (no stage) — instruct agent to create and submit a plan
  * in_progress — execute current stage with evidence
  * in_review / review_e2e — run validations, do not self-approve gates
  * deploying — execute the resolved deploy strategy
  * fallback — generic assignment prompt

  ## Selection is keyed on the STAGE, not on `task.status` (task 019fa469)

  This used to be five function heads pattern-matching `task.status`.
  `task.status` lags a full dispatch cycle behind the plan engine: after a
  previous stage's `manual_approval` gate is approved the task row still reads
  `"in_review"` while the CURRENT stage is `running` with only `test_pass` /
  `lint_pass` pending, so the executor received the reviewer template (observed
  3x on task `019f9b29-9c47-7b66-b863-641b50d09eff`). The same staleness sent a
  `pr_merged`-only DEPLOY stage the reviewer template on task `019fa230`.

  `DispatchPhase.resolve/3` now picks the slug from the stage's own contract
  and only consults `task.status` when a stage carries no pending validations
  at all. Every per-slug assigns body below is unchanged from the five heads —
  this seam changed SELECTION only, no assign values moved.
  """
  @spec dispatch_prompt(map(), map() | nil, map() | nil, keyword()) :: String.t()
  def dispatch_prompt(task, plan, stage, opts \\ []) do
    phase = DispatchPhase.resolve(task, plan, stage)

    # Exhaustive over `DispatchPhase`'s closed phase set — deliberately no
    # catch-all, so a new phase fails loudly here instead of silently landing
    # on a generic prompt.
    case phase.slug do
      "dispatch.planning" -> planning_prompt(task, opts)
      "dispatch.in_progress" -> in_progress_prompt(task, plan, stage, opts)
      "dispatch.in_review" -> review_prompt(phase.slug, task, plan, stage, opts)
      "dispatch.review_e2e" -> review_prompt(phase.slug, task, plan, stage, opts)
      "dispatch.deploying" -> deploying_prompt(task, plan, stage)
      "dispatch.fallback" -> fallback_prompt(task, plan, stage)
    end
  end

  defp planning_prompt(task, opts) do
    provider_guidance = resolve_provider_guidance(opts)
    previous_rejection_reason = resolve_previous_rejection_reason(opts)
    # Stack v2 stage 5: in-stack `blocks`-kind dep parents contribute their
    # approved plans to the planner's context via `ContextAssembler`. Solo
    # tasks send `[]` and the section renders as empty string.
    parent_plans = Keyword.get(opts, :parent_plans, [])

    assigns = %{
      # NO `stage_id` and NO ack instruction on this branch (task 019fa469
      # stage 5). The comment that used to sit here said the `task_ack` MCP
      # tool "tolerates a missing stage_id and resolves via
      # `current_running_stage/1` when it can" — it does not.
      # `ToolSurface.resolve_ack_stage_id/2` returns
      # `{:error, :no_running_stage}` when the supplied stage_id is empty and
      # no plan stage is `running`, which is exactly the planning shape, and
      # the runtime gets `has no running stage — cannot ack without a
      # stage_id`. Nor is anything lost by not acking:
      # `TaskRouter.arm_liveness_timers/3`'s
      # `arm_liveness_timers(_task_id, nil, _stage_kind), do: :ok` clause means
      # a stage-less dispatch arms no timers and records no lease, so there is
      # no alarm to satisfy. `task_id` stays — the body still names the task.
      task_id: contract_id(task, :id) || "",
      task_title: task.title,
      task_description: task.description || "No description provided.",
      task_priority: task.priority,
      provider_specific_guidance: provider_guidance,
      previous_rejection_reason: render_previous_rejection_section(previous_rejection_reason),
      upstream_plans_section: render_upstream_plans_section(parent_plans),
      skills_reference: @skills_reference,
      # federation_preamble — canonical Claude Code guidance block
      # (task 019f5e2a stage 2). Consumed by dispatch.* templates via
      # `{{federation_preamble}}` after the stage 3 retrofit; the
      # placeholder resolves harmlessly on any template that doesn't
      # reference it, so this assign is safe on every branch.
      federation_preamble: PromptTemplates.federation_preamble()
    }

    case PromptTemplates.render_template("dispatch.planning", assigns) do
      {:ok, rendered} ->
        rendered

      {:error, :not_found} ->
        hardcoded_dispatch_planning(
          task,
          provider_guidance,
          previous_rejection_reason,
          parent_plans
        )
    end
  end

  defp in_progress_prompt(task, plan, stage, opts) do
    stage_info = format_stage_info(plan, stage)
    provider_guidance = resolve_provider_guidance(opts)

    assigns = %{
      # task_ack preamble assigns (task 019f640d stage 5).
      task_id: contract_id(task, :id) || "",
      stage_id: contract_id(stage || %{}, :id) || "",
      task_title: task.title,
      stage_info: stage_info,
      # Pre-rendered Git Workflow block — single source of truth shared with
      # the hardcoded fallback's enrichment path (git_workflow_section/1).
      # Stack-aware: full-UUID worktree/branch + stack membership block for
      # stack members, legacy 8-char-slug section for non-stack tasks.
      git_workflow_block: git_workflow_section(task),
      # Reserved Ecto migration timestamp for THIS stage (task 019f7b7e
      # stage 3). Empty string for solo tasks and for stack members whose
      # current stage holds no reservation.
      migration_slot_section: render_migration_slot_section(task, stage),
      provider_specific_guidance: provider_guidance,
      skills_reference: @skills_reference,
      evidence_workflow_reference: @evidence_workflow_reference,
      # federation_preamble — canonical Claude Code guidance block
      # (task 019f5e2a stage 2). See planning branch above for rationale.
      federation_preamble: PromptTemplates.federation_preamble()
    }

    prompt =
      case PromptTemplates.render_template("dispatch.in_progress", assigns) do
        {:ok, rendered} ->
          rendered

        {:error, :not_found} ->
          hardcoded_dispatch_in_progress(task, plan, stage, provider_guidance)
      end

    enrich_in_progress_prompt(prompt, task, stage)
  end

  # `dispatch.in_review` and `dispatch.review_e2e` share one assigns body — they
  # always did, as one `%{status: "in_review"}` head. `template_slug` now comes
  # from `DispatchPhase`; `select_review_template/2` is still called because it
  # owns the `e2e_review_assigns/2` build, and its slug agrees by construction
  # (it delegates the same classification to `DispatchPhase.phase_for_pending/1`).
  defp review_prompt(template_slug, task, plan, stage, opts) do
    stage_info = format_stage_info(plan, stage)
    provider_guidance = resolve_provider_guidance(opts)
    pending = pending_validations_for_stage(stage)

    {_delegated_slug, extra_assigns} = select_review_template(pending, task, opts)

    assigns =
      %{
        # task_ack preamble assigns (task 019f640d stage 5).
        task_id: contract_id(task, :id) || "",
        stage_id: contract_id(stage || %{}, :id) || "",
        task_title: task.title,
        stage_info: stage_info,
        provider_specific_guidance: provider_guidance,
        skills_reference: @skills_reference,
        evidence_workflow_reference: @evidence_workflow_reference,
        # federation_preamble — canonical Claude Code guidance block
        # (task 019f5e2a stage 2). Also inherited into the e2e review
        # branch via Map.merge below.
        federation_preamble: PromptTemplates.federation_preamble()
      }
      |> Map.merge(extra_assigns)

    prompt =
      case PromptTemplates.render_template(template_slug, assigns) do
        {:ok, rendered} ->
          rendered

        {:error, :not_found} ->
          # Fallback paths intentionally diverge by template kind: e2e_behavior
          # falls back to a hardcoded behavioral prompt; manual_approval / other
          # kinds fall back to the existing in_review prompt.
          case template_slug do
            "dispatch.review_e2e" ->
              hardcoded_dispatch_review_e2e(task, assigns)

            _ ->
              hardcoded_dispatch_in_review(task, plan, stage, provider_guidance)
          end
      end

    enrich_in_review_prompt(prompt, task, stage)
  end

  defp deploying_prompt(task, plan, stage) do
    stage_info = format_stage_info(plan, stage)
    repos = resolve_task_deploy_repos(task)
    # `repo_url` KEEPS its name and its place in the template's variable list
    # (task 019fa63a stage 5) but stops meaning `project.repo_url` — it is now
    # the resolved PRIMARY entry. Retargeting the singular assign instead of
    # deleting it is what makes this backwards compatible: a template row an
    # operator customized to interpolate `{{repo_url}}` keeps rendering, and
    # renders the RIGHT repo. Deleting the assign would have blanked those rows
    # silently, because `PromptTemplates.interpolate/2` resolves an unknown
    # placeholder to `""`.
    repo_url = primary_repo_url(repos)
    default_branch = resolve_branch(task)
    # member_slug/1 — full UUID for a stack member so the deploy-phase branch
    # reference matches the per-member branch created at in_progress; legacy
    # 8-char slug for a non-stack task (output unchanged).
    task_slug = member_slug(task)

    # Extract strategy from the task context (preloaded by TaskRouter)
    resolved_strategy = resolve_task_deploy_strategy(task)
    strategy_type = Map.get(resolved_strategy, "type", "manual")
    strategy_config = Map.get(resolved_strategy, "config", %{}) |> inspect()

    assigns = %{
      # task_ack preamble assigns (task 019f640d stage 5).
      task_id: contract_id(task, :id) || "",
      stage_id: contract_id(stage || %{}, :id) || "",
      task_title: task.title,
      stage_info: stage_info,
      repo_url: repo_url,
      default_branch: default_branch,
      task_slug: task_slug,
      # The PLURAL rendering, added alongside the singular assigns rather than
      # replacing them. Carries the per-repo PR/CI/merge sequence — which is
      # where the "one green gate means done" misread lives. Same function the
      # hardcoded fallback calls, so the two dispatch paths cannot drift.
      deploy_strategy_instructions:
        deploy_strategy_instructions(
          strategy_type,
          Map.get(resolved_strategy, "config", %{}),
          repos,
          default_branch,
          task_slug
        ),
      deploy_strategy_type: strategy_type,
      deploy_strategy_config: strategy_config,
      skills_reference: @skills_reference,
      # federation_preamble — canonical Claude Code guidance block
      # (task 019f5e2a stage 2).
      federation_preamble: PromptTemplates.federation_preamble()
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

  defp fallback_prompt(task, plan, stage) do
    stage_info = format_stage_info(plan, stage)

    assigns = %{
      task_title: task.title,
      task_description: task.description || "No description provided.",
      task_status: task.status,
      task_priority: task.priority,
      stage_info: stage_info,
      skills_reference: @skills_reference,
      # federation_preamble — canonical Claude Code guidance block
      # (task 019f5e2a stage 2).
      federation_preamble: PromptTemplates.federation_preamble()
    }

    case PromptTemplates.render_template("dispatch.fallback", assigns) do
      {:ok, rendered} ->
        rendered

      {:error, :not_found} ->
        hardcoded_dispatch_fallback(task, plan, stage)
    end
  end

  defp resolve_provider_guidance(opts) when is_list(opts) do
    agent = Keyword.get(opts, :agent)
    runtime = Keyword.get(opts, :runtime)
    ProviderGuidance.for_agent(agent, runtime)
  end

  # Pull the previous-rejection reason out of dispatch opts. Used by the
  # reopen-with-feedback flow (task 019dfad1) — the planner's redispatch
  # surfaces what didn't work last time.
  defp resolve_previous_rejection_reason(opts) when is_list(opts) do
    case Keyword.get(opts, :previous_rejection_reason) do
      reason when is_binary(reason) ->
        trimmed = String.trim(reason)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  # Render the "## Previous attempt — what didn't work" section for the
  # planning template. Pre-renders to a string at the assigns layer so the
  # template body can rely on simple `{{previous_rejection_reason}}`
  # substitution without conditional logic in the mustache layer.
  defp render_previous_rejection_section(nil), do: ""
  defp render_previous_rejection_section(""), do: ""

  defp render_previous_rejection_section(reason) when is_binary(reason) do
    """
    ## Previous attempt — what didn't work

    #{reason}

    Design v2 to address that.
    """
  end

  # Render the "## Upstream plans (approved by dep parents)" section for the
  # planning template. Same pre-render-to-string pattern as
  # `render_previous_rejection_section/1` — the DB template layer only does
  # `{{variable}}` substitution, so conditional loops live here, not in
  # the mustache body.
  #
  # `parent_plans` comes from `ContextAssembler` and only appears for
  # stack members; for solo tasks TaskRouter passes `[]` (default in the
  # planning dispatch clause) which renders as an empty string — the
  # template stays backwards-compatible when the section is absent.
  defp render_upstream_plans_section([]), do: ""
  defp render_upstream_plans_section(nil), do: ""

  defp render_upstream_plans_section(parent_plans) when is_list(parent_plans) do
    body =
      parent_plans
      |> Enum.map(&render_parent_plan_block/1)
      |> Enum.join("\n")

    """
    ## Upstream plans (approved by dep parents)

    Each in-stack `blocks`-kind parent's approved plan is included below. Align your design with the upstream approach — extend it, don't reinvent it.

    #{body}
    """
  end

  defp render_upstream_plans_section(_), do: ""

  # Task 019f7b7e stage 3 — surface the migration slot reserved at plan
  # approval (stage 2) so the executor writes the reserved filename instead
  # of minting its own with `mix ecto.gen.migration`. Two concurrent stack
  # members both producing `20260717000000_*.exs` is the incident this
  # closes: Ecto silently skips the second file, so CI drifts from prod.
  #
  # Gated on `stack_membership/1`, so a solo task that somehow carries a
  # stray `reserved_migration_slots` key renders nothing — the reservation
  # mechanism is strictly a stack concern.
  #
  # Entries are filtered to the stage being dispatched. A plan with
  # migrations in stages 2 and 4 shows stage 2's timestamp only while
  # stage 2 runs; stage 4's dispatch later shows its own. Anything that
  # doesn't match renders "" so the template stays backwards-compatible.
  defp render_migration_slot_section(task, stage) do
    with %{} <- stack_membership(task),
         stage_id when is_binary(stage_id) <- contract_id(stage || %{}, :id),
         [timestamp | _] <- reserved_slot_timestamps(task, stage_id) do
      migration_slot_block(timestamp)
    else
      _ -> ""
    end
  end

  defp reserved_slot_timestamps(task, stage_id) do
    metadata = Map.get(task, :metadata) || Map.get(task, "metadata")

    case metadata do
      %{} = metadata ->
        metadata
        |> Map.get("reserved_migration_slots", [])
        |> case do
          entries when is_list(entries) -> entries
          _ -> []
        end
        |> Enum.filter(&(is_map(&1) and Map.get(&1, "stage_id") == stage_id))
        |> Enum.map(&Map.get(&1, "timestamp"))
        |> Enum.filter(&(is_binary(&1) and &1 != ""))

      _ ->
        []
    end
  end

  defp migration_slot_block(timestamp) do
    """

    ## Reserved migration timestamp

    This task is a member of a stack. To prevent Ecto migration filename
    collisions across concurrent siblings, the following timestamp has
    been reserved for this stage:

    `#{timestamp}`

    Use it verbatim when creating your migration file. If `mix
    ecto.gen.migration <name>` produces a different timestamp, RENAME
    the file to `#{timestamp}_<name>.exs` before commit. Do NOT allocate
    your own timestamp — collisions with other stack members will silently
    corrupt the CI DB.
    """
  end

  defp render_parent_plan_block(%{task_id: task_id, task_title: task_title, plan: plan}) do
    stages = Map.get(plan, :stages, []) || []
    version = Map.get(plan, :version, "?")

    stages_body =
      stages
      |> Enum.map(fn stage ->
        pos = Map.get(stage, :position, "?")
        name = Map.get(stage, :name) || ""
        desc = Map.get(stage, :description) || ""
        "- Stage #{pos}: #{name} — #{desc}"
      end)
      |> Enum.join("\n")

    """

    ### Parent — #{task_title} (#{task_id})
    Plan v#{version}:
    #{stages_body}
    """
  end

  defp render_parent_plan_block(_), do: ""

  @doc """
  Generate the **short-form** nudge prompt sent on safety-net / no-ack events.

  Payload discipline: <500 tokens (~<2000 chars). No skills_reference, no
  evidence_workflow_reference, no task description, no org preamble. Just a
  two-line preamble telling the runtime it has fallen silent, plus the
  "## Completion Reminder" contract that names the current `task_id`,
  `stage_id`, pending validation IDs, and the ack / validation_pass /
  report_blocker fork.

  Callers: `TaskRouter.fire_no_ack_alert/2` and
  `TaskRouter.fire_safety_net_alert/2` (event-driven liveness path arm in
  `arm_liveness_timers/3`). Contrast with `dispatch_prompt/4` which composes
  the FULL context on state transitions.

  Tries the DB template `"nudge"` via `PromptTemplates.render_template/2` and
  falls back to a hardcoded local composition if the template isn't seeded.

  Optional keyword: `:elapsed_ms` — router-supplied elapsed since dispatch
  (from `LeaseManager.get/1`). If absent, derives elapsed from
  `stage.started_at` when set; otherwise omits the elapsed marker.
  """
  @spec nudge_prompt(map(), map() | nil) :: String.t()
  @spec nudge_prompt(map(), map() | nil, keyword()) :: String.t()
  def nudge_prompt(task, stage, opts \\ []) do
    task_id = contract_id(task, :id) || "unknown"
    stage_id = contract_id(stage || %{}, :id) || "unknown"
    elapsed_str = nudge_elapsed_str(stage, opts)
    pending_ids = pending_validation_ids(stage)

    assigns = %{
      task_id: task_id,
      stage_id: stage_id,
      elapsed_minutes: elapsed_str,
      pending_validation_ids:
        if(pending_ids == "",
          do: "(none — call stage_complete if work is done)",
          else: pending_ids
        )
    }

    case PromptTemplates.render_template("nudge", assigns) do
      {:ok, rendered} -> rendered
      {:error, :not_found} -> hardcoded_nudge(task, stage, elapsed_str)
    end
  end

  @doc """
  Comma-separated list of pending validation UUIDs on `stage`. Empty string
  when the stage has no pending validations (or is nil). Used by
  `nudge_prompt/2` — the nudge template does not enumerate per-validation
  instructions, it just lists IDs.
  """
  @spec pending_validation_ids(map() | nil) :: String.t()
  def pending_validation_ids(nil), do: ""

  def pending_validation_ids(stage) do
    stage
    |> pending_validations_for_stage()
    |> Enum.map(fn v -> Map.get(v, :id) || Map.get(v, "id") end)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(", ")
  end

  # Derive the elapsed-minutes string for the nudge preamble. Prefer an
  # explicit `:elapsed_ms` opt (LeaseManager-authoritative when the router
  # passes it), fall back to `stage.started_at`, return `"?"` when neither
  # is available so the preamble still renders cleanly.
  defp nudge_elapsed_str(stage, opts) when is_list(opts) do
    case Keyword.get(opts, :elapsed_ms) do
      ms when is_integer(ms) and ms >= 0 ->
        Integer.to_string(div(ms, 60_000))

      _ ->
        case stage_started_at(stage) do
          %DateTime{} = ts ->
            Integer.to_string(div(DateTime.diff(DateTime.utc_now(), ts, :second), 60))

          _ ->
            "?"
        end
    end
  end

  defp stage_started_at(nil), do: nil

  defp stage_started_at(stage) when is_map(stage) do
    Map.get(stage, :started_at) || Map.get(stage, "started_at")
  end

  # ── Hardcoded fallback prompts ─────────────────────────────────────────

  # Render the ack-first preamble for the hardcoded fallback path with
  # the runtime's actual task_id / stage_id / subagent_id substituted in
  # place of the __TASK_ID__ / __STAGE_ID__ / __SUBAGENT_ID__ placeholders.
  # Callers pass empty strings for stage_id when a stage isn't available
  # yet (planning dispatch) — the tool tolerates a missing stage_id and
  # resolves via current_running_stage.
  #
  # `subagent_id` defaults to the `<unknown — spawn a subagent first>`
  # sentinel (matching the DB template's placeholder guidance): the
  # hardcoded fallback is emitted from the periodic scheduler before any
  # real subagent handle is known to the orchestrator; the readable
  # sentinel tells the receiving agent to spawn its subagent BEFORE
  # attempting the ack (task 019f6c73 stage 3).
  defp render_task_ack_preamble(
         task_id,
         stage_id,
         subagent_id \\ "<unknown — spawn a subagent first>"
       ) do
    @task_ack_preamble_template
    |> String.replace("__TASK_ID__", task_id || "")
    |> String.replace("__STAGE_ID__", stage_id || "")
    |> String.replace("__SUBAGENT_ID__", subagent_id || "")
  end

  # Kept in parity with the DB `dispatch.planning` template so environments
  # without the seeded row (fresh dev DBs before migrations run, or tests
  # that operate on an empty templates table) get the same guidance. The
  # `parent_plans` upstream-plans section is rendered here too — same
  # renderer as the template path — so both routes emit identical output.
  #
  # Parity includes the ABSENCE of the ack preamble (task 019fa469 stage 5).
  # This branch used to call `render_task_ack_preamble(task_id, "")` with an
  # empty stage_id, which produces a first-tool-call instruction that
  # `ToolSurface.resolve_ack_stage_id/2` rejects with `:no_running_stage`.
  # Leaving it here would just relocate the defect to the unseeded
  # environments this fallback exists to serve.
  defp hardcoded_dispatch_planning(
         task,
         provider_guidance \\ "",
         previous_rejection_reason \\ nil,
         parent_plans \\ []
       ) do
    previous_rejection_section = render_previous_rejection_section(previous_rejection_reason)
    upstream_plans_section = render_upstream_plans_section(parent_plans)
    no_ack_notice = PromptTemplates.planning_no_ack_notice()

    """
    #{no_ack_notice}
    You have been assigned a task that requires a plan before any implementation begins.

    Task: #{task.title}
    Description: #{task.description || "No description provided."}
    Priority: #{task.priority}

    #{provider_guidance}

    #{previous_rejection_section}
    #{upstream_plans_section}
    Create a plan using the plan_create tool. The plan will be reviewed by a human before work starts — make it specific enough that they can meaningfully approve or reject it.

    ## Stage scope (planner's responsibility)

    Plan **implementation and validation only**. The system auto-injects the deploy stage when the task transitions to `deploying` status — you do NOT include it. Specifically:

    - **Planner** designs implementation stages (`test_pass` + `lint_pass`, plus `manual_approval` on UI-rendering stages) and the per-task `e2e_behavior` adversarial test plan.
    - **Implementer** executes each implementation stage.
    - **Review agent** runs the `e2e_behavior` cases at review time.
    - **Deployer** (auto-spawned at `deploying`) opens the PR, polls CI, follows the deploy strategy (`pr_merge` / `docker_deploy` / `skill_driven` / `manual`), and bounces the task back to `in_progress` if CI fails.

    Do NOT include a stage like "Deploy via PR merge", "Open PR", "Watch CI", or "Merge". Those are the deployer's job, not the planner's. The system auto-injects the deploy stage from the resolved deploy strategy when it is needed.

    ## Plan structure

    The plan covers implementation AND task-level review. Structure it in two sections:

    **Implementation stages** (run in `in_progress`):
    - Each stage represents a discrete, reviewable unit of work
    - Validations: use `test_pass` and `lint_pass` for code changes
    - `manual_approval` ONLY on stages that visually re-render UI (see "Validation kinds" below)
    - Push the branch when implementation stages are complete — do NOT open a PR (the auto-injected deploy stage handles PR + CI + merge)

    **Task-level review (one or more per task)**:
    - Author 2-5 `e2e_behavior` validations that adversarially test different aspects of the
      feature — happy path, edge cases, regression-prone scenarios. Each is one independently-
      dispositioned test case the review agent will run. The user reviews and approves this
      test plan at plan time. Each carries a structured `evaluation_payload` (`setup` /
      `actions` / `expected` — no `failure_feedback`; the review agent observes and posts
      failures at review time). The plan engine lifts every e2e_behavior validation to a
      single synthetic task-level review stage automatically — do NOT attach them to
      multiple stages or create a separate review stage for them.

    ## Validation kinds

    Per-stage:
    - `test_pass` / `lint_pass` for any stage that touches code.
    - `manual_approval` ONLY on stages that visually re-render UI. UI-touching means the stage
      modifies `.heex` templates, `assets/js/`, `assets/css/`, `app.css`, `compose_input`,
      `chat_live`, `tasks_live.ex`, `_web/live/`, or `_web/components/`. If the description
      doesn't reference any of those, do NOT attach `manual_approval` — overscoped human gates
      kill cycle time. When you reach a `manual_approval` validation in execution, call
      `suite_review_request_create` and post a screenshot into the execution space.

    Task-level:
    - `e2e_behavior` (2-5 per task — adversarial test plan) with `evaluation_payload`:
      - `setup`: how the review agent should prepare the dev environment
      - `actions`: concrete steps to perform against the running feature
      - `expected`: the observable behavior that constitutes success
      - Do NOT include `failure_feedback` — the review agent observes and reports failures at
        review time. Pre-writing them is wrong.

    Example e2e_behavior payloads (dependency-blocker task — two adversarial cases):

    Case A — happy path:
    ```
    {
      "kind": "e2e_behavior",
      "evaluation_payload": {
        "setup": "Create two tasks A and B; mark B as depending on A.",
        "actions": "Open task B in the detail panel; mark A done; refresh.",
        "expected": "Before: B's panel shows A under 'Blocked by' with an unmet badge. After: badge clears within 2s."
      }
    }
    ```

    Case B — regression-prone edge case:
    ```
    {
      "kind": "e2e_behavior",
      "evaluation_payload": {
        "setup": "Create A, B, C; B depends on A and C; A depends on a non-existent UUID.",
        "actions": "Complete only C; refresh B.",
        "expected": "B's 'Blocked by' shows A unmet and C met. B remains blocked. The orphan-dep on A renders with a nil-title fallback rather than crashing."
      }
    }
    ```

    Forbidden:
    - `code_review` is NOT a supported validation kind — do not include it.
    - Pre-writing `failure_feedback` in the evaluation_payload — observed at review time.

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

  defp hardcoded_dispatch_in_progress(task, plan, stage, provider_guidance \\ "") do
    stage_info = format_stage_info(plan, stage)

    ack_preamble =
      render_task_ack_preamble(contract_id(task, :id), contract_id(stage || %{}, :id))

    # Mirrors the `{{migration_slot_section}}` placeholder position in the
    # DB template: after the evidence paragraph, before the Git Workflow
    # block that `enrich_in_progress_prompt/3` appends below. Environments
    # without the seeded template row still get the reservation.
    migration_slot_section = render_migration_slot_section(task, stage)

    """
    #{ack_preamble}
    Plan approved — execute the current stage.

    Task: #{task.title}
    #{stage_info}
    #{provider_guidance}

    Push evidence using validation_pass or stage_complete as you finish each step. \
    Post commentary to the execution space so reviewers can follow along. \
    Use report_blocker if you are stuck.
    #{migration_slot_section}

    The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.
    Start from the concrete stage contract and any attached/bundled skill content in that payload before re-fetching broad task/project context.
    Avoid redundant task/plan lookup churn on the first turn unless an identifier is genuinely missing or the stage contract is ambiguous.

    #{@evidence_workflow_reference}

    #{@skills_reference}
    """
    |> enrich_in_progress_prompt(task, stage)
  end

  defp hardcoded_dispatch_in_review(task, plan, stage, provider_guidance \\ "") do
    stage_info = format_stage_info(plan, stage)

    ack_preamble =
      render_task_ack_preamble(contract_id(task, :id), contract_id(stage || %{}, :id))

    """
    #{ack_preamble}
    Task is in review — exercise and validate the implementation.

    Task: #{task.title}
    #{stage_info}
    #{provider_guidance}

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

  @doc """
  Pick the right review-time template + extra assigns for a list of pending
  validations on an in_review stage.

  Returns `{template_slug, extra_assigns_map}`.

  Policy:
  - If ANY pending validations are `e2e_behavior`, render `dispatch.review_e2e`
    with ALL pending e2e_behavior validations rendered as a JSON array in assigns
    under `pending_e2e_validations_json`. (e2e wins over manual_approval when
    both are pending — agent-driven gate fires first; once every e2e validation
    passes, the manual_approval review can fire on the next dispatch.)
  - Otherwise, render `dispatch.in_review` with no extra assigns (the existing
    UI / manual_approval review path).
  - For an empty list, default to `dispatch.in_review` so the agent still gets
    a sensible prompt during the transient window where validations have all
    been evaluated but the stage hasn't yet auto-advanced.

  ## Relationship to `DispatchPhase` (task 019fa469 stage 2)

  `dispatch_prompt/4` no longer takes its SLUG from here — that now comes from
  `DispatchPhase.resolve/3`, which classifies every phase, not just the two
  review shapes. This function survives because it owns the
  `e2e_review_assigns/3` build, and it delegates its e2e-vs-manual decision to
  `DispatchPhase.phase_for_pending/1` so there is exactly one classifier. A
  second, independently-drifting classifier is how the original defect got in.

  ### Documented divergence on the empty list

  `select_review_template([], _)` still returns `dispatch.in_review`, because
  the direct-call contract predates the resolver and is unit-tested. Under
  `DispatchPhase` an empty pending list classifies to `nil` and falls through
  to the `task.status` mapping instead — so a stage with nothing pending is
  dispatched on its task's status, not forced into the reviewer template.
  `dispatch_prompt/4` never observes the divergence: it ignores this
  function's slug entirely.

  ## `opts` (task 019fa469 stage 3)

  The third argument carries the dispatch opts through to
  `e2e_review_assigns/3`, whose only current consumer is
  `:execution_space_id` — the router's `%State{}` value, which is NOT a task
  schema field and therefore cannot be read off the `task` argument. It
  defaults to `[]` so the long-standing `/1` and `/2` direct-call contracts are
  untouched; with no opt the assign falls back to the task map and then to
  `ExecutionSpace.find_by_task_id/1`.
  """
  @spec select_review_template([map()], map() | nil, keyword()) :: {String.t(), map()}
  def select_review_template(pending_validations, task \\ nil, opts \\ [])

  def select_review_template([], _task, _opts), do: {"dispatch.in_review", %{}}

  def select_review_template(pending_validations, task, opts) when is_list(pending_validations) do
    case DispatchPhase.phase_for_pending(pending_validations) do
      :review_e2e ->
        e2es =
          Enum.filter(pending_validations, fn v ->
            kind = Map.get(v, :kind) || Map.get(v, "kind")
            kind == "e2e_behavior"
          end)

        {"dispatch.review_e2e", e2e_review_assigns(e2es, task, opts)}

      _ ->
        {"dispatch.in_review", %{}}
    end
  end

  defp e2e_review_assigns(validations, task, opts) when is_list(validations) do
    rendered =
      Enum.map(validations, fn validation ->
        %{
          "validation_id" => Map.get(validation, :id) || Map.get(validation, "id") || "",
          "evaluation_payload" =>
            Map.get(validation, :evaluation_payload) ||
              Map.get(validation, "evaluation_payload") || %{}
        }
      end)

    %{
      pending_e2e_validations_json: encode_payload_json(rendered),
      execution_space_id: resolve_execution_space_id(task, opts),
      repo_url: project_attr(task || %{}, :repo_url, ""),
      # member_slug/1 — a review agent that spins up a worktree dev server must
      # land in the stack member's full-UUID worktree, not a truncated prefix.
      task_slug: member_slug(task || %{})
    }
  end

  # `execution_space_id` is a REQUIRED assign for `dispatch.review_e2e` — it is
  # the only template that interpolates it (`prompt_templates.ex:745`, `:794`),
  # and on a FAILED verdict the reviewer's own observation IS the failure
  # feedback, which the template tells it to post into that space. An empty
  # value silently deletes the one output that matters.
  #
  # This used to be `task_field(task, :execution_space_id) || ""`, which was
  # `nil` on every production call: there is NO `execution_space_id` field on
  # the task schema. It lives on the router's `%State{}` (`task_router.ex:89`)
  # and never entered `dispatch_prompt/4`. The `|| ""` then laundered the
  # missing assign into an empty string, which rendered as `Execution space: `
  # and `...the execution space ()` (task 019f9b29 stage 5).
  #
  # Resolution order, most-authoritative first:
  #   1. `opts[:execution_space_id]` — the router's own state, threaded at
  #      `task_router.ex` `do_dispatch/2`. Primary path; costs no query.
  #   2. `task_field(task, :execution_space_id)` — retained because the existing
  #      unit tests hand this function plain maps carrying that key. It is a
  #      fixture shape, NOT a schema field.
  #   3. `ExecutionSpace.find_by_task_id/1` — last resort, so a direct caller
  #      that never went through the router still renders correctly.
  defp resolve_execution_space_id(task, opts) do
    from_opts = presence(Keyword.get(opts, :execution_space_id))
    from_task = presence(task_field(task, :execution_space_id))

    case from_opts || from_task || lookup_execution_space_id(task) do
      nil ->
        report_missing_assign("dispatch.review_e2e", :execution_space_id, task)
        ""

      space_id ->
        space_id
    end
  end

  defp lookup_execution_space_id(task) do
    case presence(task_field(task, :id)) do
      nil ->
        nil

      task_id ->
        case ExecutionSpace.find_by_task_id(task_id) do
          %{id: space_id} -> presence(space_id)
          _ -> nil
        end
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  # A required assign that resolves to nothing must be LOUD. The prompt still
  # renders — a degraded dispatch beats no dispatch — but it now leaves a trace
  # an operator can grep instead of an empty pair of parens.
  #
  # Telemetry is the machine-readable signal, deliberately not `Logger`:
  # `config/test.exs` runs the logger at `level: :warning`, so an `info`-level
  # assertion goes silently vacuous under `CaptureLog` (documented in
  # `task_router_dispatch_suppression_test.exs`). The `Logger.error` alongside
  # it is for the human reading production logs.
  defp report_missing_assign(slug, assign, task) do
    task_id = task_field(task, :id) || "unknown"

    Logger.error(
      "[HeartbeatScheduler] required assign #{inspect(assign)} unresolved for #{slug} " <>
        "(task_id=#{task_id}) — rendering a degraded prompt"
    )

    :telemetry.execute(
      [:platform, :orchestration, :dispatch_assign_missing],
      %{count: 1},
      %{slug: slug, assign: assign, task_id: task_id}
    )
  end

  defp encode_payload_json(payload) when is_map(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(payload)
    end
  rescue
    _ -> inspect(payload)
  end

  defp encode_payload_json(other), do: inspect(other)

  defp task_field(nil, _), do: nil

  defp task_field(task, key) when is_map(task) do
    Map.get(task, key) || Map.get(task, Atom.to_string(key))
  end

  # Pending validations live on the stage struct/map under :validations. Filter
  # for status == "pending" — passed/failed don't need a re-dispatch prompt.
  defp pending_validations_for_stage(nil), do: []

  defp pending_validations_for_stage(stage) when is_map(stage) do
    validations = Map.get(stage, :validations) || Map.get(stage, "validations") || []

    Enum.filter(validations, fn v ->
      status = Map.get(v, :status) || Map.get(v, "status") || "pending"
      status == "pending"
    end)
  end

  defp hardcoded_dispatch_review_e2e(task, assigns) do
    title = Map.get(task, :title) || Map.get(task, "title") || ""
    pending_json = Map.get(assigns, :pending_e2e_validations_json, "[]")
    execution_space_id = Map.get(assigns, :execution_space_id, "")

    """
    Task is in behavioral review — execute every planner-authored e2e_behavior test case and disposition each validation independently.

    Task: #{title}
    Execution space: #{execution_space_id}

    ## Pending e2e_behavior validations (pre-rendered as JSON)

    Each entry below has a `validation_id` and an `evaluation_payload` containing three fields:
    setup / actions / expected. There is no planner-supplied failure_feedback — on a failed verdict, you compose
    the feedback yourself from what you actually observed.

    ```
    #{pending_json}
    ```

    For each entry, walk through `setup` → `actions`, then compare observed behavior to `expected`.

    On success, call `suite_validation_evaluate` with the matching `validation_id`, `status: "passed"` and an `evidence` map describing what you observed.

    On failure, call `suite_validation_evaluate` with the matching `validation_id`, `status: "failed"` and an `evidence` map containing what you EXPECTED (verbatim from the payload) and what you ACTUALLY OBSERVED, with diagnostics. Post that same observation into the execution space (#{execution_space_id}) so the implementing agent reads it on the next dispatch — your observation IS the failure_feedback.

    Run every pending e2e_behavior validation even if an earlier one failed.

    Do NOT call `task_update` to bounce the task — the plan engine handles in_review→in_progress automatically on any failed e2e_behavior verdict.
    Do NOT create a `suite_review_request_create` — review requests are reserved for `manual_approval` validations.

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
    repos = resolve_task_deploy_repos(task)
    default_branch = resolve_branch(task)
    # member_slug/1 — keeps the deploy-phase branch reference consistent with
    # the per-member branch a stack member was given at in_progress.
    task_slug = member_slug(task)

    ack_preamble =
      render_task_ack_preamble(contract_id(task, :id), contract_id(stage || %{}, :id))

    strategy_instructions =
      deploy_strategy_instructions(
        strategy_type,
        strategy_config,
        repos,
        default_branch,
        task_slug
      )

    """
    #{ack_preamble}
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

  # ONE PR/CI/merge sequence per resolved repository, keyed on THAT repository's
  # own `ci` state (task 019fa63a stage 5). A single sequence naming a single
  # repo is what let both cross-repo tasks on 2026-07-27 read one merged PR as a
  # finished deploy — the behavioural half of the same bug stage 2 fixed on the
  # gate side.
  defp deploy_strategy_instructions("pr_merge", config, repos, default_branch, task_slug) do
    sequences =
      case repos do
        # No resolvable repository. `pr_merge` on a task with no repo is a
        # misconfiguration, but the deploy stage still dispatches, so say
        # something actionable rather than emitting a flow with no steps in it.
        [] ->
          """
          1. Ensure all changes are committed and pushed to `task/#{task_slug}`.
          2. This task's project declares no usable GitHub repository, so there is no PR to open. Report a blocker naming the repository the work landed in.
          """

        entries ->
          entries
          |> Enum.with_index(1)
          |> Enum.map_join("\n", &repo_pr_merge_sequence(&1, config, default_branch, task_slug))
      end

    """
    ## PR Merge Deploy Flow
    #{multi_repo_deploy_preamble(repos)}\
    #{sequences}\
    """
  end

  defp deploy_strategy_instructions(
         "docker_deploy",
         config,
         _repos,
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
         "project_files",
         config,
         _repos,
         _default_branch,
         _task_slug
       ) do
    project_id = Map.get(config, "project_id", "the target project")
    folder = Map.get(config, "folder", "Deliverables")

    """
    ## Project Files Deploy Flow
    The platform automatically executes this deploy — you do NOT push evidence.
    The `Platform.Deploy.ProjectFiles` handler will:
      1. Resolve the deliverable canvas (config.deliverable_canvas_id, or the newest canvas in the execution space).
      2. Export the canvas to Markdown.
      3. Write the file into project `#{project_id}` under folder `#{folder}/`.
      4. On success it passes `test_pass`; on failure it fails `test_pass` with a reason.
    Do NOT push `test_pass` evidence manually and do NOT create a `suite_review_request_create`. Report a blocker only if the handler itself fails to run.
    """
  end

  defp deploy_strategy_instructions(
         "skill_driven",
         _config,
         _repos,
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

  defp deploy_strategy_instructions("manual", _config, _repos, _default_branch, _task_slug) do
    """
    ## Manual Deploy
    1. The deploy must be performed manually (by a human or following manual steps).
    2. Create a review request via `suite_review_request_create` for the `manual_approval` validation describing what needs to be deployed and how.
    3. Wait for human confirmation.
    """
  end

  # Bug #5 (task 019f708f): a stack member with a live rollup branch
  # must NOT open its own per-member PR — the stack ships as ONE
  # rollup PR via `Platform.Tasks.StackDeployer.maybe_open_stack_pr/1`.
  # `Tasks.resolve_deploy_strategy/1` returns `no_op_wait_for_rollup`
  # for such tasks; the executor needs a one-shot instruction to
  # yield back to the stack sweep without doing any per-member deploy
  # work at all.
  defp deploy_strategy_instructions(
         "no_op_wait_for_rollup",
         _config,
         _repos,
         _default_branch,
         _task_slug
       ) do
    """
    ## Stack Member — No Per-Member Deploy

    This task is a member of a Task Stack (ADR 0041) with a live rollup
    branch. The stack ships as ONE rollup PR via
    `Platform.Tasks.StackDeployer.maybe_open_stack_pr/1`; a per-member
    `gh pr create` here would shatter the rollup discipline.

    1. Do NOT open a PR for this member.
    2. Pass any deploy-stage validations that were dispatched for this
       task with a short "stack-managed" evidence note.
    3. Call `stage_complete` immediately to yield back to the stack-level
       sweep — it will open (or has already opened) the rollup PR once
       every member has merged into `rollup_branch`.
    """
  end

  defp deploy_strategy_instructions(_type, _config, _repos, _default_branch, _task_slug) do
    """
    ## Deploy
    Execute the deployment according to the project's deploy configuration.
    Push validation evidence as you complete each step.
    """
  end

  defp multi_repo_deploy_preamble(repos) when length(repos) < 2, do: ""

  defp multi_repo_deploy_preamble(repos) do
    """
    This deploy covers #{length(repos)} repositories. The stage carries one
    `pr_merged` gate PER repository and does NOT complete until every one of
    them passes. Do not read one passing gate as a finished deploy, and do not
    infer one repository's readiness from another's.

    """
  end

  defp repo_pr_merge_sequence({entry, index}, config, default_branch, task_slug) do
    auto_merge = Map.get(entry.config || config, "auto_merge", false)
    heading = if entry.repo_url == "", do: "Repository #{index}", else: entry.repo_url

    """
    ### #{heading}
    1. Ensure all changes are committed and pushed to `task/#{task_slug}` in #{heading}.
    2. Open a PR against `#{default_branch}` on #{heading} if not already open.
    #{ci_instruction(entry)}
    #{merge_instruction(entry, auto_merge)}
    """
  end

  # `ci: "none"` is not a softer version of `ci: "required"` — it inverts what a
  # clean merge state MEANS. `openclaw-suite-channel` has no PR workflow at all
  # and `claude-code-suite-channel` has a workflow but no branch protection, so
  # a PR there merges with `statusCheckRollup: []`: zero checks ran. An executor
  # reading "no failing checks" as "CI green" is reading the absence of a signal
  # as the signal.
  defp ci_instruction(%{ci: "none"}) do
    "3. This repository has NO required status checks and its default branch is unprotected. A CLEAN merge state here means zero checks ran, NOT that checks passed. Do NOT infer this repository's readiness from another repository's green CI. A human merges this one, and a human looks at it first."
  end

  defp ci_instruction(_entry) do
    "3. Wait for CI to go green on the PR (GitHub branch protection / auto-merge waits for CI before allowing the merge — you do not need to push a separate `ci_passed` validation)."
  end

  defp merge_instruction(%{ci: "none"}, _auto_merge) do
    "4. Do NOT enable auto-merge here — there is no check for it to wait on. Hand the PR to a human for review and merge. The `pr_merged` validation for THIS repository auto-passes when GitHub fires the `pull_request.closed` webhook — do NOT create a `suite_review_request_create`."
  end

  defp merge_instruction(_entry, true) do
    "4. Merge the PR via GitHub (auto-merge is enabled — it will merge automatically once CI is green). The `pr_merged` validation for THIS repository auto-passes when GitHub fires the `pull_request.closed` webhook."
  end

  defp merge_instruction(_entry, false) do
    "4. Merge the PR in GitHub once CI is green (the human or agent with merge rights clicks the merge button). The `pr_merged` validation for THIS repository auto-passes when GitHub fires the `pull_request.closed` webhook — do NOT create a `suite_review_request_create`."
  end

  # Hardcoded fallback for `nudge_prompt/2` — mirrors the seeded `"nudge"`
  # template body so environments without the seeded row still emit the
  # short-form payload. Deliberately minimal: two-line preamble + the
  # `nudge_contract/2` completion reminder. No skills, no evidence workflow,
  # no task description.
  defp hardcoded_nudge(task, stage, elapsed_str) do
    task_id = contract_id(task, :id) || "unknown"
    stage_id = contract_id(stage || %{}, :id) || "unknown"

    preamble =
      "Task #{task_id} stage #{stage_id} — no ack in #{elapsed_str}m. " <>
        "Please ack, push validation, or report_blocker.\n"

    preamble <> nudge_contract(task, stage)
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
  # nudge       → nudge_contract    → pending validation IDs + ack fork

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

  defp maybe_strip_git_workflow(prompt, task) do
    if deploy_repos_present?(task) do
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
    if deploy_repos_present?(task) and not String.contains?(prompt, "## Git Workflow (CRITICAL)") do
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

              "pr_merged" ->
                "- `pr_merged` → validation_id=`#{id}` (merge the PR in GitHub once CI is green; the `pull_request.closed` webhook auto-passes this validation. Do NOT create a `suite_review_request_create` and do NOT call `validation_pass` yourself.)"

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

  # `nudge_contract/2` — the "## Completion Reminder" block appended after the
  # `nudge_prompt/2` preamble. Deliberately terse: task_id, stage_id, and a
  # single action line listing pending validation IDs compactly rather than
  # enumerating per-validation instructions (that's the dispatch contract's
  # job — the nudge is a re-poke, not the first dispatch).
  defp nudge_contract(_task, nil), do: ""

  defp nudge_contract(task, stage) do
    stage_id = contract_id(stage, :id)
    task_id = contract_id(task, :id)
    ids = pending_validation_ids(stage)

    action_line =
      case ids do
        "" ->
          "- No pending validation IDs — if the work is complete, call `stage_complete` with `stage_id=#{stage_id}`."

        list ->
          "- Pending validation IDs: #{list} — ack, push validation_pass, or report_blocker with task_id=#{task_id} stage_id=#{stage_id}"
      end

    """

    ## Completion Reminder
    #{contract_target_lines(task_id, stage_id)}
    #{action_line}
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

  # Build the "## Git Workflow (CRITICAL)" block for a dispatch prompt.
  #
  # Non-stack tasks get the legacy section verbatim — slug is the 8-char
  # `short_task_id/1`, output is byte-for-byte unchanged.
  #
  # Stack members (ADR 0041, detected via `stack_membership/1`) get a section
  # whose worktree path + branch use the FULL task UUID (`member_slug/1`), so
  # siblings minted in one batch can never collide on a shared id prefix. A
  # `## Task Stack Membership` sub-block names the stack_id, the rollup branch,
  # and flags the task as a stack member.
  defp git_workflow_section(task) do
    case stack_membership(task) do
      nil -> non_stack_git_workflow_section(task)
      membership -> stack_member_git_workflow_section(task, membership)
    end
  end

  defp non_stack_git_workflow_section(task) do
    repos = resolve_task_deploy_repos(task)
    default_branch = resolve_branch(task)
    task_slug = short_task_id(task)

    """

    ## Git Workflow (CRITICAL)
    Repository: #{primary_repo_url(repos)}
    Base branch: #{default_branch}
    #{additional_repos_block(repos, task_slug, default_branch)}\

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

  defp stack_member_git_workflow_section(task, membership) do
    repos = resolve_task_deploy_repos(task)
    default_branch = resolve_branch(task)
    # Full UUID — collision-free across siblings that share an id prefix.
    task_slug = member_slug(task)
    rollup_branch = membership.rollup_branch || "stack/#{membership.stack_slug}"

    # ADR-0042 Decision 2: retarget member branches to rollup HEAD (so a member
    # sees its already-merged siblings). Gate on the async `rollup_branch_ready`
    # stamp from `StackDeployer.do_create_rollup_branch/2` — if the stamp is
    # absent (the rollup push has not landed yet), fall back to
    # `origin/#{default_branch}` and log a warning. That keeps the executor from
    # dispatching `git worktree add ... origin/stack/foo` before the ref exists.
    parent_branch =
      case rollup_branch_ready(membership) do
        true ->
          rollup_branch

        false ->
          Logger.warning(
            "[HeartbeatScheduler] stack #{membership.stack_id} rollup not yet ready; " <>
              "member #{full_task_id(task)} branching from #{default_branch}"
          )

          default_branch
      end

    membership_note =
      if parent_branch == rollup_branch do
        "- Your member branch `task/#{task_slug}` is cut from `origin/#{rollup_branch}` " <>
          "so you see previously-merged sibling members.\n" <>
          "    - The ROLLUP branch `#{rollup_branch}` is what reconciles sibling members. " <>
          "Merge back into it via fast-forward on validation pass — do NOT open a per-member PR."
      else
        "- Your member branch `task/#{task_slug}` is cut from `origin/#{default_branch}` " <>
          "INDEPENDENTLY — the rollup branch was not ready at dispatch time.\n" <>
          "    - The ROLLUP branch `#{rollup_branch}` is what reconciles sibling members. " <>
          "Do NOT depend on a sibling member's unpushed work; treat each member branch as isolated."
      end

    """

    ## Git Workflow (CRITICAL)
    Repository: #{primary_repo_url(repos)}
    Base branch: #{default_branch}
    #{additional_repos_block(repos, task_slug, parent_branch)}\

    1. Create a worktree from the latest #{parent_branch} branch:
       ```
       git fetch origin
       git worktree add ../worktrees/#{task_slug} -b task/#{task_slug} origin/#{parent_branch}
       cd ../worktrees/#{task_slug}
       ```
    2. Do ALL work in the worktree directory.
    3. When implementation is complete:
       - Run the full test suite and lint checks
       - Commit all changes with a descriptive message referencing task #{full_task_id(task)}
       - Push the branch: `git push -u origin task/#{task_slug}`
       - Do NOT open a PR yet — PR opening happens in the deploy phase
    4. NEVER work on an existing branch. ALWAYS branch from latest origin/#{parent_branch}.

    ## Task Stack Membership
    This task is a stack member (part of task stack `#{membership.stack_id}`).
    - stack_id: `#{membership.stack_id}`
    - Rollup branch: `#{rollup_branch}`
    #{membership_note}
    """
  end

  # The rollup branch is created async by StackDeployer. Members branching from
  # `origin/#{rollup_branch}` before that push lands would hit `fatal: origin/…:
  # no such ref` in the executor. Gate on the `rollup_branch_ready` metadata
  # stamp so the flip is deterministic.
  defp rollup_branch_ready(%{stack_metadata: %{"rollup_branch_ready" => %{}}}), do: true
  defp rollup_branch_ready(_), do: false

  defp insert_before_context(prompt, ""), do: prompt

  defp insert_before_context(prompt, addition) do
    context_anchor = "\nThe attention signal"

    if String.contains?(prompt, context_anchor) do
      String.replace(prompt, context_anchor, addition <> context_anchor, global: false)
    else
      prompt <> addition
    end
  end

  defp real_repo_url?(repo_url) when is_binary(repo_url) do
    repo_url != "" and not String.contains?(repo_url, "example.invalid")
  end

  defp real_repo_url?(_repo_url), do: false

  # ── Resolved repository set (task 019fa63a stage 5) ──────────────────────
  #
  # Every dispatch site that used to read `project_attr(task, :repo_url, "")`
  # reads this instead. The project's single `repo_url` was the source of the
  # wrong-repo dispatches: both cross-repo client tasks on 2026-07-27 received
  # git blocks naming `Startup-Suite/core` because that is what their PROJECT
  # points at, not where their work lived.
  #
  # `Tasks.repos_from_strategy/2` rather than `Tasks.resolve_deploy_repos/1`
  # because this module renders prompts for plain maps as well as `%Task{}`
  # structs (see `resolve_task_deploy_strategy/1` directly above, which carries
  # the same accommodation) and must not touch the `Repo` — the prompt tests
  # are `async: true` with no sandbox checked out. Both arities share one
  # resolution body, so a prompt can never name a different repo set than the
  # deploy gates built from the same strategy.
  defp resolve_task_deploy_repos(task) do
    Platform.Tasks.repos_from_strategy(
      resolve_task_deploy_strategy(task),
      project_attr(task, :repo_url, "")
    )
  end

  # The primary entry is what every SINGULAR repo rendering resolves to — the
  # `Repository:` line, and the `repo_url` assign handed to `dispatch.deploying`.
  # For a one-entry override this alone fixes the wrong-repo dispatch, with no
  # template change at all.
  defp primary_repo(repos) do
    Enum.find(repos, &(&1.role == :primary)) || List.first(repos)
  end

  defp primary_repo_url(repos) do
    case primary_repo(repos) do
      nil -> ""
      entry -> entry.repo_url
    end
  end

  # `resolve_task_deploy_repos/1` returning `[]` is the new "no repo" signal and
  # must strip the git block exactly as a blank `project.repo_url` does today —
  # `Tasks.project_repo_entry/2` already returns `[]` for `""`, a non-GitHub
  # host and `example.invalid`. `real_repo_url?/1` keeps its rules and is
  # applied to the resolved primary entry, so a DECLARED placeholder repo (kept
  # by stage 1 so its gate cannot be matched by accident) still strips the block
  # rather than instructing an executor to clone `example.invalid`.
  defp deploy_repos_present?(task) do
    task |> resolve_task_deploy_repos() |> primary_repo_url() |> real_repo_url?()
  end

  # Rendered into the "## Git Workflow (CRITICAL)" block ONLY when the resolved
  # set holds 2+ entries, so every single-repo task — which is every task that
  # declares no `"repos"` — sees a byte-identical prompt to before.
  #
  # The branch name is deliberately the SAME in every repository:
  # `Changelog.extract_task_id_from_branch/1` resolves a task from the branch
  # name, and per-repo suffixes would break that for every repo but one.
  defp additional_repos_block([], _task_slug, _base_branch), do: ""
  defp additional_repos_block([_only], _task_slug, _base_branch), do: ""

  defp additional_repos_block(repos, task_slug, base_branch) do
    lines =
      repos
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {entry, index} ->
        """
        - #{entry.repo_url} (#{entry.role}, CI: #{entry.ci})
          ```
          git worktree add ../worktrees/#{task_slug}-#{repo_dir_suffix(entry, index)} -b task/#{task_slug} origin/#{base_branch}
          ```\
        """
      end)

    """

    ### Repositories in scope (#{length(repos)})
    This task's work spans MORE THAN ONE repository. Every one of them gets its own
    worktree, and the BRANCH NAME is `task/#{task_slug}` in ALL of them — task
    resolution reads the task id off the branch name, so per-repo suffixes would
    break it for every repository but one.

    #{lines}

    The numbered procedure below describes ONE repository. Run steps 1-3 in each
    repository listed above that your change touches, using that repository's
    worktree path, and push every branch you created. The deploy stage carries one
    `pr_merged` gate PER repository and does not complete until every one of them
    passes — one green gate is not a finished deploy.
    """
  end

  # Worktree directory suffix — the repository NAME when the URL resolves to a
  # slug, the 1-based index otherwise. Two worktrees for one task cannot share a
  # directory, and a declared-but-unresolvable entry still needs a unique one.
  defp repo_dir_suffix(%{slug: slug}, _index) when is_binary(slug) do
    slug |> String.split("/") |> List.last()
  end

  defp repo_dir_suffix(_entry, index), do: Integer.to_string(index)

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

  @doc false
  # Full, un-truncated task UUID — the counterpart of `short_task_id/1`. Stack
  # members route worktree/branch slugs through the full id so siblings minted
  # in one batch (which share a first hyphen-segment) never collide.
  def full_task_id(task) do
    task
    |> Map.get(:id, Map.get(task, "id", "task"))
    |> to_string()
  end

  @doc false
  # Detect task-stack membership (ADR 0041, fully merged to main). A real stack
  # member carries its membership in the `tasks.stack_id` column (a non-nil FK
  # into `task_stacks`), NOT in `task.metadata` — an earlier implementation
  # inspected `task.metadata` keys, which never fired because the orchestrator
  # never writes stack context there. Returns `nil` for a non-stack task
  # (`stack_id` nil or blank), otherwise a map
  # `%{stack_id, stack_slug, rollup_branch}` sourced from the preloaded
  # `task.stack` association (`Platform.Tasks.Stack`: `slug`, `rollup_branch`,
  # `base_branch`). The rollup branch falls back to `"stack/<slug>"` when the
  # stack row has no explicit `rollup_branch`.
  def stack_membership(task) do
    stack_id = Map.get(task, :stack_id) || Map.get(task, "stack_id")

    if is_binary(stack_id) and String.trim(stack_id) != "" do
      stack = stack_assoc(task)
      stack_slug = stack && (Map.get(stack, :slug) || Map.get(stack, "slug"))

      rollup_branch =
        case stack && (Map.get(stack, :rollup_branch) || Map.get(stack, "rollup_branch")) do
          rb when is_binary(rb) and rb != "" -> rb
          _ when is_binary(stack_slug) and stack_slug != "" -> "stack/#{stack_slug}"
          _ -> nil
        end

      stack_metadata =
        case stack && (Map.get(stack, :metadata) || Map.get(stack, "metadata")) do
          %{} = m -> m
          _ -> %{}
        end

      %{
        stack_id: stack_id,
        stack_slug: stack_slug,
        rollup_branch: rollup_branch,
        stack_metadata: stack_metadata
      }
    else
      nil
    end
  end

  # Pull the preloaded `:stack` association off the task. Returns `nil` when the
  # association is absent or not loaded (`%Ecto.Association.NotLoaded{}`) — the
  # caller still flags the task a stack member off `stack_id` alone and falls
  # back to a `stack/<stack_id-prefix>`-free rollup branch only when no slug is
  # available.
  defp stack_assoc(task) do
    case Map.get(task, :stack) || Map.get(task, "stack") do
      %Ecto.Association.NotLoaded{} -> nil
      %{} = stack -> stack
      _ -> nil
    end
  end

  @doc false
  # The single chokepoint every worktree/branch slug routes through: the full
  # UUID for a stack member (collision-free), the legacy 8-char prefix for a
  # non-stack task (keeps existing dispatch output byte-for-byte unchanged).
  def member_slug(task) do
    if stack_membership(task), do: full_task_id(task), else: short_task_id(task)
  end
end
