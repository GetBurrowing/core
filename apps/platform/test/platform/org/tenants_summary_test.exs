defmodule Platform.Org.TenantsSummaryTest do
  @moduledoc """
  Tests for the ADR 0042 Stage 3 TENANTS_SUMMARY.md curator.

  The curator is deterministic given a stubbed `:llm_fun`, so every case
  here injects one. The real provider path is exercised in production +
  via the SystemEventScheduler integration test.
  """

  use Platform.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Platform.Org.TenantsSummary
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tenancy

  # Stub returns a deterministic paragraph derived from the tenant name +
  # input length so tests can assert on the rendered body without coupling
  # to any LLM output.
  defp stub_llm do
    fn name, raw ->
      {:ok, "#{name} synopsis from #{byte_size(raw)} bytes of input."}
    end
  end

  defp seed_identity_page!(slug, content) do
    {:ok, page} =
      Wiki.upsert_page("org/#{slug}/IDENTITY.md", %{content: content}, workspace_id: nil)

    page
  end

  defp summary_page do
    from(p in WikiPage,
      where: p.file_key == "org/fabrikam/TENANTS_SUMMARY.md" and is_nil(p.workspace_id),
      limit: 1
    )
    |> Repo.one()
  end

  setup do
    # Seeded tenants land via the migration; ensure they're present so
    # the curator has > 0 sections to render.
    tenants = Tenancy.list_tenants()
    assert tenants != [], "expected seeded tenant orgs for this test"

    # Clear any stray pages from prior runs in this sandbox; tests own the
    # whole org_wiki_pages table here.
    Repo.delete_all(WikiPage)
    :ok
  end

  describe "recompute/1 — successful path" do
    test "writes a page with one ## header per tenant in slug-alphabetical order" do
      tenants = Tenancy.list_tenants()

      # Seed an identity page for every tenant so each section gets a
      # real LLM-derived paragraph (not the placeholder).
      Enum.each(tenants, fn t ->
        seed_identity_page!(t.slug, "Identity notes for #{t.name}: focus on quality.")
      end)

      assert {:ok, %WikiPage{file_key: "org/fabrikam/TENANTS_SUMMARY.md"}} =
               TenantsSummary.recompute(llm_fun: stub_llm())

      page = summary_page()
      assert page
      assert page.content =~ "# Tenants Summary"

      # Header order in the rendered body matches slug-alphabetical
      # ordering of the seeded tenants.
      header_order =
        page.content
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "## "))
        |> Enum.map(&String.replace_prefix(&1, "## ", ""))

      expected_order =
        tenants
        |> Enum.sort_by(& &1.slug)
        |> Enum.map(& &1.name)

      assert header_order == expected_order
    end

    test "uses placeholder copy for tenants with no IDENTITY page" do
      # Seed an identity page for ONE tenant; the rest fall through to
      # the placeholder branch.
      [first | _] = Tenancy.list_tenants() |> Enum.sort_by(& &1.slug)
      seed_identity_page!(first.slug, "Has real identity content.")

      assert {:ok, %WikiPage{}} = TenantsSummary.recompute(llm_fun: stub_llm())

      body = summary_page().content
      assert body =~ "#{first.name} synopsis from"

      # Every other tenant produces the placeholder paragraph.
      Tenancy.list_tenants()
      |> Enum.reject(&(&1.slug == first.slug))
      |> Enum.each(fn t ->
        assert body =~ "_#{t.name}: no recent activity recorded._"
      end)
    end

    test "treats whitespace-only IDENTITY content as empty (placeholder)" do
      [first | _] = Tenancy.list_tenants() |> Enum.sort_by(& &1.slug)
      seed_identity_page!(first.slug, "   \n\n   ")

      assert {:ok, %WikiPage{}} = TenantsSummary.recompute(llm_fun: stub_llm())
      body = summary_page().content
      assert body =~ "_#{first.name}: no recent activity recorded._"
    end

    test "is idempotent for unchanged inputs (second call replaces with identical content)" do
      Enum.each(Tenancy.list_tenants(), fn t ->
        seed_identity_page!(t.slug, "Stable identity for #{t.name}.")
      end)

      assert {:ok, %WikiPage{content: c1, id: id1}} =
               TenantsSummary.recompute(llm_fun: stub_llm())

      assert {:ok, %WikiPage{content: c2, id: id2}} =
               TenantsSummary.recompute(llm_fun: stub_llm())

      # Idempotency contract: same body produced for unchanged inputs.
      assert c1 == c2

      # And the curator targets the same canonical row both times — the
      # `(workspace_id, file_key)` unique index keeps duplicates out, so
      # the second call updates rather than inserts a sibling.
      assert id1 == id2
    end
  end

  describe "recompute/1 — failure handling" do
    test "leaves no half-written page when the LLM errors" do
      [first | _] = Tenancy.list_tenants() |> Enum.sort_by(& &1.slug)
      seed_identity_page!(first.slug, "Will fail to summarize.")

      llm_fun = fn _name, _raw -> {:error, :boom} end

      assert {:error, {:llm_failed, slug, :boom}} = TenantsSummary.recompute(llm_fun: llm_fun)
      assert slug == first.slug

      # No partial write — page absent or untouched.
      assert summary_page() == nil
    end

    test "an LLM returning an empty string falls back to the placeholder" do
      [first | _] = Tenancy.list_tenants() |> Enum.sort_by(& &1.slug)
      seed_identity_page!(first.slug, "Real identity content.")

      llm_fun = fn _name, _raw -> {:ok, ""} end

      assert {:ok, %WikiPage{}} = TenantsSummary.recompute(llm_fun: llm_fun)
      assert summary_page().content =~ "_#{first.name}: no recent activity recorded._"
    end
  end

  describe "telemetry" do
    test "emits :tenants_summary_recomputed on success" do
      :telemetry.attach(
        "tenants-summary-test-success",
        [:platform, :org, :tenants_summary_recomputed],
        fn _event, measurements, metadata, pid ->
          send(pid, {:telemetry_recomputed, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach("tenants-summary-test-success") end)

      assert {:ok, %WikiPage{}} = TenantsSummary.recompute(llm_fun: stub_llm())

      assert_receive {:telemetry_recomputed, %{byte_size: bs, tenant_count: tc}, _meta}
      assert bs > 0
      assert tc == length(Tenancy.list_tenants())
    end

    test "emits :tenants_summary_failed on LLM error" do
      :telemetry.attach(
        "tenants-summary-test-failed",
        [:platform, :org, :tenants_summary_failed],
        fn _event, measurements, metadata, pid ->
          send(pid, {:telemetry_failed, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach("tenants-summary-test-failed") end)

      [first | _] = Tenancy.list_tenants() |> Enum.sort_by(& &1.slug)
      seed_identity_page!(first.slug, "Triggers an LLM call that fails.")

      llm_fun = fn _name, _raw -> {:error, :network_blip} end
      assert {:error, _} = TenantsSummary.recompute(llm_fun: llm_fun)

      assert_receive {:telemetry_failed, %{tenant_count: _}, %{reason: _}}
    end
  end

  describe "file_key_for/1" do
    test "expands the root-slug placeholder" do
      assert TenantsSummary.file_key_for("fabrikam") == "org/fabrikam/TENANTS_SUMMARY.md"
      assert TenantsSummary.file_key_for("acme") == "org/acme/TENANTS_SUMMARY.md"
    end
  end
end
