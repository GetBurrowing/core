defmodule PlatformWeb.FileSignedController do
  @moduledoc """
  `GET /files/signed/:token` — serves the one `Platform.Files.File` named by
  a `Platform.Files.SignedUrl` token (task 01a165ec stage 1).

  No session, no bearer, no cookie: the token is the whole authorization,
  because the caller is an outside service (a publishing vendor fetching a
  video) that carries none of ours. The route's pipeline never fetches the
  session, so this response cannot set one.

    * 200 — the stored bytes, stored `content_type`, `nosniff`, inline.
    * 206 / 416 — a single `Range` request (vendors range-fetch large
      videos), parsed exactly as `PlatformWeb.ChatAttachmentController` does.
    * 403 — invalid, tampered or expired token.
    * 404 — the named file is unknown, soft-deleted, or its blob is missing.

  Every response carries `Content-Security-Policy: sandbox` so an uploaded
  HTML file served here renders inert in an opaque origin rather than as
  active content on the application origin.
  """

  use PlatformWeb, :controller

  alias Platform.Chat.AttachmentStorage
  alias Platform.Files
  alias Platform.Files.SignedUrl
  alias PlatformWeb.ChatAttachmentController

  @csp "sandbox; default-src 'none'"

  def show(conn, %{"token" => token}) do
    conn = put_resp_header(conn, "content-security-policy", @csp)

    with {:ok, file_id} <- SignedUrl.verify(token),
         %Files.File{} = file <- Files.get_file(file_id),
         path = AttachmentStorage.path_for(file.storage_key),
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      conn
      # Prevent MIME-sniffing: stored content_type is authoritative.
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("accept-ranges", "bytes")
      |> send_bytes(file, path, size, get_req_header(conn, "range"))
    else
      {:error, reason} when reason in [:invalid, :expired] ->
        send_resp(conn, :forbidden, "Forbidden")

      _ ->
        send_resp(conn, :not_found, "Not found")
    end
  end

  defp send_bytes(conn, file, path, _size, []) do
    send_download(conn, {:file, path},
      filename: filename(file),
      content_type: file.content_type,
      disposition: :inline
    )
  end

  defp send_bytes(conn, file, path, size, [range | _]) do
    case ChatAttachmentController.parse_range(range, size) do
      {:ok, first, last} ->
        conn
        |> put_resp_content_type(file.content_type, nil)
        |> put_resp_header("content-disposition", disposition_header(file))
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")

      :ignore ->
        send_bytes(conn, file, path, size, [])
    end
  end

  defp disposition_header(file) do
    encoded = URI.encode(filename(file), &URI.char_unreserved?/1)
    ~s(inline; filename="#{encoded}"; filename*=utf-8''#{encoded})
  end

  defp filename(file), do: file.original_filename || file.name || "file"
end
