defmodule PlatformWeb.FileSignedControllerTest do
  @moduledoc """
  `GET /files/signed/:token` (task 01a165ec stage 1). Every request here is
  made WITHOUT a session: the token is the only authorization.
  """

  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.{Files, Repo, Tasks}
  alias Platform.Files.SignedUrl

  setup do
    prev = Application.get_env(:platform, :chat_attachments_root)
    scratch = Platform.TestTemp.mkdir!("file_signed_test")
    Application.put_env(:platform, :chat_attachments_root, scratch)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:platform, :chat_attachments_root, prev),
        else: Application.delete_env(:platform, :chat_attachments_root)

      File.rm_rf!(scratch)
    end)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Signed Project #{System.unique_integer([:positive])}",
        slug: "signed-project-#{System.unique_integer([:positive])}",
        org_id: acme_org_id()
      })

    %{project: project}
  end

  defp seed_file(project, content_type, body) do
    storage_key = "files/#{project.id}/#{Ecto.UUID.generate()}/clip.bin"
    path = Platform.Chat.AttachmentStorage.path_for(storage_key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: "clip.mp4",
        original_filename: "clip.mp4",
        content_type: content_type,
        byte_size: byte_size(body),
        storage_key: storage_key,
        content_hash: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
        ingest_status: "ingested"
      })

    file
  end

  defp path_of(url), do: URI.parse(url).path

  defp signed_path(file, opts \\ []) do
    {:ok, url} = SignedUrl.url(file, opts)
    path_of(url)
  end

  test "a valid URL with no session returns 200 and the stored bytes", %{
    conn: conn,
    project: project
  } do
    body = :crypto.strong_rand_bytes(4096)
    file = seed_file(project, "video/mp4", body)

    conn = get(conn, signed_path(file))

    assert conn.status == 200
    assert conn.resp_body == body
    assert response_content_type(conn, :mp4) =~ "video/mp4"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "inline"
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "a Range request answers 206 with exactly that slice", %{conn: conn, project: project} do
    body = :crypto.strong_rand_bytes(1000)
    file = seed_file(project, "video/mp4", body)

    conn = conn |> put_req_header("range", "bytes=10-19") |> get(signed_path(file))

    assert conn.status == 206
    assert conn.resp_body == binary_part(body, 10, 10)
    assert get_resp_header(conn, "content-range") == ["bytes 10-19/1000"]
  end

  test "an expired token is 403", %{conn: conn, project: project} do
    file = seed_file(project, "video/mp4", "BYTES")

    token =
      SignedUrl.sign_payload(%{file_id: file.id, expires_at: System.os_time(:second) - 5})

    conn = get(conn, "/files/signed/" <> token)

    assert conn.status == 403
    refute conn.resp_body =~ "BYTES"
  end

  test "a tampered token is 403", %{conn: conn, project: project} do
    file = seed_file(project, "video/mp4", "BYTES")
    "/files/signed/" <> token = signed_path(file)
    mid = div(byte_size(token), 2)
    <<head::binary-size(mid), c, rest::binary>> = token
    tampered = head <> <<if(c == ?A, do: ?B, else: ?A)>> <> rest

    conn = get(conn, "/files/signed/" <> tampered)

    assert conn.status == 403
    refute conn.resp_body =~ "BYTES"
  end

  test "a token for file A serves A, never B", %{conn: conn, project: project} do
    file_a = seed_file(project, "video/mp4", "AAAA-bytes")
    file_b = seed_file(project, "video/mp4", "BBBB-bytes")

    conn_a = get(conn, signed_path(file_a))
    assert conn_a.resp_body == "AAAA-bytes"

    # The id is only in the token; appending B's id as a param changes nothing.
    conn_b = get(build_conn(), signed_path(file_a) <> "?id=#{file_b.id}")
    assert conn_b.resp_body == "AAAA-bytes"
    refute conn_b.resp_body =~ "BBBB"
  end

  test "a soft-deleted file is 404", %{conn: conn, project: project} do
    file = seed_file(project, "video/mp4", "BYTES")
    path = signed_path(file)

    file |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

    conn = get(conn, path)
    assert conn.status == 404
  end

  test "a file whose blob is gone is 404", %{conn: conn, project: project} do
    file = seed_file(project, "video/mp4", "BYTES")
    File.rm!(Platform.Chat.AttachmentStorage.path_for(file.storage_key))

    assert get(conn, signed_path(file)).status == 404
  end
end
