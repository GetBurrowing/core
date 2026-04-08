defmodule Platform.Org.ContextTest do
  @moduledoc """
  Tests for Platform.Org.Context module.

  Covers CRUD for context files, append + search for memory entries,
  and the build_context/1 bundle assembly function.
  """

  use Platform.DataCase, async: true

  alias Platform.Org.{Context, ContextFile, MemoryEntry}
  alias Platform.Repo

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  # Clear seeded data before each test to start clean
  setup do
    Repo.delete_all(ContextFile)
    Repo.delete_all(MemoryEntry)
    :ok
  end

  # ── get_context_file/2 ────────────────────────────────────────────────────

  describe "get_context_file/2" do
    test "returns {:ok, file} when found (nil workspace)" do
      Repo.insert!(%ContextFile{
        file_key: "ORG_IDENTITY.md",
        content: "# Identity",
        version: 1
      })

      assert {:ok, file} = Context.get_context_file("ORG_IDENTITY.md")
      assert file.file_key == "ORG_IDENTITY.md"
      assert file.content == "# Identity"
    end

    test "returns {:error, :not_found} when not found" do
      assert {:error, :not_found} = Context.get_context_file("ORG_IDENTITY.md")
    end

    test "scopes lookup by workspace_id" do
      ws1 = Ecto.UUID.generate()
      ws2 = Ecto.UUID.generate()

      Repo.insert!(%ContextFile{
        workspace_id: ws1,
        file_key: "ORG_IDENTITY.md",
        content: "ws1 content",
        version: 1
      })

      # ws2 has no file
      assert {:error, :not_found} = Context.get_context_file("ORG_IDENTITY.md", ws2)

      # ws1 finds its file
      assert {:ok, file} = Context.get_context_file("ORG_IDENTITY.md", ws1)
      assert file.content == "ws1 content"
    end

    test "nil workspace does not match workspace-scoped files" do
      ws = Ecto.UUID.generate()

      Repo.insert!(%ContextFile{
        workspace_id: ws,
        file_key: "ORG_MEMORY.md",
        content: "workspace memory",
        version: 1
      })

      # nil workspace lookup should not find the workspace-scoped file
      assert {:error, :not_found} = Context.get_context_file("ORG_MEMORY.md")
    end
  end

  # ── list_context_files/1 ──────────────────────────────────────────────────

  describe "list_context_files/1" do
    test "lists all files for nil workspace, ordered by file_key" do
      Repo.insert!(%ContextFile{file_key: "ORG_MEMORY.md", content: "m", version: 1})
      Repo.insert!(%ContextFile{file_key: "ORG_IDENTITY.md", content: "i", version: 1})
      Repo.insert!(%ContextFile{file_key: "ORG_AGENTS.md", content: "a", version: 1})

      files = Context.list_context_files()
      keys = Enum.map(files, & &1.file_key)
      assert keys == ["ORG_AGENTS.md", "ORG_IDENTITY.md", "ORG_MEMORY.md"]
    end

    test "returns empty list when no files exist" do
      assert [] = Context.list_context_files()
    end

    test "scopes to workspace_id" do
      ws = Ecto.UUID.generate()

      Repo.insert!(%ContextFile{
        workspace_id: ws,
        file_key: "ORG_IDENTITY.md",
        content: "ws",
        version: 1
      })

      Repo.insert!(%ContextFile{
        file_key: "ORG_MEMORY.md",
        content: "global",
        version: 1
      })

      ws_files = Context.list_context_files(ws)
      assert length(ws_files) == 1
      assert hd(ws_files).file_key == "ORG_IDENTITY.md"

      global_files = Context.list_context_files()
      assert length(global_files) == 1
      assert hd(global_files).file_key == "ORG_MEMORY.md"
    end
  end

  # ── upsert_context_file/3 ─────────────────────────────────────────────────

  describe "upsert_context_file/3" do
    test "inserts a new file when it does not exist" do
      assert {:ok, file} = Context.upsert_context_file("ORG_IDENTITY.md", "# New Identity")
      assert file.file_key == "ORG_IDENTITY.md"
      assert file.content == "# New Identity"
      assert file.version == 1
    end

    test "updates existing file and increments version" do
      Repo.insert!(%ContextFile{file_key: "ORG_IDENTITY.md", content: "v1", version: 1})

      assert {:ok, file} = Context.upsert_context_file("ORG_IDENTITY.md", "v2")
      assert file.content == "v2"
      assert file.version == 2
    end

    test "records updated_by on upsert" do
      agent_id = Ecto.UUID.generate()
      assert {:ok, file} = Context.upsert_context_file("ORG_MEMORY.md", "content", updated_by: agent_id)
      assert file.updated_by == agent_id
    end

    test "scopes insert to workspace_id" do
      ws = Ecto.UUID.generate()

      assert {:ok, file} =
               Context.upsert_context_file("ORG_IDENTITY.md", "ws content",
                 workspace_id: ws
               )

      assert file.workspace_id == ws

      # Global (nil) workspace should be unaffected
      assert {:error, :not_found} = Context.get_context_file("ORG_IDENTITY.md")
    end

    test "returns error for invalid file_key" do
      assert {:error, changeset} = Context.upsert_context_file("INVALID.md", "content")
      assert %{file_key: ["is invalid"]} = errors_on(changeset)
    end

    test "emits telemetry on successful upsert" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :org_context, :file_updated]
        ])

      Context.upsert_context_file("ORG_AGENTS.md", "agents content")

      assert_receive {[:platform, :org_context, :file_updated], ^ref, _measurements, metadata}
      assert metadata.file_key == "ORG_AGENTS.md"

      :telemetry.detach(ref)
    end
  end

  # ── append_memory/2 ───────────────────────────────────────────────────────

  describe "append_memory/2" do
    test "appends a new memory entry with defaults" do
      assert {:ok, entry} = Context.append_memory("Key decision made today")
      assert entry.content == "Key decision made today"
      assert entry.memory_type == "daily"
      assert entry.date == Date.utc_today()
    end

    test "accepts memory_type option" do
      assert {:ok, entry} = Context.append_memory("Long-term memory", memory_type: "long_term")
      assert entry.memory_type == "long_term"
    end

    test "accepts date option" do
      date = ~D[2026-04-01]
      assert {:ok, entry} = Context.append_memory("Historical note", date: date)
      assert entry.date == date
    end

    test "accepts authored_by option" do
      agent_id = Ecto.UUID.generate()
      assert {:ok, entry} = Context.append_memory("Agent memory", authored_by: agent_id)
      assert entry.authored_by == agent_id
    end

    test "accepts metadata option" do
      meta = %{"tags" => ["decision", "architecture"]}
      assert {:ok, entry} = Context.append_memory("Architecture decision", metadata: meta)
      assert entry.metadata == meta
    end

    test "scopes to workspace_id" do
      ws = Ecto.UUID.generate()
      assert {:ok, entry} = Context.append_memory("WS note", workspace_id: ws)
      assert entry.workspace_id == ws
    end

    test "emits telemetry on successful append" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :org_context, :memory_appended]
        ])

      Context.append_memory("Memory for telemetry test")

      assert_receive {[:platform, :org_context, :memory_appended], ^ref, _measurements,
                      metadata}

      assert metadata.memory_type == "daily"

      :telemetry.detach(ref)
    end

    test "returns error for missing content" do
      assert {:error, changeset} = Context.append_memory("")
      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end
  end

  # ── search_memory/2 ───────────────────────────────────────────────────────

  describe "search_memory/2" do
    setup do
      Repo.insert!(%MemoryEntry{
        content: "Decided to use FHIR R4 for data model",
        date: ~D[2026-04-08],
        memory_type: "long_term"
      })

      Repo.insert!(%MemoryEntry{
        content: "Daily standup notes — all blockers resolved",
        date: ~D[2026-04-08],
        memory_type: "daily"
      })

      Repo.insert!(%MemoryEntry{
        content: "Architecture review: migrated to event sourcing",
        date: ~D[2026-04-07],
        memory_type: "long_term"
      })

      :ok
    end

    test "finds entries matching query (case-insensitive)" do
      entries = Context.search_memory("fhir")
      assert length(entries) == 1
      assert hd(entries).content =~ "FHIR"
    end

    test "returns multiple matches" do
      entries = Context.search_memory("r4")
      assert length(entries) >= 1
    end

    test "returns empty list for no match" do
      entries = Context.search_memory("xyznotfound")
      assert entries == []
    end

    test "filters by memory_type" do
      daily = Context.search_memory("", memory_type: "daily")
      long_term = Context.search_memory("", memory_type: "long_term")

      assert Enum.all?(daily, &(&1.memory_type == "daily"))
      assert Enum.all?(long_term, &(&1.memory_type == "long_term"))
    end

    test "filters by date_from" do
      entries = Context.search_memory("", date_from: ~D[2026-04-08])
      assert Enum.all?(entries, &(Date.compare(&1.date, ~D[2026-04-08]) != :lt))
    end

    test "filters by date_to" do
      entries = Context.search_memory("", date_to: ~D[2026-04-07])
      assert Enum.all?(entries, &(Date.compare(&1.date, ~D[2026-04-07]) != :gt))
    end

    test "respects limit option" do
      entries = Context.search_memory("", limit: 1)
      assert length(entries) == 1
    end

    test "escapes ILIKE wildcards in query" do
      # Should not raise or match incorrectly for wildcard chars
      entries = Context.search_memory("%")
      assert is_list(entries)
    end
  end

  # ── list_memory_entries/1 ─────────────────────────────────────────────────

  describe "list_memory_entries/1" do
    setup do
      Repo.insert!(%MemoryEntry{
        content: "Entry A",
        date: ~D[2026-04-08],
        memory_type: "daily"
      })

      Repo.insert!(%MemoryEntry{
        content: "Entry B",
        date: ~D[2026-04-07],
        memory_type: "long_term"
      })

      Repo.insert!(%MemoryEntry{
        content: "Entry C",
        date: ~D[2026-04-06],
        memory_type: "daily"
      })

      :ok
    end

    test "lists all entries ordered by date desc" do
      entries = Context.list_memory_entries()
      dates = Enum.map(entries, & &1.date)
      assert dates == Enum.sort(dates, {:desc, Date})
    end

    test "filters by memory_type" do
      daily = Context.list_memory_entries(memory_type: "daily")
      assert Enum.all?(daily, &(&1.memory_type == "daily"))
      assert length(daily) == 2
    end

    test "filters by date_from" do
      entries = Context.list_memory_entries(date_from: ~D[2026-04-07])
      assert length(entries) == 2
    end

    test "filters by date_to" do
      entries = Context.list_memory_entries(date_to: ~D[2026-04-07])
      assert length(entries) == 2
    end

    test "date_from and date_to together form a range" do
      entries =
        Context.list_memory_entries(date_from: ~D[2026-04-07], date_to: ~D[2026-04-07])

      assert length(entries) == 1
      assert hd(entries).content == "Entry B"
    end

    test "respects limit" do
      entries = Context.list_memory_entries(limit: 2)
      assert length(entries) == 2
    end
  end

  # ── build_context/1 ───────────────────────────────────────────────────────

  describe "build_context/1" do
    test "returns map with all four workspace file keys" do
      ctx = Context.build_context()

      assert Map.has_key?(ctx, "ORG_IDENTITY.md")
      assert Map.has_key?(ctx, "ORG_MEMORY.md")
      assert Map.has_key?(ctx, "ORG_AGENTS.md")
      assert Map.has_key?(ctx, "ORG_DIRECTORY.md")
    end

    test "returns empty string for missing context files" do
      ctx = Context.build_context()

      assert ctx["ORG_IDENTITY.md"] == ""
      assert ctx["ORG_MEMORY.md"] == ""
    end

    test "includes file content when files exist" do
      Repo.insert!(%ContextFile{
        file_key: "ORG_IDENTITY.md",
        content: "# Startup Suite",
        version: 1
      })

      ctx = Context.build_context()
      assert ctx["ORG_IDENTITY.md"] == "# Startup Suite"
    end

    test "includes ORG_NOTES-YYYY-MM-DD keys for recent daily entries" do
      today = Date.utc_today()
      yesterday = Date.add(today, -1)
      old = Date.add(today, -5)

      Repo.insert!(%MemoryEntry{
        content: "Today's note",
        date: today,
        memory_type: "daily"
      })

      Repo.insert!(%MemoryEntry{
        content: "Yesterday's note",
        date: yesterday,
        memory_type: "daily"
      })

      Repo.insert!(%MemoryEntry{
        content: "Old note (should be excluded)",
        date: old,
        memory_type: "daily"
      })

      ctx = Context.build_context()

      today_key = "ORG_NOTES-#{Calendar.strftime(today, "%Y-%m-%d")}"
      yesterday_key = "ORG_NOTES-#{Calendar.strftime(yesterday, "%Y-%m-%d")}"
      old_key = "ORG_NOTES-#{Calendar.strftime(old, "%Y-%m-%d")}"

      assert Map.has_key?(ctx, today_key)
      assert Map.has_key?(ctx, yesterday_key)
      refute Map.has_key?(ctx, old_key)

      assert ctx[today_key] =~ "Today's note"
      assert ctx[yesterday_key] =~ "Yesterday's note"
    end

    test "does not include long_term entries in daily notes" do
      today = Date.utc_today()

      Repo.insert!(%MemoryEntry{
        content: "Long-term memory",
        date: today,
        memory_type: "long_term"
      })

      ctx = Context.build_context()

      # Long-term entries should not appear as ORG_NOTES keys
      notes_keys = ctx |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "ORG_NOTES-"))
      assert notes_keys == []
    end

    test "merges multiple entries for same day with separator" do
      today = Date.utc_today()

      Repo.insert!(%MemoryEntry{content: "Entry 1", date: today, memory_type: "daily"})
      Repo.insert!(%MemoryEntry{content: "Entry 2", date: today, memory_type: "daily"})

      ctx = Context.build_context()
      today_key = "ORG_NOTES-#{Calendar.strftime(today, "%Y-%m-%d")}"

      assert ctx[today_key] =~ "Entry 1"
      assert ctx[today_key] =~ "Entry 2"
      assert ctx[today_key] =~ "---"
    end

    test "days_back option controls how many days of notes to include" do
      today = Date.utc_today()
      three_days_ago = Date.add(today, -3)

      Repo.insert!(%MemoryEntry{
        content: "Three days ago",
        date: three_days_ago,
        memory_type: "daily"
      })

      # With default 2 days back, 3-day-old entry should NOT appear
      ctx_default = Context.build_context()
      old_key = "ORG_NOTES-#{Calendar.strftime(three_days_ago, "%Y-%m-%d")}"
      refute Map.has_key?(ctx_default, old_key)

      # With 4 days back, 3-day-old entry SHOULD appear
      ctx_extended = Context.build_context(days_back: 4)
      assert Map.has_key?(ctx_extended, old_key)
    end

    test "scopes to workspace_id" do
      ws = Ecto.UUID.generate()

      Repo.insert!(%ContextFile{
        workspace_id: ws,
        file_key: "ORG_IDENTITY.md",
        content: "WS Identity",
        version: 1
      })

      Repo.insert!(%ContextFile{
        file_key: "ORG_IDENTITY.md",
        content: "Global Identity",
        version: 1
      })

      ws_ctx = Context.build_context(workspace_id: ws)
      global_ctx = Context.build_context()

      assert ws_ctx["ORG_IDENTITY.md"] == "WS Identity"
      assert global_ctx["ORG_IDENTITY.md"] == "Global Identity"
    end
  end
end
