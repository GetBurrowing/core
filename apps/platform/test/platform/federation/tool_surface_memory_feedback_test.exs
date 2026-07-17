defmodule Platform.Federation.ToolSurfaceMemoryFeedbackTest do
  @moduledoc """
  Stage 4 of task 019f6381 — MCP surface for the memory-feedback corpus.

  Covers the three read-only tools registered in the `memory` bundle:

    * `org_memory_recently_edited`
    * `org_memory_recently_deleted`
    * `org_memory_feedback_at_path`

  Each tool is a thin wrapper over `Platform.MemoryFeedback.list_recent/1`
  with pre-bound `feedback_kind`. The tests assert:

    * happy-path: each tool returns rows matching a direct context call
    * `workspace_id` scoping (workspace-B rows don't leak into workspace-A
      responses)
    * `path_prefix` scoping (prefix filter passed through the MCP layer)
    * `org_memory_feedback_at_path` returns `%{path, edits: [], deletes: []}`
      when no feedback exists — never a `nil` or crash
    * `limit` is clamped at 100 even when the caller asks for 500
    * bundle registration (all three tools land in the `memory` bundle
      with the 6-component rubric)

  The stage 3 read API tests (`Platform.MemoryFeedbackTest`) already
  cover the underlying SQL filters — this file exercises the MCP
  dispatch layer only.
  """

  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.MemoryFeedback
  alias Platform.MemoryFeedback.Entry
  alias Platform.Repo

  setup do
    # Feedback rows are append-only and don't participate in the
    # DataCase Ecto Sandbox rollback across cases run with `async:
    # false`, so wipe the table between cases to keep assertions
    # deterministic.
    Repo.delete_all(Entry)
    :ok
  end

  # ── Fixtures ─────────────────────────────────────────────────────────

  defp seed_edit(overrides) do
    attrs =
      Map.merge(
        %{
          original_content: "before",
          edited_content: "after",
          original_author_id: Ecto.UUID.generate(),
          editor_id: Ecto.UUID.generate(),
          path: "ORG_MEMORY.md",
          namespace: "org_context"
        },
        overrides
      )

    {:ok, entry} = MemoryFeedback.record_edit(attrs)
    entry
  end

  defp seed_delete(overrides) do
    attrs =
      Map.merge(
        %{
          original_content: "delete-me",
          original_author_id: Ecto.UUID.generate(),
          editor_id: Ecto.UUID.generate(),
          path: "ORG_AGENTS.md",
          namespace: "org_context",
          reason_text: "outdated"
        },
        overrides
      )

    {:ok, entry} = MemoryFeedback.record_delete(attrs)
    entry
  end

  # ── Bundle registration ──────────────────────────────────────────────

  describe "tool_definitions/0 — memory-feedback tools" do
    test "three org_memory_* feedback tools are registered under the memory bundle" do
      tools = ToolSurface.list_tools(["memory"])
      names = MapSet.new(tools, & &1.name)

      for tool <-
            ~w(org_memory_recently_edited org_memory_recently_deleted org_memory_feedback_at_path) do
        assert tool in names, "memory bundle missing #{tool}"
      end

      # Every tool in the memory bundle (including these three) must
      # carry the bundle tag — mirrors the T5 e2e guard.
      assert Enum.all?(tools, &(&1.bundle == "memory"))
    end

    test "feedback tools carry the 6-component rubric" do
      ToolSurface.list_tools(["memory"])
      |> Enum.filter(
        &(&1.name in [
            "org_memory_recently_edited",
            "org_memory_recently_deleted",
            "org_memory_feedback_at_path"
          ])
      )
      |> Enum.each(fn tool ->
        for key <- [:name, :description, :parameters, :returns, :limitations, :when_to_use] do
          assert Map.has_key?(tool, key), "#{tool.name} missing key #{inspect(key)}"
        end
      end)
    end
  end

  # ── org_memory_recently_edited ───────────────────────────────────────

  describe "execute/3 org_memory_recently_edited" do
    test "returns edit rows matching a direct list_recent/1 call, newest first" do
      _e1 = seed_edit(%{original_content: "v1", edited_content: "v2", path: "ORG_MEMORY.md"})
      _e2 = seed_edit(%{original_content: "v2", edited_content: "v3", path: "ORG_AGENTS.md"})
      # A delete row must not appear in the recently_edited response.
      _d = seed_delete(%{path: "OTHER.md"})

      {:ok, rows} = ToolSurface.execute("org_memory_recently_edited", %{}, %{})

      assert length(rows) == 2

      # Rows are ordered newest-first; e2 was seeded after e1.
      [head | _] = rows
      assert head.path == "ORG_AGENTS.md"
      assert head.edited_content == "v3"

      # Each row carries the serializer's canonical keys.
      for row <- rows do
        for key <- [
              :path,
              :original_content,
              :edited_content,
              :editor_id,
              :original_author_id,
              :reason_text,
              :inserted_at
            ] do
          assert Map.has_key?(row, key), "row missing #{inspect(key)}: #{inspect(row)}"
        end

        # `edited_content` is populated for edits (never nil in this branch).
        refute is_nil(row.edited_content)
      end

      # Round-trip parity with the direct context call — same row count,
      # same first path.
      direct = MemoryFeedback.list_recent(feedback_kind: "edit")
      assert length(direct) == length(rows)
      assert hd(direct).path == head.path
    end

    test "workspace_id scoping — workspace-B rows do not leak into workspace-A response" do
      wa = Ecto.UUID.generate()
      wb = Ecto.UUID.generate()

      _a = seed_edit(%{workspace_id: wa, original_content: "A-content"})
      _b = seed_edit(%{workspace_id: wb, original_content: "B-content"})

      {:ok, a_rows} =
        ToolSurface.execute("org_memory_recently_edited", %{"workspace_id" => wa}, %{})

      assert length(a_rows) == 1
      assert hd(a_rows).original_content == "A-content"

      {:ok, b_rows} =
        ToolSurface.execute("org_memory_recently_edited", %{"workspace_id" => wb}, %{})

      assert length(b_rows) == 1
      assert hd(b_rows).original_content == "B-content"
    end

    test "path_prefix scoping — only rows whose path starts with the prefix are returned" do
      _match = seed_edit(%{path: "ORG_AGENTS.md", original_content: "match"})
      _also = seed_edit(%{path: "ORG_MEMORY.md", original_content: "match-too"})
      _miss = seed_edit(%{path: "PROJECT_STATUS.md", original_content: "miss"})

      {:ok, rows} =
        ToolSurface.execute("org_memory_recently_edited", %{"path_prefix" => "ORG_"}, %{})

      contents = Enum.map(rows, & &1.original_content) |> MapSet.new()

      assert "match" in contents
      assert "match-too" in contents
      refute "miss" in contents
    end

    test "limit is clamped to 100 even when caller asks for 500" do
      # Seed 105 rows so the ceiling of 100 is visible.
      for i <- 1..105 do
        seed_edit(%{
          original_content: "row-#{i}",
          path: "ORG_MEMORY.md"
        })
      end

      {:ok, rows} = ToolSurface.execute("org_memory_recently_edited", %{"limit" => 500}, %{})

      assert length(rows) == 100
    end

    test "invalid limit values fall back to the default of 20" do
      for i <- 1..25 do
        seed_edit(%{original_content: "row-#{i}"})
      end

      {:ok, rows} = ToolSurface.execute("org_memory_recently_edited", %{"limit" => "bogus"}, %{})

      assert length(rows) == 20
    end
  end

  # ── org_memory_recently_deleted ──────────────────────────────────────

  describe "execute/3 org_memory_recently_deleted" do
    test "returns delete rows only — edit rows are excluded" do
      _d1 = seed_delete(%{path: "ORG_AGENTS.md", original_content: "gone"})
      _d2 = seed_delete(%{path: "ORG_MEMORY.md", original_content: "also-gone"})
      _e = seed_edit(%{path: "STILL_HERE.md"})

      {:ok, rows} = ToolSurface.execute("org_memory_recently_deleted", %{}, %{})

      assert length(rows) == 2

      # Ordering: newest first, so d2 wins.
      [head | _] = rows
      assert head.path == "ORG_MEMORY.md"
      assert head.original_content == "also-gone"

      # Every delete row has nil `edited_content` (per record_delete/1).
      for row <- rows do
        assert is_nil(row.edited_content)
      end
    end

    test "reason_text is surfaced on delete rows when the editor supplied one" do
      _d = seed_delete(%{path: "ORG_AGENTS.md", reason_text: "consolidated into ORG_MEMORY.md"})

      {:ok, [row]} = ToolSurface.execute("org_memory_recently_deleted", %{}, %{})

      assert row.reason_text == "consolidated into ORG_MEMORY.md"
    end

    test "workspace_id scoping is enforced on the delete tool" do
      wa = Ecto.UUID.generate()
      wb = Ecto.UUID.generate()

      _a = seed_delete(%{workspace_id: wa, original_content: "A-del"})
      _b = seed_delete(%{workspace_id: wb, original_content: "B-del"})

      {:ok, a_rows} =
        ToolSurface.execute("org_memory_recently_deleted", %{"workspace_id" => wa}, %{})

      assert length(a_rows) == 1
      assert hd(a_rows).original_content == "A-del"
    end

    test "path_prefix scoping is enforced on the delete tool" do
      _match = seed_delete(%{path: "ORG_MEMORY.md", original_content: "match"})
      _miss = seed_delete(%{path: "PROJECT_STATUS.md", original_content: "miss"})

      {:ok, rows} =
        ToolSurface.execute("org_memory_recently_deleted", %{"path_prefix" => "ORG_"}, %{})

      contents = Enum.map(rows, & &1.original_content) |> MapSet.new()
      assert "match" in contents
      refute "miss" in contents
    end
  end

  # ── org_memory_feedback_at_path ──────────────────────────────────────

  describe "execute/3 org_memory_feedback_at_path" do
    test "returns %{path, edits: [], deletes: []} when the path has no feedback history" do
      {:ok, response} =
        ToolSurface.execute(
          "org_memory_feedback_at_path",
          %{"path" => "NEVER_TOUCHED.md"},
          %{}
        )

      assert response == %{
               path: "NEVER_TOUCHED.md",
               edits: [],
               deletes: []
             }
    end

    test "splits edits and deletes into two arrays for the queried path" do
      # Two edits + one delete on the target path.
      _e1 =
        seed_edit(%{path: "ORG_AGENTS.md", original_content: "v1", edited_content: "v2"})

      _e2 =
        seed_edit(%{path: "ORG_AGENTS.md", original_content: "v2", edited_content: "v3"})

      _d = seed_delete(%{path: "ORG_AGENTS.md", original_content: "v3", reason_text: "retired"})

      # Feedback on a different path — must NOT bleed in.
      _other_e = seed_edit(%{path: "ORG_MEMORY.md", original_content: "other"})
      _other_d = seed_delete(%{path: "OTHER.md", original_content: "other-del"})

      {:ok, response} =
        ToolSurface.execute("org_memory_feedback_at_path", %{"path" => "ORG_AGENTS.md"}, %{})

      assert response.path == "ORG_AGENTS.md"

      # Both edit rows land in the `edits` list, both non-target rows
      # are filtered out.
      assert length(response.edits) == 2
      assert Enum.all?(response.edits, &(&1.path == "ORG_AGENTS.md"))
      refute Enum.any?(response.edits, &is_nil(&1.edited_content))

      # One delete row on the target path.
      assert length(response.deletes) == 1
      assert hd(response.deletes).path == "ORG_AGENTS.md"
      assert hd(response.deletes).reason_text == "retired"
      assert is_nil(hd(response.deletes).edited_content)
    end

    test "workspace_id scoping — only rows in the caller-supplied workspace are returned" do
      wa = Ecto.UUID.generate()
      wb = Ecto.UUID.generate()

      _a_edit = seed_edit(%{path: "ORG_AGENTS.md", workspace_id: wa, original_content: "A-edit"})

      _a_del =
        seed_delete(%{path: "ORG_AGENTS.md", workspace_id: wa, original_content: "A-del"})

      _b_edit = seed_edit(%{path: "ORG_AGENTS.md", workspace_id: wb, original_content: "B-edit"})

      _b_del =
        seed_delete(%{path: "ORG_AGENTS.md", workspace_id: wb, original_content: "B-del"})

      {:ok, response} =
        ToolSurface.execute(
          "org_memory_feedback_at_path",
          %{"path" => "ORG_AGENTS.md", "workspace_id" => wa},
          %{}
        )

      assert length(response.edits) == 1
      assert hd(response.edits).original_content == "A-edit"

      assert length(response.deletes) == 1
      assert hd(response.deletes).original_content == "A-del"
    end

    test "prefix-neighbours are filtered out — exact path match only" do
      # If the caller queries `ORG_MEMORY.md` we must not return the
      # prefix-neighbour `ORG_MEMORY_ARCHIVE.md`, even though the
      # underlying `list_recent/1` uses an ilike-prefix query.
      _neighbour =
        seed_edit(%{path: "ORG_MEMORY_ARCHIVE.md", original_content: "neighbour"})

      {:ok, response} =
        ToolSurface.execute("org_memory_feedback_at_path", %{"path" => "ORG_MEMORY.md"}, %{})

      assert response.edits == []
      assert response.deletes == []
    end

    test "returns a `path` argument error envelope when path is missing" do
      assert {:error, envelope} =
               ToolSurface.execute("org_memory_feedback_at_path", %{}, %{})

      assert envelope[:recoverable] == true
      assert envelope[:error] =~ "path"
    end
  end
end
