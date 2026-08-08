defmodule Platform.Projects do
  @moduledoc """
  Cross-surface helpers for the `Platform.Tasks.Project` schema.

  Today this module holds shared formatters/groupers that the Tasks
  sidebar, the Files sidebar, and any future per-project navigation
  surface (Skills assignments, Memory scoping) all need to agree on.
  Lookups + CRUD still live in `Platform.Tasks` — this is a small,
  pure-functional companion, not a second context.

  ## Why not leave `group_by_org` private in TasksLive?

  Stage 5 of ADR 0042 added the org-grouped sidebar to TasksLive
  (PR #438) as a `defp` on the LV. Stage 5 of the Files surface needs
  the exact same grouping (Fabrikam first, then tenants in
  `Tenancy.tenant_priority/0`, orphans last) so the two sidebars never
  silently disagree. Extracting here is cheaper than copy-pasting and
  drifts.
  """

  alias Platform.Tenancy

  @typedoc """
  Output shape: `{org_slug, org_name, [project]}` tuples in canonical
  tenant-priority order. The synthetic `"_unassigned"` bucket folds in
  last for any project whose `:org` association is missing.
  """
  @type org_group :: {String.t(), String.t(), [map()]}

  @doc """
  Buckets `[%Project{org: %Org{}}]` into `[{org_slug, org_name, [project]}]`
  tuples in canonical tenant-priority order.

  Order is `Tenancy.tenant_priority/0` (Fabrikam → Soylent → Wayne-Tech →
  SXI → Paragon → unknown tenants alphabetically). Inside each bucket
  projects keep the caller's existing order (typically alphabetical via
  `Platform.Tasks.list_projects_unscoped/1`).

  Projects whose `:org` association didn't preload (legacy data or a
  preload bug) fall into a synthetic `"_unassigned"` bucket sorted last
  so the sidebar never silently drops a row.

  Archived projects (`archived_at` set) are dropped before grouping, so
  the Tasks and Files sidebars — and every project select fed from this
  grouping (New Task, Epic, deploy targets) — only ever show active rows.
  Deletion-scheduled projects are excluded by the same check: scheduling
  also stamps `archived_at` (see
  `Platform.Tenancy.Lifecycle.schedule_project_deletion/2`). Callers that
  legitimately need archived rows read `Platform.Tasks.list_projects_unscoped/1`
  directly rather than through this grouping.

  Callers MUST pass projects with `:org` preloaded
  (`Tasks.list_projects_unscoped(preload: :org)`) — this function is pure and
  doesn't reach for the Repo.
  """
  @spec group_by_org([map()]) :: [org_group()]
  def group_by_org(projects) when is_list(projects) do
    {assigned, orphan} =
      projects
      |> Enum.reject(&archived?/1)
      |> Enum.split_with(fn p ->
        match?(%Tenancy.Org{}, Map.get(p, :org))
      end)

    assigned
    |> Enum.group_by(fn p -> {p.org.slug, p.org.name} end)
    |> Enum.map(fn {{slug, name}, ps} -> {slug, name, ps} end)
    |> Enum.sort_by(fn {slug, _name, _} ->
      {Tenancy.tenant_priority_index(slug), slug}
    end)
    |> Kernel.++(
      case orphan do
        [] -> []
        _ -> [{"_unassigned", "Unassigned", orphan}]
      end
    )
  end

  @doc """
  Like `group_by_org/1`, but seeds a section for **every active org** — not
  only the orgs that still own a live project.

  `group_by_org/1` derives its buckets from the project list, so an org whose
  last active project was archived produces no tuple and drops out of the
  caller entirely. That's correct for a *selection* surface (a `<select>`
  must not offer an empty `<optgroup>`) but wrong for a *navigation* sidebar:
  the org is still active, still needs its header, and — with the
  archive/delete lifecycle — still needs its own kebab to stay reachable so
  it can itself be archived. This is the navigation source; `group_by_org/1`
  stays the selection source (task 019f4eaa).

  `active_orgs` is `Tenancy.list_active_tenants_unscoped/0`: the root plus every
  non-archived tenant, already in canonical tenant-priority order. Each gets a
  `{slug, name, projects}` tuple carrying its non-archived projects (or `[]`),
  preserving that order. A bucket whose org is NOT in `active_orgs` is dropped
  — an org row that is itself archived must not reappear here on the strength
  of a stray non-archived project, matching the scope rail. The synthetic
  `"_unassigned"` orphan bucket folds in last, exactly as `group_by_org/1`
  produces it.
  """
  @spec group_by_active_org([map()], [Tenancy.Org.t()]) :: [org_group()]
  def group_by_active_org(projects, active_orgs)
      when is_list(projects) and is_list(active_orgs) do
    by_slug =
      projects
      |> group_by_org()
      |> Map.new(fn {slug, _name, _ps} = group -> {slug, group} end)

    active_sections =
      Enum.map(active_orgs, fn org ->
        Map.get(by_slug, org.slug, {org.slug, org.name, []})
      end)

    case Map.get(by_slug, "_unassigned") do
      nil -> active_sections
      orphan -> active_sections ++ [orphan]
    end
  end

  @doc """
  True once `archived_at` is set — the project is hidden from active
  listings. Scheduling deletion also stamps `archived_at`, so this single
  check covers both the archived and pending-deletion states. Tolerant of
  plain maps for the same reason `group_by_org/1` uses `Map.get/2` for `:org`.

  Public because the LiveViews need it for a *routing* decision, not just a
  listing one: an archived project must be treated as a stale selection (see
  `PlatformWeb.TasksLive` `select_project`), since the sidebar filter alone
  can't stop a project id restored from localStorage.
  """
  @spec archived?(map()) :: boolean()
  def archived?(project), do: not is_nil(Map.get(project, :archived_at))
end
