defmodule Platform.Federation.ToolSurfaceOrgContextTest do
  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.ContextFile
  alias Platform.Org.MemoryEntry
  alias Platform.Repo

  # Clear seeded context files and memory entries so tests start clean.
  defp clear_seeded_data do
    Repo.delete_all(ContextFile)
    Repo.delete_all(MemoryEntry)
  end

  describe "tool_definitions/0 includes org context tools" do
    test "includes all 5 org context tools" do
      tools = ToolSurface.tool_definitions()
      tool_names = Enum.map(tools, & &1.name)

      assert "org_context_read" in tool_names
      assert "org_context_write" in tool_names
      assert "org_context_list" in tool_names
      assert "org_memory_append" in tool_names
      assert "org_memory_search" in tool_names
    end

    test "org context tools have required components" do
      tools = ToolSurface.tool_definitions()

      org_tools =
        Enum.filter(tools, fn t ->
          String.starts_with?(t.name, "org_context_") or
            String.starts_with?(t.name, "org_memory_")
        end)

      assert length(org_tools) == 5

      for tool <- org_tools do
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        assert Map.has_key?(tool, :parameters)
        assert Map.has_key?(tool, :returns)
        assert Map.has_key?(tool, :limitations)
        assert Map.has_key?(tool, :when_to_use)
      end
    end
  end

  describe "org_context_read" do
    test "returns file content when file exists" do
      clear_seeded_data()
      {:ok, _file} =
        OrgContext.upsert_context_file("ORG_IDENTITY.md", %{content: "We are Acme Corp"})

      {:ok, result} =
        ToolSurface.execute("org_context_read", %{"file_key" => "ORG_IDENTITY.md"}, %{})

      assert result.file_key == "ORG_IDENTITY.md"
      assert result.content == "We are Acme Corp"
      assert result.version == 1
    end

    test "returns error when file not found" do
      clear_seeded_data()

      {:error, error} =
        ToolSurface.execute("org_context_read", %{"file_key" => "NONEXISTENT_FILE.md"}, %{})

      assert error.error =~ "Context file not found"
      assert error.recoverable == true
    end

    test "returns error when file_key is missing" do
      {:error, error} = ToolSurface.execute("org_context_read", %{}, %{})

      assert error.error =~ "file_key is required"
      assert error.recoverable == true
    end
  end

  describe "org_context_write" do
    test "creates a new context file" do
      clear_seeded_data()
      {:ok, result} =
        ToolSurface.execute(
          "org_context_write",
          %{"file_key" => "ORG_AGENTS.md", "content" => "Be excellent"},
          %{}
        )

      assert result.file_key == "ORG_AGENTS.md"
      assert result.content == "Be excellent"
      assert result.version == 1
    end

    test "updates an existing context file" do
      clear_seeded_data()

      {:ok, _} =
        OrgContext.upsert_context_file("ORG_AGENTS.md", %{content: "Version 1"})

      {:ok, result} =
        ToolSurface.execute(
          "org_context_write",
          %{"file_key" => "ORG_AGENTS.md", "content" => "Version 2"},
          %{}
        )

      assert result.content == "Version 2"
      assert result.version == 2
    end

    test "returns version conflict error with stale expected_version" do
      clear_seeded_data()

      {:ok, _} =
        OrgContext.upsert_context_file("ORG_DIRECTORY.md", %{content: "V1"})

      # Update to v2
      {:ok, _} =
        OrgContext.upsert_context_file("ORG_DIRECTORY.md", %{content: "V2"})

      {:error, error} =
        ToolSurface.execute(
          "org_context_write",
          %{
            "file_key" => "ORG_DIRECTORY.md",
            "content" => "V3",
            "expected_version" => 1
          },
          %{}
        )

      assert error.error =~ "Version conflict"
      assert error.recoverable == true
    end

    test "returns error when file_key is missing" do
      {:error, error} =
        ToolSurface.execute("org_context_write", %{"content" => "stuff"}, %{})

      assert error.error =~ "file_key is required"
      assert error.recoverable == true
    end

    test "returns error when content is missing" do
      {:error, error} =
        ToolSurface.execute("org_context_write", %{"file_key" => "ORG_IDENTITY.md"}, %{})

      assert error.error =~ "content is required"
      assert error.recoverable == true
    end
  end

  describe "org_context_list" do
    test "returns empty list when no files exist" do
      clear_seeded_data()

      {:ok, result} = ToolSurface.execute("org_context_list", %{}, %{})
      assert result == []
    end

    test "returns all context files" do
      clear_seeded_data()

      {:ok, _} = OrgContext.upsert_context_file("ORG_IDENTITY.md", %{content: "A"})
      {:ok, _} = OrgContext.upsert_context_file("ORG_MEMORY.md", %{content: "B"})

      {:ok, result} = ToolSurface.execute("org_context_list", %{}, %{})

      keys = Enum.map(result, & &1.file_key)
      assert "ORG_IDENTITY.md" in keys
      assert "ORG_MEMORY.md" in keys
    end
  end

  describe "org_memory_append" do
    test "creates a daily memory entry" do
      clear_seeded_data()
      {:ok, result} =
        ToolSurface.execute(
          "org_memory_append",
          %{"content" => "Deployed v2.1 to production"},
          %{}
        )

      assert result.content == "Deployed v2.1 to production"
      assert result.memory_type == "daily"
      assert result.date == Date.to_iso8601(Date.utc_today())
      assert is_binary(result.id)
    end

    test "creates a long_term memory entry with specific date" do
      clear_seeded_data()
      {:ok, result} =
        ToolSurface.execute(
          "org_memory_append",
          %{
            "content" => "Architecture decision: use event sourcing",
            "memory_type" => "long_term",
            "date" => "2026-01-15"
          },
          %{}
        )

      assert result.memory_type == "long_term"
      assert result.date == "2026-01-15"
    end

    test "returns error when content is missing" do
      {:error, error} = ToolSurface.execute("org_memory_append", %{}, %{})
      assert error.error =~ "content is required"
      assert error.recoverable == true
    end

    test "returns error for invalid date format" do
      {:error, error} =
        ToolSurface.execute(
          "org_memory_append",
          %{"content" => "test", "date" => "not-a-date"},
          %{}
        )

      assert error.error =~ "Invalid date format"
      assert error.recoverable == true
    end
  end

  describe "org_memory_search" do
    test "returns all entries when no filters" do
      clear_seeded_data()
      {:ok, _} =
        OrgContext.append_memory_entry(%{
          content: "Entry one",
          date: Date.utc_today(),
          memory_type: "daily"
        })

      {:ok, _} =
        OrgContext.append_memory_entry(%{
          content: "Entry two",
          date: Date.utc_today(),
          memory_type: "daily"
        })

      {:ok, result} = ToolSurface.execute("org_memory_search", %{}, %{})

      assert length(result) >= 2
    end

    test "filters by query" do
      clear_seeded_data()

      {:ok, _} =
        OrgContext.append_memory_entry(%{
          content: "Deployed v2.1",
          date: Date.utc_today(),
          memory_type: "daily"
        })

      {:ok, _} =
        OrgContext.append_memory_entry(%{
          content: "Fixed login bug",
          date: Date.utc_today(),
          memory_type: "daily"
        })

      {:ok, result} =
        ToolSurface.execute("org_memory_search", %{"query" => "Deployed"}, %{})

      assert Enum.all?(result, fn e -> String.contains?(e.content, "Deployed") end)
    end

    test "filters by memory_type" do
      clear_seeded_data()

      {:ok, _} =
        OrgContext.append_memory_entry(%{
          content: "Daily note",
          date: Date.utc_today(),
          memory_type: "daily"
        })

      {:ok, _} =
        OrgContext.append_memory_entry(%{
          content: "Long-term note",
          date: Date.utc_today(),
          memory_type: "long_term"
        })

      {:ok, result} =
        ToolSurface.execute("org_memory_search", %{"memory_type" => "long_term"}, %{})

      assert Enum.all?(result, fn e -> e.memory_type == "long_term" end)
    end

    test "filters by date range" do
      clear_seeded_data()

      {:ok, _} =
        OrgContext.append_memory_entry(%{
          content: "Old entry",
          date: ~D[2026-01-01],
          memory_type: "daily"
        })

      {:ok, _} =
        OrgContext.append_memory_entry(%{
          content: "Recent entry",
          date: ~D[2026-04-01],
          memory_type: "daily"
        })

      {:ok, result} =
        ToolSurface.execute(
          "org_memory_search",
          %{"date_from" => "2026-03-01", "date_to" => "2026-04-30"},
          %{}
        )

      assert Enum.all?(result, fn e -> e.date >= "2026-03-01" end)
    end

    test "returns error for invalid date_from" do
      {:error, error} =
        ToolSurface.execute("org_memory_search", %{"date_from" => "bad"}, %{})

      assert error.error =~ "Invalid date_from format"
      assert error.recoverable == true
    end

    test "returns error for invalid date_to" do
      {:error, error} =
        ToolSurface.execute("org_memory_search", %{"date_to" => "bad"}, %{})

      assert error.error =~ "Invalid date_to format"
      assert error.recoverable == true
    end

    test "respects limit parameter" do
      clear_seeded_data()

      for i <- 1..5 do
        {:ok, _} =
          OrgContext.append_memory_entry(%{
            content: "Entry #{i}",
            date: Date.utc_today(),
            memory_type: "daily"
          })
      end

      {:ok, result} =
        ToolSurface.execute("org_memory_search", %{"limit" => 2}, %{})

      assert length(result) == 2
    end
  end
end
