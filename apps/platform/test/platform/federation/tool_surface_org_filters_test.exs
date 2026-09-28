defmodule Platform.Federation.ToolSurfaceOrgFiltersTest do
  @moduledoc """
  ADR-0042 Stage 4 — org/project filter coverage for the federation
  surface.

  Four cases, mirroring the plan's stage description:

    a. `memory_search` with an `org_id` filter returns only that org's
       journal entries (no cross-tenant bleed).
    b. A tenant agent (metadata.org_id pinned to a tenant) attempting to
       filter `memory_search` by a *sibling* tenant's org_id receives an
       `unauthorized` envelope with the literal substring
       `"not a member of org"` and `recoverable: false`.
    c. `project_list` with an `org_id` filter returns only the projects
       belonging to that org and each row carries `org_id` + `org_slug`.
    d. `org_list_descendants` for the Fabrikam root returns the four seeded
       tenants in slug order; for a tenant, returns `[]`; for an
       unknown id, returns a `:not_found` envelope.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolSurface
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.Repo
  alias Platform.Tasks

  setup do
    # Force the Noop memory provider so the lexical journal channel is
    # the only contributor — keeps assertions deterministic without
    # stubbing a vector index.
    prev_provider = Application.get_env(:platform, :memory_service, [])

    Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)

    on_exit(fn -> Application.put_env(:platform, :memory_service, prev_provider) end)

    # Clear any pre-existing wiki rows so the filter assertions only
    # consider rows this test seeded.
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp create_agent(metadata) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "stage4-#{System.unique_integer([:positive, :monotonic])}",
        name: "Stage4Agent",
        status: "active",
        metadata: metadata
      })
      |> Repo.insert()

    agent
  end

  defp seed_journal_entry(org_id, content) do
    today = Date.utc_today()

    {:ok, entry} =
      Journal.append(
        %{
          content: content,
          date: today,
          org_id: org_id
        },
        namespace: "org"
      )

    entry
  end

  # ── Case (a) — org_id filter scopes memory_search to one tenant ──────

  test "memory_search with org_id filter returns only that org's entries" do
    soylent_id = tenant_org_id("soylent")
    wayne_tech_id = tenant_org_id("wayne_tech")

    _g = seed_journal_entry(soylent_id, "alpha bravo soylent-only marker")
    _p = seed_journal_entry(wayne_tech_id, "alpha bravo wayne_tech-only marker")

    {:ok, %{results: results}} =
      ToolSurface.execute(
        "memory_search",
        %{"query" => "alpha bravo", "source" => "journal", "org_id" => soylent_id},
        %{}
      )

    contents = Enum.map(results, & &1.content)

    assert Enum.any?(contents, &String.contains?(&1, "soylent-only marker")),
           "expected a soylent-tagged hit, got: #{inspect(contents)}"

    refute Enum.any?(contents, &String.contains?(&1, "wayne_tech-only marker")),
           "wayne_tech entry leaked across the org_id filter: #{inspect(contents)}"
  end

  # ── Case (a2) — tenant agent with no filter defaults to home + root ──

  test "tenant-pinned agent with no org_id filter sees only home org + root" do
    # Regression test for V4 e2e failure: a SXI-pinned agent calling
    # memory_search without an explicit org_id used to leak Wayne-Tech
    # (sibling tenant) content because no implicit scope was applied.
    sxi_id = tenant_org_id("sxi")
    wayne_tech_id = tenant_org_id("wayne_tech")
    fabrikam_id = fabrikam_org_id()

    sxi_agent = create_agent(%{"org_id" => sxi_id})

    _sxi = seed_journal_entry(sxi_id, "marker delta sxi-only entry")
    _pt = seed_journal_entry(wayne_tech_id, "marker delta wayne_tech-only entry")
    _ko = seed_journal_entry(fabrikam_id, "marker delta fabrikam-root entry")

    {:ok, %{results: results}} =
      ToolSurface.execute(
        "memory_search",
        %{"query" => "marker delta", "source" => "journal"},
        %{agent_id: sxi_agent.id}
      )

    contents = Enum.map(results, & &1.content)

    assert Enum.any?(contents, &String.contains?(&1, "sxi-only entry")),
           "expected SXI hit, got: #{inspect(contents)}"

    assert Enum.any?(contents, &String.contains?(&1, "fabrikam-root entry")),
           "expected inherited Fabrikam root hit, got: #{inspect(contents)}"

    refute Enum.any?(contents, &String.contains?(&1, "wayne_tech-only entry")),
           "wayne_tech content leaked to SXI agent with no explicit filter: #{inspect(contents)}"
  end

  test "root-equivalent agent (no metadata pin) sees every tenant by default" do
    # Counter-test: a system-equivalent agent (no metadata.org_id)
    # must keep the legacy unscoped behavior so historian / dreaming
    # paths still cross-tenant.
    sxi_id = tenant_org_id("sxi")
    wayne_tech_id = tenant_org_id("wayne_tech")

    sys_agent = create_agent(%{})

    _sxi = seed_journal_entry(sxi_id, "marker epsilon sxi-entry")
    _pt = seed_journal_entry(wayne_tech_id, "marker epsilon wayne_tech-entry")

    {:ok, %{results: results}} =
      ToolSurface.execute(
        "memory_search",
        %{"query" => "marker epsilon", "source" => "journal"},
        %{agent_id: sys_agent.id}
      )

    contents = Enum.map(results, & &1.content)

    assert Enum.any?(contents, &String.contains?(&1, "sxi-entry")),
           "expected SXI hit for root-equivalent agent, got: #{inspect(contents)}"

    assert Enum.any?(contents, &String.contains?(&1, "wayne_tech-entry")),
           "expected Wayne-Tech hit for root-equivalent agent (no implicit filter), got: #{inspect(contents)}"
  end

  # ── Case (b) — tenant agent → sibling-org filter is unauthorized ─────

  test "tenant agent filtering memory_search by a sibling org_id receives unauthorized" do
    soylent_id = tenant_org_id("soylent")
    wayne_tech_id = tenant_org_id("wayne_tech")

    tenant_agent = create_agent(%{"org_id" => soylent_id})

    {:error, envelope} =
      ToolSurface.execute(
        "memory_search",
        %{"query" => "anything", "org_id" => wayne_tech_id},
        %{agent_id: tenant_agent.id}
      )

    assert envelope.recoverable == false
    assert envelope.error =~ "not a member of org"
    assert envelope.error =~ wayne_tech_id
  end

  # ── Case (c) — project_list org_id filter + org_slug serialization ───

  test "project_list with org_id filter returns only that org's projects with org_slug" do
    soylent_id = tenant_org_id("soylent")
    wayne_tech_id = tenant_org_id("wayne_tech")

    {:ok, _soylent_proj} =
      Tasks.create_project(%{name: "Soylent-only Stage4 #{rand()}", org_id: soylent_id})

    {:ok, _wayne_tech_proj} =
      Tasks.create_project(%{name: "WayneTech-only Stage4 #{rand()}", org_id: wayne_tech_id})

    {:ok, %{projects: results}} =
      ToolSurface.execute("project_list", %{"org_id" => soylent_id}, %{})

    names = Enum.map(results, & &1.name)
    assert Enum.any?(names, &String.starts_with?(&1, "Soylent-only Stage4"))
    refute Enum.any?(names, &String.starts_with?(&1, "WayneTech-only Stage4"))

    # Each row carries org_id + org_slug.
    assert Enum.all?(results, fn row -> row.org_id == soylent_id end)
    assert Enum.all?(results, fn row -> row.org_slug == "soylent" end)
  end

  # ── Case (d) — org_list_descendants over root, tenant, unknown ───────

  test "org_list_descendants for the Fabrikam root returns the four seeded tenants in slug order" do
    root_id = fabrikam_org_id()

    {:ok, %{descendants: descendants}} =
      ToolSurface.execute("org_list_descendants", %{"org_id" => root_id}, %{})

    slugs = Enum.map(descendants, & &1.slug)
    assert slugs == ["paragon", "soylent", "wayne_tech", "sxi"]
    assert Enum.all?(descendants, &(&1.role == "tenant"))

    # Every row carries id + slug + name + role.
    assert Enum.all?(descendants, fn d ->
             is_binary(d.id) and is_binary(d.slug) and is_binary(d.name)
           end)
  end

  test "org_list_descendants for a tenant returns an empty list" do
    soylent_id = tenant_org_id("soylent")

    assert {:ok, %{descendants: [], total: 0, has_more: false}} =
             ToolSurface.execute("org_list_descendants", %{"org_id" => soylent_id}, %{})
  end

  test "org_list_descendants for an unknown id returns a not_found envelope" do
    unknown = Ecto.UUID.generate()

    {:error, envelope} =
      ToolSurface.execute("org_list_descendants", %{"org_id" => unknown}, %{})

    assert envelope.code == :not_found
    assert envelope.recoverable == false
    assert envelope.error =~ "org not found"
  end

  # Migrated to dispatch/3 in 019fa609 stage 4. The tool's own check is gone;
  # the gate's message deliberately carries no backticks (see the ToolArguments
  # moduledoc), so the assertion drops them too.
  test "org_list_descendants without org_id returns a recoverable error" do
    {:error, envelope} = ToolArguments.dispatch("org_list_descendants", %{}, %{})
    assert envelope.recoverable == true
    assert envelope.code == :missing_org_id
    assert envelope.error =~ "org_id is required"
  end

  defp rand, do: System.unique_integer([:positive, :monotonic])
end
