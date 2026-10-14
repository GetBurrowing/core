defmodule Platform.ProjectsTest do
  @moduledoc """
  Coverage for `Platform.Projects.group_by_org/1` — the shared grouping
  that feeds every active project surface (the Tasks and Files sidebars,
  the New Task / Epic project selects, deploy targets).

  Focus here is the active-only filter added in the lifecycle work
  (task 019f4eaa): archived and deletion-scheduled projects must NOT
  surface in these listings, while the plain `Tasks.list_projects_unscoped/1`
  (used by meeting subscribers and the federation `project_list` tool)
  still returns every row.
  """

  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Projects
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Project
  alias Platform.Tenancy

  # Stamp `archived_at` directly — the column is the only thing the filter
  # reads. The full authz/cascade path is covered in
  # Platform.Tenancy.LifecycleTest.
  defp archive_project!(project) do
    project
    |> Project.changeset(%{archived_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp grouped_project_names do
    Tasks.list_projects_unscoped(preload: :org)
    |> Projects.group_by_org()
    |> Enum.flat_map(fn {_slug, _name, ps} -> Enum.map(ps, & &1.name) end)
  end

  # Navigation-source grouping: every active org, projects nested.
  defp active_sections do
    Projects.group_by_active_org(
      Tasks.list_projects_unscoped(preload: :org),
      Tenancy.list_active_tenants_unscoped()
    )
  end

  defp active_section_slugs, do: Enum.map(active_sections(), fn {slug, _n, _ps} -> slug end)

  defp active_section(slug), do: Enum.find(active_sections(), fn {s, _n, _ps} -> s == slug end)

  describe "group_by_org/1" do
    test "buckets active projects under their owning org in tenant-priority order" do
      {:ok, _} = Tasks.create_project(%{name: "Soylent Tool", org_id: tenant_org_id("soylent")})
      {:ok, _} = Tasks.create_project(%{name: "Acme Tool", org_id: acme_org_id()})

      slugs =
        Tasks.list_projects_unscoped(preload: :org)
        |> Projects.group_by_org()
        |> Enum.map(fn {slug, _name, _ps} -> slug end)

      # The root (parent_org_id nil) sorts ahead of every tenant regardless
      # of insertion order; root_org_slug_test.exs covers a non-acme slug.
      assert slugs == ["acme", "soylent"]
    end

    test "excludes an archived project but keeps its active siblings" do
      {:ok, _active} = Tasks.create_project(%{name: "Active One", org_id: acme_org_id()})
      {:ok, archived} = Tasks.create_project(%{name: "Archived One", org_id: acme_org_id()})
      archive_project!(archived)

      names = grouped_project_names()

      assert "Active One" in names
      refute "Archived One" in names
    end

    test "excludes a deletion-scheduled project (scheduling stamps archived_at)" do
      {:ok, project} = Tasks.create_project(%{name: "Scheduled One", org_id: acme_org_id()})

      project
      |> Project.changeset(%{
        archived_at: DateTime.utc_now(),
        deletion_scheduled_at: DateTime.utc_now()
      })
      |> Repo.update!()

      refute "Scheduled One" in grouped_project_names()
    end

    test "drops an org bucket entirely once its only project is archived" do
      {:ok, only} = Tasks.create_project(%{name: "Lonely SXI", org_id: tenant_org_id("sxi")})
      archive_project!(only)

      slugs =
        Tasks.list_projects_unscoped(preload: :org)
        |> Projects.group_by_org()
        |> Enum.map(fn {slug, _name, _ps} -> slug end)

      refute "sxi" in slugs
    end

    test "regression: Tasks.list_projects_unscoped/1 STILL returns archived projects for all-rows callers" do
      {:ok, archived} = Tasks.create_project(%{name: "Archived For Subs", org_id: acme_org_id()})
      archive_project!(archived)

      all_names = Tasks.list_projects_unscoped() |> Enum.map(& &1.name)
      assert "Archived For Subs" in all_names
    end
  end

  describe "group_by_active_org/2 (navigation source)" do
    test "seeds a section for every active org, even ones with zero projects" do
      # No projects at all — every seeded org still gets a header.
      slugs = active_section_slugs()

      assert "acme" in slugs
      assert "soylent" in slugs
      assert "sxi" in slugs
      assert "wayne_tech" in slugs
      assert "paragon" in slugs
      assert Enum.all?(active_sections(), fn {_s, _n, ps} -> ps == [] end)
    end

    test "keeps an org's header (empty) after its only project is archived" do
      {:ok, only} = Tasks.create_project(%{name: "Lonely SXI", org_id: tenant_org_id("sxi")})
      archive_project!(only)

      # This is the reported bug: group_by_org/1 would DROP sxi here
      # (proven by the sibling test above); group_by_active_org/2 keeps it.
      assert {"sxi", _name, []} = active_section("sxi")
    end

    test "keeps the surviving sibling when one of two projects is archived" do
      {:ok, _keep} = Tasks.create_project(%{name: "Keep Me", org_id: tenant_org_id("soylent")})
      {:ok, gone} = Tasks.create_project(%{name: "Archive Me", org_id: tenant_org_id("soylent")})
      archive_project!(gone)

      {"soylent", _name, projects} = active_section("soylent")
      assert Enum.map(projects, & &1.name) == ["Keep Me"]
    end

    test "emits sections only for orgs in active_orgs — a project of an excluded org can't resurrect it" do
      # active_orgs omitting sxi is exactly what list_active_tenants_unscoped/0 returns
      # once sxi is archived; its still-active project must not bring it back.
      {:ok, _stray} = Tasks.create_project(%{name: "Stray", org_id: tenant_org_id("sxi")})
      projects = Tasks.list_projects_unscoped(preload: :org)
      active_orgs = Enum.reject(Tenancy.list_active_tenants_unscoped(), &(&1.slug == "sxi"))

      slugs = Projects.group_by_active_org(projects, active_orgs) |> Enum.map(&elem(&1, 0))
      refute "sxi" in slugs
    end

    test "leads with Acme and preserves tenant-priority order regardless of insertion order" do
      {:ok, _} = Tasks.create_project(%{name: "A", org_id: tenant_org_id("paragon")})
      {:ok, _} = Tasks.create_project(%{name: "B", org_id: acme_org_id()})

      # Acme first; then canonical tenant priority (excludes the trailing
      # _unassigned bucket, which only appears for org-less projects).
      assert active_section_slugs() == ["acme", "soylent", "wayne_tech", "sxi", "paragon"]
    end

    test "folds org-less projects into a trailing _unassigned bucket" do
      # Pure-function path: a project whose :org didn't resolve to an Org
      # struct (legacy/preload gap) must not be dropped — it lands last.
      orphan = %{id: "orphan-1", name: "Orphan", org: nil, archived_at: nil}

      slugs =
        Projects.group_by_active_org([orphan], Tenancy.list_active_tenants_unscoped())
        |> Enum.map(&elem(&1, 0))

      assert List.last(slugs) == "_unassigned"
    end
  end
end
