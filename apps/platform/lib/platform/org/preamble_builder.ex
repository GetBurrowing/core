defmodule Platform.Org.PreambleBuilder do
  @moduledoc """
  Namespace-aware, inheritance-walking org preamble assembler (ADR 0042 §3).

  Replaces the single-tenant V1 surface in `Platform.Org.Wiki.Context` with
  a builder that honours the two-tier MT/RBAC topology:

    * The operating org is resolved per call (from `task.project.org`, an
      `org_id` opt, or the Fabrikam root fallback).
    * Pages inherit upward along the `parent_org_id` chain so tenant
      preambles automatically include Fabrikam's `org/fabrikam/*` super-context.
    * At the root org, descendant tenants contribute their
      `org/<slug>/IDENTITY.md` summary (and a single `TENANTS_SUMMARY.md`
      from `Platform.Org.TenantsSummary`) so the root sees a roster
      without paying the cost of every tenant's full memory.
    * Project-scoped pages (`project/<id>/*`) load only when the call is
      scoped to a task whose project matches.
    * Space-scoped pages (`space/<id>/*`) load when a chat space is
      attached.

  ## Return shape

  `build/3` returns `%{file_key => annotated_content}` — the same shape
  `Platform.Org.Wiki.Context.build_preamble/1` returns, so the
  `:org` field consumed by
  `Platform.Orchestration.PromptTemplates`'s dispatch + in-progress
  templates keeps rendering without any caller-side change.

  ## Eviction order

  When the assembled set exceeds the budget, entries are evicted in
  priority order — **lower** priority evicts **first**:

      space (0) > org-ancestors (1) > org-direct (2) > project (3)

  This matches the documented order from the ADR (project survives
  longest, space goes first). Eviction fires a
  `[:platform, :org, :preamble_evicted]` telemetry event with the list
  of evicted file_keys and the operating-org scope kind.

  ## Budget

  ~4096 tokens → 16_384 chars (the same 4 chars/token heuristic
  Platform.Org.Wiki.Context uses). Configurable via
  `Application.get_env(:platform, :preamble_token_budget, 4096)` and
  per-call via the `:budget` opt (tokens).

  ## Well-known file keys

  These keys are not enforced anywhere — `file_key` is free-form on the
  schema (the V1 whitelist was retired in ADR 0042 Stage 1). They are
  listed here for documentation only:

    * `org/<slug>/IDENTITY.md`        — per-org identity summary
    * `org/<slug>/MEMORY.md`          — per-org curated knowledge
    * `org/<slug>/AGENTS.md`          — per-org agent roster
    * `org/<root-slug>/TENANTS_SUMMARY.md` — auto-curated tenant roster
      (see `Platform.Org.TenantsSummary`)
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Org.TenantsSummary
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  @default_budget 4096
  @max_depth 16
  @evicted_event [:platform, :org, :preamble_evicted]

  # Documented well-known file keys — not enforced.
  @valid_file_keys ~w(
    org/identity.md
    org/memory.md
    org/agents.md
    org/page/identity.md
    org/page/memory.md
    org/page/agents.md
  )
  @doc "Documented well-known file keys. Not enforced — `file_key` is free-form."
  def valid_file_keys, do: @valid_file_keys

  @typedoc "Operating-org scope kind, surfaced in eviction telemetry."
  @type scope :: :root | :tenant

  @typedoc """
  Priority band for an included page. Lower = evicts first.

    * `0` — `space/*`
    * `1` — `org/*` from an ancestor of the operating org
    * `2` — `org/*` directly on the operating org
    * `3` — `project/*`
  """
  @type priority :: 0..3

  @doc """
  Build the org preamble.

  Returns `%{file_key => annotated_content}` ready to drop into the
  `:org` slot consumed by the dispatch / in-progress prompt templates.

  ## Args

    * `task` — `%Platform.Tasks.Task{}` with `:project` (and ideally
      `[project: :org]`) preloaded, OR `nil`.
    * `space` — `%Platform.Chat.ChatSpace{}` (any struct with `id`) or
      `nil`. When present, `space/<id>/*` pages join the candidate set.

  ## Options

    * `:org_id` — explicit operating-org UUID. Used when `task` is nil
      to resolve a context (e.g. a chat dispatch with no task).
    * `:budget` — token budget. Defaults to
      `Application.get_env(:platform, :preamble_token_budget, 4096)`.
  """
  @spec build(struct() | nil, struct() | nil, keyword()) :: %{String.t() => String.t()}
  def build(task, space, opts \\ []) do
    operating_org = resolve_operating_org(task, opts)
    budget_tokens = Keyword.get(opts, :budget, configured_budget())

    case operating_org do
      nil ->
        # No org topology at all (development DB without seeded orgs).
        # Fall back to an empty preamble rather than crashing.
        %{}

      %Org{} = org ->
        ancestors = ancestor_chain(org)

        entries =
          org
          |> collect_entries(ancestors, task, space)
          |> sort_entries()

        scope = scope_of(org)

        entries
        |> evict_to_budget(budget_tokens, scope)
        |> Map.new(fn entry -> {entry.file_key, entry.annotated} end)
    end
  end

  # ── Operating-org resolution ──────────────────────────────────────────

  @spec resolve_operating_org(struct() | nil, keyword()) :: Org.t() | nil
  defp resolve_operating_org(task, opts) do
    cond do
      org = org_from_task(task) -> org
      org_id = Keyword.get(opts, :org_id) -> Repo.get(Org, org_id)
      true -> root_org()
    end
  end

  # Pull `project.org` off the task. The caller is expected to have
  # preloaded `[:project, project: :org]`; if `:org` is not loaded we
  # fall back to a single `Repo.get/2` so we never crash the dispatch
  # pipeline on a stale preload.
  defp org_from_task(%{project: %{org: %Org{} = org}}), do: org

  defp org_from_task(%{project: %{org_id: org_id}}) when is_binary(org_id),
    do: Repo.get(Org, org_id)

  defp org_from_task(_), do: nil

  defp root_org do
    from(o in Org, where: is_nil(o.parent_org_id), limit: 1)
    |> Repo.one()
  end

  # Walk `parent_org_id` upward, returning the list of ancestors (closest
  # parent first, root last). Capped at `@max_depth` to defend against a
  # corrupt parent chain.
  @spec ancestor_chain(Org.t()) :: [Org.t()]
  defp ancestor_chain(%Org{} = org), do: walk_parents(org, [], @max_depth)

  defp walk_parents(_org, acc, 0), do: Enum.reverse(acc)
  defp walk_parents(%Org{parent_org_id: nil}, acc, _depth), do: Enum.reverse(acc)

  defp walk_parents(%Org{parent_org_id: parent_id}, acc, depth) do
    case Repo.get(Org, parent_id) do
      nil -> Enum.reverse(acc)
      %Org{} = parent -> walk_parents(parent, [parent | acc], depth - 1)
    end
  end

  @spec scope_of(Org.t()) :: scope()
  defp scope_of(%Org{parent_org_id: nil}), do: :root
  defp scope_of(%Org{}), do: :tenant

  # ── Candidate collection ──────────────────────────────────────────────

  # An assembled entry, pre-annotation. `priority` drives eviction
  # ordering (see module docs).
  defp new_entry(%WikiPage{} = page, priority) do
    %{
      file_key: page.file_key,
      page: page,
      priority: priority,
      annotated: annotate(page, page.content),
      tokens: estimate_tokens(annotate(page, page.content))
    }
  end

  @spec collect_entries(Org.t(), [Org.t()], struct() | nil, struct() | nil) ::
          [map()]
  defp collect_entries(%Org{parent_org_id: nil} = root, _ancestors, task, space) do
    # Root org: full org/<root>/* + every descendant's IDENTITY.md
    # (and TENANTS_SUMMARY.md if seeded). No full descendant content.
    #
    # ADR-0042 e2e fix: when the call is *scoped to a task* (even one
    # whose project rolls up directly under the root org), include the
    # `project/<project_id>/*` pages too. Without this, a Fabrikam-rooted
    # project task receives the descendant tenants' IDENTITY.md files
    # but loses its own project preamble — Case 2 of the reviewer's
    # validation. The tenant branch already does this; the root branch
    # also needs it.
    root_pages = preamble_pages_for_org(root.id) |> Enum.map(&new_entry(&1, 2))

    descendant_identity =
      Tenancy.list_tenants()
      |> Enum.flat_map(&identity_entries_for_tenant/1)

    summary = tenants_summary_entry(root)

    project = project_entries(task, root.id)
    space_pages = space_entries(space)

    project ++ root_pages ++ descendant_identity ++ List.wrap(summary) ++ space_pages
  end

  defp collect_entries(%Org{} = tenant, ancestors, task, space) do
    # Tenant org: project/<id>/* (when scoped) + org/<tenant>/* (direct)
    # + org/<ancestor>/* inherited, in walk order.
    direct = preamble_pages_for_org(tenant.id) |> Enum.map(&new_entry(&1, 2))

    inherited =
      ancestors
      |> Enum.flat_map(fn anc ->
        preamble_pages_for_org(anc.id) |> Enum.map(&new_entry(&1, 1))
      end)

    project = project_entries(task, tenant.id)
    space_pages = space_entries(space)

    project ++ direct ++ inherited ++ space_pages
  end

  # Pages flagged `preamble: true` belonging to `org_id` AND living
  # under the `org/<slug>/` or top-level `org/` namespace (we exclude
  # `project/` and `space/` rows that happen to carry the same org_id —
  # those get loaded through their own scoping clauses).
  @spec preamble_pages_for_org(binary()) :: [WikiPage.t()]
  defp preamble_pages_for_org(org_id) do
    from(p in WikiPage,
      where:
        p.org_id == ^org_id and
          is_nil(p.workspace_id) and
          is_nil(p.project_id) and
          like(p.file_key, "org/%"),
      order_by: [asc: p.file_key]
    )
    |> Repo.all()
    |> Enum.filter(&preamble?/1)
  end

  # Per-tenant: ONE IDENTITY.md (if present), priority 1 (ancestor band)
  # because at root scope these are summaries belonging to children.
  defp identity_entries_for_tenant(%Org{slug: slug, id: org_id}) do
    file_key = "org/#{slug}/IDENTITY.md"

    case Repo.one(
           from(p in WikiPage,
             where:
               p.org_id == ^org_id and
                 is_nil(p.workspace_id) and
                 p.file_key == ^file_key,
             limit: 1
           )
         ) do
      nil -> []
      %WikiPage{} = page -> [new_entry(page, 1)]
    end
  end

  defp tenants_summary_entry(%Org{slug: root_slug, id: org_id}) do
    file_key = TenantsSummary.file_key_for(root_slug)

    case Repo.one(
           from(p in WikiPage,
             where:
               p.org_id == ^org_id and
                 is_nil(p.workspace_id) and
                 p.file_key == ^file_key,
             limit: 1
           )
         ) do
      nil -> nil
      %WikiPage{} = page -> new_entry(page, 2)
    end
  end

  defp project_entries(nil, _tenant_id), do: []

  defp project_entries(%{project_id: project_id} = _task, _tenant_id)
       when is_binary(project_id) do
    from(p in WikiPage,
      where:
        p.project_id == ^project_id and
          is_nil(p.workspace_id),
      order_by: [asc: p.file_key]
    )
    |> Repo.all()
    |> Enum.filter(&preamble?/1)
    |> Enum.map(&new_entry(&1, 3))
  end

  defp project_entries(_task, _tenant_id), do: []

  defp space_entries(nil), do: []

  defp space_entries(%{id: space_id}) when is_binary(space_id) do
    prefix = "space/#{space_id}/"

    from(p in WikiPage,
      where: like(p.file_key, ^"#{prefix}%"),
      order_by: [asc: p.file_key]
    )
    |> Repo.all()
    |> Enum.filter(&preamble?/1)
    |> Enum.map(&new_entry(&1, 0))
  end

  defp space_entries(_), do: []

  defp preamble?(%WikiPage{frontmatter: %{"preamble" => true}}), do: true
  defp preamble?(_), do: false

  # ── Ordering ──────────────────────────────────────────────────────────

  # Stable display order: priority DESC (so project lands first), then
  # file_key ASC for determinism. Eviction is a separate concern that
  # walks in priority ASC.
  defp sort_entries(entries) do
    Enum.sort_by(entries, fn e -> {-e.priority, e.file_key} end)
  end

  # ── Budget enforcement ────────────────────────────────────────────────

  # Total token budget = configured (4096) → 16_384 chars at 4 chars/token.
  defp evict_to_budget(entries, budget_tokens, scope) do
    total = Enum.reduce(entries, 0, fn e, acc -> acc + e.tokens end)

    if total <= budget_tokens do
      entries
    else
      {kept, evicted} = drop_until_fits(entries, budget_tokens)

      if evicted != [] do
        :telemetry.execute(
          @evicted_event,
          %{
            evicted_count: length(evicted),
            kept_count: length(kept),
            budget: budget_tokens,
            used_tokens: Enum.reduce(kept, 0, fn e, acc -> acc + e.tokens end)
          },
          %{
            scope: scope,
            evicted_keys: Enum.map(evicted, & &1.file_key)
          }
        )
      end

      kept
    end
  end

  # Drop one entry at a time, lowest priority first (ties broken by
  # file_key DESC so the *last* lex within a tied band evicts before
  # earlier entries — gives deterministic ordering without any
  # cross-test surprises). Stop as soon as the remaining set fits.
  defp drop_until_fits(entries, budget_tokens) do
    sorted_for_eviction =
      Enum.sort_by(entries, fn e -> {e.priority, file_key_desc_key(e.file_key)} end)

    do_drop(sorted_for_eviction, [], budget_tokens)
  end

  # `to_visit` walks the eviction-ordered list. Anything we don't drop
  # lands in `kept`. We compute the running sum of `kept ++ remaining`
  # against the budget after each step.
  defp do_drop([], kept, _budget), do: {Enum.reverse(kept), []}

  defp do_drop([head | tail], kept, budget) do
    remaining_total =
      Enum.reduce(tail, 0, fn e, acc -> acc + e.tokens end) +
        Enum.reduce(kept, 0, fn e, acc -> acc + e.tokens end)

    if remaining_total <= budget do
      # Drop `head`, everything else fits.
      {Enum.reverse(kept) ++ tail, [head]}
    else
      # Drop head and recurse — still over budget without it.
      case do_drop(tail, kept, budget) do
        {final_kept, evicted} -> {final_kept, [head | evicted]}
      end
    end
  end

  # Lex DESC sort key for binaries — invert the bytes by mapping each
  # byte through `255 - b`. Stable across all binary inputs.
  defp file_key_desc_key(key) when is_binary(key) do
    key
    |> :binary.bin_to_list()
    |> Enum.map(fn b -> 255 - b end)
    |> :binary.list_to_bin()
  end

  # ── Annotation ────────────────────────────────────────────────────────

  defp annotate(%WikiPage{} = page, body) do
    begin_marker(page) <> "\n" <> body <> "\n" <> end_marker(page)
  end

  defp begin_marker(%WikiPage{file_key: fk, version: v}) do
    ~s(<!-- BEGIN org-preamble page="#{fk}" version="#{v}" -->)
  end

  defp end_marker(%WikiPage{file_key: fk}) do
    ~s(<!-- END org-preamble page="#{fk}" -->)
  end

  # ── Token estimator ───────────────────────────────────────────────────

  # char/4 heuristic — same convention used by Platform.Org.Wiki.Context
  # and Platform.Agents.Historian.
  defp estimate_tokens(body) when is_binary(body), do: div(byte_size(body), 4)

  # ── Config ────────────────────────────────────────────────────────────

  defp configured_budget do
    Application.get_env(:platform, :preamble_token_budget, @default_budget)
  end

  @doc false
  def evicted_event, do: @evicted_event
end
