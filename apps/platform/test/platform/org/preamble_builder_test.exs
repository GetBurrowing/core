defmodule Platform.Org.PreambleBuilderTest do
  @moduledoc """
  Tests for `Platform.Org.PreambleBuilder` — the ADR 0042 §3
  namespace-aware preamble assembler that supersedes the V1
  single-tenant surface in `Platform.Org.Wiki.Context`.

  Coverage:

    (a) tenant-SXI task preamble contains SXI + Fabrikam (root super-context)
        files, NOT sibling tenants' files
    (b) root-Fabrikam no-task call returns Fabrikam full + descendant
        IDENTITY.md summaries + TENANTS_SUMMARY.md if seeded; NOT full
        descendant files
    (c) project-scoped files load only when `task.project_id` matches
    (d) tight budget triggers eviction in documented order
        (space first, project last) and fires the
        `[:platform, :org, :preamble_evicted]` telemetry event
  """

  use Platform.DataCase, async: false

  alias Platform.Experiments.Surfaces.ProductDocsPreamble
  alias Platform.Org.BurrowDocs
  alias Platform.Org.PreambleBuilder
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  setup do
    # Stage 2 owns ONE call site (ContextAssembler) but the underlying
    # candidate set is global to the test DB. Clean the table so each
    # case has a deterministic corpus.
    Repo.delete_all(WikiPage)
    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp seed_page!(file_key, body, org_id, opts \\ []) do
    %WikiPage{}
    |> WikiPage.changeset(
      %{
        file_key: file_key,
        content: body,
        org_id: org_id,
        project_id: Keyword.get(opts, :project_id)
      }
      |> Map.merge(Map.new(Keyword.drop(opts, [:project_id])))
    )
    |> Repo.insert!()
    |> tap(fn page ->
      # Mirror Platform.Org.Wiki.upsert_page/3's frontmatter parse: the
      # PreambleBuilder filters on `frontmatter["preamble"] == true`,
      # which is stored on the WikiPage row (not just embedded in the
      # body). Tests bypass `upsert_page/3` so they can pin per-tenant
      # org_id, so we patch the row's frontmatter directly when the
      # body looks preamble-shaped.
      if String.contains?(body, "preamble: true") do
        page
        |> Ecto.Changeset.change(%{frontmatter: %{"preamble" => true}})
        |> Repo.update!()
      end
    end)
  end

  defp preamble_body(extra), do: "---\npreamble: true\n---\n" <> extra

  defp build_task!(project_id) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project_id,
        title: "preamble-builder-test",
        description: "stage 2 fixture",
        status: "backlog"
      })

    # PreambleBuilder reads `task.project.org`, so preload that chain
    # before we hand the struct to the builder.
    Repo.preload(task, project: :org)
  end

  defp seed_project!(org_id, slug_suffix) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Test Project #{slug_suffix}",
        slug: "test-project-#{slug_suffix}",
        org_id: org_id
      })

    project
  end

  # ── (a) tenant scope: SXI gets SXI + Fabrikam, NOT WayneTech ─────────────────

  test "tenant task preamble = own pages + root super-context, no siblings" do
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")
    sxi = Tenancy.get_org_by_slug!("sxi")
    wayne_tech = Tenancy.get_org_by_slug!("wayne_tech")

    seed_page!("org/fabrikam/IDENTITY.md", preamble_body("# Fabrikam identity"), fabrikam.id)
    seed_page!("org/fabrikam/MEMORY.md", preamble_body("# Fabrikam memory"), fabrikam.id)
    seed_page!("org/sxi/IDENTITY.md", preamble_body("# SXI identity"), sxi.id)
    seed_page!("org/wayne_tech/IDENTITY.md", preamble_body("# Wayne-Tech identity"), wayne_tech.id)

    project = seed_project!(sxi.id, "sxi-#{System.unique_integer([:positive])}")
    task = build_task!(project.id)

    result = PreambleBuilder.build(task, nil)

    keys = Map.keys(result)
    assert "org/sxi/IDENTITY.md" in keys
    assert "org/fabrikam/IDENTITY.md" in keys
    assert "org/fabrikam/MEMORY.md" in keys
    # Sibling tenant — explicitly excluded by ADR 0042 §3.
    refute "org/wayne_tech/IDENTITY.md" in keys

    # Sanity: content is annotated with the BEGIN/END markers.
    assert String.contains?(
             result["org/sxi/IDENTITY.md"],
             ~s(<!-- BEGIN org-preamble page="org/sxi/IDENTITY.md")
           )
  end

  # ── (b) root scope: Fabrikam gets full + descendant IDENTITY.md only ──────

  test "root no-task call returns Fabrikam full + descendant IDENTITY summaries" do
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")
    sxi = Tenancy.get_org_by_slug!("sxi")
    soylent = Tenancy.get_org_by_slug!("soylent")

    # Fabrikam's own pages — should appear in full.
    seed_page!("org/fabrikam/IDENTITY.md", preamble_body("# Fabrikam identity"), fabrikam.id)
    seed_page!("org/fabrikam/MEMORY.md", preamble_body("# Fabrikam memory"), fabrikam.id)

    # TENANTS_SUMMARY.md curated by Stage 3; we seed it manually here so
    # we don't need to run the curator.
    seed_page!(
      "org/fabrikam/TENANTS_SUMMARY.md",
      preamble_body("## SXI\n\nSBS does things.\n"),
      fabrikam.id
    )

    # Descendants: IDENTITY only should surface, MEMORY explicitly NOT.
    seed_page!("org/sxi/IDENTITY.md", preamble_body("# SXI identity"), sxi.id)
    seed_page!("org/sxi/MEMORY.md", preamble_body("# SXI memory — do NOT load at root"), sxi.id)

    seed_page!(
      "org/soylent/IDENTITY.md",
      preamble_body("# Soylent identity"),
      soylent.id
    )

    result = PreambleBuilder.build(nil, nil, org_id: fabrikam.id)

    keys = Map.keys(result)
    assert "org/fabrikam/IDENTITY.md" in keys
    assert "org/fabrikam/MEMORY.md" in keys
    assert "org/fabrikam/TENANTS_SUMMARY.md" in keys
    assert "org/sxi/IDENTITY.md" in keys
    assert "org/soylent/IDENTITY.md" in keys
    # The whole point of super-context-at-root: descendants summarize,
    # they don't dump.
    refute "org/sxi/MEMORY.md" in keys
  end

  # ── (b2) root scope + project task: include project/<id>/* too ────────

  test "root-rooted project task preamble includes project pages" do
    # Regression test for V2 e2e failure: a task whose project's org is
    # the Fabrikam root used to silently drop its `project/<id>/*` pages
    # because the root branch of collect_entries/4 never called
    # project_entries/2.
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")
    sxi = Tenancy.get_org_by_slug!("sxi")

    seed_page!("org/fabrikam/IDENTITY.md", preamble_body("# Fabrikam identity"), fabrikam.id)
    seed_page!("org/sxi/IDENTITY.md", preamble_body("# SXI identity"), sxi.id)

    project = seed_project!(fabrikam.id, "fabrikam-#{System.unique_integer([:positive])}")

    seed_page!(
      "project/#{project.id}/SCOPE.md",
      preamble_body("# Suite Infra scope"),
      fabrikam.id,
      project_id: project.id
    )

    task = build_task!(project.id)

    result = PreambleBuilder.build(task, nil)
    keys = Map.keys(result)

    # Project pages must show up even though the operating org is root.
    assert "project/#{project.id}/SCOPE.md" in keys,
           "expected project page under Fabrikam-rooted project; got #{inspect(keys)}"

    # Root super-context still applies.
    assert "org/fabrikam/IDENTITY.md" in keys
    # Descendant tenant IDENTITY.md still surfaces (super-context-at-root).
    assert "org/sxi/IDENTITY.md" in keys
  end

  # ── (c) project-scoped pages gated on task.project_id ─────────────────

  test "project-scoped pages load only when task.project_id matches" do
    sxi = Tenancy.get_org_by_slug!("sxi")
    project_a = seed_project!(sxi.id, "a-#{System.unique_integer([:positive])}")
    project_b = seed_project!(sxi.id, "b-#{System.unique_integer([:positive])}")

    # Project A page: should appear when task is scoped to A.
    seed_page!(
      "project/#{project_a.id}/decisions.md",
      preamble_body("# Project A decisions"),
      sxi.id,
      project_id: project_a.id
    )

    # Project B page: should NEVER appear for a task on project A.
    seed_page!(
      "project/#{project_b.id}/decisions.md",
      preamble_body("# Project B decisions"),
      sxi.id,
      project_id: project_b.id
    )

    # Also seed a tenant-level page so the result isn't empty even if
    # the project filter accidentally excludes everything.
    seed_page!("org/sxi/IDENTITY.md", preamble_body("# SXI"), sxi.id)

    task = build_task!(project_a.id)

    result = PreambleBuilder.build(task, nil)
    keys = Map.keys(result)

    assert "project/#{project_a.id}/decisions.md" in keys
    refute "project/#{project_b.id}/decisions.md" in keys
    assert "org/sxi/IDENTITY.md" in keys
  end

  # ── (d) eviction order + telemetry ────────────────────────────────────

  test "tight budget evicts in documented order and fires telemetry" do
    sxi = Tenancy.get_org_by_slug!("sxi")
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")
    project = seed_project!(sxi.id, "evict-#{System.unique_integer([:positive])}")
    space_id = Ecto.UUID.generate()

    # Four entries, one per priority band. Each is ~400 chars → ~100
    # tokens annotated. Budget at 200 tokens forces at least two
    # evictions; we expect `space` (priority 0) to go first and
    # `project` (priority 3) to survive longest.
    big = String.duplicate("x", 400)

    seed_page!("space/#{space_id}/notes.md", preamble_body(big), fabrikam.id)
    seed_page!("org/fabrikam/IDENTITY.md", preamble_body(big), fabrikam.id)
    seed_page!("org/sxi/IDENTITY.md", preamble_body(big), sxi.id)

    seed_page!(
      "project/#{project.id}/decisions.md",
      preamble_body(big),
      sxi.id,
      project_id: project.id
    )

    task = build_task!(project.id)
    space = %{id: space_id}

    # Attach a telemetry handler so we can capture the eviction event.
    test_pid = self()
    handler_id = "preamble-builder-evict-test-#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      PreambleBuilder.evicted_event(),
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:evicted, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    result = PreambleBuilder.build(task, space, budget: 200)
    keys = Map.keys(result)

    # Project must survive: it's the highest-priority band.
    assert "project/#{project.id}/decisions.md" in keys

    # Space must NOT survive — it's first to evict.
    refute "space/#{space_id}/notes.md" in keys

    # Eviction event should have fired with scope :tenant and the
    # space page in `evicted_keys`.
    assert_receive {:evicted, %{evicted_count: n, kept_count: _, budget: 200}, metadata}
                   when n >= 1

    assert metadata.scope == :tenant
    assert "space/#{space_id}/notes.md" in metadata.evicted_keys
  end

  # ── (e) product docs band: burrow/page, priority 4 (task 01a10a44 s2) ──

  describe "product docs band" do
    @index "burrow/page/index.md"
    @marker ~s(<!-- BEGIN org-preamble page="burrow/page/index.md")

    # Seeded the way BurrowDocs seeds them: root org, nil workspace, via
    # upsert_page so the frontmatter is parsed exactly as in production.
    defp seed_burrow!(file_key, body) do
      root = Tenancy.get_root_org()

      {:ok, page} =
        Wiki.upsert_page(file_key, %{content: body, org_id: root.id}, product_docs: true)

      page
    end

    defp tenant_task! do
      sxi = Tenancy.get_org_by_slug!("sxi")
      project = seed_project!(sxi.id, "burrow-#{System.unique_integer([:positive])}")
      build_task!(project.id)
    end

    setup do
      on_exit(fn ->
        Application.delete_env(:platform, :experiments_surface_resolver)
        :persistent_term.erase({__MODULE__, :resolution})
      end)

      :ok
    end

    test "a TENANT-org task preamble carries the index, though the row is the root org's" do
      index = seed_burrow!(@index, preamble_body("# Burrow Docs\n"))
      task = tenant_task!()

      # The row really belongs to the root org, not the task's tenant.
      refute index.org_id == task.project.org_id

      result = PreambleBuilder.build(task, nil)
      assert result[@index] =~ @marker
    end

    test "a root no-task build carries the index too" do
      seed_burrow!(@index, preamble_body("# Burrow Docs\n"))
      assert PreambleBuilder.build(nil, nil)[@index] =~ @marker
    end

    test "CONTROL: with the index row deleted, the marker is absent" do
      seed_burrow!(@index, preamble_body("# Burrow Docs\n"))
      task = tenant_task!()
      assert PreambleBuilder.build(task, nil)[@index] =~ @marker

      {:ok, _} = Wiki.delete_page(@index, product_docs: true)

      result = PreambleBuilder.build(task, nil)
      refute Map.has_key?(result, @index)
      refute Enum.any?(Map.values(result), &String.contains?(&1, @marker))
    end

    test "an index without preamble: true does not ride, whatever the surface names" do
      seed_burrow!(@index, "# Burrow Docs\n")
      refute Map.has_key?(PreambleBuilder.build(tenant_task!(), nil), @index)
    end

    test "under a budget that forces eviction, org and project pages evict before the index" do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      sxi = Tenancy.get_org_by_slug!("sxi")
      project = seed_project!(sxi.id, "burrow-evict-#{System.unique_integer([:positive])}")
      big = String.duplicate("x", 400)

      seed_burrow!(@index, preamble_body(big))
      seed_page!("org/fabrikam/IDENTITY.md", preamble_body(big), fabrikam.id)
      seed_page!("org/sxi/IDENTITY.md", preamble_body(big), sxi.id)

      seed_page!("project/#{project.id}/decisions.md", preamble_body(big), sxi.id,
        project_id: project.id
      )

      task = build_task!(project.id)

      # CONTROL: under the default budget all four ride, so the eviction
      # below is the budget's doing.
      assert map_size(PreambleBuilder.build(task, nil)) == 4

      # ~120 tokens per entry: 150 fits exactly one.
      result = PreambleBuilder.build(task, nil, budget: 150)

      assert Map.keys(result) == [@index]
    end

    test "the surface's control arm reproduces the no-experiment default" do
      seed_burrow!(@index, preamble_body("# Burrow Docs\n"))
      seed_burrow!("burrow/page/tasks.md", preamble_body("# Tasks\n"))
      task = tenant_task!()

      default = PreambleBuilder.build(task, nil)
      assert {:ok, control} = ProductDocsPreamble.control_payload("dispatch.preamble", [])
      assert control == %{"keys" => ProductDocsPreamble.default_keys()}

      put_resolver({:variant, nil, "control", control})
      assert PreambleBuilder.build(task, nil) == default

      # The default carries the index and NOT the topic, though the topic is
      # preamble-flagged: the surface picks the pages.
      assert Map.has_key?(default, @index)
      refute Map.has_key?(default, "burrow/page/tasks.md")
    end

    test "an arm with no keys carries no product page" do
      seed_burrow!(@index, preamble_body("# Burrow Docs\n"))
      task = tenant_task!()

      put_resolver({:variant, nil, "none", %{"keys" => []}})
      refute Map.has_key?(PreambleBuilder.build(task, nil), @index)
    end

    test "an arm naming the index plus a topic carries both" do
      seed_burrow!(@index, preamble_body("# Burrow Docs\n"))
      seed_burrow!("burrow/page/tasks.md", preamble_body("# Tasks\n"))
      task = tenant_task!()

      put_resolver({:variant, nil, "plus", %{"keys" => [@index, "burrow/page/tasks.md"]}})
      result = PreambleBuilder.build(task, nil)

      assert Map.has_key?(result, @index)
      assert Map.has_key?(result, "burrow/page/tasks.md")
    end

    test "a promoted default payload is honoured" do
      seed_burrow!(@index, preamble_body("# Burrow Docs\n"))
      put_resolver({:default, %{"keys" => []}})
      refute Map.has_key?(PreambleBuilder.build(tenant_task!(), nil), @index)
    end

    test "a raising resolver falls back to the control" do
      seed_burrow!(@index, preamble_body("# Burrow Docs\n"))
      Application.put_env(:platform, :experiments_surface_resolver, __MODULE__.RaisingResolver)
      assert PreambleBuilder.build(tenant_task!(), nil)[@index] =~ @marker
    end

    defp put_resolver(resolution) do
      :persistent_term.put({__MODULE__, :resolution}, resolution)
      Application.put_env(:platform, :experiments_surface_resolver, __MODULE__.StubResolver)
    end
  end

  defmodule StubResolver do
    def resolve("dispatch.product_docs_preamble", "dispatch.preamble", _subject, _opts),
      do: :persistent_term.get({Platform.Org.PreambleBuilderTest, :resolution})

    def resolve(_key, _target, _subject, _opts), do: :none
  end

  defmodule RaisingResolver do
    def resolve(_key, _target, _subject, _opts), do: raise("resolver exploded")
  end

  # ── (f) the index fits its budget: at most 600 tokens annotated ────────

  describe "the Burrow Docs index budget" do
    @max_index_bytes 600 * 4

    defp within_index_budget?(annotated), do: byte_size(annotated) <= @max_index_bytes

    test "the real docs/burrow/index.md, annotated in the preamble, is at most 600 tokens" do
      assert {:ok, _} = BurrowDocs.sync()

      annotated = PreambleBuilder.build(nil, nil)["burrow/page/index.md"]
      assert is_binary(annotated), "the seeded index did not reach the preamble"

      assert within_index_budget?(annotated),
             "index entry is #{byte_size(annotated)} bytes (~#{div(byte_size(annotated), 4)} tokens); cap is 600 tokens"
    end

    test "POSITIVE CONTROL: an index over the cap fails the same check" do
      seed_burrow!(
        "burrow/page/index.md",
        preamble_body(String.duplicate("y", @max_index_bytes))
      )

      annotated = PreambleBuilder.build(nil, nil)["burrow/page/index.md"]
      refute within_index_budget?(annotated)
    end
  end
end
