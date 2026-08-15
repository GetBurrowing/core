defmodule Platform.FilesTest do
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  import ExUnit.CaptureLog

  alias Platform.Files
  alias Platform.Files.File, as: PlatformFile
  alias Platform.Files.Ingester
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

  describe "default ingest intent at create time (task 019fd033 stage 2)" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "platform-files-default-intent-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      previous_root = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, root)

      on_exit(fn ->
        File.rm_rf!(root)

        if previous_root,
          do: Application.put_env(:platform, :chat_attachments_root, previous_root),
          else: Application.delete_env(:platform, :chat_attachments_root)
      end)

      {:ok, project} = Tasks.create_project(%{name: "Default Intent #{System.unique_integer()}"})
      {:ok, project: project, root: root}
    end

    test "round trip: an extractable file reaches the ingester, an unextractable one does not",
         %{project: project, root: root} do
      attach_telemetry([
        [:platform, :files, :ingested, :start],
        [:platform, :files, :ingested, :stop],
        [:platform, :files, :ingested, :exception]
      ])

      pdf = create_stored_file(project, root, "application/pdf", "doc.pdf", "%PDF-1.4 body")
      video = create_stored_file(project, root, "video/mp4", "clip.mp4", "not really mp4")

      # The derived defaults, read back off the persisted rows.
      assert pdf.ingest_intent == "attempt"
      assert video.ingest_intent == "human_only"
      assert video.ingest_status == "not_attempted"

      capture_log(fn ->
        assert :ok = Ingester.ingest_async(pdf)
        assert :ok = Ingester.ingest_async(video)

        # POSITIVE CONTROL: the PDF really was handed to the pipeline.
        # Without this, "no event for the video" would pass even if the
        # ingester were never wired up at all.
        assert_receive {:telemetry, [:platform, :files, :ingested, :start], _, %{file_id: id}},
                       2_000

        assert id == pdf.id

        # Drain the PDF's terminal event so its task is done before the
        # sandbox connection goes away. Extraction of a fake PDF fails;
        # either resolution is fine, we only care that it finished.
        assert_receive {:telemetry, [:platform, :files, :ingested, terminal], _, %{file_id: ^id}},
                       5_000

        assert terminal in [:stop, :exception]

        # REFUTATION: no ingest event ever carried the video's id.
        video_id = video.id
        refute_received {:telemetry, [:platform, :files, :ingested, _], _, %{file_id: ^video_id}}
      end)

      assert Files.get_file(video.id).ingest_status == "not_attempted"
    end

    test "image/png defaults to attempt, application/json defaults to human_only",
         %{project: project} do
      assert Files.default_ingest_intent("image/png") == "attempt"
      assert Files.default_ingest_intent("application/json") == "human_only"

      assert create_file!(project, %{content_type: "image/png"}).ingest_intent == "attempt"

      json = create_file!(project, %{content_type: "application/json"})
      assert json.ingest_intent == "human_only"
      assert json.ingest_status == "not_attempted"
    end

    test "a nil content type defaults to human_only", %{project: project} do
      assert Files.default_ingest_intent(nil) == "human_only"

      # A row with no content_type is unrepresentable — `content_type` is
      # required by File.changeset/2 — so the nil case only ever fires
      # through the derivation itself. Pinned here so a future relaxation
      # of that validation does not silently start creating "attempt"
      # rows for typeless uploads: the derived intent is computed and
      # carried into the changeset either way.
      assert {:error, changeset} = Files.create_file(default_attrs(project, %{content_type: nil}))
      assert %{content_type: ["can't be blank"]} = errors_on(changeset)
      assert changeset.changes.ingest_intent == "human_only"
      assert changeset.changes.ingest_status == "not_attempted"
    end

    test "an explicit intent beats the derived one (atom keys)", %{project: project} do
      file =
        create_file!(project, %{content_type: "application/pdf", ingest_intent: "human_only"})

      assert file.ingest_intent == "human_only"
      assert file.ingest_status == "not_attempted"
    end

    test "an explicit intent beats the derived one (string keys)", %{project: project} do
      assert {:ok, file} =
               Files.create_file(%{
                 "project_id" => project.id,
                 "content_type" => "application/pdf",
                 "byte_size" => 3,
                 "storage_key" => "files/#{project.id}/s/explicit.pdf",
                 "content_hash" => String.duplicate("7", 64),
                 "ingest_intent" => "human_only"
               })

      assert file.ingest_intent == "human_only"
      assert file.ingest_status == "not_attempted"

      # ...and the string-key path still derives when nothing is given.
      assert {:ok, derived} =
               Files.create_file(%{
                 "project_id" => project.id,
                 "content_type" => "application/pdf",
                 "byte_size" => 3,
                 "storage_key" => "files/#{project.id}/s/derived.pdf",
                 "content_hash" => String.duplicate("8", 64)
               })

      assert derived.ingest_intent == "attempt"
    end

    defp create_file!(project, overrides) do
      {:ok, file} = Files.create_file(default_attrs(project, overrides))
      file
    end

    defp default_attrs(project, overrides) do
      Map.merge(
        %{
          project_id: project.id,
          content_type: "text/plain",
          byte_size: 4,
          storage_key: "files/#{project.id}/d/#{System.unique_integer([:positive])}.bin",
          content_hash:
            :crypto.hash(:sha256, "#{System.unique_integer([:positive])}")
            |> Base.encode16(case: :lower)
        },
        overrides
      )
    end

    defp create_stored_file(project, root, content_type, filename, body) do
      storage_key = "files/#{project.id}/#{Ecto.UUID.generate()}/#{filename}"
      abs_path = Path.join(root, storage_key)
      File.mkdir_p!(Path.dirname(abs_path))
      File.write!(abs_path, body)

      create_file!(project, %{
        content_type: content_type,
        name: filename,
        original_filename: filename,
        byte_size: byte_size(body),
        storage_key: storage_key,
        content_hash: :crypto.hash(:sha256, storage_key <> body) |> Base.encode16(case: :lower)
      })
    end

    defp attach_telemetry(events) do
      handler_id = "files-default-intent-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        events,
        fn name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, name, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end
  end

  describe "ingest_intent (task 019fd02d stage 1)" do
    test "a changeset with an unknown intent is invalid" do
      {:ok, project} = Tasks.create_project(%{name: "Intent Unknown"})

      assert {:error, changeset} =
               Files.create_file(%{
                 project_id: project.id,
                 content_type: "text/plain",
                 byte_size: 1,
                 storage_key: "files/#{project.id}/i/unknown.txt",
                 content_hash: String.duplicate("d", 64),
                 ingest_intent: "definitely_not_an_intent"
               })

      assert %{ingest_intent: ["is invalid"]} = errors_on(changeset)
    end

    test "the DB check constraint rejects a forged intent inserted via raw SQL" do
      {:ok, project} = Tasks.create_project(%{name: "Intent Forged"})

      {:ok, file} =
        Files.create_file(%{
          project_id: project.id,
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project.id}/i/forged.txt",
          content_hash: String.duplicate("e", 64)
        })

      # Bypasses the changeset entirely: if the Elixir list were the only
      # guard, this UPDATE would succeed and the test would fail.
      assert_raise Postgrex.Error, ~r/platform_files_ingest_intent_check/, fn ->
        Repo.query!(
          "UPDATE platform_files SET ingest_intent = $1 WHERE id = $2",
          ["definitely_not_an_intent", Ecto.UUID.dump!(file.id)]
        )
      end
    end

    test "a row inserted without an intent reads back as \"attempt\"" do
      {:ok, project} = Tasks.create_project(%{name: "Intent Default"})

      {:ok, file} =
        Files.create_file(%{
          project_id: project.id,
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project.id}/i/default.txt",
          content_hash: String.duplicate("f", 64)
        })

      assert Files.get_file(file.id).ingest_intent == "attempt"
    end

    test "human_only intent round-trips" do
      {:ok, project} = Tasks.create_project(%{name: "Intent Human Only"})

      {:ok, file} =
        Files.create_file(%{
          project_id: project.id,
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project.id}/i/human.txt",
          content_hash: String.duplicate("a", 64),
          ingest_intent: "human_only",
          ingest_status: "not_attempted"
        })

      reloaded = Files.get_file(file.id)
      assert reloaded.ingest_intent == "human_only"
      assert reloaded.ingest_status == "not_attempted"
    end

    test "not_attempted still requires a content_hash" do
      # `not_attempted` is a finalized status: the bytes are stored for
      # humans, so the hash IS known. Pinning the existing
      # `validate_content_hash_when_finalized/1` rule rather than loosening it.
      {:ok, project} = Tasks.create_project(%{name: "Intent No Hash"})

      assert {:error, changeset} =
               Files.create_file(%{
                 project_id: project.id,
                 content_type: "text/plain",
                 byte_size: 1,
                 storage_key: "files/#{project.id}/i/nohash.txt",
                 content_hash: nil,
                 ingest_intent: "human_only",
                 ingest_status: "not_attempted"
               })

      assert %{content_hash: ["is required once ingest_status is not pending"]} =
               errors_on(changeset)
    end

    test "valid_ingest_intents/0 and valid_ingest_statuses/0 pin the vocabulary" do
      assert PlatformFile.valid_ingest_intents() == ["attempt", "human_only"]

      assert PlatformFile.valid_ingest_statuses() == [
               "pending",
               "ingested",
               "failed",
               "not_attempted"
             ]
    end
  end

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

    test "accepts not_attempted — the human_only terminal state" do
      {:ok, project} = Tasks.create_project(%{name: "Status Not Attempted"})

      {:ok, file} =
        Files.create_file(%{
          project_id: project.id,
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project.id}/na/s.txt",
          content_hash: String.duplicate("d", 64),
          ingest_intent: "human_only"
        })

      # `not_attempted` is only reachable alongside `human_only` intent — the
      # DB check constraint `platform_files_not_attempted_requires_human_only_check`
      # refuses the pair `attempt` + `not_attempted`, so the fixture above sets
      # the intent first. This mirrors `withdraw_from_agent_context/1`, which
      # writes intent before status for the same reason.
      assert {:ok, %{ingest_status: "not_attempted"}} =
               Files.update_ingest_status(file, "not_attempted")

      assert Files.get_file(file.id).ingest_status == "not_attempted"
    end
  end

  describe "set_ingest_intent/2" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Intent Writes"})

      {:ok, file} =
        Files.create_file(%{
          project_id: project.id,
          content_type: "text/plain",
          byte_size: 1,
          storage_key: "files/#{project.id}/in/i.txt",
          content_hash: String.duplicate("e", 64)
        })

      %{project: project, target: file}
    end

    test "flips human_only -> attempt and back", %{target: file} do
      file = file
      assert file.ingest_intent == "attempt"

      assert {:ok, %{ingest_intent: "human_only"}} =
               Files.set_ingest_intent(file, "human_only")

      reloaded = Files.get_file(file.id)
      assert reloaded.ingest_intent == "human_only"

      assert {:ok, %{ingest_intent: "attempt"}} =
               Files.set_ingest_intent(reloaded, "attempt")

      assert Files.get_file(file.id).ingest_intent == "attempt"
    end

    test "leaves ingest_status byte-identical across the call", %{target: file} do
      # Intent and status are two fields on purpose. If writing the intent
      # moves the status, they have collapsed into one and the enqueue
      # choke point has silently migrated into this function.
      {:ok, file} = Files.update_ingest_status(file, "ingested")
      before_status = file.ingest_status

      assert {:ok, flipped} = Files.set_ingest_intent(file, "human_only")
      assert flipped.ingest_status == before_status
      assert Files.get_file(file.id).ingest_status == before_status

      assert {:ok, flipped_back} = Files.set_ingest_intent(flipped, "attempt")
      assert flipped_back.ingest_status == before_status
      assert Files.get_file(file.id).ingest_status == before_status
    end

    test "refuses to flip a withdrawn row back to attempt", %{target: file} do
      # A withdrawn row is `human_only` + `not_attempted`. Writing the intent
      # alone would leave `attempt` + `not_attempted` — a row claiming we
      # meant to ingest it while recording that ingestion was never
      # attempted. The DB check constraint refuses the pair; this asserts the
      # refusal reaches the caller as a changeset error rather than a raw
      # Postgrex error, and that the row on disk is untouched.
      assert {:ok, withdrawn} = Files.withdraw_from_agent_context(file)
      assert withdrawn.ingest_intent == "human_only"
      assert withdrawn.ingest_status == "not_attempted"

      assert {:error, %Ecto.Changeset{} = changeset} =
               Files.set_ingest_intent(withdrawn, "attempt")

      assert %{ingest_status: [message]} = errors_on(changeset)
      assert message =~ "not_attempted"

      unchanged = Files.get_file(file.id)
      assert unchanged.ingest_intent == "human_only"
      assert unchanged.ingest_status == "not_attempted"
    end

    test "raises on an unknown intent rather than defaulting", %{target: file} do
      assert_raise FunctionClauseError, fn ->
        Files.set_ingest_intent(file, "maybe_later")
      end
    end
  end

  describe "list_files_for_project/2 ingest filters" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Ingest Filters"})

      # Four rows, so that neither a filter returning EVERYTHING (4) nor a
      # filter returning one arbitrary row (1) can pass an assertion that
      # demands exactly the two human_only ids. The two rows on each side
      # carry different statuses, so an implementation that filters on
      # status while claiming to filter on intent also fails.
      make = fn slug, intent, status ->
        {:ok, f} =
          Files.create_file(%{
            project_id: project.id,
            original_filename: "#{slug}.txt",
            content_type: "text/plain",
            byte_size: 1,
            storage_key: "files/#{project.id}/#{slug}/#{slug}.txt",
            content_hash: String.duplicate(String.first(slug), 64)
          })

        {:ok, f} = Files.set_ingest_intent(f, intent)
        {:ok, f} = Files.update_ingest_status(f, status)
        Process.sleep(2)
        f
      end

      attempt_pending = make.("1attempt", "attempt", "pending")
      attempt_ingested = make.("2attempt", "attempt", "ingested")
      human_not_attempted = make.("3human", "human_only", "not_attempted")
      human_failed = make.("4human", "human_only", "failed")

      %{
        project: project,
        attempt_pending: attempt_pending,
        attempt_ingested: attempt_ingested,
        human_not_attempted: human_not_attempted,
        human_failed: human_failed
      }
    end

    test "ingest_intent: human_only returns only the human_only rows", ctx do
      ids =
        ctx.project.id
        |> Files.list_files_for_project(ingest_intent: "human_only")
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids == Enum.sort([ctx.human_not_attempted.id, ctx.human_failed.id])
    end

    test "ingest_intent: attempt returns only the attempt rows", ctx do
      ids =
        ctx.project.id
        |> Files.list_files_for_project(ingest_intent: "attempt")
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids == Enum.sort([ctx.attempt_pending.id, ctx.attempt_ingested.id])
    end

    test "ingest_status filters independently of intent", ctx do
      assert [%{id: id}] =
               Files.list_files_for_project(ctx.project.id, ingest_status: "not_attempted")

      assert id == ctx.human_not_attempted.id

      assert [%{id: ingested_id}] =
               Files.list_files_for_project(ctx.project.id, ingest_status: "ingested")

      assert ingested_id == ctx.attempt_ingested.id
    end

    test "nil options apply no filter", ctx do
      all =
        Files.list_files_for_project(ctx.project.id, ingest_intent: nil, ingest_status: nil)

      assert length(all) == 4
    end
  end

  describe "list_catalogable_files/2 — the cataloging eligibility seam (task 01a0008c)" do
    test "EXCLUDES a human_only file whose status is \"ingested\" — the disclosure boundary" do
      # The load-bearing case. A human_only row that is ALSO non-ingested
      # would be dropped by the status clause anyway, so pinning the
      # boundary with one of those would pin nothing: delete the intent
      # clause and the test would still pass. This row is ingested, so
      # the intent clause is the only thing standing between a
      # deliberately-unindexed document and an LLM card pass.
      #
      # Same reasoning `Platform.Federation.ToolSurface` records for its
      # own second barrier over `ingest_intent`: "Both barriers are
      # required; neither subsumes the other."
      {:ok, project} = Tasks.create_project(%{name: "Catalog HumanOnly"})

      withheld = catalog_row(project, "withheld-orion-prompts", "human_only", "ingested")
      control = catalog_row(project, "ordinary-doc", "attempt", "ingested")

      ids = project.id |> Files.list_catalogable_files() |> Enum.map(& &1.id)

      refute withheld.id in ids,
             "a human_only file reached the cataloging seam — its bytes must never " <>
               "reach an LLM card pass, for the same reason Ingester.ingest_async/1 " <>
               "short-circuits it before Extractor.extract/1"

      assert control.id in ids
    end

    test "EXCLUDES the production human_only shape (human_only + not_attempted)" do
      # What `withdraw_from_agent_context/1` actually produces, and the
      # shape of the live SXI row `to-be-optimized-orion_prompts.mjs`.
      {:ok, project} = Tasks.create_project(%{name: "Catalog Withdrawn"})

      withdrawn = catalog_row(project, "withdrawn-doc", "human_only", "not_attempted")
      control = catalog_row(project, "kept-doc", "attempt", "ingested")

      ids = project.id |> Files.list_catalogable_files() |> Enum.map(& &1.id)

      refute withdrawn.id in ids
      assert ids == [control.id]
    end

    test "EXCLUDES every ingest_status other than \"ingested\"" do
      {:ok, project} = Tasks.create_project(%{name: "Catalog Status"})

      pending = catalog_row(project, "still-pending", "attempt", "pending")
      failed = catalog_row(project, "rubric-failed", "attempt", "failed")
      ingested = catalog_row(project, "good-doc", "attempt", "ingested")

      ids = project.id |> Files.list_catalogable_files() |> Enum.map(& &1.id)

      refute pending.id in ids, "a pending file has no extracted text to summarize"
      refute failed.id in ids, "a failed ingest never produced text and never will"
      assert ids == [ingested.id]
    end

    test "EXCLUDES soft-deleted rows" do
      {:ok, project} = Tasks.create_project(%{name: "Catalog SoftDelete"})

      gone = catalog_row(project, "deleted-doc", "attempt", "ingested", deleted: true)
      kept = catalog_row(project, "live-doc", "attempt", "ingested")

      ids = project.id |> Files.list_catalogable_files() |> Enum.map(& &1.id)

      refute gone.id in ids
      assert ids == [kept.id]
    end

    test "is scoped to the project it was asked about" do
      {:ok, mine} = Tasks.create_project(%{name: "Catalog Mine"})
      {:ok, theirs} = Tasks.create_project(%{name: "Catalog Theirs"})

      ours = catalog_row(mine, "ours", "attempt", "ingested")
      _ = catalog_row(theirs, "theirs", "attempt", "ingested")

      assert [%{id: id}] = Files.list_catalogable_files(mine.id)
      assert id == ours.id
    end

    test "has NO default cap — 60 catalogable files return 60, not 50" do
      # `list_files_for_project/2` defaults to `limit: 50`. A catalog that
      # silently stops at 50 rows and reports success is precisely the
      # failure this seam's nil default exists to prevent, so 60 rows here
      # is not an arbitrary number: it straddles that inherited default.
      {:ok, project} = Tasks.create_project(%{name: "Catalog Nocap"})

      for n <- 1..60, do: catalog_row(project, "bulk-#{n}", "attempt", "ingested")

      assert length(Files.list_catalogable_files(project.id)) == 60
    end

    test "honours an explicitly-passed limit" do
      {:ok, project} = Tasks.create_project(%{name: "Catalog Limit"})

      for n <- 1..5, do: catalog_row(project, "capped-#{n}", "attempt", "ingested")

      assert length(Files.list_catalogable_files(project.id, limit: 2)) == 2
    end

    test "returns rows in a stable oldest-first order across repeated calls" do
      {:ok, project} = Tasks.create_project(%{name: "Catalog Order"})

      for n <- 1..8, do: catalog_row(project, "ordered-#{n}", "attempt", "ingested")

      first = project.id |> Files.list_catalogable_files() |> Enum.map(& &1.id)
      second = project.id |> Files.list_catalogable_files() |> Enum.map(& &1.id)

      assert first == second
      assert length(first) == 8
    end

    test "SXI corpus shape: 49 files, 39 catalogable" do
      # Mirrors the live SXI project the plan cites: 49 rows total, of
      # which one is human_only and nine are `failed` *Rubric.md files.
      # The ticket's "49 files" is wrong as an ELIGIBLE count; 39 is the
      # number, and the arithmetic only works if both exclusions apply.
      {:ok, project} = Tasks.create_project(%{name: "Catalog SXI Shape"})

      catalog_row(project, "sxi-human-only", "human_only", "not_attempted")
      for n <- 1..9, do: catalog_row(project, "sxi-rubric-#{n}", "attempt", "failed")
      for n <- 1..39, do: catalog_row(project, "sxi-doc-#{n}", "attempt", "ingested")

      assert length(Files.list_files_for_project(project.id, limit: nil)) == 49
      assert length(Files.list_catalogable_files(project.id)) == 39
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

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  #
  # The load-bearing input is the 16-CHARACTER one. `Ecto.UUID.cast/1`
  # hex-encodes any 16-byte binary and returns {:ok, _} while
  # `Ecto.UUID.dump/1` rejects it, so a suite built from "higgins" plus a
  # valid UUID is fully green against the bug. Do not prune the 16-character
  # cases as duplicates.
  describe "UUID boundary: Files getters, and the :binary_id vs UUIDv7 split" do
    @slug_16 "higginshigginsxx"

    test "get_file/2 returns nil for a malformed id" do
      assert Files.get_file("higgins") == nil
      assert Files.get_file(@slug_16) == nil
    end

    test "get_file!/2 raises Ecto.NoResultsError, not Ecto.Query.CastError" do
      assert_raise Ecto.NoResultsError, fn -> Files.get_file!(@slug_16) end
    end

    test "fetch_extracted_text/1 returns nil for BOTH malformed shapes" do
      # Platform.Files.Text keys on a bare :binary_id, not Platform.Types.UUIDv7.
      # That difference is observable: before the guard a raw 16-byte binary
      # returned nil SILENTLY here while "higgins" RAISED — one guard-less
      # lookup, two symptoms. Both must now be nil.
      assert Files.fetch_extracted_text("higgins") == nil
      assert Files.fetch_extracted_text(@slug_16) == nil
      assert Files.fetch_extracted_text(:crypto.strong_rand_bytes(16)) == nil
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  # Row-maker for the `list_catalogable_files/2` block. `slug` doubles as
  # the uniqueness source for storage_key and content_hash (the latter is
  # unique per project), so every call is independently insertable.
  defp catalog_row(project, slug, intent, status, opts \\ []) do
    {:ok, f} =
      Files.create_file(%{
        project_id: project.id,
        original_filename: "#{slug}.txt",
        content_type: "text/plain",
        byte_size: 1,
        storage_key: "files/#{project.id}/#{slug}/#{slug}.txt",
        content_hash: Base.encode16(:crypto.hash(:sha256, slug), case: :lower)
      })

    {:ok, f} = if intent == "attempt", do: {:ok, f}, else: Files.set_ingest_intent(f, intent)
    {:ok, f} = if status == "pending", do: {:ok, f}, else: Files.update_ingest_status(f, status)

    if Keyword.get(opts, :deleted, false) do
      # Marks the soft-delete column directly rather than going through
      # `delete_file/2`, which additionally scrubs the search index via the
      # memory provider and would force this module to `async: false`. The
      # seam reads the column; the column is what needs setting.
      {:ok, deleted} = f |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()
      deleted
    else
      f
    end
  end
end
