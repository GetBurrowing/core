defmodule PlatformWeb.FilesBrowserTest do
  @moduledoc """
  The Files & Canvases browser in `PlatformWeb.FilesLive` (Burrow redesign
  rung 16, task 01a1557a-b5f9 stage 2).

  Every absence is preceded, on the same fixture, by its positive control: a
  foreign id patching to `/files` sits beside the viewer's own id rendering,
  the masked page sits beside the same page unmasked, and the "no phx-click"
  scan first proves it found the links it scans.

  Mutation probes run against this file (stage report has the output):
    (a) `phx-click` on an item link;
    (b) the location link nested inside the item link;
    (c) a location line printing the real org name while masked;
    (d) `hover:bg-base-100` on a row;
    (e) a space id from params accepted without the viewer check.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.{Canvas, Participant, SidebarMask, Space}
  alias Platform.Files
  alias Platform.Files.Browser
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Files.BrowserComponents

  setup %{conn: conn} do
    _root = acme_org_id()
    org_a = org!("Org A")
    org_b = org!("Org B")
    org_c = org!("Org C")

    user = user!("Ada Example")
    member!(user, org_a)
    member!(user, org_b)

    project_a = project!("alpha-design", org_a)
    project_b = project!("bravo-build", org_b)
    foreign_project = project!("charlie-ops", org_c)

    design = space!("org-a-design", org_a)
    atlas = space!("atlas", org_b)
    stranger = space!("stranger-room", org_a)
    foreign_space = space!("charlie-room", org_c)

    p_design = join!(design, user)
    p_atlas = join!(atlas, user)

    %{
      conn: init_test_session(conn, current_user_id: user.id),
      user: user,
      org_a: org_a,
      org_b: org_b,
      project_a: project_a,
      project_b: project_b,
      foreign_project: foreign_project,
      design: design,
      atlas: atlas,
      stranger: stranger,
      foreign_space: foreign_space,
      p_design: p_design,
      p_atlas: p_atlas
    }
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp n, do: System.unique_integer([:positive])

  defp org!(name) do
    {:ok, org} =
      Tenancy.create_org(root_admin!(), %{name: name, slug: "files-browser-#{n()}"})

    org
  end

  defp user!(name) do
    k = n()
    Repo.insert!(%User{email: "fb-#{k}@example.com", name: name, oidc_sub: "fb-#{k}"})
  end

  defp member!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp project!(name, org) do
    {:ok, project} = Tasks.create_project(%{name: "#{name}-#{n()}", org_id: org.id})
    project
  end

  defp space!(name, org) do
    %Space{}
    |> Space.changeset(%{kind: "channel", name: name, slug: "#{name}-#{n()}", org_id: org.id})
    |> Repo.insert!()
  end

  defp join!(space, user) do
    Repo.insert!(%Participant{
      space_id: space.id,
      participant_type: "user",
      participant_id: user.id,
      role: "member",
      display_name: user.name,
      joined_at: DateTime.utc_now()
    })
  end

  defp file!(project, name, attrs \\ %{}) do
    {:ok, file} =
      Files.create_file(
        Map.merge(
          %{
            project_id: project.id,
            org_id: project.org_id,
            name: name,
            original_filename: name,
            content_type: "application/pdf",
            byte_size: 10,
            storage_key: "files/#{project.id}/#{n()}/#{name}",
            content_hash: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
            ingest_status: "pending"
          },
          attrs
        )
      )

    file
  end

  defp canvas!(space, participant, title, document \\ nil) do
    Repo.insert!(%Canvas{
      space_id: space.id,
      created_by: participant.id,
      created_by_display_name: "Ada Example",
      title: title,
      document: document || %{"version" => 1, "revision" => 1, "root" => %{"type" => "stack"}}
    })
  end

  defp game_doc do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{"type" => "stack", "children" => [%{"id" => "g", "type" => "game_stream"}]}
    }
  end

  defp attachment!(space, participant, filename, content_type) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: "sharing #{filename}"
      })

    {:ok, att} =
      Chat.create_attachment(%{
        space_id: space.id,
        message_id: msg.id,
        filename: filename,
        content_type: content_type,
        byte_size: 10,
        storage_key: "fb-#{n()}"
      })

    att
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp q(html, selector), do: html |> doc() |> LazyHTML.query(selector)

  defp count(html, selector), do: html |> q(selector) |> Enum.count()

  defp text(html, selector), do: html |> q(selector) |> LazyHTML.text()

  defp row_ids(html, selector \\ "[data-role=files-list] > li"),
    do: html |> q(selector) |> LazyHTML.attribute("data-item-id")

  # Where a URL lands: an id the viewer may not see patches to /files. On a
  # dead render that patch arrives as a redirect; on a live one, as a patch.
  defp landing(conn, path) do
    case live(conn, path) do
      {:ok, view, _html} -> assert_patch(view)
      {:error, {:live_redirect, %{to: to}}} -> to
      {:error, {:redirect, %{to: to}}} -> to
    end
  end

  defp location_text(html, item_id) do
    text(html, ~s(li[data-item-id="#{item_id}"] [data-role="files-location-link"]))
  end

  # ── Recents ─────────────────────────────────────────────────────────────

  describe "Recents (/files)" do
    test "lists a canvas and a file from two orgs, each location line naming org and place",
         ctx do
      canvas = canvas!(ctx.design, ctx.p_design, "Kickoff board")
      file = file!(ctx.project_b, "bravo-brief.pdf")

      {:ok, _view, html} = live(ctx.conn, ~p"/files")

      assert Enum.sort(row_ids(html)) == Enum.sort([canvas.id, file.id])

      canvas_loc = location_text(html, canvas.id)
      assert canvas_loc =~ "Org A"
      assert canvas_loc =~ "#org-a-design"

      file_loc = location_text(html, file.id)
      assert file_loc =~ "Org B"
      assert file_loc =~ ctx.project_b.name
    end
  end

  # ── Browse ──────────────────────────────────────────────────────────────

  describe "Browse" do
    test "?tab=browse&type=canvas lists canvases from both orgs and no file", ctx do
      a = canvas!(ctx.design, ctx.p_design, "Alpha board")
      b = canvas!(ctx.atlas, ctx.p_atlas, "Atlas board")
      _file = file!(ctx.project_a, "alpha-brief.pdf")

      {:ok, _view, html} = live(ctx.conn, ~p"/files?tab=browse&type=canvas")

      assert Enum.sort(row_ids(html)) == Enum.sort([a.id, b.id])
      assert count(html, ~s([data-role=files-list] > li[data-kind="file"])) == 0
      assert text(html, "[data-role=files-title]") =~ "Canvases"
    end

    test "?space=<id> lists that space's canvases and its shared files", ctx do
      canvas = canvas!(ctx.design, ctx.p_design, "Design board")
      pdf = attachment!(ctx.design, ctx.p_design, "spec.pdf", "application/pdf")
      _elsewhere = canvas!(ctx.atlas, ctx.p_atlas, "Not here")

      {:ok, _view, html} = live(ctx.conn, ~p"/files?space=#{ctx.design.id}")

      assert Enum.sort(row_ids(html)) == Enum.sort([canvas.id, pdf.id])
      assert count(html, ~s(li[data-item-id="#{pdf.id}"][data-kind="space_file"])) == 1
    end

    test "/files/:project_id lists the project's files", ctx do
      file = file!(ctx.project_a, "alpha-brief.pdf")
      _other = file!(ctx.project_b, "bravo-brief.pdf")

      {:ok, _view, html} = live(ctx.conn, ~p"/files/#{ctx.project_a.id}")

      assert row_ids(html) == [file.id]
      assert text(html, "[data-role=files-crumb-current]") =~ ctx.project_a.name
    end

    test "a foreign project id and a foreign space id patch to /files; own ids render", ctx do
      # Positive controls: the viewer's own ids render where they are.
      {:ok, _view, own_project} = live(ctx.conn, ~p"/files/#{ctx.project_a.id}")
      assert own_project =~ ~s(data-role="files-crumb-current")
      {:ok, _view, own_space} = live(ctx.conn, ~p"/files?space=#{ctx.design.id}")
      assert own_space =~ ~s(data-role="files-crumb-current")

      assert landing(ctx.conn, ~p"/files/#{ctx.foreign_project.id}") == "/files"
      assert landing(ctx.conn, ~p"/files?space=#{ctx.foreign_space.id}") == "/files"
      # Same org, but the viewer is not a participant.
      assert landing(ctx.conn, ~p"/files?space=#{ctx.stranger.id}") == "/files"
      # An org the viewer does not belong to.
      assert landing(ctx.conn, ~p"/files?tab=browse&org=#{ctx.foreign_project.org_id}") ==
               "/files"
    end
  end

  # ── Links ───────────────────────────────────────────────────────────────

  describe "rows are plain links" do
    test "no link carries phx-click, every row has two sibling links, none nested", ctx do
      _canvas = canvas!(ctx.design, ctx.p_design, "Kickoff board")
      _file = file!(ctx.project_b, "bravo-brief.pdf")

      {:ok, _view, html} = live(ctx.conn, ~p"/files")

      rows = count(html, "[data-role=files-list] > li")
      links = count(html, "[data-role=files-list] [data-phx-link]")

      # Positive control: the scan below has something to scan.
      assert rows == 2
      assert links == 2 * rows

      browser_links = html |> q("[data-role=files-browser] [data-phx-link]")
      assert Enum.count(browser_links) > links

      assert browser_links |> LazyHTML.attribute("phx-click") |> Enum.reject(&is_nil/1) == []
      assert count(html, "[data-role=files-browser] a a") == 0
    end
  end

  # ── Class scan ──────────────────────────────────────────────────────────

  @scanned ~w(files-header files-chips files-toolbar files-breadcrumbs files-list
              files-grid files-node-list files-browser-empty files-tree)

  defp class_offenders(html) do
    for role <- @scanned,
        el <- html |> q("[data-role=#{role}], [data-role=#{role}] [class]") |> Enum.to_list(),
        class <- LazyHTML.attribute(el, "class"),
        token <- String.split(class || ""),
        offending_class?(token),
        do: {role, token}
  end

  defp offending_class?(token) do
    String.contains?(token, "hover:") or String.starts_with?(token, "text-base-content/") or
      token == "text-error" or small_px?(token)
  end

  defp small_px?(token) do
    case Regex.run(~r/^text-\[(\d+)px\]$/, token) do
      [_, px] -> String.to_integer(px) < 12
      _ -> false
    end
  end

  describe "class scan" do
    test "no hover:, text-base-content/, text-error or sub-12px text in the browser", ctx do
      _canvas = canvas!(ctx.design, ctx.p_design, "Kickoff board")
      image = file!(ctx.project_a, "alpha-shot.png", %{content_type: "image/png"})

      {:ok, _view, recents} = live(ctx.conn, ~p"/files")
      {:ok, _view, grid} = live(ctx.conn, ~p"/files?type=image")
      {:ok, _view, empty} = live(ctx.conn, ~p"/files?q=nothing-matches-this")
      {:ok, _view, browse} = live(ctx.conn, ~p"/files?tab=browse")

      # Positive controls: each page rendered what it is scanned for.
      assert count(recents, "[data-role=files-list] > li") == 2
      assert row_ids(grid, "[data-role=files-grid] > li") == [image.id]
      assert count(empty, "[data-role=files-browser-empty]") == 1
      assert count(browse, "[data-role=files-node-list] > li") > 0

      for html <- [recents, grid, empty, browse] do
        assert class_offenders(html) == []
      end

      # The scanner can fire: a planted offender is found.
      assert class_offenders(~s(<div data-role="files-list" class="hover:bg-base-100"></div>)) ==
               [{"files-list", "hover:bg-base-100"}]
    end

    test "the browser's sources carry no hover: utility at all" do
      root = Path.expand("../../../lib/platform_web/live", __DIR__)

      for file <- ["files_live.html.heex", "files/browser_components.ex"] do
        refute File.read!(Path.join(root, file)) =~ "hover:", "#{file} carries a hover: utility"
      end
    end
  end

  # ── Masking ─────────────────────────────────────────────────────────────

  defp rail_letter(user, org) do
    sections = Platform.Chat.Sidebar.resolve_for_user(user.id, [])
    ctx = SidebarMask.context(sections, true, MapSet.new())
    %{section: section} = Enum.find(sections, &(&1.section.org_id == org.id))
    Map.fetch!(ctx.placeholders, section.id)
  end

  describe "name masking" do
    setup ctx do
      canvas = canvas!(ctx.design, ctx.p_design, "Kickoff board")
      atlas_canvas = canvas!(ctx.atlas, ctx.p_atlas, "Roadmap board")
      seeded_file = file!(ctx.project_a, "brief.pdf")
      %{canvas: canvas, atlas_canvas: atlas_canvas, seeded_file: seeded_file}
    end

    test "masked: the Chat rail's letter, no real org or project name; '#atlas' verbatim", ctx do
      # Positive control: unmasked, the real names are in the location lines.
      {:ok, _view, plain} = live(ctx.conn, ~p"/files")
      assert location_text(plain, ctx.canvas.id) =~ "Org A"
      assert location_text(plain, ctx.seeded_file.id) =~ ctx.project_a.name

      {:ok, _} = Accounts.put_mask_names(ctx.user, true)
      {:ok, _view, html} = live(ctx.conn, ~p"/files")

      letter_a = rail_letter(ctx.user, ctx.org_a)
      assert letter_a =~ ~r/^Workspace [A-Z]+$/

      browser = text(html, "[data-role=files-browser]")
      assert browser =~ letter_a
      refute browser =~ "Org A"
      refute browser =~ "Org B"
      refute browser =~ ctx.project_a.name
      refute browser =~ ctx.project_b.name

      # The org-named channel masks to the org's letter, in channel form.
      assert location_text(html, ctx.canvas.id) =~ "#" <> SidebarMask.slug(letter_a)
      refute browser =~ "org-a-design"
      # A project-code channel names no org: verbatim (SidebarMask's rule).
      assert location_text(html, ctx.atlas_canvas.id) =~ "#atlas"
      # Titles and file names stay real.
      assert browser =~ "Kickoff board"
      assert browser =~ "brief.pdf"
    end

    test "masked: Browse at All and the tree show letters, not names", ctx do
      {:ok, _} = Accounts.put_mask_names(ctx.user, true)
      {:ok, _view, html} = live(ctx.conn, ~p"/files?tab=browse")

      nodes = text(html, "[data-role=files-node-list]")
      tree = text(html, "[data-role=files-tree]")
      assert nodes =~ rail_letter(ctx.user, ctx.org_a)
      assert tree =~ rail_letter(ctx.user, ctx.org_b)

      for name <- ["Org A", "Org B", ctx.project_a.name] do
        refute nodes =~ name
        refute tree =~ name
      end
    end
  end

  # ── Project node behaviour kept ─────────────────────────────────────────

  describe "the project node keeps its detail pane" do
    test "?file=<id> opens the detail pane; delete then undo still works", ctx do
      file = file!(ctx.project_a, "alpha-brief.pdf")

      {:ok, view, html} = live(ctx.conn, ~p"/files/#{ctx.project_a.id}?file=#{file.id}")
      assert html =~ ~s(data-role="files-detail-panel")

      view |> element("#files-detail-delete-#{file.id}") |> render_click()
      assert_patch(view, ~p"/files/#{ctx.project_a.id}")
      refute has_element?(view, ~s([data-role="files-row"][data-file-id="#{file.id}"]))

      view |> element("[data-role='files-undo-button']") |> render_click()
      assert has_element?(view, ~s([data-role="files-row"][data-file-id="#{file.id}"]))
    end

    test "an unknown file id patches to /files", ctx do
      _ = file!(ctx.project_a, "alpha-brief.pdf")
      other = file!(ctx.project_b, "bravo-brief.pdf")

      assert landing(ctx.conn, ~p"/files/#{ctx.project_a.id}?file=#{other.id}") == "/files"
    end

    test "an ingest broadcast still flips the row's badge", ctx do
      file = file!(ctx.project_a, "alpha-brief.pdf")
      {:ok, view, html} = live(ctx.conn, ~p"/files/#{ctx.project_a.id}")
      assert html =~ "Ingesting"

      {:ok, _} = Files.update_ingest_status(file, "ingested")
      :ok = Files.broadcast_project(ctx.project_a.id, {:file_ingested, file.id})

      badge =
        view
        |> element(
          ~s([data-role="files-row"][data-file-id="#{file.id}"] [data-role="files-status-badge"])
        )
        |> render()

      assert badge =~ "Ready"
    end
  end

  # ── Layout ──────────────────────────────────────────────────────────────

  describe "list and grid" do
    test "the toggle writes files_layout and a fresh mount reads it", ctx do
      _ = canvas!(ctx.design, ctx.p_design, "Kickoff board")
      {:ok, view, html} = live(ctx.conn, ~p"/files")
      assert html =~ ~s(data-role="files-list")

      view |> element("[data-role=files-layout-toggle]") |> render_click()
      assert Accounts.get_user(ctx.user.id).preferences["files_layout"] == "grid"

      {:ok, _view, fresh} = live(ctx.conn, ~p"/files")
      assert fresh =~ ~s(data-role="files-grid")
      refute fresh =~ ~s(data-role="files-list")
    end

    test "Images defaults to grid with no stored choice", ctx do
      _ = file!(ctx.project_a, "alpha-shot.png", %{content_type: "image/png"})
      assert Accounts.get_user(ctx.user.id).preferences["files_layout"] == nil

      {:ok, _view, html} = live(ctx.conn, ~p"/files?type=image")
      assert html =~ ~s(data-role="files-grid")

      {:ok, _view, all} = live(ctx.conn, ~p"/files")
      assert all =~ ~s(data-role="files-list")
    end
  end

  # ── Thumbnails ──────────────────────────────────────────────────────────

  describe "thumbnails are honest" do
    test "an image row's img is its blob url; a canvas row has no img", ctx do
      image = file!(ctx.project_a, "alpha-shot.png", %{content_type: "image/png"})
      canvas = canvas!(ctx.design, ctx.p_design, "Kickoff board")

      {:ok, _view, project} = live(ctx.conn, ~p"/files/#{ctx.project_a.id}")

      assert project |> q(~s(li[data-item-id="#{image.id}"] img)) |> LazyHTML.attribute("src") ==
               ["/files/blob/#{image.id}"]

      {:ok, _view, recents} = live(ctx.conn, ~p"/files?sort=name")
      assert count(recents, ~s(li[data-item-id="#{canvas.id}"])) == 1
      assert count(recents, ~s(li[data-item-id="#{canvas.id}"] img)) == 0
    end
  end

  # ── Games chip ──────────────────────────────────────────────────────────

  describe "the Games chip" do
    test "is absent when the game_stream kind is not registered", ctx do
      refute Browser.games_enabled?()
      {:ok, _view, html} = live(ctx.conn, ~p"/files")
      assert count(html, ~s([data-role=files-type-chip][data-chip="canvas"])) == 1
      assert count(html, ~s([data-role=files-type-chip][data-chip="game"])) == 0
    end

    test "is present, and lists games, when an extension registers game_stream", ctx do
      Platform.FixtureExtension.register([__MODULE__.GamesExtension])
      assert Browser.games_enabled?()

      game = canvas!(ctx.design, ctx.p_design, "Arcade", game_doc())
      _plain = canvas!(ctx.design, ctx.p_design, "Plain board")

      {:ok, _view, html} = live(ctx.conn, ~p"/files?type=game")
      assert count(html, ~s([data-role=files-type-chip][data-chip="game"])) == 1
      assert row_ids(html) == [game.id]
    end

    test "the chip row renders Games exactly when games is set" do
      browser = %{mode: :recents, type: nil, params: %{}}
      on = render_component(&BrowserComponents.browser_chips/1, browser: browser, games: true)
      off = render_component(&BrowserComponents.browser_chips/1, browser: browser, games: false)

      assert on =~ ~s(data-chip="game")
      refute off =~ ~s(data-chip="game")
    end
  end

  # ── ＋ New (stage 3) ─────────────────────────────────────────────────────

  defp open_new(view), do: view |> element("[data-role=files-new]") |> render_click()

  defp new_sheet(html), do: q(html, "#files-new-sheet")

  describe "＋ New" do
    test "in a space node, New canvas creates in THAT space as the viewer and redirects", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files?space=#{ctx.design.id}")
      open_new(view)

      view |> element("#files-new-sheet [data-role=files-new-canvas]") |> render_click()
      {path, _flash} = assert_redirect(view)

      [canvas] =
        Repo.all(
          from(c in Canvas, where: c.space_id == ^ctx.design.id and c.title == "Untitled canvas")
        )

      assert path == "/canvases/#{canvas.id}"
      assert canvas.created_by == ctx.p_design.id

      {:ok, _view, recents} = live(ctx.conn, ~p"/files")
      assert hd(row_ids(recents)) == canvas.id
    end

    test "in Recents, New canvas asks for the space; a forged foreign space creates nothing",
         ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files")
      open_new(view)
      html = view |> element("#files-new-sheet [data-role=files-new-canvas]") |> render_click()

      picker = html |> new_sheet() |> LazyHTML.query("[data-role=files-new-space]")
      picked = picker |> LazyHTML.attribute("phx-value-space-id") |> Enum.sort()
      assert picked == Enum.sort([ctx.design.id, ctx.atlas.id])

      # Both forged targets have a real participant (someone else), so only
      # the viewer check can refuse them.
      outsider = user!("Bea Example")
      _ = join!(ctx.foreign_space, outsider)
      _ = join!(ctx.stranger, outsider)
      before = Repo.aggregate(Canvas, :count)

      for forged <- [ctx.foreign_space.id, ctx.stranger.id] do
        render_click(view, "new_canvas", %{"space-id" => forged})
      end

      assert Repo.aggregate(Canvas, :count) == before

      for malformed <- [Ecto.UUID.generate(), "not-a-uuid"] do
        render_click(view, "new_canvas", %{"space-id" => malformed})
      end

      assert Repo.aggregate(Canvas, :count) == before
      # Positive control: an own space from the picker does create.
      render_click(view, "new_canvas", %{"space-id" => ctx.atlas.id})
      assert {"/canvases/" <> _, _} = assert_redirect(view)
      assert Repo.aggregate(Canvas, :count) == before + 1
    end

    test "Upload opens the upload sheet in a project node, and the project picker elsewhere",
         ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files/#{ctx.project_a.id}")
      open_new(view)
      refute render(view) =~ ~s(data-role="files-upload-sheet")
      html = view |> element("#files-new-sheet [data-role=files-new-upload]") |> render_click()
      assert html =~ ~s(data-role="files-upload-sheet")

      {:ok, view, _html} = live(ctx.conn, ~p"/files")
      open_new(view)
      html = view |> element("#files-new-sheet [data-role=files-new-upload]") |> render_click()

      projects =
        html |> new_sheet() |> LazyHTML.query("[data-role=files-new-project]")

      assert projects |> LazyHTML.attribute("phx-value-project-id") |> Enum.sort() ==
               Enum.sort([ctx.project_a.id, ctx.project_b.id])

      view
      |> element(
        ~s(#files-new-sheet [data-role=files-new-project][phx-value-project-id="#{ctx.project_b.id}"])
      )
      |> render_click()

      assert_patch(view, ~p"/files/#{ctx.project_b.id}")
      assert render(view) =~ ~s(data-role="files-upload-sheet")

      # A forged foreign project patches nowhere and opens nothing.
      {:ok, view, _html} = live(ctx.conn, ~p"/files")
      render_click(view, "upload_to_project", %{"project-id" => ctx.foreign_project.id})
      refute render(view) =~ ~s(data-role="files-upload-sheet")
    end

    test "the New sheet is a bottom swipe sheet with the handle Close, phone only", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files")
      html = open_new(view)
      sheet = new_sheet(html)

      # Positive control first: the sheet and its first item are there.
      assert sheet |> LazyHTML.query("[data-role=files-new-canvas]") |> Enum.count() == 1
      assert LazyHTML.attribute(sheet, "data-swipe-dismiss") == ["true"]

      assert sheet
             |> LazyHTML.attribute("class")
             |> hd()
             |> String.split()
             |> Enum.member?("lg:hidden")

      button = LazyHTML.query(sheet, "button.sheet-handle-button")
      assert LazyHTML.attribute(button, "phx-click") == ["close_new_sheet"]

      text = LazyHTML.text(sheet)
      refute text =~ "New folder"
      refute text =~ "Game canvas"
    end

    test "the old upload FAB is gone and + New is the browser's only primary control", ctx do
      {:ok, _view, html} = live(ctx.conn, ~p"/files/#{ctx.project_a.id}")

      refute html =~ ~s(data-role="file-upload-fab")

      primaries =
        html
        |> q("[data-role=files-browser] .btn-primary")
        |> LazyHTML.attribute("data-role")

      assert primaries == ["files-new"]
    end

    test "the desktop New menu holds the same items and no hover utility", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/files")
      html = open_new(view)
      menu = q(html, "#files-new-menu")

      assert menu |> LazyHTML.query("[data-role=files-new-canvas]") |> Enum.count() == 1
      assert menu |> LazyHTML.query("[data-role=files-new-upload]") |> Enum.count() == 1

      assert menu
             |> LazyHTML.attribute("class")
             |> hd()
             |> String.split()
             |> Enum.member?("lg:block")

      refute LazyHTML.to_html(menu) =~ "hover:"
    end
  end

  # ── Fidelity fixes (stage 5) ─────────────────────────────────────────────

  describe "row composition and tiles (prototype v3 :641-646)" do
    test "the location line sits in row 2 of the same grid as the tile, beside it, not nested",
         ctx do
      canvas = canvas!(ctx.design, ctx.p_design, "Kickoff board")
      {:ok, _view, html} = live(ctx.conn, ~p"/files")

      row = q(html, ~s(li[data-item-id="#{canvas.id}"]))
      assert Enum.count(row) == 1

      row_classes = row |> LazyHTML.attribute("class") |> hd() |> String.split()
      # One grid holds the tile column and the two text lines.
      assert "grid" in row_classes
      assert "grid-rows-[1fr_1fr]" in row_classes
      assert LazyHTML.attribute(row, "data-location") == ["true"]

      tile = LazyHTML.query(row, "[data-role=files-row-tile]")

      assert tile
             |> LazyHTML.attribute("class")
             |> hd()
             |> String.split()
             |> Enum.member?("row-end-3")

      # The location line is a direct child of the row, in row 2 of the text
      # column, and its link is not inside the item link.
      location =
        html
        |> q(~s(li[data-item-id="#{canvas.id}"] > div))
        |> Enum.filter(
          &(&1 |> LazyHTML.query("[data-role=files-location-link]") |> Enum.count() == 1)
        )

      assert [loc] = location
      loc_classes = loc |> LazyHTML.attribute("class") |> hd() |> String.split()
      assert "row-start-2" in loc_classes
      assert "col-start-2" in loc_classes

      assert row
             |> LazyHTML.query("[data-role=files-item-link] [data-role=files-location-link]")
             |> Enum.count() == 0

      assert row
             |> LazyHTML.query("[data-role=files-item-link] [data-role=files-row-tile]")
             |> Enum.count() == 1
    end

    test "a grid tile shows the copy marker, so a clone pair is told apart", ctx do
      original = canvas!(ctx.design, ctx.p_design, "Launch plan")

      clone =
        Repo.insert!(%Canvas{
          space_id: ctx.design.id,
          created_by: ctx.p_design.id,
          created_by_display_name: "Ada Example",
          title: "Launch plan.",
          cloned_from: original.id,
          document: %{"version" => 1, "revision" => 1, "root" => %{"type" => "stack"}}
        })

      {:ok, _} = Accounts.update_user_preference(ctx.user.id, "files_layout", "grid")
      {:ok, _view, html} = live(ctx.conn, ~p"/files?tab=browse&type=canvas")

      # Positive control: both tiles are in the grid.
      assert html |> q("[data-role=files-grid] > li") |> Enum.count() == 2

      clone_tile = q(html, ~s([data-role=browser-tile][data-item-id="#{clone.id}"]))
      original_tile = q(html, ~s([data-role=browser-tile][data-item-id="#{original.id}"]))

      assert clone_tile |> LazyHTML.query("[data-role=files-copy-marker]") |> Enum.count() == 1
      assert original_tile |> LazyHTML.query("[data-role=files-copy-marker]") |> Enum.count() == 0
      # Author and age ride on the tile too.
      assert LazyHTML.text(clone_tile) =~ "Ada Example"
      assert LazyHTML.text(original_tile) =~ "Ada Example"
    end
  end

  defmodule GamesExtension do
    @moduledoc false
    # Registers only a `game_stream` canvas kind, so `Browser.games_enabled?/0`
    # is true for the test that registers it. Core never names the real
    # extension's modules (extension_boundary_test.exs).
    @behaviour Platform.Extension

    defmodule Kinds.GameStream do
      @moduledoc false
      use Platform.Chat.Canvas.Kind

      @impl true
      def describe, do: "Test-only game_stream kind."

      @impl true
      def schema, do: %{"type" => "object", "properties" => %{}}

      attr :node, :map, required: true
      attr :viewer, :any, default: nil

      @impl true
      def render(assigns) do
        ~H"""
        <span data-role="test-game"></span>
        """
      end
    end

    @impl true
    def canvas_kinds, do: [__MODULE__.Kinds.GameStream]
    @impl true
    def mcp_tool_bundles, do: []
    @impl true
    def runtime_channel_events, do: []
    @impl true
    def handle_runtime_event(_event, _runtime_id, _payload), do: :ok
    @impl true
    def runtime_disconnected(_runtime_id), do: :ok
    @impl true
    def live_hooks, do: []
    @impl true
    def experiment_surfaces, do: []
    @impl true
    def experiment_metrics, do: %{}
    @impl true
    def migrations_path, do: nil
    @impl true
    def routes, do: []
    @impl true
    def inbox_kinds, do: []
    @impl true
    def live_pages, do: []
  end
end
