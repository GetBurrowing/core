defmodule Platform.Org.WikiTest do
  @moduledoc """
  Behaviour tests for `Platform.Org.Wiki` — CRUD, backlink materialization,
  alias fallback, and PubSub emission. DB-backed; `async: false` so we can
  use Ecto sandbox subscriptions against `Platform.PubSub`.
  """
  use Platform.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo

  # Each test starts from a clean wiki table — seeded defaults from the
  # migration would collide with explicit inserts.
  setup do
    Repo.delete_all(WikiPage)
    Phoenix.PubSub.subscribe(Platform.PubSub, Wiki.index_topic())
    :ok
  end

  defp link_rows_for(page) do
    SQL.query!(
      Repo,
      "SELECT target_path, target_id, display_text, position FROM org_wiki_links WHERE source_id = $1 ORDER BY position",
      [Ecto.UUID.dump!(page.id)]
    )
    |> Map.fetch!(:rows)
    |> Enum.map(fn [path, id_bin, display, pos] ->
      %{
        target_path: path,
        target_id: if(is_nil(id_bin), do: nil, else: Ecto.UUID.load!(id_bin)),
        display_text: display,
        position: pos
      }
    end)
  end

  # ── CRUD ────────────────────────────────────────────────────────────

  describe "upsert_page/3 — create" do
    test "inserts an org-scoped page" do
      assert {:ok, %WikiPage{} = page} =
               Wiki.upsert_page("org/identity.md", %{content: "# Org"})

      assert page.file_key == "org/identity.md"
      assert page.workspace_id == nil
      assert page.content == "# Org"
      assert page.version == 1
    end

    test "inserts a workspace-scoped page" do
      ws = Ecto.UUID.generate()

      assert {:ok, %WikiPage{} = page} =
               Wiki.upsert_page("org/identity.md", %{content: "# Org"}, workspace_id: ws)

      assert page.workspace_id == ws
    end

    test "parses frontmatter and stores both fm map and original content" do
      body =
        "---\npreamble: true\nowner: alice\n---\n# Body\n"

      assert {:ok, page} = Wiki.upsert_page("org/x.md", %{content: body})

      assert page.frontmatter == %{"preamble" => true, "owner" => "alice"}
      assert page.content == body
    end
  end

  describe "upsert_page/3 — update / optimistic lock" do
    test "second upsert increments version" do
      {:ok, p1} = Wiki.upsert_page("a.md", %{content: "v1"})
      {:ok, p2} = Wiki.upsert_page("a.md", %{content: "v2"})

      assert p1.version == 1
      assert p2.version == 2
      assert p2.id == p1.id
    end

    test "stale expected_version returns {:error, :stale}" do
      {:ok, _p1} = Wiki.upsert_page("a.md", %{content: "v1"})
      {:ok, _p2} = Wiki.upsert_page("a.md", %{content: "v2"})

      assert {:error, :stale} =
               Wiki.upsert_page("a.md", %{content: "v3"}, expected_version: 1)
    end
  end

  describe "delete_page/2" do
    test "deletes the page and cascades link rows" do
      {:ok, target} = Wiki.upsert_page("b.md", %{content: "target"})
      {:ok, source} = Wiki.upsert_page("a.md", %{content: "see [[b.md]]"})

      assert length(link_rows_for(source)) == 1

      assert {:ok, _} = Wiki.delete_page("a.md")
      assert Wiki.get_page("a.md") == nil

      # Cascading delete removes the link row that referenced the deleted source.
      assert SQL.query!(
               Repo,
               "SELECT count(*) FROM org_wiki_links WHERE source_id = $1",
               [Ecto.UUID.dump!(source.id)]
             ).rows == [[0]]

      # Target survives.
      assert %WikiPage{} = Wiki.get_page("b.md")
      _ = target
    end

    test "returns {:error, :not_found} for a missing page" do
      assert {:error, :not_found} = Wiki.delete_page("nope.md")
    end
  end

  # ── Backlinks ───────────────────────────────────────────────────────

  describe "backlinks/2" do
    test "A → B yields backlinks(B) == [A]" do
      {:ok, _b} = Wiki.upsert_page("b.md", %{content: "target"})
      {:ok, a} = Wiki.upsert_page("a.md", %{content: "see [[b.md]]"})

      assert [%WikiPage{id: id}] = Wiki.backlinks("b.md")
      assert id == a.id
    end

    test "editing A to drop the link clears the backlink" do
      {:ok, _b} = Wiki.upsert_page("b.md", %{content: "target"})
      {:ok, _a1} = Wiki.upsert_page("a.md", %{content: "see [[b.md]]"})
      assert length(Wiki.backlinks("b.md")) == 1

      {:ok, _a2} = Wiki.upsert_page("a.md", %{content: "no link now"})
      assert Wiki.backlinks("b.md") == []
    end

    test "two pages linking to B both surface as backlinks" do
      {:ok, _b} = Wiki.upsert_page("b.md", %{content: "target"})
      {:ok, _a1} = Wiki.upsert_page("a1.md", %{content: "see [[b.md]]"})
      {:ok, _a2} = Wiki.upsert_page("a2.md", %{content: "see [[b.md]]"})

      keys = Wiki.backlinks("b.md") |> Enum.map(& &1.file_key)
      assert Enum.sort(keys) == ["a1.md", "a2.md"]
    end

    test "unresolved target: link row gets target_id: nil but path is preserved" do
      {:ok, a} = Wiki.upsert_page("a.md", %{content: "see [[d.md]] (doesn't exist)"})

      assert [%{target_path: "d.md", target_id: nil}] = link_rows_for(a)
      # Backlinks for the non-existent page still surface A.
      assert [%WikiPage{file_key: "a.md"}] = Wiki.backlinks("d.md")
    end

    test "upserting the target page later does NOT auto-resolve old link rows" do
      {:ok, a} = Wiki.upsert_page("a.md", %{content: "see [[d.md]]"})
      assert [%{target_id: nil}] = link_rows_for(a)

      {:ok, _d} = Wiki.upsert_page("d.md", %{content: "now exists"})
      # No reconciliation pass: A's row still nil until A is re-upserted.
      assert [%{target_id: nil}] = link_rows_for(a)

      {:ok, a2} = Wiki.upsert_page("a.md", %{content: "see [[d.md]]"})
      [%{target_id: target_id}] = link_rows_for(a2)
      assert is_binary(target_id)
    end
  end

  # ── Alias fallback ──────────────────────────────────────────────────

  describe "alias fallback" do
    test "get_page(\"ORG_IDENTITY.md\") resolves via org_wiki_aliases" do
      # The migration backfill seeds the canonical legacy → path-style
      # aliases for both org-scoped and workspace-scoped (sentinel)
      # rows. Insert the canonical page; the alias row pre-exists.
      {:ok, _page} = Wiki.upsert_page("org/identity.md", %{content: "# Identity"})

      # Insert the alias row directly since the test starts from an
      # empty wiki table. Use the nil-workspace sentinel.
      page = Repo.get_by!(WikiPage, file_key: "org/identity.md")
      sentinel = "00000000-0000-0000-0000-000000000000"

      SQL.query!(
        Repo,
        "INSERT INTO org_wiki_aliases (workspace_id, old_path, current_id, inserted_at) VALUES ($1, $2, $3, now()) ON CONFLICT (workspace_id, old_path) DO UPDATE SET current_id = EXCLUDED.current_id",
        [
          Ecto.UUID.dump!(sentinel),
          "ORG_IDENTITY.md",
          Ecto.UUID.dump!(page.id)
        ]
      )

      assert %WikiPage{file_key: "org/identity.md"} = Wiki.get_page("ORG_IDENTITY.md")
    end

    test "resolve_alias/2 is the public alias-only entry point" do
      {:ok, page} = Wiki.upsert_page("org/agents.md", %{content: "# Agents"})
      sentinel = "00000000-0000-0000-0000-000000000000"

      SQL.query!(
        Repo,
        "INSERT INTO org_wiki_aliases (workspace_id, old_path, current_id, inserted_at) VALUES ($1, $2, $3, now()) ON CONFLICT (workspace_id, old_path) DO UPDATE SET current_id = EXCLUDED.current_id",
        [
          Ecto.UUID.dump!(sentinel),
          "ORG_AGENTS.md",
          Ecto.UUID.dump!(page.id)
        ]
      )

      assert %WikiPage{id: id} = Wiki.resolve_alias("ORG_AGENTS.md")
      assert id == page.id
    end
  end

  # ── PubSub ──────────────────────────────────────────────────────────

  describe "PubSub :index events" do
    test "upsert_page emits :wiki_page_written" do
      {:ok, page} = Wiki.upsert_page("a.md", %{content: "v1"})

      assert_receive {:wiki_page_written,
                      %{
                        page_id: page_id,
                        file_key: "a.md",
                        version: 1,
                        workspace_id: nil
                      }}

      assert page_id == page.id
    end

    test "delete_page emits :wiki_page_deleted" do
      {:ok, _page} = Wiki.upsert_page("a.md", %{content: "v1"})
      # Drop the create event before asserting on delete.
      assert_receive {:wiki_page_written, _}

      {:ok, _} = Wiki.delete_page("a.md")
      assert_receive {:wiki_page_deleted, %{file_key: "a.md", workspace_id: nil}}
    end
  end

  # ── Workspace isolation ─────────────────────────────────────────────

  describe "workspace isolation" do
    test "same file_key in two workspaces creates two distinct pages" do
      ws_a = Ecto.UUID.generate()
      ws_b = Ecto.UUID.generate()

      {:ok, pa} = Wiki.upsert_page("org/identity.md", %{content: "A"}, workspace_id: ws_a)
      {:ok, pb} = Wiki.upsert_page("org/identity.md", %{content: "B"}, workspace_id: ws_b)

      assert pa.id != pb.id
      assert Wiki.get_page("org/identity.md", workspace_id: ws_a).content == "A"
      assert Wiki.get_page("org/identity.md", workspace_id: ws_b).content == "B"
    end

    test "backlinks are workspace-scoped" do
      ws_a = Ecto.UUID.generate()
      ws_b = Ecto.UUID.generate()

      {:ok, _b_in_a} = Wiki.upsert_page("b.md", %{content: "in A"}, workspace_id: ws_a)
      {:ok, _b_in_b} = Wiki.upsert_page("b.md", %{content: "in B"}, workspace_id: ws_b)

      {:ok, _a_in_a} =
        Wiki.upsert_page("a.md", %{content: "see [[b.md]]"}, workspace_id: ws_a)

      {:ok, _c_in_b} =
        Wiki.upsert_page("c.md", %{content: "different link [[other.md]]"}, workspace_id: ws_b)

      ws_a_backlinks = Wiki.backlinks("b.md", workspace_id: ws_a)
      ws_b_backlinks = Wiki.backlinks("b.md", workspace_id: ws_b)

      assert Enum.map(ws_a_backlinks, & &1.file_key) == ["a.md"]
      assert ws_b_backlinks == []
    end
  end
end
