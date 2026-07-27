defmodule Platform.Org.ContextTest do
  @moduledoc "Tests for org context file and memory entry schemas + seeds."
  use Platform.DataCase, async: true

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.MemoryFeedback.Entry, as: FeedbackEntry
  alias Platform.Org.Context
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.Seeds
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  # Delete seeded context files to start each test with a clean slate.
  # The seed migration inserts defaults that would conflict with test inserts.
  defp clear_seeded_files do
    Repo.delete_all(WikiPage)
  end

  # ── WikiPage schema ──────────────────────────────────────────────────

  describe "WikiPage changeset" do
    test "valid changeset with required fields" do
      changeset =
        WikiPage.changeset(%WikiPage{}, %{
          file_key: "org/identity.md",
          content: "# Identity"
        })

      assert changeset.valid?
    end

    test "requires file_key" do
      changeset = WikiPage.changeset(%WikiPage{}, %{content: "test"})
      refute changeset.valid?
      assert %{file_key: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts arbitrary path-style file_keys (whitelist relaxed in T1)" do
      # Mix of legacy uppercase (still accepted for back-compat at the
      # changeset layer — alias resolution lives in Platform.Org.Context)
      # and modern path-style keys including non-org/ namespaces unlocked
      # by the whitelist removal.
      for key <- ~w(
            ORG_IDENTITY.md
            ORG_MEMORY.md
            ORG_AGENTS.md
            org/identity.md
            project/abc-123/decisions/2026-05.md
            private/sloane/notes.md
          ) do
        changeset =
          WikiPage.changeset(%WikiPage{}, %{
            file_key: key,
            content: "test content"
          })

        assert changeset.valid?, "Expected #{key} to be valid"
      end
    end

    test "defaults version to 1" do
      clear_seeded_files()

      {:ok, file} =
        %WikiPage{}
        |> WikiPage.changeset(%{file_key: "org/identity.md", content: "test"})
        |> Repo.insert()

      assert file.version == 1
    end
  end

  # ── WikiPage update changeset ────────────────────────────────────────

  describe "WikiPage update_changeset" do
    test "updates content and increments version" do
      clear_seeded_files()

      {:ok, file} =
        %WikiPage{}
        |> WikiPage.changeset(%{file_key: "org/memory.md", content: "v1"})
        |> Repo.insert()

      assert file.version == 1

      changeset =
        WikiPage.update_changeset(file, %{content: "v2"})

      assert changeset.valid?
    end

    test "requires content on update" do
      clear_seeded_files()

      {:ok, file} =
        %WikiPage{}
        |> WikiPage.changeset(%{file_key: "org/agents.md", content: "v1"})
        |> Repo.insert()

      changeset = WikiPage.update_changeset(file, %{content: nil})
      refute changeset.valid?
    end
  end

  # ── WikiPage uniqueness ─────────────────────────────────────────────

  describe "WikiPage uniqueness" do
    test "prevents duplicate file_key for same workspace_id" do
      clear_seeded_files()

      {:ok, _} =
        %WikiPage{}
        |> WikiPage.changeset(%{file_key: "org/identity.md", content: "first"})
        |> Repo.insert()

      {:error, changeset} =
        %WikiPage{}
        |> WikiPage.changeset(%{file_key: "org/identity.md", content: "second"})
        |> Repo.insert()

      assert %{workspace_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows same file_key with different workspace_ids" do
      clear_seeded_files()
      ws1 = Ecto.UUID.generate()
      ws2 = Ecto.UUID.generate()

      {:ok, _} =
        %WikiPage{}
        |> WikiPage.changeset(%{
          file_key: "org/identity.md",
          content: "ws1",
          workspace_id: ws1
        })
        |> Repo.insert()

      {:ok, file2} =
        %WikiPage{}
        |> WikiPage.changeset(%{
          file_key: "org/identity.md",
          content: "ws2",
          workspace_id: ws2
        })
        |> Repo.insert()

      assert file2.workspace_id == ws2
    end
  end

  # ── WikiJournalEntry schema ─────────────────────────────────────────────────

  describe "WikiJournalEntry changeset" do
    test "valid changeset with required fields" do
      changeset =
        WikiJournalEntry.changeset(%WikiJournalEntry{}, %{
          content: "Decided to use FHIR R4",
          date: ~D[2026-04-08]
        })

      assert changeset.valid?
    end

    test "requires content and date" do
      changeset = WikiJournalEntry.changeset(%WikiJournalEntry{}, %{})
      refute changeset.valid?
      assert %{content: ["can't be blank"], date: ["can't be blank"]} = errors_on(changeset)
    end

    test "inserts with metadata" do
      {:ok, entry} =
        %WikiJournalEntry{}
        |> WikiJournalEntry.changeset(%{
          content: "Architectural decision",
          date: ~D[2026-04-08],
          metadata: %{"tags" => ["architecture", "decision"]}
        })
        |> Repo.insert()

      assert entry.metadata == %{"tags" => ["architecture", "decision"]}
    end
  end

  # ── Seeds ──────────────────────────────────────────────────────────────

  describe "Seeds.seed_defaults/1" do
    test "creates all default org context files" do
      clear_seeded_files()
      :ok = Seeds.seed_defaults()

      files = Repo.all(WikiPage)
      file_keys = Enum.map(files, & &1.file_key) |> Enum.sort()

      # Page-grammar keys (`<ns>/page/<rest>`) since the 2026-06-11
      # key migration — flat keys are no longer seeded.
      assert file_keys == [
               "org/page/agents.md",
               "org/page/identity.md",
               "org/page/memory.md"
             ]
    end

    test "is idempotent — calling twice does not create duplicates" do
      clear_seeded_files()
      :ok = Seeds.seed_defaults()
      :ok = Seeds.seed_defaults()

      files = Repo.all(WikiPage)
      assert length(files) == 3
    end

    test "does not overwrite existing content" do
      clear_seeded_files()
      :ok = Seeds.seed_defaults()

      file = Repo.get_by!(WikiPage, file_key: "org/page/identity.md")

      file
      |> WikiPage.update_changeset(%{content: "Custom identity"})
      |> Repo.update!()

      :ok = Seeds.seed_defaults()

      updated = Repo.get_by!(WikiPage, file_key: "org/page/identity.md")
      assert updated.content == "Custom identity"
    end

    test "default files have non-empty content" do
      clear_seeded_files()
      :ok = Seeds.seed_defaults()

      files = Repo.all(WikiPage)

      for file <- files do
        assert String.length(file.content) > 0,
               "Expected #{file.file_key} to have content"
      end
    end
  end

  # ── Memory-feedback capture (stage 2) ────────────────────────────────
  #
  # These assertions cover the invariant that every write-path mutation
  # against `Platform.Org.Context` produces exactly one append-only row
  # in `org_memory_feedback`, and that a rolled-back mutation (stale
  # optimistic lock) leaves the ledger untouched.

  describe "upsert_context_file/3 feedback capture" do
    setup do
      clear_seeded_files()
      # Feedback rows accumulate across the test DB; snapshot a baseline
      # so assertions are relative to work this test performed.
      {:ok, baseline: Repo.aggregate(FeedbackEntry, :count, :id)}
    end

    test "first-create writes ZERO feedback rows", %{baseline: baseline} do
      assert {:ok, %WikiPage{}} =
               Context.upsert_context_file("org/page/identity.md", %{
                 content: "brand-new",
                 updated_by: Ecto.UUID.generate()
               })

      assert Repo.aggregate(FeedbackEntry, :count, :id) == baseline
    end

    test "edit round-trip writes ONE feedback row with edit shape", %{baseline: baseline} do
      author_a = Ecto.UUID.generate()
      author_b = Ecto.UUID.generate()

      {:ok, _v1} =
        Context.upsert_context_file("org/page/memory.md", %{
          content: "roster v1",
          updated_by: author_a
        })

      # First-create didn't emit anything.
      assert Repo.aggregate(FeedbackEntry, :count, :id) == baseline

      {:ok, _v2} =
        Context.upsert_context_file("org/page/memory.md", %{
          content: "roster v2",
          updated_by: author_b
        })

      assert Repo.aggregate(FeedbackEntry, :count, :id) == baseline + 1

      row =
        FeedbackEntry
        |> last_inserted()

      assert row.feedback_kind == "edit"
      assert row.original_content == "roster v1"
      assert row.edited_content == "roster v2"
      assert row.path == "org/page/memory.md"
      assert row.namespace == "org_context"
      assert row.original_author_id == author_a
      assert row.editor_id == author_b
    end

    test "stale optimistic-lock rollback leaves no orphan feedback row",
         %{baseline: baseline} do
      author = Ecto.UUID.generate()

      {:ok, v1} =
        Context.upsert_context_file("org/page/agents.md", %{
          content: "v1",
          updated_by: author
        })

      # Race: caller believes we're still on v1's predecessor (version 0).
      # `expected_version: 0` mismatches the actual v1, so the txn rolls
      # back with `:stale` and the feedback row must NOT be inserted.
      assert {:error, :stale} =
               Context.upsert_context_file(
                 "org/page/agents.md",
                 %{content: "v2-lost", updated_by: author},
                 expected_version: 0
               )

      # Baseline unchanged — the rolled-back branch never wrote either
      # the WikiPage update or a feedback row.
      assert Repo.aggregate(FeedbackEntry, :count, :id) == baseline

      # Version still v1's version (no successful update happened).
      assert %WikiPage{version: unchanged_version} =
               Context.get_file("org/page/agents.md")

      assert unchanged_version == v1.version
    end
  end

  describe "delete_file/2 feedback capture" do
    setup do
      clear_seeded_files()
      {:ok, baseline: Repo.aggregate(FeedbackEntry, :count, :id)}
    end

    test "delete writes ONE feedback row with delete shape", %{baseline: baseline} do
      author = Ecto.UUID.generate()
      deleter = Ecto.UUID.generate()

      {:ok, _} =
        Context.upsert_context_file("org/page/agents.md", %{
          content: "content-to-delete",
          updated_by: author
        })

      assert {:ok, %WikiPage{}} =
               Context.delete_file("org/page/agents.md",
                 editor_id: deleter,
                 reason: "outdated"
               )

      assert Repo.aggregate(FeedbackEntry, :count, :id) == baseline + 1
      assert is_nil(Context.get_file("org/page/agents.md"))

      row = last_inserted(FeedbackEntry)
      assert row.feedback_kind == "delete"
      assert row.original_content == "content-to-delete"
      assert is_nil(row.edited_content)
      assert row.path == "org/page/agents.md"
      assert row.namespace == "org_context"
      assert row.original_author_id == author
      assert row.editor_id == deleter
      assert row.reason_text == "outdated"
    end

    test "delete of a missing file returns {:error, :not_found} and writes no row",
         %{baseline: baseline} do
      assert {:error, :not_found} = Context.delete_file("org/page/does-not-exist.md")
      assert Repo.aggregate(FeedbackEntry, :count, :id) == baseline
    end

    test "delete_file/1 (no opts) still works — editor_id defaults to nil",
         %{baseline: baseline} do
      {:ok, _} =
        Context.upsert_context_file("org/page/identity.md", %{
          content: "will-be-nuked",
          updated_by: Ecto.UUID.generate()
        })

      assert {:ok, %WikiPage{}} = Context.delete_file("org/page/identity.md")

      assert Repo.aggregate(FeedbackEntry, :count, :id) == baseline + 1
      row = last_inserted(FeedbackEntry)
      assert row.feedback_kind == "delete"
      assert is_nil(row.editor_id)
      assert is_nil(row.reason_text)
    end
  end

  defp last_inserted(schema) do
    import Ecto.Query
    Repo.one(from(r in schema, order_by: [desc: r.inserted_at, desc: r.id], limit: 1))
  end

  # ── resolve_authors/1 (task 019f671f stage 2) ─────────────────────────
  #
  # Memory-entry authors must still resolve to their display name after
  # the user is archived. `resolve_authors/1` overrides the Stage-1
  # `include_archived: false` default via `Accounts.get_users_map(ids,
  # include_archived: true)` — this test is the regression guard for
  # that explicit override.
  describe "resolve_authors/1 with archived user" do
    test "still returns display name for a memory entry authored by an archived user" do
      author =
        Repo.insert!(%User{
          email: "author_#{System.unique_integer([:positive])}@example.com",
          name: "Archived Author",
          oidc_sub: "oidc-author-#{System.unique_integer([:positive])}"
        })

      {:ok, entry} =
        %WikiJournalEntry{}
        |> WikiJournalEntry.changeset(%{
          content: "Historical decision by a since-archived user.",
          date: ~D[2026-04-08],
          authored_by: author.id
        })
        |> Repo.insert()

      {:ok, _archived} = Accounts.archive_user(author)

      resolved = OrgContext.resolve_authors([entry])

      assert %{kind: :user, name: "Archived Author"} = Map.fetch!(resolved, author.id)
    end

    test "returns display name for an active user (baseline)" do
      author =
        Repo.insert!(%User{
          email: "author_active_#{System.unique_integer([:positive])}@example.com",
          name: "Active Author",
          oidc_sub: "oidc-author-active-#{System.unique_integer([:positive])}"
        })

      {:ok, entry} =
        %WikiJournalEntry{}
        |> WikiJournalEntry.changeset(%{
          content: "Recent decision.",
          date: ~D[2026-06-01],
          authored_by: author.id
        })
        |> Repo.insert()

      resolved = OrgContext.resolve_authors([entry])

      assert %{kind: :user, name: "Active Author"} = Map.fetch!(resolved, author.id)
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  # The 16-character case is the load-bearing one: `Ecto.UUID.cast/1` accepts
  # any 16-byte binary, so a test built from "higgins" alone is green against
  # the bug these guards fix.
  describe "UUID boundary: get_file_by_id/1" do
    test "returns nil for a malformed page id rather than raising" do
      assert OrgContext.get_file_by_id("higgins") == nil
      assert OrgContext.get_file_by_id("higginshigginsxx") == nil
    end
  end
end
