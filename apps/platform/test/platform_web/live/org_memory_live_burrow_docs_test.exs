defmodule PlatformWeb.OrgMemoryLiveBurrowDocsTest do
  @moduledoc """
  The Burrow Docs section of the Org Memory wiki (task 01a10a44 stage 5).

  Burrow Docs are the product-owned `burrow/page/*` rows that
  `Platform.Org.BurrowDocs` mirrors from `docs/burrow`. This file pins the
  wiki's rendering of them and the server-side refusal of every edit or
  delete event on a `burrow/` key:

    * the section renders ABOVE the Pages header, collapsed, and lists the
      topics by title in product order once opened; `burrow/` never appears
      in the Pages tree;
    * it opens by default when the install has no org pages, opens when a
      Burrow page is selected, and is hidden when there are no Burrow rows;
    * a Burrow page has no Edit and no Delete control (absent, not
      disabled), shows its title, the provenance strip and the right-pane
      provenance, and drops the bytes/lines footer;
    * forged `start_edit`, `confirm_delete`, `save_page` and `delete_file`
      events on a Burrow key are refused with a flash and change no row,
      while the same events on an org page still work (the control);
    * a Burrow search hit reads DOCS, the title and `Burrow Docs · <sha>`;
    * the 375px path chip reads `Burrow Docs > <Title>`.

  `async: false`: these tests write `burrow/page/*` rows through
  `BurrowDocs.sync/1`, and async Burrow writes break `BurrowDocsTest`
  (stage 2 finding).
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Org.BurrowDocs
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo

  @org_key "org/page/runbook.md"

  defmodule StubToolSurface do
    @moduledoc false
    # Returns one Burrow Docs hit and one org page hit.
    def execute("memory_search", _args, _context) do
      {:ok,
       %{
         results: [
           %{
             source: "page",
             id: Ecto.UUID.generate(),
             path: "burrow/page/stacks.md",
             space_id: nil,
             content:
               "---\ntitle: Task stacks\norder: 5\n---\n\n# Task stacks\n\n## What it is\nA stack groups tasks that ship together.",
             score: 0.0328,
             semantic_rank: 1,
             lexical_rank: 1,
             authored_by: nil,
             date_or_inserted_at: "2026-10-05T00:00:00Z"
           },
           %{
             source: "page",
             id: Ecto.UUID.generate(),
             path: "org/page/runbook.md",
             space_id: nil,
             content: "Our team merges stacks on Thursdays.",
             score: 0.0164,
             semantic_rank: 2,
             lexical_rank: 2,
             authored_by: nil,
             date_or_inserted_at: "2026-10-04T00:00:00Z"
           }
         ],
         fusion_constant_k: 60,
         truncated: false
       }}
    end
  end

  setup %{conn: conn} do
    assert Platform.Tenancy.get_root_org(),
           "the test database has no root org; BurrowDocs.sync/1 would no-op"

    Repo.delete_all(WikiPage)
    {:ok, _} = Wiki.upsert_page(@org_key, %{content: "# Runbook\n\nOrg notes.\n"})
    {:ok, _report} = BurrowDocs.sync()

    {:ok, conn: authed(conn)}
  end

  defp authed(conn) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "burrow-docs-ui-#{n}@example.com",
        name: "Burrow Docs UI #{n}",
        oidc_sub: "oidc-burrow-docs-ui-#{n}"
      })
      |> Repo.insert!()

    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  defp row(file_key) do
    Repo.one(from(p in WikiPage, where: p.file_key == ^file_key and is_nil(p.workspace_id)))
  end

  defp frontmatter(file_key), do: row(file_key).frontmatter

  # The repo's topics in product order, read from the docs themselves.
  defp expected_topics do
    BurrowDocs.docs()
    |> Enum.map(fn %{file_key: key, content: content} ->
      {fm, _} = Wiki.parse_frontmatter(content)
      {key, fm["title"], fm["order"]}
    end)
    |> Enum.reject(fn {key, _, _} -> key == "burrow/page/index.md" end)
    |> Enum.sort_by(fn {_, _, order} -> order end)
  end

  defp product_owned_message(file_key) do
    "#{file_key} is Burrow product documentation and is read-only. It is updated on deploy."
  end

  # Attribute values in document order, from the desktop grid only.
  defp desktop_attrs(view, selector, attr) do
    view
    |> element("[data-view-mode]")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find(selector)
    |> Enum.flat_map(&Floki.attribute(&1, attr))
  end

  describe "tree section" do
    test "renders above the Pages header, collapsed, then lists topics by title in product order",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      desktop = view |> element("[data-view-mode]") |> render()
      section_at = :binary.match(desktop, ~s(data-role="burrow-docs-section")) |> elem(0)
      pages_at = :binary.match(desktop, ~s(data-role="pages-tree-header")) |> elem(0)
      assert section_at < pages_at, "the Burrow Docs section must render ABOVE the Pages header"

      # Collapsed by default when the install has org pages.
      refute has_element?(view, "[data-view-mode] [data-burrow-leaf]")

      view
      |> element(~s([data-view-mode] [data-role="burrow-docs-toggle"]))
      |> render_click()

      keys = desktop_attrs(view, "[data-burrow-leaf]", "data-burrow-leaf")
      topic_keys = Enum.map(expected_topics(), &elem(&1, 0))
      titles = Enum.map(expected_topics(), &elem(&1, 1))

      assert keys == ["burrow/page/index.md" | topic_keys]
      assert length(topic_keys) == 13

      labels =
        view
        |> element(~s([data-view-mode] [data-role="burrow-docs-leaves"]))
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.find("[data-burrow-leaf]")
        |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

      assert labels == ["Overview" | titles]
      assert Enum.take(labels, 5) == ["Overview", "Spaces", "Agents", "Canvases", "Tasks"]

      # No filename, no version, no "+" in the section.
      section =
        view |> element(~s([data-view-mode] [data-role="burrow-docs-section"])) |> render()

      refute section =~ ".md<"
      refute section =~ ~r/>\s*v\d+\s*</
      refute section =~ "hero-plus"

      # burrow/ is excluded from the Pages tree.
      refute has_element?(view, ~s([data-view-mode] [data-namespace-prefix="burrow/"]))
      assert has_element?(view, ~s([data-view-mode] [data-namespace-prefix="org/"]))
    end

    test "opens by default when the install has no org pages", %{conn: conn} do
      Repo.delete_all(from(p in WikiPage, where: p.file_key == ^@org_key))
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      assert has_element?(view, ~s([data-view-mode] [data-burrow-leaf="burrow/page/tasks.md"]))
    end

    test "opens when a Burrow page is selected, and the leaf is the current one", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/burrow/page/tasks.md")

      assert has_element?(
               view,
               ~s([data-view-mode] [data-burrow-leaf="burrow/page/tasks.md"][aria-current="page"])
             )

      [class] =
        desktop_attrs(view, ~s([data-burrow-leaf="burrow/page/tasks.md"]), "class")

      assert class =~ "text-[var(--color-interactive)]"
      refute class =~ "text-primary"
    end

    test "is hidden when there are no Burrow rows", %{conn: conn} do
      Repo.delete_all(from(p in WikiPage, where: like(p.file_key, "burrow/%")))
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      refute has_element?(view, ~s([data-role="burrow-docs-section"]))
      assert has_element?(view, ~s([data-view-mode] [data-role="pages-tree-header"]))
    end

    test "the selected org leaf uses --color-interactive, not text-primary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/" <> @org_key)

      [class] =
        desktop_attrs(view, ~s(button[data-file-key="#{@org_key}"][aria-current="page"]), "class")

      assert class =~ "text-[var(--color-interactive)]"
      refute class =~ "text-primary"
    end
  end

  describe "Burrow page" do
    test "shows its title, the provenance strip and no Edit or Delete control", %{conn: conn} do
      sha = frontmatter("burrow/page/tasks.md")["verified_at"]
      assert is_binary(sha) and sha != ""

      {:ok, view, html} = live(conn, "/org_memory/burrow/page/tasks.md")

      assert has_element?(view, ~s([data-view-mode] h1[data-role="burrow-page-title"]), "Tasks")
      assert has_element?(view, ~s([data-view-mode] [data-role="burrow-spine"]))

      strip = view |> element(~s([data-view-mode] [data-role="burrow-provenance"])) |> render()
      assert strip =~ "Product documentation. Updated with each release."
      assert strip =~ "Last verified at"
      assert strip =~ sha
      assert strip =~ "Maintained in the product repo"

      # ABSENT, not disabled, in both viewports.
      refute has_element?(view, ~s(button[phx-click="start_edit"]))
      refute has_element?(view, ~s(button[phx-click="confirm_delete"]))
      refute has_element?(view, ~s(button[aria-label="Edit page"]))
      refute has_element?(view, ~s(button[aria-label="Delete page"]))

      # The bytes/lines footer is dropped.
      refute html =~ " bytes"

      # Right pane: Source / Verified at replace Version / Updated by.
      meta = view |> element(~s([data-view-mode] [data-role="page-meta"])) |> render()
      assert meta =~ "Source"
      assert meta =~ "Product docs"
      assert meta =~ "Verified at"
      assert meta =~ sha
      refute meta =~ "Version"
      assert has_element?(view, ~s([data-view-mode] [data-role="backlinks"]))
    end

    test "CONTROL: an org page still shows Edit and Delete", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/" <> @org_key)

      assert has_element?(view, ~s([data-view-mode] button[phx-click="start_edit"]))
      assert has_element?(view, ~s([data-view-mode] button[phx-click="confirm_delete"]))
      refute has_element?(view, ~s([data-role="burrow-provenance"]))
    end

    test "the index renders as the Overview, one row per topic in product order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/burrow/page/index.md")

      overview = view |> element(~s([data-view-mode] [data-role="burrow-overview"])) |> render()

      assert overview =~
               "How each part of the product works. Your org&#39;s own notes live under Pages."

      assert overview =~ "All topics verified at"

      topic_keys = Enum.map(expected_topics(), &elem(&1, 0))
      assert desktop_attrs(view, "[data-burrow-topic]", "data-burrow-topic") == topic_keys

      # Every topic shares one sha here, so no row repeats it.
      refute has_element?(view, ~s([data-role="burrow-row-sha"]))

      view
      |> element(~s([data-view-mode] [data-burrow-topic="burrow/page/tasks.md"]))
      |> render_click()

      assert URI.decode(assert_patch(view)) == "/org_memory/burrow/page/tasks.md"
    end

    test "an Overview row names its sha only when it differs from the set's", %{conn: conn} do
      {:ok, _} =
        BurrowDocs.sync([
          %{
            file_key: "burrow/page/index.md",
            content: "---\ntitle: Burrow Docs\norder: 0\nverified_at: \"aaaa1111\"\n---\n"
          },
          %{
            file_key: "burrow/page/one.md",
            content: "---\ntitle: One\norder: 1\nverified_at: \"aaaa1111\"\n---\n# One\n"
          },
          %{
            file_key: "burrow/page/two.md",
            content: "---\ntitle: Two\norder: 2\nverified_at: \"aaaa1111\"\n---\n# Two\n"
          },
          %{
            file_key: "burrow/page/three.md",
            content: "---\ntitle: Three\norder: 3\nverified_at: \"bbbb2222\"\n---\n# Three\n"
          }
        ])

      {:ok, view, _html} = live(conn, "/org_memory/burrow/page/index.md")

      set = view |> element(~s([data-view-mode] [data-role="burrow-set-sha"])) |> render()
      assert set =~ "aaaa1111"

      assert [row_sha] =
               view
               |> element(~s([data-view-mode] [data-role="burrow-overview"]))
               |> render()
               |> Floki.parse_fragment!()
               |> Floki.find(~s([data-role="burrow-row-sha"]))

      assert Floki.text(row_sha) =~ "verified"
      assert Floki.text(row_sha) =~ "bbbb2222"
    end
  end

  describe "server-side refusal of edit and delete events on a Burrow key" do
    setup do
      key = "burrow/page/tasks.md"
      %{key: key, before: row(key)}
    end

    test "forged start_edit is refused with a flash and opens no editor",
         %{conn: conn, key: key} do
      {:ok, view, _html} = live(conn, "/org_memory/" <> key)

      html = render_click(view, "start_edit", %{})

      assert html =~ product_owned_message(key)
      refute has_element?(view, "#org-memory-editor")
      refute has_element?(view, "#m-org-memory-editor")
    end

    test "forged confirm_delete is refused with a flash", %{conn: conn, key: key} do
      {:ok, view, _html} = live(conn, "/org_memory/" <> key)

      html = render_click(view, "confirm_delete", %{"key" => key})

      assert html =~ product_owned_message(key)
      refute html =~ "Delete #{key}?"
    end

    test "forged save_page is refused and the row is unchanged",
         %{conn: conn, key: key, before: before} do
      {:ok, view, _html} = live(conn, "/org_memory/" <> key)

      html = render_click(view, "save_page", %{"content" => "# Hijacked\n"})

      assert html =~ product_owned_message(key)
      after_row = row(key)
      assert after_row.content == before.content
      assert after_row.version == before.version
      assert after_row.updated_at == before.updated_at
    end

    test "forged delete_file is refused and the row survives",
         %{conn: conn, key: key, before: before} do
      {:ok, view, _html} = live(conn, "/org_memory/" <> key)

      html = render_click(view, "delete_file", %{"key" => key})

      assert html =~ product_owned_message(key)
      assert row(key).id == before.id
      assert row(key).content == before.content
    end

    test "CONTROL: the same events on an org page succeed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/" <> @org_key)

      render_click(view, "start_edit", %{})
      assert has_element?(view, "#org-memory-editor")

      html = render_click(view, "save_page", %{"content" => "# Runbook\n\nEdited.\n"})
      refute html =~ "Burrow product documentation"
      assert row(@org_key).content == "# Runbook\n\nEdited.\n"

      html = render_click(view, "confirm_delete", %{"key" => @org_key})
      assert html =~ "Delete #{@org_key}?"

      render_click(view, "delete_file", %{"key" => @org_key})
      assert row(@org_key) == nil
    end
  end

  describe "search" do
    setup do
      Application.put_env(:platform, :org_memory_tool_surface, StubToolSurface)
      on_exit(fn -> Application.delete_env(:platform, :org_memory_tool_surface) end)
      :ok
    end

    test "a Burrow hit reads DOCS, its title and Burrow Docs · <sha>; an org hit is unchanged",
         %{conn: conn} do
      sha = frontmatter("burrow/page/stacks.md")["verified_at"]
      {:ok, view, _html} = live(conn, ~p"/org_memory")

      view |> element(~s([data-role="tab-strip"] button[data-tab="search"])) |> render_click()

      assert has_element?(
               view,
               ~s(select[name="namespace"] option[value="burrow"]),
               "Burrow Docs"
             )

      view
      |> element("#org-memory-search-form")
      |> render_submit(%{"query" => "stacks", "corpus" => "all", "namespace" => "all"})

      hit =
        view
        |> element(~s([data-view-mode] [data-role="burrow-search-hit"]))
        |> render()

      assert hit =~ "DOCS"
      refute hit =~ ">\n    PAGE"
      assert hit =~ "Task stacks"
      refute hit =~ "burrow/page/stacks.md<"
      assert hit =~ "data-role=\"burrow-spine\""

      # The snippet starts at the prose: no frontmatter, no repeated title,
      # no heading markers.
      assert hit =~ "What it is A stack groups tasks" or hit =~ "What it is\nA stack groups tasks"
      refute hit =~ "## What it is"
      refute hit =~ "title: Task stacks"

      source =
        view
        |> element(~s([data-view-mode] [data-role="burrow-hit-source"]))
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      assert source == "Burrow Docs · #{sha}"

      # The org page hit keeps the PAGE badge and its mono path.
      desktop = view |> element("[data-view-mode]") |> render()
      assert desktop =~ "org/page/runbook.md"
      assert desktop =~ ~r/>\s*PAGE\s*</
      assert desktop =~ ~r/>\s*DOCS\s*</
    end
  end

  describe "mobile (375px shell)" do
    test "the path chip reads Burrow Docs > <Title>, last segment interactive, no Edit/Delete",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/org_memory/burrow/page/stacks.md")

      chip = view |> element(~s([data-role="mobile-path-chip"])) |> render()

      segments =
        chip
        |> Floki.parse_fragment!()
        |> Floki.find("[data-chip-segment]")
        |> Enum.flat_map(&Floki.attribute(&1, "data-chip-segment"))

      assert segments == ["Burrow Docs", "Task stacks"]

      [last] =
        chip |> Floki.parse_fragment!() |> Floki.find(~s([data-chip-last="true"]))

      assert Floki.text(last) =~ "Task stacks"
      assert last |> Floki.attribute("class") |> hd() =~ "text-[var(--color-interactive)]"
      refute chip =~ "text-primary"
      refute chip =~ "font-mono"

      shell = view |> element(~s([data-role="mobile-shell"])) |> render()
      refute shell =~ ~s(aria-label="Edit page")
      refute shell =~ ~s(aria-label="Delete page")
      assert shell =~ ~s(data-role="burrow-provenance")
      # The drawer carries the section too.
      assert shell =~ ~s(data-role="burrow-docs-section")
    end
  end

  describe "create panel" do
    test "does not offer a burrow/ location", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/org_memory")
      html = render_click(view, "show_create", %{})
      refute html =~ ~s(phx-value-key="burrow/)
    end
  end
end
