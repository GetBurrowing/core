defmodule Platform.Mail.AccountsTest do
  @moduledoc """
  `Platform.Mail` accounts, senders, secrets and authorization (task
  01a0cf21 stage 1). Relies on the seeded orgs.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Mail
  alias Platform.Mail.Account
  alias Platform.Mail.Sender
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias Platform.Vault.Credential

  defp user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "mail-#{n}@example.com",
      name: "Mail #{n}",
      oidc_sub: "oidc-mail-#{n}"
    })
    |> Repo.insert!()
  end

  defp member!(user, org_id, role, external \\ false) do
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

  defp attrs(name, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "smtp_host" => "smtp.#{name}.test",
        "smtp_port" => 587,
        "smtp_tls" => "starttls",
        "username" => "#{name}-relay"
      },
      overrides
    )
  end

  defp account!(admin, org_id, name, secrets \\ %{}) do
    {:ok, account} = Mail.create_account(admin, org_id, attrs(name), secrets)
    account
  end

  defp sender!(admin, account, key, address) do
    {:ok, sender} = Mail.put_sender(admin, account, %{"key" => key, "address" => address})
    sender
  end

  setup do
    org_id = Tenancy.get_org_by_slug!("soylent").id
    other_org_id = Tenancy.get_org_by_slug!("sxi").id
    admin = user!() |> member!(org_id, "admin")
    other_admin = user!() |> member!(other_org_id, "admin")
    %{org_id: org_id, other_org_id: other_org_id, admin: admin, other_admin: other_admin}
  end

  describe "secrets" do
    test "the secret is stored in the Vault at integration scope, never on the row", ctx do
      secret = "smtp-pass-#{System.unique_integer([:positive])}"
      account = account!(ctx.admin, ctx.org_id, "ops", %{smtp: secret})

      assert account.smtp_secret_slug == "mail:#{account.id}:smtp"
      assert is_nil(account.imap_secret_slug)

      cred = Repo.get_by!(Credential, slug: account.smtp_secret_slug)
      assert cred.scope_type == "integration"
      assert cred.scope_id == account.id

      # No column on either table holds the value: scan the raw row.
      %{rows: [row]} =
        Repo.query!("SELECT * FROM mail_accounts WHERE id = $1", [Ecto.UUID.dump!(account.id)])

      refute Enum.any?(row, &(is_binary(&1) and &1 =~ secret))

      refute Enum.any?(
               Account.__schema__(:fields) ++ Sender.__schema__(:fields),
               &(to_string(&1) =~ ~r/password|secret$/)
             )

      assert {:ok, ^secret} = Mail.fetch_secret(account, :smtp)
      assert {:error, :not_configured} = Mail.fetch_secret(account, :imap)
    end

    test "replace_secret rotates in place, and first-sets a missing secret", ctx do
      account = account!(ctx.admin, ctx.org_id, "ops", %{smtp: "old"})
      cred = Repo.get_by!(Credential, slug: account.smtp_secret_slug)

      assert {:ok, account} = Mail.replace_secret(ctx.admin, account, :smtp, "new")
      assert {:ok, "new"} = Mail.fetch_secret(account, :smtp)
      assert Repo.get_by!(Credential, slug: account.smtp_secret_slug).id == cred.id

      assert {:ok, account} = Mail.replace_secret(ctx.admin, account, :imap, "imap-pass")
      assert account.imap_secret_slug == "mail:#{account.id}:imap"
      assert {:ok, "imap-pass"} = Mail.fetch_secret(account, :imap)
    end

    test "a member cannot replace a secret", ctx do
      account = account!(ctx.admin, ctx.org_id, "ops", %{smtp: "old"})
      member = user!() |> member!(ctx.org_id, "member")

      assert {:error, :unauthorized} = Mail.replace_secret(member, account, :smtp, "evil")
      assert {:ok, "old"} = Mail.fetch_secret(account, :smtp)
    end
  end

  describe "resolve_sender/3" do
    setup ctx do
      a = account!(ctx.admin, ctx.org_id, "a")
      b = account!(ctx.admin, ctx.org_id, "b")
      sender!(ctx.admin, a, "ops", "ops-a@example.test")
      sender!(ctx.admin, a, "alerts", "alerts-a@example.test")
      sender!(ctx.admin, b, "ops", "ops-b@example.test")
      %{a: a, b: b}
    end

    test "returns B's exact pair for B's id and key", ctx do
      assert {:ok, {account, sender}} = Mail.resolve_sender(ctx.org_id, ctx.b.id, "ops")
      assert account.id == ctx.b.id
      assert sender.address == "ops-b@example.test"

      # Control: the same key on A resolves to A, so the B answer is not a default.
      assert {:ok, {a, a_sender}} = Mail.resolve_sender(ctx.org_id, ctx.a.id, "ops")
      assert a.id == ctx.a.id
      assert a_sender.address == "ops-a@example.test"
    end

    test "a key present only on A is refused for B, never falling back", ctx do
      assert {:ok, _} = Mail.resolve_sender(ctx.org_id, ctx.a.id, "alerts")
      assert {:error, :sender_key_not_found} = Mail.resolve_sender(ctx.org_id, ctx.b.id, "alerts")
      assert {:error, :sender_key_not_found} = Mail.resolve_sender(ctx.org_id, ctx.b.id, nil)
    end

    test "an account from another org is :account_wrong_org", ctx do
      foreign = account!(ctx.other_admin, ctx.other_org_id, "foreign")
      sender!(ctx.other_admin, foreign, "ops", "ops@foreign.test")

      assert {:error, :account_wrong_org} = Mail.resolve_sender(ctx.org_id, foreign.id, "ops")
      assert {:ok, _} = Mail.resolve_sender(ctx.other_org_id, foreign.id, "ops")
    end

    test "unknown, malformed and archived accounts are refused by name", ctx do
      assert {:error, :account_not_found} =
               Mail.resolve_sender(ctx.org_id, Ecto.UUID.generate(), "ops")

      assert {:error, :account_not_found} = Mail.resolve_sender(ctx.org_id, "nope", "ops")
      assert {:error, :account_not_found} = Mail.resolve_sender(ctx.org_id, nil, "ops")

      {:ok, _} = Mail.archive_account(ctx.admin, ctx.b)
      assert {:error, :account_archived} = Mail.resolve_sender(ctx.org_id, ctx.b.id, "ops")
    end
  end

  describe "authorization" do
    test "an org admin may create, update, add senders and archive", ctx do
      assert Mail.can_manage_accounts?(ctx.admin, ctx.org_id)
      account = account!(ctx.admin, ctx.org_id, "ops")
      assert account.internal_only == true
      assert account.read_enabled == false
      assert account.read_folders == []

      assert {:ok, updated} =
               Mail.update_account(ctx.admin, account, %{"internal_only" => false})

      refute updated.internal_only

      assert {:ok, %Sender{}} =
               Mail.put_sender(ctx.admin, account, %{key: "ops", address: "o@x.test"})

      assert {:ok, archived} = Mail.archive_account(ctx.admin, account)
      refute is_nil(archived.archived_at)

      assert {:error, :account_archived} =
               Mail.update_account(ctx.admin, archived, %{"name" => "x"})
    end

    test "an org member (role member) is refused create and update", ctx do
      member = user!() |> member!(ctx.org_id, "member")
      assert Mail.can_use?(member, ctx.org_id)
      refute Mail.can_manage_accounts?(member, ctx.org_id)

      assert {:error, :unauthorized} = Mail.create_account(member, ctx.org_id, attrs("m"), %{})
      assert Mail.list_accounts(ctx.org_id) == []

      account = account!(ctx.admin, ctx.org_id, "ops")

      assert {:error, :unauthorized} =
               Mail.update_account(member, account, %{"internal_only" => false})

      assert {:error, :unauthorized} =
               Mail.put_sender(member, account, %{"key" => "x", "address" => "x@x.test"})

      assert {:error, :unauthorized} = Mail.archive_account(member, account)
      assert Repo.get!(Account, account.id).internal_only == true
      assert is_nil(Repo.get!(Account, account.id).archived_at)
    end

    test "an external admin is refused, and cannot use the module", ctx do
      external = user!() |> member!(ctx.org_id, "admin", true)
      refute Mail.can_use?(external, ctx.org_id)

      assert {:error, :unauthorized} =
               Mail.create_account(external, ctx.org_id, attrs("ext"), %{})
    end

    test "a Fabrikam admin who is not an admin of the org is refused", ctx do
      fabrikam_id = Tenancy.get_org_by_slug!("fabrikam").id
      root = user!() |> member!(fabrikam_id, "admin")
      assert Tenancy.fabrikam_admin?(root)

      assert {:error, :unauthorized} = Mail.create_account(root, ctx.org_id, attrs("root"), %{})

      account = account!(ctx.admin, ctx.org_id, "ops")
      assert {:error, :unauthorized} = Mail.update_account(root, account, %{"name" => "hijack"})
    end

    test "an admin of another org cannot touch this org's account", ctx do
      account = account!(ctx.admin, ctx.org_id, "ops")

      assert {:error, :unauthorized} =
               Mail.update_account(ctx.other_admin, account, %{"name" => "x"})

      # A forged struct naming the other admin's org does not move authority:
      # the check reads the persisted org_id.
      forged = %{account | org_id: ctx.other_org_id}

      assert {:error, :unauthorized} =
               Mail.update_account(ctx.other_admin, forged, %{"name" => "x"})
    end
  end

  describe "reads" do
    test "list_accounts and get_account are org-scoped; list skips archived", ctx do
      a = account!(ctx.admin, ctx.org_id, "a")
      b = account!(ctx.admin, ctx.org_id, "b")
      foreign = account!(ctx.other_admin, ctx.other_org_id, "foreign")
      {:ok, _} = Mail.archive_account(ctx.admin, b)

      assert Enum.map(Mail.list_accounts(ctx.org_id), & &1.id) == [a.id]
      assert Mail.get_account(ctx.org_id, a.id).id == a.id
      assert is_nil(Mail.get_account(ctx.org_id, foreign.id))
      assert is_nil(Mail.get_account(ctx.org_id, "garbage"))
    end

    test "account names are unique per org", ctx do
      account!(ctx.admin, ctx.org_id, "ops")

      assert {:error, %Ecto.Changeset{}} =
               Mail.create_account(ctx.admin, ctx.org_id, attrs("ops"), %{})

      assert {:ok, _} = Mail.create_account(ctx.other_admin, ctx.other_org_id, attrs("ops"), %{})
    end
  end
end
