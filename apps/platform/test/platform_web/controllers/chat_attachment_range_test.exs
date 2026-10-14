defmodule PlatformWeb.ChatAttachmentRangeTest do
  @moduledoc "Task 01a120be stage 2: Range requests on GET /chat/attachments/:id."
  use PlatformWeb.ConnCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Chat
  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk
  alias Platform.Chat.AttachmentStorage.Root
  alias PlatformWeb.ChatAttachmentController

  @body for i <- 0..999, into: <<>>, do: <<rem(i, 256)>>

  setup %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "platform-range-test-#{Ecto.UUID.generate()}")
    Root.put_override(root)
    on_exit(fn -> File.rm_rf(root) end)

    user = create_user!()
    space = channel!()
    participant = add_user!(space.id, user.id)
    message = post!(space.id, participant.id, "video")
    key = "chat/range/#{Ecto.UUID.generate()}.mp4"
    {:ok, _} = LocalDisk.persist(key, {:binary, @body})

    {:ok, attachment} =
      Chat.create_attachment(%{
        space_id: space.id,
        message_id: message.id,
        filename: "clip.mp4",
        content_type: "video/mp4",
        byte_size: byte_size(@body),
        storage_key: key,
        state: "ready"
      })

    %{conn: init_test_session(conn, current_user_id: user.id), attachment: attachment}
  end

  defp fetch(conn, attachment, range) do
    conn = if range, do: put_req_header(conn, "range", range), else: conn
    get(conn, "/chat/attachments/#{attachment.id}")
  end

  test "bytes=0-99 is 206 with 100 bytes and Content-Range", %{conn: c, attachment: a} do
    conn = fetch(c, a, "bytes=0-99")
    assert conn.status == 206
    assert conn.resp_body == binary_part(@body, 0, 100)
    assert get_resp_header(conn, "content-range") == ["bytes 0-99/1000"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "content-type") == ["video/mp4"]
    assert [disp] = get_resp_header(conn, "content-disposition")
    assert String.starts_with?(disp, "inline;")
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "suffix bytes=-10 is the last 10 bytes", %{conn: c, attachment: a} do
    conn = fetch(c, a, "bytes=-10")
    assert conn.status == 206
    assert conn.resp_body == binary_part(@body, 990, 10)
    assert get_resp_header(conn, "content-range") == ["bytes 990-999/1000"]
  end

  test "open-ended bytes=900- runs to the end", %{conn: c, attachment: a} do
    conn = fetch(c, a, "bytes=900-")
    assert conn.status == 206
    assert conn.resp_body == binary_part(@body, 900, 100)
    assert get_resp_header(conn, "content-range") == ["bytes 900-999/1000"]
  end

  test "a range past the end is 416 with bytes */size", %{conn: c, attachment: a} do
    conn = fetch(c, a, "bytes=1000-1010")
    assert conn.status == 416
    assert get_resp_header(conn, "content-range") == ["bytes */1000"]
  end

  test "no Range header is today's 200 full body, with Accept-Ranges", %{conn: c, attachment: a} do
    conn = fetch(c, a, nil)
    assert conn.status == 200
    assert conn.resp_body == @body
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end

  test "HEAD returns Accept-Ranges", %{conn: c, attachment: a} do
    conn = head(c, "/chat/attachments/#{a.id}")
    assert conn.status == 200
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end

  test "parse_range edge cases" do
    assert ChatAttachmentController.parse_range("bytes=5-2", 10) == :ignore
    assert ChatAttachmentController.parse_range("bytes=0-5,7-8", 10) == :ignore
    assert ChatAttachmentController.parse_range("items=0-5", 10) == :ignore
    assert ChatAttachmentController.parse_range("bytes=0-50", 10) == {:ok, 0, 9}
    assert ChatAttachmentController.parse_range("bytes=-50", 10) == {:ok, 0, 9}
    assert ChatAttachmentController.parse_range("bytes=-0", 10) == :unsatisfiable
  end
end
