defmodule Platform.Mail.OwnershipTest do
  @moduledoc """
  `Platform.Mail.Ownership` (task 01a1ea5b stage 1, Email privacy): who may
  read a mail account, who may manage its grants, and what the schema
  guarantees. Every test names the rule in `ownership.ex` it pins; the stage
  report maps each mutation of that file to the test here that goes red.

  The mail accounts live in the install's ROOT org, so the support-session
  admin (a root-org admin, which is what a vendor support admin session of
  task 01a1b362 confers, and which holds `install.admin`) is ALSO an org
  admin of the mailbox's org: the strongest admin there is.
  """
  use Platform.DataCase, async: true

  import Ecto.Query
  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Audit.Event
  alias Platform.Mail
  alias Platform.Mail.{Account, AccountGrant, Ownership}
  alias Platform.Tenancy.OrgMembership

  defp user!(tag) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "own-#{tag}-#{n}@example.com",
      name: "Own #{tag} #{n}",
      oidc_sub: "own-#{tag}-#{n}"
    })
    |> Repo.insert!()
  end

  defp member!(user, org_id, role \\ "member", external \\ false) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: role,
      external: external
    })
    |> Repo.insert!()

    user
  end

  defp agent! do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{slug: "own-agent-#{n}", name: "Own Agent #{n}", status: "active"})
    |> Repo.insert!()
  end

  defp account!(admin, org_id, name) do
    {:ok, account} =
      Mail.create_account(admin, org_id, %{
        "name" => "#{name}-#{System.unique_integer([:positive])}",
        "smtp_host" => "smtp.#{name}.test",
        "smtp_port" => 587,
        "smtp_tls" => "starttls"
      })

    account
  end

  # Writes a grant row directly, bypassing `grant/3`'s checks, to prove the
  # READ rules do not depend on the write rules.
  defp raw_grant!(account, type, id) do
    Repo.insert!(%AccountGrant{account_id: account.id, principal_type: type, principal_id: id})
  end

  defp personal!(ctx, owner) do
    account = account!(ctx.admin, ctx.org_id, "personal")

    {:ok, account} =
      Ownership.set_owner(ctx.admin, account, %{kind: "personal", owner_user_id: owner.id})

    account
  end

  defp shared!(ctx) do
    account = account!(ctx.admin, ctx.org_id, "shared")
    {:ok, account} = Ownership.set_owner(ctx.admin, account, %{kind: "shared"})
    account
  end

  defp readable?(user, account),
    do: account.id in Ownership.readable_account_ids(user, account.org_id)

  setup do
    org_id = acme_org_id()
    other_org_id = tenant_org_id("own_other")
    admin = user!("admin") |> member!(org_id, "admin")
    owner = user!("owner") |> member!(org_id)
    other = user!("other") |> member!(org_id)

    # The support-session admin: a root-org admin (task 01a1b362's admin
    # session is exactly this membership, time-boxed). It holds
    # `install.admin`, proven here so the tests below are not vacuous.
    support = root_admin!()
    assert Access.can?(Scope.for_user(Accounts.get_user(support.id)), "install.admin")
    assert Platform.Tenancy.org_admin?(support, org_id)

    %{
      org_id: org_id,
      other_org_id: other_org_id,
      admin: admin,
      owner: owner,
      other: other,
      support: support
    }
  end

  describe "schema and migration" do
    test "every new account is unassigned, not digest-opted-in, with no owner", ctx do
      account = account!(ctx.admin, ctx.org_id, "fresh")
      row = Repo.one!(from(a in Account, where: a.id == ^account.id))

      assert row.owner_kind == "unassigned"
      assert is_nil(row.owner_user_id)
      refute row.digest_opt_in

      assert Repo.aggregate(from(g in AccountGrant, where: g.account_id == ^account.id), :count) ==
               0
    end

    test "the owner fields are not cast by the admin changeset", ctx do
      account = account!(ctx.admin, ctx.org_id, "nocast")

      {:ok, updated} =
        Mail.update_account(ctx.admin, account, %{
          "owner_kind" => "personal",
          "owner_user_id" => ctx.other.id,
          "digest_opt_in" => true
        })

      assert updated.owner_kind == "unassigned"
      assert is_nil(updated.owner_user_id)
      refute updated.digest_opt_in
    end

    test "a check constraint rejects personal with a nil owner", ctx do
      account = account!(ctx.admin, ctx.org_id, "chk")

      assert_raise Postgrex.Error, ~r/mail_accounts_owner_user_iff_personal/, fn ->
        Repo.transaction(fn ->
          Repo.update_all(from(a in Account, where: a.id == ^account.id),
            set: [owner_kind: "personal"]
          )
        end)
      end
    end

    test "a check constraint rejects an owner on a shared or unassigned account", ctx do
      account = account!(ctx.admin, ctx.org_id, "chk2")

      for kind <- ["shared", "unassigned"] do
        assert_raise Postgrex.Error, ~r/mail_accounts_owner_user_iff_personal/, fn ->
          Repo.transaction(fn ->
            Repo.update_all(from(a in Account, where: a.id == ^account.id),
              set: [owner_kind: kind, owner_user_id: ctx.owner.id]
            )
          end)
        end
      end
    end

    test "an unknown owner_kind is rejected by the database", ctx do
      account = account!(ctx.admin, ctx.org_id, "chk3")

      assert_raise Postgrex.Error, ~r/mail_accounts_owner_kind_check/, fn ->
        Repo.transaction(fn ->
          Repo.update_all(from(a in Account, where: a.id == ^account.id),
            set: [owner_kind: "team"]
          )
        end)
      end
    end

    test "a grant row is unique per account and principal", ctx do
      account = shared!(ctx)
      raw_grant!(account, "user", ctx.other.id)

      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(fn -> raw_grant!(account, "user", ctx.other.id) end)
      end
    end
  end

  describe "readable_account_ids/2 and can_read_account?/2" do
    test "the owner reads their personal mailbox", ctx do
      account = personal!(ctx, ctx.owner)

      assert readable?(ctx.owner, account)
      assert Ownership.can_read_account?(ctx.owner, account)
    end

    test "a non-owner member does not read a personal mailbox", ctx do
      account = personal!(ctx, ctx.owner)

      refute readable?(ctx.other, account)
      refute Ownership.can_read_account?(ctx.other, account)
    end

    test "an org admin does not read a personal mailbox", ctx do
      account = personal!(ctx, ctx.owner)

      refute readable?(ctx.admin, account)
      refute Ownership.can_read_account?(ctx.admin, account)
    end

    test "a support-session admin (install.admin) does not read a personal mailbox", ctx do
      account = personal!(ctx, ctx.owner)

      refute readable?(ctx.support, account)
      refute Ownership.can_read_account?(ctx.support, account)
    end

    test "a support-session admin (install.admin) does not read an unassigned mailbox", ctx do
      account = account!(ctx.admin, ctx.org_id, "unassigned")

      refute readable?(ctx.support, account)
      refute Ownership.can_read_account?(ctx.support, account)
      assert Ownership.agent_granted_account_ids(ctx.support.id, ctx.org_id) == []
    end

    test "an unassigned mailbox is read by nobody, admins included", ctx do
      account = account!(ctx.admin, ctx.org_id, "nobody")

      for user <- [ctx.admin, ctx.owner, ctx.other, ctx.support] do
        refute readable?(user, account)
        refute Ownership.can_read_account?(user, account)
      end
    end

    test "a stray user grant row on an unassigned or personal mailbox confers nothing", ctx do
      unassigned = account!(ctx.admin, ctx.org_id, "stray-u")
      personal = personal!(ctx, ctx.owner)
      raw_grant!(unassigned, "user", ctx.other.id)
      raw_grant!(personal, "user", ctx.other.id)

      refute readable?(ctx.other, unassigned)
      refute readable?(ctx.other, personal)
    end

    test "a shared member reads; a shared non-member does not, admin included", ctx do
      account = shared!(ctx)
      {:ok, _} = Ownership.grant(ctx.admin, account, {:user, ctx.other.id})

      assert readable?(ctx.other, account)
      assert Ownership.can_read_account?(ctx.other, account)
      refute readable?(ctx.owner, account)
      refute readable?(ctx.admin, account)
      refute readable?(ctx.support, account)
    end

    test "a member of one shared mailbox does not read another", ctx do
      a = shared!(ctx)
      b = shared!(ctx)
      {:ok, _} = Ownership.grant(ctx.admin, a, {:user, ctx.other.id})

      assert readable?(ctx.other, a)
      refute readable?(ctx.other, b)
      refute Ownership.can_read_account?(ctx.other, b)
    end

    test "can_read_account? answers for that account only", ctx do
      mine = personal!(ctx, ctx.owner)
      theirs = personal!(ctx, ctx.other)

      assert Ownership.can_read_account?(ctx.owner, mine)
      refute Ownership.can_read_account?(ctx.owner, theirs)
    end

    test "an AGENT grant whose id equals a user's id does not let that user read", ctx do
      account = shared!(ctx)
      raw_grant!(account, "agent", ctx.other.id)

      refute readable?(ctx.other, account)
    end

    test "only the given org's accounts are returned", ctx do
      foreign_admin = user!("fadmin") |> member!(ctx.other_org_id, "admin")
      member!(ctx.owner, ctx.other_org_id)
      foreign = account!(foreign_admin, ctx.other_org_id, "foreign")

      {:ok, foreign} =
        Ownership.set_owner(foreign_admin, foreign, %{
          kind: "personal",
          owner_user_id: ctx.owner.id
        })

      assert foreign.id in Ownership.readable_account_ids(ctx.owner, ctx.other_org_id)
      refute foreign.id in Ownership.readable_account_ids(ctx.owner, ctx.org_id)
    end

    test "an owner who leaves the org stops reading on the next call", ctx do
      account = personal!(ctx, ctx.owner)
      assert readable?(ctx.owner, account)

      Repo.delete_all(
        from(m in OrgMembership, where: m.user_id == ^ctx.owner.id and m.org_id == ^ctx.org_id)
      )

      refute readable?(ctx.owner, account)
      refute Ownership.can_read_account?(ctx.owner, account)
    end

    test "an external member who owns a mailbox does not read it", ctx do
      ext = user!("ext") |> member!(ctx.org_id, "member", true)
      account = account!(ctx.admin, ctx.org_id, "ext")

      Repo.update_all(from(a in Account, where: a.id == ^account.id),
        set: [owner_kind: "personal", owner_user_id: ext.id]
      )

      refute readable?(ext, account)
    end

    test "can_read_account? re-reads the row, ignoring a stale struct", ctx do
      account = personal!(ctx, ctx.owner)
      forged = %{account | owner_user_id: ctx.other.id}

      refute Ownership.can_read_account?(ctx.other, forged)
      assert Ownership.can_read_account?(ctx.owner, %{account | owner_kind: "unassigned"})
    end

    test "garbage input reads nothing and never raises", ctx do
      assert Ownership.readable_account_ids(nil, ctx.org_id) == []
      assert Ownership.readable_account_ids(%{id: "nope"}, ctx.org_id) == []
      assert Ownership.readable_account_ids(ctx.owner, "nope") == []
      refute Ownership.can_read_account?(ctx.owner, nil)
      assert Ownership.agent_granted_account_ids("nope", ctx.org_id) == []
    end
  end

  describe "grant/3 and revoke/3" do
    test "grant then revoke flips the next readable call (shared member)", ctx do
      account = shared!(ctx)
      refute readable?(ctx.other, account)

      {:ok, _} = Ownership.grant(ctx.admin, account, {:user, ctx.other.id})
      assert readable?(ctx.other, account)

      {:ok, _} = Ownership.revoke(ctx.admin, account, {:user, ctx.other.id})
      refute readable?(ctx.other, account)

      assert Repo.aggregate(from(g in AccountGrant, where: g.account_id == ^account.id), :count) ==
               0
    end

    test "grant then revoke flips the next agent_granted call", ctx do
      account = personal!(ctx, ctx.owner)
      agent = agent!()
      assert Ownership.agent_granted_account_ids(agent.id, ctx.org_id) == []

      {:ok, _} = Ownership.grant(ctx.owner, account, {:agent, agent.id})
      assert Ownership.agent_granted_account_ids(agent.id, ctx.org_id) == [account.id]

      {:ok, _} = Ownership.revoke(ctx.owner, account, {:agent, agent.id})
      assert Ownership.agent_granted_account_ids(agent.id, ctx.org_id) == []
    end

    test "agent_granted ignores other orgs, user rows with the agent's id, and unassigned",
         ctx do
      agent = agent!()
      unassigned = account!(ctx.admin, ctx.org_id, "ag-u")
      raw_grant!(unassigned, "agent", agent.id)
      shared = shared!(ctx)
      raw_grant!(shared, "user", agent.id)

      foreign_admin = user!("fadmin2") |> member!(ctx.other_org_id, "admin")
      foreign = account!(foreign_admin, ctx.other_org_id, "ag-f")
      {:ok, foreign} = Ownership.set_owner(foreign_admin, foreign, %{kind: "shared"})
      {:ok, _} = Ownership.grant(foreign_admin, foreign, {:agent, agent.id})

      assert Ownership.agent_granted_account_ids(agent.id, ctx.org_id) == []
      assert Ownership.agent_granted_account_ids(agent.id, ctx.other_org_id) == [foreign.id]
    end

    test "a non-owner's grant on a personal mailbox is refused and writes nothing", ctx do
      account = personal!(ctx, ctx.owner)
      agent = agent!()

      for actor <- [ctx.other, ctx.admin, ctx.support] do
        assert {:error, :unauthorized} = Ownership.grant(actor, account, {:agent, agent.id})
      end

      assert Ownership.agent_granted_account_ids(agent.id, ctx.org_id) == []
    end

    test "a non-admin's grant on a shared mailbox is refused, even by a member", ctx do
      account = shared!(ctx)
      {:ok, _} = Ownership.grant(ctx.admin, account, {:user, ctx.other.id})

      assert {:error, :unauthorized} =
               Ownership.grant(ctx.other, account, {:user, ctx.owner.id})

      refute readable?(ctx.owner, account)
    end

    test "nobody may grant on an unassigned mailbox, admins included", ctx do
      account = account!(ctx.admin, ctx.org_id, "g-u")
      agent = agent!()

      for actor <- [ctx.admin, ctx.support, ctx.owner] do
        assert {:error, :unauthorized} = Ownership.grant(actor, account, {:agent, agent.id})
        assert {:error, :unauthorized} = Ownership.grant(actor, account, {:user, ctx.other.id})
      end

      assert Repo.aggregate(from(g in AccountGrant, where: g.account_id == ^account.id), :count) ==
               0
    end

    test "a non-manager's revoke is refused and the grant survives", ctx do
      account = personal!(ctx, ctx.owner)
      agent = agent!()
      {:ok, _} = Ownership.grant(ctx.owner, account, {:agent, agent.id})

      for actor <- [ctx.other, ctx.admin, ctx.support] do
        assert {:error, :unauthorized} = Ownership.revoke(actor, account, {:agent, agent.id})
      end

      assert Ownership.agent_granted_account_ids(agent.id, ctx.org_id) == [account.id]
    end

    test "grant and revoke re-read the row: a forged struct is refused", ctx do
      account = personal!(ctx, ctx.owner)
      agent = agent!()
      forged = %{account | owner_user_id: ctx.other.id}

      refute Ownership.can_manage_access?(ctx.other, forged)
      assert {:error, :unauthorized} = Ownership.grant(ctx.other, forged, {:agent, agent.id})
      assert Ownership.agent_granted_account_ids(agent.id, ctx.org_id) == []

      {:ok, _} = Ownership.grant(ctx.owner, account, {:agent, agent.id})
      assert {:error, :unauthorized} = Ownership.revoke(ctx.other, forged, {:agent, agent.id})
      assert Ownership.agent_granted_account_ids(agent.id, ctx.org_id) == [account.id]
    end

    test "a user grant on a personal mailbox is refused: there are no co-owners", ctx do
      account = personal!(ctx, ctx.owner)

      assert {:error, :not_shared} = Ownership.grant(ctx.owner, account, {:user, ctx.other.id})
      refute readable?(ctx.other, account)
    end

    test "a user grant needs an internal member of the account's org", ctx do
      account = shared!(ctx)
      outsider = user!("outsider")
      ext = user!("ext2") |> member!(ctx.org_id, "member", true)

      assert {:error, :unknown_principal} =
               Ownership.grant(ctx.admin, account, {:user, outsider.id})

      assert {:error, :unknown_principal} = Ownership.grant(ctx.admin, account, {:user, ext.id})
    end

    test "an agent grant needs an existing agent", ctx do
      account = personal!(ctx, ctx.owner)

      assert {:error, :unknown_principal} =
               Ownership.grant(ctx.owner, account, {:agent, Ecto.UUID.generate()})

      assert {:error, :unknown_principal} = Ownership.grant(ctx.owner, account, {:agent, "x"})
    end

    test "a duplicate grant and a missing revoke are reported", ctx do
      account = personal!(ctx, ctx.owner)
      agent = agent!()
      {:ok, _} = Ownership.grant(ctx.owner, account, {:agent, agent.id})

      assert {:error, :already_granted} = Ownership.grant(ctx.owner, account, {:agent, agent.id})
      {:ok, _} = Ownership.revoke(ctx.owner, account, {:agent, agent.id})
      assert {:error, :not_found} = Ownership.revoke(ctx.owner, account, {:agent, agent.id})
    end

    test "grant and revoke each write one audit row, with no content", ctx do
      account = personal!(ctx, ctx.owner)
      agent = agent!()
      {:ok, _} = Ownership.grant(ctx.owner, account, {:agent, agent.id})
      {:ok, _} = Ownership.revoke(ctx.owner, account, {:agent, agent.id})

      events =
        Repo.all(
          from(e in Event,
            where:
              e.event_type == "platform.mail.ownership" and e.resource_id == ^account.id and
                e.action in ["grant", "revoke"],
            order_by: [asc: e.id]
          )
        )

      assert [%{action: "grant"} = g, %{action: "revoke"} = r] = events

      for e <- [g, r] do
        assert e.actor_id == ctx.owner.id
        assert e.resource_type == "mail_account"
        assert e.metadata["principal_type"] == "agent"
        assert e.metadata["principal_id"] == agent.id
      end
    end

    test "a refused grant writes no audit row", ctx do
      account = personal!(ctx, ctx.owner)
      agent = agent!()
      {:error, :unauthorized} = Ownership.grant(ctx.other, account, {:agent, agent.id})

      refute Repo.exists?(
               from(e in Event,
                 where: e.resource_id == ^account.id and e.action == "grant"
               )
             )
    end
  end

  describe "can_manage_access?/2" do
    test "owner for personal, org admin for shared, nobody for unassigned", ctx do
      personal = personal!(ctx, ctx.owner)
      shared = shared!(ctx)
      unassigned = account!(ctx.admin, ctx.org_id, "m-u")

      assert Ownership.can_manage_access?(ctx.owner, personal)
      refute Ownership.can_manage_access?(ctx.other, personal)
      refute Ownership.can_manage_access?(ctx.admin, personal)
      refute Ownership.can_manage_access?(ctx.support, personal)

      assert Ownership.can_manage_access?(ctx.admin, shared)
      refute Ownership.can_manage_access?(ctx.other, shared)

      for user <- [ctx.admin, ctx.support, ctx.owner, ctx.other],
          do: refute(Ownership.can_manage_access?(user, unassigned))
    end

    test "an owner who left the org no longer manages", ctx do
      personal = personal!(ctx, ctx.owner)

      Repo.delete_all(
        from(m in OrgMembership, where: m.user_id == ^ctx.owner.id and m.org_id == ^ctx.org_id)
      )

      refute Ownership.can_manage_access?(ctx.owner, personal)
    end
  end

  describe "set_owner/3" do
    test "admin only, audited with the previous and new owner", ctx do
      account = account!(ctx.admin, ctx.org_id, "so")

      for actor <- [ctx.owner, ctx.other] do
        assert {:error, :unauthorized} =
                 Ownership.set_owner(actor, account, %{
                   kind: "personal",
                   owner_user_id: actor.id
                 })
      end

      assert Repo.one!(from(a in Account, where: a.id == ^account.id)).owner_kind ==
               "unassigned"

      {:ok, updated} =
        Ownership.set_owner(ctx.admin, account, %{kind: "personal", owner_user_id: ctx.owner.id})

      assert updated.owner_kind == "personal"
      assert updated.owner_user_id == ctx.owner.id

      event =
        Repo.one!(
          from(e in Event, where: e.resource_id == ^account.id and e.action == "set_owner")
        )

      assert event.actor_id == ctx.admin.id
      assert event.metadata["previous_kind"] == "unassigned"
      assert event.metadata["kind"] == "personal"
      assert event.metadata["owner_user_id"] == ctx.owner.id
    end

    test "a personal owner must be an internal member of the org", ctx do
      account = account!(ctx.admin, ctx.org_id, "so2")
      outsider = user!("so-out")

      assert {:error, :unknown_principal} =
               Ownership.set_owner(ctx.admin, account, %{
                 kind: "personal",
                 owner_user_id: outsider.id
               })

      assert {:error, :unknown_principal} =
               Ownership.set_owner(ctx.admin, account, %{kind: "personal"})

      assert {:error, :invalid_kind} = Ownership.set_owner(ctx.admin, account, %{kind: "team"})
    end

    test "reassigning the owner deletes every grant; the new owner inherits no agent", ctx do
      account = personal!(ctx, ctx.owner)
      agent = agent!()
      {:ok, _} = Ownership.grant(ctx.owner, account, {:agent, agent.id})

      {:ok, account} =
        Ownership.set_owner(ctx.admin, account, %{kind: "personal", owner_user_id: ctx.other.id})

      assert readable?(ctx.other, account)
      refute readable?(ctx.owner, account)
      assert Ownership.agent_granted_account_ids(agent.id, ctx.org_id) == []
    end

    test "shared -> personal -> shared does not revive old members", ctx do
      account = shared!(ctx)
      {:ok, _} = Ownership.grant(ctx.admin, account, {:user, ctx.other.id})

      {:ok, account} =
        Ownership.set_owner(ctx.admin, account, %{kind: "personal", owner_user_id: ctx.owner.id})

      {:ok, account} = Ownership.set_owner(ctx.admin, account, %{kind: "shared"})

      refute readable?(ctx.other, account)
    end

    test "re-setting the same owner keeps the grants", ctx do
      account = personal!(ctx, ctx.owner)
      agent = agent!()
      {:ok, _} = Ownership.grant(ctx.owner, account, {:agent, agent.id})

      {:ok, _} =
        Ownership.set_owner(ctx.admin, account, %{kind: "personal", owner_user_id: ctx.owner.id})

      assert Ownership.agent_granted_account_ids(agent.id, ctx.org_id) == [account.id]
    end
  end

  describe "deleting a principal (no FK on principal_id)" do
    test "deleting a user deletes their grants and returns their mailbox to unassigned",
         ctx do
      personal = personal!(ctx, ctx.owner)
      shared = shared!(ctx)
      agent = agent!()
      {:ok, _} = Ownership.grant(ctx.owner, personal, {:agent, agent.id})
      {:ok, _} = Ownership.grant(ctx.admin, shared, {:user, ctx.owner.id})

      Repo.delete!(ctx.owner)

      row = Repo.one!(from(a in Account, where: a.id == ^personal.id))
      assert row.owner_kind == "unassigned"
      assert is_nil(row.owner_user_id)

      refute Repo.exists?(
               from(g in AccountGrant,
                 where: g.principal_type == "user" and g.principal_id == ^ctx.owner.id
               )
             )

      # A row with the same id coming back inherits nothing.
      Repo.insert!(%User{
        id: ctx.owner.id,
        email: "own-recycled-#{System.unique_integer([:positive])}@example.com",
        name: "Recycled",
        oidc_sub: "own-recycled-#{System.unique_integer([:positive])}"
      })
      |> member!(ctx.org_id)

      assert Ownership.readable_account_ids(%{id: ctx.owner.id}, ctx.org_id) == []

      # The agents the deleted owner chose lose the mailbox too: the grant
      # row is gone, not merely masked by `unassigned`.
      refute Repo.exists?(from(g in AccountGrant, where: g.account_id == ^personal.id))
      assert Ownership.agent_granted_account_ids(agent.id, ctx.org_id) == []
    end

    test "deleting an agent deletes its grants", ctx do
      account = personal!(ctx, ctx.owner)
      agent = agent!()
      {:ok, _} = Ownership.grant(ctx.owner, account, {:agent, agent.id})

      Repo.delete!(agent)

      refute Repo.exists?(
               from(g in AccountGrant,
                 where: g.principal_type == "agent" and g.principal_id == ^agent.id
               )
             )

      # A recycled id inherits nothing.
      Repo.insert!(%Agent{
        id: agent.id,
        slug: "own-recycled-#{System.unique_integer([:positive])}",
        name: "Recycled",
        status: "active"
      })

      assert Ownership.agent_granted_account_ids(agent.id, ctx.org_id) == []
    end

    test "deleting the granter keeps the grant (provenance nilified)", ctx do
      account = shared!(ctx)
      granter = user!("granter") |> member!(ctx.org_id, "admin")
      {:ok, grant} = Ownership.grant(granter, account, {:user, ctx.other.id})

      Repo.delete!(granter)

      row = Repo.one!(from(g in AccountGrant, where: g.id == ^grant.id))
      assert is_nil(row.granted_by_user_id)
      assert readable?(ctx.other, account)
    end

    test "the (principal_type, principal_id) index exists" do
      %{rows: rows} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE tablename = 'mail_account_grants'",
          []
        )

      assert Enum.any?(rows, fn [def] -> def =~ "(principal_type, principal_id)" end)
    end
  end

  # ── The previous-owner notice (task 01a1ea5b stage 4) ─────────────────────
  #
  # Ryan accepted the plan's question-4 proposal: when an admin reassigns a
  # personal mailbox, its previous owner is told, with no mail content.

  describe "set_owner/3 notice to the previous owner" do
    alias Platform.Inbox.Item

    defp notices(account_id) do
      Repo.all(
        from(i in Item,
          where:
            i.kind == "mailbox_reassigned" and i.source_type == "mail_account" and
              i.source_id == ^account_id
        )
      )
    end

    test "the previous owner gets exactly one notice naming the admin, address and new owner",
         ctx do
      account = personal!(ctx, ctx.owner)
      token = "SUBJ-NOTICE-#{System.unique_integer([:positive])}"

      Repo.insert!(%Platform.Mail.InboundMessage{
        account_id: account.id,
        org_id: account.org_id,
        folder: "INBOX",
        uidvalidity: 1,
        uid: System.unique_integer([:positive]),
        message_id_key: "#{token}@example.test",
        raw: "raw",
        subject: token,
        text_body: "BODY-" <> token,
        received_at: DateTime.utc_now()
      })

      {:ok, _} =
        Ownership.set_owner(ctx.admin, account, %{kind: "personal", owner_user_id: ctx.other.id})

      assert [notice] = notices(account.id)
      assert notice.user_id == ctx.owner.id
      assert notice.title == "#{ctx.admin.name} reassigned #{account.name} to #{ctx.other.name}"
      assert is_nil(notice.body)
      refute notice.title =~ token
    end

    test "nobody else is notified: not the new owner, not the admin, not a bystander", ctx do
      account = personal!(ctx, ctx.owner)

      {:ok, _} =
        Ownership.set_owner(ctx.admin, account, %{kind: "personal", owner_user_id: ctx.other.id})

      recipients = account.id |> notices() |> Enum.map(& &1.user_id)
      assert recipients == [ctx.owner.id]

      for id <- [ctx.other.id, ctx.admin.id, ctx.support.id] do
        refute Repo.exists?(
                 from(i in Item, where: i.user_id == ^id and i.kind == "mailbox_reassigned")
               )
      end
    end

    test "personal to shared tells the previous owner it became a shared mailbox", ctx do
      account = personal!(ctx, ctx.owner)
      {:ok, _} = Ownership.set_owner(ctx.admin, account, %{kind: "shared"})

      assert [notice] = notices(account.id)
      assert notice.user_id == ctx.owner.id
      assert notice.title == "#{ctx.admin.name} reassigned #{account.name} to a shared mailbox"
    end

    test "no notice when there was no previous owner, or the owner did not change", ctx do
      # unassigned -> personal (personal!/2), then the same owner again.
      account = personal!(ctx, ctx.owner)
      assert notices(account.id) == []

      {:ok, _} =
        Ownership.set_owner(ctx.admin, account, %{kind: "personal", owner_user_id: ctx.owner.id})

      assert notices(account.id) == []

      shared = shared!(ctx)
      {:ok, _} = Ownership.set_owner(ctx.admin, shared, %{kind: "unassigned"})
      assert notices(shared.id) == []
    end

    test "a refused reassignment notifies nobody", ctx do
      account = personal!(ctx, ctx.owner)

      assert {:error, :unauthorized} =
               Ownership.set_owner(ctx.other, account, %{
                 kind: "personal",
                 owner_user_id: ctx.other.id
               })

      assert notices(account.id) == []
    end
  end

  # ── Reader-only audience (task 01a1ea5b stage 4) ──────────────────────────

  describe "audience/2" do
    test "the owner reads it; a non-owner member and an org admin are refused", ctx do
      account = personal!(ctx, ctx.owner)
      agent = agent!()
      {:ok, _} = Ownership.grant(ctx.owner, account, {:agent, agent.id})

      assert {:ok, %{kind: "personal", people: [%{id: owner_id}], agents: [%{id: agent_id}]}} =
               Ownership.audience(ctx.owner, account)

      assert owner_id == ctx.owner.id
      assert agent_id == agent.id

      for viewer <- [ctx.other, ctx.admin, ctx.support] do
        assert {:error, :unauthorized} = Ownership.audience(viewer, account)
      end
    end

    test "a shared mailbox lists its internal members to a member", ctx do
      account = shared!(ctx)
      {:ok, _} = Ownership.grant(ctx.admin, account, {:user, ctx.other.id})
      {:ok, _} = Ownership.grant(ctx.admin, account, {:user, ctx.owner.id})

      assert {:ok, %{people: people}} = Ownership.audience(ctx.other, account)
      assert Enum.sort(Enum.map(people, & &1.id)) == Enum.sort([ctx.other.id, ctx.owner.id])
      assert {:error, :unauthorized} = Ownership.audience(ctx.admin, account)
    end
  end
end
