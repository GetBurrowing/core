defmodule Platform.Access.ChangesTest do
  @moduledoc """
  Task 01a1386e-30bd stage 1 (RBAC stack member 6): the access change ledger.

  `Platform.Access.Changes.commit/4` is the one writer to `access_grants`; it
  writes the `Platform.Access.Change` row with the exact before/after rows in
  the same transaction, and `undo/3` restores the before-set row for row.

  Every absence here is preceded by its positive control on the same fixture:
  a refused undo is shown to leave rows that WERE there, and the rollback test
  shows the grant exists when the ledger insert is not blocked.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures, except: [root_admin!: 0]

  alias Platform.Access.{Change, Changes, Grant, Grants, Scope}
  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Audit
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Node, NodePath, Nodes}
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tasks

  setup do
    Repo.delete_all(NodePath)
    Repo.delete_all(Node)
    Repo.delete_all(WikiPage)
    _root = acme_org_id()
    org = tenant_org_id("ledger")
    {:ok, p} = Tasks.create_project(%{name: "ledger-#{uniq()}", org_id: org})
    {:ok, q} = Tasks.create_project(%{name: "ledger-#{uniq()}", org_id: org})
    %{org: org, p: p, q: q}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp user!(tag \\ "u") do
    n = uniq()

    Repo.insert!(%User{
      email: "ledger-#{tag}-#{n}@example.com",
      name: "Ledger #{tag} #{n}",
      oidc_sub: "ledger-#{tag}-#{n}"
    })
  end

  defp ok!({:ok, value}), do: value

  # Stage 2 (delegation): a user actor's change is authorized, so the actor
  # here is a root admin (an admin membership in the root org), whose
  # changes pass as the audited bypass.
  defp root_admin! do
    user = user!("admin")

    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: acme_org_id(),
      role: "admin"
    })
    |> Repo.insert!()

    Platform.Accounts.get_user(user.id)
  end

  # Every grant row, as snapshots, ordered by id: the "exact grant set".
  defp all_grants, do: Repo.all(from(g in Grant, order_by: g.id)) |> Enum.map(&Grant.snapshot/1)

  defp change_count, do: Repo.aggregate(Change, :count)

  defp last_change, do: Repo.one(from(c in Change, order_by: [desc: c.id], limit: 1))

  # The access_grants columns, read from the catalogue rather than the schema,
  # so "snapshot serialises every column" is checked against the table.
  defp grant_columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'access_grants'"
      )

    rows |> List.flatten() |> Enum.sort()
  end

  @uuid_columns ~w(id org_id principal_id resource_id granted_by)

  # A raw SELECT of one tuple's rows, normalised to the snapshot shape.
  defp raw_tuple_rows(principal_id, permission, resource_id) do
    %{columns: columns, rows: rows} =
      Repo.query!(
        "SELECT * FROM access_grants WHERE principal_id = $1 AND permission = $2 AND resource_id = $3 ORDER BY id",
        [Ecto.UUID.dump!(principal_id), permission, Ecto.UUID.dump!(resource_id)]
      )

    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn
        {"inserted_at", %NaiveDateTime{} = at} ->
          {"inserted_at", at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()}

        {"inserted_at", %DateTime{} = at} ->
          {"inserted_at", DateTime.to_iso8601(at)}

        {col, <<_::128>> = uuid} when col in @uuid_columns ->
          {col, Ecto.UUID.load!(uuid)}

        {col, value} ->
          {col, value}
      end)
    end)
  end

  describe "snapshot" do
    test "serialises every access_grants column and restores losslessly", %{p: p} do
      u = user!()
      grant = ok!(Grants.grant(%{principal: u, permission: "tasks.read", resource: p}))
      snap = Grant.snapshot(grant)

      assert snap |> Map.keys() |> Enum.sort() == grant_columns()
      assert [snap] == raw_tuple_rows(u.id, "tasks.read", p.id)

      restored = struct(Grant, Grant.from_snapshot(snap))
      assert Grant.snapshot(restored) == snap
    end
  end

  describe "commit: one change row per write, before/after equal to the rows" do
    test "grant, deny and revoke each write exactly one change row", %{org: org, p: p, q: q} do
      u = user!()
      raw_before = raw_tuple_rows(u.id, "tasks.read", p.id)
      assert raw_before == []

      n0 = change_count()
      grant = ok!(Grants.grant(%{principal: u, permission: "tasks.read", resource: p}))
      assert change_count() == n0 + 1

      c1 = last_change()
      assert c1.action == "grant"
      assert c1.org_id == org
      assert c1.before == raw_before
      assert c1.after == raw_tuple_rows(u.id, "tasks.read", p.id)
      assert [%{"id" => id, "effect" => "allow"}] = c1.after
      assert id == grant.id
      assert c1.tuple_keys == [Grant.tuple_key(grant)]

      ok!(Grants.deny(%{principal: u, permission: "tasks.read", resource: q}))
      assert change_count() == n0 + 2
      c2 = last_change()
      assert c2.action == "deny"
      assert c2.before == []
      assert c2.after == raw_tuple_rows(u.id, "tasks.read", q.id)
      assert [%{"effect" => "deny"}] = c2.after

      raw_pre_revoke = raw_tuple_rows(u.id, "tasks.read", p.id)
      assert {:ok, %Grant{}} = Grants.revoke(grant)
      assert change_count() == n0 + 3
      c3 = last_change()
      assert c3.action == "revoke"
      assert c3.before == raw_pre_revoke
      assert c3.after == []
      assert raw_tuple_rows(u.id, "tasks.read", p.id) == []
    end

    test "the arity-1 forms record actor_type system; arity-2 records the actor",
         %{p: p, q: q} do
      u = user!()
      admin = root_admin!()
      agent_id = Ecto.UUID.generate()

      ok!(Grants.grant(%{principal: u, permission: "tasks.read", resource: p}))
      assert %Change{actor_type: "system", actor_id: nil, via_agent_id: nil} = last_change()

      grant =
        ok!(
          Grants.grant(%{principal: u, permission: "chat.read", resource: p},
            actor: Scope.for_user(admin),
            via_agent_id: agent_id
          )
        )

      assert grant.granted_by == admin.id
      c = last_change()
      assert {c.actor_type, c.actor_id, c.via_agent_id} == {"user", admin.id, agent_id}

      # Stage 2: a deny needs `access.manage` on the resource. This scope
      # carries it directly; delegation itself is delegation_test.exs.
      agent_scope = %Scope{
        actor: %AgentRuntime{agent_id: agent_id},
        permissions: %{"access.manage" => :all}
      }

      ok!(Grants.deny(%{principal: u, permission: "tasks.read", resource: q}, actor: agent_scope))
      assert {last_change().actor_type, last_change().actor_id} == {"agent", agent_id}
    end

    test "a write without an actor raises; an actor-less scope is refused", %{p: p} do
      u = user!()
      attrs = %{principal: u, permission: "tasks.read", resource: p}

      assert_raise ArgumentError, ~r/actor:/, fn -> Grants.grant(attrs, []) end
      assert {:error, :invalid_actor} = Grants.grant(attrs, actor: %Scope{})
      assert all_grants() == []
      assert change_count() == 0
    end

    test "a refused write (double effect) writes neither a grant nor a change row", %{p: p} do
      u = user!()
      ok!(Grants.grant(%{principal: u, permission: "tasks.read", resource: p}))
      grants = all_grants()
      n = change_count()

      assert {:error, %Ecto.Changeset{}} =
               Grants.deny(%{principal: u, permission: "tasks.read", resource: p})

      assert all_grants() == grants
      assert change_count() == n
    end
  end

  describe "rollback" do
    test "a failing change-row insert leaves the grants unchanged", %{p: p} do
      u = user!()
      v = user!()

      # Positive control: the same write, unblocked, does insert.
      ok!(Grants.grant(%{principal: v, permission: "tasks.read", resource: p}))
      grants = all_grants()
      n = change_count()

      Repo.query!("""
      CREATE FUNCTION changes_test_block_ledger() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'changes_test: ledger insert blocked';
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER changes_test_block_ledger BEFORE INSERT ON access_grant_changes
      FOR EACH ROW EXECUTE FUNCTION changes_test_block_ledger()
      """)

      assert_raise Postgrex.Error, ~r/ledger insert blocked/, fn ->
        Grants.grant(%{principal: u, permission: "tasks.read", resource: p})
      end

      assert all_grants() == grants
      assert change_count() == n
    end

    test "an invalid change row (bad via_agent_id) rolls the grant back", %{p: p} do
      u = user!()
      n = change_count()

      assert {:error, %Ecto.Changeset{data: %Change{}}} =
               Grants.grant(%{principal: u, permission: "tasks.read", resource: p},
                 actor: Scope.system(),
                 via_agent_id: "not-a-uuid"
               )

      assert all_grants() == []
      assert change_count() == n
    end
  end

  describe "undo" do
    test "restores the exact prior grant set after a multi-row change", %{org: org, p: p, q: q} do
      u = user!()
      v = user!()
      agent_id = Ecto.UUID.generate()

      a1 = ok!(Grants.grant(%{principal: u, permission: "tasks.read", resource: p}))
      a2 = ok!(Grants.grant(%{principal: u, permission: "chat.read", resource: p}))
      ok!(Grants.deny(%{principal: {:role, "guest"}, permission: "canvas.read", resource: q}))
      ok!(Grants.grant(%{principal: {:agent, agent_id}, permission: "tasks.read", resource: q}))
      ok!(Grants.grant(%{principal: v, permission: "tasks.read", resource: q}))

      s0 = all_grants()
      assert length(s0) == 5

      # X1: revoke two allows and add a deny, in ONE change.
      query =
        from(g in Grant,
          where: g.id in ^[a1.id, a2.id] or (g.principal_id == ^u.id and g.resource_id == ^q.id)
        )

      x1 =
        Changes.commit(
          Scope.system(),
          "revoke",
          fn ->
            Repo.delete_all(from(g in Grant, where: g.id in ^[a1.id, a2.id]))

            %Grant{}
            |> Grant.changeset(%{
              org_id: org,
              principal_type: "user",
              principal_id: u.id,
              permission: "tasks.read",
              resource_type: "project",
              resource_id: q.id,
              effect: "deny"
            })
            |> Repo.insert()
          end,
          query: query
        )
        |> ok!()
        |> Map.fetch!(:change)

      assert length(x1.before) == 2
      assert length(x1.after) == 1
      refute all_grants() == s0

      assert {:ok, %{change: undo}} = Changes.undo(x1.id, Scope.system())
      assert undo.action == "undo"
      assert undo.undoes_change_id == x1.id

      # Row for row: ids, effects, permissions, resources, principals,
      # granted_by and inserted_at.
      assert all_grants() == s0
    end

    test "a superseded undo is refused and changes nothing", %{p: p} do
      u = user!()
      x1 = Grants.grant(%{principal: u, permission: "tasks.read", resource: p}) |> ok!()
      c1 = last_change()
      ok!(Grants.revoke(x1))
      c2 = last_change()

      # The revoke holds the tuple: undoing the grant would resurrect state a
      # later change already replaced.
      ok!(Grants.grant(%{principal: u, permission: "chat.read", resource: p}))
      grants = all_grants()
      assert grants != []
      n = change_count()

      assert {:error, {:superseded, [later]}} = Changes.undo(c1.id, Scope.system())
      assert later == c2.id
      assert all_grants() == grants
      assert change_count() == n
    end

    test "a second undo is refused; undoing the undo redoes the change", %{p: p} do
      u = user!()
      grant = ok!(Grants.grant(%{principal: u, permission: "tasks.read", resource: p}))
      x = last_change()
      post_change = all_grants()
      assert [_] = post_change

      assert {:ok, %{change: u1}} = Changes.undo(x.id, Scope.system())
      assert all_grants() == []

      n = change_count()
      assert {:error, :already_undone} = Changes.undo(x.id, Scope.system())
      assert change_count() == n

      assert {:ok, %{change: redo}} = Changes.undo(u1.id, Scope.system())
      assert redo.undoes_change_id == u1.id
      assert all_grants() == post_change
      assert [%{"id" => id}] = all_grants()
      assert id == grant.id

      assert {:error, :already_undone} = Changes.undo(u1.id, Scope.system())
      assert {:error, :not_found} = Changes.undo("nope", Scope.system())
      assert {:error, :not_found} = Changes.undo(Ecto.UUID.generate(), Scope.system())
    end

    test "undo of a revoke re-inserts the original row verbatim", %{p: p} do
      u = user!()
      grant = ok!(Grants.deny(%{principal: u, permission: "tasks.read", resource: p}))
      s0 = all_grants()
      ok!(Grants.revoke(grant.id))
      assert all_grants() == []

      assert {:ok, %{result: [restored]}} = Changes.undo(last_change().id, Scope.system())
      assert restored.id == grant.id
      assert restored.inserted_at == grant.inserted_at
      assert all_grants() == s0
    end
  end

  describe "system_repoint" do
    test "a rename that re-points grants is one ledgered change; with no grants, none" do
      {:ok, _} = Wiki.upsert_page("org/page/a.md", %{content: "a"})
      {:ok, _} = Wiki.upsert_page("org/page/b.md", %{content: "b"})
      {:ok, _} = Wiki.upsert_page("org/page/c.md", %{content: "c"})
      {:ok, _} = Wiki.upsert_page("org/page/d.md", %{content: "d"})
      {:ok, _a} = Nodes.ensure("org/page/a.md")
      {:ok, b} = Nodes.ensure("org/page/b.md")
      {:ok, _c} = Nodes.ensure("org/page/c.md")
      {:ok, _d} = Nodes.ensure("org/page/d.md")

      # No grants on either node: the overwrite writes no change row.
      n = change_count()
      assert {:ok, _} = Wiki.rename_page("org/page/c.md", "org/page/d.md")
      assert change_count() == n

      u = user!()

      ok!(Grants.deny(%{principal: u, permission: "memory.read", resource: {:memory_node, b.id}}))

      n = change_count()
      assert {:ok, _} = Wiki.rename_page("org/page/a.md", "org/page/b.md")
      assert change_count() == n + 1

      c = last_change()
      assert c.action == "system_repoint"
      assert c.actor_type == "system"
      assert [%{"resource_id" => from}] = c.before
      assert [%{"resource_id" => to}] = c.after
      assert from == b.id
      refute to == b.id
    end
  end

  describe "audit mirror and listing" do
    test "each change is mirrored as platform.access.grant_changed", %{p: p} do
      u = user!()
      admin = root_admin!()

      ok!(
        Grants.grant(%{principal: u, permission: "tasks.read", resource: p},
          actor: Scope.for_user(admin)
        )
      )

      c = last_change()

      assert [event] =
               Audit.list(event_type: "platform.access.grant_changed", resource_id: c.id)

      assert event.resource_type == "access_grant_change"
      assert event.actor_type == "user"
      assert event.actor_id == admin.id
      assert event.action == "grant"
      assert event.metadata["org_id"] == c.org_id
    end

    test "list_changes pages by id cursor", %{org: org, p: p, q: q} do
      u = user!()
      ok!(Grants.grant(%{principal: u, permission: "tasks.read", resource: p}))
      ok!(Grants.grant(%{principal: u, permission: "tasks.read", resource: q}))
      ok!(Grants.grant(%{principal: u, permission: "chat.read", resource: q}))

      assert [c1, c2] = Changes.list_changes(org, limit: 2)
      assert [c3] = Changes.list_changes(org, limit: 2, cursor: c2.id)
      assert c1.id < c2.id and c2.id < c3.id
      assert [^c3] = Changes.list_changes(org, tuple_key: hd(c3.tuple_keys))
      assert Changes.list_changes(Ecto.UUID.generate()) == []
    end
  end

  describe "zero grants" do
    test "with no grants and no writes, the ledger is empty and nothing changes" do
      assert all_grants() == []
      assert change_count() == 0

      {:ok, _} = Wiki.upsert_page("org/page/x.md", %{content: "x"})
      {:ok, _} = Wiki.upsert_page("org/page/y.md", %{content: "y"})
      {:ok, _} = Nodes.ensure("org/page/x.md")
      {:ok, _} = Nodes.ensure("org/page/y.md")
      assert {:ok, _} = Wiki.rename_page("org/page/x.md", "org/page/y.md")

      assert all_grants() == []
      assert change_count() == 0
      assert Audit.list(event_type: "platform.access.grant_changed") == []
    end
  end
end
