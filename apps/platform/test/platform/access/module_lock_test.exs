defmodule Platform.Access.ModuleLockTest do
  @moduledoc """
  Task 01a14721 stage 2: MODULE LOCKS. A module-scoped deny row in
  `access_grants` (`resource_type "module"`, `resource_id` the org,
  `permission` a module name) locks its principal out of the whole module:
  every permission of it evaluates false everywhere, including where the
  built-in role rule is `"all"`.

  The world: the root org R and a sub-org S. U and V are internal members of
  S, A is S's admin, RM a root member. S has project P (task T) and a
  channel C. Every refusal is preceded by its positive control on the same
  fixture: the answer was true before the lock, or is true for an unlocked
  principal.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Change, Changes, Effective, Grant, Grants, Lineage, Query, Registry}
  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy.OrgMembership

  # ── fixtures ────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive])

  defp user!(tag) do
    n = uniq()

    Repo.insert!(%User{
      email: "lock-#{tag}-#{n}@example.com",
      name: "Lock #{tag} #{n}",
      oidc_sub: "lock-#{tag}-#{n}"
    })
  end

  defp in_org!(org, role, tag) do
    u = user!(tag)

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: u.id, org_id: org, role: role})
    |> Repo.insert!()

    u
  end

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp lock!(principal, module, org, opts \\ [actor: Scope.system()]) do
    {:ok, grant} =
      Grants.deny(%{principal: principal, permission: module, resource: {:module, org}}, opts)

    grant
  end

  defp counts, do: {Repo.aggregate(Grant, :count), Repo.aggregate(Change, :count)}

  defp perms(module), do: Enum.map(Registry.module_permissions(module), & &1.name)

  # Every answer the lock could change, for every declared permission.
  defp answers(scope, resources) do
    for p <- Registry.permission_names(), r <- [nil | resources], into: %{} do
      {{p, r}, Access.can?(scope, p, r)}
    end
    |> Map.merge(
      for p <- Registry.permission_names(),
          into: %{},
          do: {{:anywhere, p}, Access.holds_anywhere?(scope, p)}
    )
    |> Map.merge(
      for e <- Registry.rail_entries(),
          into: %{},
          do: {{:rail, e.key}, Access.module_access?(scope, e.key)}
    )
  end

  setup do
    root = acme_org_id()
    s = tenant_org_id("lock_s_#{uniq()}")

    u = in_org!(s, "member", "u")
    v = in_org!(s, "member", "v")
    a = in_org!(s, "admin", "a")
    rm = in_org!(root, "member", "rm")

    {:ok, p} = Tasks.create_project(%{name: "lock-p-#{uniq()}", org_id: s})
    t = Repo.insert!(%Task{project_id: p.id, title: "lock task #{uniq()}", status: "backlog"})

    c =
      %Space{}
      |> Space.changeset(%{
        kind: "channel",
        name: "lock-c-#{uniq()}",
        slug: "lock-c-#{uniq()}",
        org_id: s
      })
      |> Repo.insert!()

    %{
      root: root,
      s: s,
      u: u,
      v: v,
      a: a,
      rm: rm,
      p: p,
      t: t,
      c: c,
      resources: [{:project, p.id}, {:task, t.id}, {:space, c.id}]
    }
  end

  # ── the decision ────────────────────────────────────────────────────────

  describe "a locked user" do
    test "can? is false for every permission of the module, on nil and typed resources, even with member \"all\"",
         ctx do
      before = scope(ctx.u)

      # Positive control: the member role carries tasks.read/write at "all".
      assert Scope.carries?(before, "tasks.read")
      assert Access.can?(before, "tasks.read", nil)
      assert Access.can?(before, "tasks.read", {:task, ctx.t.id})
      assert Access.can?(before, "tasks.write", {:project, ctx.p.id})

      lock!({:user, ctx.u.id}, "tasks", ctx.s)
      locked = scope(ctx.u)

      # The role rule is untouched; the lock beats it.
      assert Scope.carries?(locked, "tasks.read")

      for perm <- perms("tasks"), r <- [nil | ctx.resources] do
        refute Access.can?(locked, perm, r), "#{perm} on #{inspect(r)} must be refused"
      end

      assert Access.permitted(locked, "tasks.read", :task).allow == []
      assert Access.granted(locked, "tasks.read", :task).allow == []
      refute Access.within?(locked, "tasks.read", {:task, ctx.t.id}, true)
      assert Access.check(locked, "tasks.read", {:task, ctx.t.id}) == {:error, :denied}
      assert Access.authorize(locked, "tasks.read", {:task, ctx.t.id}) == {:error, :unauthorized}
      assert Access.locked?(locked, "tasks.read")
      assert Access.module_locked?(locked, "tasks")
      refute Access.module_locked?(locked, "files")
    end

    test "Query refuses every row of a locked permission (where: false)", ctx do
      query = from(t in Task, where: t.id == ^ctx.t.id, select: t.id)

      # Positive control: an unlocked member reads T through each form.
      for sc <- [scope(ctx.u), scope(ctx.v)] do
        assert Repo.all(Query.restrict(query, sc, "tasks.read", :task, %{id: :id})) == [ctx.t.id]

        assert Repo.all(Query.where_readable(query, sc, "tasks.read", :task, %{id: :id})) == [
                 ctx.t.id
               ]
      end

      lock!({:user, ctx.u.id}, "tasks", ctx.s)
      locked = scope(ctx.u)

      assert Repo.all(Query.restrict(query, locked, "tasks.read", :task, %{id: :id})) == []
      assert Repo.all(Query.where_readable(query, locked, "tasks.read", :task, %{id: :id})) == []
      assert Repo.all(Query.where_permitted(query, locked, "tasks.read", :task, %{id: :id})) == []
      assert Tasks.list_all_tasks(access_scope: locked) |> Enum.map(& &1.id) == []

      # The unlocked member is unchanged.
      assert ctx.t.id in Enum.map(Tasks.list_all_tasks(access_scope: scope(ctx.v)), & &1.id)
    end

    test "holds_anywhere? and module_access? are false for the module", ctx do
      before = scope(ctx.u)
      assert Access.holds_anywhere?(before, "files.read")
      assert Access.module_access?(before, :files)
      assert Access.module_access?(before, :tasks)

      lock!({:user, ctx.u.id}, "files", ctx.s)
      lock!({:user, ctx.u.id}, "tasks", ctx.s)
      locked = scope(ctx.u)

      for perm <- perms("files") ++ perms("tasks"),
          do: refute(Access.holds_anywhere?(locked, perm), perm)

      refute Access.module_access?(locked, :files)
      refute Access.module_access?(locked, :tasks)
      assert Access.module_access?(locked, :chat)
    end

    test "every other module's answers are unchanged", ctx do
      before = answers(scope(ctx.u), ctx.resources)
      lock!({:user, ctx.u.id}, "files", ctx.s)
      after_lock = answers(scope(ctx.u), ctx.resources)

      files = perms("files")

      changed =
        for {key, value} <- after_lock, Map.fetch!(before, key) != value, do: key

      assert changed != []

      files_answer? = fn
        {:rail, key} -> key == :files
        {:anywhere, p} -> p in files
        {p, _resource} -> p in files
      end

      for key <- changed,
          do: assert(files_answer?.(key), "#{inspect(key)} changed but is not a files answer")
    end

    test "an unlocked user's answers are unchanged by another user's lock", ctx do
      before = answers(scope(ctx.v), ctx.resources)
      lock!({:user, ctx.u.id}, "files", ctx.s)
      lock!({:user, ctx.u.id}, "tasks", ctx.s)
      assert answers(scope(ctx.v), ctx.resources) == before
    end
  end

  describe "a role-principal lock" do
    test "applies to holders of that role in that org only", ctx do
      control_rm = answers(scope(ctx.rm), ctx.resources)
      control_a = answers(scope(ctx.a), ctx.resources)
      assert Access.module_access?(scope(ctx.u), :files)

      lock!({:role, "member"}, "files", ctx.s)

      # S members are locked.
      refute Access.module_access?(scope(ctx.u), :files)
      refute Access.module_access?(scope(ctx.v), :files)
      refute Access.can?(scope(ctx.u), "files.read", {:project, ctx.p.id})

      # S's admin (role admin) and R's member (member of another org) are not.
      assert answers(scope(ctx.a), ctx.resources) == control_a
      assert answers(scope(ctx.rm), ctx.resources) == control_rm
      assert Access.module_access?(scope(ctx.rm), :files)
    end
  end

  describe "undo" do
    test "Changes.undo/3 restores exactly the pre-lock answers", ctx do
      before = answers(scope(ctx.u), ctx.resources)

      grant = lock!({:user, ctx.u.id}, "tasks", ctx.s)
      assert answers(scope(ctx.u), ctx.resources) != before

      [change] = Changes.list_changes(ctx.s, tuple_key: Grant.tuple_key(grant))
      assert {:ok, _} = Changes.undo(change.id, Scope.system())

      assert Repo.get(Grant, grant.id) == nil
      assert answers(scope(ctx.u), ctx.resources) == before
    end

    test "undo by S's admin (an unlock) is authorized and restores the module", ctx do
      grant = lock!({:user, ctx.u.id}, "files", ctx.s, actor: scope(ctx.a))
      refute Access.module_access?(scope(ctx.u), :files)

      [change] = Changes.list_changes(ctx.s, tuple_key: Grant.tuple_key(grant))
      assert {:ok, _} = Changes.undo(change.id, scope(ctx.a))
      assert Access.module_access?(scope(ctx.u), :files)
    end
  end

  # ── writes ──────────────────────────────────────────────────────────────

  describe "the row" do
    test "is stored with resource_id and org_id both the org", ctx do
      grant = lock!({:user, ctx.u.id}, "files", ctx.s)

      assert %Grant{
               resource_type: "module",
               resource_id: rid,
               org_id: oid,
               permission: "files",
               effect: "deny"
             } = Repo.get!(Grant, grant.id)

      assert rid == ctx.s and oid == ctx.s
      assert Grant.target(grant) == {:module, ctx.s}
      assert Grant.module_lock?(grant)
    end

    test "snapshot -> from_snapshot -> insert round-trips the row losslessly", ctx do
      grant = Repo.get!(Grant, lock!({:user, ctx.u.id}, "files", ctx.s).id)
      snap = Grant.snapshot(grant)
      key = Grant.tuple_key(snap)

      assert key == Enum.join(["user", ctx.u.id, "files", "module", ctx.s], "|")

      Repo.delete!(grant)
      {1, _} = Repo.insert_all(Grant, [Grant.from_snapshot(snap)])

      restored = Repo.get!(Grant, grant.id)
      assert restored == grant
      assert Grant.snapshot(restored) == snap
      assert Grant.tuple_key(restored) == key
    end

    test "an allow on a module is refused by grant/2, apply_ops/2, the changeset and the CHECK",
         ctx do
      n = counts()
      attrs = %{principal: {:user, ctx.u.id}, permission: "files", resource: {:module, ctx.s}}

      assert Grants.grant(attrs) == {:error, :module_allow_refused}

      assert Grants.apply_ops([Map.put(attrs, :action, "grant")], actor: Scope.system()) ==
               {:error, :module_allow_refused}

      cs =
        Grant.changeset(%Grant{}, %{
          org_id: ctx.s,
          principal_type: "user",
          principal_id: ctx.u.id,
          permission: "files",
          resource_type: "module",
          resource_id: ctx.s,
          effect: "allow"
        })

      refute cs.valid?
      assert cs.errors[:effect]
      assert counts() == n

      # Last: a raw insert past the changeset hits the CHECK.
      assert_raise Postgrex.Error, ~r/access_grants_module_deny_check/, fn ->
        Repo.insert_all(Grant, [
          [
            id: Ecto.UUID.generate(),
            org_id: ctx.s,
            principal_type: "user",
            principal_id: ctx.u.id,
            permission: "files",
            resource_type: "module",
            resource_id: ctx.s,
            effect: "allow",
            inserted_at: DateTime.utc_now()
          ]
        ])
      end
    end

    test "access, install, orgs, mcp and a module.action name are not lockable", ctx do
      n = counts()

      for module <- ~w(access install orgs mcp tasks.read nonsense) do
        assert {:error, %Ecto.Changeset{} = cs} =
                 Grants.deny(%{
                   principal: {:user, ctx.u.id},
                   permission: module,
                   resource: {:module, ctx.s}
                 })

        assert cs.errors[:permission], module
      end

      assert counts() == n
      refute "access" in Grant.lockable_modules()
      assert "files" in Grant.lockable_modules()
      assert "tasks" in Grant.lockable_modules()
    end

    test "a lock naming another org than its row's is refused", ctx do
      assert {:error, %Ecto.Changeset{} = cs} =
               Grants.deny(%{
                 principal: {:user, ctx.u.id},
                 permission: "files",
                 resource: {:module, ctx.s},
                 org_id: ctx.root
               })

      assert cs.errors[:resource_id]

      assert Grants.deny(%{
               principal: {:user, ctx.u.id},
               permission: "files",
               resource: {:module, Ecto.UUID.generate()}
             }) == {:error, :resource_not_found}
    end
  end

  describe "delegation" do
    test "S's admin locks an S member; the change is ledgered", ctx do
      grant = lock!({:user, ctx.u.id}, "files", ctx.s, actor: scope(ctx.a))

      assert [%Change{action: "deny", actor_id: actor_id}] =
               Changes.list_changes(ctx.s, tuple_key: Grant.tuple_key(grant))

      assert actor_id == ctx.a.id
    end

    test "a non-manager is refused with nothing written", ctx do
      n = counts()

      assert {:error, %{rule: :not_granted, missing: "access.manage"}} =
               Grants.deny(
                 %{principal: {:user, ctx.u.id}, permission: "files", resource: {:module, ctx.s}},
                 actor: scope(ctx.v)
               )

      assert counts() == n
    end

    test "S's admin cannot lock a user who is not a member of S; a root admin can", ctx do
      n = counts()
      attrs = %{principal: {:user, ctx.rm.id}, permission: "files", resource: {:module, ctx.s}}

      assert {:error, %{rule: :org_mismatch}} = Grants.deny(attrs, actor: scope(ctx.a))
      assert counts() == n

      assert {:ok, _} = Grants.deny(attrs, actor: scope(root_admin!()))
    end

    test "unlocking widens: an admin locked out of the module cannot unlock it", ctx do
      grant = lock!({:user, ctx.u.id}, "files", ctx.s, actor: scope(ctx.a))
      lock!({:user, ctx.a.id}, "files", ctx.s)
      n = counts()

      assert {:error, %{rule: :beyond_held, missing: "files." <> _}} =
               Grants.revoke(grant, actor: scope(ctx.a))

      assert counts() == n

      # Positive control: an unlocked admin of S may unlock.
      other_admin = in_org!(ctx.s, "admin", "a2")
      assert {:ok, _} = Grants.revoke(grant, actor: scope(other_admin))
      assert Access.module_access?(scope(ctx.u), :files)
    end
  end

  describe "no crash in the readers" do
    test "Lineage, applicable/2, Effective and the explain path", ctx do
      lock!({:user, ctx.u.id}, "files", ctx.s)
      locked = scope(ctx.u)

      assert Lineage.typed({:module, ctx.s}) == :untyped
      assert Enum.any?(locked.grants, &(&1.permission == "files"))

      # applicable/2 excludes module rows: even asked for the module NAME
      # the row carries, no grant applies.
      refute Access.grants_apply?(locked, "files")
      refute Access.grants_apply?(locked, "files.read")

      assert {:ok, lines} = Effective.lines(scope(root_admin!()), {:user, ctx.u.id})
      assert is_list(lines)
    end

    test "Impact previews a lock as the module going away", ctx do
      ops = [
        %{
          action: "deny",
          principal: {:user, ctx.u.id},
          permission: "files",
          resource: {:module, ctx.s}
        }
      ]

      assert {:ok, %{loses: loses}} = Platform.Access.Impact.diff(Scope.system(), ops)

      assert Enum.any?(
               loses,
               &(&1.id == ctx.u.id and &1.permission == "files" and &1.resource.type == "module")
             )

      assert Repo.aggregate(from(g in Grant, where: g.resource_type == "module"), :count) == 0
    end
  end

  describe "a runtime" do
    test "a runtime whose owner is locked is locked", ctx do
      rt =
        Platform.RuntimeProfileFixtures.runtime!(ctx.u.id, [
          "task" | Platform.Agents.AgentRuntime.default_tool_profile()
        ])

      assert Access.holds_anywhere?(Scope.for_runtime(rt), "tasks.read")

      lock!({:user, ctx.u.id}, "tasks", ctx.s)
      capped = Scope.for_runtime(rt)
      refute Access.holds_anywhere?(capped, "tasks.read")
      refute Access.can?(capped, "tasks.read", {:task, ctx.t.id})
      assert Access.check(capped, "tasks.read", {:task, ctx.t.id}) == {:error, :denied}
    end
  end
end
