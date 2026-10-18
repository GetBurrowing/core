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

  defp tenant_or_acme_org_id("acme"), do: acme_org_id()
  defp tenant_or_acme_org_id(slug), do: tenant_org_id(slug)

  defp seed_project(org_slug, name) do
    {:ok, project} =
      Tasks.create_project(%{
        name: name,
        slug: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"),
        org_id: tenant_or_acme_org_id(org_slug)
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

      _acme = seed_project("acme", "Files Mount Acme")
      _gen = seed_project("soylent", "Files Mount Gen")

      {:ok, _view, html} = live(conn, ~p"/files")

      assert html =~ ~s(data-role="files-project-group" data-org-slug="acme")
      assert html =~ ~s(data-role="files-project-group" data-org-slug="soylent")
      assert html =~ "Files Mount Acme"
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
      own = seed_project("acme", "Own Files Project #{System.unique_integer([:positive])}")
      foreign = seed_project("sxi", "Foreign Project #{System.unique_integer([:positive])}")

      user = scoped_user!("member", acme_org_id())
      refute Tenancy.root_admin?(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, html} = live(conn, ~p"/files")

      picker = picker_text(html)

      assert picker =~ own.name
      refute picker =~ foreign.name
    end

    test "an Acme root admin sees both orgs' projects", %{conn: conn} do
      own = seed_project("acme", "Own Files Project #{System.unique_integer([:positive])}")
      foreign = seed_project("sxi", "Foreign Project #{System.unique_integer([:positive])}")

      admin = scoped_user!("admin", acme_org_id())
      assert Tenancy.root_admin?(admin) == true

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
      own = seed_project("acme", "Own Files Project #{System.unique_integer([:positive])}")
      gen = seed_project("soylent", "Soylent Files #{System.unique_integer([:positive])}")
      foreign = seed_project("sxi", "Foreign Project #{System.unique_integer([:positive])}")

      user = scoped_user!("member", acme_org_id())

      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user.id,
        org_id: tenant_org_id("soylent"),
        role: "member"
      })
      |> Repo.insert!()

      refute Tenancy.root_admin?(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, _view, html} = live(conn, ~p"/files")

      # Positive control — rendering ZERO sections must fail this.
      assert files_section_slugs(html) == ["acme", "soylent"]

      picker = picker_text(html)

      for absent <- ["wayne_tech", "sxi", "paragon"] do
        refute picker =~ Tenancy.scope_label(absent)
      end

      assert picker =~ own.name
      assert picker =~ gen.name
      refute picker =~ foreign.name
    end

    test "an Acme root admin still sees every active org's section", %{conn: conn} do
      admin = scoped_user!("admin", acme_org_id())
      assert Tenancy.root_admin?(admin) == true

      conn = init_test_session(conn, current_user_id: admin.id)
      {:ok, _view, html} = live(conn, ~p"/files")

      slugs = files_section_slugs(html)

      for expected <- Enum.map(Tenancy.list_active_tenants_unscoped(), & &1.slug) do
        assert expected in slugs
      end
    end
  end

  describe "select project" do
    test "loading a project URL renders its file list", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Project Alpha")
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
      _project = seed_project("acme", "Project Empty Picker")

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
      project = seed_project("acme", "Project With Files")
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
      project = seed_project("acme", "Project No Files")

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      assert html =~ "No files yet"
      assert html =~ ~s(data-role="files-upload-form")
      assert html =~ ~s(id="files-upload-form")
    end
  end

  describe "PubSub: ingest_status flips on broadcast" do
    test "file_ingested message updates the row's status badge", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Live Refresh Project")
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
      project = seed_project("acme", "Failure Refresh Project")
      file = seed_file(project, %{name: "failing-doc.txt"})

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      {:ok, _} = Files.update_ingest_status(file, "failed")
      :ok = Files.broadcast_project(project.id, {:file_ingest_failed, file.id, :extract_failed})

      html_after = render(view)
      assert html_after =~ "Failed"
    end

    test "file_deleted message drops the row from the LV", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Delete Refresh Project")
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
      _ = seed_project("acme", "FAB Project")

      {:ok, _view, html} = live(conn, ~p"/files")

      assert html =~ ~s(data-role="file-upload-fab")

      assert html =~
               "bottom-[calc(env(safe-area-inset-bottom)+1.5rem+var(--bottom-nav-height,0px))]"
    end

    test "dropzone carries the namespaced marker (not chat's)", %{conn: conn} do
      conn = authenticated_conn(conn)
      _ = seed_project("acme", "Dropzone Project")

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
    # the contract Alex's stage-5 revision pinned down ("you should be
    # able to open and see the ingested file" — not a text excerpt).

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Detail Pane Project")
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
    # returns. Regression here would surface as Robin's original bug:
    # a false "N file(s) failed to upload" toast on happy paths (Bug
    # B), and — on bulk — a crash before any row lands (Bug A). The
    # fix drains per-entry via `consume_uploaded_entry/3` (singular)
    # and pattern-matches the inner tuple shape.

    setup do
      # Point the local-disk storage adapter at an isolated temp root
      # for the duration of the describe.
      root =
        Platform.TestTemp.path("files-live-upload-test")

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
      project = seed_project("acme", "Upload Happy Single")

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
      project = seed_project("acme", "Upload Happy Bulk")

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
      project = seed_project("acme", "Upload Info Flash Single")

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
      project = seed_project("acme", "Upload Info Flash Bulk")

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
      project = seed_project("acme", "Upload Info Flash Mixed")

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
      project = seed_project("acme", "Upload Error Path")

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

  describe "HTML preview + full screen (task 019ff1ab stage 2)" do
    # Every negative here is paired with a positive control in the SAME
    # test: without one, an assertion like "no allow-scripts anywhere"
    # passes for a preview that renders nothing at all.

    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "HTML Preview Project")
      {:ok, conn: conn, project: project}
    end

    defp seed_html_file(project) do
      seed_file(project, %{
        name: "mockup.html",
        original_filename: "mockup.html",
        content_type: "text/html",
        ingest_status: "ingested"
      })
    end

    defp select(view, file),
      do: view |> element("tr[data-file-id='#{file.id}']") |> render_click()

    test "text/html classifies as :html, and text/plain still does not", %{project: _project} do
      assert PlatformWeb.FilesLive.preview_mode(%Files.File{content_type: "text/html"}) == :html
      assert PlatformWeb.FilesLive.preview_mode(%Files.File{content_type: "text/plain"}) == :text
    end

    test "html frame carries a sandbox that grants neither same-origin nor scripts",
         %{conn: conn, project: project} do
      html_file = seed_html_file(project)

      pdf_file =
        seed_file(project, %{
          name: "spec.pdf",
          original_filename: "spec.pdf",
          content_type: "application/pdf",
          ingest_status: "ingested"
        })

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      html = select(view, html_file)

      assert node_count(html, "iframe[data-role='files-detail-html']") == 1
      sandboxes = attribute_values(html, "iframe[data-role='files-detail-html']", "sandbox")

      # The attribute must EXIST (an absent attribute yields [], which
      # would otherwise satisfy every "does not contain" below).
      assert length(sandboxes) == 1
      [sandbox] = sandboxes
      refute sandbox =~ "allow-same-origin"
      refute sandbox =~ "allow-scripts"

      # Declared design width, not 100% — a pane-sized frame fires the
      # mockup's own media queries and shows the mobile layout.
      [style] = attribute_values(html, "iframe[data-role='files-detail-html']", "style")
      assert style =~ "width: #{PlatformWeb.FilesLive.html_preview_width()}px"

      # POSITIVE CONTROL: a non-HTML file still renders its own branch,
      # so the assertions above are not passing on an empty preview.
      pdf_html = select(view, pdf_file)
      assert node_count(pdf_html, "iframe[data-role='files-detail-pdf']") == 1
      assert node_count(pdf_html, "iframe[data-role='files-detail-html']") == 0
    end

    test "scripts-off notice renders with the exact copy and no warning/error colour",
         %{conn: conn, project: project} do
      file = seed_html_file(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      html = select(view, file)

      assert node_count(html, "[data-role='files-detail-html-notice']") == 1

      notice =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role='files-detail-html-notice']")
        |> LazyHTML.text()

      assert notice =~ "Scripts are off in preview."
      assert notice =~ "Download"

      [classes] = attribute_values(html, "[data-role='files-detail-html-notice']", "class")
      refute classes =~ "warning"
      refute classes =~ "error"
      # Positive control on the same attribute: the strip IS styled, so
      # the two refutes are not reading an empty class list.
      assert classes =~ "border-edge"
    end

    test "full-screen overlay opens, does NOT take the reserved z-50, and Escape-closes",
         %{conn: conn, project: project} do
      file = seed_html_file(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      before_open = select(view, file)
      assert node_count(before_open, "[data-role='files-preview-fullscreen']") == 0

      opened =
        view
        |> element("[data-role='files-detail-fullscreen-open']")
        |> render_click()

      assert node_count(opened, "[data-role='files-preview-fullscreen']") == 1

      [overlay_class] =
        attribute_values(opened, "[data-role='files-preview-fullscreen']", "class")

      # z-50 belongs to the per-canvas review overlay. Two surfaces at the
      # same level only misbehave when both are open — the state nobody
      # screenshots — so the reservation is asserted here instead.
      refute overlay_class =~ "z-50"
      assert overlay_class =~ "z-[45]"

      # The overlay renders the preview body itself, not a placeholder.
      assert node_count(opened, "iframe[data-role='files-fullscreen-html']") == 1

      closed = render_keydown(view, "close_preview_fullscreen", %{"key" => "Escape"})
      assert node_count(closed, "[data-role='files-preview-fullscreen']") == 0
    end

    test "full-screen control is on every previewable type and absent on :unknown",
         %{conn: conn, project: project} do
      html_file = seed_html_file(project)

      image_file =
        seed_file(project, %{
          name: "shot.png",
          original_filename: "shot.png",
          content_type: "image/png",
          ingest_status: "ingested"
        })

      unknown_file =
        seed_file(project, %{
          name: "blob.bin",
          original_filename: "blob.bin",
          content_type: "application/octet-stream",
          ingest_status: "ingested"
        })

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      for file <- [html_file, image_file] do
        html = select(view, file)

        assert node_count(html, "[data-role='files-detail-fullscreen-open']") == 1,
               "expected a full-screen control for #{file.content_type}"
      end

      unknown_html = select(view, unknown_file)
      # Presence and absence live in the same test so a selector rename
      # breaks both rather than silently passing one.
      assert node_count(unknown_html, "[data-role='files-detail-unknown']") == 1
      assert node_count(unknown_html, "[data-role='files-detail-fullscreen-open']") == 0
    end
  end

  describe "interactive prototype flag + attribution bar (task 01a06a20 stage 3)" do
    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Interactive Prototype Project")
      {:ok, conn: conn, project: project}
    end

    test "unflagged HTML file renders the ORIGINAL notice + bare sandbox, unchanged",
         %{conn: conn, project: project} do
      file = seed_html_file(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      html = select(view, file)

      assert node_count(html, "[data-role='files-detail-html-interactive']") == 0
      assert node_count(html, "[data-role='files-detail-html-attribution-bar']") == 0

      [sandbox] = attribute_values(html, "iframe[data-role='files-detail-html']", "sandbox")
      refute sandbox =~ "allow-scripts"

      notice =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role='files-detail-html-notice']")
        |> LazyHTML.text()

      assert notice =~ "Scripts are off in preview."
    end

    test "flagging a file grants allow-scripts, renders the bar, and changes the notice",
         %{conn: conn, project: project} do
      file = seed_html_file(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      select(view, file)

      html =
        view
        |> element("[data-role='files-detail-interactive-on']")
        |> render_click()

      assert node_count(html, "[data-role='files-detail-html-interactive']") == 1
      assert node_count(html, "[data-role='files-detail-html-attribution-bar']") == 1
      assert node_count(html, "[data-role='files-detail-html-live-pill']") == 1

      [sandbox] = attribute_values(html, "iframe[data-role='files-detail-html']", "sandbox")
      assert sandbox =~ "allow-scripts"
      refute sandbox =~ "allow-same-origin"

      filename_text =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role='files-detail-html-filename']")
        |> LazyHTML.text()

      assert filename_text =~ "mockup.html"

      attribution_text =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role='files-detail-html-attribution']")
        |> LazyHTML.text()

      # authenticated_conn/1 always names its user "Files LV User". Flagged
      # via a live click a moment ago, so the recency framing reads "just
      # now" rather than an absolute date.
      assert attribution_text =~ "Made interactive by Files LV User"
      assert attribution_text =~ "just now"

      notice =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role='files-detail-html-notice']")
        |> LazyHTML.text()

      assert notice =~ "Interactive prototype. Never enter a password here."

      # The DB actually flipped, actor attributed — not just a UI flag.
      updated = Files.get_file(file.id)
      assert %DateTime{} = updated.interactive_at
      assert is_binary(updated.interactive_by_user_id)
    end

    test "no warning/error colour token appears anywhere on the flagged surface",
         %{conn: conn, project: project} do
      file = seed_html_file(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      select(view, file)

      html =
        view
        |> element("[data-role='files-detail-interactive-on']")
        |> render_click()

      [bar_class] =
        attribute_values(html, "[data-role='files-detail-html-attribution-bar']", "class")

      refute bar_class =~ "warning"
      refute bar_class =~ "error"

      [notice_class] = attribute_values(html, "[data-role='files-detail-html-notice']", "class")
      refute notice_class =~ "warning"
      refute notice_class =~ "error"
    end

    test "unflagging reverts to the bare sandbox and the original notice",
         %{conn: conn, project: project} do
      file = seed_html_file(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      select(view, file)
      view |> element("[data-role='files-detail-interactive-on']") |> render_click()

      html =
        view
        |> element("[data-role='files-detail-interactive-off']")
        |> render_click()

      assert node_count(html, "[data-role='files-detail-html-interactive']") == 0

      [sandbox] = attribute_values(html, "iframe[data-role='files-detail-html']", "sandbox")
      refute sandbox =~ "allow-scripts"

      updated = Files.get_file(file.id)
      assert updated.interactive_at == nil
      assert updated.interactive_by_user_id == nil
    end

    test "the flag control renders only for :html mode files", %{conn: conn, project: project} do
      pdf_file =
        seed_file(project, %{
          name: "spec.pdf",
          original_filename: "spec.pdf",
          content_type: "application/pdf",
          ingest_status: "ingested"
        })

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      html = select(view, pdf_file)

      assert node_count(html, "[data-role='files-detail-interactive-toggle']") == 0
    end

    test "the corner full-screen icon is suppressed on a flagged file — the bar's action replaces it",
         %{conn: conn, project: project} do
      file = seed_html_file(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      select(view, file)

      html =
        view
        |> element("[data-role='files-detail-interactive-on']")
        |> render_click()

      assert node_count(html, "[data-role='files-detail-fullscreen-open']") == 0
      assert node_count(html, "[data-role='files-detail-html-full-window']") == 1
    end

    test "unflagged html keeps the corner full-screen icon (only the flagged path replaces it)",
         %{conn: conn, project: project} do
      file = seed_html_file(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      html = select(view, file)

      assert node_count(html, "[data-role='files-detail-fullscreen-open']") == 1
    end

    test "the flagged frame carries the auto-scale hook with the declared width/height",
         %{conn: conn, project: project} do
      file = seed_html_file(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      select(view, file)

      html =
        view
        |> element("[data-role='files-detail-interactive-on']")
        |> render_click()

      assert node_count(html, "[data-role='files-detail-html-scale']") == 1

      [declared_width] =
        attribute_values(html, "[data-role='files-detail-html-scale']", "data-declared-width")

      [declared_height] =
        attribute_values(html, "[data-role='files-detail-html-scale']", "data-declared-height")

      assert declared_width == to_string(PlatformWeb.FilesLive.html_preview_width())
      assert declared_height == to_string(PlatformWeb.FilesLive.html_preview_height())
    end

    test "clicking the already-active side of the control is a silent no-op",
         %{conn: conn, project: project} do
      file = seed_html_file(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")
      select(view, file)

      # Already off — clicking "Scripts are off" again must not error and
      # must not touch the DB row.
      html =
        view
        |> element("[data-role='files-detail-interactive-off']")
        |> render_click()

      assert node_count(html, "[data-role='files-detail-html-interactive']") == 0
      assert Files.get_file(file.id).interactive_at == nil
      assert Process.alive?(view.pid)
    end
  end

  describe "interactive_attribution_text/1 + interactive_uploader_name/1" do
    defp insert_user(name) do
      Repo.insert!(%User{
        email: "interactive-attr-#{System.unique_integer([:positive])}@example.com",
        name: name,
        oidc_sub: "oidc-interactive-attr-#{System.unique_integer([:positive])}"
      })
    end

    test "nil when the file has never been flagged" do
      file = %Files.File{interactive_at: nil, interactive_by_user_id: nil}
      assert PlatformWeb.FilesLive.interactive_attribution_text(file) == nil
    end

    test "degrades to a date-only string when the flagging user is gone" do
      file = %Files.File{
        interactive_at: ~U[2026-08-15 12:00:00.000000Z],
        interactive_by_user_id: nil
      }

      assert PlatformWeb.FilesLive.interactive_attribution_text(file) ==
               "Made interactive 15 Aug"

      assert PlatformWeb.FilesLive.interactive_uploader_name(file) == nil
    end

    test "names the actor who flipped the flag, absolute date once it's old" do
      user = insert_user("Robin Park")

      file = %Files.File{
        interactive_at: ~U[2026-08-15 12:00:00.000000Z],
        interactive_by_user_id: user.id
      }

      assert PlatformWeb.FilesLive.interactive_attribution_text(file) ==
               "Made interactive by Robin Park · 15 Aug"

      assert PlatformWeb.FilesLive.interactive_uploader_name(file) == "Robin Park"
    end

    test "a file flagged seconds ago reads \"just now\"" do
      user = insert_user("Priya Nair")

      file = %Files.File{
        interactive_at: DateTime.add(DateTime.utc_now(), -5, :second),
        interactive_by_user_id: user.id
      }

      assert PlatformWeb.FilesLive.interactive_attribution_text(file) ==
               "Made interactive by Priya Nair · just now"
    end

    test "recency framing across the minute, hour, and yesterday boundaries" do
      user = insert_user("Priya Nair")
      now = DateTime.utc_now()

      build = fn seconds_ago ->
        %Files.File{
          interactive_at: DateTime.add(now, -seconds_ago, :second),
          interactive_by_user_id: user.id
        }
      end

      assert PlatformWeb.FilesLive.interactive_attribution_text(build.(60)) ==
               "Made interactive by Priya Nair · 1 minute ago"

      assert PlatformWeb.FilesLive.interactive_attribution_text(build.(5 * 60)) ==
               "Made interactive by Priya Nair · 5 minutes ago"

      assert PlatformWeb.FilesLive.interactive_attribution_text(build.(3600)) ==
               "Made interactive by Priya Nair · 1 hour ago"

      assert PlatformWeb.FilesLive.interactive_attribution_text(build.(3 * 3600)) ==
               "Made interactive by Priya Nair · 3 hours ago"

      assert PlatformWeb.FilesLive.interactive_attribution_text(build.(30 * 3600)) ==
               "Made interactive by Priya Nair · yesterday"
    end

    test "older than two days falls back to the absolute date, not a relative phrase" do
      user = insert_user("Priya Nair")

      file = %Files.File{
        interactive_at: DateTime.add(DateTime.utc_now(), -5 * 86_400, :second),
        interactive_by_user_id: user.id
      }

      text = PlatformWeb.FilesLive.interactive_attribution_text(file)
      refute text =~ "ago"
      refute text =~ "yesterday"
      assert text =~ "Priya Nair"
    end

    test "REGRESSION: names the user who flagged the file, not the original uploader" do
      uploader = insert_user("Alice Uploader")
      flagger = insert_user("Bob Flagger")

      # Same file, two different people: A uploaded it, B is the one who
      # later flipped it interactive. The bar's entire job is to say who
      # made this run — so it must name B, never A. A test that reused one
      # user for both roles could not fail if this regressed.
      file = %Files.File{
        uploaded_by_user_id: uploader.id,
        interactive_at: ~U[2026-08-15 12:00:00.000000Z],
        interactive_by_user_id: flagger.id
      }

      text = PlatformWeb.FilesLive.interactive_attribution_text(file)

      assert text =~ "Bob Flagger"
      refute text =~ "Alice Uploader"
    end
  end

  describe "html_preview_height/1" do
    test "returns a fixed declared pixel height, paired with html_preview_width/0" do
      assert PlatformWeb.FilesLive.html_preview_height() == 800
      assert is_integer(PlatformWeb.FilesLive.html_preview_width())
    end
  end

  describe "filtered_and_sorted helper" do
    test "filter narrows by case-insensitive substring", %{conn: _conn} do
      project = seed_project("acme", "Filter Helper Project")
      a = seed_file(project, %{name: "Alpha.txt"})
      b = seed_file(project, %{name: "Beta.txt"})

      result = PlatformWeb.FilesLive.filtered_and_sorted([a, b], "alpha", "date_desc")
      assert result == [a]
    end

    test "name_asc sorts alphabetically case-insensitively", %{conn: _conn} do
      project = seed_project("acme", "Sort Helper Project")
      a = seed_file(project, %{name: "zeta.txt"})
      b = seed_file(project, %{name: "Alpha.txt"})

      result = PlatformWeb.FilesLive.filtered_and_sorted([a, b], "", "name_asc")
      assert result == [b, a]
    end
  end

  describe "delete + undo (stage 5)" do
    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Delete Undo Project")
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
      project = seed_project("acme", "Audience Toggle Project")
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
      project = seed_project("acme", "Audience Confirm Project")
      {attempt_a, _attempt_b, human_a, _human_b} = seed_audience_fixture(project)

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      html = select_row(view, attempt_a.id)
      assert html =~ "Removes this file&#39;s extracted text from agent search."

      html = select_row(view, human_a.id)
      refute html =~ "Removes this file"
    end

    test "clicking the toggle flips the row's intent both ways, no reload", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Audience Flip Project")
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
      project = seed_project("acme", "Audience Badge Project")
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
        Platform.TestTemp.path("files-live-audience-test")

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
      project = seed_project("acme", "Upload Audience Off")

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
      project = seed_project("acme", "Upload Audience On")

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
      project = seed_project("acme", "Upload Audience Default")

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

  describe "failed-ingest summary line (task 01a0008b stage 4)" do
    test "renders with the project-wide count when files failed", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Summary Count Project")

      seed_failed_file(project, %{name: "broken-one.txt"}, 1)
      seed_failed_file(project, %{name: "broken-two.txt"}, 1)
      seed_file(project, %{name: "fine.txt", ingest_status: "ingested"})

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      assert html =~ ~s(data-role="files-failed-summary")
      assert summary_attr(html, "data-failed-count") == "2"
      assert html =~ ~s(data-role="files-retry-all")
    end

    # The absence IS the design decision, so this asserts the element is
    # gone from the DOM — not that it rendered with a zero or an empty
    # string. A summary that renders when everything is fine trains
    # people to stop reading it.
    test "does not render AT ALL for a project with no failed ingests", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Summary Clean Project")

      seed_file(project, %{name: "fine-one.txt", ingest_status: "ingested"})
      seed_file(project, %{name: "fine-two.txt", ingest_status: "ingested"})

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      refute html =~ ~s(data-role="files-failed-summary")
      refute html =~ ~s(data-role="files-retry-all")
      # And no all-clear surface took its place. (The apostrophe in the
      # real copy is HTML-escaped, so match the escape-free tail.)
      refute html =~ "be read by agents"
      # The table still starts at the top exactly as before.
      assert html =~ ~s(data-role="files-table")
    end

    # A `human_only` / `not_attempted` file was never attempted and never
    # broke. Reporting it as a failure would surface every deliberate
    # exclusion as something to repair, which is the same noise problem
    # this line exists to remove.
    test "a human_only / not_attempted file produces NO summary line", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Summary Human Only Project")

      seed_file(project, %{name: "readable.txt", ingest_status: "ingested"})

      withheld =
        seed_file(project, %{
          name: "people-only.txt",
          ingest_intent: "human_only",
          ingest_status: "not_attempted"
        })

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      refute html =~ ~s(data-role="files-failed-summary")
      refute html =~ ~s(data-role="files-retry-all")

      # The row itself is untouched — still listed, still badged.
      assert_in_row(html, withheld.id, "People only")
    end

    test "a file at the repeat-failure threshold re-diagnoses and withdraws the action",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Summary Exhausted Project")

      threshold = Files.repeat_failure_threshold()
      exhausted = seed_failed_file(project, %{name: "corrupt.pdf"}, threshold)
      assert Files.get_file(exhausted.id).ingest_failure_count == threshold

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      # Still present, still counted, still the same colour slot.
      assert html =~ ~s(data-role="files-failed-summary")
      assert summary_attr(html, "data-failed-count") == "1"

      element = summary_html(html)
      assert element =~ "text-error"

      # The sentence changed...
      assert element =~ "likely needs re-exporting"
      refute element =~ "be read by agents"

      # ...and the button did not come back, in the line or the panel.
      refute html =~ ~s(data-role="files-retry-all")
      refute html =~ ~s(data-role="files-detail-retry")

      # Nothing got louder: it did not borrow the in-flight warning slot,
      # and it is not an alert component.
      refute element =~ "warning"
      refute element =~ ~s(role="alert")
    end

    test "both populations: retry-all stays, and the note accounts for the withheld ones",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Summary Mixed Project")

      threshold = Files.repeat_failure_threshold()
      seed_failed_file(project, %{name: "fresh.txt"}, 1)
      seed_failed_file(project, %{name: "corrupt.pdf"}, threshold)

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      assert summary_attr(html, "data-failed-count") == "2"
      # The action survives for the one that is still worth trying...
      assert html =~ ~s(data-role="files-retry-all")
      assert summary_attr(html, "data-retryable-count") == "1"
      # ...and the sentence does not pretend it will fix the other.
      assert html =~ "1 of them has failed #{threshold} times"
    end

    # The note about the withheld files is copy, and the copy is the
    # behaviour here: a reader who is told a file was held back and is
    # NOT told what they can still do concludes the door is shut. The
    # manual retry is unbounded by design (see the retry-past-threshold
    # tests below), so a note implying otherwise contradicts the control
    # that ships beside it.
    test "the withheld note names the AUTOMATIC path and points at the per-file retry",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Summary Withheld Copy Project")

      threshold = Files.repeat_failure_threshold()
      seed_failed_file(project, %{name: "fresh.txt"}, 1)
      seed_failed_file(project, %{name: "corrupt.pdf"}, threshold)

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      note = summary_html(html)

      # Both populations really are present, or the clause under test
      # does not render at all and every assertion below is vacuous.
      assert summary_attr(html, "data-failed-count") == "2"
      assert summary_attr(html, "data-retryable-count") == "1"

      # 1. The reason is the AUTOMATIC sweep declining, said in that word.
      assert note =~ "automatically",
             "withheld note must name the automatic path explicitly: #{note}"

      # 2. It points at an action the reader can take. The retry lives in
      #    the detail pane, reached by opening the file — there is no
      #    per-row button to send them looking for.
      assert note =~ "open",
             "withheld note must point at the per-file retry: #{note}"

      assert note =~ "try again",
             "withheld note must name the retry action: #{note}"

      # 3. Re-exporting is a suggestion, NOT a replacement for retrying.
      #    "instead" frames it as the alternative to a retry and so reads
      #    as "you cannot retry this one" — the inversion this task
      #    exists to remove, and the defect the reviewer caught here.
      refute note =~ "instead",
             "withheld note must not frame re-exporting as replacing retry: #{note}"

      # 4. The count tracks the shared threshold. A literal 3 here would
      #    stay green while a threshold change silently made the copy
      #    lie about how many attempts were spent.
      assert note =~ "failed #{Files.repeat_failure_threshold()} times"
    end

    # Deterministic by construction rather than by waiting: the retry
    # flips both rows out of "failed" INSIDE the click handler, so the
    # count is zero the moment the handler returns, whatever the spawned
    # ingest task is doing. The telemetry sync point below then pins that
    # the retry genuinely completed rather than merely being asked for —
    # no sleep, no poll loop.
    test "retry-all flips the failed rows and the summary disappears", %{conn: conn} do
      conn = authenticated_conn(conn)
      root = attachments_root()
      project = seed_project("acme", "Summary Retry Project")

      one = seed_readable_failed_file(project, root, "first recoverable body", "one.txt")
      two = seed_readable_failed_file(project, root, "second recoverable body", "two.txt")

      attach_ingest_telemetry([[:platform, :files, :ingested, :stop]])

      {:ok, view, html} = live(conn, ~p"/files/#{project.id}")
      assert summary_attr(html, "data-failed-count") == "2"

      html_after =
        view
        |> element(~s([data-role="files-retry-all"]))
        |> render_click()

      # Gone from the DOM entirely, not lingering with a stale number.
      refute html_after =~ ~s(data-role="files-failed-summary")

      # Both rows left "failed" through the single retry entry point.
      refute Files.get_file(one.id).ingest_status == "failed"
      refute Files.get_file(two.id).ingest_status == "failed"

      # Sync on the pipeline resolving, then pin the end state.
      assert_receive {:ingest_telemetry, [:platform, :files, :ingested, :stop], _, %{file_id: a}},
                     2_000

      assert_receive {:ingest_telemetry, [:platform, :files, :ingested, :stop], _, %{file_id: b}},
                     2_000

      assert Enum.sort([a, b]) == Enum.sort([one.id, two.id])

      assert Files.get_file(one.id).ingest_status == "ingested"
      assert Files.get_file(two.id).ingest_status == "ingested"
      assert Files.count_failed_ingests(project.id) == 0

      # Still absent after the PubSub round-trip — the count was
      # recomputed, not merely cleared once.
      refute render(view) =~ ~s(data-role="files-failed-summary")
    end

    test "the summary is recomputed when a single row fails over PubSub", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Summary Recompute Project")
      file = seed_file(project, %{name: "will-break.txt"})

      {:ok, view, html} = live(conn, ~p"/files/#{project.id}")
      refute html =~ ~s(data-role="files-failed-summary")

      {:ok, _} = Files.update_ingest_status(file, "failed")
      :ok = Files.broadcast_project(project.id, {:file_ingest_failed, file.id, :extract_failed})

      html_after = render(view)

      assert html_after =~ ~s(data-role="files-failed-summary")
      assert summary_attr(html_after, "data-failed-count") == "1"
    end
  end

  describe "detail-panel retry (task 01a0008b stage 4)" do
    test "appears for a failed file and drives request_ingest/2", %{conn: conn} do
      conn = authenticated_conn(conn)
      root = attachments_root()
      project = seed_project("acme", "Detail Retry Project")

      file = seed_readable_failed_file(project, root, "detail panel body", "detail.txt")

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      html =
        view
        |> element(~s([data-role="files-row"][data-file-id="#{file.id}"]))
        |> render_click()

      assert html =~ ~s(data-role="files-detail-retry")

      view
      |> element(~s([data-role="files-detail-retry"]))
      |> render_click()

      refute Files.get_file(file.id).ingest_status == "failed"
    end

    test "does not appear for an ingested file", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Detail No Retry Project")
      file = seed_file(project, %{name: "healthy.txt", ingest_status: "ingested"})

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      html =
        view
        |> element(~s([data-role="files-row"][data-file-id="#{file.id}"]))
        |> render_click()

      # The panel is open (the agent toggle proves it) and the retry is
      # simply not offered.
      assert html =~ ~s(data-role="files-detail-agent-toggle")
      refute html =~ ~s(data-role="files-detail-retry")
    end

    # Task 01a0166d: the manual retry is UNBOUNDED. Asserting the button
    # renders would prove nothing about the click, so this drives the
    # control from far past the sweep's threshold and asserts the retry
    # ACTUALLY HAPPENED — twice, so an off-by-one bound hiding at 4
    # cannot pass.
    test "is honoured far past the sweep threshold, twice over", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Detail Unbounded Project")

      # No bytes on disk, so every attempt fails deterministically and we
      # can sync on the failure rather than sleeping.
      file = seed_failed_file(project, %{name: "unbounded.pdf"}, 1)
      file = force_failure_count(file, 5)
      assert Files.get_file(file.id).ingest_failure_count == 5
      assert Files.get_file(file.id).ingest_failure_count > Files.repeat_failure_threshold()

      attach_ingest_telemetry([[:platform, :files, :ingested, :exception]])

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      html =
        view
        |> element(~s([data-role="files-row"][data-file-id="#{file.id}"]))
        |> render_click()

      assert html =~ ~s(data-role="files-detail-retry")

      # FIRST click, from count 5.
      after_first =
        view
        |> element(~s([data-role="files-detail-retry"]))
        |> render_click()

      assert_in_row(after_first, file.id, "Ingesting…")

      assert_receive {:ingest_telemetry, [:platform, :files, :ingested, :exception], _,
                      %{file_id: first_id}},
                     2_000

      assert first_id == file.id
      assert Files.get_file(file.id).ingest_status == "failed"
      assert Files.get_file(file.id).ingest_failure_count == 6

      # SECOND click, from the state the first one produced.
      after_second =
        view
        |> element(~s([data-role="files-detail-retry"]))
        |> render_click()

      assert_in_row(after_second, file.id, "Ingesting…")

      assert_receive {:ingest_telemetry, [:platform, :files, :ingested, :exception], _,
                      %{file_id: second_id}},
                     2_000

      assert second_id == file.id
      assert Files.get_file(file.id).ingest_failure_count == 7
    end

    # The server-side re-check is the real gate: a replayed click arrives
    # with no button on the page at all.
    test "a replayed retry_file event at count 5 is honoured", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Replayed Retry Project")

      file = seed_failed_file(project, %{name: "replayed.pdf"}, 1)
      file = force_failure_count(file, 5)

      attach_ingest_telemetry([[:platform, :files, :ingested, :exception]])

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      # No selection, so no retry control has ever been rendered.
      refute render(view) =~ ~s(data-role="files-detail-retry")

      html = render_click(view, "retry_file", %{"id" => file.id})

      assert_in_row(html, file.id, "Ingesting…")

      # Sync on the spawned pipeline so it does not outlive the test's DB
      # ownership, and pin that the attempt really reached the extractor.
      assert_receive {:ingest_telemetry, [:platform, :files, :ingested, :exception], _,
                      %{file_id: id}},
                     2_000

      assert id == file.id
      assert Files.get_file(file.id).ingest_failure_count == 6
    end

    # ...but the status gate the re-check still enforces has NOT gone
    # away: a human_only row was withheld by a person, not by a bound.
    test "a replayed retry_file event on a human_only row is still refused", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Replayed Human Only Project")

      file =
        seed_file(project, %{
          name: "people-only.txt",
          ingest_intent: "human_only",
          ingest_status: "not_attempted"
        })

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      html = render_click(view, "retry_file", %{"id" => file.id})

      assert_in_row(html, file.id, "People only")
      assert Files.get_file(file.id).ingest_status == "not_attempted"
    end
  end

  describe "failure reason strip on the list row (task 01a0166d stage 4)" do
    # Two forms of the same marker, and the distinction matters: the
    # `_selector` is a CSS selector for `element/2`, the `_marker` is the
    # literal attribute text for a substring assertion over the rendered
    # HTML. They are not interchangeable.
    @strip_selector ~s([data-role="files-row-failure-reason"])
    @strip_marker ~s(data-role="files-row-failure-reason")
    @skip_marker ~s(data-role="files-row-sweep-skipped")

    # Invented detail strings throughout: `core` is a public repository,
    # so no real hostname, URL, container or node id may appear in a
    # fixture or a screenshot.
    test "renders the stage prefix AND the verbatim detail in the list, without selecting the file",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Strip Embed Project")

      seed_failed_file_with_reason(
        project,
        %{name: "brief.md"},
        :embed,
        "connect timed out after 5000ms",
        1
      )

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      assert html =~ @strip_marker

      # The human half. Without it the column is worthless: eight rows
      # reading "connect timed out" and one reading "unsupported
      # encoding" is the whole value of the strip, and it is invisible
      # unless the stage is named.
      assert html =~ "Embedding:"

      # The machine half, verbatim — this is the string a reader pastes
      # to an engineer, so it must not be reworded or summarised.
      assert html =~ "connect timed out after 5000ms"

      # ...and all of that on MOUNT, with no click. The detail pane's
      # marker is absent, which is what proves no file got selected.
      refute html =~ ~s(data-role="files-detail-retry")
    end

    test "a healthy or in-flight row renders no strip at all", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Strip Absent Project")

      seed_file(project, %{name: "ready.txt", ingest_status: "ingested"})
      seed_file(project, %{name: "working.txt", ingest_status: "pending"})

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      assert html =~ "ready.txt"
      assert html =~ "working.txt"

      # Asserted on the `data-role`, NOT on the absence of the reason
      # prose. A substring refute over HTML is position-dependent and a
      # longer value defeats it; the marker is the only thing that
      # actually says "no strip was rendered".
      refute html =~ @strip_marker
    end

    test "a legacy row with no recorded reason still says something", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Strip Legacy Project")

      # No opts — exactly the shape of the rows that failed before the
      # reason columns existed.
      seed_failed_file(project, %{name: "legacy.txt"}, 1)

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      assert html =~ @strip_marker
      assert html =~ "Reason not recorded"

      # A blank strip on a failed row would re-create the exact defect
      # this task exists to remove, so the generic prefix renders too.
      assert html =~ "Ingest:"
    end

    test "below the threshold the row carries NO sweep-skipped clause", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Strip Under Threshold")

      under = Files.repeat_failure_threshold() - 1

      file =
        seed_failed_file_with_reason(
          project,
          %{name: "twice.txt"},
          :embed,
          "connect timed out after 5000ms",
          under
        )

      assert file.ingest_failure_count == under

      {:ok, _view, html} = live(conn, ~p"/files/#{project.id}")

      assert html =~ @strip_marker
      refute html =~ @skip_marker
    end

    test "at the threshold the row says it was not retried AUTOMATICALLY", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Strip At Threshold")

      threshold = Files.repeat_failure_threshold()

      file =
        seed_failed_file_with_reason(
          project,
          %{name: "thrice.txt"},
          :embed,
          "connect timed out after 5000ms",
          threshold
        )

      assert file.ingest_failure_count == threshold

      {:ok, view, html} = live(conn, ~p"/files/#{project.id}")

      assert html =~ @skip_marker

      strip = view |> element(@strip_selector) |> render()

      # Appended to the reason, never replacing it: the reader needs both
      # halves — what broke, and why nothing has happened since.
      assert strip =~ "Embedding:"
      assert strip =~ "connect timed out after 5000ms"

      # The copy is the load-bearing part. The manual retry beside this
      # text is unbounded, so a bare "not retried" would read as "you
      # cannot retry" — the precise inversion of this task's instruction.
      # The word that carries the distinction is "automatically".
      assert strip =~ "automatically"

      # Tracks the shared threshold rather than pinning a literal 3, so
      # changing the bound cannot leave the copy quietly lying.
      assert strip =~ "after #{Files.repeat_failure_threshold()} attempts"
    end

    test "a legacy row can also carry the sweep-skipped clause; they compose", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Strip Legacy Skipped")

      seed_failed_file(project, %{name: "old-and-stuck.txt"}, Files.repeat_failure_threshold())

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      strip = view |> element(@strip_selector) |> render()

      assert strip =~ "Reason not recorded"
      assert strip =~ "automatically"
    end

    test "the strip emits no title attribute — it is text, never a tooltip", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Strip No Tooltip")

      seed_failed_file_with_reason(
        project,
        %{name: "no-hover.txt"},
        :extract,
        "unsupported encoding in page 4",
        Files.repeat_failure_threshold()
      )

      {:ok, view, _html} = live(conn, ~p"/files/#{project.id}")

      strip = view |> element(@strip_selector) |> render()

      assert strip =~ "Extraction:"

      # A hover affordance is invisible on touch and unreachable by
      # keyboard, and this string is the entire point of the ticket. It
      # renders as text or it does not exist.
      refute strip =~ "title="
    end

    test "the strip disappears on a later success without a page reload", %{conn: conn} do
      conn = authenticated_conn(conn)
      project = seed_project("acme", "Strip Clears Project")

      file =
        seed_failed_file_with_reason(
          project,
          %{name: "recovers.txt"},
          :embed,
          "connect timed out after 5000ms",
          1
        )

      {:ok, view, html} = live(conn, ~p"/files/#{project.id}")

      assert html =~ @strip_marker
      assert html =~ "connect timed out after 5000ms"

      # The context clears BOTH reason columns on an "ingested" write, so
      # this is the real end-to-end path, not a hand-cleared row.
      {:ok, ingested} = Files.update_ingest_status(file, "ingested")
      assert is_nil(ingested.ingest_failure_stage)
      assert is_nil(ingested.ingest_failure_detail)

      :ok = Files.broadcast_project(project.id, {:file_ingested, file.id})

      # Same LiveView process, no re-mount, no `live/2` call: this only
      # passes if the PubSub handler re-fetches the WHOLE row rather than
      # patching the status field, which is what would leave a stale
      # reason strip on a now-healthy file.
      html_after = render(view)

      assert html_after =~ "Ready"
      refute html_after =~ @strip_marker
    end
  end

  # ── Local helpers ──────────────────────────────────────────────────────

  # As `seed_failed_file/3`, but recording a reason on every attempt —
  # the shape the ingester's `mark_failed/2` writes. `failures` drives
  # the count through the real seam, so the sweep-skipped condition is
  # reached the way production reaches it.
  defp seed_failed_file_with_reason(project, attrs, stage, detail, failures) do
    file = seed_file(project, attrs)

    Enum.reduce(1..failures, file, fn _n, acc ->
      {:ok, updated} =
        Files.update_ingest_status(acc, "failed", failure_stage: stage, failure_detail: detail)

      updated
    end)
  end

  # Drive the failure count through the real seam
  # (`update_ingest_status/2` increments it) rather than writing the
  # column directly — it is outside `@cast_fields` precisely so nothing
  # but that function can move it.
  defp seed_failed_file(project, attrs, failures) do
    file = seed_file(project, attrs)

    Enum.reduce(1..failures, file, fn _n, acc ->
      {:ok, updated} = Files.update_ingest_status(acc, "failed")
      updated
    end)
  end

  # `:ingest_failure_count` is outside `@cast_fields` on purpose, so a
  # count this far past the threshold can only be written directly.
  defp force_failure_count(file, count) do
    file
    |> Ecto.Changeset.change(%{ingest_failure_count: count})
    |> Platform.Repo.update!()

    Files.get_file(file.id)
  end

  # A failed file whose bytes are genuinely on disk, so a retry can
  # actually succeed instead of breaking again.
  defp seed_readable_failed_file(project, root, body, filename) do
    storage_key = "files/#{project.id}/#{Ecto.UUID.generate()}/#{filename}"
    abs_path = Path.join(root, storage_key)
    File.mkdir_p!(Path.dirname(abs_path))
    File.write!(abs_path, body)

    seed_failed_file(
      project,
      %{
        name: filename,
        original_filename: filename,
        content_type: "text/plain",
        byte_size: byte_size(body),
        storage_key: storage_key
      },
      1
    )
  end

  # Point the local-disk attachment adapter at a per-test tmp dir so the
  # extractor's path resolution works. Mirrors the ingester test's setup.
  defp attachments_root do
    root =
      Platform.TestTemp.path("platform-files-live-test")

    File.mkdir_p!(root)
    previous = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:platform, :chat_attachments_root, previous),
        else: Application.delete_env(:platform, :chat_attachments_root)
    end)

    root
  end

  defp attach_ingest_telemetry(events) do
    handler_id = "files-live-ingest-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn name, measurements, metadata, _config ->
        send(test_pid, {:ingest_telemetry, name, measurements, metadata})
      end,
      %{}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # The whole summary element. Colour and component assertions scope to
  # this rather than the page: `role="alert"` and the warning slot both
  # legitimately appear elsewhere in the layout, so a page-wide `refute`
  # would be asserting something other than what it claims.
  defp summary_html(html) do
    case Regex.run(~r/<div[^>]*data-role="files-failed-summary".*?<\/div>/s, html) do
      [element] -> element
      _ -> flunk("no element matched data-role=\"files-failed-summary\"")
    end
  end

  # Pull one attribute off an element inside the summary, so a count
  # assertion keys on the stable hook instead of a copy string.
  defp summary_attr(html, attr) do
    element = summary_html(html)

    case Regex.run(~r/#{Regex.escape(attr)}="([^"]*)"/, element) do
      [_, value] -> value
      _ -> flunk("summary element had no #{attr}; got: #{element}")
    end
  end

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
  # `LazyHTML.query/2` returns a struct, so BOTH `== []` and `!= []` are
  # wrong for "no nodes matched". Count.
  defp node_count(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp attribute_values(html, selector, attr) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute(attr)
  end

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
