defmodule Platform.Files.SoftDeleteTest do
  @moduledoc """
  Task 019f7cb0 stage 2 — file soft-delete with restore and search-index
  scrub.

  Invariants under test:

    1. `delete_file/2` marks `deleted_at` (no row removal), scrubs the
       file's entry from the memory index under the file id, emits the
       bridged `[:platform, :files, :file_deleted]` audit event with the
       actor attributed, and broadcasts `{:file_deleted, id}` on the
       project topic.
    2. Deleted rows are invisible on every get/list/search path:
       `get_file/2`, `get_file!/2`, `list_files_for_project/2`,
       `find_ingested_sibling/2`. `include_deleted: true` is the restore
       path's escape hatch.
    3. `restore_file/2` clears the marker, returns the RE-FETCHED row,
       re-indexes from the cached extracted text (no re-extraction),
       emits `[:platform, :files, :file_restored]`, and broadcasts
       `{:file_restored, id}`.
    4. Actor-first: a missing/anonymous actor is `:unauthorized` before
       any write; an archived project is `:project_archived`.

  Uses the same swap-`:provider`-out pattern as `Platform.Files.IngesterTest`
  (the suite isn't wired for Mox), so this module is `async: false`.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Audit
  alias Platform.Files
  alias Platform.Files.File, as: PlatformFile
  alias Platform.Repo
  alias Platform.Tasks

  # ── Capture provider ───────────────────────────────────────────────────

  defmodule CaptureProvider do
    @moduledoc false
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(entries, _config) do
      pid = :persistent_term.get({__MODULE__, :pid}, nil)
      if pid, do: Enum.each(entries, &send(pid, {:provider_ingest, &1}))
      {:ok, length(entries)}
    end

    @impl true
    def search(_q, _o, _c), do: {:ok, []}

    @impl true
    def delete(ids, _config) do
      pid = :persistent_term.get({__MODULE__, :pid}, nil)
      if pid, do: send(pid, {:provider_delete, ids})
      {:ok, length(ids)}
    end

    @impl true
    def health(_c), do: :ok
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  setup do
    original = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: CaptureProvider)
    :persistent_term.put({CaptureProvider, :pid}, self())

    # Guarantee the telemetry→audit bridge is attached so the new
    # `[:platform, :files, …]` events actually persist. If either is
    # missing from TelemetryHandler @events the row silently won't
    # exist — which these tests would then catch.
    Platform.Audit.TelemetryHandler.detach()
    Platform.Audit.TelemetryHandler.attach()

    on_exit(fn ->
      Application.put_env(:platform, :memory_service, original)
      :persistent_term.erase({CaptureProvider, :pid})
      Platform.Audit.TelemetryHandler.detach()
      Platform.Audit.TelemetryHandler.attach()
    end)

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp actor, do: %{id: Ecto.UUID.generate()}

  defp project! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Soft Delete #{n}"})
    project
  end

  defp file!(project, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          project_id: project.id,
          name: "Doc #{n}",
          original_filename: "doc-#{n}.txt",
          content_type: "text/plain",
          byte_size: 42,
          storage_key: "files/#{project.id}/#{n}/doc.txt",
          content_hash: :crypto.hash(:sha256, "doc-#{n}") |> Base.encode16(case: :lower)
        },
        overrides
      )

    {:ok, file} = Files.create_file(attrs)
    file
  end

  defp archive_project!(project) do
    project
    |> Platform.Tasks.Project.changeset(%{archived_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  # ── delete_file/2 ──────────────────────────────────────────────────────

  describe "delete_file/2" do
    test "marks the row deleted and returns the updated struct" do
      file = file!(project!())

      assert {:ok, %PlatformFile{} = deleted} = Files.delete_file(actor(), file)
      assert %DateTime{} = deleted.deleted_at
      assert deleted.id == file.id

      # Row still exists — soft delete, not removal.
      assert %PlatformFile{} = Files.get_file(file.id, include_deleted: true)
    end

    test "scrubs the file's entry from the search index under the file id" do
      file = file!(project!())

      assert {:ok, _} = Files.delete_file(actor(), file)
      assert_receive {:provider_delete, ids}
      assert ids == [file.id]
    end

    test "broadcasts {:file_deleted, id} on the project topic" do
      project = project!()
      file = file!(project)
      :ok = Files.subscribe_project(project.id)

      assert {:ok, _} = Files.delete_file(actor(), file)

      file_id = file.id
      assert_receive {:file_deleted, ^file_id}
    end

    test "persists a bridged audit row with the actor attributed" do
      user = actor()
      file = file!(project!())

      assert {:ok, _} = Files.delete_file(user, file)

      assert [event] = Audit.list(event_type: "platform.files.file_deleted")
      assert event.actor_id == user.id
      assert event.actor_type == "user"
      assert event.resource_type == "file"
      assert event.resource_id == file.id
      assert event.action == "file_deleted"
      assert event.metadata["project_id"] == file.project_id
    end

    test "rejects a missing or anonymous actor before any write" do
      file = file!(project!())

      assert {:error, :unauthorized} = Files.delete_file(nil, file)
      assert {:error, :unauthorized} = Files.delete_file(%{}, file)

      # No side effects leaked.
      assert %PlatformFile{deleted_at: nil} = Files.get_file(file.id)
      refute_received {:provider_delete, _}
    end

    test "rejects an already-deleted file" do
      file = file!(project!())
      assert {:ok, deleted} = Files.delete_file(actor(), file)
      assert {:error, :already_deleted} = Files.delete_file(actor(), deleted)
    end

    test "refuses a file in an archived project" do
      project = project!()
      file = file!(project)
      archive_project!(project)

      assert {:error, :project_archived} = Files.delete_file(actor(), file)
    end
  end

  # ── Visibility (get/list/search paths) ─────────────────────────────────

  describe "deleted-row visibility" do
    test "get_file/2 returns nil for a deleted file; include_deleted fetches it" do
      file = file!(project!())
      assert {:ok, _} = Files.delete_file(actor(), file)

      assert Files.get_file(file.id) == nil
      assert %PlatformFile{id: id} = Files.get_file(file.id, include_deleted: true)
      assert id == file.id
    end

    test "get_file!/2 raises for a deleted file; include_deleted fetches it" do
      file = file!(project!())
      assert {:ok, _} = Files.delete_file(actor(), file)

      assert_raise Ecto.NoResultsError, fn -> Files.get_file!(file.id) end
      assert %PlatformFile{} = Files.get_file!(file.id, include_deleted: true)
    end

    test "list_files_for_project/2 excludes deleted rows" do
      project = project!()
      keep = file!(project)
      gone = file!(project)

      assert {:ok, _} = Files.delete_file(actor(), gone)

      ids = project.id |> Files.list_files_for_project() |> Enum.map(& &1.id)
      assert keep.id in ids
      refute gone.id in ids
    end

    test "find_ingested_sibling/2 never resolves a deleted file as dedup source" do
      project = project!()
      file = file!(project)
      {:ok, file} = Files.update_ingest_status(file, "ingested")

      assert %PlatformFile{id: sibling_id} =
               Files.find_ingested_sibling(project.id, file.content_hash)

      assert sibling_id == file.id

      assert {:ok, _} = Files.delete_file(actor(), file)
      assert Files.find_ingested_sibling(project.id, file.content_hash) == nil
    end

    # Task 019f7cb0 stage 4 — tripwire for the ratified "identical
    # twins" concern. The scrub in `delete_file/2` keys on THIS file's
    # id alone; that is only safe because the strict UNIQUE
    # (content_hash, project_id) index makes a coexisting byte-identical
    # sibling row impossible — including through a delete → re-upload
    # cycle, because a SOFT-DELETED row still occupies the unique slot
    # (the deliberately-deferred re-upload collision behavior). If this
    # test starts failing, someone relaxed the index (e.g. to a partial
    # index over live rows): at that point deleting one twin CAN orphan
    # the surviving twin's search-index entry, and the scrub in
    # `Platform.Files.delete_file/2` must become sibling-aware — see the
    # comment on `scrub_search_index/1`.
    test "a soft-deleted row still occupies the (content_hash, project_id) unique slot" do
      project = project!()
      file = file!(project)
      assert {:ok, _} = Files.delete_file(actor(), file)

      assert {:error, changeset} =
               Files.create_file(%{
                 project_id: project.id,
                 content_type: "text/plain",
                 byte_size: 42,
                 storage_key: "files/#{project.id}/reupload/doc.txt",
                 content_hash: file.content_hash
               })

      assert {"already exists in this project", _} = changeset.errors[:content_hash]
    end
  end

  # ── restore_file/2 ─────────────────────────────────────────────────────

  describe "restore_file/2" do
    test "clears the marker and returns the re-fetched row" do
      file = file!(project!())
      assert {:ok, deleted} = Files.delete_file(actor(), file)

      assert {:ok, %PlatformFile{} = restored} = Files.restore_file(actor(), deleted)
      assert restored.id == file.id
      assert restored.deleted_at == nil

      # Visible again on the normal get path.
      assert %PlatformFile{} = Files.get_file(file.id)
    end

    test "re-indexes from the cached extracted text without re-extraction" do
      file = file!(project!())
      {:ok, _} = Files.upsert_extracted_text(file.id, "cached body", ["cached body"])
      assert {:ok, deleted} = Files.delete_file(actor(), file)
      assert_receive {:provider_delete, _}

      assert {:ok, _} = Files.restore_file(actor(), deleted)

      assert_receive {:provider_ingest, entry}, 1_000
      assert entry.id == file.id
      assert entry.content == "cached body"
      assert entry.project_id == file.project_id
      assert entry.metadata["file_id"] == file.id
    end

    test "skips re-index (with a log, not a crash) when no cached text exists" do
      file = file!(project!())
      assert {:ok, deleted} = Files.delete_file(actor(), file)
      assert_receive {:provider_delete, _}

      # Test env runs the primary Logger level at :warning, which drops the
      # :info-severity skip message (an unindexed file restoring is normal,
      # not anomalous) before any handler sees it. Raise the level for just
      # this block; async: false makes that safe.
      previous_level = Logger.level()
      Logger.configure(level: :info)

      log =
        try do
          capture_log(fn ->
            assert {:ok, _} = Files.restore_file(actor(), deleted)
          end)
        after
          Logger.configure(level: previous_level)
        end

      refute_receive {:provider_ingest, _}, 200
      assert log =~ "no cached extracted text"
    end

    test "broadcasts {:file_restored, id} on the project topic" do
      project = project!()
      file = file!(project)
      assert {:ok, deleted} = Files.delete_file(actor(), file)

      :ok = Files.subscribe_project(project.id)
      assert {:ok, _} = Files.restore_file(actor(), deleted)

      file_id = file.id
      assert_receive {:file_restored, ^file_id}
    end

    test "persists a bridged audit row with the actor attributed" do
      user = actor()
      file = file!(project!())
      assert {:ok, deleted} = Files.delete_file(actor(), file)

      assert {:ok, _} = Files.restore_file(user, deleted)

      assert [event] = Audit.list(event_type: "platform.files.file_restored")
      assert event.actor_id == user.id
      assert event.actor_type == "user"
      assert event.resource_type == "file"
      assert event.resource_id == file.id
      assert event.action == "file_restored"
    end

    test "rejects a file that is not deleted" do
      file = file!(project!())
      assert {:error, :not_deleted} = Files.restore_file(actor(), file)
    end

    test "rejects a missing actor" do
      file = file!(project!())
      assert {:ok, deleted} = Files.delete_file(actor(), file)
      assert {:error, :unauthorized} = Files.restore_file(nil, deleted)
    end

    test "refuses a file in an archived project" do
      project = project!()
      file = file!(project)
      assert {:ok, deleted} = Files.delete_file(actor(), file)
      archive_project!(project)

      assert {:error, :project_archived} = Files.restore_file(actor(), deleted)
    end
  end
end
