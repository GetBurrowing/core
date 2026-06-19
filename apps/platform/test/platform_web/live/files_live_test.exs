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
