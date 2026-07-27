defmodule Platform.Design.Brand do
  @moduledoc """
  Resolves the brand context a design step works inside, and asks — at most
  once per project — how strictly to enforce it (ADR 0046).

  ## Brand decides HOW STRICTLY, never WHETHER

  `resolve/1` returns a plain map. No error tuple, no `nil` return, no clause
  that can raise: every source it reads is optional and every read is guarded.
  That is the mechanism behind "brand never blocks development" — not a comment
  and not a convention callers have to honour. **A caller cannot block on this
  function because there is no value to block on.** The only thing brand moves
  is `enforcement`, which is `:strict` or `:advisory`.

  ## Storage — no table, no migration

  Brand context here is PROSE a designer reads (palette names, type roles,
  voice), which is exactly what the wiki page store already holds, namespaced
  by `file_key` prefix:

    * org brand     — `org/page/brand.md`
    * project brand — `project/<project_id>/page/brand.md`
    * the recorded decision — `project.config["brand_decision"]`, shaped
      `%{"mode" => ..., "recorded_at" => iso8601, "recorded_by" => id | nil}`

  A `brands` table was rejected: it would duplicate the page store and hand the
  designer a worse artifact than the page a human would write anyway.

  ### There is exactly ONE org brand page per deployment

  `org_wiki_pages` is uniquely indexed on
  `(COALESCE(workspace_id, '00000000-0000-0000-0000-000000000000'), file_key)`
  — migration `20260408180000_create_org_context_tables`, which spells the
  index out in raw SQL precisely so a `NULL` workspace does not make rows
  distinct. So an org-scoped `org/page/brand.md` is **global**: a second tenant
  org cannot own a row under that key. `Platform.Org.Wiki.Routing`'s page regex
  admits only the `org`, `project/<uuid>` and `space/<uuid>` namespaces, so
  `org/<tenant-slug>/page/brand.md` is not a writable memory path either.

  Per-tenant differentiation is therefore expressed at PROJECT scope. A reader
  expecting `resolve/1` to select a different org page per tenant org will be
  wrong, and the wrongness is in the schema, not here.

  ## Merge rule — project OVERRIDES and EXTENDS org, implemented as ORDER

  These are prose pages, not key-value settings; there is nothing to deep-merge
  and no token to shadow. "Override" is implemented as **document order**:
  `guidance` carries the org body first under `#{"## Org brand"}`, then the
  project body under `#{"## Project brand"}`, and states in one sentence that
  the project section wins on any conflict. A reader expecting a deep merge of
  design tokens will misread this function; the ordering IS the merge.

  Project-only is valid on its own and yields `:project_only` + `:strict`. An
  org page is not a prerequisite for a project having a brand.

  ## Enforcement

  `:strict` when any page resolved. `:advisory` when none did — including a
  recorded `"exploring"` and a recorded `"asked"`. An empty or
  frontmatter-only page counts as **absent**: enforcing strictly against a
  blank document is enforcing against nothing, and it would also suppress the
  escalation that would have got a real page written.

  ## Asked once per PROJECT, not once per task

  `escalate_once/2` fires only when both pages are absent AND no decision is
  recorded. It posts ONE message to the task's execution space enumerating
  exactly three options — apply the org default identity, create an identity
  now, or exploring/no identity yet — and in the SAME call records
  `%{"mode" => "asked"}` on the project. A second task in the same project then
  resolves as `:recorded` and returns `{:ok, :already_recorded}` without
  posting.

  An Inbox row was rejected for the escalation: `Platform.Inbox.Item`'s
  `@kinds` is a guarded enum and `PlatformWeb.Components.InboxItem` renders
  per-kind, so a new kind is a UI change. This is a question about enforcement
  strictness, not a work item, and the execution space already carries the
  task's human-facing conversation.

  ## Which way this fails, and why

  Every degradation fails **open**, because the alternative to a wrong brand is
  a stalled task:

    * **A brand page is unreadable** (DB error, malformed `project_id`) →
      treated as absent → `:unresolved` + `:advisory`. Design proceeds with no
      brand rather than not proceeding.
    * **The recorded decision is malformed** (e.g. `%{"mode" => 7}`) → read as
      NO decision. This is the one degradation that costs something: it
      re-opens the re-ask loop. It is exactly why `project_update` exposes a
      named `brand_decision` enum instead of letting an agent write `config`
      freely — `Project.changeset/2` does not validate `config`'s shape, so a
      free-form write is a shape that lands here.
    * **The execution space cannot be resolved** → the decision is STILL
      recorded and `{:ok, :asked}` still returned. Losing the question once is
      strictly better than asking it on every task forever.
    * **The decision write itself fails** → `escalate_once/2` still returns
      `{:ok, :asked}` and logs a warning. The caller has nothing useful to do
      with a failure here and the only alternative outcome is a repeated
      question later — never a block.

  The single case that does NOT fail open is `record_decision/3` with an
  unknown mode: that returns `{:error, {:invalid_brand_decision, mode}}`,
  because it is a caller bug, is reached only from the MCP surface, and
  silently writing an unknown mode would poison the once-per-project cache.
  """

  require Logger

  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Tasks
  alias Platform.Tasks.Project

  @org_page_key "org/page/brand.md"
  @decision_key "brand_decision"

  @org_heading "## Org brand"
  @project_heading "## Project brand"

  @override_sentence "Where the project section conflicts with the org section, the project section wins."

  @advisory_sentence "Enforcement is ADVISORY: apply taste and internal consistency, note drift, and do not block on brand."

  # Modes a human or agent can choose. `"asked"` is deliberately absent —
  # it is written by `escalate_once/2` and is not something anyone selects.
  @recordable_modes ~w(org_default identity exploring)
  @modes @recordable_modes ++ ["asked"]

  @typedoc "Which sources produced the brand context."
  @type mode :: :org_and_project | :project_only | :org_only | :recorded | :unresolved

  @typedoc "How strictly the designer enforces. Never whether work proceeds."
  @type enforcement :: :strict | :advisory

  @typedoc """
  `org_page` / `project_page` are the page **bodies** (frontmatter stripped,
  trimmed), not their file keys — the keys are derivable from
  `org_page_key/0` and `project_page_key/1`, the bodies are not.
  """
  @type t :: %{
          mode: mode(),
          enforcement: enforcement(),
          org_page: String.t() | nil,
          project_page: String.t() | nil,
          decision: map() | nil,
          guidance: String.t()
        }

  @doc "File key of the (single, deployment-global) org brand page."
  @spec org_page_key() :: String.t()
  def org_page_key, do: @org_page_key

  @doc "File key of a project's brand page."
  @spec project_page_key(String.t()) :: String.t()
  def project_page_key(project_id) when is_binary(project_id),
    do: "project/#{project_id}/page/brand.md"

  @doc """
  Modes a caller may record through `record_decision/3` or the
  `project_update` MCP tool.

  There is exactly one copy of this list. The MCP surface builds its
  parameter description and its validation from this function rather than
  restating the three strings, so a drifting copy is not possible.
  """
  @spec recordable_modes() :: [String.t()]
  def recordable_modes, do: @recordable_modes

  @doc """
  Resolve the brand context for a task.

  Accepts a `Platform.Tasks.Task` struct or any map carrying `:project_id`
  (and, for `escalate_once/2`, `:id`).

  Never returns an error tuple, never returns `nil`, never raises.
  """
  @spec resolve(map()) :: t()
  def resolve(task) when is_map(task) do
    project_id = Map.get(task, :project_id)
    project = fetch_project(project_id)

    org_body = fetch_page(@org_page_key)
    project_body = fetch_project_page(project_id)
    decision = decision_of(project)

    build(org_body, project_body, decision)
  end

  @doc """
  Ask the project — once, ever — how strictly to enforce brand.

  Fires only when both brand pages are absent AND no decision is recorded.
  Posts one log message to the task's execution space and records
  `%{"mode" => "asked"}` on the project in the same call.

  Options:

    * `:recorded_by` — id of the agent or user on whose behalf the
      escalation is recorded. Stored verbatim in the decision map.

  Returns `{:ok, :asked}` when it fired, `{:ok, :already_recorded}` when a
  decision already exists, `{:ok, :not_needed}` when a brand page resolved or
  the task has no project to record against. Never `{:error, _}`.
  """
  @spec escalate_once(map(), keyword()) :: {:ok, :asked | :already_recorded | :not_needed}
  def escalate_once(task, opts \\ []) when is_map(task) do
    case resolve(task) do
      %{mode: :recorded} -> {:ok, :already_recorded}
      %{mode: :unresolved} -> do_escalate(task, opts)
      %{mode: _resolved_from_a_page} -> {:ok, :not_needed}
    end
  end

  @doc """
  Record a brand decision on a project's `config["brand_decision"]`.

  `mode` must be one of `recordable_modes/0`, or `"asked"` (written by
  `escalate_once/2`). Anything else is a caller bug and returns
  `{:error, {:invalid_brand_decision, mode}}` rather than poisoning the
  once-per-project cache with a mode nothing can read back.
  """
  @spec record_decision(Project.t(), String.t(), keyword()) ::
          {:ok, Project.t()} | {:error, term()}
  def record_decision(project, mode, opts \\ [])

  def record_decision(%Project{} = project, mode, opts) when is_binary(mode) do
    if mode in @modes do
      decision = %{
        "mode" => mode,
        "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "recorded_by" => stringish(Keyword.get(opts, :recorded_by))
      }

      config =
        project.config
        |> normalize_config()
        |> Map.put(@decision_key, decision)

      Tasks.update_project(project, %{config: config})
    else
      {:error, {:invalid_brand_decision, mode}}
    end
  end

  def record_decision(%Project{}, mode, _opts), do: {:error, {:invalid_brand_decision, mode}}

  @doc """
  The escalation body, exposed so the wording can be asserted without
  reaching through a chat message row.

  Enumerates exactly three options. Nothing here blocks; the last line says so.
  """
  @spec escalation_message(Project.t()) :: String.t()
  def escalation_message(%Project{} = project) do
    """
    **Brand direction — asked once per project.**

    `#{project.name}` has no brand page (`#{project_page_key(project.id)}`) and
    there is no org brand page (`#{@org_page_key}`). Design work proceeds
    either way. This only sets how strictly the designer enforces an identity.

    (a) **Apply the org default identity** — `project_update(project_id: "#{project.id}", brand_decision: "org_default")`
    (b) **Create an identity now** — write `#{project_page_key(project.id)}` and it is picked up on the next task, or record the intent with `project_update(project_id: "#{project.id}", brand_decision: "identity")`
    (c) **Exploring, no identity yet** — `project_update(project_id: "#{project.id}", brand_decision: "exploring")`

    Until one of those lands, brand enforcement is advisory. Nothing is blocked, and this question is not asked again for this project.
    """
  end

  # ── Resolution ────────────────────────────────────────────────────────────

  defp build(org, project, decision) do
    {mode, enforcement} =
      case {org, project} do
        {o, p} when is_binary(o) and is_binary(p) -> {:org_and_project, :strict}
        {nil, p} when is_binary(p) -> {:project_only, :strict}
        {o, nil} when is_binary(o) -> {:org_only, :strict}
        {nil, nil} when is_map(decision) -> {:recorded, :advisory}
        {nil, nil} -> {:unresolved, :advisory}
      end

    %{
      mode: mode,
      enforcement: enforcement,
      org_page: org,
      project_page: project,
      decision: decision,
      guidance: guidance_for(mode, org, project, decision)
    }
  end

  defp guidance_for(:org_and_project, org, project, _decision) do
    """
    Brand context resolved from two pages. #{@override_sentence}

    #{@org_heading}

    #{org}

    #{@project_heading}

    #{project}
    """
  end

  defp guidance_for(:org_only, org, _project, _decision) do
    """
    Brand context resolved from the org brand page. This project has no brand page of its own, so the org brand applies unmodified.

    #{@org_heading}

    #{org}
    """
  end

  defp guidance_for(:project_only, _org, project, _decision) do
    """
    Brand context resolved from the project brand page. There is no org brand page; a project-only brand is complete on its own and is enforced.

    #{@project_heading}

    #{project}
    """
  end

  defp guidance_for(:recorded, _org, _project, %{"mode" => mode}) do
    """
    No brand page exists for this org or project. A brand decision is on record: `#{mode}`.

    #{@advisory_sentence}
    """
  end

  defp guidance_for(:unresolved, _org, _project, _decision) do
    """
    No brand page exists for this org or project and no brand decision is on record.

    #{@advisory_sentence}
    """
  end

  # ── Escalation ────────────────────────────────────────────────────────────

  defp do_escalate(task, opts) do
    case fetch_project(Map.get(task, :project_id)) do
      %Project{} = project ->
        post_question(task, project)
        record_asked(project, opts)
        {:ok, :asked}

      nil ->
        # No project means nowhere to record "asked", so posting would ask the
        # same question on every task in perpetuity. Stay silent; brand is
        # already advisory and nothing is blocked.
        Logger.info(
          "[design.brand] task #{inspect(Map.get(task, :id))} has no resolvable project; " <>
            "skipping the brand escalation rather than asking un-recordably"
        )

        {:ok, :not_needed}
    end
  end

  defp post_question(task, %Project{} = project) do
    with task_id when is_binary(task_id) <- Map.get(task, :id),
         %{id: space_id} <- ExecutionSpace.find_by_task_id(task_id),
         {:ok, _message} <- ExecutionSpace.post_log(space_id, escalation_message(project)) do
      :ok
    else
      other ->
        Logger.warning(
          "[design.brand] could not deliver the brand escalation for project #{project.id} " <>
            "(#{inspect(other)}); recording the decision anyway so it is not re-asked"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[design.brand] brand escalation delivery raised #{inspect(error.__struct__)} for " <>
          "project #{project.id}; recording the decision anyway"
      )

      :ok
  end

  defp record_asked(%Project{} = project, opts) do
    case record_decision(project, "asked", opts) do
      {:ok, updated} ->
        {:ok, updated}

      other ->
        Logger.warning(
          "[design.brand] could not record the brand escalation for project #{project.id} " <>
            "(#{inspect(other)}); the question may be asked again"
        )

        :error
    end
  end

  # ── Sources ───────────────────────────────────────────────────────────────

  defp fetch_project_page(project_id) when is_binary(project_id) and project_id != "" do
    fetch_page(project_page_key(project_id))
  end

  defp fetch_project_page(_), do: nil

  defp fetch_page(file_key) do
    case Wiki.get_page(file_key) do
      %WikiPage{content: content} -> page_body(content)
      _ -> nil
    end
  rescue
    error ->
      Logger.warning(
        "[design.brand] brand page #{file_key} unreadable " <>
          "(#{inspect(error.__struct__)}); treating it as absent"
      )

      nil
  end

  # Frontmatter is metadata, not brand prose — a designer handed raw YAML is
  # worse off than one handed nothing. A page that is empty once frontmatter
  # is stripped is ABSENT, not resolved.
  defp page_body(content) when is_binary(content) do
    {_frontmatter, body} = Wiki.parse_frontmatter(content)

    case String.trim(body) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp page_body(_), do: nil

  defp fetch_project(project_id) when is_binary(project_id) and project_id != "" do
    case Ecto.UUID.cast(project_id) do
      {:ok, uuid} -> Tasks.get_project(uuid)
      :error -> nil
    end
  rescue
    error ->
      Logger.warning(
        "[design.brand] project #{inspect(project_id)} unreadable " <>
          "(#{inspect(error.__struct__)}); resolving brand without it"
      )

      nil
  end

  defp fetch_project(_), do: nil

  defp decision_of(%Project{config: config}) when is_map(config) do
    config |> Map.get(@decision_key) |> normalize_decision()
  end

  defp decision_of(_), do: nil

  # Anything that is not a map carrying a KNOWN string `"mode"` reads as no
  # decision. See the moduledoc: this is the one degradation with a cost, and
  # the MCP enum is what keeps it unreachable in practice.
  defp normalize_decision(%{"mode" => mode} = decision) when is_binary(mode) do
    if mode in @modes do
      %{
        "mode" => mode,
        "recorded_at" => stringish(Map.get(decision, "recorded_at")),
        "recorded_by" => stringish(Map.get(decision, "recorded_by"))
      }
    else
      nil
    end
  end

  defp normalize_decision(_), do: nil

  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(_), do: %{}

  defp stringish(value) when is_binary(value), do: value
  defp stringish(_), do: nil
end
