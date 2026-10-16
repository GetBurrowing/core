defmodule Platform.Access.ScopeTest do
  @moduledoc """
  Task 01a1386d-cb5c stage 2: `%Platform.Access.Scope{}` over every actor
  class in
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Today's state mapped onto built-in roles (no behaviour change)`.

  Each row asserts the EXACT permissions map, written out here rather than
  derived from the role table, so a changed role row or rule turns a row red.
  Beside each map the test cross-checks the three quantities today's code
  computes for the same user: `Tenancy.visibility/1` (against `orgs.read`),
  `Tenancy.external_user?/1` (against `Scope.guest?/1`) and
  `Tenancy.root_admin?/1` minus external (against `install.admin`).
  """
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.{Participant, Space}
  alias Platform.Federation.ToolAuthorization
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp create_user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "scope-#{tag}-#{n}@example.com",
      name: "Scope #{tag} #{n}",
      oidc_sub: "scope-#{tag}-#{n}"
    })
  end

  defp member!(user, org_id, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()
  end

  defp external!(user, org_id, role \\ "member") do
    {:ok, m} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org_id, role: role})
    m
  end

  defp space!(kind, org_id) do
    n = System.unique_integer([:positive])

    %Space{}
    |> Space.changeset(%{
      kind: kind,
      name: "s2-#{kind}-#{n}",
      slug: "s2-#{kind}-#{n}",
      org_id: org_id
    })
    |> Repo.insert!()
  end

  defp join!(user, space) do
    Repo.insert!(%Participant{
      space_id: space.id,
      participant_type: "user",
      participant_id: user.id,
      role: "member",
      joined_at: DateTime.utc_now()
    })
  end

  defp loaded(user), do: Accounts.get_user(user.id)

  defp sorted(ids), do: Enum.sort(ids)

  # The built-in `member` permission set, resolved: `org_ids` are the
  # contributing memberships' orgs, `p` the participant snapshot.
  defp member_map(org_ids, p) do
    orgs = sorted(org_ids)

    %{
      "chat.read" => p,
      "chat.write" => p,
      "tasks.read" => :all,
      "tasks.write" => :all,
      "memory.read" => :all,
      "memory.write" => :all,
      "memory.journal" => :all,
      "files.read" => orgs,
      "files.write" => orgs,
      "canvas.read" => sorted(p ++ orgs),
      "canvas.write" => sorted(p ++ orgs),
      "prototypes.read" => orgs,
      "experiments.read" => :all,
      "experiments.propose" => :all,
      "agents.manage_own" => :all,
      "skills.read" => :all,
      "skills.write" => :all,
      "vault.use" => :all,
      "prompts.read" => :all,
      "meetings.join" => :all,
      "mail.use" => :all,
      "inbox.read" => :all,
      "activity.read" => :all
    }
  end

  defp admin_extra(org_ids) do
    orgs = sorted(org_ids)

    %{
      "access.manage" => orgs,
      "mail.manage" => orgs,
      "prototypes.publish" => orgs,
      "tasks.promote" => orgs
    }
  end

  @root_admin_rule %{"install.admin" => :all, "tasks.manage" => :all, "prompts.manage" => :all}

  defp guest_map(p), do: %{"chat.read" => p, "chat.write" => p}

  # Today's three quantities, beside the Scope's.
  defp assert_matches_today(user, scope) do
    case Tenancy.visibility(user) do
      :root_all -> assert scope.permissions["orgs.read"] == :all
      {:orgs, ids} -> assert scope.permissions["orgs.read"] == ids
      :none -> refute Map.has_key?(scope.permissions, "orgs.read")
    end

    assert Scope.guest?(scope) == Tenancy.external_user?(user)

    assert Access.can?(scope, "install.admin") ==
             (Tenancy.root_admin?(user) and not Tenancy.external_user?(user))
  end

  setup do
    root = acme_org_id()
    a = tenant_org_id("rbac_s2_a")
    b = tenant_org_id("rbac_s2_b")
    channel = space!("channel", a)
    dm = space!("dm", a)
    %{root: root, a: a, b: b, channel: channel, dm: dm}
  end

  # ── The table ───────────────────────────────────────────────────────────

  describe "for_user/1 over every human actor class" do
    test "root-org admin: admin on root, org visibility :all, plus the root-admin rule", ctx do
      user = create_user!("root-admin")
      member!(user, ctx.root, "admin")
      join!(user, ctx.dm)
      scope = Scope.for_user(loaded(user))

      assert scope.permissions ==
               member_map([ctx.root], [ctx.dm.id])
               |> Map.merge(admin_extra([ctx.root]))
               |> Map.merge(@root_admin_rule)
               |> Map.put("orgs.read", :all)

      assert scope.org.id == ctx.root
      assert scope.role_keys == %{ctx.root => MapSet.new(["admin"])}
      assert_matches_today(user, scope)
    end

    test "root-org member: org visibility widened to :all, files stay strict", ctx do
      user = create_user!("root-member")
      member!(user, ctx.root, "member")
      scope = Scope.for_user(loaded(user))

      assert scope.permissions == Map.put(member_map([ctx.root], []), "orgs.read", :all)
      refute Access.can?(scope, "install.admin")
      assert_matches_today(user, scope)
    end

    test "sub-org admin: admin scoped to that org, NOT widened, no install-level", ctx do
      user = create_user!("sub-admin")
      member!(user, ctx.a, "admin")
      join!(user, ctx.channel)
      scope = Scope.for_user(loaded(user))

      assert scope.permissions ==
               member_map([ctx.a], [ctx.channel.id])
               |> Map.merge(admin_extra([ctx.a]))
               |> Map.put("orgs.read", [ctx.a])

      for p <- ~w(install.admin tasks.manage prompts.manage), do: refute(Access.can?(scope, p))
      assert_matches_today(user, scope)
    end

    test "sub-org member: member scoped to that org", ctx do
      user = create_user!("sub-member")
      member!(user, ctx.a, "member")
      scope = Scope.for_user(loaded(user))

      assert scope.permissions == Map.put(member_map([ctx.a], []), "orgs.read", [ctx.a])
      assert_matches_today(user, scope)
    end

    test "external member: guest on participant spaces, nothing else", ctx do
      user = create_user!("ext-member")
      external!(user, ctx.a)
      join!(user, ctx.dm)
      scope = Scope.for_user(loaded(user))

      assert scope.permissions == Map.put(guest_map([ctx.dm.id]), "orgs.read", [ctx.a])
      assert scope.role_keys == %{ctx.a => MapSet.new(["guest"])}
      assert_matches_today(user, scope)
    end

    test "external admin: exactly the external member's set", ctx do
      user = create_user!("ext-admin")
      external!(user, ctx.a, "admin")
      join!(user, ctx.dm)
      scope = Scope.for_user(loaded(user))

      assert scope.permissions == Map.put(guest_map([ctx.dm.id]), "orgs.read", [ctx.a])
      assert_matches_today(user, scope)
    end

    test "external member of the ROOT org: guest, visibility :all as today, no install", ctx do
      user = create_user!("ext-root")
      external!(user, ctx.root)
      scope = Scope.for_user(loaded(user))

      assert scope.permissions == Map.put(guest_map([]), "orgs.read", :all)
      assert_matches_today(user, scope)
    end

    test "external ADMIN of the root org: root_admin?/1 is true today, install.admin is not",
         ctx do
      user = create_user!("ext-root-admin")
      external!(user, ctx.root, "admin")
      scope = Scope.for_user(loaded(user))

      assert Tenancy.root_admin?(user)
      refute Access.can?(scope, "install.admin")
      assert scope.permissions == Map.put(guest_map([]), "orgs.read", :all)
      assert_matches_today(user, scope)
    end

    test "mixed (external in A, internal in B): guest dominates the internal row", ctx do
      user = create_user!("mixed")
      external!(user, ctx.a)
      member!(user, ctx.b, "admin")
      join!(user, ctx.dm)
      scope = Scope.for_user(loaded(user))

      # The internal admin row contributes no member role data: a
      # per-membership union would widen this user's chat to every channel.
      # It does keep org admin on B, as `Tenancy.org_admin?/2` says today
      # (`org_admin_per_membership/3`, task 01a1386d-cb5c stage 4).
      assert scope.permissions ==
               guest_map([ctx.dm.id])
               |> Map.merge(admin_extra([ctx.b]))
               |> Map.put("orgs.read", sorted([ctx.a, ctx.b]))

      assert Tenancy.org_admin?(user, ctx.b)

      assert scope.role_keys == %{
               ctx.a => MapSet.new(["guest"]),
               ctx.b => MapSet.new(["admin"])
             }

      refute Access.can?(scope, "chat.read", ctx.channel)
      assert_matches_today(user, scope)
    end

    test "mixed with an internal ROOT admin row: guest dominates the root-admin rule", ctx do
      user = create_user!("mixed-root")
      external!(user, ctx.a)
      member!(user, ctx.root, "admin")
      scope = Scope.for_user(loaded(user))

      assert Tenancy.root_admin?(user)
      refute Access.can?(scope, "install.admin")

      assert scope.permissions ==
               guest_map([]) |> Map.merge(admin_extra([ctx.root])) |> Map.put("orgs.read", :all)

      assert_matches_today(user, scope)
    end

    test "zero memberships: the no-membership baseline, the whole member role", ctx do
      user = create_user!("none")
      join!(user, ctx.dm)
      scope = Scope.for_user(loaded(user))

      # Internal today: every channel, the whole board, every internal module
      # (`no_membership_baseline/1`, task 01a1386d-cb5c stage 4). With no org,
      # each `membership_org` rule resolves to nothing.
      assert scope.permissions == member_map([], [ctx.dm.id])
      refute Access.can?(scope, "files.read")
      # Carried, though it resolves to nothing: the rail declares the module.
      assert Scope.carries?(scope, "files.read")
      assert :files in Scope.declared_rail(scope)
      refute Scope.carries?(scope, "install.admin")

      assert Access.can?(scope, "chat.read", ctx.channel)
      assert scope.org == nil
      assert scope.role_keys == %{}
      assert_matches_today(user, scope)
    end

    test "nil and the legacy display-name string fail closed" do
      assert Scope.for_user(nil) == %Scope{}
      assert Scope.for_user("Marlowe Quill") == %Scope{}
      refute Access.can?(Scope.for_user(nil), "chat.read")
      assert Access.permitted_ids(Scope.for_user(nil), "tasks.read") == []
    end
  end

  describe "the implicit_or_participant chat rule" do
    test "internal: any channel by kind, a DM only as participant; guest: participant only",
         ctx do
      other_dm = space!("dm", ctx.a)
      group = space!("group", ctx.b)
      exec = space!("execution", ctx.b)

      internal = create_user!("chat-int")
      member!(internal, ctx.a, "member")
      join!(internal, ctx.dm)
      s = Scope.for_user(loaded(internal))

      assert Access.can?(s, "chat.read", ctx.channel)
      assert Access.can?(s, "chat.write", exec)
      assert Access.can?(s, "chat.read", ctx.dm)
      assert Access.can?(s, "chat.read", ctx.dm.id)
      refute Access.can?(s, "chat.read", other_dm)
      refute Access.can?(s, "chat.read", group)
      assert Access.can?(s, "chat.read")
      # The set form is the participant snapshot only; kind admission needs the space.
      assert Access.permitted_ids(s, "chat.read") == [ctx.dm.id]
      refute Access.can?(s, "chat.read", ctx.channel.id)

      guest = create_user!("chat-guest")
      external!(guest, ctx.a)
      g = Scope.for_user(loaded(guest))

      refute Access.can?(g, "chat.read", ctx.channel)
      refute Access.can?(g, "chat.read", ctx.dm)
      refute Access.can?(g, "chat.read")
    end
  end

  describe "resolution paths" do
    test "the preloaded and Repo paths build equal structs", ctx do
      user = create_user!("paths")
      member!(user, ctx.a, "admin")
      member!(user, ctx.root, "member")
      join!(user, ctx.dm)

      preloaded = Scope.for_user(loaded(user))
      repo = Scope.for_user(Repo.get!(User, user.id))

      assert preloaded == repo

      bare = Scope.for_user(%{id: user.id})
      assert bare.permissions == preloaded.permissions
      assert bare.role_keys == preloaded.role_keys
    end

    test "the preloaded path issues no membership, org or role query: one participant query and one grants query",
         ctx do
      user = create_user!("queries")
      member!(user, ctx.a, "admin")
      member!(user, ctx.root, "member")
      join!(user, ctx.dm)
      user = loaded(user)
      # Warm the built-in role cache, as the first request after boot does.
      assert length(Access.builtin_roles()) == 3

      {scope, sources} = count_queries(fn -> Scope.for_user(user) end)

      assert scope.permissions["chat.read"] == [ctx.dm.id]
      # Task 01a1386d-e528 stage 2 adds exactly one query: the actor's
      # `access_grants` rows, loaded once for every principal.
      assert sources == ["chat_participants", "access_grants"]

      # A zero-membership user's baseline carries a participant rule too:
      # still the one participant query plus the grants query, nothing else.
      nobody = loaded(create_user!("queries-none"))

      assert {_, ["chat_participants", "access_grants"]} =
               count_queries(fn -> Scope.for_user(nobody) end)
    end
  end

  defp count_queries(fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :repo, :query],
        fn _event, _measurements, meta, _config ->
          # The handler runs in the emitting process; sibling async tests are
          # discarded by the pid check.
          if self() == test_pid, do: send(test_pid, {ref, meta[:source]})
        end,
        nil
      )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain(ref, [])}
  end

  defp drain(ref, acc) do
    receive do
      {^ref, source} -> drain(ref, [source | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "for_runtime/1" do
    defp owner!(ctx, external?) do
      user = create_user!("owner")
      if external?, do: external!(user, ctx.a), else: member!(user, ctx.root, "member")
      user
    end

    test "default bundles retain the transitional mcp keys and add capped tool permissions",
         ctx do
      runtime = %AgentRuntime{owner_user_id: owner!(ctx, false).id}
      scope = Scope.for_runtime(runtime)

      for bundle <- AgentRuntime.default_allowed_bundles() do
        assert scope.permissions["mcp." <> bundle] == :all
      end

      assert is_list(scope.permissions["chat.write"])
      assert scope.permissions["agents.manage_own"] == :all

      refute Scope.guest?(scope)
      assert Scope.tool_names(scope) == ToolAuthorization.tool_names(runtime)
      assert Scope.tool_names(scope) != []
    end

    test "narrowed bundles, in row order", ctx do
      runtime = %AgentRuntime{
        owner_user_id: owner!(ctx, false).id,
        allowed_bundles: ["task", "messaging"]
      }

      scope = Scope.for_runtime(runtime)

      assert scope.permissions["mcp.task"] == :all
      assert scope.permissions["mcp.messaging"] == :all
      assert scope.permissions["tasks.read"] == :all
      assert is_list(scope.permissions["chat.write"])
      assert Scope.tool_names(scope) == ToolAuthorization.tool_names(runtime)
    end

    test "owned by an external user: marked guest, tools reduced to the chat allowlist", ctx do
      runtime = %AgentRuntime{owner_user_id: owner!(ctx, true).id}
      scope = Scope.for_runtime(runtime)

      assert ToolAuthorization.external_principal?(runtime)
      assert Scope.guest?(scope)
      assert scope.role_keys == %{ctx.a => MapSet.new(["guest"])}
      assert Scope.tool_names(scope) == ToolAuthorization.tool_names(runtime)
    end

    test "no bundles: nothing" do
      scope = Scope.for_runtime(%AgentRuntime{allowed_bundles: nil})
      assert scope.permissions == %{}
      assert Scope.tool_names(scope) == []
    end

    test "Access.scope_for/1 dispatches a runtime to for_runtime/1", ctx do
      runtime = %AgentRuntime{owner_user_id: owner!(ctx, false).id, allowed_bundles: ["task"]}
      assert Access.scope_for(runtime) == Scope.for_runtime(runtime)
      assert Access.scope_for(nil) == %Scope{}
    end
  end

  describe "meeting invitee and system" do
    test "a meeting invitee holds nothing; it is not the guest role", ctx do
      scope = Scope.for_meeting_invitee(%{slug: "room", token: "t"})

      assert scope.permissions == %{}
      refute Scope.guest?(scope)
      refute Access.can?(scope, "chat.read", ctx.channel)
      refute Access.can?(scope, "meetings.join")
    end

    test "system/0 is the only unrestricted scope", ctx do
      scope = Scope.system()

      assert Access.can?(scope, "install.admin")
      assert Access.can?(scope, "chat.read", ctx.dm)
      assert Access.permitted_ids(scope, "files.read") == :all
    end
  end

  describe "Access.builtin_roles/0" do
    test "the three seeded rows, matching the table" do
      cached = Access.builtin_role_rules()
      table = Map.new(Repo.all(Platform.Access.Role), &{&1.key, &1.permissions})

      assert Map.keys(cached) == ["admin", "guest", "member"]
      assert cached == Map.take(table, ["admin", "guest", "member"])
    end
  end
end
