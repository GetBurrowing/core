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
  `Platform.Tasks.list_projects/1`).

  Projects whose `:org` association didn't preload (legacy data or a
  preload bug) fall into a synthetic `"_unassigned"` bucket sorted last
  so the sidebar never silently drops a row.

  Callers MUST pass projects with `:org` preloaded
  (`Tasks.list_projects(preload: :org)`) — this function is pure and
  doesn't reach for the Repo.
  """
  @spec group_by_org([map()]) :: [org_group()]
  def group_by_org(projects) when is_list(projects) do
    {assigned, orphan} =
      Enum.split_with(projects, fn p ->
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
end
