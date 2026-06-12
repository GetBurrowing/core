defmodule Platform.Org.ContextTest do
  @moduledoc "Tests for org context file and memory entry schemas + seeds."
  use Platform.DataCase, async: true

  alias Platform.Org.WikiPage
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.Seeds
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
end
