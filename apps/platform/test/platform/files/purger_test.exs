defmodule Platform.Files.PurgerTest do
  @moduledoc """
  Task 019f7cb0 stage 3 — permanent purge of soft-deleted files after the
  retention window.

  Invariants under test (mirrors `Platform.Tenancy.ContainerPurgerTest`):

    1. A file soft-deleted past `Lifecycle.retention_days/0` is erased for
       real: storage bytes (adapter delete with the file's key), the
       `platform_files` row, and — via the DB-level `ON DELETE :delete_all`
       FKs — its chunk back-refs and cached extracted text.
    2. Live files and files still inside the window are untouched; the
       sweep is idempotent.
    3. Storage-then-row atomicity: a failing storage delete rolls the row
       delete back, so the file is kept and retried next sweep — the row
       is never gone while bytes may remain. No phantom audit row either.
    4. The delete re-checks the full predicate IN the query: a candidate
       restored after selection is skipped and the storage adapter is
       never called for it (`purge_one/2` is the exposed seam).
    5. The batched drain continues past a failing file (skip-exclusion
       terminates the loop) and across batches.
    6. Each purge emits a system-actor `[:platform, :files, :file_purged]`
       audit event and re-scrubs the search index under the file id.

  Swaps the storage adapter and memory provider via config (the suite
  isn't wired for Mox — same pattern as `Platform.Files.SoftDeleteTest`),
  so this module is `async: false`.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Audit
  alias Platform.Files
  alias Platform.Files.File, as: PlatformFile
  alias Platform.Files.Purger
  alias Platform.Files.Text
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.Lifecycle

  # ── Capture memory provider (same shape as SoftDeleteTest) ─────────────

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

  # ── Scripted storage adapter ───────────────────────────────────────────

  defmodule ScriptedStorageAdapter do
    @moduledoc false
    @behaviour Platform.Chat.AttachmentStorage.Adapter

    @impl true
    def persist(_key, _source), do: {:error, :not_supported}

    @impl true
    def read_stream(_key), do: {:error, :enoent}

    @impl true
    def presign_upload(_key, _max_bytes, _ttl_s), do: {:error, :not_supported}

    # Reports every delete to the test pid and fails for scripted keys.
    # The behaviour types delete as `:ok`-only (LocalDisk swallows errors),
    # but a future R2/S3 adapter can surface failures — returning
    # `{:error, _}` here is exactly how the purger's defensive skip path
    # gets exercised.
    @impl true
    def delete(key) do
      pid = :persistent_term.get({__MODULE__, :pid}, nil)
      if pid, do: send(pid, {:storage_delete, key})

      failing = :persistent_term.get({__MODULE__, :failing}, MapSet.new())
      if MapSet.member?(failing, key), do: {:error, :unavailable}, else: :ok
    end
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  setup do
    original_memory = Application.get_env(:platform, :memory_service, [])
    original_adapter = Application.get_env(:platform, :attachment_storage_adapter)

    Application.put_env(:platform, :memory_service, provider: CaptureProvider)
    Application.put_env(:platform, :attachment_storage_adapter, ScriptedStorageAdapter)
    :persistent_term.put({CaptureProvider, :pid}, self())
    :persistent_term.put({ScriptedStorageAdapter, :pid}, self())
    :persistent_term.put({ScriptedStorageAdapter, :failing}, MapSet.new())

    # Guarantee the telemetry→audit bridge is attached so the
    # `[:platform, :files, :file_purged]` event actually persists — if it
    # is missing from TelemetryHandler @events these tests catch it.
    Platform.Audit.TelemetryHandler.detach()
    Platform.Audit.TelemetryHandler.attach()

    on_exit(fn ->
      Application.put_env(:platform, :memory_service, original_memory)

      if original_adapter,
        do: Application.put_env(:platform, :attachment_storage_adapter, original_adapter),
        else: Application.delete_env(:platform, :attachment_storage_adapter)

      :persistent_term.erase({CaptureProvider, :pid})
      :persistent_term.erase({ScriptedStorageAdapter, :pid})
      :persistent_term.erase({ScriptedStorageAdapter, :failing})
      Platform.Audit.TelemetryHandler.detach()
      Platform.Audit.TelemetryHandler.attach()
    end)

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp actor, do: %{id: Ecto.UUID.generate()}

  defp project! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Purge #{n}"})
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

  # Soft-deletes via the public stage-2 path, then backdates the marker —
  # the window tests need history the public API refuses to fabricate
  # (same convention as ContainerPurgerTest.backdate_scheduled!/2).
  defp soft_delete_backdated!(file, days_ago) do
    {:ok, deleted} = Files.delete_file(actor(), file)

    # Drain the soft-delete-time index scrub so purge-time assertions see
    # only the purge's own provider messages.
    assert_receive {:provider_delete, _}

    past = DateTime.add(DateTime.utc_now(), -days_ago, :day)
    deleted |> Ecto.Changeset.change(deleted_at: past) |> Repo.update!()
  end

  defp past_window_days, do: Lifecycle.retention_days() + 1

  defp cutoff, do: DateTime.add(DateTime.utc_now(), -Lifecycle.retention_days(), :day)

  defp fail_storage_key!(key) do
    failing = :persistent_term.get({ScriptedStorageAdapter, :failing})
    :persistent_term.put({ScriptedStorageAdapter, :failing}, MapSet.put(failing, key))
  end

  defp clear_storage_failures! do
    :persistent_term.put({ScriptedStorageAdapter, :failing}, MapSet.new())
  end

  # ── sweep/1 ────────────────────────────────────────────────────────────

  describe "sweep/1" do
    test "erases bytes, row, and dependent chunk/text rows past the window; idempotent" do
      project = project!()
      file = file!(project)
      {:ok, _} = Files.insert_chunk(%{file_id: file.id, chunk_external_id: "chunk-1"})
      {:ok, _} = Files.upsert_extracted_text(file.id, "cached body", ["cached body"])
      soft_delete_backdated!(file, past_window_days())

      assert {:ok, 1} = Purger.sweep()

      key = file.storage_key
      assert_received {:storage_delete, ^key}

      # Row gone for real — not merely hidden.
      assert Files.get_file(file.id, include_deleted: true) == nil

      # Dependents cascade at the DB level (ON DELETE :delete_all on both
      # platform_file_chunks.file_id and platform_file_texts.file_id).
      assert Files.list_chunks_for_file(file.id) == []
      assert Repo.get(Text, file.id) == nil

      # Idempotent — a second sweep finds nothing.
      assert {:ok, 0} = Purger.sweep()
    end

    test "leaves live files and files still inside the window untouched" do
      project = project!()
      live = file!(project)
      recent = file!(project)
      old = file!(project)
      soft_delete_backdated!(recent, 1)
      soft_delete_backdated!(old, past_window_days())

      assert {:ok, 1} = Purger.sweep()

      old_key = old.storage_key
      assert_received {:storage_delete, ^old_key}
      refute_received {:storage_delete, _}

      assert %PlatformFile{deleted_at: nil} = Files.get_file(live.id)

      assert %PlatformFile{deleted_at: %DateTime{}} =
               Files.get_file(recent.id, include_deleted: true)

      assert Files.get_file(old.id, include_deleted: true) == nil
    end

    test "a failing storage delete keeps the row (no phantom audit) and retries next sweep" do
      project = project!()
      file = file!(project)
      soft_delete_backdated!(file, past_window_days())
      fail_storage_key!(file.storage_key)

      log =
        capture_log(fn ->
          assert {:ok, 0} = Purger.sweep()
        end)

      assert log =~ "storage delete failed"

      # The adapter WAS asked — the row survived because it said no.
      key = file.storage_key
      assert_received {:storage_delete, ^key}
      assert %PlatformFile{} = Files.get_file(file.id, include_deleted: true)
      assert Audit.list(event_type: "platform.files.file_purged") == []

      clear_storage_failures!()
      assert {:ok, 1} = Purger.sweep()
      assert Files.get_file(file.id, include_deleted: true) == nil
    end

    test "the batched drain continues past a failing file" do
      project = project!()
      files = for _ <- 1..3, do: file!(project)
      Enum.each(files, &soft_delete_backdated!(&1, past_window_days()))
      [a, b, c] = files
      fail_storage_key!(b.storage_key)

      log =
        capture_log(fn ->
          assert {:ok, 2} = Purger.sweep(batch_size: 1)
        end)

      assert log =~ "storage delete failed"

      assert Files.get_file(a.id, include_deleted: true) == nil
      assert %PlatformFile{} = Files.get_file(b.id, include_deleted: true)
      assert Files.get_file(c.id, include_deleted: true) == nil
    end

    test "persists a system-actor audit row per purge" do
      project = project!()
      file = file!(project)
      deleted = soft_delete_backdated!(file, past_window_days())

      assert {:ok, 1} = Purger.sweep()

      assert [event] = Audit.list(event_type: "platform.files.file_purged")
      assert event.actor_id == nil
      assert event.actor_type == "system"
      assert event.resource_type == "file"
      assert event.resource_id == file.id
      assert event.action == "file_purged"
      assert event.metadata["project_id"] == project.id
      assert event.metadata["storage_key"] == file.storage_key
      assert event.metadata["deleted_at"] == DateTime.to_iso8601(deleted.deleted_at)
    end

    test "re-scrubs the search index under the file id at purge time" do
      file = file!(project!())
      soft_delete_backdated!(file, past_window_days())

      assert {:ok, 1} = Purger.sweep()

      file_id = file.id
      assert_received {:provider_delete, [^file_id]}
    end
  end

  # ── purge_one/2 (race-guard seam) ──────────────────────────────────────

  describe "purge_one/2" do
    test "a candidate restored after selection is skipped and storage is never called" do
      project = project!()
      file = file!(project)

      # The sweep's candidate snapshot: still carries the past-window
      # deleted_at…
      stale_candidate = soft_delete_backdated!(file, past_window_days())

      # …but a restore lands before the delete (cleared directly — the
      # seam under test is the in-query re-check, not restore_file/2).
      Files.get_file!(file.id, include_deleted: true)
      |> Ecto.Changeset.change(deleted_at: nil)
      |> Repo.update!()

      log =
        capture_log(fn ->
          assert :skipped = Purger.purge_one(stale_candidate, cutoff())
        end)

      assert log =~ "no longer matched the delete re-check"

      # The row delete rolled back BEFORE the storage call — the restored
      # file keeps its bytes.
      refute_received {:storage_delete, _}
      assert %PlatformFile{deleted_at: nil} = Files.get_file(file.id)
    end
  end
end
