defmodule Platform.Orchestration.PromptTemplates do
  @moduledoc """
  Context module for managing prompt templates.

  Prompt templates are stored in the database and used by HeartbeatScheduler
  to generate dispatch and heartbeat prompts. Templates use `{{variable_name}}`
  mustache-style interpolation (NOT EEx — too dangerous for user-editable content).

  If a template is not found in the database, HeartbeatScheduler falls back
  to its hardcoded prompts, so the system works even before seeding.
  """

  import Ecto.Query

  alias Platform.Orchestration.PromptTemplate
  alias Platform.Repo

  @doc "List all prompt templates ordered by slug."
  @spec list_templates() :: [PromptTemplate.t()]
  def list_templates do
    Repo.all(from(t in PromptTemplate, order_by: [asc: t.slug]))
  end

  @doc "Get a prompt template by id."
  @spec get_template(String.t()) :: PromptTemplate.t() | nil
  def get_template(id) do
    Repo.get(PromptTemplate, id)
  end

  @doc "Get a prompt template by slug."
  @spec get_template_by_slug(String.t()) :: PromptTemplate.t() | nil
  def get_template_by_slug(slug) do
    Repo.get_by(PromptTemplate, slug: slug)
  end

  @doc "Create a new prompt template."
  @spec create_template(map()) :: {:ok, PromptTemplate.t()} | {:error, Ecto.Changeset.t()}
  def create_template(attrs) do
    %PromptTemplate{}
    |> PromptTemplate.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing prompt template."
  @spec update_template(PromptTemplate.t(), map()) ::
          {:ok, PromptTemplate.t()} | {:error, Ecto.Changeset.t()}
  def update_template(%PromptTemplate{} = template, attrs) do
    template
    |> PromptTemplate.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a prompt template."
  @spec delete_template(PromptTemplate.t()) ::
          {:ok, PromptTemplate.t()} | {:error, Ecto.Changeset.t()}
  def delete_template(%PromptTemplate{} = template) do
    Repo.delete(template)
  end

  @doc """
  Render a template by slug with the given assigns map.

  Fetches the template from the database and interpolates `{{variable_name}}`
  placeholders with values from the assigns map. Returns `{:error, :not_found}`
  if no template exists for the given slug, or if the database is unavailable.
  """
  @spec render_template(String.t(), map()) :: {:ok, String.t()} | {:error, :not_found}
  def render_template(slug, assigns) do
    case get_template_by_slug(slug) do
      nil ->
        {:error, :not_found}

      %PromptTemplate{content: content} ->
        rendered = interpolate(content, assigns)
        {:ok, rendered}
    end
  rescue
    _ ->
      {:error, :not_found}
  end

  @doc """
  Return the default (hardcoded) content for a given slug.

  Returns `nil` if the slug is not a known default.
  """
  @spec default_content_for_slug(String.t()) :: String.t() | nil
  def default_content_for_slug(slug) do
    case Enum.find(default_templates(), &(&1.slug == slug)) do
      %{content: content} -> content
      nil -> nil
    end
  end

  @doc """
  Seed the 5 default prompt templates from the hardcoded HeartbeatScheduler prompts.

  Idempotent — only inserts if the slug doesn't already exist.
  """
  @spec seed_defaults() :: :ok
  def seed_defaults do
    Enum.each(default_templates(), fn template ->
      case get_template_by_slug(template.slug) do
        nil ->
          {:ok, _} = create_template(template)

        _existing ->
          :skip
      end
    end)

    :ok
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp interpolate(content, assigns) do
    Regex.replace(~r/\{\{(\w+)\}\}/, content, fn _match, key ->
      value =
        try do
          atom_key = String.to_existing_atom(key)
          Map.get(assigns, atom_key) || Map.get(assigns, key) || ""
        rescue
          ArgumentError ->
            Map.get(assigns, key) || ""
        end

      to_string(value)
    end)
  end

  defp default_templates do
    skills_reference =
      "The dispatch context includes attached skills under the `skills` key. " <>
        "Treat bundled skill content in that payload as authoritative for this task before trying to rediscover skills from disk. " <>
        "Read and follow any relevant bundled skills — they describe conventions, repo layout, deploy targets, and how to delegate work. " <>
        "Only fall back to filesystem skill lookup if the payload clearly references a path without including the needed content."

    [
      %{
        slug: "dispatch.planning",
        name: "Planning Dispatch Prompt",
        description:
          "Sent when a task is first assigned and needs a plan created. " <>
            "Instructs the agent to create and submit a plan before starting work.",
        variables: ["task_title", "task_description", "task_priority", "skills_reference"],
        content: """
        You have been assigned a task that requires a plan before any implementation begins.

        Task: {{task_title}}
        Description: {{task_description}}
        Priority: {{task_priority}}

        Create a plan using the plan_create tool. The plan will be reviewed by a human before work starts — make it specific enough that they can meaningfully approve or reject it.

        A good plan stage must include:
        - A clear name (not just a category label)
        - A description that explains: what specifically will be changed, which files will be modified or created, what the implementation approach is, and why that approach was chosen
        - Appropriate validations: use test_pass and lint_pass for code changes. Use manual_approval for any stage that requires a human to visually verify a UI change — when you reach that stage, post a screenshot as a canvas into the execution space so the human can review it. Do NOT include code_review as a validation kind — it is not supported.

        Aim for 3–7 stages. Each stage should represent a discrete, reviewable unit of work. "Client-side draft persistence" with no further detail is not acceptable — describe the actual change.

        Example of a good stage description:
        "Add a module-level drafts Map to ComposeInput JS hook (assets/js/hooks/compose_input.js). On every input event, store the current textarea value keyed by space_id (read from data-space-id attribute on the element). On mounted(), restore any saved draft and push it to the server via compose_changed event. On compose_reset, delete the draft for that space."

        Submit the plan with plan_submit when complete. Do not begin implementation until the plan is approved.

        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project (name, repo_url, tech_stack), epic (name, description, acceptance_criteria), task metadata, current plan with stages, and execution_space_id. Use it for full context when writing your plan.

        ## Organization Context
        The `context.org` field carries org-level knowledge: ORG_IDENTITY.md (mission, values, product summary), ORG_MEMORY.md (long-term curated decisions), ORG_AGENTS.md (roster), and recent ORG_NOTES-YYYY-MM-DD daily notes. Read these before writing your plan — they often explain constraints, patterns, or prior decisions that should shape your approach.

        ## Writing to Org Memory
        Org memory writes are a first-class responsibility. When planning surfaces a decision worth preserving, record it. Qualifying moments include:
        - Architectural decisions made (what, why, alternatives considered)
        - New integrations or dependencies agreed
        - Context shifts (priorities reordered, strategy changes)
        - Blockers resolved (what broke, how, what to watch next time)
        - Milestones completed (what shipped, what it enables)

        Use `suite_org_memory_append` for daily notes (append-only). Use `suite_org_context_write` to update curated files (`ORG_MEMORY.md` for long-term knowledge, `ORG_AGENTS.md` for roster changes). Brief, concrete entries beat long essays — one decision per entry.

        {{skills_reference}}
        """
      },
      %{
        slug: "dispatch.in_progress",
        name: "In-Progress Dispatch Prompt",
        description:
          "Sent when a task is in_progress with an approved plan. " <>
            "Instructs the agent to execute the current stage and push evidence.",
        variables: [
          "task_title",
          "stage_info",
          "repo_url",
          "default_branch",
          "task_slug",
          "skills_reference"
        ],
        content: """
        Plan approved — execute the current stage.

        Task: {{task_title}}
        {{stage_info}}Push evidence using validation_pass or stage_complete as you finish each step. Post commentary to the execution space so reviewers can follow along. Use report_blocker if you are stuck.

        ## Git Workflow (CRITICAL)
        Repository: {{repo_url}}
        Base branch: {{default_branch}}

        1. Create a worktree from the latest {{default_branch}} branch:
           ```
           git fetch origin
           git worktree add ../worktrees/{{task_slug}} -b task/{{task_slug}} origin/{{default_branch}}
           cd ../worktrees/{{task_slug}}
           ```
        2. Do ALL work in the worktree directory.
        3. When implementation is complete:
           - Run the full test suite and lint checks
           - Commit all changes with a descriptive message referencing task {{task_slug}}
           - Push the branch: `git push -u origin task/{{task_slug}}`
           - Do NOT open a PR yet — PR opening happens in the deploy phase
        4. NEVER work on an existing branch. ALWAYS branch from latest origin/{{default_branch}}.

        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.
        Start from the concrete stage contract and any attached/bundled skill content in that payload before re-fetching broad task/project context.
        Avoid redundant task/plan lookup churn on the first turn unless an identifier is genuinely missing or the stage contract is ambiguous.

        ## Organization Context
        The `context.org` field carries org-level knowledge: ORG_IDENTITY.md (mission, values, product summary), ORG_MEMORY.md (long-term curated decisions), ORG_AGENTS.md (roster), and recent ORG_NOTES-YYYY-MM-DD daily notes. Check these before making non-obvious choices — they often encode constraints or prior decisions that apply here.

        ## Writing to Org Memory
        Org memory writes are a first-class responsibility. As you execute, record decisions and milestones that future agents and humans will care about. Qualifying moments include:
        - Architectural decisions made (what, why, alternatives considered)
        - New integrations or dependencies agreed
        - Context shifts (priorities reordered, strategy changes)
        - Blockers resolved (what broke, how, what to watch next time)
        - Milestones completed (what shipped, what it enables)

        Use `suite_org_memory_append` for daily notes (append-only). Use `suite_org_context_write` to update curated files (`ORG_MEMORY.md` for long-term knowledge, `ORG_AGENTS.md` for roster changes). Brief, concrete entries beat long essays — one decision per entry. Write memory alongside your stage work, not as a final cleanup step.

        {{skills_reference}}
        """
      },
      %{
        slug: "dispatch.in_review",
        name: "In-Review Dispatch Prompt",
        description:
          "Sent when a task is in_review. " <>
            "Instructs the agent to exercise and validate the implementation experientially.",
        variables: [
          "task_title",
          "stage_info",
          "skills_reference"
        ],
        content: """
        Task is in review — exercise and validate the implementation.

        Task: {{task_title}}
        {{stage_info}}Your job is experiential review: exercise the feature in a running environment and produce evidence that it works as intended. Tests and lint were already validated during execution — do not re-check them here.

        ## How to review
        - Start a local dev server for the worktree (reference the dev server skill via attached skills if available)
        - For UI changes: navigate to the relevant pages, take screenshots, verify visual correctness and interaction behavior
        - For non-UI changes: exercise the feature via API calls, CLI, or functional tests that demonstrate the behavior
        - Post screenshots, canvas snapshots, or other concrete evidence into the execution space

        ## First-turn rule (CRITICAL)
        - Do NOT spend your first substantive turn re-discovering broad task/plan state if the dispatch already provides `Current task_id`, `Current stage_id`, `validation_id`, and `execution_space_id`.
        - For a `manual_approval` review stage, your first substantive turn should do the real review work and then create the human gate:
          1. exercise the implementation in a running environment,
          2. publish concrete evidence into the execution space,
          3. call `suite_review_request_create` for the provided `validation_id` with labelled checklist items and links to that evidence.
        - Only call `suite_task_get`, `suite_plan_get`, or `suite_validation_list` if an identifier is actually missing or the dispatch context is contradicted by direct evidence.
        - Reach the evidence + review-request step in the same attempt unless a real blocker prevents it.

        ## Review rules
        - Use `suite_validation_evaluate` for deterministic review validations (`passed` / `failed`).
        - Use `suite_review_request_create` for `manual_approval` validations — include labelled checklist items plus screenshots/canvas/evidence links.
        - Do NOT call `stage_complete` before the required review request and evidence have been created.
        - Do NOT self-approve `manual_approval` validations.
        - Do NOT call `task_update` for lifecycle status changes — review outcomes flow through validations and review requests.
        - If the feature does not work as intended, fail the relevant validation with concrete reproduction details so the task can return to `in_progress`.
        - If review passes, let the plan engine advance the task; do not force status changes manually.

        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.

        {{skills_reference}}
        """
      },
      %{
        slug: "dispatch.deploying",
        name: "Deploying Dispatch Prompt",
        description:
          "Sent when a task is in deploying status with a running deploy stage. " <>
            "Instructs the agent to execute the deploy based on the resolved strategy.",
        variables: [
          "task_title",
          "stage_info",
          "repo_url",
          "default_branch",
          "task_slug",
          "deploy_strategy_type",
          "deploy_strategy_config",
          "skills_reference"
        ],
        content: """
        Task is deploying — execute the deploy stage based on the resolved strategy.

        Task: {{task_title}}
        {{stage_info}}Deploy strategy: **{{deploy_strategy_type}}**
        Strategy config: {{deploy_strategy_config}}

        ### Strategy-specific instructions

        **pr_merge**: Open PR from task branch against {{default_branch}}, wait for CI to pass, then request human merge approval via `suite_review_request_create`.
        **docker_deploy**: SSH to target, pull image, compose up, health check, push evidence.
        **skill_driven**: Execute the attached skill's deploy procedure, confirm via manual approval.
        **manual**: Create a review request describing what needs to be deployed; wait for human confirmation.

        Follow the instructions for **{{deploy_strategy_type}}** above.

        ### Deploy boundaries
        - Do NOT modify code — if CI fails, report a blocker so the task returns to in_progress
        - Do NOT re-run tests or lint locally — CI handles that
        - The branch is already pushed from execution; your job is to get it merged and deployed

        Push evidence using validation_pass as you complete each deploy step.
        Use report_blocker if you are stuck or the deploy fails.

        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.

        {{skills_reference}}
        """
      },
      %{
        slug: "dispatch.fallback",
        name: "Fallback Dispatch Prompt",
        description:
          "Sent when a task is assigned but doesn't match planning/in_progress/in_review/deploying. " <>
            "Generic assignment prompt.",
        variables: [
          "task_title",
          "task_description",
          "task_status",
          "task_priority",
          "stage_info",
          "skills_reference"
        ],
        content: """
        You have been assigned a task.

        Task: {{task_title}}
        Description: {{task_description}}
        Status: {{task_status}}
        Priority: {{task_priority}}
        {{stage_info}}Review the task context and begin working. Report progress by pushing validation evidence as you complete each stage.

        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, current plan with stages, and execution_space_id. Use it for full context.

        #{skills_reference}
        """
      },
      %{
        slug: "heartbeat",
        name: "Heartbeat Prompt",
        description:
          "Periodic heartbeat sent to the agent to force it to account for itself. " <>
            "Carries elapsed time, stage position, pending validations, and plan status. " <>
            "During the planning phase, plan-aware prompts override this template.",
        variables: [
          "task_title",
          "stage_name",
          "stage_status",
          "elapsed",
          "pending_validations",
          "plan_status",
          "plan_exists"
        ],
        content: """
        Task: {{task_title}} [stage: {{stage_name}} — {{stage_status}}]
        Stage running for: {{elapsed}}
        Pending validations: {{pending_validations}}
        Plan status: {{plan_status}}

        Either push validation evidence or report a blocker.

        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id.\
        """
      }
    ]
  end
end
