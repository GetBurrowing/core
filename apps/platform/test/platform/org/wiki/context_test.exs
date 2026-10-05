defmodule Platform.Org.Wiki.ContextTest do
  @moduledoc """
  Tests for `Platform.Org.Wiki.Context` — the budgeted, scope-aware
  preamble assembler (ADR-0041 T4 stage 2).

  These tests seed pages via `Platform.Org.Wiki.upsert_page/3` and
  exercise the full pure path through `build_preamble_with_metadata/1`.
  The arity-1 public API is exercised through the standard DataCase
  sandbox; no mocks.

  Stage-2 surface only — call-site integration is stage 3; adversarial
  e2e + scope-creep guards are stage 4.
  """
  use Platform.DataCase, async: false

  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Context, as: WikiContext
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)
    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp seed!(file_key, body, opts \\ []) do
    {:ok, page} = Wiki.upsert_page(file_key, %{content: body}, opts)
    page
  end

  defp preamble_body(extra), do: "---\npreamble: true\n---\n" <> extra
  defp non_preamble_body(extra), do: "---\npreamble: false\n---\n" <> extra

  defp begin_marker(file_key, version),
    do: ~s(<!-- BEGIN org-preamble page="#{file_key}" version="#{version}" -->)

  defp end_marker(file_key),
    do: ~s(<!-- END org-preamble page="#{file_key}" -->)

  # ── Empty corpus ──────────────────────────────────────────────────────

  test "empty corpus returns empty map and zeroed metadata" do
    assert {:ok, meta} = WikiContext.build_preamble_with_metadata([])
    assert meta.pages == %{}
    assert meta.used_tokens == 0
    assert meta.dropped == []
    assert meta.truncated == []
    assert WikiContext.build_preamble([]) == %{}
  end

  # ── Single small page ────────────────────────────────────────────────

  test "single small page is included whole with annotation" do
    body = "# Identity\n\nMission: ship Suite.\n"
    page = seed!("org/identity.md", preamble_body(body))

    assert {:ok, meta} = WikiContext.build_preamble_with_metadata([])

    assert Map.keys(meta.pages) == ["org/identity.md"]
    assert meta.dropped == []
    assert meta.truncated == []

    annotated = meta.pages["org/identity.md"]
    assert String.starts_with?(annotated, begin_marker("org/identity.md", page.version))
    assert String.ends_with?(annotated, end_marker("org/identity.md"))
    assert String.contains?(annotated, "Mission: ship Suite.")

    assert meta.used_tokens == div(byte_size(annotated), 4)
  end

  # ── Two pages, both fit ──────────────────────────────────────────────

  test "two small pages both fit; lex-ordered iteration within band" do
    seed!("org/a.md", preamble_body("a body"))
    seed!("org/b.md", preamble_body("b body"))

    assert %{"org/a.md" => a, "org/b.md" => b} = WikiContext.build_preamble([])

    assert String.contains?(a, "a body")
    assert String.contains?(b, "b body")
  end

  # ── Two pages, second overflows ──────────────────────────────────────

  test "lex-later overflow drops with :budget_overrun" do
    # ~3000 chars → ~750 tokens
    seed!("org/a.md", preamble_body(String.duplicate("a", 3000)))
    # ~3000 chars → ~750 tokens. Together ~1500 tokens, both fit in 4096.
    seed!("org/b.md", preamble_body(String.duplicate("b", 3000)))
    # Override budget to a tight 1000 tokens. a uses ~750+overhead; b
    # cannot fit.
    {:ok, meta} = WikiContext.build_preamble_with_metadata(budget: 1000)

    assert Map.has_key?(meta.pages, "org/a.md")
    refute Map.has_key?(meta.pages, "org/b.md")
    assert [%{path: "org/b.md", reason: :budget_overrun}] = meta.dropped
    assert meta.truncated == []
  end

  # ── Single huge page > budget → truncate at paragraph boundary ───────

  test "single huge page is truncated at the nearest \\n\\n boundary with [truncated] sentinel" do
    paragraphs =
      1..40
      |> Enum.map(fn n ->
        "## Section #{n}\n\n" <>
          String.duplicate("Lorem ipsum dolor sit amet consectetur. ", 12) <> "\n"
      end)
      |> Enum.join("\n")

    body = preamble_body(paragraphs)
    page = seed!("org/bigref.md", body)

    {:ok, meta} =
      WikiContext.build_preamble_with_metadata(budget: 500)

    assert Map.keys(meta.pages) == ["org/bigref.md"]
    assert [%{path: "org/bigref.md", lost_tokens: lost}] = meta.truncated
    assert lost > 0
    assert meta.dropped == []

    value = meta.pages["org/bigref.md"]
    assert String.starts_with?(value, begin_marker("org/bigref.md", page.version))
    assert String.ends_with?(value, end_marker("org/bigref.md"))

    # The literal [truncated] sentinel must appear, preceded by \n\n
    # (paragraph-boundary join) and followed by \n then the END marker.
    assert String.contains?(value, "\n\n[truncated]\n" <> end_marker("org/bigref.md"))

    # Used tokens must respect budget.
    assert meta.used_tokens <= 500
  end

  # ── Multiple pages where lex-earlier truncates ───────────────────────
  #
  # When the lex-first page alone exceeds budget, it's truncated and
  # `any_included?` flips. Lex-later pages then evaluate against the
  # remaining (potentially zero or negative) budget. With the truncation
  # consuming the full budget, lex-later pages should drop.

  test "lex-earlier huge truncates; lex-later pages then drop" do
    big = String.duplicate("paragraph body. ", 400) <> "\n\n" <> String.duplicate("more. ", 400)
    seed!("org/aaa-big.md", preamble_body(big))
    seed!("org/zzz-small.md", preamble_body("small content"))

    {:ok, meta} =
      WikiContext.build_preamble_with_metadata(budget: 500)

    # Big truncates.
    assert Map.has_key?(meta.pages, "org/aaa-big.md")
    assert [%{path: "org/aaa-big.md"}] = meta.truncated

    # Small drops because truncation consumed the budget.
    refute Map.has_key?(meta.pages, "org/zzz-small.md")
    assert [%{path: "org/zzz-small.md", reason: :budget_overrun}] = meta.dropped
  end

  # ── Namespace scope: task ────────────────────────────────────────────

  test "task scope includes project/<project_id>/ pages and drops other projects" do
    seed!("org/general.md", preamble_body("global"))
    seed!("project/proj-xyz/runbook.md", preamble_body("xyz body"))
    seed!("project/proj-other/notes.md", preamble_body("other body"))

    task = %Platform.Tasks.Task{project_id: "proj-xyz"}
    {:ok, meta} = WikiContext.build_preamble_with_metadata(task: task)

    assert Map.has_key?(meta.pages, "org/general.md")
    assert Map.has_key?(meta.pages, "project/proj-xyz/runbook.md")
    refute Map.has_key?(meta.pages, "project/proj-other/notes.md")

    scope_dropped = Enum.filter(meta.dropped, &(&1.reason == :scope))
    assert [%{path: "project/proj-other/notes.md", reason: :scope}] = scope_dropped
  end

  # ── Namespace scope: space ───────────────────────────────────────────

  test "space scope includes space/<space_id>/ pages and drops other spaces" do
    seed!("space/s1/pinned.md", preamble_body("s1 body"))
    seed!("space/s2/pinned.md", preamble_body("s2 body"))

    {:ok, meta} = WikiContext.build_preamble_with_metadata(space_id: "s1")

    assert Map.has_key?(meta.pages, "space/s1/pinned.md")
    refute Map.has_key?(meta.pages, "space/s2/pinned.md")

    scope_dropped = Enum.filter(meta.dropped, &(&1.reason == :scope))
    assert [%{path: "space/s2/pinned.md", reason: :scope}] = scope_dropped
  end

  # ── Org-only call ────────────────────────────────────────────────────

  test "org-only call drops both project/ and space/ pages with :scope" do
    seed!("org/identity.md", preamble_body("org body"))
    seed!("project/foo/runbook.md", preamble_body("project body"))
    seed!("space/abc/pinned.md", preamble_body("space body"))

    {:ok, meta} = WikiContext.build_preamble_with_metadata([])

    assert Map.keys(meta.pages) == ["org/identity.md"]
    scope_dropped = Enum.filter(meta.dropped, &(&1.reason == :scope)) |> Enum.map(& &1.path)
    assert Enum.sort(scope_dropped) == ["project/foo/runbook.md", "space/abc/pinned.md"]
  end

  # ── preamble: false pages silently excluded ──────────────────────────

  test "pages without preamble: true are silently excluded (not in dropped)" do
    seed!("org/identity.md", preamble_body("kept"))
    seed!("org/notes.md", non_preamble_body("excluded"))

    {:ok, meta} = WikiContext.build_preamble_with_metadata([])

    assert Map.keys(meta.pages) == ["org/identity.md"]
    assert meta.dropped == []
    refute Enum.any?(meta.dropped, &(&1.path == "org/notes.md"))
  end

  # ── Annotation format ────────────────────────────────────────────────

  test "annotation wraps content in BEGIN/END HTML comment markers with path + version" do
    page = seed!("org/identity.md", preamble_body("hello"))
    %{"org/identity.md" => value} = WikiContext.build_preamble([])

    expected_begin =
      ~s(<!-- BEGIN org-preamble page="org/identity.md" version="#{page.version}" -->)

    expected_end = ~s(<!-- END org-preamble page="org/identity.md" -->)

    assert String.starts_with?(value, expected_begin <> "\n")
    assert String.ends_with?(value, "\n" <> expected_end)
  end

  # ── Budget=0 drops everything ────────────────────────────────────────

  test "budget=0 drops all pages with :budget_overrun and returns empty map" do
    seed!("org/a.md", preamble_body("a"))
    seed!("org/b.md", preamble_body("b"))

    {:ok, meta} = WikiContext.build_preamble_with_metadata(budget: 0)

    assert meta.pages == %{}
    assert meta.used_tokens == 0
    assert meta.truncated == []
    paths = meta.dropped |> Enum.map(& &1.path) |> Enum.sort()
    assert paths == ["org/a.md", "org/b.md"]
    assert Enum.all?(meta.dropped, &(&1.reason == :budget_overrun))
  end

  # ── Configurable budget via :budget opt ──────────────────────────────

  test "per-call :budget opt overrides the configured default" do
    # Body big enough to overflow a tight 50-token budget.
    seed!("org/a.md", preamble_body(String.duplicate("text. ", 200)))

    {:ok, default_meta} = WikiContext.build_preamble_with_metadata([])
    assert map_size(default_meta.pages) == 1

    {:ok, tight_meta} = WikiContext.build_preamble_with_metadata(budget: 50)
    # Tight budget either drops or truncates the page; either way the
    # `:budget` override took effect (default budget would have included
    # the page whole — verified above).
    assert tight_meta.used_tokens <= 50
  end

  # ── Telemetry ────────────────────────────────────────────────────────

  test "telemetry fires with measurements + caller_kind on every call" do
    seed!("org/identity.md", preamble_body("hi"))

    ref = make_ref()
    handler_id = "ctx-telemetry-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      WikiContext.telemetry_event(),
      fn _event, measurements, metadata, pid ->
        send(pid, {:telemetry_event, ref, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # caller_kind: :org
    WikiContext.build_preamble([])
    assert_receive {:telemetry_event, ^ref, m1, %{caller_kind: :org}}
    assert m1.page_count == 1
    assert m1.used_tokens > 0
    assert m1.budget > 0

    # caller_kind: :space
    WikiContext.build_preamble(space_id: "some-space")
    assert_receive {:telemetry_event, ^ref, _m2, %{caller_kind: :space}}

    # caller_kind: :task
    task = %Platform.Tasks.Task{project_id: "abc"}
    WikiContext.build_preamble(task: task)
    assert_receive {:telemetry_event, ^ref, _m3, %{caller_kind: :task}}
  end

  # ── Workspace isolation ──────────────────────────────────────────────

  test "workspace_id scope is honored — no cross-tenant leak" do
    workspace_a = Ecto.UUID.generate()

    seed!("org/global.md", preamble_body("content-A"))
    seed!("org/global.md", preamble_body("content-B"), workspace_id: workspace_a)

    {:ok, default_meta} = WikiContext.build_preamble_with_metadata([])
    {:ok, ws_meta} = WikiContext.build_preamble_with_metadata(workspace_id: workspace_a)

    assert default_meta.pages |> Map.values() |> Enum.join("") |> String.contains?("content-A")
    refute default_meta.pages |> Map.values() |> Enum.join("") |> String.contains?("content-B")

    assert ws_meta.pages |> Map.values() |> Enum.join("") |> String.contains?("content-B")
    refute ws_meta.pages |> Map.values() |> Enum.join("") |> String.contains?("content-A")
  end

  # ── Product docs: burrow/ in band -1 (task 01a10a44 stage 2) ──────────

  describe "burrow/ product docs" do
    @index "burrow/page/index.md"
    @marker ~s(<!-- BEGIN org-preamble page="burrow/page/index.md")

    defp seed_burrow!(file_key, body), do: seed!(file_key, body, product_docs: true)

    test "a tenant-project task preamble carries the index" do
      seed_burrow!(@index, preamble_body("# Burrow Docs\n"))

      project_id = Ecto.UUID.generate()
      pages = WikiContext.build_preamble(task: %{project_id: project_id})

      assert pages[@index] =~ @marker
    end

    test "a space (chat) preamble and an org-only preamble carry it too" do
      seed_burrow!(@index, preamble_body("# Burrow Docs\n"))

      assert WikiContext.build_preamble(space_id: Ecto.UUID.generate())[@index] =~ @marker
      assert WikiContext.build_preamble([])[@index] =~ @marker
    end

    test "CONTROL: with the index row deleted, the marker is absent" do
      seed_burrow!(@index, preamble_body("# Burrow Docs\n"))
      assert WikiContext.build_preamble([])[@index] =~ @marker

      {:ok, _} = Wiki.delete_page(@index, product_docs: true)

      pages = WikiContext.build_preamble([])
      refute Map.has_key?(pages, @index)
      refute Enum.any?(Map.values(pages), &String.contains?(&1, @marker))
    end

    test "under a budget that forces eviction, org pages drop before the index" do
      big = String.duplicate("x", 400)
      # Without band -1 a burrow key falls to the catch-all band 3 and sorts
      # LAST, so the org page would be walked first and the index dropped.
      seed!("org/a.md", preamble_body(big))
      seed_burrow!(@index, preamble_body(big))

      # CONTROL: both ride under the default budget.
      assert map_size(WikiContext.build_preamble([])) == 2

      assert {:ok, meta} = WikiContext.build_preamble_with_metadata(budget: 150)
      assert Map.keys(meta.pages) == [@index]
      assert %{path: "org/a.md", reason: :budget_overrun} in meta.dropped
    end
  end
end
