defmodule Platform.Files.PresignedFinalizeTest do
  @moduledoc """
  `Platform.Files.finalize_presigned_upload/3` and the storage_key lookups
  it depends on (task 01a091b7 stage 1). Drives the context directly —
  the controller wiring that calls these lands in stage 2.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk
  alias Platform.Files
  alias Platform.Files.File, as: PFile
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  defmodule MemoryStub do
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(_entries, _config), do: {:ok, 0}

    @impl true
    def search(_query, _opts, _config), do: {:ok, []}

    @impl true
    def delete(_ids, _config), do: {:ok, 0}

    @impl true
    def health(_), do: :ok
  end

  defp install_memory_stub(_) do
    prev = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: MemoryStub)
    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
    :ok
  end

  defp with_tmp_storage_root(_) do
    root = Platform.TestTemp.path("platform-files-presigned-finalize")
    File.mkdir_p!(root)
    previous = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:platform, :chat_attachments_root, previous),
        else: Application.delete_env(:platform, :chat_attachments_root)
    end)

    {:ok, %{storage_root: root}}
  end

  defp u, do: System.unique_integer([:positive])

  defp ensure_root_org do
    case Repo.get_by(Tenancy.Org, slug: "acme") do
      nil ->
        {:ok, org} =
          %Tenancy.Org{}
          |> Tenancy.Org.changeset(%{slug: "acme", name: "Acme", parent_org_id: nil})
          |> Repo.insert()

        org

      org ->
        org
    end
  end

  setup [:with_tmp_storage_root, :install_memory_stub]

  setup do
    acme = ensure_root_org()

    {:ok, org} =
      %Tenancy.Org{}
      |> Tenancy.Org.changeset(%{
        slug: "presigned-finalize-#{u()}",
        name: "Presigned",
        parent_org_id: acme.id
      })
      |> Repo.insert()

    {:ok, project} = Tasks.create_project(%{name: "Presigned-#{u()}", org_id: org.id})
    {:ok, %{org: org, project: project}}
  end

  # Mirrors `file_add_presigned/4` in ToolSurface: deterministic key, a
  # pending row with no content_hash, byte_size = the caller's declaration.
  defp reserve(project, filename, content_type, declared_size) do
    file_id = Ecto.UUID.generate()
    key = Files.Storage.build_key(project.id, file_id, filename)

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: filename,
        original_filename: filename,
        content_type: content_type,
        byte_size: declared_size,
        storage_key: key,
        ingest_status: "pending"
      })

    file
  end

  # The byte POST the controller will perform in stage 2: land bytes at
  # the reservation's key and return the adapter's stat.
  defp land_bytes(%PFile{storage_key: key}, bytes) do
    {:ok, stat} = LocalDisk.persist(key, {:binary, bytes})
    stat
  end

  test "(i) pending row + sync finalize: hash + size set, ingested, text extracted",
       %{project: project} do
    body = "presigned finalize body #{u()}\n"
    file = reserve(project, "note-#{u()}.txt", "text/plain", byte_size(body))
    assert is_nil(file.content_hash)

    stat = land_bytes(file, body)

    assert {:ok, %{file: %PFile{} = done, deduplicated: false}} =
             Files.finalize_presigned_upload(file, stat, mode: :sync)

    assert done.id == file.id
    assert done.byte_size == byte_size(body)
    assert done.content_hash == stat.content_hash
    assert done.ingest_status == "ingested"

    assert %Files.Text{text: text} = Files.fetch_extracted_text(file.id)
    assert text == body
  end

  test "(ii) ingested sibling with same hash: deduplicated, reservation row + bytes gone",
       %{project: project} do
    body = "shared bytes #{u()}\n"
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    {:ok, sibling} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: "sibling.txt",
        original_filename: "sibling.txt",
        content_type: "text/plain",
        byte_size: byte_size(body),
        storage_key: "files/#{project.id}/#{Ecto.UUID.generate()}/sibling.txt",
        content_hash: hash,
        ingest_status: "ingested"
      })

    file = reserve(project, "dup-#{u()}.txt", "text/plain", byte_size(body))
    stat = land_bytes(file, body)
    path = LocalDisk.path_for(file.storage_key)
    assert File.exists?(path)

    assert {:ok, %{file: %PFile{id: sibling_id}, deduplicated: true}} =
             Files.finalize_presigned_upload(file, stat, mode: :sync)

    assert sibling_id == sibling.id
    assert is_nil(Repo.get(PFile, file.id))
    refute File.exists?(path)
  end

  test "(iii) already-ingested row is not finalizable", %{project: project} do
    body = "twice #{u()}\n"
    file = reserve(project, "twice-#{u()}.txt", "text/plain", byte_size(body))
    stat = land_bytes(file, body)
    assert {:ok, %{file: done}} = Files.finalize_presigned_upload(file, stat, mode: :sync)
    assert done.ingest_status == "ingested"

    assert {:error, :not_pending} = Files.finalize_presigned_upload(done, stat, mode: :sync)
  end

  test "(iii-b) async finalize leaves the row pending-for-ingest but not re-finalizable",
       %{project: project} do
    body = "async twice #{u()}\n"
    file = reserve(project, "async-#{u()}.txt", "text/plain", byte_size(body))
    stat = land_bytes(file, body)
    assert {:ok, %{file: done, deduplicated: false}} = Files.finalize_presigned_upload(file, stat)
    assert done.content_hash == stat.content_hash

    # Whatever the Ingester has done by now, the hash is the reservation
    # marker (task 01a091b7 stage 2): a second finalize must be refused.
    reloaded = Files.get_file(file.id)
    assert {:error, :not_pending} = Files.finalize_presigned_upload(reloaded, stat)
  end

  test "(iv) soft-deleted pending reservation reads as absent", %{project: project} do
    file = reserve(project, "gone-#{u()}.txt", "text/plain", 3)
    assert %PFile{id: id} = Files.get_pending_by_storage_key(file.storage_key)
    assert id == file.id
    assert %PFile{id: ^id} = Files.get_by_storage_key(file.storage_key)

    {:ok, _} =
      file
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update()

    assert is_nil(Files.get_pending_by_storage_key(file.storage_key))
    assert is_nil(Files.get_by_storage_key(file.storage_key))
  end

  test "(iv-b) get_by_storage_key sees a finalized row that get_pending_by_storage_key hides",
       %{project: project} do
    body = "finalized #{u()}\n"
    file = reserve(project, "fin-#{u()}.txt", "text/plain", byte_size(body))
    stat = land_bytes(file, body)
    assert {:ok, _} = Files.finalize_presigned_upload(file, stat, mode: :sync)

    assert is_nil(Files.get_pending_by_storage_key(file.storage_key))
    assert %PFile{id: id} = Files.get_by_storage_key(file.storage_key)
    assert id == file.id
  end

  test "(v) human_only reservation (application/zip) finalizes to not_attempted, no extraction",
       %{project: project} do
    body = "PK\x03\x04not-really-a-zip-#{u()}"
    file = reserve(project, "archive-#{u()}.zip", "application/zip", byte_size(body))
    assert file.ingest_intent == "human_only"
    assert file.ingest_status == "pending"

    stat = land_bytes(file, body)

    assert {:ok, %{file: %PFile{id: id}, deduplicated: false}} =
             Files.finalize_presigned_upload(file, stat)

    reloaded = Files.get_file(id)
    assert reloaded.ingest_status == "not_attempted"
    assert reloaded.content_hash == stat.content_hash
    assert reloaded.byte_size == byte_size(body)
    assert is_nil(Files.fetch_extracted_text(id))
  end
end
