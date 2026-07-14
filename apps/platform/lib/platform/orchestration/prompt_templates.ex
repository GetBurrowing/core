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
    case Enum.find(do_default_templates(), &(&1.slug == slug)) do
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
    Enum.each(do_default_templates(), fn template ->
      case get_template_by_slug(template.slug) do
        nil ->
          {:ok, _} = create_template(template)

        _existing ->
          :skip
      end
    end)

    :ok
  end

  @doc """
  Return the hardcoded default template descriptors (slug, name,
  description, variables, content). Exposed so tests and migrations can
  inspect the registered metadata — the seed path uses the same list.
  """
  @spec default_templates() :: [map()]
  def default_templates, do: do_default_templates()

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

  defp do_default_templates do
    skills_reference =
      "## Skill discovery — do this BEFORE you start executing\n\n" <>
        "Skills encode org conventions you may not have; load the right one before improvising. " <>
        "Discovery is an active step, not a passive read — the payload bundler does NOT always pre-attach the skill you need:\n\n" <>
        "1. Derive this task's domain from its title and description (e.g. \"task stack\", \"canvas\", \"migration\", \"LiveView\").\n" <>
        "2. Call the `skill_list` MCP tool yourself and scan the returned skills for one plausibly matching that domain " <>
        "(a task mentioning \"task stack\" -> the `task-stack-creation` skill; \"canvas\" -> a `canvas-*` skill). " <>
        "Do NOT assume the right skill was pre-attached to the payload.\n" <>
        "3. If a skill matches, call the `skill_get` MCP tool to fetch its full content and follow it as authoritative.\n\n" <>
        "Discovery happens by calling `skill_list` / `skill_get` yourself — do NOT treat \"the `skills` key\" or an attached " <>
        "skills object as your discovery mechanism, because you receive rendered text, not an introspectable object.\n\n" <>
        "If the dispatch context did attach skill content inline, still treat that bundled content as authoritative for this task " <>
        "before trying to rediscover skills from disk. " <>
        "Read and follow any relevant bundled skills — they describe conventions, repo layout, deploy targets, and how to delegate work. " <>
        "Only fall back to filesystem skill lookup if the payload clearly references a path without including the needed content."

    [
      %{
        slug: "dispatch.planning",
        name: "Planning Dispatch Prompt",
        description:
          "Sent when a task is first assigned and needs a plan created. " <>
            "Instructs the agent to create and submit a plan before starting work.",
        variables: [
          "task_title",
          "task_description",
          "task_priority",
          "provider_specific_guidance",
          "previous_rejection_reason",
          "upstream_plans_section",
          "skills_reference"
        ],
        content: """
        You have been assigned a task that requires a plan before any implementation begins.

        Task: {{task_title}}
        Description: {{task_description}}
        Priority: {{task_priority}}

        {{provider_specific_guidance}}

        {{previous_rejection_reason}}
        {{upstream_plans_section}}
        Create a plan using the plan_create tool. The plan will be reviewed by a human before work starts — make it specific enough that they can meaningfully approve or reject it.

        ## Stage scope (planner's responsibility)

        Plan **implementation and validation only**. The system auto-injects the deploy stage when the task transitions to `deploying` status — you do NOT include it. Specifically:

        - **Planner** designs implementation stages (`test_pass` + `lint_pass`, plus `manual_approval` on UI-rendering stages) and the per-task `e2e_behavior` adversarial test plan.
        - **Implementer** executes each implementation stage.
        - **Review agent** runs the `e2e_behavior` cases at review time.
        - **Deployer** (auto-spawned at `deploying`) opens the PR, polls CI, follows the deploy strategy (`pr_merge` / `docker_deploy` / `skill_driven` / `manual`), and bounces the task back to `in_progress` if CI fails.

        Do NOT include a stage like "Deploy via PR merge", "Open PR", "Watch CI", or "Merge". Those are the deployer's job, not the planner's. The system auto-injects the deploy stage from the resolved deploy strategy when it is needed.

        A good plan stage must include:
        - A clear name (not just a category label)
        - A description that explains: what specifically will be changed, which files will be modified or created, what the implementation approach is, and why that approach was chosen
        - Appropriate per-stage validations (see "Validation kinds" below)

        Aim for 3–7 implementation stages. Each stage should represent a discrete, reviewable unit of work. "Client-side draft persistence" with no further detail is not acceptable — describe the actual change.

        Example of a good stage description:
        "Add a module-level drafts Map to ComposeInput JS hook (assets/js/hooks/compose_input.js). On every input event, store the current textarea value keyed by space_id (read from data-space-id attribute on the element). On mounted(), restore any saved draft and push it to the server via compose_changed event. On compose_reset, delete the draft for that space."

        ## Validation kinds

        Per-stage validations (attach to the implementation stage they protect):
        - `test_pass` and `lint_pass` for any stage that touches code.
        - `manual_approval` ONLY on stages that visually re-render UI. UI-touching means the stage modifies one of: `.heex` templates, `assets/js/`, `assets/css/`, `app.css`, `compose_input`, `chat_live`, `tasks_live.ex`, `_web/live/`, or `_web/components/`. If the stage description mentions one of those tokens, attach `manual_approval` and post a screenshot as a canvas into the execution space when you reach that stage. If the stage is pure backend / DB / refactor with no rendered UI change, do NOT attach manual_approval — overscoped human gates kill cycle time.

        Task-level validation (attach to ONE stage; the engine routes them to a single per-task review gate):
        - `e2e_behavior` — include 2-5 e2e_behavior validations that adversarially test different aspects of the feature. Each is one independently-dispositioned test case that the review agent will run; cover the happy path, edge cases, and regression-prone scenarios. The user reviews and approves this test plan at plan time, so be specific. Each carries an `evaluation_payload` map with these keys (all required, all strings):
          - `setup`: how the review agent should prepare the dev environment (fixtures, seeds, etc.)
          - `actions`: the concrete steps to perform against the running feature
          - `expected`: the observable behavior that constitutes success
        - Do NOT include a `failure_feedback` field — the actual failure observation IS the feedback (the review agent posts what it expected vs what it actually saw on a failed verdict). Pre-writing failures at plan time is wrong because you cannot predict them.
        - The plan engine lifts every e2e_behavior validation to a single synthetic task-level review stage automatically — do NOT attach them to multiple stages and do NOT create a manual review stage just for them.

        Worked e2e_behavior payload examples (for a "task dependency blocker UI" task — show two adversarial cases side-by-side):

        Case A — happy path:
        ```
        {
          "kind": "e2e_behavior",
          "evaluation_payload": {
            "setup": "Create two tasks A and B in the same project; mark task B as depending on task A (kind: blocks).",
            "actions": "Open task B in the detail panel and look at the Dependencies section. Then mark task A as done via task_complete and refresh task B.",
            "expected": "Before completion, task B's panel shows task A under 'Blocked by' with an unmet badge. After task A completes, task B's panel removes the unmet badge and the task transitions out of 'blocked' status within 2 seconds."
          }
        }
        ```

        Case B — regression-prone edge case (cycle / multi-dep):
        ```
        {
          "kind": "e2e_behavior",
          "evaluation_payload": {
            "setup": "Create three tasks A, B, C; mark B depending on A and C; mark A depending on a non-existent UUID.",
            "actions": "Open task B's detail panel; complete only task C; refresh.",
            "expected": "Task B's 'Blocked by' list shows two entries (A unmet, C met). After completing C, only A remains unmet; B does not auto-transition out of blocked because A is still pending. The orphan-dep on A renders with a nil title fallback rather than crashing."
          }
        }
        ```

        Forbidden:
        - `code_review` is NOT a supported validation kind — do not include it.
        - Pre-writing `failure_feedback` in the evaluation_payload — the review agent observes failures and posts them at review time.
        - `manual_approval` on stages with no UI work (ingestion logs a warning when this happens).

        ## Design involvement (UI/UX tasks) — decide at plan time

        First decide: does this task touch UI/UX? It does if ANY of:
        - a planned stage would modify UI files (the same token list as the `manual_approval` rule above), OR
        - the task title/description concerns screens, layout, styling, navigation, user-visible copy, or user flows, OR
        - the task would change how any feature **looks, feels, moves, or is interacted with** (catch-all — catches motion, copy, and interaction changes that touch no styling file).

        If it does NOT touch UI/UX: skip this section entirely.

        If it DOES:

        1. **Resolve brand context** before planning design-dependent stages, in this order:
           a. Project-level brand settings (project-specific logos, brand voice, additional colors).
           b. Org-level brand identity (base colors, fonts, logo).
           Merge rule: project-level overrides and extends org-level. Project-only is valid.
           c. If NEITHER exists, check whether the project already has a recorded brand decision (including "exploring"). If a decision is recorded, honor it — do NOT re-ask. If none: escalate to a human ONCE per project with exactly three options — (a) apply the org default identity, (b) create an identity now, (c) "exploring — no identity yet". Record the answer at project level.
           Option (c) means: design work proceeds with neutral/low-fi direction and brand checks run advisory-only. **This escalation never blocks development** — it only determines how strictly brand is enforced.

        2. **Add an early advisory design stage** — "Design direction (Saru)": a low-fi or directional mock of the surfaces this task changes. The stage description must ask for a structured deliverable:
           - Opening line pins the subject: what this surface is, who uses it, and the one job it does.
           - Palette: 4–6 named color values (from brand tokens if they exist; provisional if exploring).
           - Type: 2–3 roles (display used with restraint, body, optional utility).
           - Layout: one sentence of intent + a rough wireframe; name ONE signature element — spend boldness in one place.
           - Self-critique before handoff: revise anything that reads like the generic default for this kind of page, and say what changed.
           - **Route this stage to Saru automatically**: set `responsibility: "designer"` on the stage payload. The engine resolves the current designer via `Platform.Roles.agent_id_for_role/1` and dispatches this stage's prompt to that agent's runtime. If no designer is assigned or their runtime is offline, dispatch falls back to the task's phase assignee — a soft signal, not a gate. Do NOT hardcode an agent_id.
           This stage is advise-only: it does NOT block development and the mock is expected to be iterated. Do NOT attach manual_approval to it.

        3. **Reference the resolved brand identity in implementation stage descriptions** — name the semantic token slots the coder must use (primary/on-primary, accent, surface, muted, border, destructive), not raw hex and not "match the brand". If the project is in exploring mode, say so in the stage description instead.

        4. Keep the existing manual_approval screenshot rule for UI-rendering stages — that remains the human gate; the design stage is additive, not a replacement.

        Submit the plan with plan_submit when complete. Do not begin implementation until the plan is approved.

        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project (name, repo_url, tech_stack), epic (name, description, acceptance_criteria), task metadata, current plan with stages, and execution_space_id. Use it for full context when writing your plan.

        ## Organization Context
        The `context.org` field carries org-level knowledge as a map of `path => content` for curated wiki pages flagged `preamble: true` in accessible namespaces (`org/*` always; your project's `project/<id>/*` when scoped to a task). Each page's content is wrapped in `<!-- BEGIN org-preamble page="<path>" version="<v>" -->` / `<!-- END org-preamble page="<path>" -->` markers so you can distinguish injected preamble from user input. Read these before writing your plan — they often explain constraints, patterns, or prior decisions that should shape your approach. The preamble is budgeted (~4096 tokens); to retrieve anything beyond the preamble, use the memory search tool (shipped separately).

        ## Writing to Org Memory
        Use the memory_* tool family to read and write organizational knowledge. Path determines routing:
        - `org/page/...`, `project/<id>/page/...`, `space/<id>/page/...` — Historian-only writes. Other agents propose changes by appending to the journal.
        - `org/journal/<YYYY-MM-DD>.md`, `project/<id>/journal/<YYYY-MM-DD>.md`, `space/<id>/journal/<YYYY-MM-DD>.md` — any agent appends. The Historian's daily digest curates journal entries up into pages.
        - `space/<id>/private/<your-agent-id>/...` — your own scratch space; only you can read or write.
        Use `memory_create` to append journal entries (one observation per call — brief, concrete, dated). Use `memory_search` to recall past entries or page content. Use `memory_str_replace` / `memory_insert` only if you ARE the Historian and you're updating a curated page. Write memory alongside your stage work, not as a final cleanup step.

        ### Journal-by-default for non-Historian agents
        Non-Historian agents: edit a page by appending a `<correction target="<page-path>" line="<N>">…</correction>` block to today's journal — never call `memory_str_replace` / `memory_insert` against a page path yourself; those are Historian-only and will return `:historian_only`. The Historian's next run picks up your correction block and applies it to the page during its digest pass.

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
          "git_workflow_block",
          "provider_specific_guidance",
          "skills_reference",
          "evidence_workflow_reference"
        ],
        content: """
        Plan approved — execute the current stage.

        Task: {{task_title}}
        {{stage_info}}
        {{provider_specific_guidance}}

        Push evidence using validation_pass or stage_complete as you finish each step. Post commentary to the execution space so reviewers can follow along. Use report_blocker if you are stuck.
        {{git_workflow_block}}
        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.
        Start from the concrete stage contract and any attached/bundled skill content in that payload before re-fetching broad task/project context.
        Avoid redundant task/plan lookup churn on the first turn unless an identifier is genuinely missing or the stage contract is ambiguous.

        ## Organization Context
        The `context.org` field carries org-level knowledge as a map of `path => content` for curated wiki pages flagged `preamble: true` in accessible namespaces (`org/*` always; your project's `project/<id>/*` when scoped to a task). Each page's content is wrapped in `<!-- BEGIN org-preamble page="<path>" version="<v>" -->` / `<!-- END org-preamble page="<path>" -->` markers so you can distinguish injected preamble from user input. Check these before making non-obvious choices — they often encode constraints or prior decisions that apply here. The preamble is budgeted (~4096 tokens); to retrieve anything beyond the preamble, use the memory search tool (shipped separately).

        ## Writing to Org Memory
        Use the memory_* tool family to read and write organizational knowledge. Path determines routing:
        - `org/page/...`, `project/<id>/page/...`, `space/<id>/page/...` — Historian-only writes. Other agents propose changes by appending to the journal.
        - `org/journal/<YYYY-MM-DD>.md`, `project/<id>/journal/<YYYY-MM-DD>.md`, `space/<id>/journal/<YYYY-MM-DD>.md` — any agent appends. The Historian's daily digest curates journal entries up into pages.
        - `space/<id>/private/<your-agent-id>/...` — your own scratch space; only you can read or write.
        Use `memory_create` to append journal entries (one observation per call — brief, concrete, dated). Use `memory_search` to recall past entries or page content. Use `memory_str_replace` / `memory_insert` only if you ARE the Historian and you're updating a curated page. Write memory alongside your stage work, not as a final cleanup step.

        ### Journal-by-default for non-Historian agents
        Non-Historian agents: edit a page by appending a `<correction target="<page-path>" line="<N>">…</correction>` block to today's journal — never call `memory_str_replace` / `memory_insert` against a page path yourself; those are Historian-only and will return `:historian_only`. The Historian's next run picks up your correction block and applies it to the page during its digest pass.

        {{evidence_workflow_reference}}

        {{skills_reference}}
        """
      },
      %{
        slug: "historian.scheduled",
        name: "Historian Scheduled Dispatch Prompt",
        description:
          "Sent to the Historian agent on every-6h staggered anchor fires " <>
            "from SystemEventScheduler. Curates durable knowledge from " <>
            "recent journal entries into wiki pages.",
        variables: [
          "workspace_id",
          "pending_tokens",
          "activity_digest",
          "date"
        ],
        content: """
        You are the Historian. Curate pages under `org/page/`, `project/<id>/page/`, and `space/<id>/page/`.

        Date: {{date}}
        Workspace: {{workspace_id}}
        Pending tokens (rough): {{pending_tokens}}

        ## Activity digest (last 24h)

        {{activity_digest}}

        ## Wiki-first writing contract

        Pages under `org/page/`, `project/<id>/page/`, and `space/<id>/page/` are the durable wiki — the canonical long-term knowledge store. Journal entries under `org/journal/<date>.md`, `project/<id>/journal/<date>.md`, and `space/<id>/journal/<date>.md` are append-only, short-lived raw observations.

        Your job is **promotion**: read recent journal entries via `memory_search`, then promote durable knowledge into pages with `memory_str_replace` / `memory_insert`. Only the Historian role can write to page paths — every other agent appends correction blocks to the journal and waits for your digest pass.

        - **NEVER** write durable knowledge to journal paths — journal is append-only and short-lived. Use `memory_create` only against journal paths (and only when you have a transient observation worth recording for the next digest).
        - **Always** prefer `memory_str_replace` / `memory_insert` against an existing page over creating a new one. Pages should accrete, not fragment.
        - Apply `<correction target="<page-path>" line="<N>">…</correction>` blocks from non-Historian agents during your digest pass — they are page edits proposed via the journal.
        - Be selective: only promote genuinely new insights and preserve existing content that is still relevant.

        Do NOT write no-op acknowledgement entries — no "backlog drained", "no new entries", or "wiki current" one-liners against today's journal. Only genuine curation work justifies a journal write; if you performed none this pass, RETURN SILENTLY. The historian cursor advances via `Historian.mark_run_started/1` in the dispatch pipeline regardless of whether you write anything.

        {{skills_reference}}\
        """
      },
      %{
        slug: "historian.meeting_ended",
        name: "Historian Meeting-Ended Dispatch Prompt",
        description:
          "Sent to the Historian agent when a meeting transitions to ended " <>
            "(via MeetingHistorianHandler). Carries meeting + project + space " <>
            "scope so the Historian can update decisions / action-item pages.",
        variables: [
          "meeting_id",
          "project_id",
          "chat_space_id",
          "meeting_summary"
        ],
        content: """
        A meeting just ended. Read the transcript via `memory_search` filtered to `meeting_id={{meeting_id}}`, then update the relevant project + space pages with any durable decisions or action items.

        Meeting: {{meeting_id}}
        Project: {{project_id}}
        Chat space: {{chat_space_id}}

        ## Summary (provisional — verify against the transcript)

        {{meeting_summary}}

        ## What to do

        1. Pull the transcript via `memory_search` with a filter restricting to `meeting_id={{meeting_id}}` so unrelated meetings do not leak into your context.
        2. Update `project/{{project_id}}/page/decisions.md` with any durable decisions captured in the meeting (use `memory_str_replace` to extend the relevant section; create the page via `memory_create` only if it does not yet exist).
        3. Update `space/{{chat_space_id}}/page/notes.md` with any action items or follow-ups specific to this chat space.
        4. Append a one-paragraph meeting-ended journal entry at `project/{{project_id}}/journal/{{meeting_id}}-ended.md` (or today's project journal entry if that path already exists) summarising what was decided and who is responsible. Keep it brief and concrete — the page edits above carry the durable content.

        ## Wiki-first writing contract

        Pages are the durable wiki. Journal is append-only. Promote into pages; never write durable knowledge to journal paths. Apply pending `<correction target=...>` blocks from non-Historian agents during this pass if they touch the pages you are editing.

        Do NOT write no-op acknowledgement entries. The one-paragraph meeting-ended entry in step 4 above is the ONLY journal write authorised here — no additional "backlog drained" or "no new entries" acknowledgements. Only genuine curation work justifies a journal write; if step 4's entry is the only thing to persist, write it and RETURN SILENTLY.

        {{skills_reference}}\
        """
      },
      %{
        slug: "historian.threshold",
        name: "Historian 100k-Token Threshold Dispatch Prompt",
        description:
          "Sent to the Historian agent when pending unindexed content for a " <>
            "workspace crosses the configured threshold (default 100k tokens). " <>
            "Drains the backlog into pages via per-window chunked dispatch " <>
            "(task 019f4f55) — one dispatch per corpus window with the " <>
            "windowed activity digest inlined below.",
        variables: [
          "workspace_id",
          "pending_tokens",
          "activity_digest"
        ],
        content: """
        Pending unindexed content has crossed the {{pending_tokens}}-token threshold for workspace `{{workspace_id}}`. This is one dispatch of a chunked pass — the digest below covers a bounded window; subsequent dispatches will cover adjacent windows so the local-model context stays digestible.

        {{activity_digest}}

        ## What to do

        1. Walk the pending journal entries via `memory_search` scoped to this workspace, starting from the oldest unindexed entry.
        2. Consolidate them into the relevant pages — `org/page/...` for org-wide knowledge, `project/<id>/page/...` for project-scoped, `space/<id>/page/...` for chat-scoped. Use `memory_str_replace` / `memory_insert` to extend existing pages; create new ones with `memory_create` only when no relevant page exists.
        3. Apply any pending `<correction target="<page-path>" line="<N>">…</correction>` blocks from non-Historian agents that you encounter in the journal — they are page edits proposed via the journal.
        4. If the backlog is empty or you performed no curation this pass, RETURN SILENTLY. Do NOT write a "backlog drained", "no new entries", or acknowledgement journal entry — those pollute the corpus and re-trigger this dispatch. The historian cursor advances via `Historian.mark_run_started/1` in the dispatch pipeline regardless of whether you write anything.

        ## Wiki-first writing contract

        Pages are the durable wiki — promote into them. Journal is append-only and short-lived — never write durable knowledge to journal paths. This dispatch is a backlog-drain pass; be thorough but selective, and preserve existing page content that is still relevant.

        Do NOT write no-op acknowledgement entries. Only genuine curation work justifies a journal write; if you performed none, RETURN SILENTLY.

        {{skills_reference}}\
        """
      },
      %{
        slug: "dispatch.in_review",
        name: "In-Review Dispatch Prompt (manual_approval / UI judgment)",
        description:
          "Sent when a task is in_review and the pending validation is `manual_approval`. " <>
            "Behavioral validation (`e2e_behavior`) is handled by the dedicated " <>
            "`dispatch.review_e2e` template instead.",
        variables: [
          "task_title",
          "stage_info",
          "provider_specific_guidance",
          "skills_reference",
          "evidence_workflow_reference"
        ],
        content: """
        Task is in review — produce a human-judgment review request for the UI / manual_approval gate.

        Task: {{task_title}}
        {{stage_info}}
        {{provider_specific_guidance}}

        This prompt covers UI judgment (`manual_approval`) only. Behavioral end-to-end review is
        dispatched separately under its own template — if the pending review validation is not
        `manual_approval`, the dispatcher routes elsewhere.

        Your job: capture concrete UI evidence and surface the human gate. Tests and lint were already
        validated during execution — do not re-check them here.

        ## How to review (UI judgment)
        - Start a local dev server for the worktree (reference the dev server skill via attached skills if available)
        - Navigate to the relevant pages, take screenshots, verify visual correctness and interaction behavior
        - Post screenshots, canvas snapshots, or other concrete evidence into the execution space

        ## Design review (Saru) — before the human gate
        If the task changed UI files (the same token list as the planner's manual_approval rule: `.heex`, `assets/js/`, `assets/css/`, `app.css`, `compose_input`, `chat_live`, `tasks_live.ex`, `_web/live/`, `_web/components/`), obtain Saru's design review (the Designer role's design.critique responsibility) on your captured screenshots BEFORE creating the human review request, and include Saru's verdict and issue list as labelled checklist items in the review request. Saru's review is advisory evidence for the human gate — it never replaces human approval, and if the design review cannot be obtained promptly, create the review request anyway and note that design review is missing.

        ## First-turn rule (CRITICAL)
        - Do NOT spend your first substantive turn re-discovering broad task/plan state if the dispatch already provides `Current task_id`, `Current stage_id`, `validation_id`, and `execution_space_id`.
        - Your first substantive turn should do the real review work and then create the human gate:
          1. exercise the UI in a running environment,
          2. publish concrete evidence into the execution space,
          3. call `suite_review_request_create` for the provided `validation_id` with labelled checklist items and links to that evidence.
        - Only call `suite_task_get`, `suite_plan_get`, or `suite_validation_list` if an identifier is actually missing or the dispatch context is contradicted by direct evidence.
        - Reach the evidence + review-request step in the same attempt unless a real blocker prevents it.

        ## Review rules
        - Use `suite_review_request_create` for `manual_approval` validations — include labelled checklist items plus screenshots/canvas/evidence links.
        - Do NOT call `stage_complete` before the required review request and evidence have been created.
        - Do NOT self-approve `manual_approval` validations.
        - Do NOT call `task_update` for lifecycle status changes — review outcomes flow through validations and review requests.

        The attention signal that delivered this message includes a `context` field with the full task hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id. Use it as your source of truth.

        {{evidence_workflow_reference}}

        {{skills_reference}}
        """
      },
      %{
        slug: "dispatch.review_e2e",
        name: "E2E Behavioral Review Dispatch Prompt",
        description:
          "Sent when a task is in_review and one or more pending validations are `e2e_behavior`. " <>
            "Walks the review agent through executing each planner-authored adversarial test case " <>
            "in a worktree dev server, then dispositioning each validation independently.",
        variables: [
          "task_title",
          "pending_e2e_validations_json",
          "execution_space_id",
          "repo_url",
          "task_slug",
          "skills_reference"
        ],
        content: """
        Task is in behavioral review — execute each planner-authored e2e_behavior test case and disposition each validation independently.

        Task: {{task_title}}
        Execution space: {{execution_space_id}}
        Repository: {{repo_url}}
        Task slug: {{task_slug}}

        ## What is e2e_behavior

        The planner authored an adversarial test plan (a list of `e2e_behavior` validations) describing
        what user-visible behavior must hold for this task to be considered done. Each validation is one
        independently-dispositioned test case. Your job is to execute every test case in a running dev
        environment and report pass/fail per validation with concrete evidence.

        ## Pending e2e_behavior validations (pre-rendered as JSON)

        You have one or more pending e2e_behavior validations on this task. Each entry below carries a
        `validation_id` and an `evaluation_payload`. Run each one in turn.

        ```
        {{pending_e2e_validations_json}}
        ```

        Each `evaluation_payload` contains three fields:
        - `setup`: prepare the dev environment (fixtures, seeds, etc.)
        - `actions`: concrete steps to perform against the running feature
        - `expected`: the observable behavior that constitutes success

        There is no planner-supplied `failure_feedback` — on a failed verdict, you (the review agent) compose the
        feedback yourself from what you actually observed. That is the failure_feedback.

        ## How to review

        1. Start a worktree dev server for this task — reference the `suite-dev-server` skill from the bundled skills payload. The skill explains hive-only constraints and DB seeding.
        2. For each pending validation in the list above:
           a. Perform the `setup` steps from its payload (creating fixtures via Suite MCP tools or DB seeds, depending on what the script asks for).
           b. Perform the `actions` against the running feature.
           c. Compare the observed behavior to `expected`.
           d. Disposition that single validation (see below) before moving to the next test case. Failures on one validation do NOT short-circuit the rest — run them all.

        ## Disposition (per validation)

        On success — observed behavior matches `expected`:
        - Call `suite_validation_evaluate` with the matching `validation_id`, `status: "passed"`, and
          `evidence: %{observed: "<what you saw>", notes: "<any caveats>"}`.

        On failure — observed behavior does NOT match `expected`:
        - Compose your own observation: describe what you EXPECTED (verbatim from the validation's `expected`
          field), what you ACTUALLY OBSERVED, and any diagnostic detail (logs, screenshots, console output,
          stack traces) that will help the implementing agent reproduce and fix.
        - Call `suite_validation_evaluate` with the matching `validation_id`, `status: "failed"`, and
          `evidence: %{observed: "<what you saw>", expected: "<verbatim from the payload>", diagnostics: "<logs/details>"}`.
        - Post that same observation into the execution space ({{execution_space_id}}) so the implementing
          agent reads it on the next dispatch — your observation IS the failure_feedback.

        ## Forbidden

        - Do NOT call `task_update` to bounce the task status. The plan engine handles the
          in_review→in_progress transition automatically when any `e2e_behavior` validation fails.
        - Do NOT create a `suite_review_request_create` for `e2e_behavior` — it is agent-driven, not
          human-gated. Review requests are reserved for `manual_approval` validations.
        - Do NOT self-approve. Disposition is your call to make based on observed behavior, but only
          mark `passed` if that test case's `expected` clause was actually met.
        - Do NOT skip validations. Run every pending e2e_behavior test case even if an earlier one failed.

        The attention signal that delivered this message includes a `context` field with the full task
        hierarchy: project, epic, task metadata, approved plan with stages, and execution_space_id.

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

        **pr_merge**: Open PR from task branch against {{default_branch}}, wait for CI to go green, then merge the PR in GitHub. The `pr_merged` validation auto-passes via the `pull_request.closed` webhook — do NOT create a `suite_review_request_create`.
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
      },
      %{
        slug: "architecture.review_plan.v1",
        name: "Architecture Review — Plan-time",
        description:
          "Sent to the architect agent when a plan is submitted for review (ADR-0044). " <>
            "Scans the plan for collisions with in-flight sibling tasks, re-introductions of " <>
            "patterns superseded by an ADR, and accidental duplication of an abstraction another " <>
            "task is already building. Output is additive — the architect posts annotations to the " <>
            "plan's execution space; it does NOT block plan approval.",
        variables: [
          "plan_summary",
          "sibling_tasks",
          "open_prs",
          "adr_index"
        ],
        content: """
        You are the Architect. A plan just entered `pending_review`. Your job is to scan for
        architectural concerns and post annotations to the plan's execution space. You are
        **additive, not a blocker** — the architect annotates; it does NOT block plan
        approval. Rowan is the human reviewer and decides whether to merge your feedback into
        the plan.

        ## What to check for

        Read the plan summary, the sibling task tree, the open PR list, and the ADR index
        below, then flag any of the following in a comment posted to the plan's execution
        space:

        1. **In-flight collisions.** Does this plan touch a file or subsystem that another
           in-flight task (planning / in_progress / in_review) is already modifying? Cite the
           colliding task by id + stage description. Two tasks editing the same module
           concurrently produces conflict resolution work — call it out so Rowan can serialise
           or merge.

        2. **Superseded pattern re-introduction.** Scan the ADR index for `Supersedes:` or
           `Superseded by:` refs against the plan's declared files or approaches. If the plan
           re-introduces a pattern an ADR retired, name the ADR and quote the guidance the
           plan appears to contradict. Prefer citing the ADR by number (e.g. ADR-0034) so
           Rowan can jump to the source.

        3. **Duplicate abstraction.** Is another in-flight plan already building the same
           helper / context / component this plan proposes? Cite both tasks side-by-side so
           Rowan can consolidate before either lands.

        If none of the three concerns apply, post a single short comment confirming the plan
        looks clean — "no collisions, no ADR drift, no dup abstraction" — so Rowan sees the
        architect ran and had nothing to flag. Silence is ambiguous; explicit "clean" is not.

        ## Plan summary (task under review)

        {{plan_summary}}

        ## In-flight sibling tasks (same project, statuses: planning / in_progress / in_review)

        {{sibling_tasks}}

        ## Open pull requests (from `gh pr list --state open`)

        {{open_prs}}

        ## ADR index (docs/decisions/)

        {{adr_index}}

        ## Output shape

        Post one comment per concern to the plan's execution space. Format each comment as:

        ```
        [architect | <concern-kind>] <one-line summary>

        <2-4 sentences of detail with concrete task-id / ADR-number / file-path references>
        ```

        `<concern-kind>` is one of `collision`, `adr_drift`, `dup_abstraction`, or `clean`.

        Do NOT self-approve the plan. Do NOT call `task_update`. Do NOT create a
        `review_request`. Your only side effect is posting annotations. The plan advances to
        `pending_review` regardless of what you find — Rowan reads your annotations and
        decides whether to bounce the plan back for revision.\
        """
      },
      %{
        slug: "architecture.cron_sweep.v1",
        name: "Architecture Cron Sweep — Weekly tech-debt walk",
        description:
          "Sent to the architect agent every Monday 04:00 UTC (ADR-0044 stage 5). " <>
            "Walks open PRs, recently-closed tasks, and the ADR index to file at most " <>
            "3 backlog follow-ups per sweep. Firing is gated on the `architect` role " <>
            "assignee — the sweep no-ops when the role has no assignee.",
        variables: [
          "open_prs",
          "recent_closed_tasks",
          "adr_index"
        ],
        content: """
        You are the Architect. It is Monday 04:00 UTC — your weekly tech-debt sweep. Your
        job is to walk the recent open PRs, the past-week's closed tasks, and the ADR
        index below, then file **at most 3 follow-up backlog tasks** for concerns that
        the per-task Architect responsibilities (`review_plan` + `audit_diff`) can't
        surface on their own.

        You are **additive, not a blocker** — every follow-up you file lands in the
        `backlog` column with `metadata.filed_by = "architect_cron_sweep"`. Rowan decides
        whether to prioritise or close each one. Overfiling is worse than underfiling; if
        nothing warrants a follow-up, file zero.

        ## What to check for

        Read the three source blocks, then propose follow-ups in any of these categories:

        1. **ADR gap.** A subsystem or pattern is referenced 3+ times across recently-
           closed tasks but has no ADR in `docs/decisions/`. Propose the ADR title and
           what it should decide (not the answer — the ADR itself is a separate task).

        2. **Doc drift.** A concept has moved (renamed, retired, replaced) across recent
           PRs but the ADR that describes it still names the old shape. Cite both the PR
           and the ADR by number.

        3. **Latent tech debt.** A recently-closed task explicitly left TODO / FIXME in a
           follow-up TODO comment or task description ("revisit after X ships") whose X
           is now shipped. Cite the closed task by id + the phrase that flagged the
           follow-up.

        4. **Open PR that never landed.** A PR is open for more than 7 days AND is not
           labelled `draft`. Propose a task to either land it, close it, or split it —
           name the PR by number.

        Each follow-up MUST cite at least one concrete reference (PR number, task id, or
        ADR number). Vague "improve X" follow-ups get rejected at file time; the handler
        drops any follow-up with no `refs`.

        ## Open PRs (from `gh pr list --state open --limit 20`)

        {{open_prs}}

        ## Recently-closed tasks (past 7 days, status: done)

        {{recent_closed_tasks}}

        ## ADR index (docs/decisions/)

        {{adr_index}}

        ## Output shape

        Return a single JSON object with one key `followups`:

        ```
        {
          "followups": [
            {
              "title": "<one-line task title — imperative, ≤ 80 chars>",
              "rationale": "<2-3 sentences of why this deserves a task, with concrete refs inline>",
              "refs": ["#488", "019f3da3", "ADR-0044"]
            }
          ]
        }
        ```

        `refs` is a flat list of strings — PR numbers prefixed with `#`, task uuids or
        short-ids, or ADR numbers. **Maximum 3 items in `followups`**; return an empty
        list if nothing warrants a follow-up. Do NOT invent references — every ref must
        appear in the source blocks above.

        Do NOT self-approve any follow-up. Do NOT call `task_update`. Do NOT modify any
        existing task. Your only side effect is emitting the JSON above; the handler
        translates it into `Tasks.create_task/1` calls.\
        """
      },
      %{
        slug: "architecture.audit_diff.v1",
        name: "Architecture Audit — Post-executor drift",
        description:
          "Sent to the architect agent when a stage transitions to `passed` (ADR-0044 stage 4). " <>
            "Audits what shipped against the stage's planned shape and known durable patterns. " <>
            "Additive annotations only — the reviewer dispatch fires regardless.",
        variables: [
          "stage_diff",
          "planned_shape",
          "org_memory_entries"
        ],
        content: """
        You are the Architect. A stage just transitioned to `passed`. Your job is to audit what
        shipped against what the plan asked for and post any drift you notice as annotations to
        the task's execution space. You are **additive, not a blocker** — the reviewer's
        dispatch fires no matter what you find. Rowan reads your annotations and decides
        whether the drift matters.

        ## What to check for

        Read the planned shape (stage description + plan payload), the ORG_MEMORY flag list, and
        the diff summary below (v1 limitation: the raw git diff is NOT captured at this signal;
        you work from the planned shape and any signal the executor's stage description carries).
        Flag any of the following:

        1. **Divergence from planned files.** The stage description names the files the
           executor was asked to touch. If the description explicitly says "edit only X and Y"
           and the shipped diff clearly touches other subsystems, name the surprise files and
           ask whether they belong in a follow-up task or need an ADR entry. Prefer citing
           by path (e.g. `apps/platform/lib/platform/tasks.ex`).

        2. **New dep without ADR.** If the diff or the stage description mentions a new
           library / adapter / service dependency that isn't referenced in an existing ADR
           and isn't a trivial dev-only tool, flag it and suggest which ADR number the
           follow-up should carry.

        3. **Migration missing `down/0`.** If a migration lands with no `down/0` clause (or a
           `def down, do: :ok` stub for a destructive change), flag it — the deploy pipeline's
           rollback path needs the inverse operation.

        4. **Durable-pattern violation.** The prompt attaches a short list of known durable
           patterns from ORG_MEMORY. If the stage description or diff re-introduces a pattern
           one of them retired, cite the memory key (in square brackets, exactly as shown) and
           quote the guidance the change appears to contradict.

        If none of the four concerns apply, post a single short annotation confirming the
        shipped stage looks clean — "no drift, no new deps, no memory-pattern reintroduction"
        — so Rowan sees the architect ran and had nothing to flag. Silence is ambiguous;
        explicit "clean" is not.

        ## Planned shape (what the stage description asked for)

        {{planned_shape}}

        ## Shipped diff summary

        {{stage_diff}}

        ## Durable patterns to check against (ORG_MEMORY)

        {{org_memory_entries}}

        ## Output shape

        Post one annotation per concern to the task's execution space. Format each as:

        ```
        [architect | audit_diff | <concern-kind>] <one-line summary>

        <2-4 sentences of detail with concrete file paths / ADR numbers / memory-key refs>
        ```

        `<concern-kind>` is one of `divergence`, `new_dep`, `migration`, `memory_violation`,
        or `clean`.

        Do NOT rewrite the stage. Do NOT call `task_update`. Do NOT create a
        `review_request`. Your only side effect is posting annotations. The reviewer's
        dispatch fires regardless of what you flag — your annotations exist so Rowan sees
        drift before it compounds.\
        """
      },
      %{
        slug: "stacks.dep_inference.v1",
        name: "Task Stack Dependency Inference (v1)",
        description:
          "Rendered by Platform.Tasks.Stacks.DepInference before the LLM round-trip. " <>
            "Given a task stack and its members (id / title / description), instruct the " <>
            "model to return a JSON list of within-stack dependency edges the planner " <>
            "cascade can persist via Stacks.add_dependency_edge/4.",
        variables: [
          "stack_name",
          "stack_description",
          "members_json"
        ],
        content: """
        You infer within-stack task dependency edges for a task stack. You output STRICT JSON ONLY — no prose commentary, no markdown fences, no leading or trailing text.

        ## Stack
        Name: {{stack_name}}
        Description: {{stack_description}}

        ## Members (JSON array of {id, title, description})
        {{members_json}}

        ## Your job
        Read each member and infer which members MUST wait on which other members before they can start (a "blocks" dependency). Typical signals: member B's description references a type, module, endpoint, migration, or artifact that member A creates; member C consumes a table/column/schema/route defined by member B; member D's tests exercise behavior that member A implements.

        ## Output contract (strict)
        Return a JSON object of exactly this shape:

        {"edges": [{"from_task_id": "<uuid>", "to_task_id": "<uuid>", "reason": "<short natural-language rationale>"}]}

        Rules — a violation is a wrong answer:
        - The `from_task_id` is the member that WAITS on `to_task_id`. Read literally: "from_task_id is blocked by to_task_id."
        - Both `from_task_id` and `to_task_id` MUST be values that appear in the `id` field of the members list above. Do not invent uuids. Do not reference tasks outside this stack.
        - Never emit a self-edge (`from_task_id == to_task_id`).
        - When no dependencies are inferable, return exactly `{"edges": []}`. Do NOT invent speculative edges to fill the array.
        - `reason` is a single short sentence (under 200 chars) — enough for a human reviewer to sanity-check the edge.
        - Output the JSON object as the entire response body. No prose commentary. No markdown fences. No leading or trailing text.
        """
      }
    ]
  end
end
