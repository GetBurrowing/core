defmodule PlatformWeb.FileBlobController do
  @moduledoc """
  Serves the bytes behind a `Platform.Files.File` row for inline preview
  in the FilesLive surface (ADR 0042 stage 5 UI).

  Authorization mirrors the `file_get_text` MCP tool: the caller must
  either be a root-org admin or a member of the project's owning
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

  ## Interactive-code gate (task 01a06a20 stage 2)

  A file whose `interactive_at` is set (task 01a06a20 stage 1) gets
  `sandbox allow-scripts` instead of bare `sandbox` — but only when the
  request's `Sec-Fetch-Dest` header is `iframe`. A direct top-level hit on
  this route (address bar, a bare link) carries no such header and always
  gets bare `sandbox`, because a flagged file rendered full-page on the
  Burrow origin is a phishing surface (attacker-styled content behind a
  suite.example.com URL), not an XSS one, and `allow-scripts` would make
  that surface active instead of inert.

  INVARIANT: the framed document can still call `window.postMessage`
  toward its parent — `sandbox` does not block that. Nothing in
  `apps/platform/assets/js` listens for `message` events today, so there
  is nothing to receive it. Adding such a listener later without
  validating `event.origin` would reopen the surface this gate closes.
  """

  use PlatformWeb, :controller

  alias Platform.Accounts
  alias Platform.Chat.AttachmentStorage
  alias Platform.Files
  alias Platform.Tasks
  alias Platform.Tenancy

  def show(conn, %{"id" => file_id} = params) do
    with %Files.File{} = file <- Files.get_file(file_id),
         {:ok, project} <- authorize(conn, file),
         :ok <- access_check(conn, project) do
      send_file_bytes(
        conn,
        file,
        force_download?(params),
        sandboxed_preview?(params, file.content_type)
      )
    else
      nil -> send_resp(conn, :not_found, "Not found")
      {:error, :forbidden} -> send_resp(conn, :forbidden, "Forbidden")
      # A deny answers exactly as an unknown file id does.
      {:error, :denied} -> send_resp(conn, :not_found, "Not found")
    end
  end

  # RBAC v2 (task 01a1386e-45a5 stage 1): `files.read` on the file's project,
  # in conjunction with `do_authorize/2`. It runs after EVERY admitting arm,
  # the root-admin one included, because "the root-admin bypass does not read
  # past a deny":
  # `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`.
  # With no grants on the scope it is `:ok`.
  defp access_check(_conn, nil), do: :ok

  defp access_check(conn, %Tasks.Project{id: project_id}) do
    scope =
      case conn.assigns do
        %{access_scope: %Platform.Access.Scope{} = scope} ->
          scope

        _ ->
          Platform.Access.Scope.for_user(Accounts.get_user(get_session(conn, :current_user_id)))
      end

    Platform.Access.check(scope, "files.read", {:project, project_id})
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
      |> maybe_sandbox_header(file)
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

  # `default-src 'none'` denies everything not explicitly reopened below,
  # for the narrow case of a flagged file framed for real (see
  # `sandbox_directive/2`):
  #
  #   * `script-src 'unsafe-inline'` — inline `<script>` in the uploaded
  #     markup. `script-src-attr` has no value of its own and falls back
  #     to `script-src`, so this also covers inline event-handler
  #     attributes — verified against the CSP3 fallback rules while
  #     planning, not assumed.
  #   * `style-src 'unsafe-inline'` — inline styling in the same markup.
  #   * `img-src`/`media-src` include `blob:` because canvas chart flows
  #     call `canvas.toBlob()`; without it, charts render blank.
  #   * `connect-src 'none'` is the point of the whole design: the framed
  #     document gets no network of its own, so `allow-scripts` running
  #     inside it has no exfiltration path.
  #   * `form-action 'none'` — no `<form>` submission out of the frame.
  #
  # `sandbox` is a document directive and composes with these fetch
  # directives in one policy (CSP3) — no need to split them across two
  # headers.
  @interactive_frame_csp "sandbox allow-scripts; default-src 'none'; " <>
                           "script-src 'unsafe-inline'; style-src 'unsafe-inline'; " <>
                           "img-src data: blob:; media-src data: blob:; font-src data:; " <>
                           "connect-src 'none'; form-action 'none'"

  # APPENDS rather than sets: the browser pipeline's
  # `put_secure_browser_headers` already put `base-uri 'self';
  # frame-ancestors 'self';` on this response, and replacing the header
  # would quietly drop both while looking like a hardening change.
  defp maybe_sandbox_header(conn, %Files.File{} = file) do
    if markup_content_type?(file.content_type) do
      existing =
        case get_resp_header(conn, "content-security-policy") do
          [value | _] -> String.trim(value)
          [] -> ""
        end

      merged = String.trim_leading(existing <> " " <> sandbox_directive(conn, file))
      put_resp_header(conn, "content-security-policy", merged)
    else
      conn
    end
  end

  # Flagged (`interactive_at` set) AND requested by the preview <iframe> —
  # the only combination that gets `allow-scripts`. `Sec-Fetch-Dest:
  # iframe` is what tells the preview frame's request apart from a direct
  # top-level hit on the same URL; a missing header (older browsers) or
  # any other value (a bare link, the address bar, `Sec-Fetch-Dest:
  # document`) falls back to bare `sandbox`, same as an unflagged file.
  #
  # Emits `sandbox allow-scripts` rather than a second, separate `sandbox`
  # directive: CSP ignores every directive of a given type after the
  # first one in a policy, so a duplicate `sandbox` later in the header
  # would silently leave the file inert instead of interactive.
  defp sandbox_directive(conn, %Files.File{interactive_at: %DateTime{}}) do
    if get_req_header(conn, "sec-fetch-dest") == ["iframe"] do
      @interactive_frame_csp
    else
      "sandbox;"
    end
  end

  defp sandbox_directive(_conn, _file), do: "sandbox;"

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
      Tenancy.root_admin?(user) ->
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
