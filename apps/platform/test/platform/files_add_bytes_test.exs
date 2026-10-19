defmodule Platform.FilesAddBytesTest do
  @moduledoc """
  `Platform.Files.add_bytes/5` — the bytes-in-hand ingest path extracted from
  the `file_add` MCP tool's inline branch (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 4). The tool's own behaviour is
  pinned by `test/platform/federation/tool_surface_files_test.exs`.

  async: false — redirects the Files storage root in application env.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Files
  alias Platform.Tasks
  alias Platform.Tenancy

  setup do
    root = Platform.TestTemp.path("files-add-bytes")
    File.mkdir_p!(root)
    previous = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:platform, :chat_attachments_root, previous),
        else: Application.delete_env(:platform, :chat_attachments_root)
    end)

    org_id = Tenancy.get_org_by_slug!("initech").id

    {:ok, project} =
      Tasks.create_project(%{
        name: "Add bytes #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    handler = "files-add-bytes-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:platform, :files, :ingested, :start],
      fn _event, _measurements, meta, _ -> send(test_pid, {:ingest_started, meta.file_id}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{project: project}
  end

  defp rows(project) do
    from(f in Files.File, where: f.project_id == ^project.id and is_nil(f.deleted_at))
    |> Repo.all()
  end

  test "stores the bytes, inserts one row and fires ingest", %{project: project} do
    body = "# Notes\n\nhello #{System.unique_integer([:positive])}\n"
    n = System.unique_integer([:positive])

    user =
      %Platform.Accounts.User{}
      |> Platform.Accounts.User.changeset(%{
        email: "add-bytes-#{n}@example.com",
        name: "Add bytes #{n}",
        oidc_sub: "oidc-add-bytes-#{n}"
      })
      |> Repo.insert!()

    user_id = user.id

    assert {:ok, file, false} =
             Files.add_bytes(project, body, "notes.md", "text/markdown",
               uploaded_by_user_id: user_id
             )

    assert [%{id: id}] = rows(project)
    assert id == file.id
    assert file.content_type == "text/markdown"
    assert file.org_id == project.org_id
    assert file.uploaded_by_user_id == user_id
    assert file.byte_size == byte_size(body)
    assert file.content_hash == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    {:ok, stream} = Files.Storage.get(file.storage_key)
    assert stream |> Enum.to_list() |> IO.iodata_to_binary() == body

    assert_receive {:ingest_started, ^id}, 2_000
  end

  test "dedupes on content hash against an ingested sibling", %{project: project} do
    body = "same bytes #{System.unique_integer([:positive])}"

    assert {:ok, first, false} = Files.add_bytes(project, body, "a.txt", "text/plain")
    {:ok, _} = Files.update_ingest_status(first, "ingested")

    assert {:ok, second, true} = Files.add_bytes(project, body, "b.txt", "text/plain")
    assert second.id == first.id
    assert [%{id: only}] = rows(project)
    assert only == first.id

    # Positive control: different bytes are a different row.
    assert {:ok, third, false} = Files.add_bytes(project, body <> "!", "c.txt", "text/plain")
    refute third.id == first.id
    assert length(rows(project)) == 2
  end

  test "ingest: false inserts the row without enqueuing ingest", %{project: project} do
    assert {:ok, file, false} =
             Files.add_bytes(
               project,
               "quiet #{System.unique_integer([:positive])}",
               "q.txt",
               "text/plain",
               ingest: false
             )

    id = file.id
    refute_receive {:ingest_started, ^id}, 200
    assert Files.get_file(id).ingest_status == "pending"
  end
end
