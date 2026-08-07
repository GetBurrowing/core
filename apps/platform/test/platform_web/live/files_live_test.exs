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
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias Platform.{Files, Repo, Tasks}

  # ── Helpers ────────────────────────────────────────────────────────────

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "files_lv_#{System.unique_integer([:positive])}@example.com",
        name: "Files LV User",
        oidc_sub: "oidc-files-lv-#{System.unique_integer([:positive])}"
      })

    # The sidebar reads `Tasks.list_projects_for_user/2`, so a viewer with no
    # `org_memberships` sees nothing. These tests are about the Files surface,
    # not about scoping. Scoping itself is pinned by the "project scoping"
    # describe block below, with its own single-org viewer.
    member_of_all_orgs!(user)

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

  describe "project scoping" do
    # Asserted on the RENDERED picker, not on the return value of
    # `Tasks.list_projects_for_user/2` — the point is that FilesLive.mount/3
    # actually passes a viewer through. The positive controls are mandatory:
    # a fix that renders an empty picker for everybody would satisfy the
    # absence assertion alone while breaking the feature.
    defp scoped_user!(role, org_id) do
      user =
        Repo.insert!(%User{
          email: "files_scope_#{System.unique_integer([:positive])}@example.com",
          name: "Files Scope User",
          oidc_sub: "oidc-files-scope-#{System.unique_integer([:positive])}"
        })

      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
      |> Repo.insert!()

      user
    end

    defp picker_text(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role=files-project-picker]")
      |> LazyHTML.text()
    end

    test "a plain member does not see a foreign org's project name", %{conn: conn} do
      own = seed_project("fabrikam", "Own Files Project #{System.unique_integer([:positive])}")
      foreign = seed_project("sxi", "Foreign Project #{System.unique_integer([:positive])}")

      user = scoped_user!("member", fabrikam_org_id())
      refute Tenancy.fabrikam_admin?(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, html} = live(conn, ~p"/files")

      picker = picker_text(html)

      assert picker =~ own.name
      refute picker =~ foreign.name
    end

    test "a Fabrikam root admin sees both orgs' projects", %{conn: conn} do
      own = seed_project("fabrikam", "Own Files Project #{System.unique_integer([:positive])}")
      foreign = seed_project("sxi", "Foreign Project #{System.unique_integer([:positive])}")

      admin = scoped_user!("admin", fabrikam_org_id())
      assert Tenancy.fabrikam_admin?(admin) == true

      conn = init_test_session(conn, current_user_id: admin.id)
      {:ok, _view, html} = live(conn, ~p"/files")

      picker = picker_text(html)

      assert picker =~ own.name
      assert picker =~ foreign.name
    end

    # Scoping the project list alone still rendered a header for every active
    # org — a member of two orgs saw five org names, three of them at a `0`
    # count. An empty header naming an org the viewer isn't in is an existence
    # leak on its own, so the org read is scoped too.
    defp files_section_slugs(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role=files-project-group]")
      |> LazyHTML.attribute("data-org-slug")
      |> Enum.uniq()
      |> Enum.sort()
    end

    test "a member of exactly two orgs sees exactly those two sections", %{conn: conn} do
      own = seed_project("fabrikam", "Own Files Project #{System.unique_integer([:positive])}")
      gen = seed_project("soylent", "Soylent Files #{System.unique_integer([:positive])}")
      foreign = seed_project("sxi", "Foreign Project #{System.unique_integer([:positive])}")

      user = scoped_user!("member", fabrikam_org_id())

      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user.id,
        org_id: tenant_org_id("soylent"),
        role: "member"
      })
      |> Repo.insert!()

      refute Tenancy.fabrikam_admin?(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, html} = live(conn, ~p"/files")

      # Positive control — rendering ZERO sections must fail this.
      assert files_section_slugs(html) == ["soylent", "fabrikam"]

      picker = picker_text(html)

      for absent <- ["wayne_tech", "sxi", "paragon"] do
        refute picker =~ Tenancy.scope_label(absent)
      end

      assert picker =~ own.name
      assert picker =~ gen.name
      refute picker =~ foreign.name
    end

    test "a Fabrikam root admin still sees every active org's section", %{conn: conn} do
      admin = scoped_user!("admin", fabrikam_org_id())
      assert Tenancy.fabrikam_admin?(admin) == true

      conn = init_test_session(conn, current_user_id: admin.id)
      {:ok, _view, html} = live(conn, ~p"/files")

      slugs = files_section_slugs(html)

      for expected <- Enum.map(Tenancy.list_active_tenants(), & &1.slug) do
        assert expected in slugs
      end
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

      # The file_delete MCP tool soft-deletes via `Files.delete_file/2`,
      # which broadcasts {:file_deleted, id} on the project topic itself
      # (task 019f7cb0 stage 4) — no separate broadcast call.
      {:ok, _} = Files.delete_file(%{id: Ecto.UUID.generate()}, file)

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

  describe "delete + undo (stage 5)" do
    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Delete Undo Project")
      {:ok, conn: conn, project: project}
    end

    test "Delete button renders enabled in the desktop aside and the mobile drawer",
         %{conn: conn, project: project} do
      file = seed_file(project, %{name: "keeper.txt"})

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      view |> element("tr[data-file-id='#{file.id}']") |> render_click()

      # Extract each button, then assert attributes individually —
      # Phoenix attr order is non-deterministic, never regex across it.
      desktop = view |> element("#files-detail-delete-#{file.id}") |> render()
      assert desktop =~ "hero-trash"
      assert desktop =~ "Delete"
      assert desktop =~ "text-error"
      assert desktop =~ ~s(phx-click="delete_file")
      assert desktop =~ ~s(data-role="files-detail-delete")
      # Enabled: no disabled affordances (semantic state, not styling).
      refute desktop =~ "aria-disabled"
      refute desktop =~ "opacity-50"

      mobile = view |> element("#files-detail-delete-mobile-#{file.id}") |> render()
      assert mobile =~ ~s(data-role="files-detail-delete-mobile")
      assert mobile =~ ~s(phx-click="delete_file")
      # >=44px hit area at btn-sm visual size (design direction, mobile).
      assert mobile =~ "min-h-11"
      refute mobile =~ "aria-disabled"
    end

    test "delete click removes the row, closes the pane, and shows the undo toast",
         %{conn: conn, project: project} do
      file = seed_file(project, %{name: "doomed.txt"})

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      view |> element("tr[data-file-id='#{file.id}']") |> render_click()

      html = view |> element("#files-detail-delete-#{file.id}") |> render_click()

      # Optimistic: row gone + both detail surfaces closed, no dialog.
      refute html =~ "data-file-id=\"#{file.id}\""
      refute html =~ ~s(data-role="files-detail-panel")
      refute html =~ ~s(data-role="files-detail-mobile")

      # The toast IS the confirmation: filename + Undo action.
      assert html =~ ~s(data-role="files-undo-toast")
      assert html =~ "doomed.txt deleted"
      assert html =~ ~s(data-role="files-undo-button")
      assert html =~ ~s(phx-click="undo_delete")

      # Soft-deleted server-side — invisible on every read path.
      assert Files.get_file(file.id) == nil
    end

    test "undo click restores the row and clears the toast",
         %{conn: conn, project: project} do
      file = seed_file(project, %{name: "phoenix.txt"})

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      view |> element("tr[data-file-id='#{file.id}']") |> render_click()
      view |> element("#files-detail-delete-#{file.id}") |> render_click()

      html = view |> element("[data-role='files-undo-button']") |> render_click()

      assert html =~ "data-file-id=\"#{file.id}\""
      refute html =~ ~s(data-role="files-undo-toast")

      # Restored server-side (visible again on the read paths).
      assert %Files.File{} = Files.get_file(file.id)
    end

    test "toast expiry clears the toast without restoring the file",
         %{conn: conn, project: project} do
      file = seed_file(project, %{name: "expired.txt"})

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      view |> element("tr[data-file-id='#{file.id}']") |> render_click()
      view |> element("#files-detail-delete-#{file.id}") |> render_click()

      # Drive the LV-side timer message directly instead of sleeping 8s.
      send(view.pid, {:clear_undo_toast, file.id})
      html = render(view)

      refute html =~ ~s(data-role="files-undo-toast")
      refute html =~ "data-file-id=\"#{file.id}\""
      # Still soft-deleted — expiry never restores.
      assert Files.get_file(file.id) == nil
    end

    test "a consecutive delete replaces the toast and a stale timer can't clear it",
         %{conn: conn, project: project} do
      file_a = seed_file(project, %{name: "first.txt"})
      file_b = seed_file(project, %{name: "second.txt"})

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      view |> element("tr[data-file-id='#{file_a.id}']") |> render_click()
      view |> element("#files-detail-delete-#{file_a.id}") |> render_click()
      view |> element("tr[data-file-id='#{file_b.id}']") |> render_click()
      html = view |> element("#files-detail-delete-#{file_b.id}") |> render_click()

      # One toast at a time — newest delete wins.
      assert html =~ "second.txt deleted"
      refute html =~ "first.txt deleted"

      # A late timer message for the replaced toast (cancel_timer race)
      # must not clear the newer one — the id guard holds it open.
      send(view.pid, {:clear_undo_toast, file_a.id})
      assert render(view) =~ "second.txt deleted"
    end

    test "{:file_restored, id} broadcast from another session reinserts the row",
         %{conn: conn, project: project} do
      file = seed_file(project, %{name: "other-tab.txt"})
      actor = %{id: Ecto.UUID.generate()}

      {:ok, view, html} = live(conn, ~p"/files/#{project.id}")
      assert html =~ "other-tab.txt"

      # Deleted elsewhere (context broadcasts {:file_deleted, id} itself).
      {:ok, deleted} = Files.delete_file(actor, file)
      refute render(view) =~ "other-tab.txt"

      # Restored elsewhere — the LV's new {:file_restored, id} subscriber
      # re-fetches and reinserts without a refresh.
      {:ok, _restored} = Files.restore_file(actor, deleted)
      html_after = render(view)
      assert html_after =~ "other-tab.txt"
      assert html_after =~ "data-file-id=\"#{file.id}\""
    end

    test "undo after the purger removed the row shows a graceful note, never crashes",
         %{conn: conn, project: project} do
      file = seed_file(project, %{name: "purged.txt"})

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      view |> element("tr[data-file-id='#{file.id}']") |> render_click()
      view |> element("#files-detail-delete-#{file.id}") |> render_click()

      # Simulate the 30-day sweeper purging the row mid-undo —
      # restore_file/2 has no window check, so this is the stale path.
      Files.File |> Repo.get(file.id) |> Repo.delete!()

      html = view |> element("[data-role='files-undo-button']") |> render_click()

      assert html =~ "permanently removed"
      refute html =~ "data-file-id=\"#{file.id}\""
      refute html =~ ~s(data-role="files-undo-toast")
      assert Process.alive?(view.pid)
    end
  end

  describe "delete_file_button/1 (component)" do
    # The /files route sits behind RequireAuth, so the unpermitted state
    # is unreachable through the router today — the disabled render path
    # is a defensive rail and is unit-tested at the component boundary.

    test "unpermitted state renders disabled-but-visible with aria-disabled + tooltip" do
      file = %Files.File{id: Ecto.UUID.generate(), name: "locked.txt"}

      html =
        render_component(&PlatformWeb.Components.FileDeleteUI.delete_file_button/1,
          file: file,
          can_delete: false,
          id: "test-delete"
        )

      assert html =~ ~s(aria-disabled="true")
      assert html =~ "opacity-50"
      assert html =~ "Sign in to delete files"
      # Persistent controls: still rendered, never hidden.
      assert html =~ "Delete"
      assert html =~ "hero-trash"
    end

    test "permitted state renders without the disabled affordances" do
      file = %Files.File{id: Ecto.UUID.generate(), name: "open.txt"}

      html =
        render_component(&PlatformWeb.Components.FileDeleteUI.delete_file_button/1,
          file: file,
          can_delete: true,
          id: "test-delete"
        )

      refute html =~ "aria-disabled"
      refute html =~ "opacity-50"
      refute html =~ "title="
      assert html =~ ~s(phx-click="delete_file")
      assert html =~ ~s(phx-value-id="#{file.id}")
    end
  end

  describe "agent-context toggle (stage 4)" do
    # The audience control has to work in BOTH directions and AFTER the
    # upload — a user changing their mind must not re-upload. Every
    # fixture here seeds MORE THAN ONE file per intent so an assertion
    # that happens to match some other row cannot pass by accident.

    defp seed_audience_fixture(project) do
      attempt_a = seed_file(project, %{name: "attempt-a.txt", ingest_intent: "attempt"})
      attempt_b = seed_file(project, %{name: "attempt-b.txt", ingest_intent: "attempt"})

      human_a =
        seed_file(project, %{
          name: "human-a.txt",
          ingest_intent: "human_only",
          ingest_status: "not_attempted"
        })

      human_b =
        seed_file(project, %{
          name: "human-b.txt",
          ingest_intent: "human_only",
          ingest_status: "not_attempted"
        })

      {attempt_a, attempt_b, human_a, human_b}
    end

    defp select_row(view, file_id) do
      view
      |> element(~s([data-role="files-row"][data-file-id="#{file_id}"]))
      |> render_click()
    end

    defp toggle_intent(html) do
      case Regex.run(
             ~r/<button[^>]*data-role="files-detail-agent-toggle"[^>]*>/,
             html
           ) do
        [tag] ->
          [_, intent] = Regex.run(~r/data-ingest-intent="([^"]+)"/, tag)
          intent

        _ ->
          flunk("no desktop agent-context toggle rendered")
      end
    end

    defp row_intent(html, file_id) do
      case Regex.run(
             ~r/<tr[^>]*data-file-id="#{Regex.escape(file_id)}"[^>]*>/,
             html
           ) do
        [tag] ->
          [_, intent] = Regex.run(~r/data-ingest-intent="([^"]+)"/, tag)
          intent

        _ ->
          flunk("no row matched data-file-id=#{file_id}")
      end
    end

    test "toggle reflects the selected file's intent, per selection", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Audience Toggle Project")
      {attempt_a, attempt_b, human_a, human_b} = seed_audience_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      for file <- [attempt_a, attempt_b] do
        html = select_row(view, file.id)
        assert toggle_intent(html) == "attempt"
        assert html =~ "Included for agents"
      end

      for file <- [human_a, human_b] do
        html = select_row(view, file.id)
        assert toggle_intent(html) == "human_only"

        assert has_element?(
                 view,
                 ~s([data-role="files-detail-agent-toggle"][data-ingest-intent="human_only"])
               )
      end
    end

    test "the withdrawing direction confirms, the restoring direction does not", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Audience Confirm Project")
      {attempt_a, _attempt_b, human_a, _human_b} = seed_audience_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      html = select_row(view, attempt_a.id)
      assert html =~ "Removes this file&#39;s extracted text from agent search."

      html = select_row(view, human_a.id)
      refute html =~ "Removes this file"
    end

    test "clicking the toggle flips the row's intent both ways, no reload", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Audience Flip Project")
      {attempt_a, attempt_b, _human_a, _human_b} = seed_audience_fixture(project)

      {:ok, view, html} = live(conn, ~p"/files/#{project.id}")
      assert row_intent(html, attempt_a.id) == "attempt"

      _ = select_row(view, attempt_a.id)

      html =
        view
        |> element(~s([data-role="files-detail-agent-toggle"]))
        |> render_click()

      assert row_intent(html, attempt_a.id) == "human_only"
      assert Files.get_file(attempt_a.id).ingest_intent == "human_only"
      # The sibling in the same starting state must not have moved —
      # the click acts on the selection, not on every attempt row.
      assert row_intent(html, attempt_b.id) == "attempt"

      html =
        view
        |> element(~s([data-role="files-detail-agent-toggle"]))
        |> render_click()

      assert row_intent(html, attempt_a.id) == "attempt"
      assert Files.get_file(attempt_a.id).ingest_intent == "attempt"
    end

    test "a not_attempted file renders People only, not Ingesting", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Audience Badge Project")
      {_attempt_a, _attempt_b, human_a, human_b} = seed_audience_fixture(project)

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      # The page as a whole DOES contain "Ingesting" — the two attempt
      # rows are still pending — so the absence has to be asserted on
      # the specific rows, never on the body.
      for file <- [human_a, human_b] do
        assert_in_row(html, file.id, "People only")
        refute_in_row(html, file.id, "Ingesting")
      end
    end
  end

  describe "upload audience checkbox (stage 4)" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "files-live-audience-test-#{System.unique_integer([:positive])}"
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

    test "unchecking the box uploads the file as human_only", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Upload Audience Off")

      {:ok, view, html} = live(conn, ~p"/files/#{project.id}")

      # Default is CHECKED — assert on the checkbox's own tag, not on the
      # presence of the word "checked" anywhere in the document.
      [checkbox_tag] =
        Regex.run(
          ~r/<input[^>]*data-role="files-upload-include-for-agents"[^>]*>/,
          html
        )

      assert checkbox_tag =~ "checked"

      view
      |> element("#files-upload-form")
      |> render_change(%{"include_for_agents" => "false"})

      upload =
        file_input(view, "#files-upload-form", :files, [
          %{
            name: "held-back.txt",
            content: "plain body #{System.unique_integer([:positive])}",
            type: "text/plain"
          }
        ])

      render_upload(upload, "held-back.txt")

      [file] = Files.list_files_for_project(project.id)
      # text/plain is a SUPPORTED type, so the content-type default would
      # have been "attempt" — the override is what produced this.
      assert Files.default_ingest_intent("text/plain") == "attempt"
      assert file.ingest_intent == "human_only"
      assert file.ingest_status == "not_attempted"
    end

    test "leaving the box checked does not force attempt on an unsupported type", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Upload Audience On")

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      upload =
        file_input(view, "#files-upload-form", :files, [
          %{
            name: "clip.mp4",
            content: "not really a video #{System.unique_integer([:positive])}",
            type: "video/mp4"
          }
        ])

      render_upload(upload, "clip.mp4")

      [file] = Files.list_files_for_project(project.id)
      assert file.ingest_intent == "human_only"
    end

    test "checked box leaves a supported type on the attempt default", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("fabrikam", "Upload Audience Default")

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      upload =
        file_input(view, "#files-upload-form", :files, [
          %{
            name: "notes.txt",
            content: "plain body #{System.unique_integer([:positive])}",
            type: "text/plain"
          }
        ])

      render_upload(upload, "notes.txt")

      [file] = Files.list_files_for_project(project.id)
      assert file.ingest_intent == "attempt"
    end
  end

  # ── Local helpers ──────────────────────────────────────────────────────

  # Row-scoped presence assertion. Sibling of `refute_in_row/3` — a
  # whole-body `=~` would pass on a string another row supplied.
  defp assert_in_row(html, file_id, needle) do
    case Regex.run(
           ~r/<tr[^>]*data-file-id="#{Regex.escape(file_id)}"[^>]*>(.*?)<\/tr>/s,
           html
         ) do
      [_, row_body] ->
        assert row_body =~ needle,
               "expected row #{file_id} to contain #{inspect(needle)}; got: #{row_body}"

      _ ->
        flunk("no row matched data-file-id=#{file_id}")
    end
  end

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
