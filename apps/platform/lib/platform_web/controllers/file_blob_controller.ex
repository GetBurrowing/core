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
    * `preview=1` — HTML/XHTML only: serve the markup inline for the
      sandboxed preview frame. Without it, markup downloads. Either way
      the response carries `Content-Security-Policy: sandbox`, so the
      document loads into an opaque origin with scripts refused rather
      than executing on the application origin.
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
      send_file_bytes(
        conn,
        file,
        force_download?(params),
        sandboxed_preview?(params, file.content_type)
      )
    else
      nil -> send_resp(conn, :not_found, "Not found")
      {:error, :forbidden} -> send_resp(conn, :forbidden, "Forbidden")
    end
  end

  defp send_file_bytes(conn, file, force_download?, sandboxed_preview?) do
    path = AttachmentStorage.path_for(file.storage_key)

    if File.exists?(path) do
      disposition =
        cond do
          force_download? -> :attachment
          sandboxed_preview? -> :inline
          true -> disposition_for(file.content_type)
        end

      conn
      # Prevent MIME-sniffing: stored content_type is authoritative.
      |> put_resp_header("x-content-type-options", "nosniff")
      |> maybe_sandbox_header(file.content_type)
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

  # `?preview=1` is the ONLY way markup is served inline, and it is not a
  # bypass of the rule above: every HTML response carries the sandbox CSP,
  # which puts the document in an opaque origin with scripts refused. The
  # preview <iframe> needs an inline response to render at all, and a
  # disposition-only fix would have made the preview download instead.
  defp sandboxed_preview?(%{"preview" => value}, content_type)
       when value in ["1", "true"],
       do: markup_content_type?(content_type)

  defp sandboxed_preview?(_params, _content_type), do: false

  # APPENDS rather than sets: the browser pipeline's
  # `put_secure_browser_headers` already put `base-uri 'self';
  # frame-ancestors 'self';` on this response, and replacing the header
  # would quietly drop both while looking like a hardening change.
  defp maybe_sandbox_header(conn, content_type) do
    if markup_content_type?(content_type) do
      # `sandbox` with no allow-list: opaque origin, scripts refused.
      # Never add `allow-scripts` together with `allow-same-origin` —
      # the pair is equivalent to no sandbox, because the document can
      # then reach out and remove the restriction itself.
      existing =
        case get_resp_header(conn, "content-security-policy") do
          [value | _] -> String.trim(value)
          [] -> ""
        end

      merged = String.trim_leading(existing <> " sandbox;")
      put_resp_header(conn, "content-security-policy", merged)
    else
      conn
    end
  end

  defp markup_content_type?(ct), do: ct in ["text/html", "application/xhtml+xml"]

  # ORDER IS LOAD-BEARING: `text/html` matches the `"text/" <> _rest`
  # prefix below, so this clause is only reachable above it. Moved down,
  # it is dead code that still reads like a fix.
  defp disposition_for("text/html"), do: :attachment
  defp disposition_for("application/xhtml+xml"), do: :attachment
  defp disposition_for("image/" <> _rest), do: :inline
  defp disposition_for("text/" <> _rest), do: :inline
  defp disposition_for("application/pdf"), do: :inline
  defp disposition_for(_content_type), do: :attachment

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
end
