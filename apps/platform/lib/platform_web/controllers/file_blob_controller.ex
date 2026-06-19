defmodule PlatformWeb.FileBlobController do
  @moduledoc """
  Serves the bytes behind a `Platform.Files.File` row for inline preview
  in the FilesLive surface (ADR 0042 stage 5 UI).

  Authorization mirrors the `file_get_text` MCP tool: the caller must
  either be a Fabrikam (root) admin or a member of the project's owning
  org. Files without an org association fall back to the standard
  authenticated-user check (every logged-in user can read).

  Mounted under `/files/blob/:id` in the same `:require_auth` browser
  pipeline as the FilesLive routes so the session cookie alone is
  enough — no bearer / no presigned token at this layer.

  Bytes are streamed via the same `Platform.Chat.AttachmentStorage`
  adapter the file was written through. Reuse keeps dev (local disk) and
  prod (R2/S3) parity automatic.

  ## Query params

    * `download=1` — force `Content-Disposition: attachment`, so the
      browser saves the file instead of trying to preview it. Default
      disposition is inline for image/* / text/* / application/pdf and
      attachment for anything else.
  """

  use PlatformWeb, :controller

  alias Platform.Accounts
  alias Platform.Chat.AttachmentStorage
  alias Platform.Files
  alias Platform.Tasks
  alias Platform.Tenancy

  def show(conn, %{"id" => file_id} = params) do
    with %Files.File{} = file <- Files.get_file(file_id),
         {:ok, _project} <- authorize(conn, file) do
      send_file_bytes(conn, file, force_download?(params))
    else
      nil -> send_resp(conn, :not_found, "Not found")
      {:error, :forbidden} -> send_resp(conn, :forbidden, "Forbidden")
    end
  end

  defp send_file_bytes(conn, file, force_download?) do
    path = AttachmentStorage.path_for(file.storage_key)

    if File.exists?(path) do
      disposition =
        if force_download?, do: :attachment, else: disposition_for(file.content_type)

      conn
      # Prevent MIME-sniffing: stored content_type is authoritative.
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_download({:file, path},
        filename: file.original_filename || file.name || "file",
        content_type: file.content_type,
        disposition: disposition
      )
    else
      send_resp(conn, :not_found, "Not found")
    end
  end

  defp force_download?(%{"download" => value}) when value in ["1", "true"], do: true
  defp force_download?(_), do: false

  defp authorize(conn, %Files.File{} = file) do
    user_id = get_session(conn, :current_user_id)

    cond do
      is_nil(user_id) ->
        {:error, :forbidden}

      true ->
        user = Accounts.get_user(user_id)
        do_authorize(user, file)
    end
  end

  defp do_authorize(nil, _file), do: {:error, :forbidden}

  defp do_authorize(user, %Files.File{project_id: project_id} = _file) do
    project = Tasks.get_project(project_id)

    cond do
      Tenancy.fabrikam_admin?(user) ->
        {:ok, project}

      is_nil(project) ->
        {:error, :forbidden}

      is_nil(project.org_id) ->
        # Org-less project (legacy / dev seed) — gate on auth only.
        {:ok, project}

      Tenancy.member_of?(user, project.org_id) ->
        {:ok, project}

      true ->
        {:error, :forbidden}
    end
  end

  defp disposition_for("image/" <> _rest), do: :inline
  defp disposition_for("text/" <> _rest), do: :inline
  defp disposition_for("application/pdf"), do: :inline
  defp disposition_for(_content_type), do: :attachment
end
