defmodule Platform.Org.ContextModuleTest do
  @moduledoc "Tests for Platform.Org.Context business logic."
  use Platform.DataCase, async: true

  alias Platform.Org.Context
  alias Platform.Org.ContextFile
  alias Platform.Org.MemoryEntry
  alias Platform.Repo

  # Clear seeded context files so tests start clean.
  defp clear_seeded_files do
    Repo.delete_all(ContextFile)
  end

  defp clear_memory_entries do
    Repo.delete_all(MemoryEntry)
  end

  # ── Context file CRUD ────────────────────────────────────────────────

  describe "get_context_file/2" do
    test "returns nil when file does not exist" do
      clear_seeded_files()
      assert Context.get_context_file("ORG_IDENTITY.md") == nil
    end

    test "returns file by file_key" do
      clear_seeded_files()

      {:ok, _} =
        Context.upsert_context_file("ORG_IDENTITY.md", %{content: "hello"})

      file = Context.get_context_file("ORG_IDENTITY.md")
      assert file.content == "hello"
    end

    test "scopes by workspace_id" do
      clear_seeded_files()
      ws = Ecto.UUID.generate()

      {:ok, _} =
        Context.upsert_context_file("ORG_IDENTITY.md", %{content: "default"})

      {:ok, _} =
        Context.upsert_context_file("ORG_IDENTITY.md", %{content: "workspace"}, workspace_id: ws)

      assert Context.get_context_file("ORG_IDENTITY.md").content == "default"
      assert Context.get_context_file("ORG_IDENTITY.md", ws).content == "workspace"
    end
  end

  describe "list_context_files/1" do
    test "returns all files for default workspace" do
      clear_seeded_files()

      {:ok, _} = Context.upsert_context_file("ORG_IDENTITY.md", %{content: "a"})
      {:ok, _} = Context.upsert_context_file("ORG_MEMORY.md", %{content: "b"})

      files = Context.list_context_files()
      assert length(files) == 2
      assert Enum.map(files, & &1.file_key) == ["ORG_IDENTITY.md", "ORG_MEMORY.md"]
    end
  end

  describe "upsert_context_file/3" do
    test "creates a new file with version 1" do
      clear_seeded_files()

      {:ok, file} =
        Context.upsert_context_file("ORG_IDENTITY.md", %{content: "new"})

      assert file.version == 1
      assert file.content == "new"
    end

    test "updates existing file and increments version" do
      clear_seeded_files()

      {:ok, v1} = Context.upsert_context_file("ORG_IDENTITY.md", %{content: "v1"})
      assert v1.version == 1

      {:ok, v2} = Context.upsert_context_file("ORG_IDENTITY.md", %{content: "v2"})
      assert v2.version == 2
      assert v2.content == "v2"
    end

    test "returns {:error, :stale} on version mismatch" do
      clear_seeded_files()

      {:ok, _v1} = Context.upsert_context_file("ORG_IDENTITY.md", %{content: "v1"})

      assert {:error, :stale} =
               Context.upsert_context_file("ORG_IDENTITY.md", %{content: "conflict"},
                 expected_version: 999
               )
    end

    test "succeeds with correct expected_version" do
      clear_seeded_files()

      {:ok, v1} = Context.upsert_context_file("ORG_IDENTITY.md", %{content: "v1"})

      {:ok, v2} =
        Context.upsert_context_file("ORG_IDENTITY.md", %{content: "v2"},
          expected_version: v1.version
        )

      assert v2.version == 2
    end

    test "emits telemetry on write" do
      clear_seeded_files()

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :org, :context_file_written]
        ])

      {:ok, _file} =
        Context.upsert_context_file("ORG_IDENTITY.md", %{content: "telemetry test"})

      assert_received {[:platform, :org, :context_file_written], ^ref, %{system_time: _},
                       %{file_key: "ORG_IDENTITY.md", version: 1, workspace_id: nil}}

      # Update also emits
      {:ok, _} = Context.upsert_context_file("ORG_IDENTITY.md", %{content: "v2"})

      assert_received {[:platform, :org, :context_file_written], ^ref, %{system_time: _},
                       %{file_key: "ORG_IDENTITY.md", version: 2, workspace_id: nil}}
    end
  end

  # ── Memory entries ───────────────────────────────────────────────────

  describe "append_memory_entry/2" do
    test "inserts a daily memory entry" do
      {:ok, entry} =
        Context.append_memory_entry(%{
          content: "Shipped v1",
          date: ~D[2026-04-08],
          memory_type: "daily"
        })

      assert entry.content == "Shipped v1"
      assert entry.memory_type == "daily"
    end

    test "emits telemetry on append" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :org, :memory_entry_written]
        ])

      {:ok, entry} =
        Context.append_memory_entry(%{
          content: "Telemetry note",
          date: ~D[2026-04-08]
        })

      assert_received {[:platform, :org, :memory_entry_written], ^ref, %{system_time: _},
                       %{memory_entry_id: id, memory_type: "daily", date: ~D[2026-04-08]}}

      assert id == entry.id
    end

    test "returns error on invalid attrs" do
      assert {:error, %Ecto.Changeset{}} = Context.append_memory_entry(%{})
    end
  end

  describe "search_memory_entries/1" do
    setup do
      clear_memory_entries()

      {:ok, e1} =
        Context.append_memory_entry(%{
          content: "Deployed FHIR service",
          date: ~D[2026-04-07],
          memory_type: "daily"
        })

      {:ok, e2} =
        Context.append_memory_entry(%{
          content: "Fixed auth bug",
          date: ~D[2026-04-08],
          memory_type: "daily"
        })

      {:ok, e3} =
        Context.append_memory_entry(%{
          content: "Architecture decision: use FHIR R4",
          date: ~D[2026-04-06],
          memory_type: "long_term"
        })

      %{entries: [e1, e2, e3]}
    end

    test "returns all entries with no filters" do
      entries = Context.search_memory_entries()
      assert length(entries) == 3
    end

    test "filters by ilike query" do
      entries = Context.search_memory_entries(query: "FHIR")
      assert length(entries) == 2
      assert Enum.all?(entries, &String.contains?(&1.content, "FHIR"))
    end

    test "filters by memory_type" do
      entries = Context.search_memory_entries(memory_type: "long_term")
      assert length(entries) == 1
      assert hd(entries).memory_type == "long_term"
    end

    test "filters by date_from" do
      entries = Context.search_memory_entries(date_from: ~D[2026-04-08])
      assert length(entries) == 1
      assert hd(entries).date == ~D[2026-04-08]
    end

    test "filters by date_to" do
      entries = Context.search_memory_entries(date_to: ~D[2026-04-06])
      assert length(entries) == 1
      assert hd(entries).date == ~D[2026-04-06]
    end

    test "filters by date range" do
      entries =
        Context.search_memory_entries(
          date_from: ~D[2026-04-07],
          date_to: ~D[2026-04-08]
        )

      assert length(entries) == 2
    end

    test "respects limit" do
      entries = Context.search_memory_entries(limit: 1)
      assert length(entries) == 1
    end
  end

  # ── Build context ────────────────────────────────────────────────────

  describe "build_context/1" do
    test "returns context files and ORG_NOTES for last 2 days" do
      clear_seeded_files()
      clear_memory_entries()

      {:ok, _} = Context.upsert_context_file("ORG_IDENTITY.md", %{content: "We are Acme"})
      {:ok, _} = Context.upsert_context_file("ORG_MEMORY.md", %{content: "Key decisions"})

      today = Date.utc_today()
      yesterday = Date.add(today, -1)

      {:ok, _} =
        Context.append_memory_entry(%{
          content: "Morning standup notes",
          date: today,
          memory_type: "daily"
        })

      {:ok, _} =
        Context.append_memory_entry(%{
          content: "Afternoon retro",
          date: today,
          memory_type: "daily"
        })

      {:ok, _} =
        Context.append_memory_entry(%{
          content: "Yesterday's deploy",
          date: yesterday,
          memory_type: "daily"
        })

      # Old entry — should NOT appear
      {:ok, _} =
        Context.append_memory_entry(%{
          content: "Ancient history",
          date: ~D[2026-01-01],
          memory_type: "daily"
        })

      ctx = Context.build_context()

      # Context files present
      assert ctx["ORG_IDENTITY.md"] == "We are Acme"
      assert ctx["ORG_MEMORY.md"] == "Key decisions"

      # Today's notes concatenated
      today_key = "ORG_NOTES-#{Date.to_iso8601(today)}"
      assert ctx[today_key] =~ "Morning standup notes"
      assert ctx[today_key] =~ "Afternoon retro"

      # Yesterday's notes
      yesterday_key = "ORG_NOTES-#{Date.to_iso8601(yesterday)}"
      assert ctx[yesterday_key] == "Yesterday's deploy"

      # Old entry excluded
      refute Map.has_key?(ctx, "ORG_NOTES-2026-01-01")
    end

    test "returns empty map when no data exists" do
      clear_seeded_files()
      clear_memory_entries()

      ctx = Context.build_context()
      assert ctx == %{}
    end
  end
end
