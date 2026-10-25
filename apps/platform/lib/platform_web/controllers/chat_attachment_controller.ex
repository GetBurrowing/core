defmodule PlatformWeb.ChatAttachmentController do
  use PlatformWeb, :controller

  alias Platform.Chat
  alias Platform.Chat.AttachmentStorage
  alias PlatformWeb.AttachmentResponsePolicy

  def show(conn, %{"id" => id}) do
    principal = conn.assigns[:principal]

    case Chat.get_visible_attachment_for_principal(id, principal) do
      nil ->
        send_resp(conn, :not_found, "Not found")

      attachment ->
        path = AttachmentStorage.path_for(attachment.storage_key)

        case File.stat(path) do
          {:ok, %File.Stat{size: size}} ->
            conn
            # Prevent MIME-sniffing: the stored content_type is authoritative.
            # Without this, a browser can reinterpret a response as HTML based on
            # its bytes, bypassing the safe-override allowlist in AttachmentStorage.
            |> put_resp_header("x-content-type-options", "nosniff")
            # In show/2 so the 200, 206 and 416 responses all carry it (task 01a16a08).
            |> maybe_sandbox(attachment)
            |> put_resp_header("accept-ranges", "bytes")
            |> send_attachment(attachment, path, size, get_req_header(conn, "range"))

          {:error, _} ->
            send_resp(conn, :not_found, "Not found")
        end
    end
  end

  # No Range header: today's 200 full-body download, unchanged.
  defp send_attachment(conn, attachment, path, _size, []) do
    send_download(conn, {:file, path},
      filename: attachment.filename,
      content_type: attachment.content_type,
      disposition: AttachmentResponsePolicy.disposition(attachment.content_type)
    )
  end

  # Range requests (task 01a120be stage 2) let a video seek without
  # downloading the whole file. One range only; a multi-range or malformed
  # header is ignored per RFC 9110 14.2 and answered with the full body.
  defp send_attachment(conn, attachment, path, size, [range | _]) do
    case parse_range(range, size) do
      {:ok, first, last} ->
        length = last - first + 1

        conn
        |> put_download_headers(attachment)
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, length)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")

      :ignore ->
        send_attachment(conn, attachment, path, size, [])
    end
  end

  # Same Content-Type / Content-Disposition `send_download/3` would set.
  defp put_download_headers(conn, attachment) do
    disposition = Atom.to_string(AttachmentResponsePolicy.disposition(attachment.content_type))
    encoded = URI.encode(attachment.filename, &URI.char_unreserved?/1)

    conn
    |> put_resp_content_type(attachment.content_type, nil)
    |> put_resp_header(
      "content-disposition",
      ~s(#{disposition}; filename="#{encoded}"; filename*=utf-8''#{encoded})
    )
  end

  @doc false
  # `bytes=a-b`, `bytes=a-`, `bytes=-n`. Returns `{:ok, first, last}`,
  # `:unsatisfiable` (416) or `:ignore` (serve the whole body).
  def parse_range("bytes=" <> spec, size) do
    case String.split(String.trim(spec), "-", parts: 2) do
      ["", suffix] ->
        case Integer.parse(suffix) do
          {n, ""} when n > 0 and size > 0 -> {:ok, max(size - n, 0), size - 1}
          {n, ""} when n >= 0 -> :unsatisfiable
          _ -> :ignore
        end

      [first, last] ->
        with {f, ""} <- Integer.parse(first),
             {:ok, l} <- range_last(last, size) do
          cond do
            f >= size -> :unsatisfiable
            l < f -> :ignore
            true -> {:ok, f, min(l, size - 1)}
          end
        else
          _ -> :ignore
        end

      _ ->
        :ignore
    end
  end

  def parse_range(_other, _size), do: :ignore

  defp range_last("", size), do: {:ok, size - 1}

  defp range_last(last, _size) do
    case Integer.parse(last) do
      {l, ""} -> {:ok, l}
      _ -> :error
    end
  end

  # Anything not served inline (text/*, svg, unknown) is sandboxed so that a
  # browser which renders it anyway cannot run it as same-origin script.
  defp maybe_sandbox(conn, attachment) do
    if AttachmentResponsePolicy.disposition(attachment.content_type) == :attachment do
      AttachmentResponsePolicy.put_sandbox_csp(conn)
    else
      conn
    end
  end
end
