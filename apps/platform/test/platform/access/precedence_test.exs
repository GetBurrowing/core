defmodule Platform.Access.PrecedenceTest do
  @moduledoc """
  Task 01a1386d-e528 stage 2: explicit grants, inheritance and deny-wins
  precedence in `Platform.Access.can?/3`, against the worked examples of
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`.

  Every refusal that matters is preceded by its positive control on the
  same fixture: the same call answering `true` before the deny exists.
  Example (b) is the deny part only; capping is stack position 5.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Grant, Grants, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.{Canvas, Participant, Space}
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Node, NodePath}
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{CanvasAttachment, Task}
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── fixtures ────────────────────────────────────────────────────────────

  setup do
    Repo.delete_all(NodePath)
    Repo.delete_all(Node)
    Repo.delete_all(WikiPage)
    _root = acme_org_id()
    org = tenant_org_id("sxi")
    %{org: org}
  end

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "prec-#{tag}-#{n}@example.com",
      name: "Prec #{tag} #{n}",
      oidc_sub: "prec-#{tag}-#{n}"
    })
  end

  defp guest!(org) do
    u = user!("guest")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: u.id, org_id: org})
    u
  end

  defp member!(org) do
    u = user!("member")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: u.id, org_id: org, role: "member"})
    |> Repo.insert!()

    u
  end

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp project!(org) do
    {:ok, p} =
      Tasks.create_project(%{name: "prec-#{System.unique_integer([:positive])}", org_id: org})

    p
  end

  defp task!(project), do: Repo.insert!(%Task{project_id: project.id, title: "prec task"})

  defp space!(kind, org, metadata \\ %{}) do
    n = System.unique_integer([:positive])

    %Space{}
    |> Space.changeset(%{
      kind: kind,
      name: "prec-#{kind}-#{n}",
      slug: "prec-#{kind}-#{n}",
      org_id: org,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp exec_space!(task, org), do: space!("execution", org, %{"task_id" => task.id})

  # `chat_canvases.created_by` references `chat_participants`: the author
  # is a participant row with no real user behind it, so no fixture user
  # gains participation by creating a canvas.
  defp canvas!(space, _author) do
    author =
      Repo.insert!(%Participant{
        space_id: space.id,
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        role: "member",
        joined_at: DateTime.utc_now()
      })

    Repo.insert!(%Canvas{space_id: space.id, created_by: author.id, title: "prec canvas"})
  end

  defp attach!(task, canvas) do
    Repo.insert!(%CanvasAttachment{
      task_id: task.id,
      canvas_id: canvas.id,
      attached_by_kind: "user",
      attached_by_id: Ecto.UUID.generate()
    })
  end

  defp ok!({:ok, value}), do: value

  # ── worked examples ─────────────────────────────────────────────────────

  describe "example (a): a deny on project P beats a direct allow on an execution space of P" do
    test "the direct allow alone permits; adding the deny on P refuses", %{org: org} do
      u = guest!(org)
      p = project!(org)
      c = exec_space!(task!(p), org)

      refute Access.can?(scope(u), "chat.read", {:space, c.id}),
             "fixture: a guest is not a participant of C, so no role rule reads it"

      ok!(Grants.grant(%{principal: u, permission: "chat.read", resource: {:space, c.id}}))
      assert Access.can?(scope(u), "chat.read", {:space, c.id})
      assert Access.can?(scope(u), "chat.read", c)

      ok!(Grants.deny(%{principal: u, permission: "chat.read", resource: {:project, p.id}}))
      refute Access.can?(scope(u), "chat.read", {:space, c.id})
      refute Access.can?(scope(u), "chat.read", c)
    end

    test "a deny refuses only its own permission", %{org: org} do
      u = guest!(org)
      p = project!(org)
      c = exec_space!(task!(p), org)

      ok!(Grants.grant(%{principal: u, permission: "chat.read", resource: {:space, c.id}}))
      ok!(Grants.deny(%{principal: u, permission: "tasks.read", resource: {:project, p.id}}))

      assert Access.can?(scope(u), "chat.read", {:space, c.id})
    end
  end

  describe "example (b), deny part: an allow on project X and a deny on canvas K in X" do
    test "K is refused, the other canvases in X stay readable", %{org: org} do
      u = guest!(org)
      author = member!(org)
      x = project!(org)
      t = task!(x)
      space = exec_space!(t, org)
      k = canvas!(space, author)
      k2 = canvas!(space, author)
      attached = canvas!(space!("channel", org), author)
      attach!(t, attached)
      outside = canvas!(space!("channel", org), author)

      for c <- [k, k2, attached],
          do: refute(Access.can?(scope(u), "canvas.read", {:canvas, c.id}))

      ok!(Grants.grant(%{principal: u, permission: "canvas.read", resource: {:project, x.id}}))
      s = scope(u)

      for c <- [k, k2, attached],
          do: assert(Access.can?(s, "canvas.read", {:canvas, c.id}), "control: #{c.id}")

      refute Access.can?(s, "canvas.read", {:canvas, outside.id})

      ok!(Grants.deny(%{principal: u, permission: "canvas.read", resource: {:canvas, k.id}}))
      s = scope(u)

      refute Access.can?(s, "canvas.read", {:canvas, k.id})
      refute Access.can?(s, "canvas.read", k)
      assert Access.can?(s, "canvas.read", {:canvas, k2.id})
      assert Access.can?(s, "canvas.read", {:canvas, attached.id})
    end

    test "a deny on a space covers its canvases (the ADR's space-to-canvas edge)", %{org: org} do
      u = member!(org)
      channel = space!("channel", org)
      k = canvas!(channel, u)

      assert Access.can?(scope(u), "canvas.read", {:canvas, k.id}),
             "control: a member reads canvases in its org through membership_org"

      ok!(Grants.deny(%{principal: u, permission: "canvas.read", resource: {:space, channel.id}}))
      refute Access.can?(scope(u), "canvas.read", {:canvas, k.id})
    end
  end

  describe "example (c): a memory subtree grant follows a prefix rename" do
    test "the allow and the child deny move with their nodes; the old path holds nothing",
         %{org: org} do
      u = guest!(org)
      {:ok, _} = Wiki.upsert_page("org/page/eng/x.md", %{content: "x"})
      {:ok, _} = Wiki.upsert_page("org/page/eng/secret/plan.md", %{content: "plan"})

      refute Access.can?(scope(u), "memory.read", {:memory, "org/page/eng/x.md"}),
             "fixture: a guest carries no memory permission"

      allow =
        ok!(
          Grants.grant(%{
            principal: u,
            permission: "memory.read",
            resource: {:memory, "org/page/eng/"}
          })
        )

      deny =
        ok!(
          Grants.deny(%{
            principal: u,
            permission: "memory.read",
            resource: {:memory, "org/page/eng/secret/plan.md"}
          })
        )

      s = scope(u)
      assert Access.can?(s, "memory.read", {:memory, "org/page/eng/x.md"})

      assert Access.can?(s, "memory.read", {:memory, "org/page/eng/y.md"}),
             "control: before the rename the allow covers any path under eng/"

      refute Access.can?(s, "memory.read", {:memory, "org/page/eng/secret/plan.md"})

      before_ids = Repo.all(from(g in Grant, order_by: g.id, select: {g.id, g.resource_id}))
      assert {:ok, _} = Wiki.rename_prefix("org/page/eng/", "org/page/engineering/")
      {:ok, _} = Wiki.upsert_page("org/page/eng/y.md", %{content: "new"})

      assert Repo.all(from(g in Grant, order_by: g.id, select: {g.id, g.resource_id})) ==
               before_ids

      s = scope(u)
      assert Access.can?(s, "memory.read", {:memory, "org/page/engineering/x.md"})
      refute Access.can?(s, "memory.read", {:memory, "org/page/engineering/secret/plan.md"})
      refute Access.can?(s, "memory.read", {:memory, "org/page/eng/y.md"})
      refute Access.can?(s, "memory.read", {:memory, "org/page/eng/x.md"})

      # Grant rows name nodes, never paths.
      assert allow.resource_type == "memory_node"
      assert deny.resource_type == "memory_node"
    end
  end

  # ── direction, principals, empty ───────────────────────────────────────

  describe "nothing flows upward" do
    test "a grant on an execution space gives no task or project read", %{org: org} do
      u = guest!(org)
      r = project!(org)
      t = task!(r)
      er = exec_space!(t, org)
      k = canvas!(er, member!(org))

      for perm <- ["tasks.read", "chat.read"] do
        ok!(Grants.grant(%{principal: u, permission: perm, resource: {:space, er.id}}))
      end

      ok!(Grants.grant(%{principal: u, permission: "canvas.read", resource: {:canvas, k.id}}))
      s = scope(u)

      assert Access.can?(s, "tasks.read", {:space, er.id}), "control: the grant itself applies"
      refute Access.can?(s, "tasks.read", {:task, t.id})
      refute Access.can?(s, "tasks.read", {:project, r.id})
      refute Access.can?(s, "tasks.read", t)
      assert Access.can?(s, "canvas.read", {:canvas, k.id})
      refute Access.can?(s, "canvas.read", {:space, er.id})
    end

    test "a child memory node's grant never widens to its parent", %{org: org} do
      u = guest!(org)
      {:ok, _} = Wiki.upsert_page("org/page/eng/sub/a.md", %{content: "a"})
      {:ok, _} = Wiki.upsert_page("org/page/eng/b.md", %{content: "b"})

      ok!(
        Grants.grant(%{
          principal: u,
          permission: "memory.read",
          resource: {:memory, "org/page/eng/sub/"}
        })
      )

      s = scope(u)
      assert Access.can?(s, "memory.read", {:memory, "org/page/eng/sub/a.md"})
      refute Access.can?(s, "memory.read", {:memory, "org/page/eng/b.md"})
      refute Access.can?(s, "memory.read", {:memory, "org/page/eng/"})
    end
  end

  describe "principals" do
    test "a role grant applies to every holder of the role in the grant's org", %{org: org} do
      g1 = guest!(org)
      g2 = guest!(org)
      m = member!(org)
      p = project!(org)
      t = task!(p)

      ok!(Grants.grant(%{principal: {:role, "guest"}, permission: "tasks.read", resource: p}))

      assert Access.can?(scope(g1), "tasks.read", {:task, t.id})
      assert Access.can?(scope(g2), "tasks.read", {:task, t.id})

      assert Access.can?(scope(m), "tasks.read", {:task, t.id}), "control: member reads by role"
      ok!(Grants.deny(%{principal: {:role, "member"}, permission: "tasks.read", resource: p}))
      refute Access.can?(scope(m), "tasks.read", {:task, t.id})
      assert Access.can?(scope(g1), "tasks.read", {:task, t.id})
    end

    test "a role grant in another org does not apply", %{org: org} do
      other = tenant_org_id("soylent")
      g = guest!(org)
      p = project!(other)

      ok!(
        Grants.grant(%{
          principal: {:role, "guest"},
          permission: "tasks.read",
          resource: p,
          org_id: other
        })
      )

      refute Access.can?(scope(g), "tasks.read", {:project, p.id})
    end

    test "an agent principal's grants are its own", %{org: org} do
      owner = member!(org)
      p = project!(org)
      t = task!(p)
      agent_id = Ecto.UUID.generate()
      runtime = %AgentRuntime{agent_id: agent_id, owner_user_id: owner.id, allowed_bundles: []}
      stranger = %AgentRuntime{agent_id: Ecto.UUID.generate(), owner_user_id: owner.id}

      refute Access.can?(Scope.for_runtime(runtime), "tasks.read", {:task, t.id})

      ok!(Grants.grant(%{principal: {:agent, agent_id}, permission: "tasks.read", resource: p}))

      assert Access.can?(Scope.for_runtime(runtime), "tasks.read", {:task, t.id})
      refute Access.can?(Scope.for_runtime(stranger), "tasks.read", {:task, t.id})
    end
  end

  describe "no grants means member 2's Scope" do
    test "the struct equals member 2's and every answer is Scope.can?/3's", %{org: org} do
      m = member!(org)
      g = guest!(org)
      p = project!(org)
      t = task!(p)
      channel = space!("channel", org)

      for user <- [m, g] do
        s = scope(user)
        assert s.grants == []
        assert s == %{s | grants: %Scope{}.grants}

        for perm <- ["tasks.read", "chat.read", "canvas.read", "memory.read", "install.admin"],
            resource <- [nil, t.id, channel, channel.id, p] do
          assert Access.can?(s, perm, resource) == Scope.can?(s, perm, resource),
                 "#{perm} on #{inspect(resource)}"
        end

        assert Access.permitted_ids(s, "chat.read") == Scope.permitted_ids(s, "chat.read")
      end
    end

    test "a grant on another permission leaves this permission at member 2's answer",
         %{org: org} do
      g = guest!(org)
      p = project!(org)
      channel = space!("channel", org)
      ok!(Grants.grant(%{principal: g, permission: "tasks.read", resource: p}))
      s = scope(g)

      assert length(s.grants) == 1
      assert Access.can?(s, "chat.read", channel) == Scope.can?(s, "chat.read", channel)
    end
  end

  describe "Grants refusals" do
    test "a namespace root, an install-level or derived permission, and a double effect",
         %{org: org} do
      u = guest!(org)
      p = project!(org)

      assert {:error, :namespace_root} =
               Grants.grant(%{
                 principal: u,
                 permission: "memory.read",
                 resource: {:memory, "org/page/"}
               })

      assert {:error, :product_owned} =
               Grants.grant(%{
                 principal: u,
                 permission: "memory.read",
                 resource: {:memory, "burrow/page/x.md"}
               })

      for perm <- ["install.admin", "orgs.read", "nope.nope"] do
        assert {:error, %Ecto.Changeset{errors: [permission: _]}} =
                 Grants.grant(%{principal: u, permission: perm, resource: p})
      end

      ok!(Grants.grant(%{principal: u, permission: "tasks.read", resource: p}))

      assert {:error, %Ecto.Changeset{}} =
               Grants.deny(%{principal: u, permission: "tasks.read", resource: p})
    end

    test "malformed ids are not found and decide nothing", %{org: org} do
      u = guest!(org)
      m = member!(org)

      for type <- [:project, :space, :canvas, :memory_node] do
        assert {:error, :resource_not_found} =
                 Grants.grant(%{principal: u, permission: "tasks.read", resource: {type, "nope"}})
      end

      assert {:error, :not_found} = Grants.revoke("not-a-uuid")

      p = project!(org)
      ok!(Grants.deny(%{principal: m, permission: "tasks.read", resource: p}))
      s = scope(m)

      for type <- [:project, :task, :stack, :space, :canvas, :memory_node] do
        assert Access.can?(s, "tasks.read", {type, "not-a-uuid"}) ==
                 Scope.can?(s, "tasks.read", {type, "not-a-uuid"})
      end
    end

    test "revoke removes the row and its effect", %{org: org} do
      u = guest!(org)
      p = project!(org)
      grant = ok!(Grants.grant(%{principal: u, permission: "tasks.read", resource: p}))
      assert Access.can?(scope(u), "tasks.read", {:project, p.id})

      assert {:ok, _} = Grants.revoke(grant)
      refute Access.can?(scope(u), "tasks.read", {:project, p.id})
      assert {:error, :not_found} = Grants.revoke(grant.id)
    end
  end
end
