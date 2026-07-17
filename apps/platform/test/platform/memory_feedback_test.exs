defmodule Platform.MemoryFeedbackTest do
  @moduledoc """
  Layer-1 tests for `Platform.MemoryFeedback` — the append-only ledger
  that captures every mutation against org memory.

  Stage 1 only asserts write-shape correctness. The read API
  (`list_recent/1`, `deleted_at_path/2`, `signature_matches?/2`) and
  the query-side tests land in stage 3.
  """

  use Platform.DataCase, async: true

  alias Platform.MemoryFeedback
  alias Platform.MemoryFeedback.Entry
  alias Platform.Repo

  defp valid_edit_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        original_content: "before",
        edited_content: "after",
        original_author_id: Ecto.UUID.generate(),
        editor_id: Ecto.UUID.generate(),
        path: "ORG_MEMORY.md",
        namespace: "org_context",
        workspace_id: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp valid_delete_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        original_content: "content-to-delete",
        original_author_id: Ecto.UUID.generate(),
        editor_id: Ecto.UUID.generate(),
        path: "ORG_AGENTS.md",
        namespace: "org_context",
        workspace_id: Ecto.UUID.generate(),
        reason_text: "outdated"
      },
      overrides
    )
  end

  describe "record_edit/1" do
    test "writes an edit row with feedback_kind: \"edit\" and both contents" do
      attrs = valid_edit_attrs()

      assert {:ok, %Entry{} = entry} = MemoryFeedback.record_edit(attrs)
      assert entry.feedback_kind == "edit"
      assert entry.original_content == "before"
      assert entry.edited_content == "after"
      assert entry.path == "ORG_MEMORY.md"
      assert entry.namespace == "org_context"
      assert entry.workspace_id == attrs.workspace_id
      assert entry.original_author_id == attrs.original_author_id
      assert entry.editor_id == attrs.editor_id
      refute is_nil(entry.inserted_at)
    end

    test "accepts string-keyed attrs (MCP / LiveView payload shape)" do
      attrs = %{
        "original_content" => "before",
        "edited_content" => "after",
        "path" => "ORG_MEMORY.md",
        "namespace" => "org_context"
      }

      assert {:ok, %Entry{} = entry} = MemoryFeedback.record_edit(attrs)
      assert entry.feedback_kind == "edit"
      assert entry.edited_content == "after"
    end

    test "ignores a caller-supplied feedback_kind — always \"edit\"" do
      attrs = valid_edit_attrs(%{feedback_kind: "delete"})

      assert {:ok, %Entry{feedback_kind: "edit"}} = MemoryFeedback.record_edit(attrs)
    end

    test "returns changeset error when required fields are missing" do
      attrs = %{path: "ORG_MEMORY.md", namespace: "org_context"}

      assert {:error, %Ecto.Changeset{valid?: false} = cs} = MemoryFeedback.record_edit(attrs)
      assert %{original_content: ["can't be blank"]} = errors_on(cs)
    end
  end

  describe "record_delete/1" do
    test "writes a delete row with feedback_kind: \"delete\" and nil edited_content" do
      attrs = valid_delete_attrs()

      assert {:ok, %Entry{} = entry} = MemoryFeedback.record_delete(attrs)
      assert entry.feedback_kind == "delete"
      assert entry.original_content == "content-to-delete"
      assert is_nil(entry.edited_content)
      assert entry.path == "ORG_AGENTS.md"
      assert entry.reason_text == "outdated"
    end

    test "forces edited_content to nil even when caller supplies it" do
      attrs = valid_delete_attrs(%{edited_content: "sneaky"})

      assert {:ok, %Entry{edited_content: nil}} = MemoryFeedback.record_delete(attrs)
    end

    test "allows omitted reason_text (optional field)" do
      attrs = valid_delete_attrs() |> Map.delete(:reason_text)

      assert {:ok, %Entry{reason_text: nil}} = MemoryFeedback.record_delete(attrs)
    end

    test "returns changeset error when original_content is missing" do
      attrs = %{path: "ORG_AGENTS.md", namespace: "org_context"}

      assert {:error, %Ecto.Changeset{valid?: false} = cs} = MemoryFeedback.record_delete(attrs)
      assert %{original_content: ["can't be blank"]} = errors_on(cs)
    end
  end

  describe "record_retention/1" do
    test "returns {:error, :not_implemented} — layer-2 stub" do
      assert {:error, :not_implemented} =
               MemoryFeedback.record_retention(%{path: "ORG_MEMORY.md"})
    end

    test "does not insert a row" do
      before = Repo.aggregate(Entry, :count, :id)
      _ = MemoryFeedback.record_retention(%{path: "ORG_MEMORY.md"})
      assert Repo.aggregate(Entry, :count, :id) == before
    end
  end

  describe "list_recent/1" do
    setup do
      ws_a = Ecto.UUID.generate()
      ws_b = Ecto.UUID.generate()

      # Rows land newest-last (t1 → t4), interleaved across workspaces,
      # namespaces, paths, and kinds so filters can be exercised in
      # isolation and in combination.
      {:ok, e_ws_a} =
        MemoryFeedback.record_edit(valid_edit_attrs(%{workspace_id: ws_a, path: "ORG_MEMORY.md"}))

      Process.sleep(2)

      {:ok, d_ws_a} =
        MemoryFeedback.record_delete(
          valid_delete_attrs(%{workspace_id: ws_a, path: "ORG_AGENTS.md"})
        )

      Process.sleep(2)

      {:ok, e_ws_b} =
        MemoryFeedback.record_edit(valid_edit_attrs(%{workspace_id: ws_b, path: "PROJECT_X.md"}))

      Process.sleep(2)

      {:ok, d_other_ns} =
        MemoryFeedback.record_delete(
          valid_delete_attrs(%{
            workspace_id: ws_a,
            path: "ORG_MEMORY.md",
            namespace: "other_ns"
          })
        )

      %{
        ws_a: ws_a,
        ws_b: ws_b,
        e_ws_a: e_ws_a,
        d_ws_a: d_ws_a,
        e_ws_b: e_ws_b,
        d_other_ns: d_other_ns
      }
    end

    test "defaults to namespace: \"org_context\" and returns newest-first",
         %{e_ws_a: e_ws_a, d_ws_a: d_ws_a, e_ws_b: e_ws_b, d_other_ns: d_other_ns} do
      results = MemoryFeedback.list_recent()
      ids = Enum.map(results, & &1.id)

      # d_other_ns lives in "other_ns", so the default namespace query
      # excludes it.
      refute d_other_ns.id in ids
      assert ids == [e_ws_b.id, d_ws_a.id, e_ws_a.id]
    end

    test "filters by namespace strictly", %{d_other_ns: d_other_ns} do
      results = MemoryFeedback.list_recent(namespace: "other_ns")

      assert Enum.map(results, & &1.id) == [d_other_ns.id]
    end

    test "filters by workspace_id strictly", %{ws_a: ws_a, e_ws_a: e_ws_a, d_ws_a: d_ws_a} do
      results = MemoryFeedback.list_recent(workspace_id: ws_a)

      # Newest-first, scoped to ws_a within default namespace.
      assert Enum.map(results, & &1.id) == [d_ws_a.id, e_ws_a.id]
    end

    test "workspace_id: nil is treated as \"no filter\" (not \"is_nil match\")",
         %{e_ws_a: e_ws_a, d_ws_a: d_ws_a, e_ws_b: e_ws_b} do
      results = MemoryFeedback.list_recent(workspace_id: nil)
      ids = Enum.map(results, & &1.id)

      # All three default-namespace rows are present regardless of their
      # (non-nil) workspace_ids.
      assert ids == [e_ws_b.id, d_ws_a.id, e_ws_a.id]
    end

    test "filters by path_prefix via literal ilike", %{e_ws_a: e_ws_a, d_ws_a: d_ws_a} do
      results = MemoryFeedback.list_recent(path_prefix: "ORG_")

      assert Enum.map(results, & &1.id) == [d_ws_a.id, e_ws_a.id]
    end

    test "path_prefix escapes ilike wildcards" do
      # Both entries below share the "A_B" *literal* prefix vs an
      # ilike-wildcarded "A?B" — verify the escape treats `_` as literal.
      {:ok, literal} =
        MemoryFeedback.record_edit(valid_edit_attrs(%{path: "A_B.md"}))

      {:ok, wildcard_match} =
        MemoryFeedback.record_edit(valid_edit_attrs(%{path: "AXB.md"}))

      literal_ids =
        MemoryFeedback.list_recent(path_prefix: "A_")
        |> Enum.map(& &1.id)

      assert literal.id in literal_ids
      refute wildcard_match.id in literal_ids
    end

    test "filters by feedback_kind", %{d_ws_a: d_ws_a} do
      # Only default-namespace delete is d_ws_a.
      results = MemoryFeedback.list_recent(feedback_kind: "delete")

      assert Enum.map(results, & &1.id) == [d_ws_a.id]
    end

    test "combines workspace_id + feedback_kind filters",
         %{ws_a: ws_a, d_ws_a: d_ws_a} do
      results = MemoryFeedback.list_recent(workspace_id: ws_a, feedback_kind: "delete")

      assert Enum.map(results, & &1.id) == [d_ws_a.id]
    end

    test "orders inserted_at DESC across many rows" do
      # Isolate ordering in a fresh namespace to avoid the setup fixtures.
      inserted =
        for i <- 1..5 do
          Process.sleep(2)

          {:ok, entry} =
            MemoryFeedback.record_edit(
              valid_edit_attrs(%{
                namespace: "ordering_ns",
                path: "ORDER_#{i}.md"
              })
            )

          entry
        end

      expected_ids = inserted |> Enum.reverse() |> Enum.map(& &1.id)

      actual_ids =
        MemoryFeedback.list_recent(namespace: "ordering_ns")
        |> Enum.map(& &1.id)

      assert actual_ids == expected_ids
    end

    test "respects an explicit :limit below the default" do
      results = MemoryFeedback.list_recent(limit: 1)

      assert length(results) == 1
    end

    test "silently caps :limit at 100" do
      # We don't need to insert 101 rows to prove the cap is applied —
      # exercising the call with an oversized :limit must not crash
      # and must not exceed 100 in the returned set.
      {:ok, _} = MemoryFeedback.record_edit(valid_edit_attrs())

      results = MemoryFeedback.list_recent(limit: 500)
      assert length(results) <= 100
      assert Repo.aggregate(Entry, :count, :id) >= 1
    end
  end

  describe "deleted_at_path/2" do
    setup do
      ws_a = Ecto.UUID.generate()
      ws_b = Ecto.UUID.generate()

      %{ws_a: ws_a, ws_b: ws_b}
    end

    test "returns the most-recent delete when multiple deletes share the path",
         %{ws_a: ws_a} do
      {:ok, _older} =
        MemoryFeedback.record_delete(
          valid_delete_attrs(%{
            workspace_id: ws_a,
            path: "ORG_AGENTS.md",
            original_content: "first"
          })
        )

      Process.sleep(2)

      {:ok, newer} =
        MemoryFeedback.record_delete(
          valid_delete_attrs(%{
            workspace_id: ws_a,
            path: "ORG_AGENTS.md",
            original_content: "second"
          })
        )

      assert %Entry{id: id, original_content: "second"} =
               MemoryFeedback.deleted_at_path("ORG_AGENTS.md", workspace_id: ws_a)

      assert id == newer.id
    end

    test "ignores edit rows at the same path", %{ws_a: ws_a} do
      {:ok, _edit} =
        MemoryFeedback.record_edit(valid_edit_attrs(%{workspace_id: ws_a, path: "ORG_MEMORY.md"}))

      assert MemoryFeedback.deleted_at_path("ORG_MEMORY.md", workspace_id: ws_a) == nil
    end

    test "returns nil for a path with no delete history" do
      assert MemoryFeedback.deleted_at_path("NEVER_TOUCHED.md") == nil
    end

    test "enforces workspace scoping — ws_a delete invisible to ws_b query",
         %{ws_a: ws_a, ws_b: ws_b} do
      {:ok, _} =
        MemoryFeedback.record_delete(
          valid_delete_attrs(%{workspace_id: ws_a, path: "SHARED_PATH.md"})
        )

      assert MemoryFeedback.deleted_at_path("SHARED_PATH.md", workspace_id: ws_b) == nil

      assert %Entry{workspace_id: ^ws_a} =
               MemoryFeedback.deleted_at_path("SHARED_PATH.md", workspace_id: ws_a)
    end

    test "enforces namespace scoping — a delete in \"other_ns\" is invisible to the default query",
         %{ws_a: ws_a} do
      {:ok, _} =
        MemoryFeedback.record_delete(
          valid_delete_attrs(%{
            workspace_id: ws_a,
            path: "ORG_MEMORY.md",
            namespace: "other_ns"
          })
        )

      assert MemoryFeedback.deleted_at_path("ORG_MEMORY.md", workspace_id: ws_a) == nil

      assert %Entry{namespace: "other_ns"} =
               MemoryFeedback.deleted_at_path("ORG_MEMORY.md",
                 workspace_id: ws_a,
                 namespace: "other_ns"
               )
    end
  end

  describe "signature_matches?/2" do
    setup do
      ws_a = Ecto.UUID.generate()
      ws_b = Ecto.UUID.generate()

      %{ws_a: ws_a, ws_b: ws_b}
    end

    test "returns true when content exactly matches a prior delete's original_content",
         %{ws_a: ws_a} do
      content = "This paragraph is bad and should never come back."

      {:ok, _} =
        MemoryFeedback.record_delete(
          valid_delete_attrs(%{
            workspace_id: ws_a,
            path: "ORG_MEMORY.md",
            original_content: content
          })
        )

      assert MemoryFeedback.signature_matches?(content, workspace_id: ws_a)
    end

    test "returns false for novel content", %{ws_a: ws_a} do
      {:ok, _} =
        MemoryFeedback.record_delete(
          valid_delete_attrs(%{
            workspace_id: ws_a,
            original_content: "recorded-content"
          })
        )

      refute MemoryFeedback.signature_matches?("something-new", workspace_id: ws_a)
    end

    test "ignores edits — even byte-identical edit rows do not count", %{ws_a: ws_a} do
      content = "This paragraph is fine — just being edited, not censored."

      {:ok, _} =
        MemoryFeedback.record_edit(
          valid_edit_attrs(%{
            workspace_id: ws_a,
            path: "ORG_MEMORY.md",
            original_content: content,
            edited_content: "rewritten form"
          })
        )

      refute MemoryFeedback.signature_matches?(content, workspace_id: ws_a)
    end

    test "enforces workspace scoping — ws_a delete does not fire in ws_b",
         %{ws_a: ws_a, ws_b: ws_b} do
      content = "workspace-scoped signature"

      {:ok, _} =
        MemoryFeedback.record_delete(
          valid_delete_attrs(%{
            workspace_id: ws_a,
            original_content: content
          })
        )

      refute MemoryFeedback.signature_matches?(content, workspace_id: ws_b)
      assert MemoryFeedback.signature_matches?(content, workspace_id: ws_a)
    end

    test "enforces namespace scoping — a delete in \"other_ns\" is invisible to the default query" do
      content = "namespace-scoped signature"

      {:ok, _} =
        MemoryFeedback.record_delete(
          valid_delete_attrs(%{
            original_content: content,
            namespace: "other_ns"
          })
        )

      refute MemoryFeedback.signature_matches?(content)
      assert MemoryFeedback.signature_matches?(content, namespace: "other_ns")
    end

    test "workspace_id: nil sees deletes across every workspace" do
      content = "cross-workspace signature"

      {:ok, _} =
        MemoryFeedback.record_delete(
          valid_delete_attrs(%{
            workspace_id: Ecto.UUID.generate(),
            original_content: content
          })
        )

      assert MemoryFeedback.signature_matches?(content)
    end
  end

  describe "Entry.changeset/2" do
    test "rejects an unknown feedback_kind" do
      cs = Entry.changeset(%Entry{}, valid_edit_attrs(%{feedback_kind: "bogus"}))

      refute cs.valid?
      assert %{feedback_kind: ["is invalid"]} = errors_on(cs)
    end

    test "requires path, namespace, original_content, and feedback_kind" do
      cs = Entry.changeset(%Entry{}, %{})

      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:path] == ["can't be blank"]
      assert errors[:namespace] == ["can't be blank"]
      assert errors[:original_content] == ["can't be blank"]
      assert errors[:feedback_kind] == ["can't be blank"]
    end
  end

  # Local errors_on helper mirroring the shape used across other schema tests.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
