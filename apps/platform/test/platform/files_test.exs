defmodule Platform.FilesTest do
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Files
  alias Platform.Files.File, as: PlatformFile
  alias Platform.Tasks

  describe "create_file/1" do
    test "creates a file with valid attrs" do
      {:ok, project} = Tasks.create_project(%{name: "Files Happy"})

      attrs = %{
        project_id: project.id,
        name: "Sample Doc",
        original_filename: "sample.pdf",
        content_type: "application/pdf",
        byte_size: 1024,
        storage_key: "files/#{project.id}/abc/sample.pdf",
        content_hash: String.duplicate("a", 64)
      }

      assert {:ok, %PlatformFile{} = file} = Files.create_file(attrs)
      assert file.project_id == project.id
      assert file.content_type == "application/pdf"
      assert file.byte_size == 1024
      assert file.content_hash == String.duplicate("a", 64)
      assert file.org_id == nil
    end

    test "changeset rejects nil project_id" do
      attrs = %{
        project_id: nil,
        content_type: "text/plain",
        byte_size: 10,
        storage_key: "files/x/y/z.txt",
        content_hash: String.duplicate("b", 64)
      }

      assert {:error, changeset} = Files.create_file(attrs)
      assert %{project_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "FK violation surfaces friendly error when project_id is bogus" do
      bogus = Ecto.UUID.generate()

      attrs = %{
        project_id: bogus,
        content_type: "text/plain",
        byte_size: 10,
        storage_key: "files/#{bogus}/y/z.txt",
        content_hash: String.duplicate("c", 64)
      }

      assert {:error, changeset} = Files.create_file(attrs)
      assert %{project_id: ["does not exist"]} = errors_on(changeset)
    end

    test "same content_hash is allowed across two projects" do
      {:ok, project_a} = Tasks.create_project(%{name: "Project Alpha"})
      {:ok, project_b} = Tasks.create_project(%{name: "Project Bravo"})
      hash = String.duplicate("d", 64)

      assert {:ok, _file_a} =
               Files.create_file(%{
                 project_id: project_a.id,
                 content_type: "text/plain",
                 byte_size: 5,
                 storage_key: "files/#{project_a.id}/aaa/note.txt",
                 content_hash: hash
               })

      assert {:ok, _file_b} =
               Files.create_file(%{
                 project_id: project_b.id,
                 content_type: "text/plain",
                 byte_size: 5,
                 storage_key: "files/#{project_b.id}/bbb/note.txt",
                 content_hash: hash
               })
    end

    test "same content_hash in the same project is rejected" do
      {:ok, project} = Tasks.create_project(%{name: "Dedup Within"})
      hash = String.duplicate("e", 64)

      assert {:ok, _} =
               Files.create_file(%{
                 project_id: project.id,
                 content_type: "text/plain",
                 byte_size: 3,
                 storage_key: "files/#{project.id}/k1/a.txt",
                 content_hash: hash
               })

      assert {:error, changeset} =
               Files.create_file(%{
                 project_id: project.id,
                 content_type: "text/plain",
                 byte_size: 3,
                 storage_key: "files/#{project.id}/k2/b.txt",
                 content_hash: hash
               })

      assert %{content_hash: ["already exists in this project"]} = errors_on(changeset)
    end

    test "duplicate storage_key is rejected globally" do
      {:ok, project} = Tasks.create_project(%{name: "Storage Key Unique"})
      key = "files/#{project.id}/shared/same.txt"

      assert {:ok, _} =
               Files.create_file(%{
                 project_id: project.id,
                 content_type: "text/plain",
                 byte_size: 1,
                 storage_key: key,
                 content_hash: String.duplicate("f", 64)
               })

      assert {:error, changeset} =
               Files.create_file(%{
                 project_id: project.id,
                 content_type: "text/plain",
                 byte_size: 1,
                 storage_key: key,
                 content_hash: String.duplicate("0", 64)
               })

      assert %{storage_key: ["must be unique"]} = errors_on(changeset)
    end

    test "honors an explicitly-passed org_id" do
      {:ok, project} = Tasks.create_project(%{name: "Org-scoped File"})
      org_id = tenant_org_id("soylent")

      assert {:ok, file} =
               Files.create_file(%{
                 project_id: project.id,
                 org_id: org_id,
                 content_type: "application/pdf",
                 byte_size: 42,
                 storage_key: "files/#{project.id}/orgctx/x.pdf",
                 content_hash: String.duplicate("9", 64)
               })

      assert file.org_id == org_id
    end

    test "byte_size and content_type round-trip from changeset" do
      {:ok, project} = Tasks.create_project(%{name: "Round Trip"})

      attrs = %{
        project_id: project.id,
        content_type: "image/png",
        byte_size: 2048,
        storage_key: "files/#{project.id}/img/photo.png",
        content_hash: String.duplicate("1", 64)
      }

      assert {:ok, file} = Files.create_file(attrs)
      assert file.content_type == "image/png"
      assert file.byte_size == 2048
    end

    test "negative byte_size is rejected" do
      {:ok, project} = Tasks.create_project(%{name: "Bad Size"})

      attrs = %{
        project_id: project.id,
        content_type: "text/plain",
        byte_size: -1,
        storage_key: "files/#{project.id}/neg/n.txt",
        content_hash: String.duplicate("2", 64)
      }

      assert {:error, changeset} = Files.create_file(attrs)
      assert %{byte_size: ["must be greater than or equal to 0"]} = errors_on(changeset)
    end
  end

  describe "get_file/1" do
    test "returns the file when present" do
      {:ok, project} = Tasks.create_project(%{name: "Getter"})

      {:ok, file} =
        Files.create_file(%{
          project_id: project.id,
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project.id}/g/g.txt",
          content_hash: String.duplicate("3", 64)
        })

      assert Files.get_file(file.id).id == file.id
    end

    test "returns nil when absent" do
      assert Files.get_file(Ecto.UUID.generate()) == nil
    end
  end

  describe "list_files_for_project/2" do
    test "returns only the requested project's files, newest first" do
      {:ok, project_a} = Tasks.create_project(%{name: "List A"})
      {:ok, project_b} = Tasks.create_project(%{name: "List B"})

      {:ok, _a1} =
        Files.create_file(%{
          project_id: project_a.id,
          original_filename: "older.txt",
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project_a.id}/a1/older.txt",
          content_hash: String.duplicate("4", 64)
        })

      # Force a different inserted_at by sleeping a hair past UUIDv7 + the
      # utc_datetime_usec stamp resolution. 5ms is plenty.
      Process.sleep(5)

      {:ok, a2} =
        Files.create_file(%{
          project_id: project_a.id,
          original_filename: "newer.txt",
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project_a.id}/a2/newer.txt",
          content_hash: String.duplicate("5", 64)
        })

      {:ok, _b1} =
        Files.create_file(%{
          project_id: project_b.id,
          original_filename: "other.txt",
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project_b.id}/b1/other.txt",
          content_hash: String.duplicate("6", 64)
        })

      results = Files.list_files_for_project(project_a.id)

      assert length(results) == 2
      assert hd(results).id == a2.id
      assert Enum.all?(results, &(&1.project_id == project_a.id))
    end

    test "honors :limit" do
      {:ok, project} = Tasks.create_project(%{name: "Limit Test"})

      for i <- 1..3 do
        {:ok, _} =
          Files.create_file(%{
            project_id: project.id,
            content_type: "text/plain",
            byte_size: 1,
            storage_key: "files/#{project.id}/limit/#{i}.txt",
            content_hash: String.duplicate(Integer.to_string(i), 64)
          })
      end

      assert length(Files.list_files_for_project(project.id, limit: 2)) == 2
    end

    test "honors :content_type filter" do
      {:ok, project} = Tasks.create_project(%{name: "Filter Test"})

      {:ok, _txt} =
        Files.create_file(%{
          project_id: project.id,
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project.id}/ft/a.txt",
          content_hash: String.duplicate("7", 64)
        })

      {:ok, png} =
        Files.create_file(%{
          project_id: project.id,
          content_type: "image/png",
          byte_size: 1,
          storage_key: "files/#{project.id}/ft/a.png",
          content_hash: String.duplicate("8", 64)
        })

      results = Files.list_files_for_project(project.id, content_type: "image/png")

      assert length(results) == 1
      assert hd(results).id == png.id
    end

    test "returns an empty list when the project has no files" do
      {:ok, project} = Tasks.create_project(%{name: "Empty"})
      assert Files.list_files_for_project(project.id) == []
    end
  end

  # NOTE: the legacy hard-delete `delete_file/1` was removed in task
  # 019f7cb0 stage 4 (the MCP `file_delete` tool was its last caller —
  # it now rides the soft-delete `delete_file/2`). Soft delete + restore
  # are covered in `Platform.Files.SoftDeleteTest`; permanent removal in
  # `Platform.Files.PurgerTest`.

  describe "update_ingest_status/2" do
    test "flips a file row through the lifecycle" do
      {:ok, project} = Tasks.create_project(%{name: "Status Lifecycle"})

      {:ok, file} =
        Files.create_file(%{
          project_id: project.id,
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project.id}/st/s.txt",
          content_hash: String.duplicate("b", 64)
        })

      assert file.ingest_status == "pending"

      assert {:ok, %{ingest_status: "ingested"}} =
               Files.update_ingest_status(file, "ingested")

      reloaded = Files.get_file(file.id)
      assert reloaded.ingest_status == "ingested"

      assert {:ok, %{ingest_status: "failed"}} =
               Files.update_ingest_status(reloaded, "failed")
    end
  end

  describe "find_ingested_sibling/2" do
    test "returns the most recent ingested row with matching project + hash" do
      {:ok, project} = Tasks.create_project(%{name: "Dedup Search"})
      hash = String.duplicate("c", 64)

      {:ok, pending} =
        Files.create_file(%{
          project_id: project.id,
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project.id}/d1/p.txt",
          content_hash: hash
        })

      # Pending row should not match — dedup only short-circuits when
      # the prior upload actually finished embedding.
      assert Files.find_ingested_sibling(project.id, hash) == nil

      Files.update_ingest_status(pending, "ingested")
      assert match = Files.find_ingested_sibling(project.id, hash)
      assert match.id == pending.id
    end

    test "is scoped per-project; same hash in another project does not match" do
      {:ok, project_a} = Tasks.create_project(%{name: "Sibling A"})
      {:ok, project_b} = Tasks.create_project(%{name: "Sibling B"})

      hash = String.duplicate("d", 64)

      {:ok, file_a} =
        Files.create_file(%{
          project_id: project_a.id,
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project_a.id}/sib/a.txt",
          content_hash: hash
        })

      Files.update_ingest_status(file_a, "ingested")

      assert Files.find_ingested_sibling(project_b.id, hash) == nil
    end
  end

  describe "insert_chunk/1 + list_chunks_for_file/1" do
    test "round-trips a chunk linkage" do
      {:ok, project} = Tasks.create_project(%{name: "Chunks Round Trip"})

      {:ok, file} =
        Files.create_file(%{
          project_id: project.id,
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project.id}/c/c.txt",
          content_hash: String.duplicate("e", 64)
        })

      assert {:ok, chunk} =
               Files.insert_chunk(%{
                 file_id: file.id,
                 chunk_external_id: "ext-1",
                 page: nil
               })

      assert chunk.file_id == file.id
      assert chunk.chunk_external_id == "ext-1"

      assert [^chunk] = Files.list_chunks_for_file(file.id)
    end

    test "duplicate (file_id, chunk_external_id) collides" do
      {:ok, project} = Tasks.create_project(%{name: "Chunks Unique"})

      {:ok, file} =
        Files.create_file(%{
          project_id: project.id,
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project.id}/cu/u.txt",
          content_hash: String.duplicate("a", 64)
        })

      assert {:ok, _} =
               Files.insert_chunk(%{file_id: file.id, chunk_external_id: "ext-dupe"})

      assert {:error, changeset} =
               Files.insert_chunk(%{file_id: file.id, chunk_external_id: "ext-dupe"})

      assert %{file_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
