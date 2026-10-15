defmodule Platform.Org.Wiki.NodesTest do
  @moduledoc """
  Task 01a1386d-e528 stage 1: org-memory node identity
  (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`).

  A node is a location identity with a path-interval history. These tests
  pin the rules the ADR records: nodes are created on demand for page
  namespaces only; a rename (page or prefix) moves the node and the old
  location stops resolving to it except historically; an overwrite merges
  the displaced node's grants with deny kept; deleting a page keeps the node;
  and the node move is atomic with the page rename in BOTH directions.

  ## What the mutations detonate

    * Run `Nodes.move/3` before `Wiki.do_rename/4`'s transaction instead of
      inside it: "a failed page delete moves no node" goes red.
    * Run it after the transaction commits: "a failed node move renames no
      page" goes red.
    * Drop step 1 of `Platform.Access.Grants.merge_memory_nodes/2`: the merge test
      keeps an allow where a deny must win.
  """

  use Platform.DataCase, async: false

  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Node, NodePath, Nodes}
  alias Platform.Org.WikiPage
  alias Platform.Repo

  doctest Platform.Org.Wiki.Nodes

  setup do
    Repo.delete_all(NodePath)
    Repo.delete_all(Node)
    Repo.delete_all(WikiPage)
    :ok
  end

  defp seed_page(key, content \\ "body") do
    {:ok, page} = Wiki.upsert_page(key, %{content: content})
    page
  end

  defp ensure!(path) do
    {:ok, node} = Nodes.ensure(path)
    node
  end

  defp ids(nodes), do: Enum.map(nodes, & &1.id)

  # A strictly-earlier instant than anything that follows it.
  defp instant do
    at = DateTime.utc_now()
    Process.sleep(2)
    at
  end

  describe "ensure/2" do
    test "creates a node for a page path and returns the same node again" do
      seed_page("org/page/plan.md")

      node = ensure!("org/page/plan.md")
      assert node.path == "org/page/plan.md"
      assert node.org_id == Platform.Tenancy.get_root_org().id

      assert {:ok, again} = Nodes.ensure("org/page/plan.md")
      assert again.id == node.id
      assert Nodes.current("org/page/plan.md").id == node.id
      assert Repo.aggregate(Node, :count) == 1
    end

    test "creates a node for a directory prefix that has no page row" do
      node = ensure!("org/page/eng/")
      assert node.path == "org/page/eng/"
      refute Wiki.get_page("org/page/eng/")
      assert Nodes.current("org/page/eng/").id == node.id
    end

    test "creates nodes for project and space page namespaces" do
      assert {:ok, _} = Nodes.ensure("project/#{Ecto.UUID.generate()}/page/a.md")
      assert {:ok, _} = Nodes.ensure("space/#{Ecto.UUID.generate()}/page/sub/")
    end

    test "refuses journal, private, unknown and namespace-root paths" do
      space = Ecto.UUID.generate()
      agent = Ecto.UUID.generate()

      for path <- [
            "org/journal/2026-10-15.md",
            "project/#{space}/journal/2026-10-15.md",
            "space/#{space}/private/#{agent}/notes.md",
            "space/#{space}/private/#{agent}/dir/",
            "org/page/",
            "org/page/a//b.md",
            "random/path.md",
            "project/not-a-uuid/page/a.md"
          ] do
        assert Nodes.ensure(path) == {:error, :not_a_node_path}, path
      end

      assert Repo.aggregate(Node, :count) == 0
    end

    test "refuses product-owned burrow paths" do
      assert Nodes.ensure("burrow/page/guide.md") == {:error, :product_owned}
      assert Nodes.ensure("burrow/page/") == {:error, :product_owned}
      assert Nodes.ensure("burrow/page/docs/") == {:error, :product_owned}
      assert Repo.aggregate(Node, :count) == 0
    end

    test "a page write creates no node" do
      seed_page("org/page/unanchored.md")
      assert Repo.aggregate(Node, :count) == 0
    end
  end

  describe "resolve/2" do
    test "returns the node at the path and at every ancestor prefix, most specific first" do
      seed_page("org/page/eng/sub/y.md")
      eng = ensure!("org/page/eng/")
      sub = ensure!("org/page/eng/sub/")
      y = ensure!("org/page/eng/sub/y.md")
      _sibling = ensure!("org/page/ops/")

      assert ids(Nodes.resolve("org/page/eng/sub/y.md")) == [y.id, sub.id, eng.id]
      assert ids(Nodes.resolve("org/page/eng/other.md")) == [eng.id]
      assert Nodes.resolve("org/page/elsewhere.md") == []
    end

    test "scopes by workspace" do
      ws = Ecto.UUID.generate()
      {:ok, in_ws} = Nodes.ensure("org/page/eng/", workspace_id: ws)
      org_level = ensure!("org/page/eng/")

      assert ids(Nodes.resolve("org/page/eng/x.md", workspace_id: ws)) == [in_ws.id]
      assert ids(Nodes.resolve("org/page/eng/x.md")) == [org_level.id]
    end
  end

  describe "rename moves the node" do
    test "a page rename moves its node; the old location resolves to it only historically" do
      seed_page("org/page/old.md")
      node = ensure!("org/page/old.md")
      before = instant()

      assert {:ok, _} = Wiki.rename_page("org/page/old.md", "org/page/new.md")

      assert Nodes.current("org/page/new.md").id == node.id
      assert Nodes.current("org/page/old.md") == nil
      assert ids(Nodes.resolve("org/page/new.md")) == [node.id]
      assert Nodes.resolve("org/page/old.md") == []
      assert ids(Nodes.resolve("org/page/old.md", at: before)) == [node.id]
      assert Repo.aggregate(Node, :count) == 1
    end

    test "a page rename with no node creates none" do
      seed_page("org/page/plain.md")
      assert {:ok, _} = Wiki.rename_page("org/page/plain.md", "org/page/plain2.md")
      assert Repo.aggregate(Node, :count) == 0
    end

    test "rename_prefix moves the whole subtree, including nodes with no page" do
      seed_page("org/page/eng/x.md")
      seed_page("org/page/eng/secret/plan.md")
      eng = ensure!("org/page/eng/")
      x = ensure!("org/page/eng/x.md")
      plan = ensure!("org/page/eng/secret/plan.md")
      # A node whose page was deleted still moves with the subtree.
      seed_page("org/page/eng/gone.md")
      gone = ensure!("org/page/eng/gone.md")
      {:ok, _} = Wiki.delete_page("org/page/eng/gone.md")
      before = instant()

      assert {:ok, _} = Wiki.rename_prefix("org/page/eng/", "org/page/engineering/")

      assert ids(Nodes.resolve("org/page/engineering/x.md")) == [x.id, eng.id]
      assert ids(Nodes.resolve("org/page/engineering/secret/plan.md")) == [plan.id, eng.id]
      assert Nodes.current("org/page/engineering/gone.md").id == gone.id

      # The OLD location resolves to nothing now…
      assert Nodes.resolve("org/page/eng/x.md") == []
      assert Nodes.resolve("org/page/eng/y.md") == []
      # …and to the moved nodes at an instant before the rename.
      assert ids(Nodes.resolve("org/page/eng/x.md", at: before)) == [x.id, eng.id]
      assert Nodes.current_under("org/page/eng/") == []
    end

    test "an overwriting page rename closes the displaced node and keeps the moved one" do
      seed_page("org/page/a.md", "from a")
      seed_page("org/page/b.md", "from b")
      a = ensure!("org/page/a.md")
      b = ensure!("org/page/b.md")
      before = instant()

      assert {:ok, %WikiPage{content: "from a"}} =
               Wiki.rename_page("org/page/a.md", "org/page/b.md")

      assert Nodes.current("org/page/b.md").id == a.id
      assert ids(Nodes.resolve("org/page/b.md")) == [a.id]
      assert ids(Nodes.resolve("org/page/b.md", at: before)) == [b.id]
      assert ids(Nodes.resolve("org/page/a.md", at: before)) == [a.id]

      # The displaced node keeps its history but has no current location.
      assert [%NodePath{valid_to: %DateTime{}}] =
               Repo.all(from(p in NodePath, where: p.node_id == ^b.id))
    end

    test "an overwrite re-points the displaced node's grants and keeps deny over allow" do
      seed_page("org/page/a.md")
      seed_page("org/page/b.md")
      a = ensure!("org/page/a.md")
      b = ensure!("org/page/b.md")
      u = Ecto.UUID.generate()
      v = Ecto.UUID.generate()

      # Displaced node b.
      grant!(b.id, "user", u, nil, "memory.read", "deny")
      grant!(b.id, "user", v, nil, "memory.write", "allow")
      grant!(b.id, "role", nil, "guest", "memory.read", "allow")
      # Moved node a.
      grant!(a.id, "user", u, nil, "memory.read", "allow")
      grant!(a.id, "user", v, nil, "memory.write", "allow")

      assert {:ok, _} = Wiki.rename_page("org/page/a.md", "org/page/b.md")

      assert grants_on(b.id) == []

      assert grants_on(a.id) == [
               {"role", nil, "guest", "memory.read", "allow"},
               {"user", u, nil, "memory.read", "deny"},
               {"user", v, nil, "memory.write", "allow"}
             ]
    end
  end

  describe "delete keeps the node" do
    test "a deleted page's node stays at its location and a recreated page reaches it" do
      seed_page("org/page/kept.md")
      node = ensure!("org/page/kept.md")

      assert {:ok, _} = Wiki.delete_page("org/page/kept.md")
      assert Nodes.current("org/page/kept.md").id == node.id

      seed_page("org/page/kept.md", "recreated")
      assert ids(Nodes.resolve("org/page/kept.md")) == [node.id]
    end
  end

  describe "rollback" do
    test "a failed page delete moves no node" do
      seed_page("org/page/locked.md")
      node = ensure!("org/page/locked.md")

      Repo.query!("""
      CREATE FUNCTION nodes_test_block_delete() RETURNS trigger AS $$
      BEGIN
        IF OLD.file_key = 'org/page/locked.md' THEN
          RAISE EXCEPTION 'nodes_test: delete blocked';
        END IF;
        RETURN OLD;
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER nodes_test_block_delete BEFORE DELETE ON org_wiki_pages
      FOR EACH ROW EXECUTE FUNCTION nodes_test_block_delete()
      """)

      assert_raise Postgrex.Error, ~r/delete blocked/, fn ->
        Wiki.rename_page("org/page/locked.md", "org/page/moved.md")
      end

      assert Nodes.current("org/page/locked.md").id == node.id
      assert Nodes.current("org/page/moved.md") == nil
      assert Wiki.get_page("org/page/locked.md")
      refute Wiki.get_page("org/page/moved.md")
    end

    test "a failed node move renames no page" do
      seed_page("org/page/src.md", "src body")
      node = ensure!("org/page/src.md")

      Repo.query!("""
      CREATE FUNCTION nodes_test_block_interval() RETURNS trigger AS $$
      BEGIN
        IF NEW.path = 'org/page/blocked-target.md' THEN
          RAISE EXCEPTION 'nodes_test: interval blocked';
        END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER nodes_test_block_interval BEFORE INSERT ON org_memory_node_paths
      FOR EACH ROW EXECUTE FUNCTION nodes_test_block_interval()
      """)

      assert_raise Postgrex.Error, ~r/interval blocked/, fn ->
        Wiki.rename_page("org/page/src.md", "org/page/blocked-target.md")
      end

      assert %WikiPage{content: "src body"} = Wiki.get_page("org/page/src.md")
      refute Wiki.get_page("org/page/blocked-target.md")
      assert Nodes.current("org/page/src.md").id == node.id
    end
  end

  # ── grant fixtures ─────────────────────────────────────────────────────
  #
  # Rows go into the real `access_grants` table (stage 2 of this task), each
  # carrying its node's org, as `Platform.Access.Grants` stores them.
  defp grant!(node_id, type, principal_id, role_key, permission, effect) do
    %Node{org_id: org_id} = Repo.get!(Node, node_id)

    Repo.insert!(%Platform.Access.Grant{
      org_id: org_id,
      principal_type: type,
      principal_id: principal_id,
      principal_role_key: role_key,
      permission: permission,
      resource_type: "memory_node",
      resource_id: node_id,
      effect: effect
    })
  end

  defp grants_on(node_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT principal_type, principal_id, principal_role_key, permission, effect FROM access_grants WHERE resource_type = 'memory_node' AND resource_id = $1 ORDER BY principal_type, permission",
        [Ecto.UUID.dump!(node_id)]
      )

    Enum.map(rows, fn [t, pid, role, perm, eff] ->
      {t, pid && Ecto.UUID.load!(pid), role, perm, eff}
    end)
  end
end
