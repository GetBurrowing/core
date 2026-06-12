defmodule Platform.Org.Wiki.Indexer.PayloadTest do
  @moduledoc """
  Unit tests for `Platform.Org.Wiki.Indexer.Payload` — the pure shapers
  that turn T2 wiki rows into provider entries. No Repo here: every input
  is a constructed struct so the test is fast and side-effect-free.
  """
  use ExUnit.Case, async: true

  alias Platform.Org.Wiki.Indexer.Payload
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage

  describe "from_page/1" do
    test "shapes a minimal org-scoped page with default frontmatter" do
      page = %WikiPage{
        id: "01HX0000000000000000000001",
        file_key: "org/identity.md",
        workspace_id: nil,
        content: "# Identity",
        frontmatter: %{},
        version: 1
      }

      entry = Payload.from_page(page)

      assert entry.id == "01HX0000000000000000000001"
      assert entry.content == "# Identity"
      assert entry.memory_type == "page"
      assert entry.workspace_id == nil
      assert entry.date == Date.to_iso8601(Date.utc_today())

      assert entry.metadata == %{
               "file_key" => "org/identity.md",
               "version" => 1,
               "frontmatter" => %{}
             }
    end

    test "preserves frontmatter and workspace_id" do
      ws = "01HX00000000000000000000FF"

      page = %WikiPage{
        id: "01HX0000000000000000000002",
        file_key: "project/abc/decisions.md",
        workspace_id: ws,
        content: "---\nowner: alice\n---\n\n# Decisions",
        frontmatter: %{"owner" => "alice"},
        version: 3
      }

      entry = Payload.from_page(page)

      assert entry.workspace_id == ws
      assert entry.metadata["frontmatter"] == %{"owner" => "alice"}
      assert entry.metadata["version"] == 3
      assert entry.metadata["file_key"] == "project/abc/decisions.md"
    end

    test "handles nil content + nil frontmatter without crashing" do
      page = %WikiPage{
        id: "01HX0000000000000000000003",
        file_key: "org/empty.md",
        workspace_id: nil,
        content: nil,
        frontmatter: nil,
        version: 1
      }

      entry = Payload.from_page(page)

      assert entry.content == ""
      assert entry.metadata["frontmatter"] == %{}
    end

    test "always stamps memory_type=\"page\"" do
      page = %WikiPage{
        id: "x",
        file_key: "k",
        workspace_id: nil,
        content: "",
        frontmatter: %{},
        version: 1
      }

      assert Payload.from_page(page).memory_type == Payload.page_memory_type()
      assert Payload.page_memory_type() == "page"
    end
  end

  describe "from_journal_entry/1" do
    test "shapes a default-namespace journal entry on a real date" do
      entry_row = %WikiJournalEntry{
        id: "01HX0000000000000000000010",
        date: ~D[2026-05-19],
        content: "we agreed on the indexer interval",
        workspace_id: nil,
        metadata: %{"namespace" => "org"}
      }

      entry = Payload.from_journal_entry(entry_row)

      assert entry.id == "01HX0000000000000000000010"
      assert entry.content == "we agreed on the indexer interval"
      assert entry.memory_type == "journal"
      assert entry.date == "2026-05-19"
      assert entry.workspace_id == nil
      assert entry.metadata == %{"namespace" => "org"}
    end

    test "preserves arbitrary metadata + workspace_id" do
      ws = "01HX00000000000000000000AB"

      entry_row = %WikiJournalEntry{
        id: "01HX0000000000000000000011",
        date: ~D[2026-04-01],
        content: "project note",
        workspace_id: ws,
        metadata: %{"namespace" => "project/abc", "tag" => "infra"}
      }

      entry = Payload.from_journal_entry(entry_row)

      assert entry.workspace_id == ws
      assert entry.metadata["namespace"] == "project/abc"
      assert entry.metadata["tag"] == "infra"
    end

    test "handles nil metadata + nil content" do
      entry_row = %WikiJournalEntry{
        id: "01HX0000000000000000000012",
        date: ~D[2026-05-19],
        content: nil,
        workspace_id: nil,
        metadata: nil
      }

      entry = Payload.from_journal_entry(entry_row)

      assert entry.content == ""
      assert entry.metadata == %{}
    end

    test "always stamps memory_type=\"journal\"" do
      entry_row = %WikiJournalEntry{
        id: "x",
        date: ~D[2026-05-19],
        content: "",
        workspace_id: nil,
        metadata: %{}
      }

      assert Payload.from_journal_entry(entry_row).memory_type ==
               Payload.journal_memory_type()

      assert Payload.journal_memory_type() == "journal"
    end
  end
end
