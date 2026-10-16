defmodule Platform.Access.DelegationTest do
  @moduledoc """
  Task 01a1386e-30bd stage 2 (RBAC stack member 6): delegation.
  `Platform.Access.Delegation` decides who may change a grant, and
  `Platform.Access.Changes` runs it inside every non-system change.

  Every refusal is paired with its succeeding half on the same fixture, and
  every refusal asserts that NO row was added to `access_grants` or
  `access_grant_changes`.

  The fixture org is a fresh tenant org with no members of its own, so a
  project in it has no role-rule manager: its managers are exactly the
  explicit `access.manage` holders the test creates (the root admin manages
  it only through the bypass, which does not count).
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Change, Changes, Delegation, Grant, Grants, RuntimeProfiles, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat.{Canvas, Participant, Space}
  alias Platform.Repo
  alias Platform.SignInAdmin
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    root = acme_org_id()
    org = tenant_org_id("deleg-#{uniq()}")
    other = tenant_org_id("deleg-other-#{uniq()}")

    p = project!(org)
    q = project!(org)
    task = Repo.insert!(%Task{project_id: p.id, title: "deleg task", status: "backlog"})
    exec = space!("execution", org, %{"task_id" => task.id})
    canvas = canvas!(exec)

    r = admin_in!(root)

    # PA: a guest-role user holding explicit allows on P only.
    pa = guest!(org)
    for perm <- ~w(access.manage tasks.read chat.read), do: system_grant!(pa, perm, p)

    %{
      root: root,
      org: org,
      other: other,
      p: p,
      q: q,
      exec: exec,
      canvas: canvas,
      r: r,
      pa: pa,
      u: user!("u")
    }
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive])

  defp user!(tag) do
    n = uniq()

    Repo.insert!(%User{
      email: "deleg-#{tag}-#{n}@example.com",
      name: "Deleg #{tag} #{n}",
      oidc_sub: "deleg-#{tag}-#{n}"
    })
  end

  defp membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org, role: role})
    |> Repo.insert!()

    user
  end

  defp admin_in!(org), do: membership!(user!("admin"), org, "admin")

  defp guest!(org) do
    u = user!("guest")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: u.id, org_id: org})
    u
  end

  defp project!(org) do
    {:ok, p} = Tasks.create_project(%{name: "deleg-#{uniq()}", org_id: org})
    p
  end

  defp space!(kind, org, metadata) do
    n = uniq()

    %Space{}
    |> Space.changeset(%{
      kind: kind,
      name: "deleg-#{kind}-#{n}",
      slug: "deleg-#{kind}-#{n}",
      org_id: org,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp canvas!(space) do
    author =
      Repo.insert!(%Participant{
        space_id: space.id,
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        role: "member",
        joined_at: DateTime.utc_now()
      })

    Repo.insert!(%Canvas{space_id: space.id, created_by: author.id, title: "deleg canvas"})
  end

  defp system_grant!(principal, permission, resource) do
    {:ok, grant} =
      Grants.grant(%{principal: principal, permission: permission, resource: resource})

    grant
  end

  defp scope(%User{id: id}), do: Scope.for_user(Accounts.get_user(id))

  defp counts, do: {Repo.aggregate(Grant, :count), Repo.aggregate(Change, :count)}

  defp last_change, do: Repo.one(from(c in Change, order_by: [desc: c.id], limit: 1))

  # A refusal: the call returns the denial and adds no row to either table.
  defp refused(fun) do
    before = counts()
    assert {:error, %{rule: rule} = denial} = fun.()
    assert counts() == before, "a refused change wrote a row"
    {rule, denial}
  end

  # A success: exactly one grant-table delta and one change row.
  defp succeeded(fun) do
    {_, changes} = counts()
    assert {:ok, result} = fun.()
    assert Repo.aggregate(Change, :count) == changes + 1
    result
  end

  defp grant_as(actor, principal, permission, resource, extra \\ %{}) do
    Grants.grant(
      Map.merge(%{principal: principal, permission: permission, resource: resource}, extra),
      actor: scope_of(actor)
    )
  end

  defp deny_as(actor, principal, permission, resource) do
    Grants.deny(%{principal: principal, permission: permission, resource: resource},
      actor: scope_of(actor)
    )
  end

  defp scope_of(%Scope{} = s), do: s
  defp scope_of(%User{} = u), do: scope(u)

  # ── project admin PA ────────────────────────────────────────────────────

  describe "a project admin's reach is bounded by access.manage on the resource" do
    test "granting on P succeeds; granting on Q is refused with zero rows", ctx do
      %{pa: pa, u: u, p: p, q: q} = ctx

      grant = succeeded(fn -> grant_as(pa, u, "tasks.read", p) end)
      assert grant.resource_id == p.id
      assert %Change{actor_type: "user", bypass: nil, action: "grant"} = last_change()
      assert last_change().actor_id == pa.id

      assert {:not_granted, denial} = refused(fn -> grant_as(pa, u, "tasks.read", q) end)
      assert denial == %{missing: "access.manage", resource: {:project, q.id}, rule: :not_granted}
    end

    test "granting on P's execution space and its canvas succeeds (inherited downward)", ctx do
      %{pa: pa, u: u, exec: exec, canvas: canvas} = ctx

      assert succeeded(fn -> grant_as(pa, u, "chat.read", exec) end).resource_id == exec.id
      assert succeeded(fn -> grant_as(pa, u, "chat.read", canvas) end).resource_id == canvas.id
    end

    test "granting a permission PA does not hold on P is refused as beyond held", ctx do
      %{pa: pa, u: u, p: p} = ctx

      refute Access.can?(scope(pa), "canvas.read", {:project, p.id})

      assert {:beyond_held, denial} = refused(fn -> grant_as(pa, u, "canvas.read", p) end)
      assert denial.missing == "canvas.read"

      # Succeeding half: once PA holds it, PA may grant it.
      system_grant!(pa, "canvas.read", p)
      succeeded(fn -> grant_as(pa, u, "canvas.read", p) end)
    end

    test "PA may grant access.manage itself on P, never on Q", ctx do
      %{pa: pa, u: u, p: p, q: q} = ctx

      succeeded(fn -> grant_as(pa, u, "access.manage", p) end)
      assert {:not_granted, _} = refused(fn -> grant_as(pa, u, "access.manage", q) end)
    end

    test "a deny on P succeeds without holding p; revoking a deny PA could not grant is refused",
         ctx do
      %{pa: pa, u: u, p: p, r: r} = ctx

      # A deny narrows: access.manage alone suffices, even for a permission
      # PA does not hold on P.
      refute Access.can?(scope(pa), "canvas.read", {:project, p.id})
      deny = succeeded(fn -> deny_as(pa, u, "canvas.read", p) end)

      # Revoking that deny WIDENS access: checked like an allow.
      assert {:beyond_held, denial} =
               refused(fn -> Grants.revoke(deny, actor: scope(pa)) end)

      assert denial.missing == "canvas.read"

      # Succeeding halves: a deny on a permission PA holds may be revoked by
      # PA, and the canvas.read deny by the root admin.
      tasks_deny = succeeded(fn -> deny_as(pa, user!("v"), "tasks.read", p) end)
      succeeded(fn -> Grants.revoke(tasks_deny, actor: scope(pa)) end)
      succeeded(fn -> Grants.revoke(deny, actor: scope(r)) end)
    end

    test "revoking an allow needs access.manage only", ctx do
      %{pa: pa, u: u, p: p, q: q} = ctx

      on_p = system_grant!(u, "canvas.read", p)
      on_q = system_grant!(u, "canvas.read", q)

      succeeded(fn -> Grants.revoke(on_p, actor: scope(pa)) end)
      assert {:not_granted, _} = refused(fn -> Grants.revoke(on_q, actor: scope(pa)) end)
    end
  end

  describe "nothing flows upward" do
    test "a space-only manager manages the space and not its project", ctx do
      %{org: org, u: u, p: p, exec: exec} = ctx
      ps = guest!(org)
      system_grant!(ps, "access.manage", exec)
      system_grant!(ps, "chat.read", exec)

      succeeded(fn -> grant_as(ps, u, "chat.read", exec) end)

      assert {:not_granted, denial} = refused(fn -> grant_as(ps, u, "chat.read", p) end)
      assert denial.resource == {:project, p.id}
    end
  end

  describe "an org admin manages the org's resources through the role rule" do
    test "an internal admin of the org manages P; not a project of another org", ctx do
      %{org: org, other: other, u: u, p: p} = ctx
      a = admin_in!(org)
      elsewhere = project!(other)

      succeeded(fn -> grant_as(a, u, "tasks.read", p) end)
      assert {:not_granted, _} = refused(fn -> grant_as(a, u, "tasks.read", elsewhere) end)
    end
  end

  describe "org binding" do
    test "a role principal bound to another org is refused; bound to R's org it succeeds",
         ctx do
      %{pa: pa, p: p, org: org, other: other} = ctx

      assert {:org_mismatch, _} =
               refused(fn ->
                 grant_as(pa, {:role, "member"}, "chat.read", p, %{org_id: other})
               end)

      grant = succeeded(fn -> grant_as(pa, {:role, "member"}, "chat.read", p) end)
      assert grant.org_id == org
    end

    test "the root admin is bound too", ctx do
      %{r: r, u: u, p: p, other: other} = ctx

      assert {:org_mismatch, _} =
               refused(fn -> grant_as(r, u, "tasks.read", p, %{org_id: other}) end)

      succeeded(fn -> grant_as(r, u, "tasks.read", p) end)
    end
  end

  describe "root admin" do
    test "is authorized for any change, recorded as the root_admin bypass", ctx do
      %{r: r, root: root, u: u, q: q} = ctx

      # Positive control: R holds no access.manage on Q (another org).
      refute Access.can?(scope(r), "access.manage", {:project, q.id})
      assert Delegation.root_admin?(scope(r))

      succeeded(fn -> grant_as(r, u, "tasks.read", q) end)
      assert %Change{bypass: "root_admin", actor_type: "user"} = last_change()

      # Succeeding half's refusal: a plain member of the root org is not.
      m = membership!(user!("m"), root, "member")
      refute Delegation.root_admin?(scope(m))
      assert {:not_granted, _} = refused(fn -> grant_as(m, u, "chat.read", q) end)
    end

    test "an org admin's own change records no bypass", ctx do
      %{org: org, u: u, p: p} = ctx
      a = admin_in!(org)

      succeeded(fn -> grant_as(a, u, "tasks.read", p) end)
      assert last_change().bypass == nil
    end
  end

  # ── the last-manager guard ──────────────────────────────────────────────

  describe "the last manager cannot be removed" do
    test "SignInAdmin refuses demoting the sole org admin, then permits it with a second admin",
         ctx do
      %{root: root, r: r} = ctx

      # `tenant_org_id/1` seeds a throwaway root admin to create each org.
      # Remove those fixture memberships so R is the sole manager here.
      Repo.delete_all(from(m in OrgMembership, where: m.org_id == ^root and m.user_id != ^r.id))

      for {key, value} <- [
            sign_in_admin_enabled: true,
            sign_in_admin_url: "http://pocket-id.test",
            sign_in_admin_api_key: "test-key"
          ] do
        previous = Application.fetch_env(:platform, key)

        on_exit(fn ->
          case previous do
            {:ok, old} -> Application.put_env(:platform, key, old)
            :error -> Application.delete_env(:platform, key)
          end
        end)

        Application.put_env(:platform, key, value)
      end

      assert Enum.map(Delegation.managers({:org, root}), & &1.id) == [r.id]

      # The private set_role/3 is reached by restoring an archived admin
      # through Invite. Relink unarchives R before the role step.
      Repo.update_all(
        from(u in User, where: u.id == ^r.id),
        set: [archived_at: DateTime.utc_now()]
      )

      Req.Test.stub(Platform.SignInAdmin.PocketId, fn conn ->
        case {conn.method, conn.path_info} do
          {"POST", ["api", "users"]} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            user = Jason.decode!(body) |> Map.put("id", "pid-restored")
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(user)

          {"DELETE", ["api", "users", _]} ->
            Plug.Conn.resp(conn, 204, "")

          {"POST", ["api", "users", _, "one-time-access-token"]} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => "test-token"})
        end
      end)

      assert {:error, %{rule: :last_admin, resource: {:org, ^root}}} =
               SignInAdmin.invite(r, %{email: r.email, role: :member})

      second = admin_in!(root)

      assert {:ok, %{user: restored}} =
               SignInAdmin.invite(second, %{email: r.email, role: :member})

      membership = Repo.get_by!(OrgMembership, org_id: root, user_id: restored.id)
      assert membership.role == "member"
    end

    test "revoking P's only manager is refused; with a second manager it succeeds", ctx do
      %{org: org, p: p, r: r} = ctx
      p2 = project!(org)
      pm = guest!(org)
      only = system_grant!(pm, "access.manage", p2)

      assert Enum.map(Delegation.managers({:project, p2.id}), & &1.id) == [pm.id]

      assert {:last_admin, denial} = refused(fn -> Grants.revoke(only, actor: scope(r)) end)
      assert denial == %{missing: "access.manage", resource: {:project, p2.id}, rule: :last_admin}

      pm2 = guest!(org)
      system_grant!(pm2, "access.manage", p2)
      succeeded(fn -> Grants.revoke(only, actor: scope(r)) end)

      # P itself was never touched.
      assert Enum.map(Delegation.managers({:project, p.id}), & &1.id) == [ctx.pa.id]
    end

    test "a deny of access.manage on P against P's only manager is refused", ctx do
      %{org: org, r: r, pa: pa, p: p} = ctx

      # PA (a guest) is P's only manager; a deny on the guest role reaches PA.
      assert Enum.map(Delegation.managers({:project, p.id}), & &1.id) == [pa.id]

      assert {:last_admin, _} =
               refused(fn -> deny_as(r, {:role, "guest"}, "access.manage", p) end)

      assert Access.can?(scope(pa), "access.manage", {:project, p.id})

      # Succeeding half: a member-role manager survives the guest deny.
      keeper = membership!(user!("keeper"), org, "member")
      system_grant!(keeper, "access.manage", p)

      succeeded(fn -> deny_as(r, {:role, "guest"}, "access.manage", p) end)
      refute Access.can?(scope(pa), "access.manage", {:project, p.id})
      assert Enum.map(Delegation.managers({:project, p.id}), & &1.id) == [keeper.id]
    end

    test "an undo that would remove the last manager is refused", ctx do
      %{org: org, r: r} = ctx
      p2 = project!(org)
      pm = guest!(org)

      # P2 has no manager; R makes PM its first. Zero → one is not guarded.
      assert Delegation.managers({:project, p2.id}) == []
      succeeded(fn -> grant_as(r, pm, "access.manage", p2) end)
      x = last_change()

      assert {:last_admin, _} = refused(fn -> Changes.undo(x.id, scope(r)) end)

      # Succeeding half: with a second manager, the same undo goes through.
      pm2 = guest!(org)
      system_grant!(pm2, "access.manage", p2)

      assert {:ok, %{change: %Change{action: "undo", bypass: "root_admin"}}} =
               Changes.undo(x.id, scope(r))
    end

    test "a change to another permission never runs the guard", ctx do
      %{org: org, r: r} = ctx
      p2 = project!(org)
      u = user!("w")

      # P2 has no manager at all: a tasks.read grant on it is not a
      # last-manager question.
      assert Delegation.managers({:project, p2.id}) == []
      g = succeeded(fn -> grant_as(r, u, "tasks.read", p2) end)
      succeeded(fn -> Grants.revoke(g, actor: scope(r)) end)
    end
  end

  describe "undo is authorized as its inverse change" do
    test "PA may undo its own grant on P; PA may not undo the root admin's grant on Q", ctx do
      %{pa: pa, r: r, u: u, p: p, q: q} = ctx

      succeeded(fn -> grant_as(pa, u, "tasks.read", p) end)
      on_p = last_change()
      succeeded(fn -> grant_as(r, u, "tasks.read", q) end)
      on_q = last_change()

      # Undoing a grant removes an allow: access.manage on its resource.
      assert {:not_granted, _} = refused(fn -> Changes.undo(on_q.id, scope(pa)) end)
      assert {:ok, %{change: %Change{action: "undo"}}} = Changes.undo(on_p.id, scope(pa))
    end

    test "undoing a revoked deny is a widening only when it removes a deny", ctx do
      %{pa: pa, r: r, u: u, p: p} = ctx

      # R denies U canvas.read on P; PA undoing that deny REMOVES a deny,
      # which widens, and PA does not hold canvas.read on P.
      succeeded(fn -> deny_as(r, u, "canvas.read", p) end)
      deny_change = last_change()

      assert {:beyond_held, _} = refused(fn -> Changes.undo(deny_change.id, scope(pa)) end)

      # Succeeding half: the same shape on a permission PA holds.
      succeeded(fn -> deny_as(r, u, "tasks.read", p) end)
      assert {:ok, _} = Changes.undo(last_change().id, scope(pa))
    end
  end

  # ── agents ──────────────────────────────────────────────────────────────

  describe "an agent actor is checked against its owner-capped for_runtime/1 scope" do
    test "an explicit agent allow cannot outlive its owner's matching allow", ctx do
      %{u: u, p: p, pa: pa} = ctx
      runtime = runtime!(pa)

      # Inherit from PA: the positive control succeeds before changing either
      # actor's grant.
      assert Access.can?(Scope.for_runtime(runtime), "access.manage", {:project, p.id})
      assert Access.can?(Scope.for_runtime(runtime), "tasks.read", {:project, p.id})
      succeeded(fn -> grant_as(Scope.for_runtime(runtime), u, "tasks.read", p) end)

      owner_grant =
        Repo.get_by!(Grant,
          principal_type: "user",
          principal_id: pa.id,
          permission: "tasks.read",
          resource_type: "project",
          resource_id: p.id
        )

      assert {:ok, _} = Grants.revoke(owner_grant)
      system_grant!({:agent, runtime.agent_id}, "tasks.read", p)
      agent_scope = Scope.for_runtime(runtime)
      assert Access.can?(agent_scope, "access.manage", {:project, p.id})
      refute Access.can?(agent_scope, "tasks.read", {:project, p.id})

      next_user = user!("agent-target")

      assert {:beyond_held, _} =
               refused(fn -> grant_as(agent_scope, next_user, "tasks.read", p) end)

      system_grant!(pa, "tasks.read", p)
      succeeded(fn -> grant_as(Scope.for_runtime(runtime), next_user, "tasks.read", p) end)
      assert %Change{actor_type: "agent"} = last_change()
      assert last_change().actor_id == runtime.agent_id
    end
  end

  defp runtime!(owner) do
    n = uniq()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "deleg-agent-#{n}", name: "Deleg agent #{n}", status: "active"})
      |> Repo.insert()

    {:ok, rt} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "deleg-rt-#{n}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
        status: "active"
      })
      |> Repo.insert()

    {:ok, _profile} =
      RuntimeProfiles.create_for_runtime(rt, AgentRuntime.default_tool_profile(), nil)

    rt
  end

  # ── system and operator paths ───────────────────────────────────────────

  describe "the operator paths" do
    test "Scope.system/0 is not delegated: it changes a grant on any resource", ctx do
      %{u: u, q: q} = ctx
      assert Delegation.authorize(Scope.system(), %{added: [], removed: []}) == :ok
      system_grant!(u, "tasks.read", q)
      assert last_change().actor_type == "system"
    end

    # The plan named `SignInAdmin.set_role(user, :member, actor)` as a human
    # demotion path to guard. Measured on this base it is not one: it is a
    # PRIVATE helper called only from the invite flow, and the only demotion
    # code is the raw operator `Tenancy.revoke_admin/2` (and
    # `set_membership_role/3`), deliberately unguarded. This pins that no
    # other module calls either, so a human- or agent-facing demotion path
    # cannot appear without failing here (and getting the guard).
    test "no human- or agent-facing module calls the org-role demotion functions" do
      lib = Path.expand("../../../lib", __DIR__)
      pattern = ~r/\b(revoke_admin|set_membership_role|set_managed_role)\(/

      callers =
        Path.wildcard(Path.join(lib, "**/*.{ex,heex}"))
        |> Enum.filter(&Regex.match?(pattern, File.read!(&1)))
        |> Enum.map(&Path.relative_to(&1, lib))
        |> Enum.sort()

      # Positive control: the scan finds the definitions.
      assert "platform/tenancy.ex" in callers
      assert callers == ["platform/sign_in_admin.ex", "platform/tenancy.ex"]
      refute Enum.any?(callers, &String.starts_with?(&1, "platform_web/"))

      # SignInAdmin's only route to it is the private invite helper.
      refute function_exported?(SignInAdmin, :set_role, 3)
      source = File.read!(Path.join(lib, "platform/sign_in_admin.ex"))
      assert length(Regex.scan(~r/\bset_role\(/, source)) == 3
      assert source =~ "case set_role(user, role, actor) do"
    end
  end
end
