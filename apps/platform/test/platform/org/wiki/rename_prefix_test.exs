defmodule Platform.Org.Wiki.RenamePrefixTest do
  @moduledoc """
  Task 01a1386d-e528 stage 1: `Platform.Org.Wiki.rename_prefix/3`, the
  subtree rename, recorded in
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`.

  The per-page result must equal what N single `rename_page/3` calls
  produce, because a prefix rename is those renames in one transaction. A
  prefix rename never overwrites: any occupied target refuses the whole
  operation.

  ## What the mutations detonate

    * Drop the conflict check: "refuses the whole rename when any target page
      exists" goes red (the target's content is overwritten).
    * Rename each page in its own transaction instead of one: "a failure on
      one page leaves every page where it was" goes red.
  """

  use Platform.DataCase, async: false

  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Node, NodePath, Nodes}
  alias Platform.Org.WikiPage
  alias Platform.Repo

  setup do
    Repo.delete_all(NodePath)
    Repo.delete_all(Node)
    Repo.delete_all(WikiPage)
    :ok
  end

  @sources %{
    "org/page/eng/a.md" => "alpha",
    "org/page/eng/b.md" => "---\ntitle: Bee\n---\nbeta [[org/page/eng/a.md]]",
    "org/page/eng/deep/c.md" => "gamma"
  }

  defp seed_sources do
    for {key, content} <- @sources do
      {:ok, _} = Wiki.upsert_page(key, %{content: content})
    end

    # A page edited twice, so a source version above 1 is in the set.
    p = Wiki.get_page("org/page/eng/a.md")
    {:ok, _} = Wiki.upsert_page(p.file_key, %{content: "alpha v2"}, expected_version: 1)
    {:ok, _} = Wiki.upsert_page(p.file_key, %{content: "alpha v3"}, expected_version: 2)

    {:ok, _} = Wiki.upsert_page("org/page/engineer.md", %{content: "not under the prefix"})
    :ok
  end

  defp snapshot do
    WikiPage
    |> order_by([p], asc: p.file_key)
    |> Repo.all()
    |> Enum.map(&{&1.file_key, &1.content, &1.version, &1.updated_by, &1.frontmatter})
  end

  test "per-page content, version, frontmatter and updated_by equal N single rename_page calls" do
    editor = Ecto.UUID.generate()

    seed_sources()

    assert {:ok, renamed} =
             Wiki.rename_prefix("org/page/eng/", "org/page/engineering/", updated_by: editor)

    via_prefix = snapshot()

    assert Enum.map(renamed, fn {from, page} -> {from, page.file_key} end) == [
             {"org/page/eng/a.md", "org/page/engineering/a.md"},
             {"org/page/eng/b.md", "org/page/engineering/b.md"},
             {"org/page/eng/deep/c.md", "org/page/engineering/deep/c.md"}
           ]

    Repo.delete_all(WikiPage)
    seed_sources()

    for key <- ["org/page/eng/a.md", "org/page/eng/b.md", "org/page/eng/deep/c.md"] do
      target = String.replace_prefix(key, "org/page/eng/", "org/page/engineering/")
      assert {:ok, _} = Wiki.rename_page(key, target, updated_by: editor)
    end

    assert via_prefix == snapshot()

    assert via_prefix |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [
             "org/page/engineer.md",
             "org/page/engineering/a.md",
             "org/page/engineering/b.md",
             "org/page/engineering/deep/c.md"
           ]
  end

  test "refuses the whole rename when any target page exists" do
    seed_sources()
    {:ok, _} = Wiki.upsert_page("org/page/engineering/b.md", %{content: "occupied"})
    before = snapshot()

    assert Wiki.rename_prefix("org/page/eng/", "org/page/engineering/") ==
             {:error, {:conflict, ["org/page/engineering/b.md"]}}

    assert snapshot() == before
  end

  test "refuses when a target location holds a node, even with no page there" do
    seed_sources()
    {:ok, _} = Nodes.ensure("org/page/engineering/")
    before = snapshot()

    assert Wiki.rename_prefix("org/page/eng/", "org/page/engineering/") ==
             {:error, {:conflict, ["org/page/engineering/"]}}

    assert snapshot() == before
  end

  test "a failure on one page leaves every page where it was" do
    seed_sources()
    before = snapshot()

    Repo.query!("""
    CREATE FUNCTION rename_prefix_test_block() RETURNS trigger AS $$
    BEGIN
      IF NEW.file_key = 'org/page/engineering/deep/c.md' THEN
        RAISE EXCEPTION 'rename_prefix_test: insert blocked';
      END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER rename_prefix_test_block BEFORE INSERT ON org_wiki_pages
    FOR EACH ROW EXECUTE FUNCTION rename_prefix_test_block()
    """)

    assert_raise Postgrex.Error, ~r/insert blocked/, fn ->
      Wiki.rename_prefix("org/page/eng/", "org/page/engineering/")
    end

    assert snapshot() == before
  end

  test "refuses product-owned burrow prefixes on either side" do
    assert Wiki.rename_prefix("burrow/page/a/", "burrow/page/b/") == {:error, :product_owned}
    assert Wiki.rename_prefix("org/page/a/", "burrow/page/a/") == {:error, :product_owned}
    assert Wiki.rename_prefix("burrow/page/a/", "org/page/a/") == {:error, :product_owned}
  end

  test "an empty prefix is :not_found" do
    seed_sources()
    assert Wiki.rename_prefix("org/page/none/", "org/page/nada/") == {:error, :not_found}
  end

  test "a prefix with nodes but no pages moves the nodes" do
    {:ok, node} = Nodes.ensure("org/page/future/")

    assert Wiki.rename_prefix("org/page/future/", "org/page/later/") == {:ok, []}
    assert Nodes.current("org/page/later/").id == node.id
    assert Nodes.current("org/page/future/") == nil
  end

  test "input refusals" do
    assert Wiki.rename_prefix("org/page/a/", "org/page/b.md") == {:error, :not_a_prefix}
    assert Wiki.rename_prefix("org/page/a.md", "org/page/b/") == {:error, :not_a_prefix}
    assert Wiki.rename_prefix("org/page/a/", "org/page/a/") == {:error, :same_path}
    assert Wiki.rename_prefix("org/journal/", "org/page/a/") == {:error, :ambiguous_kind}
    assert Wiki.rename_prefix("org/page/", "org/page/x/") == {:error, :ambiguous_kind}

    space = Ecto.UUID.generate()
    agent = Ecto.UUID.generate()

    assert Wiki.rename_prefix(
             "space/#{space}/private/#{agent}/a/",
             "space/#{space}/private/#{agent}/b/"
           ) == {:error, :ambiguous_kind}
  end
end
