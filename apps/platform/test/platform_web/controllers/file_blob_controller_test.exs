defmodule PlatformWeb.FileBlobControllerTest do
  @moduledoc """
  Tests for `/files/blob/:id` — the inline-preview byte server behind
  the FilesLive detail pane (ADR 0042 stage 5 revision).

  Auth is exercised via the FilesLive ConnCase: a session-authenticated
  conn drops the `current_user_id` into the session the controller's
  `authorize/2` reads.

  ## Coverage matrix

    * 200 inline for image/text/pdf (Content-Disposition: inline).
    * 200 attachment for unknown content type (forced attachment).
    * 200 attachment when `?download=1` is passed regardless of type
      (the revision contract from Rowan's feedback).
    * 404 for unknown file id.
    * 403 for an unauthenticated session.
    * 403 for an authenticated user who's not a member of the file's
      org and is not a Fabrikam admin.
  """

  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Tenancy.OrgMembership
  alias Platform.{Files, Repo, Tasks}

  # ── Setup ──────────────────────────────────────────────────────────────

  # Point the attachment store at a per-test scratch dir so this module's
  # blobs are isolated from the shared per-run root `test.exs` configures.
  # We restore the prior value on exit so we don't poison other suites.
  setup do
    prev = Application.get_env(:platform, :chat_attachments_root)
    scratch = Platform.TestTemp.mkdir!("file_blob_test")
    Application.put_env(:platform, :chat_attachments_root, scratch)

    on_exit(fn ->
      if prev do
        Application.put_env(:platform, :chat_attachments_root, prev)
      else
        Application.delete_env(:platform, :chat_attachments_root)
      end

      File.rm_rf!(scratch)
    end)

    :ok
  end

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp insert_user(opts \\ []) do
    uniq = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: opts[:email] || "blob_user_#{uniq}@example.com",
        name: opts[:name] || "Blob User",
        oidc_sub: "oidc-blob-#{uniq}"
      })

    # Default: make the user a Fabrikam-org member so the controller's
    # `authorize/2` lets them through for fixtures parked in a Fabrikam
    # project. Pass `member: false` to skip and exercise the forbidden
    # path.
    unless opts[:member] == false do
      add_member!(user, fabrikam_org_id(), opts[:role] || "member")
    end

    user
  end

  defp add_member!(user, org_id, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()
  end

  defp authed_conn(conn, user),
    do: init_test_session(conn, current_user_id: user.id)

  defp seed_fabrikam_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Blob Project #{System.unique_integer([:positive])}",
        slug: "blob-project-#{System.unique_integer([:positive])}",
        org_id: fabrikam_org_id()
      })

    project
  end

  defp seed_blob(project, content_type, body) do
    # Write the bytes to the local-disk attachment store so the
    # controller's `send_download/3` can stream them. `storage_key`
    # mirrors the project-scoped layout that `Storage.put/3` produces.
    storage_key = "files/#{project.id}/#{Ecto.UUID.generate()}/preview.bin"

    path = Platform.Chat.AttachmentStorage.path_for(storage_key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: "preview.bin",
        original_filename: "preview-original.bin",
        content_type: content_type,
        byte_size: byte_size(body),
        storage_key: storage_key,
        content_hash:
          :crypto.hash(:sha256, body)
          |> Base.encode16(case: :lower),
        ingest_status: "ingested"
      })

    {file, path}
  end

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "GET /files/blob/:id (default disposition)" do
    test "renders inline for image content type", %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "image/png", "PNGBYTES")

      conn = conn |> authed_conn(user) |> get(~p"/files/blob/#{file.id}")

      assert conn.status == 200
      assert response_content_type(conn, :png) =~ "image/png"
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "inline"
      assert response(conn, 200) == "PNGBYTES"
    end

    test "renders inline for text content type", %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/plain", "hello body")

      conn = conn |> authed_conn(user) |> get(~p"/files/blob/#{file.id}")

      assert conn.status == 200
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "inline"
    end

    test "renders inline for application/pdf", %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "application/pdf", "%PDF-1.4")

      conn = conn |> authed_conn(user) |> get(~p"/files/blob/#{file.id}")

      assert conn.status == 200
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "inline"
    end

    test "forces attachment for unknown content type", %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "application/octet-stream", "<<bytes>>")

      conn = conn |> authed_conn(user) |> get(~p"/files/blob/#{file.id}")

      assert conn.status == 200
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
    end

    test "sets x-content-type-options: nosniff", %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/plain", "x")

      conn = conn |> authed_conn(user) |> get(~p"/files/blob/#{file.id}")

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end

  describe "uploaded markup (task 019ff1ab stage 2)" do
    # `text/html` matches the `"text/" <> _rest` prefix clause, so the
    # new clause is only reachable ABOVE it. Moved below, it is dead code
    # that reads exactly like a fix — which is why this is asserted
    # through the route rather than by reading the source.
    test "text/html is served as an attachment by default", %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/html", "<h1>Mockup</h1>")

      conn = conn |> authed_conn(user) |> get(~p"/files/blob/#{file.id}")

      assert conn.status == 200
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      refute disposition =~ "inline"
    end

    test "the change is narrow: text/plain and text/csv still render inline", %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()

      for ct <- ["text/plain", "text/csv", "text/markdown"] do
        {file, _path} = seed_blob(project, ct, "body of #{ct}")
        conn = build_conn() |> authed_conn(user) |> get(~p"/files/blob/#{file.id}")

        [disposition] = get_resp_header(conn, "content-disposition")
        assert disposition =~ "inline", "expected #{ct} to stay inline"
      end
    end

    test "?preview=1 serves markup inline for the sandboxed frame, under a sandbox CSP",
         %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/html", "<h1>Mockup</h1>")

      conn = conn |> authed_conn(user) |> get(~p"/files/blob/#{file.id}?preview=1")

      assert conn.status == 200
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "inline"
      # Inline is only safe BECAUSE of this header: an opaque origin with
      # scripts refused, whichever frame asked for the bytes.
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "sandbox"
      # The directive is APPENDED: replacing the header would silently
      # drop the browser pipeline's baseline while looking like a fix.
      assert csp =~ "frame-ancestors"
    end

    test "?preview=1 does not widen anything else — a non-markup type is unaffected",
         %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "application/octet-stream", "<<bytes>>")

      conn = conn |> authed_conn(user) |> get(~p"/files/blob/#{file.id}?preview=1")

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      [csp] = get_resp_header(conn, "content-security-policy")
      refute csp =~ "sandbox"
      # Positive control: the baseline header IS present, so the refute
      # above is not reading a missing header.
      assert csp =~ "frame-ancestors"
    end

    test "download=1 still wins over preview=1 for markup", %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/html", "<h1>Mockup</h1>")

      conn = conn |> authed_conn(user) |> get(~p"/files/blob/#{file.id}?preview=1&download=1")

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
    end

    # ── Interactive-code gate (task 01a06a20 stage 2) ─────────────────────

    test "a flagged file requested by the preview iframe receives sandbox allow-scripts",
         %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/html", "<h1>Mockup</h1>")
      {:ok, file} = Files.mark_interactive(%{id: user.id}, file)

      conn =
        conn
        |> authed_conn(user)
        |> put_req_header("sec-fetch-dest", "iframe")
        |> get(~p"/files/blob/#{file.id}?preview=1")

      assert conn.status == 200
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "sandbox allow-scripts"
      assert csp =~ "default-src 'none'"
      assert csp =~ "script-src 'unsafe-inline'"
      assert csp =~ "style-src 'unsafe-inline'"
      assert csp =~ "img-src data: blob:"
      assert csp =~ "media-src data: blob:"
      assert csp =~ "font-src data:"
      assert csp =~ "connect-src 'none'"
      assert csp =~ "form-action 'none'"
      # Never these, under any circumstance — `allow-scripts` plus any of
      # them lets the document lift its own sandbox restriction.
      refute csp =~ "allow-same-origin"
      refute csp =~ "allow-popups"
      refute csp =~ "allow-forms"
      refute csp =~ "allow-modals"
      refute csp =~ "allow-top-navigation"
    end

    test "a flagged file requested as a top-level document (not framed) falls back to bare sandbox",
         %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/html", "<h1>Mockup</h1>")
      {:ok, file} = Files.mark_interactive(%{id: user.id}, file)

      conn =
        conn
        |> authed_conn(user)
        |> put_req_header("sec-fetch-dest", "document")
        |> get(~p"/files/blob/#{file.id}?preview=1")

      assert conn.status == 200
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "sandbox"
      refute csp =~ "allow-scripts"
    end

    test "a flagged, framed response still carries Phoenix's base-uri and frame-ancestors",
         %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/html", "<h1>Mockup</h1>")
      {:ok, file} = Files.mark_interactive(%{id: user.id}, file)

      conn =
        conn
        |> authed_conn(user)
        |> put_req_header("sec-fetch-dest", "iframe")
        |> get(~p"/files/blob/#{file.id}?preview=1")

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "base-uri 'self'"
      assert csp =~ "frame-ancestors 'self'"
    end
  end

  describe "GET /files/blob/:id?download=1" do
    test "forces attachment disposition for an inline-default type (image)", %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "image/png", "PNGBYTES")

      conn =
        conn
        |> authed_conn(user)
        |> get(~p"/files/blob/#{file.id}?download=1")

      assert conn.status == 200
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "preview-original.bin"
    end

    test "forces attachment disposition for PDF", %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "application/pdf", "%PDF-1.4")

      conn =
        conn
        |> authed_conn(user)
        |> get(~p"/files/blob/#{file.id}?download=1")

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
    end

    test "download=true also accepted (truthy alias)", %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "image/png", "PNG")

      conn =
        conn
        |> authed_conn(user)
        |> get(~p"/files/blob/#{file.id}?download=true")

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
    end
  end

  describe "errors" do
    test "403 for an authenticated user that's not a member of the file's org",
         %{conn: conn} do
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/plain", "x")

      # `member: false` skips the default Fabrikam-org membership, so the
      # controller's `do_authorize/2` hits the final `:forbidden`
      # branch.
      user = insert_user(member: false)

      conn = conn |> authed_conn(user) |> get(~p"/files/blob/#{file.id}")

      assert conn.status == 403
    end

    test "404 for an unknown file id", %{conn: conn} do
      user = insert_user()

      conn =
        conn
        |> authed_conn(user)
        |> get(~p"/files/blob/#{Ecto.UUID.generate()}")

      assert conn.status == 404
    end

    test "unauthenticated session is bounced to /auth/login by the pipeline",
         %{conn: conn} do
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/plain", "x")

      # No init_test_session — the :require_auth pipeline plug halts
      # the conn with a 302 to /auth/login long before the controller
      # gets a chance to do its own org-membership check.
      conn = get(conn, ~p"/files/blob/#{file.id}")

      assert conn.status == 302
      assert redirected_to(conn) == "/auth/login"
    end
  end

  describe "API-caller auth contract (task 01a09415 stage 3)" do
    # NOTE (task 01a09415 stage 1): `/files/blob/:id` is mounted behind the
    # `:blob_browser` pipeline, NOT the shared `:browser` pipeline.
    # `:blob_browser` is identical to `:browser` except it declares
    # `plug(:accepts, ["html", "json"])`, so an `Accept: application/json`
    # request is no longer refused with 406 by content negotiation and DOES
    # reach `RequireAuth.deny/2`. Both API-caller signals are therefore
    # reachable on this route: the bare `authorization` header and the
    # `accept` header. On every other `:browser` route the Accept path is
    # still refused with 406 — the widening is scoped to this route alone.
    test "bearer token without a session gets 401, not a login redirect", %{conn: conn} do
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/plain", "x")

      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> get(~p"/files/blob/#{file.id}")

      assert conn.status == 401
    end

    test "the 401 body is JSON, not an HTML login page", %{conn: conn} do
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/plain", "x")

      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> get(~p"/files/blob/#{file.id}")

      # The negative alone would be satisfied by an empty body from a 500 or
      # a vanished route, so it is paired with a positive decode.
      refute conn.resp_body =~ "<html"
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "unauthorized"
    end

    test "positive control: an authenticated session still gets the exact bytes",
         %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      body = "POSITIVE-CONTROL-BYTES"
      {file, _path} = seed_blob(project, "text/plain", body)

      conn = conn |> authed_conn(user) |> get(~p"/files/blob/#{file.id}")

      assert conn.status == 200
      assert conn.resp_body == body
    end

    test "Accept: application/json without a session reaches RequireAuth and gets 401 JSON",
         %{conn: conn} do
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/plain", "JSON-PREFERRING-CLIENT-BYTES")

      # Before task 01a09415 this request raised `Phoenix.NotAcceptableError`
      # (406) from `plug(:accepts, ["html"])` before `:require_auth` ran. On
      # `:blob_browser` it reaches `RequireAuth.deny/2` instead.
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/files/blob/#{file.id}")

      assert conn.status == 401
      # The negative alone would be satisfied by an empty body from a 500 or
      # a vanished route, so it is paired with a positive decode.
      refute conn.resp_body =~ "<html"
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "unauthorized"
    end

    test "an authenticated session sending Accept: application/json still gets the exact bytes",
         %{conn: conn} do
      user = insert_user()
      project = seed_fabrikam_project()
      body = "JSON-ACCEPT-POSITIVE-CONTROL-BYTES"
      {file, _path} = seed_blob(project, "text/plain", body)

      # Positive control for the test above: proves the 401 is the auth gate
      # firing, not the route having stopped serving under this Accept header.
      conn =
        conn
        |> authed_conn(user)
        |> put_req_header("accept", "application/json")
        |> get(~p"/files/blob/#{file.id}")

      assert conn.status == 200
      assert conn.resp_body == body
    end

    test "authenticated non-member sending Accept: application/json gets 403 Forbidden",
         %{conn: conn} do
      project = seed_fabrikam_project()
      {file, _path} = seed_blob(project, "text/plain", "x")

      # `member: false` skips the default Fabrikam-org membership, so the
      # controller's own org gate — which this task does not change —
      # answers. Reachable only now that the Accept header no longer 406s.
      user = insert_user(member: false)

      conn =
        conn
        |> authed_conn(user)
        |> put_req_header("accept", "application/json")
        |> get(~p"/files/blob/#{file.id}")

      assert conn.status == 403
      assert conn.resp_body == "Forbidden"
    end

    test "authenticated member sending Accept: application/json gets 404 for an absent id",
         %{conn: conn} do
      user = insert_user()

      conn =
        conn
        |> authed_conn(user)
        |> put_req_header("accept", "application/json")
        |> get(~p"/files/blob/#{Ecto.UUID.generate()}")

      assert conn.status == 404
      assert conn.resp_body == "Not found"
    end
  end

  describe "content-negotiation blast radius (task 01a09415 stage 2)" do
    test "another :browser route still raises Phoenix.NotAcceptableError for Accept: application/json",
         %{conn: conn} do
      user = insert_user()

      # `~p"/"` is mounted on the SHARED `:browser` pipeline, whose first plug
      # is still `plug(:accepts, ["html"])`. Stage 1 widened `:blob_browser`
      # only. If this ever stops raising, `:browser` itself was widened and
      # the siting decision this task recorded has been undone.
      assert_raise Phoenix.NotAcceptableError, fn ->
        conn
        |> authed_conn(user)
        |> put_req_header("accept", "application/json")
        |> get(~p"/")
      end
    end
  end
end
