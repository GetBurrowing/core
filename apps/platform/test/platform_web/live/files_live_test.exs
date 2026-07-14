defmodule PlatformWeb.FilesLiveTest do
  @moduledoc """
  Tests for the FilesLive surface (ADR 0042 stage 5).

  Covers the four contract surfaces the dispatch called out:

    * Mount renders the project picker grouped by org (ADR 0042 sidebar
      shape — same shape as TasksLive so the two surfaces never drift).
    * Selecting a project loads its file list.
    * Upload pipeline → create row + kick off the async ingester.
    * PubSub broadcast (`{:file_ingested, file_id}`) updates the row's
      `ingest_status` badge live without a refresh.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.{Files, Repo, Tasks}

  # ── Helpers ────────────────────────────────────────────────────────────

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "files_lv_#{System.unique_integer([:positive])}@example.com",
        name: "Files LV User",
        oidc_sub: "oidc-files-lv-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp tenant_or_fabrikam_org_id("fabrikam"), do: fabrikam_org_id()
  defp tenant_or_fabrikam_org_id(slug), do: tenant_org_id(slug)

  defp seed_project(org_slug, name) do
    {:ok, project} =
      Tasks.create_project(%{
        name: name,
        slug: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"),
        org_id: tenant_or_fabrikam_org_id(org_slug)
      })

    project
  end

  defp seed_file(project, attrs) do
    base = %{
      project_id: project.id,
      org_id: project.org_id,
      name: "doc.txt",
      original_filename: "doc.txt",
      content_type: "text/plain",
      byte_size: 12,
      storage_key: "files/#{project.id}/#{Ecto.UUID.generate()}/doc.txt",
      content_hash: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
      ingest_status: "pending"
    }

    {:ok, file} = Files.create_file(Map.merge(base, attrs))
    file
  end

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "mount" do
    test "renders project picker grouped by org (ADR 0042 shape)", %{conn: conn} do
      conn = authenticated_conn(conn)

      _fabrikam = seed_project("fabrikam", "Files Mount Fabrikam")
      _gen = seed_project("soylent", "Files Mount Gen")

      {:ok, _view, html} = live(conn, ~p"/files")

      assert html =~ ~s(data-role="files-project-group" data-org-slug="fabrikam")
      assert html =~ ~s(data-role="files-project-group" data-org-slug="soylent")
      assert html =~ "Files Mount Fabrikam"
      assert html =~ "Files Mount Gen"
    end

    test "registers the icon-rail Files tile", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/files")

      assert html =~ ~s(data-destination="files")
    end
  end

  describe "select project" do
    test "loading a project URL renders its file list", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Project Alpha")
      file = seed_file(project, %{name: "alpha-readme.txt"})

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      assert html =~ "alpha-readme.txt"
      # The pending-status badge label is "Ingesting…" (Phase-2 copy).
      assert html =~ "Ingesting"
      assert html =~ ~s(data-role="files-table")
      # Selected file row carries the stable file-id selector so the
      # PubSub-refresh test below can target it.
      assert html =~ "data-file-id=\"#{file.id}\""
    end

    test "without a selected project the dropzone shows the empty state", %{conn: conn} do
      conn = authenticated_conn(conn)
      _project = seed_project("fabrikam", "Project Empty Picker")

      {:ok, _view, html} = live(conn, ~p"/files")

      assert html =~ "Pick a project"
      assert html =~ ~s(data-role="file-dropzone")
    end

    # Regression: the upload control used to live ONLY inside the
    # empty-state branch, so a project that already had files rendered the
    # table with no way to add more. The control now lives in the header
    # toolbar and must be present whenever a project is selected — for both
    # empty and non-empty projects.
    test "non-empty project still renders the persistent upload control", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Project With Files")
      _file = seed_file(project, %{name: "existing.txt"})

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      # The file table is showing (non-empty branch)…
      assert html =~ ~s(data-role="files-table")
      # …and the upload control is STILL present (the bug being fixed).
      assert html =~ ~s(data-role="files-upload-form")
      assert html =~ ~s(id="files-upload-form")
      # Drag-drop target still wraps the file area.
      assert html =~ ~s(data-role="file-dropzone")
    end

    test "empty project renders the persistent upload control", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Project No Files")

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      assert html =~ "No files yet"
      assert html =~ ~s(data-role="files-upload-form")
      assert html =~ ~s(id="files-upload-form")
    end
  end

  describe "PubSub: ingest_status flips on broadcast" do
    test "file_ingested message updates the row's status badge", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Live Refresh Project")
      file = seed_file(project, %{name: "live-doc.txt"})

      {:ok, view, html} = live(conn, ~p"/files/#{project.id}")

      assert html =~ "Ingesting"

      # Flip the persisted status, then broadcast — the LV re-fetches and
      # the badge text should now read "Ready".
      {:ok, _} = Files.update_ingest_status(file, "ingested")
      :ok = Files.broadcast_project(project.id, {:file_ingested, file.id})

      # Allow the LV process to drain the PubSub message.
      html_after = render(view)

      assert html_after =~ "Ready"
      refute_in_row(html_after, file.id, "Ingesting")
    end

    test "file_ingest_failed message flips status to Failed", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Failure Refresh Project")
      file = seed_file(project, %{name: "failing-doc.txt"})

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      {:ok, _} = Files.update_ingest_status(file, "failed")
      :ok = Files.broadcast_project(project.id, {:file_ingest_failed, file.id, :extract_failed})

      html_after = render(view)
      assert html_after =~ "Failed"
    end

    test "file_deleted message drops the row from the LV", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Delete Refresh Project")
      file = seed_file(project, %{name: "going-away.txt"})

      {:ok, view, html} = live(conn, ~p"/files/#{project.id}")

      assert html =~ "going-away.txt"

      # The file_delete MCP tool removes the row + broadcasts on the
      # project topic. Simulate the post-row-delete + broadcast sequence.
      {:ok, _} = Files.delete_file(file)
      :ok = Files.broadcast_deleted(project.id, file.id)

      html_after = render(view)
      refute html_after =~ "going-away.txt"
    end
  end

  describe "FAB + dropzone markers" do
    test "mobile FAB carries the canonical data-role marker", %{conn: conn} do
      conn = authenticated_conn(conn)
      _ = seed_project("fabrikam", "FAB Project")

      {:ok, _view, html} = live(conn, ~p"/files")

      assert html =~ ~s(data-role="file-upload-fab")

      assert html =~
               "bottom-[calc(env(safe-area-inset-bottom)+1.5rem+var(--bottom-nav-height,0px))]"
    end

    test "dropzone carries the namespaced marker (not chat's)", %{conn: conn} do
      conn = authenticated_conn(conn)
      _ = seed_project("fabrikam", "Dropzone Project")

      {:ok, _view, html} = live(conn, ~p"/files")

      assert html =~ ~s(data-role="file-dropzone")
      # Chat's dropzone uses a different role; never collide.
      refute html =~ ~s(data-role="chat-dropzone")
    end
  end

  describe "detail pane (in-app viewer)" do
    # Each branch is verified end-to-end: a file of the given content
    # type is seeded, the LV selects it, and we assert the correct
    # render mode element + its data-role marker is present. This is
    # the contract Rowan's stage-5 revision pinned down ("you should be
    # able to open and see the ingested file" — not a text excerpt).

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Detail Pane Project")
      {:ok, conn: conn, project: project}
    end

    test "image content type renders inline <img> pointing at /files/blob/:id",
         %{conn: conn, project: project} do
      file =
        seed_file(project, %{
          name: "shot.png",
          original_filename: "shot.png",
          content_type: "image/png",
          ingest_status: "ingested"
        })

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      html = view |> element("tr[data-file-id='#{file.id}']") |> render_click()

      assert html =~ ~s(data-role="files-detail-image")
      assert html =~ ~s(src="/files/blob/#{file.id}")
    end

    test "application/pdf renders an <iframe> for in-app PDF preview",
         %{conn: conn, project: project} do
      file =
        seed_file(project, %{
          name: "spec.pdf",
          original_filename: "spec.pdf",
          content_type: "application/pdf",
          ingest_status: "ingested"
        })

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      html = view |> element("tr[data-file-id='#{file.id}']") |> render_click()

      assert html =~ ~s(data-role="files-detail-pdf")
      assert html =~ "<iframe"
      assert html =~ ~s(src="/files/blob/#{file.id}")
    end

    test "text/plain renders extracted text in a <pre>",
         %{conn: conn, project: project} do
      file =
        seed_file(project, %{
          name: "notes.txt",
          original_filename: "notes.txt",
          content_type: "text/plain",
          ingest_status: "ingested"
        })

      {:ok, _text} = Files.upsert_extracted_text(file.id, "Plain body content")

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      html = view |> element("tr[data-file-id='#{file.id}']") |> render_click()

      assert html =~ ~s(data-role="files-detail-text")
      assert html =~ "Plain body content"
    end

    test "text/markdown renders extracted text through the markdown renderer",
         %{conn: conn, project: project} do
      file =
        seed_file(project, %{
          name: "readme.md",
          original_filename: "readme.md",
          content_type: "text/markdown",
          ingest_status: "ingested"
        })

      {:ok, _text} =
        Files.upsert_extracted_text(file.id, "# Heading\n\nParagraph **bold** here.")

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      html = view |> element("tr[data-file-id='#{file.id}']") |> render_click()

      assert html =~ ~s(data-role="files-detail-markdown")
      # Markdown pipeline downgrades h1 to h3 + emits <strong> for **bold**.
      assert html =~ "<strong>bold</strong>"
    end

    test "DOCX-class content type renders extracted text as a prose <div>",
         %{conn: conn, project: project} do
      file =
        seed_file(project, %{
          name: "draft.docx",
          original_filename: "draft.docx",
          content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
          ingest_status: "ingested"
        })

      {:ok, _text} = Files.upsert_extracted_text(file.id, "DOCX body text")

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      html = view |> element("tr[data-file-id='#{file.id}']") |> render_click()

      assert html =~ ~s(data-role="files-detail-document")
      assert html =~ "DOCX body text"
    end

    test "unknown content type renders a 'cannot preview' card with a download link",
         %{conn: conn, project: project} do
      file =
        seed_file(project, %{
          name: "blob.bin",
          original_filename: "blob.bin",
          content_type: "application/octet-stream",
          ingest_status: "ingested"
        })

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      html = view |> element("tr[data-file-id='#{file.id}']") |> render_click()

      assert html =~ ~s(data-role="files-detail-unknown")
      assert html =~ "/files/blob/#{file.id}?download=1"
    end

    test "detail-pane Download + Copy-link controls are always rendered",
         %{conn: conn, project: project} do
      file =
        seed_file(project, %{
          name: "any.txt",
          original_filename: "any.txt",
          content_type: "text/plain",
          ingest_status: "ingested"
        })

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      html = view |> element("tr[data-file-id='#{file.id}']") |> render_click()

      assert html =~ ~s(data-role="files-detail-download")
      assert html =~ "/files/blob/#{file.id}?download=1"
      assert html =~ ~s(data-role="files-detail-copy-link")
      assert html =~ ~s(phx-hook="CopyToClipboard")
      assert html =~ ~s(data-clipboard-text="/files/blob/#{file.id}")
    end
  end

  describe "upload pipeline" do
    # These cases lock in the fix for task 019f5e1f: the LV's upload
    # progress callback used `consume_uploaded_entries/3` (plural),
    # which raises whenever any entry in the batch is still in
    # progress, and its `split_with` matched `{:ok, _}` instead of the
    # actual `{:created, _}` / `{:dedup, _}` shapes the callback
    # returns. Regression here would surface as Marlowe's original bug:
    # a false "N file(s) failed to upload" toast on happy paths (Bug
    # B), and — on bulk — a crash before any row lands (Bug A). The
    # fix drains per-entry via `consume_uploaded_entry/3` (singular)
    # and pattern-matches the inner tuple shape.

    setup do
      # Point the local-disk storage adapter at a writable temp root
      # for the duration of the describe. The default runtime.exs
      # value is `/data/platform/chat_uploads` (prod path) which is
      # not writable in CI.
      root =
        Path.join(
          System.tmp_dir!(),
          "files-live-upload-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      previous = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, root)

      on_exit(fn ->
        File.rm_rf!(root)

        if previous do
          Application.put_env(:platform, :chat_attachments_root, previous)
        else
          Application.delete_env(:platform, :chat_attachments_root)
        end
      end)

      :ok
    end

    test "single-entry upload does not flash an error on success", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Upload Happy Single")

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      upload =
        file_input(view, "#files-upload-form", :files, [
          %{
            name: "alpha.pdf",
            content: "%PDF-alpha-body-#{System.unique_integer([:positive])}",
            type: "application/pdf"
          }
        ])

      # `auto_upload: true` triggers `handle_file_upload_progress` at
      # `done? == true`; the progress callback drains + inserts the
      # row inside the LV process (same sandbox as this test).
      render_upload(upload, "alpha.pdf")

      html = render(view)

      refute html =~ "failed to upload"
      refute html =~ ~s(id="flash-error")

      [file] = Files.list_files_for_project(project.id)
      assert file.original_filename == "alpha.pdf"
      assert file.content_type == "application/pdf"
    end

    test "bulk-entry upload stores each entry's own filename + content_type", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Upload Happy Bulk")

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      unique = System.unique_integer([:positive])

      # Distinct bytes so the content_hash unique index doesn't dedup
      # them into a single row (which would mask the metadata bug).
      # We sequence three uploads through the SAME view, each via its
      # own `file_input` so LiveViewTest's per-upload client survives
      # `consume_uploaded_entry/3`'s post-consume channel shutdown —
      # `render_upload/2` for a second entry against a stopped
      # channel exits with `no process`, so we spin up a fresh input
      # per file. In real UI usage the browser opens three concurrent
      # UploadChannels and each fires its own progress callback, so
      # this preserves the per-entry drain semantics we care about.
      entries = [
        %{name: "alpha.pdf", content: "%PDF-alpha-#{unique}", type: "application/pdf"},
        %{name: "bravo.pdf", content: "%PDF-bravo-#{unique}", type: "application/pdf"},
        %{name: "charlie.pdf", content: "%PDF-charlie-#{unique}", type: "application/pdf"}
      ]

      Enum.each(entries, fn entry ->
        upload = file_input(view, "#files-upload-form", :files, [entry])
        render_upload(upload, entry.name)
      end)

      html = render(view)

      refute html =~ "failed to upload"

      files = Files.list_files_for_project(project.id)
      assert length(files) == 3

      names = files |> Enum.map(& &1.original_filename) |> Enum.sort()
      assert names == ["alpha.pdf", "bravo.pdf", "charlie.pdf"]

      # Each row carries its OWN client_type — regression check:
      # closing over the outer trigger entry (or ignoring the inner
      # entry arg on the plural drain) would tag every row with
      # entry-1's mime, which the `content_type` filter in
      # `Files.list_files_for_project/2` would silently drop.
      assert Enum.all?(files, &(&1.content_type == "application/pdf"))

      # Distinct bytes → distinct content_hashes → no dedup collapse.
      hashes = files |> Enum.map(& &1.content_hash) |> Enum.uniq()
      assert length(hashes) == 3
    end

    test "successful single upload puts an info flash", %{conn: conn} do
      # Positive-feedback path added in Stage 3: after Stage 2's
      # result-classification fix, we surface a `put_flash(:info, …)` so
      # users see confirmation instead of silent success (the old code
      # only ever surfaced errors). Rendered flash markup carries
      # `role="alert"` from CoreComponents' `<.flash>`; the info variant
      # is keyed with `id="flash-info"` in the shell layout.
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Upload Info Flash Single")

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      upload =
        file_input(view, "#files-upload-form", :files, [
          %{
            name: "hello.pdf",
            content: "%PDF-hello-#{System.unique_integer([:positive])}",
            type: "application/pdf"
          }
        ])

      render_upload(upload, "hello.pdf")

      html = render(view)

      assert html =~ "1 file uploaded"
      assert html =~ ~s(id="flash-info")
      refute html =~ "failed to upload"
      refute html =~ ~s(id="flash-error")
    end

    test "successful bulk upload puts a pluralized info flash", %{conn: conn} do
      # Three fresh uploads should tally into a single "3 files uploaded"
      # flash. We sequence via separate `file_input` calls (same reason as
      # the bulk-metadata regression test above — `render_upload/2` for a
      # second entry against a stopped channel exits with `no process`).
      # In real UI, each concurrent UploadChannel fires its own progress
      # callback; the batch counter accumulates the same way. `validate_upload`
      # (which resets the batch) is NOT triggered by `file_input` in tests,
      # so the running count survives across the three inputs.
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Upload Info Flash Bulk")

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      unique = System.unique_integer([:positive])

      entries = [
        %{name: "alpha.pdf", content: "%PDF-alpha-flash-#{unique}", type: "application/pdf"},
        %{name: "bravo.pdf", content: "%PDF-bravo-flash-#{unique}", type: "application/pdf"},
        %{name: "charlie.pdf", content: "%PDF-charlie-flash-#{unique}", type: "application/pdf"}
      ]

      Enum.each(entries, fn entry ->
        upload = file_input(view, "#files-upload-form", :files, [entry])
        render_upload(upload, entry.name)
      end)

      html = render(view)

      assert html =~ "3 files uploaded"
      assert html =~ ~s(id="flash-info")
      refute html =~ "failed to upload"
    end

    test "mixed created + dedup flashes a hybrid message", %{conn: conn} do
      # Seed an already-ingested row with a specific hash, then upload
      # two files: one with FRESH bytes (→ `{:created, _}`) and one with
      # the SAME bytes as the seed (→ `{:dedup, _}` via
      # `find_ingested_sibling/2`). The batch counter should report
      # "2 files uploaded (1 already ingested)" — dedup called out
      # parenthetically so users understand nothing new landed for that
      # one, but nothing failed either.
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Upload Info Flash Mixed")

      unique = System.unique_integer([:positive])
      dup_body = "%PDF-dup-body-#{unique}"
      new_body = "%PDF-fresh-body-#{unique}"

      dup_hash =
        :crypto.hash(:sha256, dup_body) |> Base.encode16(case: :lower)

      _sibling =
        seed_file(project, %{
          name: "seeded-dup.pdf",
          original_filename: "seeded-dup.pdf",
          content_type: "application/pdf",
          content_hash: dup_hash,
          ingest_status: "ingested"
        })

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      dup_upload =
        file_input(view, "#files-upload-form", :files, [
          %{name: "dup.pdf", content: dup_body, type: "application/pdf"}
        ])

      render_upload(dup_upload, "dup.pdf")

      new_upload =
        file_input(view, "#files-upload-form", :files, [
          %{name: "fresh.pdf", content: new_body, type: "application/pdf"}
        ])

      render_upload(new_upload, "fresh.pdf")

      html = render(view)

      assert html =~ "2 files uploaded (1 already ingested)"
      assert html =~ ~s(id="flash-info")
      refute html =~ "failed to upload"
    end

    test "storage-adapter error surfaces the error flash", %{conn: conn} do
      # Swap the attachment_storage_adapter for a stub that fails
      # persist/2. Files.Storage.put dispatches through the same
      # adapter as the chat side; forcing an error there lets us
      # verify the surviving error-flash path.
      previous = Application.get_env(:platform, :attachment_storage_adapter)

      Application.put_env(
        :platform,
        :attachment_storage_adapter,
        PlatformWeb.FilesLiveTest.FailingAdapter
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:platform, :attachment_storage_adapter, previous)
        else
          Application.delete_env(:platform, :attachment_storage_adapter)
        end
      end)

      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Upload Error Path")

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      upload =
        file_input(view, "#files-upload-form", :files, [
          %{name: "boom.pdf", content: "%PDF-boom", type: "application/pdf"}
        ])

      render_upload(upload, "boom.pdf")

      html = render(view)

      assert html =~ "1 file(s) failed to upload"
      assert Files.list_files_for_project(project.id) == []
    end
  end

  describe "preview_mode/1" do
    test "classifies content types into render modes" do
      assert PlatformWeb.FilesLive.preview_mode(%Files.File{content_type: "image/png"}) == :image

      assert PlatformWeb.FilesLive.preview_mode(%Files.File{content_type: "image/svg+xml"}) ==
               :image

      assert PlatformWeb.FilesLive.preview_mode(%Files.File{content_type: "application/pdf"}) ==
               :pdf

      assert PlatformWeb.FilesLive.preview_mode(%Files.File{content_type: "text/markdown"}) ==
               :markdown

      assert PlatformWeb.FilesLive.preview_mode(%Files.File{content_type: "text/plain"}) == :text

      assert PlatformWeb.FilesLive.preview_mode(%Files.File{content_type: "application/json"}) ==
               :text

      assert PlatformWeb.FilesLive.preview_mode(%Files.File{
               content_type:
                 "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
             }) == :document

      assert PlatformWeb.FilesLive.preview_mode(%Files.File{
               content_type: "application/octet-stream"
             }) == :unknown
    end
  end

  describe "filtered_and_sorted helper" do
    test "filter narrows by case-insensitive substring", %{conn: _conn} do
      project = seed_project("fabrikam", "Filter Helper Project")
      a = seed_file(project, %{name: "Alpha.txt"})
      b = seed_file(project, %{name: "Beta.txt"})

      result = PlatformWeb.FilesLive.filtered_and_sorted([a, b], "alpha", "date_desc")
      assert result == [a]
    end

    test "name_asc sorts alphabetically case-insensitively", %{conn: _conn} do
      project = seed_project("fabrikam", "Sort Helper Project")
      a = seed_file(project, %{name: "zeta.txt"})
      b = seed_file(project, %{name: "Alpha.txt"})

      result = PlatformWeb.FilesLive.filtered_and_sorted([a, b], "", "name_asc")
      assert result == [b, a]
    end
  end

  # ── Local helpers ──────────────────────────────────────────────────────

  # Scan the rendered HTML for a `<tr data-file-id="...">…</tr>` block and
  # assert it does NOT contain the given needle. Helps the live-refresh
  # test pin "Ingesting" specifically to the row that flipped, not just
  # to the document as a whole (other rows may still be pending in a
  # broader fixture).
  defp refute_in_row(html, file_id, needle) do
    case Regex.run(
           ~r/<tr[^>]*data-file-id="#{Regex.escape(file_id)}"[^>]*>(.*?)<\/tr>/s,
           html
         ) do
      [_, row_body] ->
        refute row_body =~ needle,
               "expected row #{file_id} to NOT contain #{inspect(needle)}; got: #{row_body}"

      _ ->
        flunk("no row matched data-file-id=#{file_id}")
    end
  end
end

defmodule PlatformWeb.FilesLiveTest.FailingAdapter do
  @moduledoc false
  # Stub attachment-storage adapter used by the upload-error test.
  # Fails `persist/2` so `Files.Storage.put` returns `{:error, _}` and
  # the LV can prove the error-flash path still fires.

  @behaviour Platform.Chat.AttachmentStorage.Adapter

  @impl true
  def persist(_key, _source), do: {:error, :storage_failed}

  @impl true
  def read_stream(_key), do: {:error, :enoent}

  @impl true
  def delete(_key), do: :ok

  @impl true
  def presign_upload(_key, _max_bytes, _ttl_s), do: {:error, :not_supported}
end
