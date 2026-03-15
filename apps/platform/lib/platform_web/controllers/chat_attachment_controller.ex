defmodule PlatformWeb.ChatAttachmentController do
  use PlatformWeb, :controller

  alias Platform.Chat
  alias Platform.Chat.AttachmentStorage

  def show(conn, %{"id" => id}) do
    case Chat.get_visible_attachment(id) do
      nil ->
        send_resp(conn, :not_found, "Not found")

      attachment ->
        path = AttachmentStorage.path_for(attachment.storage_key)

        if File.exists?(path) do
          send_download(conn, {:file, path},
            filename: attachment.filename,
            content_type: attachment.content_type,
            disposition: disposition_for(attachment.content_type)
          )
        else
          send_resp(conn, :not_found, "Not found")
        end
    end
  end

  defp disposition_for("image/" <> _rest), do: :inline
  defp disposition_for("text/" <> _rest), do: :inline
  defp disposition_for("application/pdf"), do: :inline
  defp disposition_for(_content_type), do: :attachment
end
