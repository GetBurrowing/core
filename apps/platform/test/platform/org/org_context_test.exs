defmodule Platform.Org.ContextTest do
  @moduledoc "Tests for org context file and memory entry schemas + seeds."
  use Platform.DataCase, async: true

  alias Platform.Org.ContextFile
  alias Platform.Org.MemoryEntry
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
    Repo.delete_all(ContextFile)
  end

  # ── ContextFile schema ──────────────────────────────────────────────────

  describe "ContextFile changeset" do
    test "valid changeset with required fields" do
      changeset =
        ContextFile.changeset(%ContextFile{}, %{
          file_key: "ORG_IDENTITY.md",
          content: "# Identity"
        })

      assert changeset.valid?
    end

    test "requires file_key" do
      changeset = ContextFile.changeset(%ContextFile{}, %{content: "test"})
      refute changeset.valid?
      assert %{file_key: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates file_key is in allowed list" do
      changeset =
        ContextFile.changeset(%ContextFile{}, %{
          file_key: "INVALID.md",
          content: "test"
        })

      refute changeset.valid?
      assert %{file_key: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts all allowed file keys" do
      for key <- ContextFile.allowed_file_keys() do
        changeset =
          ContextFile.changeset(%ContextFile{}, %{
            file_key: key,
            content: "test content"
          })

        assert changeset.valid?, "Expected #{key} to be valid"
      end
    end

    test "defaults version to 1" do
      clear_seeded_files()

      {:ok, file} =
        %ContextFile{}
        |> ContextFile.changeset(%{file_key: "ORG_IDENTITY.md", content: "test"})
        |> Repo.insert()

      assert file.version == 1
    end
  end

  # ── ContextFile update changeset ────────────────────────────────────────

  describe "ContextFile update_changeset" do
    test "updates content and increments version" do
      clear_seeded_files()

      {:ok, file} =
        %ContextFile{}
        |> ContextFile.changeset(%{file_key: "ORG_MEMORY.md", content: "v1"})
        |> Repo.insert()

      assert file.version == 1

      changeset =
        ContextFile.update_changeset(file, %{content: "v2"})

      assert changeset.valid?
    end

    test "requires content on update" do
      clear_seeded_files()

      {:ok, file} =
        %ContextFile{}
        |> ContextFile.changeset(%{file_key: "ORG_AGENTS.md", content: "v1"})
        |> Repo.insert()

      changeset = ContextFile.update_changeset(file, %{content: nil})
      refute changeset.valid?
    end
  end

  # ── ContextFile uniqueness ─────────────────────────────────────────────

  describe "ContextFile uniqueness" do
    test "prevents duplicate file_key for same workspace_id" do
      clear_seeded_files()

      {:ok, _} =
        %ContextFile{}
        |> ContextFile.changeset(%{file_key: "ORG_IDENTITY.md", content: "first"})
        |> Repo.insert()

      {:error, changeset} =
        %ContextFile{}
        |> ContextFile.changeset(%{file_key: "ORG_IDENTITY.md", content: "second"})
        |> Repo.insert()

      assert %{workspace_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows same file_key with different workspace_ids" do
      clear_seeded_files()
      ws1 = Ecto.UUID.generate()
      ws2 = Ecto.UUID.generate()

      {:ok, _} =
        %ContextFile{}
        |> ContextFile.changeset(%{
          file_key: "ORG_IDENTITY.md",
          content: "ws1",
          workspace_id: ws1
        })
        |> Repo.insert()

      {:ok, file2} =
        %ContextFile{}
        |> ContextFile.changeset(%{
          file_key: "ORG_IDENTITY.md",
          content: "ws2",
          workspace_id: ws2
        })
        |> Repo.insert()

      assert file2.workspace_id == ws2
    end
  end

  # ── MemoryEntry schema ─────────────────────────────────────────────────

  describe "MemoryEntry changeset" do
    test "valid changeset with required fields" do
      changeset =
        MemoryEntry.changeset(%MemoryEntry{}, %{
          content: "Decided to use FHIR R4",
          date: ~D[2026-04-08]
        })

      assert changeset.valid?
    end

    test "requires content and date" do
      changeset = MemoryEntry.changeset(%MemoryEntry{}, %{})
      refute changeset.valid?
      assert %{content: ["can't be blank"], date: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates memory_type is daily or long_term" do
      changeset =
        MemoryEntry.changeset(%MemoryEntry{}, %{
          content: "test",
          date: ~D[2026-04-08],
          memory_type: "invalid"
        })

      refute changeset.valid?
      assert %{memory_type: ["is invalid"]} = errors_on(changeset)
    end

    test "defaults memory_type to daily" do
      {:ok, entry} =
        %MemoryEntry{}
        |> MemoryEntry.changeset(%{
          content: "Daily note",
          date: ~D[2026-04-08]
        })
        |> Repo.insert()

      assert entry.memory_type == "daily"
    end

    test "inserts with metadata" do
      {:ok, entry} =
        %MemoryEntry{}
        |> MemoryEntry.changeset(%{
          content: "Architectural decision",
          date: ~D[2026-04-08],
          memory_type: "long_term",
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

      files = Repo.all(ContextFile)
      file_keys = Enum.map(files, & &1.file_key) |> Enum.sort()

      assert file_keys == [
               "ORG_AGENTS.md",
               "ORG_IDENTITY.md",
               "ORG_MEMORY.md"
             ]
    end

    test "is idempotent — calling twice does not create duplicates" do
      clear_seeded_files()
      :ok = Seeds.seed_defaults()
      :ok = Seeds.seed_defaults()

      files = Repo.all(ContextFile)
      assert length(files) == 4
    end

    test "does not overwrite existing content" do
      clear_seeded_files()
      :ok = Seeds.seed_defaults()

      file = Repo.get_by!(ContextFile, file_key: "ORG_IDENTITY.md")

      file
      |> ContextFile.update_changeset(%{content: "Custom identity"})
      |> Repo.update!()

      :ok = Seeds.seed_defaults()

      updated = Repo.get_by!(ContextFile, file_key: "ORG_IDENTITY.md")
      assert updated.content == "Custom identity"
    end

    test "default files have non-empty content" do
      clear_seeded_files()
      :ok = Seeds.seed_defaults()

      files = Repo.all(ContextFile)

      for file <- files do
        assert String.length(file.content) > 0,
               "Expected #{file.file_key} to have content"
      end
    end
  end
end
