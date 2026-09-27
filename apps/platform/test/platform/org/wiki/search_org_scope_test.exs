defmodule Platform.Org.Wiki.SearchOrgScopeTest do
  @moduledoc """
  Pins the `:org_id` opt of `Platform.Org.Wiki.Search.search/2` after the
  two byte-identical private `filter_org/2` copies (and the near-copy
  `filter_task_org/2`) were folded onto `Platform.Tenancy.scope/3`.

  The behaviour change under test is `[]`: it used to return the queryable
  UNTOUCHED (fail open) and now maps to `:none` (matches nothing). `nil` is
  deliberately unchanged — it is the absence of a question, not a resolved
  "no orgs" answer — and the legacy workspace-only path depends on that.

  Every scoping assertion carries a positive control in the same test body,
  because "zero rows" is also what an empty index returns.
  """
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Org.Wiki.Search
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.Repo
  alias Platform.Tasks.{Project, Task}

  @query "chokepoint"

  setup do
    prev = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)
    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)

    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)

    :ok
  end

  defp seed_page(org_id) do
    %WikiPage{}
    |> WikiPage.changeset(%{
      file_key: "org/page/scope_#{System.unique_integer([:positive])}.md",
      content: "a #{@query} page",
      org_id: org_id
    })
    |> Repo.insert!()
  end

  defp seed_task(org_id) do
    project =
      %Project{}
      |> Project.changeset(%{
        name: "Scope Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })
      |> Repo.insert!()

    %Task{}
    |> Task.changeset(%{
      project_id: project.id,
      title: "a #{@query} task",
      description: "a #{@query} task"
    })
    |> Repo.insert!()
  end

  defp hit_ids(opts) do
    {:ok, %{results: results}} = Search.search(@query, opts)
    Enum.map(results, & &1.id)
  end

  describe "page/journal scoping via org_id" do
    test "org_id: [] returns zero rows from a fixture proven to hold matching rows" do
      page = seed_page(tenant_org_id("sxi"))

      # ANTI-VACUITY: without this control the assertion below would pass
      # against an index that simply contains nothing.
      assert page.id in hit_ids(source: :page)

      assert hit_ids(source: :page, org_id: []) == []
    end

    test "org_id: nil still returns the legacy workspace-only rows" do
      page = seed_page(tenant_org_id("sxi"))

      assert page.id in hit_ids(source: :page, org_id: nil)
    end

    test "org_id: [a, b] returns A's and B's rows and NOT C's" do
      a = tenant_org_id("sxi")
      b = tenant_org_id("soylent")
      c = tenant_org_id("wayne_tech")

      pa = seed_page(a)
      pb = seed_page(b)
      pc = seed_page(c)

      ids = hit_ids(source: :page, org_id: [a, b])

      assert pa.id in ids
      assert pb.id in ids
      refute pc.id in ids
    end

    test "org_id: a single binary returns only that org's rows" do
      a = tenant_org_id("sxi")
      pa = seed_page(a)
      pb = seed_page(tenant_org_id("soylent"))

      ids = hit_ids(source: :page, org_id: a)

      assert pa.id in ids
      refute pb.id in ids
    end
  end

  describe "task scoping via the projects join" do
    test "org_id: [] returns zero tasks from a fixture proven to hold matching tasks" do
      task = seed_task(tenant_org_id("sxi"))

      assert task.id in hit_ids(source: :task)

      assert hit_ids(source: :task, org_id: []) == []
    end

    test "org_id: nil still returns tasks" do
      task = seed_task(tenant_org_id("sxi"))

      assert task.id in hit_ids(source: :task, org_id: nil)
    end

    test "org_id: [a, b] returns A's and B's tasks and NOT C's" do
      a = tenant_org_id("sxi")
      b = tenant_org_id("soylent")
      c = tenant_org_id("wayne_tech")

      ta = seed_task(a)
      tb = seed_task(b)
      tc = seed_task(c)

      ids = hit_ids(source: :task, org_id: [a, b])

      assert ta.id in ids
      assert tb.id in ids
      refute tc.id in ids
    end
  end
end
