defmodule Platform.Skills do
  @moduledoc """
  Context for the Skills domain (Skill Library).

  Skills are markdown playbooks that describe how agents should work within a
  domain. They can be attached to projects, epics, or tasks and are bundled
  into dispatch context for federated agents.

  ## Inheritance

  `resolve_skills/1` walks the task hierarchy (project → epic → task) and
  returns a deduplicated list of `{skill, source}` tuples. Skills attached at
  the project level apply to all tasks in that project, epic-level skills apply
  to tasks in that epic, and task-level skills are task-specific.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Skills.{Skill, SkillAttachment}
  alias Platform.Tasks.Task

  # ── CRUD ─────────────────────────────────────────────────────────────────

  @doc "List all skills, ordered by name."
  def list_skills do
    Skill
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  @doc "Get a skill by ID."
  def get_skill(id) do
    # `skill_get` accepts a slug OR an id and skills/tool_handlers.ex:49 routes
    # any non-empty binary straight here, so a slug reaching the id branch is
    # DESIGNED traffic, not a malformed input. nil sends it to the slug branch.
    if Platform.UUID.valid?(id), do: Repo.get(Skill, id), else: nil
  end

  @doc "Get a skill by slug."
  def get_skill_by_slug(slug), do: Repo.get_by(Skill, slug: slug)

  @doc "Create a new skill."
  def create_skill(attrs) do
    %Skill{}
    |> Skill.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing skill."
  def update_skill(%Skill{} = skill, attrs) do
    skill
    |> Skill.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a skill. Cascades to all attachments."
  def delete_skill(%Skill{} = skill) do
    Repo.delete(skill)
  end

  # ── Attachments ──────────────────────────────────────────────────────────

  @doc """
  Attach a skill to an entity (project, epic, or task).

  Returns `{:ok, attachment}` or `{:error, changeset}`. The unique constraint
  on `(skill_id, entity_type, entity_id)` prevents duplicate attachments.
  """
  def attach_skill(skill_id, entity_type, entity_id) do
    %SkillAttachment{}
    |> SkillAttachment.changeset(%{
      skill_id: skill_id,
      entity_type: entity_type,
      entity_id: entity_id
    })
    |> Repo.insert()
  end

  @doc """
  Detach a skill from an entity.

  Returns `:ok` or `{:error, :not_found}`.
  """
  def detach_skill(skill_id, entity_type, entity_id) do
    case Repo.get_by(SkillAttachment,
           skill_id: skill_id,
           entity_type: entity_type,
           entity_id: entity_id
         ) do
      nil ->
        {:error, :not_found}

      attachment ->
        {:ok, _} = Repo.delete(attachment)
        :ok
    end
  end

  @doc """
  Return all skills attached to a specific entity.
  """
  def skills_for_entity(entity_type, entity_id) do
    Skill
    |> join(:inner, [s], sa in SkillAttachment,
      on: sa.skill_id == s.id and sa.entity_type == ^entity_type and sa.entity_id == ^entity_id
    )
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  @doc """
  Resolve all skills for a task by walking the hierarchy.

  Returns a list of `{%Skill{}, source}` tuples where source is
  `"project"`, `"epic"`, or `"task"`. Skills are deduplicated by ID —
  task-level wins over epic, epic over project.
  """
  @spec resolve_skills(String.t()) :: [{Skill.t(), String.t()}]
  def resolve_skills(task_id) do
    # `task_id` arrives on a run-dispatch payload (ContextHydrator).
    task = if Platform.UUID.valid?(task_id), do: Repo.get(Task, task_id)

    case task do
      nil ->
        []

      task ->
        task = Repo.preload(task, [:project, :epic])

        # Gather skills at each level, task first (for dedup priority)
        task_skills = skills_with_source("task", task.id)

        epic_skills =
          if task.epic, do: skills_with_source("epic", task.epic.id), else: []

        project_skills =
          if task.project, do: skills_with_source("project", task.project.id), else: []

        # Task-level wins, then epic, then project (dedup by skill.id)
        (task_skills ++ epic_skills ++ project_skills)
        |> Enum.uniq_by(fn {skill, _source} -> skill.id end)
    end
  end

  @doc """
  Seed the default skills registry from the hardcoded `do_default_skills/0`
  list.

  Mirrors `Platform.Orchestration.PromptTemplates.seed_defaults/0` at
  `apps/platform/lib/platform/orchestration/prompt_templates.ex` lines
  100–113: iterate a hardcoded descriptor list, gate on
  `get_skill_by_slug/1` so an existing row is a no-op, `create_skill/1`
  on miss. The slug auto-derives from the descriptor's `name` via
  `Skill.changeset/2`'s `generate_slug/1` (see
  `apps/platform/lib/platform/skills/skill.ex:28`).

  Idempotent — a second call is a no-op (all rows already exist), no
  changeset error.
  """
  @spec seed_defaults() :: :ok
  def seed_defaults do
    Enum.each(do_default_skills(), fn skill ->
      slug = derive_slug(skill.name)

      case get_skill_by_slug(slug) do
        nil ->
          {:ok, _} = create_skill(skill)

        _existing ->
          :skip
      end
    end)

    :ok
  end

  @doc """
  Return all entities a skill is attached to, grouped by entity_type.

  Returns `%{"project" => [{id, name}], "epic" => [...], "task" => [...]}`.
  """
  def entities_for_skill(skill_id) do
    attachments =
      SkillAttachment
      |> where([sa], sa.skill_id == ^skill_id)
      |> Repo.all()

    grouped = Enum.group_by(attachments, & &1.entity_type)

    %{
      "project" => resolve_entity_names("project", Map.get(grouped, "project", [])),
      "epic" => resolve_entity_names("epic", Map.get(grouped, "epic", [])),
      "task" => resolve_entity_names("task", Map.get(grouped, "task", []))
    }
  end

  # ── Private ──────────────────────────────────────────────────────────────

  # Mirrors `Skill.generate_slug/1` (see
  # `apps/platform/lib/platform/skills/skill.ex:28`) so `seed_defaults/0`
  # can compute the auto-derived slug without inserting first. Keep the
  # rules identical: downcase, strip non-alphanumeric / non-space /
  # non-hyphen, collapse whitespace to hyphens, collapse repeats, trim
  # leading/trailing hyphens.
  defp derive_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  # Hardcoded default skills, seeded via `seed_defaults/0`. The seed path
  # is insert-only-if-missing so re-running is safe. New defaults are
  # appended here and picked up by a migration that calls
  # `Platform.Skills.seed_defaults()`.
  defp do_default_skills do
    [
      %{
        name: "Meeting Triage Officer",
        description:
          "How the triage-officer runtime consumes a scribe-completion canvas " <>
            "and files tasks: parse conventions, project resolution rules, " <>
            "assignee inference, priority parsing, and the idempotency contract " <>
            "with `Platform.Meetings.Triage.file_tasks_from_canvas/2`.",
        content: meeting_triage_officer_skill_body()
      }
    ]
  end

  defp meeting_triage_officer_skill_body do
    """
    # Meeting Triage Officer

    You are the triage officer converting a meeting's scribe-completion canvas
    into concrete tasks. The `dispatch.triage_dispatch` runtime prompt tells
    you *what to do*; this skill pins the *conventions* — the JSON shape,
    the matching threshold, the assignee-inference rules, and the
    idempotency contract — so every triage pass produces the same shape.

    ## 1. Signal shape

    Call `meeting_triage_file` with `meeting_id`, `run_id`, `transcript_id`,
    `canvas_id`, `snapshot_hash` copied from the completion dispatch, plus
    `action_items`. Read `completion_transcript` (the full ordered segments
    across `source_transcript_ids`), not a summary or latest chunk alone.
    Each filed item requires `item_id` equal to the canonical checklist_item
    node id, normalized imperative `title`, grounded `description`, and
    nonempty `source_segment_ids` drawn from that snapshot. Never use raw
    utterances as titles. Questions and canvas edits remain canvas-only.
    Synthesis duplicate/conflict/exclude decisions use the same item_id with
    `decision`; these create no tasks. Never call task_create independently.
    The tool invokes the internal Triage function with its dedup and caps.
    Reuse the same run, snapshot_hash and canonical item ids on retry,
    including after a filed task is done. When the signal carries canvas_id,
    update that existing canvas and preserve checklist node ids for the same
    work. Never replace the canvas or mint new ids for previously reviewed
    work. Only the first run without canvas_id uses canvas_create.
    Report callback failures and wait
    for a refreshed dispatch if the snapshot changed.

    The `meeting_triage_dispatch` attention signal (broadcast by
    `Platform.Federation.dispatch_triage_attention/2`) carries the canonical
    meeting_id, run_id, transcript_id, canvas_id and snapshot_hash, plus full
    completion_transcript and source_transcript_ids. It also carries:

    - `space_id` — the chat space the meeting lives in.
    - `room_id` — the meeting room the transcript belongs to.
    - `transcript_id` — the source transcript feeding this triage pass.
    - `canvas_id` — the scribe-completion canvas whose contents you consume.

    The canvas the scribe posts has a `checklist` section titled `actions`.
    Its children are `checklist_item` nodes — one per candidate task the
    scribe surfaced from the transcript. Everything you file comes from
    walking those `checklist_item` children.

    ## 2. Parse conventions

    Each `checklist_item` carries two fields you read:

    - `checklist_item.label` — the human-readable action string. This
      is candidate evidence. Normalize it to an imperative task title and
      a grounded description before submitting it through meeting_triage_file.
    - `checklist_item.note` — a JSON blob with keys:
      - `owner` — string, e.g. `"@dev"` or `"@nobody_matches"`. May be `nil`.
      - `project_hint` — string, e.g. `"Widgets Platform"`. May be `nil`.
      - `priority` — one of `"low" | "medium" | "high" | "critical"`. May be missing.
      - `due_hint` — free-text like `"this week"` or `"next sprint"`. May
        be `nil`.
      - `source_transcript_id` — UUID of the transcript that surfaced
        this action.

    Parse with `Jason.decode/1`. Fallback rules on malformed JSON — do
    NOT crash, degrade gracefully:

    - Whole `note` string is not JSON → treat the entire string as a
      free-text description; leave `owner`, `project_hint`, `due_hint`,
      `source_transcript_id` as `nil`; default `priority` to `"medium"`.
    - Key is missing from a valid JSON object → treat that individual key
      as `nil` (or its default, for `priority`).
    - `source_transcript_id` missing → fall back to the dispatch's
      `transcript_id` (the outer attention-signal value).

    ## 3. Project resolution

    For each parsed item:

    1. Call `project_list` to fetch every project the actor can see.
    2. Score each project's `name` against the parsed `project_hint`
       using `String.jaro_distance/2`.
    3. If the highest score is `>= 0.85`, accept that project as the
       target and mark the row's status `filed`.
    4. Otherwise fall back to the project that owns the source canvas's
       space (resolve via `space_id → project_id`). Mark that row's
       status `fallback_project` so the summary card distinguishes it
       from a jaro-matched `filed` row.
    5. If `project_hint` is `nil`, skip step 2–3 and go straight to the
       fallback branch.

    The `0.85` threshold is deliberately tight enough to reject
    `"Widgets Platform"` vs `"unknown_gibberish_xyz"` (score ≈ 0.4) and
    accept `"Widgets Platform"` vs `"widgets-platform"` (score ≈ 0.9).
    Do not soften it without a corresponding change to
    `dispatch.triage_dispatch`.

    ## 4. Assignee inference

    Resolve `owner` mentions through the `principal_search` MCP tool:

    - A well-formed `@handle` string (leading `@`, then a handle) →
      call `principal_search` with the handle.
    - Exactly one hit → take that principal's `agent_id` as the task's
      `assignee_id`.
    - Zero hits, multiple ambiguous hits, or a malformed `owner` string
      → return `nil`. Let the runtime fall through to the task's
      `phase_assignee` (the project's or epic's default). Do NOT guess.

    Do not invent assignees. Do not fuzzy-match handles. Explicit or
    absent — nothing in between.

    ## 5. Priority parsing + idempotency

    Priority map (`low|medium|high|critical`, case-insensitive on the JSON string):

    - `"high"` → `high`
    - `"medium"` → `medium`
    - `"low"` → `low`
    - `"critical"` → `critical`
    - anything else (unrecognised string, missing key, `nil`) → `medium`

    ## Priority forwarding and batch control

    Copy the parsed note priority into `priority` on every filed `action_items` entry.
    Normalize note strings case-insensitively: `low` → `low`, `medium` → `medium`,
    `high` → `high`, `critical` → `critical`. Missing, nil, malformed or unrecognized
    note priorities default to `medium`. This is a note-parsing fallback only:
    an invalid explicit API priority is refused by `meeting_triage_file`, not silently
    normalized. Send a valid lowercase enum value and preserve canonical run/item
    identities, transcript grounding and candidate provenance.
    The server owns the single batch junk control; do not append another
    "Junk this batch" control, including on replay.

    ### Idempotency contract

    Server-side Triage owns title dedup; the persisted completion run owns
    stable run/item replay, including done tasks. The meeting_triage_file
    response contains meeting_id, run_id, status, canvas_id and task_ids.
    Report success only when status is filed; delivery alone is not filing.
    The response is cumulative for this run, so a replay returning the same
    task_ids does not mean new tasks were created. Record duplicate/conflict
    decisions as exclusions, without inventing task ids or per-item verdicts
    absent from the tool response. Reuse canonical item ids on every retry.
    """
  end

  defp skills_with_source(entity_type, entity_id) do
    Skill
    |> join(:inner, [s], sa in SkillAttachment,
      on: sa.skill_id == s.id and sa.entity_type == ^entity_type and sa.entity_id == ^entity_id
    )
    |> order_by([s], asc: s.name)
    |> Repo.all()
    |> Enum.map(fn skill -> {skill, entity_type} end)
  end

  defp resolve_entity_names("project", attachments) do
    ids = Enum.map(attachments, & &1.entity_id)

    Platform.Tasks.Project
    |> where([p], p.id in ^ids)
    |> select([p], {p.id, p.name})
    |> Repo.all()
  end

  defp resolve_entity_names("epic", attachments) do
    ids = Enum.map(attachments, & &1.entity_id)

    Platform.Tasks.Epic
    |> where([e], e.id in ^ids)
    |> select([e], {e.id, e.name})
    |> Repo.all()
  end

  defp resolve_entity_names("task", attachments) do
    ids = Enum.map(attachments, & &1.entity_id)

    Platform.Tasks.Task
    |> where([t], t.id in ^ids)
    |> select([t], {t.id, t.title})
    |> Repo.all()
  end
end
