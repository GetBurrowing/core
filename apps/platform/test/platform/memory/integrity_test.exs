defmodule Platform.Memory.IntegrityTest do
  @moduledoc """
  Behaviour tests for `Platform.Memory.Integrity.scan/1`.

  Fixture pattern mirrors `Platform.Org.WikiTest`: fresh page table per
  test, seed pages via `Wiki.upsert_page/3` (which materializes the
  link table under the hood), then assert on categorization.

  MemoryFeedback delete rows are inserted directly rather than via the
  full `record_delete/1` path — the scan reads the ledger, it doesn't
  care about the write shape.
  """
  use Platform.DataCase, async: true

  alias Platform.Memory.Integrity
  alias Platform.MemoryFeedback
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(Platform.MemoryFeedback.Entry)
    :ok
  end

  # ── Bucket identification ────────────────────────────────────────────

  describe "scan/1 — broken bucket" do
    test "surfaces a link whose target does not exist and cannot basename-resolve" do
      {:ok, source} =
        Wiki.upsert_page("org/page/notes.md", %{content: "see [[org/page/absent.md]]"})

      report = Integrity.scan()

      assert %{broken: [entry], format_dirty: [], retired_target: []} = report
      assert entry.source_id == source.id
      assert entry.source_path == "org/page/notes.md"
      assert entry.target_path == "org/page/absent.md"
      assert entry.resolved_target_path == nil
      assert entry.reason =~ "no basename match"
    end

    test "path-shaped target that doesn't exist stays in broken (basename won't match `/`)" do
      {:ok, _source} =
        Wiki.upsert_page("org/page/notes.md", %{content: "see [[some/nested/path.md]]"})

      report = Integrity.scan()

      assert %{broken: [_], format_dirty: [], retired_target: []} = report
    end
  end

  describe "scan/1 — format_dirty bucket" do
    test "bare-slug link whose basename resolves unambiguously moves to format_dirty" do
      {:ok, _target} = Wiki.upsert_page("org/page/identity.md", %{content: "canonical"})
      {:ok, source} = Wiki.upsert_page("org/page/notes.md", %{content: "see [[identity]]"})

      report = Integrity.scan()

      assert %{broken: [], format_dirty: [entry], retired_target: []} = report
      assert entry.source_id == source.id
      assert entry.source_path == "org/page/notes.md"
      assert entry.target_path == "identity"
      assert entry.resolved_target_path == "org/page/identity.md"
      assert entry.reason =~ "basename resolves"
    end

    test "bare-slug with .md suffix also resolves" do
      {:ok, _target} = Wiki.upsert_page("org/page/identity.md", %{content: "canonical"})
      {:ok, _source} = Wiki.upsert_page("org/page/notes.md", %{content: "see [[identity.md]]"})

      assert %{format_dirty: [%{resolved_target_path: "org/page/identity.md"}]} =
               Integrity.scan()
    end

    test "ambiguous basename (2+ matches) stays broken, not format_dirty" do
      {:ok, _a} = Wiki.upsert_page("org/page/foo.md", %{content: "a"})
      {:ok, _b} = Wiki.upsert_page("org/page/nested/foo.md", %{content: "b"})
      {:ok, _source} = Wiki.upsert_page("org/page/notes.md", %{content: "see [[foo]]"})

      report = Integrity.scan()

      assert %{broken: [_], format_dirty: [], retired_target: []} = report
    end
  end

  describe "scan/1 — retired_target bucket" do
    test "link whose target is in MemoryFeedback deletes surfaces as retired_target" do
      # Seed a delete row at the target path in the default org_context
      # namespace with a NULL workspace_id (org scope matches the source
      # page's org scope).
      insert_org_delete("org/page/retired.md")

      {:ok, source} =
        Wiki.upsert_page("org/page/notes.md", %{content: "see [[org/page/retired.md]]"})

      report = Integrity.scan()

      assert %{broken: [], format_dirty: [], retired_target: [entry]} = report
      assert entry.source_id == source.id
      assert entry.target_path == "org/page/retired.md"
      assert entry.resolved_target_path == nil
      assert entry.reason =~ "previously deleted"
    end

    test "retired_target takes precedence over broken when both signals match" do
      insert_org_delete("org/page/absent.md")

      {:ok, _source} =
        Wiki.upsert_page("org/page/notes.md", %{content: "see [[org/page/absent.md]]"})

      report = Integrity.scan()

      assert %{broken: [], retired_target: [_]} = report
    end

    test "retired_target takes precedence over format_dirty when both signals match" do
      # A page named `identity.md` currently exists AND the same path was
      # previously deleted — retired wins.
      {:ok, _target} = Wiki.upsert_page("org/page/identity.md", %{content: "reincarnated"})
      insert_org_delete("identity")

      {:ok, _source} = Wiki.upsert_page("org/page/notes.md", %{content: "see [[identity]]"})

      report = Integrity.scan()

      assert %{format_dirty: [], retired_target: [_], broken: []} = report
    end
  end

  # ── Workspace scoping ────────────────────────────────────────────────

  describe "scan/1 — workspace scoping" do
    test "workspace_id: nil scans org-scoped pages only" do
      ws = Ecto.UUID.generate()

      {:ok, _} =
        Wiki.upsert_page("org/page/x.md", %{content: "see [[org/page/gone.md]]"})

      {:ok, _} =
        Wiki.upsert_page(
          "org/page/x.md",
          %{content: "see [[org/page/other.md]]"},
          workspace_id: ws
        )

      report = Integrity.scan()

      assert %{broken: [entry]} = report
      assert entry.source_path == "org/page/x.md"
      assert entry.target_path == "org/page/gone.md"
    end

    test "workspace-scoped scan excludes org-scoped dangling links" do
      ws = Ecto.UUID.generate()

      {:ok, _} =
        Wiki.upsert_page("org/page/x.md", %{content: "see [[org/page/gone.md]]"})

      {:ok, _} =
        Wiki.upsert_page(
          "org/page/x.md",
          %{content: "see [[org/page/other.md]]"},
          workspace_id: ws
        )

      report = Integrity.scan(workspace_id: ws)

      assert %{broken: [entry]} = report
      assert entry.target_path == "org/page/other.md"
    end

    test "delete rows in a different workspace do not classify as retired" do
      ws_a = Ecto.UUID.generate()
      ws_b = Ecto.UUID.generate()

      # Seed a delete in ws_a for target 'shared.md'
      insert_delete("shared.md", ws_a)

      # Source in ws_b references the same path — should be broken, not retired
      {:ok, _} =
        Wiki.upsert_page(
          "org/page/notes.md",
          %{content: "see [[shared.md]]"},
          workspace_id: ws_b
        )

      report = Integrity.scan(workspace_id: ws_b)

      assert %{broken: [_], format_dirty: [], retired_target: []} = report
    end
  end

  # ── Cap ──────────────────────────────────────────────────────────────

  describe "scan/1 — bucket cap" do
    test "caps at :cap entries per bucket (default is 500; use small cap for the test)" do
      # 12 pages each linking to a distinct dangling target
      for i <- 1..12 do
        {:ok, _} =
          Wiki.upsert_page(
            "org/page/src_#{String.pad_leading(Integer.to_string(i), 3, "0")}.md",
            %{content: "see [[org/page/missing_#{i}.md]]"}
          )
      end

      report = Integrity.scan(cap: 5)

      assert %{broken: broken} = report
      assert length(broken) == 5
    end
  end

  # ── Empty state ──────────────────────────────────────────────────────

  describe "scan/1 — empty state" do
    test "returns three empty buckets when nothing is dangling" do
      {:ok, _} = Wiki.upsert_page("org/page/a.md", %{content: "no links"})

      assert %{broken: [], format_dirty: [], retired_target: []} = Integrity.scan()
    end

    test "returns three empty buckets when the DB is completely fresh" do
      assert %{broken: [], format_dirty: [], retired_target: []} = Integrity.scan()
    end
  end

  # ── Scope filter ─────────────────────────────────────────────────────

  describe "scan/1 — scope prefix" do
    test ":org restricts source pages to file_key starting with 'org/'" do
      {:ok, _org} =
        Wiki.upsert_page("org/page/notes.md", %{content: "see [[org/page/gone.md]]"})

      {:ok, _proj} =
        Wiki.upsert_page("project/foo/notes.md", %{content: "see [[project/foo/gone.md]]"})

      report = Integrity.scan(scope: :org)

      assert %{broken: [entry]} = report
      assert entry.source_path == "org/page/notes.md"
    end

    test ":project restricts source pages to file_key starting with 'project/'" do
      {:ok, _org} =
        Wiki.upsert_page("org/page/notes.md", %{content: "see [[org/page/gone.md]]"})

      {:ok, _proj} =
        Wiki.upsert_page("project/foo/notes.md", %{content: "see [[project/foo/gone.md]]"})

      report = Integrity.scan(scope: :project)

      assert %{broken: [entry]} = report
      assert entry.source_path == "project/foo/notes.md"
    end
  end

  # ── Return shape ─────────────────────────────────────────────────────

  describe "scan/1 — return shape" do
    test "each entry carries the load-bearing keys" do
      {:ok, _} = Wiki.upsert_page("org/page/x.md", %{content: "see [[org/page/gone.md]]"})

      %{broken: [entry]} = Integrity.scan()

      assert Map.has_key?(entry, :source_id)
      assert Map.has_key?(entry, :source_path)
      assert Map.has_key?(entry, :target_path)
      assert Map.has_key?(entry, :resolved_target_path)
      assert Map.has_key?(entry, :reason)
      assert is_binary(entry.source_id)
      assert is_binary(entry.reason)
    end
  end

  # ── Test helpers ─────────────────────────────────────────────────────

  defp insert_org_delete(path), do: insert_delete(path, nil)

  defp insert_delete(path, workspace_id) do
    {:ok, _} =
      MemoryFeedback.record_delete(%{
        original_content: "prior body",
        editor_id: Ecto.UUID.generate(),
        original_author_id: Ecto.UUID.generate(),
        path: path,
        namespace: "org_context",
        workspace_id: workspace_id,
        reason_text: "test-seeded"
      })
  end
end
